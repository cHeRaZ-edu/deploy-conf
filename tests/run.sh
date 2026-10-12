#!/usr/bin/env bash
# Pruebas de deploy-conf v2 simulando un hosting compartido:
#   repo git con una subcarpeta publicable, public_html servido por php -S, carpeta real que hay que adoptar,
#   deploys buenos, rotos (health) y con error de sintaxis, rollback, candado, limpieza, modo rsync y modo v1.
# Requisitos: bash, git, rsync, php, curl, flock.   Uso: bash tests/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$HERE/deploy.sh"
T="$(mktemp -d /tmp/deploy-conf-test.XXXXXX)"
PORT=8099
PASS=0; FAIL=0
export DEPLOY_CONF_DIR="$T/projects"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()   { if eval "$2"; then echo "[OK]   $1"; PASS=$((PASS+1)); else echo "[FAIL] $1"; FAIL=$((FAIL+1)); sed 's/^/         | /' "$T/last.out" 2>/dev/null | tail -6; fi; }
page() { curl -s "http://127.0.0.1:$PORT/$1"; }
run()  { bash "$DEPLOY" "$@" > "$T/last.out" 2>&1; echo $? > "$T/last.rc"; }
rc()   { cat "$T/last.rc"; }
out()  { cat "$T/last.out"; }

