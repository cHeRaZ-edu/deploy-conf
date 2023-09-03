#!/bin/bash

USER=$1
PROJECT=$2
DEPLOY=$3
EXCLUDES=$4
ENVS=$5

PATH_HOME="/home/$USER/";
PATH_PROJECT="${PATH_HOME}${PROJECT}/"
PATH_DEPLOY="${PATH_HOME}${DEPLOY}/"
PATH_EXCLUDE="${PATH_HOME}${EXCLUDES}"
PATH_ENV="${PATH_HOME}${ENVS}"

echo "PATH_PROJECT=$PATH_PROJECT"
echo "PATH_DEPLOY=$PATH_DEPLOY"
echo "PATH_EXCLUDE=$PATH_EXCLUDE"
echo "PATH_ENV=$PATH_ENV"