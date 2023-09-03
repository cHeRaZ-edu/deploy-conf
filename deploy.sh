#!/bin/bash
dateformat=`date +"%Y-%m-%d_%H_%M_%S"`
echo '' >> 'deploy.log'
cp 'deploy.log' "deploy-${dateformat}.log"
echo '' > 'deploy.log'
echo -e "########### START DEPLOYMENT ###############\n\n" >> 'deploy.log'


USER=$1
PROJECT=$2
DEPLOY=$3
EXCLUDES=$4
ENVS=$5

PATH_HOME="/home/$USER/";

#PATHS DEPLOY PROJECT
PATH_CONF="${PATH_HOME}deploy-conf/"
PATH_TEMP_EXCLUDE="${PATH_CONF}excludes.temp"

#PATHS PROJECTS
PATH_PROJECT="${PATH_HOME}${PROJECT}/"
PATH_EXCLUDE="${PATH_HOME}${EXCLUDES}"
PATH_ENV="${PATH_HOME}${ENVS}"
PATH_PROJECT_CONF="${PATH_PROJECT}deploy.sh"

#PATH DEPLOY
PATH_DEPLOY="${PATH_HOME}${DEPLOY}/"

#PATH RECOVERY
# ...
echo -e "$PATH_PROJECT_CONF" >> 'deploy.log'

if [ -f "$PATH_PROJECT_CONF" ]

then

    echo "Prepare file excludes ..." >> 'deploy.log'
    cp "$PATH_EXCLUDE" "$PATH_TEMP_EXCLUDE"
    
    echo "Prepare $PATH_EXCLUDE $PATH_TEMP_EXCLUDE" >> 'deploy.log'
    
    echo -e "\ndeploy.sh" >> "$PATH_TEMP_EXCLUDE"
    # IGNORE HARD CORDE ENVS REPO
    echo -e ".envExample" >> "$PATH_TEMP_EXCLUDE"
    echo -e ".envPRD" >> "$PATH_TEMP_EXCLUDE"
    
    echo -e "\nShow excludes:\n" >> 'deploy.log'
    
    cat "$PATH_TEMP_EXCLUDE" >> 'deploy.log'

    echo -e "\n" >> 'deploy.log'

    echo -e "\n\nInitial start deployment $PATH_PROJECT to $PATH_DEPLOY \n\n" >> 'deploy.log'
    { #TRY
        rsync -avu --exclude-from="$PATH_EXCLUDE" --delete "$PATH_PROJECT" "$PATH_DEPLOY" >> 'deploy.log' &&
        rm "$PATH_TEMP_EXCLUDE"
    } || { # CATCH
        echo -e "Error al intentar hacer deploy, favor de revisar sus variables de configuracion" >> 'deploy.log'
    }

    
    
    
    echo -e "\n Finish deploy" >> 'deploy.log'

    # cat 'deploy.log' | grep -q "error" >> /dev/null
    # if [  ]; then
    #     echo "Error a intentar desplear app favor revisar ${PATH_CONF}deploy.log"
    # else
    #     echo "Finish deploy"
    # fi

else
    echo "Error file $PATH_PROJECT_CONF not found"
fi

echo -e "\n\n########### END DEPLOYMENT ###############\n\n" >> 'deploy.log'