cleanup() { [ -n "${PHP_PID:-}" ] && kill "$PHP_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# ---------- repo de origen ----------
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/work" 2>/dev/null
cd "$T/work"
mkdir -p app/tests app/config
cat > app/index.php <<'E'
<?php $c = @include __DIR__ . '/config/config.php'; echo trim(file_get_contents(__DIR__ . '/VERSION')) . '|' . ($c['secret'] ?? 'SIN-CONFIG');
E
cat > app/health.php <<'E'
<?php if (strpos(file_get_contents(__DIR__ . '/VERSION'), 'broken') !== false) { http_response_code(500); } echo 'ok';
E
echo "v1" > app/VERSION
echo "prueba" > app/tests/secret-test.txt
printf 'app/config/config.php\napp/uploads/*\n' > .gitignore
echo "otra cosa del repo" > README-raiz.md
commit() { echo "$1" > app/VERSION; git add -A; git commit -qm "$1"; git push -q -f origin HEAD:main 2>/dev/null; git rev-parse HEAD; }
git add -A; git commit -qm v1; git push -q origin HEAD:main 2>/dev/null
SHA1="$(git rev-parse HEAD)"
cd "$HERE"

# ---------- hosting simulado ----------
mkdir -p "$T/public_html" "$T/projects"
( cd "$T/public_html" && exec php -S "127.0.0.1:$PORT" > "$T/php.log" 2>&1 ) & PHP_PID=$!
sleep 0.7

# carpeta real "como esta hoy en Hostinger" (subida a mano, con su config)
mkdir -p "$T/public_html/app/config"
echo "<?php return ['secret' => 'S3CR3T'];" > "$T/public_html/app/config/config.php"
echo '<?php echo "viejo|manual";' > "$T/public_html/app/index.php"

cat > "$T/projects/app.conf" <<E
REPO_URL="file://$T/origin.git"
BRANCH="main"
MODE="releases"
BASE="$T/apps/app"
TARGET="$T/public_html/app"
SOURCE_DIR="app"
SHARED=( "config/config.php" "uploads/" )
EXCLUDE=( "tests" )
KEEP_RELEASES=3
CHECK_CMD='find . -name "*.php" -print0 | xargs -0 -r -n1 php -l > /dev/null'
HEALTH_URL="http://127.0.0.1:$PORT/app/health.php"
HEALTH_EXPECT="200"
HEALTH_RETRIES=2
E

echo "== portabilidad"
ok "sin process substitution <(...) (en Hostinger/CageFS no existe /dev/fd)" '! grep -n "<(" "$DEPLOY" | grep -v "^[0-9]*:[[:space:]]*#" | grep -q .'

echo "== modo releases"
run app
ok "sin --adopt no toca la carpeta real y lo explica" '[ "$(rc)" != 0 ] && out | grep -q -- "--adopt" && [ "$(page app/index.php)" = "viejo|manual" ]'

run app init
ok "init clona y pide los compartidos que faltan" '[ "$(rc)" = 0 ] && [ -d "$T/apps/app/repo/.git" ] && out | grep -q "config/config.php"'

run app --adopt
ok "si falta el config compartido, falla sin publicar nada" '[ "$(rc)" != 0 ] && out | grep -q "falta" && [ "$(page app/index.php)" = "viejo|manual" ]'
ok "un deploy fallido no deja releases a medio armar" '[ -z "$(ls -A "$T/apps/app/releases" 2>/dev/null)" ]'

cp "$T/public_html/app/config/config.php" "$T/apps/app/shared/config/config.php" 2>/dev/null || { mkdir -p "$T/apps/app/shared/config"; cp "$T/public_html/app/config/config.php" "$T/apps/app/shared/config/"; }
run app --dry-run
ok "dry-run no cambia nada y avisa del --adopt" '[ "$(rc)" = 0 ] && [ ! -L "$T/public_html/app" ] && out | grep -q "adopt" && [ ! -e "$T/apps/app/current" ]'

run app --adopt
ok "primer deploy con --adopt: publica v1 con la config compartida" '[ "$(rc)" = 0 ] && [ "$(page app/index.php)" = "v1|S3CR3T" ]'
ok "TARGET ahora es symlink y la carpeta vieja quedo respaldada" '[ -L "$T/public_html/app" ] && ls -d "$T"/apps/app/adopted-* >/dev/null 2>&1 && [ -f "$(ls -d "$T"/apps/app/adopted-* | head -1)/index.php" ]'
REL1="$(basename "$(readlink "$T/apps/app/current")")"
ok "no se publica .git, ni tests/, ni lo de fuera de la subcarpeta" '[ ! -e "$T/apps/app/current/.git" ] && [ ! -e "$T/apps/app/current/tests" ] && [ ! -e "$T/apps/app/current/README-raiz.md" ] && [ "$(page app/tests/secret-test.txt | grep -c prueba)" = 0 ]'
ok "config.php y uploads/ son enlaces a shared/" '[ -L "$T/apps/app/current/config/config.php" ] && [ -L "$T/apps/app/current/uploads" ]'

echo "foto" > "$T/public_html/app/uploads/foto.jpg"
cd "$T/work"; SHA2="$(commit v2)"; cd "$HERE"
run app
ok "deploy v2" '[ "$(rc)" = 0 ] && [ "$(page app/index.php)" = "v2|S3CR3T" ]'
ok "lo subido por los usuarios (uploads) sobrevive al deploy" '[ "$(cat "$T/public_html/app/uploads/foto.jpg")" = foto ]'
REL2="$(basename "$(readlink "$T/apps/app/current")")"

cd "$T/work"; commit "v3-broken" >/dev/null; cd "$HERE"
run app
ok "deploy roto (health 500): falla y se regresa solo a v2" '[ "$(rc)" != 0 ] && out | grep -q "se regreso solo" && [ "$(page app/index.php)" = "v2|S3CR3T" ]'

cd "$T/work"; echo '<?php echo "sin cerrar' > app/roto.php; commit v4 >/dev/null; git rm -q app/roto.php; git commit -qm "quitar roto"; cd "$HERE"
cd "$T/work"; git reset -q --hard HEAD~1; git push -q -f origin HEAD:main 2>/dev/null; cd "$HERE"
run app
ok "error de sintaxis PHP: el check frena el deploy y no publica nada" '[ "$(rc)" != 0 ] && out | grep -q "check fallo" && [ "$(page app/index.php)" = "v2|S3CR3T" ]'

run app rollback
ok "rollback regresa a la release anterior (v1)" '[ "$(rc)" = 0 ] && [ "$(page app/index.php)" = "v1|S3CR3T" ]'
run app rollback "$REL2"
ok "rollback a una release especifica (v2)" '[ "$(rc)" = 0 ] && [ "$(page app/index.php)" = "v2|S3CR3T" ]'

run app --ref "$SHA1"
ok "--ref despliega un commit viejo" '[ "$(rc)" = 0 ] && [ "$(page app/index.php)" = "v1|S3CR3T" ]'

cd "$T/work"; git reset -q --hard "$SHA2"; SHA5="$(commit v5)"; SHA6="$(commit v6)"; cd "$HERE"
run app; run app
ok "limpieza: se guardan KEEP_RELEASES (3) y la publicada nunca se borra" '[ "$(ls "$T/apps/app/releases" | wc -l)" -le 3 ] && [ -d "$(readlink "$T/apps/app/current")" ] && [ "$(page app/index.php)" = "v6|S3CR3T" ]'

run app status
ok "status muestra lo publicado y el historial" '[ "$(rc)" = 0 ] && out | grep -q "v6" && out | grep -q "rollback"'

( exec 8>"$T/apps/app/.lock"; flock 8; sleep 3 ) & LOCKER=$!; sleep 0.5
run app
ok "candado: no corren dos deploys a la vez" '[ "$(rc)" != 0 ] && out | grep -q "otro deploy"'
wait "$LOCKER"

cfg_bad() { sed "s|^BASE=.*|BASE=\"$1\"|" "$T/projects/app.conf" > "$T/projects/bad.conf"; }
cfg_bad "$HOME"; run bad
ok "se niega con BASE = \$HOME" '[ "$(rc)" != 0 ] && out | grep -q "peligrosa"'
cfg_bad "$T/public_html/app/.deploy"; run bad
ok "se niega con BASE dentro de TARGET (quedaria publico)" '[ "$(rc)" != 0 ]'
cfg_bad "/"; run bad
ok "se niega con BASE = /" '[ "$(rc)" != 0 ]'

echo "== modo rsync"
mkdir -p "$T/public_html/web/uploads" "$T/public_html/web/config"
echo "subida" > "$T/public_html/web/uploads/a.txt"
echo "<?php return ['secret' => 'RS'];" > "$T/public_html/web/config/config.php"
echo "basura vieja" > "$T/public_html/web/viejo.html"
sed -e 's|^MODE=.*|MODE="rsync"|' -e "s|^BASE=.*|BASE=\"$T/apps/web\"|" -e "s|^TARGET=.*|TARGET=\"$T/public_html/web\"|" \
    -e 's|^SHARED=.*|SHARED=( "config/config.php" )|' -e "s|app/health.php|web/health.php|" "$T/projects/app.conf" > "$T/projects/web.conf"
echo 'PROTECT=( "uploads/" )' >> "$T/projects/web.conf"
cd "$T/work"; git reset -q --hard "$SHA6"; cd "$HERE"
run web --dry-run
ok "rsync dry-run: muestra cambios sin tocar nada" '[ "$(rc)" = 0 ] && [ -f "$T/public_html/web/viejo.html" ] && [ ! -f "$T/public_html/web/index.php" ]'
run web
ok "rsync: publica v6 sin .git ni tests, con la config intacta" '[ "$(rc)" = 0 ] && [ "$(page web/index.php)" = "v6|RS" ] && [ ! -e "$T/public_html/web/.git" ] && [ ! -e "$T/public_html/web/tests" ]'
ok "rsync: protege uploads/ y borra lo que ya no esta en el repo (respaldado)" '[ "$(cat "$T/public_html/web/uploads/a.txt")" = subida ] && [ ! -f "$T/public_html/web/viejo.html" ] && ls "$T"/apps/web/backups/*/viejo.html >/dev/null 2>&1'
cd "$T/work"; commit "v7-broken" >/dev/null; cd "$HERE"
run web
ok "rsync: deploy roto se regresa al anterior" '[ "$(rc)" != 0 ] && [ "$(page web/index.php)" = "v6|RS" ]'

echo "== compatibilidad v1"
mkdir -p "$T/v1src/.git" "$T/v1dst"; echo hola > "$T/v1src/index.html"; echo "x" > "$T/v1src/.git/config"; echo "*.log" > "$T/v1ex"
( cd "$T" && bash "$DEPLOY" "$T/v1src" "$T/v1dst" "$T/v1ex" > "$T/last.out" 2>&1 ); echo $? > "$T/last.rc"
ok "v1: copia como antes (carpeta dentro del destino) pero sin .git" '[ "$(rc)" = 0 ] && [ -f "$T/v1dst/v1src/index.html" ] && [ ! -e "$T/v1dst/v1src/.git" ]'
( cd "$T" && bash "$DEPLOY" "$T/v1src" "/no/existe/destino/x" "$T/v1ex" > "$T/last.out" 2>&1 ); echo $? > "$T/last.rc"
ok "v1: si rsync falla, el script ahora falla (antes decia exito)" '[ "$(rc)" != 0 ]'

echo
echo "RESULTADO: $PASS bien, $FAIL mal"
[ "$FAIL" = 0 ]
