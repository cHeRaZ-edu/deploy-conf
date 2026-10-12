#!/usr/bin/env bash
# deploy-conf v2: despliegues desde git en hosting compartido (Hostinger, HostGator/cPanel, VPS).
#
#   deploy.sh PROYECTO                 despliega la rama configurada
#   deploy.sh PROYECTO --dry-run       solo muestra que haria (no toca nada)
#   deploy.sh PROYECTO --ref REF       despliega una rama, tag o commit especifico
#   deploy.sh PROYECTO --adopt         primera vez: respalda la carpeta real del destino y la cambia por el symlink
#   deploy.sh PROYECTO rollback [REL]  regresa a la release anterior (o a la indicada)
#   deploy.sh PROYECTO status          que esta publicado, releases, archivos compartidos, ultimos deploys
#   deploy.sh PROYECTO init            crea carpetas y clona el repo (primer paso)
#
# La configuracion de cada proyecto vive en projects/PROYECTO.conf (ver projects/example.conf).
# Compatibilidad v1: deploy.sh RUTA_PROYECTO RUTA_DEPLOY ARCHIVO_EXCLUDES  (rsync, como antes pero corregido)
set -Eeuo pipefail

VERSION="2.0.0"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${DEPLOY_CONF_DIR:-$SELF_DIR/projects}"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_off=$'\e[0m'
[ -t 1 ] || { c_red=; c_grn=; c_ylw=; c_off=; }

LOG_FILE=""
log()  { local m; m="$(date '+%F %T')  $*"; echo "$m"; if [ -n "$LOG_FILE" ]; then echo "$m" >> "$LOG_FILE"; fi; }
ok()   { log "${c_grn}OK${c_off} $*"; }
warn() { log "${c_ylw}AVISO${c_off} $*"; }
BUILDING=""  # release a medio armar: si algo falla, se borra para no dejar basura
die()  {
  log "${c_red}ERROR${c_off} $*" >&2
  if [ -n "$BUILDING" ] && [ -d "$BUILDING" ]; then rm -rf -- "$BUILDING"; fi
  exit 1
}

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------- compatibilidad v1
legacy_rsync() {
  # v1: deploy.sh PROYECTO DEPLOY EXCLUDES. Igual que antes (copia la carpeta del proyecto dentro de DEPLOY)
  # pero: nunca publica .git, sin -u (siempre deja lo del repo) y si rsync falla, el script falla.
  local project="$1" deploy="$2" excludes="$3" stamp rc
  stamp="$(date +%Y-%m-%d_%H_%M_%S)"
  LOG_FILE="$PWD/deploy.log"
  if [ -f "$LOG_FILE" ]; then cp "$LOG_FILE" "deploy-$stamp.log"; fi
  : > "$LOG_FILE"
  log "deploy-conf v$VERSION (modo compatible v1): $project -> $deploy"
  set +e
  rsync -a --delete --exclude='.git' --exclude='.git/**' --exclude-from="$excludes" "$project" "$deploy" >> "$LOG_FILE" 2>&1
  rc=$?
  set -e
  [ $rc -eq 0 ] || die "rsync fallo (codigo $rc). Revisa $LOG_FILE"
  ok "deploy terminado"
}

if [ $# -eq 3 ] && [ -d "$1" ] && [ -f "$3" ]; then legacy_rsync "$@"; exit 0; fi

# ---------------------------------------------------------------- argumentos
[ $# -ge 1 ] || usage 1
case "$1" in -h|--help) usage 0 ;; --version) echo "deploy-conf $VERSION"; exit 0 ;; esac
PROJECT="$1"; shift
CMD="deploy"; DRY=0; REF=""; ADOPT=0; ROLLBACK_TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --ref) [ $# -ge 2 ] || die "--ref necesita un valor"; REF="$2"; shift ;;
    --ref=*) REF="${1#--ref=}" ;;
    --adopt) ADOPT=1 ;;
    rollback) CMD="rollback"; if [ $# -ge 2 ] && [[ "$2" != -* ]]; then ROLLBACK_TO="$2"; shift; fi ;;
    status|init) CMD="$1" ;;
    -h|--help) usage 0 ;;
    *) die "argumento desconocido: $1" ;;
  esac
  shift
