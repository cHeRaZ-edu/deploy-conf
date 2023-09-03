# deploy-conf
## Comando para hacer deploy

Este proyecto se creo para poder hacer deployment desde cpanel.
Todo se basa en el comando `rsync`

Clona este proyecto en la carpeta del usuario

```
git clone https://github.com/cHeRaZ-edu/deploy-conf.git
```


Dentro de tu proyecto agrega un archivo `deploy.sh`

```
# Tu usuario del servidor
USER=$1
# Directorio del repositorio deploy-conf
DEPLOY_CONF="/home/$USER/deploy-conf"
# Nombre de la carpeta del proyecto 
PROJECT=$2
# Carpeta donde se sincroniza produccion
DEPLOY=$3
# Archivo para excluir archivos que no quieres sincronizar
EXCLUDES="$PROJECT/.gitignore"
# Variables de entorno, aun no esta implementado, se tiene que agregar manualemente
ENVS="$PROJECT/.envPRD"



cd "$DEPLOY_CONF"

# Iniciar deploy
bash deploy.sh "$USER" "$PROJECT" "$DEPLOY" "$EXCLUDES" "$ENVS"

```


En tu archivo `.cpanel.yml`

```
---
deployment:
  tasks:
    - /bin/bash deploy.sh "$USER" app-express app
```