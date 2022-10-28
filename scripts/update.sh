#!/bin/bash

git remote update
RES=$(git status -uno | grep behind)

if [ $? -eq 0 ]; then
    echo "Newer version available, would you like to update? [y/N]"
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
