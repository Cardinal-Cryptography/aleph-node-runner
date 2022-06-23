#!/bin/bash

set -euo pipefail

NAME="aleph-signer"
BASE_PATH="/data"
CHAINSPEC_FILE="chainspec.json"
CONTAINER_NAME="aleph-signer"
SIGNER_VERSION="fe6399f"
NODE_KEY_PATH="/data/p2p_secret"
SIGNER_IMAGE=public.ecr.aws/p6e8q1z1/peer-verifier:${SIGNER_VERSION}

docker pull ${SIGNER_IMAGE} > /dev/null
source env/validator

# remove the container if it exists
if [ "$(docker ps -aq -f status=exited -f name=${CONTAINER_NAME})" ]; then
    docker rm ${CONTAINER_NAME} > /dev/null
fi


docker run -e PEER_ID="$1" -e P2P_SECRET_PATH="${NODE_KEY_PATH}" -u $(id -u):$(id -g) --mount type=bind,source=$(pwd),target=${BASE_PATH} --name ${CONTAINER_NAME} ${SIGNER_IMAGE}

