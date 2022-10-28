#!/bin/bash

set -eo pipefail

Help()
{
    echo "Run the signer tool."
    echo "Syntax: ./signer.sh [--p2p_secret_path <value>]"
    echo
    echo "options:"
    echo "p2p_secret_path Use a custom path for the p2p_secret."
    echo "help            Print this help."
    echo
    echo "Example usage:"
    echo "./signer.sh"
    echo
    echo "or, providing a custom secret path:"
    echo "./signer.sh --p2p_secret_path /home/test/aleph-data/p2p_secret"
    echo
}

NAME="aleph-signer"
VOLUME="/data"
CHAINSPEC_FILE="chainspec.json"
CONTAINER_NAME="aleph-signer"
SIGNER_VERSION="fca5dd5"
NODE_KEY_PATH="/data/p2p_secret"
SIGNER_IMAGE=public.ecr.aws/p6e8q1z1/peer-verifier:${SIGNER_VERSION}
ALEPH_DIRECTORY="${HOME}/.alephzero"
HOST_SECRET_PATH="${ALEPH_DIRECTORY}/p2p_secret"


while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) # display Help
            Help
            exit;;
        --p2p_secret_path)
            HOST_SECRET_PATH="$2"
            shift 2;;
        -* | --* )
            echo "Warning: unrecognized option: $1"
            exit;; 
        *)
            echo "Unrecognized command"
            Help
            exit;;
  esac
done

docker pull ${SIGNER_IMAGE} > /dev/null
HOST_SECRET_PATH=$(dirname ${HOST_SECRET_PATH})

# remove the container if it exists
if [ "$(docker ps -aq -f status=exited -f name=${CONTAINER_NAME})" ]; then
    docker rm ${CONTAINER_NAME} > /dev/null
fi


docker run -e P2P_SECRET_PATH="${NODE_KEY_PATH}" \
           -u $(id -u):$(id -g) \
           --mount type=bind,source=${HOST_SECRET_PATH},target=${VOLUME} \
           --name ${CONTAINER_NAME} \
           ${SIGNER_IMAGE}