done
[[ "$PROJECT" =~ ^[A-Za-z0-9._-]+$ ]] || die "nombre de proyecto invalido: $PROJECT"

# ---------------------------------------------------------------- configuracion
CONF="$CONF_DIR/$PROJECT.conf"
[ -f "$CONF" ] || die "no existe $CONF (copia projects/example.conf y ajustalo)"
REPO_URL=""; BRANCH="main"; MODE="releases"; BASE=""; TARGET=""; SOURCE_DIR=""
SHARED=(); EXCLUDE=(); PROTECT=(); KEEP_RELEASES=5
CHECK_CMD=""; BEFORE_ACTIVATE=""; AFTER_ACTIVATE=""
HEALTH_URL=""; HEALTH_EXPECT="200"; HEALTH_TIMEOUT=20; HEALTH_RETRIES=3
# shellcheck disable=SC1090
source "$CONF"

SOURCE_DIR="${SOURCE_DIR%/}"; SOURCE_DIR="${SOURCE_DIR#/}"; BASE="${BASE%/}"; TARGET="${TARGET%/}"
[ -n "$REPO_URL" ] || die "falta REPO_URL en $CONF"
[ -n "$BASE" ] && [ -n "$TARGET" ] || die "faltan BASE o TARGET en $CONF"
[[ "$BASE" == /* && "$TARGET" == /* ]] || die "BASE y TARGET deben ser rutas absolutas"
for p in "$BASE" "$TARGET"; do
  [[ "$p" != *..* ]] || die "ruta con '..': $p"
  case "$p" in /|/home|"$HOME"|/root|/var|/var/www|/etc|/usr|/tmp|/opt|/srv) die "ruta peligrosa para BASE/TARGET: $p" ;; esac
done
[ "$BASE" != "$TARGET" ] || die "BASE y TARGET no pueden ser la misma ruta"
case "$TARGET/" in "$BASE"/*) die "TARGET no puede estar dentro de BASE" ;; esac
case "$BASE/" in "$TARGET"/*) die "BASE no puede estar dentro de TARGET (quedaria publico)" ;; esac
[[ "$MODE" == releases || "$MODE" == rsync ]] || die "MODE debe ser releases o rsync"
[[ "$SOURCE_DIR" != *..* ]] || die "SOURCE_DIR no puede tener .."
{ [[ "$KEEP_RELEASES" =~ ^[0-9]+$ ]] && [ "$KEEP_RELEASES" -ge 2 ]; } || die "KEEP_RELEASES debe ser un numero >= 2"

REPO="$BASE/repo"; RELEASES="$BASE/releases"; SHARED_DIR="$BASE/shared"; CURRENT="$BASE/current"
mkdir -p "$BASE"
LOG_FILE="$BASE/deploy.log"

safe_rel() { [[ -n "$1" && "$1" != /* && "$1" != *..* ]]; }

# ---------------------------------------------------------------- candado
lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$BASE/.lock"
    flock -n 9 || die "ya hay otro deploy de $PROJECT corriendo"
  else
    mkdir "$BASE/.lockdir" 2>/dev/null || die "ya hay otro deploy de $PROJECT corriendo (si no, borra $BASE/.lockdir)"
    trap 'rmdir "$BASE/.lockdir" 2>/dev/null || true' EXIT
  fi
}

# ---------------------------------------------------------------- git
repo_sync() {
  if [ ! -d "$REPO/.git" ]; then
    log "clonando $REPO_URL"
    git clone --quiet --no-checkout "$REPO_URL" "$REPO" || die "no pude clonar $REPO_URL (revisa la deploy key / la URL)"
  fi
  git -C "$REPO" remote set-url origin "$REPO_URL"
  git -C "$REPO" fetch --quiet --prune --tags origin '+refs/heads/*:refs/remotes/origin/*' || die "git fetch fallo (red o permisos)"
}

resolve_ref() {
  local want="${REF:-$BRANCH}" sha cand
  for cand in "origin/$want" "$want"; do
    if sha="$(git -C "$REPO" rev-parse --verify --quiet "$cand^{commit}")"; then echo "$sha"; return 0; fi
  done
  die "no existe la rama/tag/commit '$want' en el repo"
}

subject() { git -C "$REPO" log -1 --format='%h %s' "$1" 2>/dev/null || echo "$1"; }
current_name() { if [ -L "$CURRENT" ]; then basename "$(readlink "$CURRENT")"; fi; }
name_sha() { echo "${1##*-}"; }  # 20261011-120000-abc1234 -> abc1234
# Llena el arreglo global RELS sin usar < <(...): en hostings con CageFS (Hostinger) no existe /dev/fd.
releases_array() {
  local r
  RELS=()
  while IFS= read -r r; do
    if [ -n "$r" ]; then RELS+=("$r"); fi
  done <<< "$(releases_sorted)"
}

releases_sorted() {
  local d n
  for d in "$RELEASES"/*; do
    n="${d##*/}"
    if [ -d "$d" ] && [[ "$n" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]+$ ]]; then echo "$n"; fi
  done
}
history() { echo "$(date '+%F %T') | $* " >> "$BASE/history"; }

