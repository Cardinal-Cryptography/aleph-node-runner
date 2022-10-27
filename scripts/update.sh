#!/bin/bash

set -eo pipefail

git remote update
BRANCH=$(git rev-parse --abbrev-ref HEAD)
LOCAL=$(git rev-parse HEAD)
BASE=$(git merge-base HEAD origin/${BRANCH})

if [ $LOCAL = $BASE ]; then
    echo "Newer version available, would you like to update? y/N"
    read -r UPDATE
    if [[ "${UPDATE}" != 'y' ]]
    then
        echo "Skipping the update. You can still do it manually using git."
        exit 0
    fi


    echo "Updating this repo..."
    git stash || true
    git pull --rebase origin ${BRANCH}
    git stash pop || true
    echo "Done"
else
    echo "Repository up-to-date"
fi
