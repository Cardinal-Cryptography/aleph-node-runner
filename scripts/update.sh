#!/bin/bash

set -eo pipefail

git remote update
BRANCH=$(git rev-parse --abbrev-ref HEAD)
LOCAL=$(git rev-parse HEAD)
BASE=$(git merge-base HEAD origin/${BRANCH})

if [ $LOCAL = $BASE ]; then
    echo "Updating this repo..."
    git stash
    git pull --rebase origin ${BRANCH}
    git stash pop
    echo "Done"
else
    echo "Repository up-to-date"
fi