# ---------------------------------------------------------------- armado
extract() { # sha destino
  local tree="$1"
  if [ -n "$SOURCE_DIR" ]; then tree="$1:$SOURCE_DIR"; fi
  git -C "$REPO" cat-file -e "$tree" 2>/dev/null || die "el commit ${1:0:7} no tiene la carpeta '$SOURCE_DIR'"
  mkdir -p "$2"
  git -C "$REPO" archive --format=tar "$tree" | tar -x -C "$2" || die "no pude extraer el codigo"
}

apply_excludes() { # carpeta
  local dir="$1" p
  for p in ${EXCLUDE[@]+"${EXCLUDE[@]}"}; do
    safe_rel "$p" || die "EXCLUDE invalido: $p"
    ( shopt -s nullglob dotglob; cd "$dir"; for m in $p; do rm -rf -- "$m"; done )
  done
}

link_shared() { # carpeta
  local dir="$1" s name src
  for s in ${SHARED[@]+"${SHARED[@]}"}; do
    name="${s%/}"; safe_rel "$name" || die "SHARED invalido: $s"
    src="$SHARED_DIR/$name"
    if [ ! -e "$src" ]; then
      if [[ "$s" == */ ]]; then mkdir -p "$src"; log "creada carpeta compartida $name/"
      elif [ -e "$dir/$name" ]; then mkdir -p "$(dirname "$src")"; cp -a "$dir/$name" "$src"; log "sembrado $name desde el repo"
      else die "falta $src: copialo ahi antes de desplegar (es un archivo que no vive en git)"
      fi
    fi
    rm -rf -- "${dir:?}/$name"
    mkdir -p "$(dirname "$dir/$name")"
    ln -s "$src" "$dir/$name"
  done
}

run_hook() { # nombre comando carpeta
  [ -n "$2" ] || return 0
  log "$1: $2"
  ( cd "$3" && bash -c "$2" ) || return 1
}

