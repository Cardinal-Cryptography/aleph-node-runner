#!/bin/bash

set -eo pipefail

Help()
{
    echo "Run the aleph-node as either a validator or an archivist."
    echo "Syntax: ./run_node.sh [--<name|image|data_dir> <value>] [--<archivist|mainnet|build_only|sync_from_genesis>]"
    echo
    echo "options:"
    echo "archivist         Run the node as an archivist (the default is to run as a validator)"
    echo "n | name          Set the node's name."
    echo "d | data_dir      Specify the directory where all the chain data will be stored (default: ~/.alephzero)."
    echo "mainnet           Join the mainnet (by default the script will join testnet)."
    echo "i | image         Specify the Docker image to use"
    echo "build_only        Do not run after the setup."
    echo "sync_from_genesis Perform a full sync instead of downloading the backup."
    echo "help              Print this help."
    echo
    echo "Example usage:"
    echo "./run_node.sh --name my-aleph-node --mainnet"
    echo
    echo "or, shorter:"
    echo "./run_node.sh --n my-aleph-node --mainnet"
    echo
}

echo "Updating this repo..."
# git pull origin main
echo "Done"


# The defaults
NAME="aleph-node-$(xxd -l "16" -p /dev/urandom | tr -d " \n" ; echo)"
BASE_PATH="/data"
HOST_BASE_PATH="${HOME}/.alephzero"
DB_SNAPSHOT_FILE="db_backup.tar.gz"
DB_SNAPSHOT_URL="https://db.test.azero.dev/latest.html"
MAINNET_DB_SNAPSHOT_URL="https://db.azero.dev/latest.html"
DB_SNAPSHOT_PATH="chains/testnet/"     # testnet by default
CHAINSPEC_FILE="testnet_chainspec.json"


while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) # display Help
            Help
            exit;;
        --archivist) # Run as an archivist
            ARCHIVIST=true
            shift;;
        -n | --name) # Enter a name
            NAME="$2"
            shift 2;;
        -d | --data_dir) # Choose the data directory
            HOST_BASE_PATH="$2"
            shift 2;;
        --mainnet) # Join the mainnet
            DB_SNAPSHOT_PATH="chains/mainnet/"
            CHAINSPEC_FILE="mainnet_chainspec.json"
            DB_SNAPSHOT_URL="${MAINNET_DB_SNAPSHOT_URL}"
            shift;;
        -i | --image) # Enter a base path
            ALEPH_IMAGE="$2"
            PULL_IMAGE=false
            shift 2;;
        --build_only)
            BUILD_ONLY=true
            shift;;
        --sync_from_genesis)
            SYNC=true
            shift;;
        -* | --* )
            echo "Warning: unrecognized option: $1"
            exit;; 
        *)
            echo "Unrecognized command"
            Help
            exit;;
  esac
done

ALEPH_VERSION=$(cat env/version)

if [ ! -d "${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}" ] && [ -d "${DB_SNAPSHOT_PATH}/keystore" ]
then
    echo "The default location of the data directory has changed."
    echo "Your files will be copied automatically to ${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}."
    echo "If you wish to customize the directory, select \'n\' and re-run the script"
    echo "with the \'--data_dir\' argument."
    echo "Do you want to continue? [y]/n"
    read -r CONT

    if [[ "$CONT" == 'n' ]]
    then
        echo "Please re-run the script, supplying the \'--data_dir\' argument, exiting."
        exit 0
    fi

    echo "Moving the data from ${DB_SNAPSHOT_PATH} into ${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}..."
    mkdir -p ${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}
    mv ${DB_SNAPSHOT_PATH}/* ${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}
fi

mkdir -p ${HOST_BASE_PATH}
DB_SNAPSHOT_PATH=${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}
mkdir -p ${DB_SNAPSHOT_PATH}

if [ ! -d "${DB_SNAPSHOT_PATH}/db/full" ] && [ -z "$SYNC" ]
then
    echo "Downloading the snapshot..."
    pushd ${DB_SNAPSHOT_PATH}
    wget -O ${DB_SNAPSHOT_FILE} ${DB_SNAPSHOT_URL}
    tar xvzf ${DB_SNAPSHOT_FILE}
    rm ${DB_SNAPSHOT_FILE}
    popd
fi

echo "Downloading the chainspec..."
pushd ${HOST_BASE_PATH}
wget -O ${CHAINSPEC_FILE} https://raw.githubusercontent.com/Cardinal-Cryptography/aleph-node/${ALEPH_VERSION}/bin/node/src/resources/${CHAINSPEC_FILE}
popd

if [ -z "$ALEPH_IMAGE" ]
then
    echo "Pulling docker image..."
    ALEPH_IMAGE=public.ecr.aws/p6e8q1z1/aleph-node:${ALEPH_VERSION}
    docker pull ${ALEPH_IMAGE}
fi

if [ -z "$BUILD_ONLY" ]
then
    echo "Running the node..."
    if [ -z "$ARCHIVIST" ]
    then
        source env/validator
        eval "echo \"$(cat env/validator)\"" > env/validator.env
        ENV_FILE="env/validator.env"
    else
        source env/archivist
        eval "echo \"$(cat env/archivist)\"" > env/archivist.env
        ENV_FILE="env/archivist.env"
    fi

    PORT_MAP="${PORT}:${PORT}"

    # remove the container if it exists
    if [ "$(docker ps -aq -f status=exited -f name=${NAME})" ]; then
        docker rm ${NAME}
    fi
    docker run --env-file ${ENV_FILE} \
               -p ${RPC_PORT_MAP} \
               -p ${WS_PORT_MAP} \
               -p ${PORT_MAP} \
               -p ${METRICS_PORT_MAP} \
               -u $(id -u):$(id -g) \
               --mount type=bind,source=${HOST_BASE_PATH},target=${BASE_PATH} \
               --name ${NAME} \
               -d ${ALEPH_IMAGE}
fi

