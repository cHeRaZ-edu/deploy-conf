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
# RUTA DEL RPOYECTO
PROJECT="$HOME/express-app"
# RUTA DE LOS GIT INGORE
EXCLUDES="$PROJECT/.gitignore"
#RUTA DONDE SE VA DESPLEGAR
DEPLOY="/var/www/html"
# ARCHIVOS A EXCLUIR DEL ESPLIEGUE
declare -a ignores=("deploy.sh" ".gitignore" ".envExample" "excludes.temp")
# RUTA DEL REPOSITORIO DEPLOY-CONF
DEPLOY_CONF="$HOME/deploy-conf"

# ARCHIVO TEMPORTAL DE EXCLUSIONES
PATH_TEMP_EXCLUDE="$PROJECT/excludes.temp"

cp "$EXCLUDES" "$PATH_TEMP_EXCLUDE"

echo -e "\n" >> "$PATH_TEMP_EXCLUDE"

for i in "${ignores[@]}"
do
    echo -e "$i" >> "$PATH_TEMP_EXCLUDE"
done

cd "$DEPLOY_CONF"

# Iniciar deploy
bash deploy.sh "$PROJECT" "$DEPLOY" "$PATH_TEMP_EXCLUDE"

# BORRAR ARCHIVO TEMPORAL
rm "$PATH_TEMP_EXCLUDE"


```


En tu archivo `.cpanel.yml`

```
---
deployment:
  tasks:
    - /bin/bash deploy.sh
```