health() {
  [ -n "$HEALTH_URL" ] || return 0
  local i code want
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" || true)"
    for want in $HEALTH_EXPECT; do
      if [ "$code" = "$want" ]; then ok "health $HEALTH_URL -> $code"; return 0; fi
    done
    warn "health $HEALTH_URL -> ${code:-sin respuesta} (intento $i/$HEALTH_RETRIES)"
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------- modo releases
point_current() { ln -sfn "$1" "$CURRENT.new" && mv -Tf "$CURRENT.new" "$CURRENT"; }

ensure_target() {
  if [ -L "$TARGET" ]; then
    if [ "$(readlink "$TARGET")" != "$CURRENT" ]; then
      ln -sfn "$CURRENT" "$TARGET.new" && mv -Tf "$TARGET.new" "$TARGET"
      log "TARGET reenlazado a $CURRENT"
    fi
  elif [ -e "$TARGET" ]; then
    if [ "$ADOPT" = 1 ]; then
      local bk; bk="$BASE/adopted-$(date +%Y%m%d-%H%M%S)"
      { mv "$TARGET" "$bk" && ln -s "$CURRENT" "$TARGET"; } || die "no pude reemplazar $TARGET"
      ok "la carpeta que habia en TARGET se respaldo en $bk"
    else
      die "$TARGET es una carpeta real. La primera vez corre con --adopt (se respalda en $BASE/adopted-FECHA y se cambia por el symlink)"
    fi
  else
    mkdir -p "$(dirname "$TARGET")" && ln -s "$CURRENT" "$TARGET"
  fi
}

cleanup_releases() {
  local cur all=() n i del=0
  cur="$(current_name)"
  releases_array; all=( ${RELS[@]+"${RELS[@]}"} )
  n=${#all[@]}
  ((n > KEEP_RELEASES)) || return 0
  for ((i = 0; i < n - KEEP_RELEASES; i++)); do
    [ "${all[$i]}" = "$cur" ] && continue
    rm -rf -- "${RELEASES:?}/${all[$i]}"; del=$((del + 1))
  done
  ((del == 0)) || log "releases viejas borradas: $del (se guardan $KEEP_RELEASES)"
}

deploy_releases() {
  local sha="$1" cur prev name dir
  cur="$(current_name)"
  name="$(date +%Y%m%d-%H%M%S)-${sha:0:7}"
  while [ -e "$RELEASES/$name" ]; do sleep 1; name="$(date +%Y%m%d-%H%M%S)-${sha:0:7}"; done
  dir="$RELEASES/$name"
  if [ -L "$TARGET" ] || [ ! -e "$TARGET" ] || [ "$ADOPT" = 1 ]; then :; else
    die "$TARGET es una carpeta real. La primera vez corre con --adopt (se respalda en $BASE/adopted-FECHA y se cambia por el symlink)"
  fi
  log "armando release $name"
  BUILDING="$dir"
  extract "$sha" "$dir"
  apply_excludes "$dir"
  link_shared "$dir"
  run_hook "check" "$CHECK_CMD" "$dir" || { rm -rf -- "$dir"; die "el check fallo: no se publico nada"; }
  run_hook "antes de activar" "$BEFORE_ACTIVATE" "$dir" || { rm -rf -- "$dir"; die "BEFORE_ACTIVATE fallo: no se publico nada"; }
  prev=""; if [ -n "$cur" ] && [ -d "$RELEASES/$cur" ]; then prev="$RELEASES/$cur"; fi
  BUILDING=""
  point_current "$dir"
  ensure_target
  ok "publicada $name ($(subject "$sha"))"
  if ! health; then
    if [ -n "$prev" ]; then
      point_current "$prev"
      history "deploy | $name | $sha | FALLO health, regresado a $cur"
      die "el sitio no respondio bien: se regreso solo a $cur. La release rota queda en $dir para revisarla."
    fi
    history "deploy | $name | $sha | FALLO health, sin anterior"
    die "el sitio no respondio bien y no hay release anterior a la cual regresar"
  fi
  run_hook "despues de activar" "$AFTER_ACTIVATE" "$CURRENT/" || warn "AFTER_ACTIVATE fallo (el deploy ya esta publicado)"
  history "deploy | $name | $sha | ok"
  cleanup_releases
}

rollback_releases() {
  local cur target="" all=() i
  cur="$(current_name)"
  [ -n "$cur" ] || die "no hay ninguna release publicada"
  releases_array; all=( ${RELS[@]+"${RELS[@]}"} )
  if [ -n "$ROLLBACK_TO" ]; then
    target="$ROLLBACK_TO"
    [ -d "$RELEASES/$target" ] || die "no existe la release $target (mira: deploy.sh $PROJECT status)"
  else
    for ((i = ${#all[@]} - 1; i >= 0; i--)); do
      if [ "${all[$i]}" = "$cur" ]; then
        if ((i > 0)); then target="${all[$((i - 1))]}"; fi
        break
      fi
    done
    [ -n "$target" ] || die "no hay una release anterior a $cur"
  fi
  [ "$target" != "$cur" ] || die "$target ya es la release publicada"
  point_current "$RELEASES/$target"
  ensure_target
  ok "rollback: $cur -> $target"
  health || warn "el sitio tampoco responde bien con $target; revisa"
  history "rollback | $target | $(name_sha "$target") | desde $cur"
}

# ---------------------------------------------------------------- modo rsync
last_ok_sha() { # N-esimo deploy correcto contando desde el final (1 = el ultimo)
  grep ' | ok $' "$BASE/history" 2>/dev/null | grep '| deploy |' | tail -"$1" | head -1 | awk -F' [|] ' '{print $4}'
}

deploy_rsync() {
  local sha="$1" stage="$BASE/staging" name ex rc
  name="$(date +%Y%m%d-%H%M%S)-${sha:0:7}"
  rm -rf -- "$stage"; extract "$sha" "$stage"; apply_excludes "$stage"
  run_hook "check" "$CHECK_CMD" "$stage" || die "el check fallo: no se publico nada"
  ex="$BASE/.rsync-exclude"
  { echo ".git"; echo ".git/**"
    for s in ${SHARED[@]+"${SHARED[@]}"} ${PROTECT[@]+"${PROTECT[@]}"}; do echo "/${s#/}"; done
  } > "$ex"
  mkdir -p "$TARGET"
  local opts=(-a --delete --filter=':- .gitignore' --exclude-from="$ex")
  if [ "$DRY" = 1 ]; then opts+=(--dry-run --itemize-changes); else opts+=(--backup "--backup-dir=$BASE/backups/$name"); fi
  set +e; rsync "${opts[@]}" "$stage/" "$TARGET/"; rc=$?; set -e
  [ $rc -eq 0 ] || die "rsync fallo (codigo $rc)"
  if [ "$DRY" = 1 ]; then ok "dry-run: arriba lo que cambiaria en $TARGET (no se toco nada)"; return 0; fi
  ok "publicado $(subject "$sha") con rsync (lo reemplazado quedo en $BASE/backups/$name)"
  if ! health; then
    local prevsha; prevsha="$(last_ok_sha 1)"
    if [ -n "$prevsha" ] && [ "$prevsha" != "$sha" ]; then
      warn "regresando al deploy anterior ${prevsha:0:7}"
      rm -rf -- "$stage"; extract "$prevsha" "$stage"; apply_excludes "$stage"
      rsync -a --delete --filter=':- .gitignore' --exclude-from="$ex" "$stage/" "$TARGET/" || true
      history "deploy | $name | $sha | FALLO health, regresado a ${prevsha:0:7}"
      die "el sitio no respondio bien: se regreso a ${prevsha:0:7}"
    fi
    history "deploy | $name | $sha | FALLO health, sin anterior"
    die "el sitio no respondio bien y no hay deploy anterior registrado"
  fi
  run_hook "despues de activar" "$AFTER_ACTIVATE" "$TARGET" || warn "AFTER_ACTIVATE fallo"
  history "deploy | $name | $sha | ok"
}

rollback_rsync() {
  local sha="$ROLLBACK_TO"
  [ -n "$sha" ] || sha="$(last_ok_sha 2)"
  [ -n "$sha" ] || die "no hay un deploy anterior registrado"
  REF="$sha"; deploy_rsync "$(resolve_ref)"
}

# ---------------------------------------------------------------- dry-run, status, init
dry_run_releases() {
  local sha="$1" cur cursha="" s
  cur="$(current_name)"
  if [ -n "$cur" ]; then cursha="$(name_sha "$cur")"; fi
  echo "Proyecto:   $PROJECT ($MODE, rama $BRANCH)"
  echo "Publicado:  ${cur:-(nada)}${cursha:+  ->  $(subject "$cursha")}"
  echo "Nuevo:      $(subject "$sha")"
  if [ -n "$cursha" ]; then
    echo; echo "Commits nuevos${SOURCE_DIR:+ en $SOURCE_DIR/}:"
    git -C "$REPO" log --oneline "$cursha..$sha" ${SOURCE_DIR:+-- "$SOURCE_DIR"} | sed 's/^/  /' || true
    echo; echo "Archivos que cambian:"
    git -C "$REPO" diff --stat "$cursha" "$sha" ${SOURCE_DIR:+-- "$SOURCE_DIR"} | sed 's/^/  /' || true
  fi
  echo; echo "Compartidos (no se tocan; viven en $SHARED_DIR):"
  for s in ${SHARED[@]+"${SHARED[@]}"}; do
    if [ -e "$SHARED_DIR/${s%/}" ]; then echo "  ok     $s"; elif [[ "$s" == */ ]]; then echo "  (se crea) $s"; else echo "  FALTA  $s"; fi
  done
  if [ ${#EXCLUDE[@]} -gt 0 ]; then echo "No se publican: ${EXCLUDE[*]}"; fi
  echo
  if [ -L "$TARGET" ]; then echo "TARGET:     $TARGET -> $(readlink "$TARGET")"
  elif [ -e "$TARGET" ]; then echo "TARGET:     $TARGET es carpeta real (el primer deploy necesita --adopt)"
  else echo "TARGET:     $TARGET (se creara el symlink)"; fi
  ok "dry-run: no se cambio nada"
}

status() {
  local s cur
  echo "deploy-conf $VERSION  |  proyecto $PROJECT  |  modo $MODE  |  rama $BRANCH"
  echo "repo:      $REPO_URL"
  if [ "$MODE" = releases ]; then
    cur="$(current_name)"
    echo "publicado: ${cur:-(nada)}"
    if [ -d "$REPO/.git" ] && [ -n "$cur" ]; then echo "commit:    $(subject "$(name_sha "$cur")")"; fi
    if [ -L "$TARGET" ]; then echo "TARGET:    $TARGET -> $(readlink "$TARGET")"; else echo "TARGET:    $TARGET (${c_ylw}no es symlink${c_off})"; fi
    echo "releases:"
    releases_sorted | while read -r r; do if [ "$r" = "$cur" ]; then echo "  * $r"; else echo "    $r"; fi; done
  else
    echo "TARGET:    $TARGET"
  fi
  echo "compartidos ($SHARED_DIR):"
  for s in ${SHARED[@]+"${SHARED[@]}"}; do if [ -e "$SHARED_DIR/${s%/}" ]; then echo "  ok     $s"; else echo "  FALTA  $s"; fi; done
  echo "ultimos movimientos:"
  if [ -f "$BASE/history" ]; then tail -5 "$BASE/history" | sed 's/^/  /'; else echo "  (ninguno)"; fi
}

init() {
  local s
  mkdir -p "$RELEASES" "$SHARED_DIR"
  repo_sync
  ok "listo: $BASE"
  echo "Siguiente:"
  for s in ${SHARED[@]+"${SHARED[@]}"}; do
    if [ ! -e "$SHARED_DIR/${s%/}" ] && [[ "$s" != */ ]]; then echo "  - copia $s a $SHARED_DIR/${s%/}"; fi
  done
  echo "  - revisa con:  $0 $PROJECT --dry-run"
}

# ---------------------------------------------------------------- main
case "$CMD" in
  status) status; exit 0 ;;
  init)   lock; init; exit 0 ;;
esac
lock
repo_sync
if [ "$CMD" = rollback ]; then
  log "== rollback $PROJECT"
  if [ "$MODE" = releases ]; then rollback_releases; else rollback_rsync; fi
  exit 0
fi
SHA="$(resolve_ref)"
if [ "$DRY" = 1 ]; then
  if [ "$MODE" = releases ]; then dry_run_releases "$SHA"; else deploy_rsync "$SHA"; fi
  exit 0
fi
log "== deploy $PROJECT ($MODE) -> $(subject "$SHA")"
if [ "$MODE" = releases ]; then deploy_releases "$SHA"; else deploy_rsync "$SHA"; fi
