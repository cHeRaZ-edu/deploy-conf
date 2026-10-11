# deploy-conf

Despliegues desde git en **hosting compartido** (Hostinger, HostGator/cPanel) o un VPS, con SSH y un solo comando.

```bash
~/deploy-conf/deploy.sh drive            # despliega la rama configurada
~/deploy-conf/deploy.sh drive --dry-run  # muestra commits y archivos que cambian, sin tocar nada
~/deploy-conf/deploy.sh drive rollback   # regresa a la version anterior en un segundo
~/deploy-conf/deploy.sh drive status     # que esta publicado, releases, historial
```

## Como funciona (modo `releases`, recomendado)

```
~/apps/drive/
  repo/                       clon de git (solo se actualiza con fetch; nadie lo edita)
  releases/
    20261011-120000-fc9e8c3/  copia limpia de la carpeta publicable de ese commit
    20261012-093000-aed2a69/
  shared/                     lo que NO vive en git y sobrevive a todo: config, uploads...
  current -> releases/20261012-093000-aed2a69
  history, deploy.log

public_html/drive-api -> ~/apps/drive/current      (symlink)
```

Cada deploy:

1. Toma un candado, para que no corran dos a la vez.
2. Hace `git fetch` del repo.
3. Extrae **solo** la subcarpeta configurada (nunca `.git`) a una release nueva.
4. Quita lo excluido (por ejemplo `tests`).
5. Enlaza lo compartido desde `shared/`.
6. Corre un check, por ejemplo `php -l` de todo. Si falla, **no se publica nada**.
7. Cambia el symlink `current`. Es **atomico**: no hay un momento con archivos mezclados.
8. Hace un health check con `curl`. Si el sitio no responde lo esperado, **regresa solo** a la release anterior.
9. Borra las releases viejas, guardando las ultimas `KEEP_RELEASES`.

Si algo falla a medio armar, la release incompleta se borra.

El modo **`rsync`** copia sobre una carpeta normal, como hacia la v1, pero:

- Nunca publica `.git`.
- Protege lo que esta en `.gitignore`, `SHARED` y `PROTECT`.
- Respalda lo reemplazado en `backups/FECHA/`.
- Tiene `--dry-run`.
- Falla de verdad si rsync falla, y regresa al deploy anterior si el health check falla.

## Configuracion

Copia `projects/example.conf` como `projects/MIPROYECTO.conf`. Los `.conf` reales no se suben al repo. Variables:

| Variable | Para que |
|---|---|
| `REPO_URL`, `BRANCH` | Que se despliega (privado: `git@github.com:...` con deploy key) |
| `MODE` | `releases` o `rsync` |
| `BASE` | Carpeta privada del deploy, **fuera** de `public_html` |
| `TARGET` | Lo que se publica (symlink en releases, carpeta en rsync) |
| `SOURCE_DIR` | Subcarpeta del repo a publicar (`""` = todo) |
| `SHARED` | Archivos/carpetas fuera de git que se conservan (`"uploads/"` = carpeta) |
| `EXCLUDE` | Rutas del repo que no se publican |
| `PROTECT` | Solo rsync: rutas del destino que nunca se tocan |
| `CHECK_CMD`, `BEFORE_ACTIVATE`, `AFTER_ACTIVATE` | Ganchos en bash |
| `HEALTH_URL`, `HEALTH_EXPECT` | Revision despues de publicar (rollback automatico si falla) |
| `KEEP_RELEASES` | Cuantas releases guardar |

Protecciones: se niega a desplegar si `BASE` o `TARGET` son `/`, `$HOME` u otras rutas del sistema, o si `BASE` queda dentro de `TARGET` (seria publica). La primera vez que `TARGET` es una carpeta real, exige `--adopt`, que la respalda en `BASE/adopted-FECHA` antes de cambiarla por el symlink.

## Guia: muve drive en Hostinger

En Hostinger el home (`~`) esta fuera de `public_html` y el servidor sigue symlinks hacia el home. Ya esta probado.

**1. Deploy key (solo lectura) para el repo privado**

```bash
ssh-keygen -t ed25519 -N "" -C "hostinger-drive" -f ~/.ssh/drive_deploy
cat ~/.ssh/drive_deploy.pub
```

Pega esa llave en GitHub: `drive-project` → **Settings → Deploy keys → Add deploy key**, sin "Allow write access". Luego:

```bash
cat >> ~/.ssh/config <<'E'
Host github-drive
  HostName github.com
  User git
  IdentityFile ~/.ssh/drive_deploy
  IdentitiesOnly yes
E
chmod 600 ~/.ssh/config
ssh -T github-drive   # debe decir "Hi cHeRaZ-edu/drive-project! You've successfully authenticated"
```

Si el hosting bloquea el puerto 22, en ese bloque cambia `HostName github.com` por `HostName ssh.github.com` y agrega `Port 443`.

**2. Configurar el proyecto**

```bash
cd ~/deploy-conf && git pull
cat > projects/drive.conf <<'E'
REPO_URL="github-drive:cHeRaZ-edu/drive-project.git"
BRANCH="main"
MODE="releases"
BASE="$HOME/apps/drive"
TARGET="$HOME/domains/edu-dungeons.com/public_html/drive-api"
SOURCE_DIR="server"
SHARED=( "config/config.php" "config/install.lock" )
EXCLUDE=( "tests" "install.php" )
KEEP_RELEASES=5
CHECK_CMD='find . -name "*.php" -print0 | xargs -0 -r -n1 php -l > /dev/null'
HEALTH_URL="https://edu-dungeons.com/drive-api/panel"
HEALTH_EXPECT="200"
E
~/deploy-conf/deploy.sh drive init
```

**3. Pasar los secretos actuales a `shared/` y revisar**

```bash
mkdir -p ~/apps/drive/shared/config
cp ~/domains/edu-dungeons.com/public_html/drive-api/config/config.php  ~/apps/drive/shared/config/
cp ~/domains/edu-dungeons.com/public_html/drive-api/config/install.lock ~/apps/drive/shared/config/
~/deploy-conf/deploy.sh drive --dry-run
```

**4. Primer deploy**: respalda la carpeta actual en `~/apps/drive/adopted-FECHA` y la cambia por el symlink.

```bash
~/deploy-conf/deploy.sh drive --adopt
```

**De ahi en adelante:** `~/deploy-conf/deploy.sh drive`. El cron no cambia, porque la ruta `public_html/drive-api/cron.php` sigue existiendo a traves del symlink.

## Compatibilidad con la v1

La llamada vieja sigue funcionando y se comporta igual (copia la carpeta del proyecto dentro del destino), con estas correcciones: ya no publica `.git`, ya no usa `-u` (que se saltaba archivos "mas nuevos" en el servidor) y, si rsync falla, el script falla en lugar de decir que todo salio bien.

```bash
bash deploy.sh RUTA_PROYECTO RUTA_DEPLOY ARCHIVO_EXCLUDES
```

En cPanel/HostGator se puede seguir disparando desde `.cpanel.yml`:

```yaml
---
deployment:
  tasks:
    - /bin/bash $HOME/deploy-conf/deploy.sh miproyecto
```

## Pruebas

```bash
bash tests/run.sh   # simula un hosting compartido: 28 pruebas (releases, rollback, health, candado, rsync, v1)
```

Requiere `bash`, `git`, `rsync`, `php`, `curl` y `flock`.
