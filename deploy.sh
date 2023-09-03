#!/bin/bash
dateformat=`date +"%Y-%m-%d_%H_%M_%S"`
echo '' >> 'deploy.log'
cp 'deploy.log' "deploy-${dateformat}.log"
echo '' > 'deploy.log'
echo -e "########### START DEPLOYMENT ###############\n\n" >> 'deploy.log'


PATH_HOME="$HOME/";

#PATHS PROJECTS
PATH_PROJECT=$1
PATH_DEPLOY=$2
PATH_EXCLUDE=$3
PATH_PROJECT_CONF="${PATH_PROJECT}/deploy.sh"

#PATH DEPLOY

echo -e "$PATH_PROJECT_CONF" >> 'deploy.log'

if [ -f "$PATH_PROJECT_CONF" ]

then
    
    cat "$PATH_EXCLUDE" >> 'deploy.log'

    echo -e "\n" >> 'deploy.log'

    echo -e "\n\nInitial start deployment $PATH_PROJECT to $PATH_DEPLOY \n\n" >> 'deploy.log'
    { #TRY
        rsync -avu --exclude-from="$PATH_EXCLUDE" --delete "$PATH_PROJECT" "$PATH_DEPLOY" >> 'deploy.log'
    } || { # CATCH
        echo -e "Error al intentar hacer deploy, favor de revisar sus variables de configuracion" >> 'deploy.log'
    }

    
    
    
    echo -e "\n Finish deploy" >> 'deploy.log'

else
    echo "Error file $PATH_PROJECT_CONF not found"
fi

echo -e "\n\n########### END DEPLOYMENT ###############\n\n" >> 'deploy.log'
