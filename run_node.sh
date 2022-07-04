#!/bin/bash

set -eo pipefail

Help()
{
    echo "Run the aleph-node as either a validator or an archivist."
    echo "Syntax: ./run_node.sh [--<name|image|container_name>=<value> [--<archivist|mainnet|build_only|sync_from_genesis>]"
    echo
    echo "options:"
    echo "archivist         Run the node as an archivist (the default is to run as a validator)"
    echo "n | name          Set the node's name."
    echo "mainnet           Join the mainnet (by default the script will join testnet)."
    echo "i | image         Specify the Docker image to use"
    echo "build_only        Do not run after the setup."
    echo "container_name    The name of the Docker container that will be run."
    echo "sync_from_genesis Perform a full sync instead of downloading the backup."
    echo "help              Print this help."
    echo
    echo "Example usage:"
    echo "./run_node.sh --name=my-aleph-node --mainnet --release=r-6.0"
    echo
    echo "or, shorter:"
    echo "./run_node.sh --n my-aleph-node --mainnet --r r-6.0"
    echo
}


# The defaults
NAME="aleph-node-$(xxd -l "16" -p /dev/urandom | tr -d " \n" ; echo)"
BASE_PATH="/data"
ALEPH_VERSION="r-6.0"
DATE=$(date -d "yesterday" '+%Y-%m-%d')  # yesterday's date to make sure the snapshot is already uploaded (it happens once a day)
DB_SNAPSHOT_FILE="db_backup_${DATE}.tar.gz"
DB_SNAPSHOT_URL="https://db.test.azero.dev/${DATE}/${DB_SNAPSHOT_FILE}"
MAINNET_DB_SNAPSHOT_URL_BASE="https://db-chain-exchange-bucket.s3.ap-northeast-1.amazonaws.com/${DATE}/"
DB_SNAPSHOT_PATH="chains/testnet/"     # testnet by default
CHAINSPEC_FILE="testnet_chainspec.json"
CONTAINER_NAME="aleph-node"


while getopts n:i:r:-: OPT; do
    if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
        OPT="${OPTARG%%=*}"       # extract long option name
        OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
        OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
    fi
    echo ""
    case "$OPT" in
        help) # display Help
            Help
            exit;;
        archivist) # Run as an archivist
            ARCHIVIST=true;;
        n | name) # Enter a name
            NAME=$OPTARG;;
        mainnet) # Join the mainnet
            DB_SNAPSHOT_PATH="chains/mainnet/"
            CHAINSPEC_FILE="mainnet_chainspec.json"
            DB_SNAPSHOT_FILE="db_chain_backup.tar.gz"
            DB_SNAPSHOT_URL="${MAINNET_DB_SNAPSHOT_URL_BASE}/${DB_SNAPSHOT_FILE}";;
        i | image) # Enter a base path
            ALEPH_IMAGE=$OPTARG
            PULL_IMAGE=false;;
        build_only)
            BUILD_ONLY=true;;
        sync_from_genesis)
            SYNC=true;;
        container_name)
            CONTAINER_NAME=$OPTARG;;
        *) # Invalid option
            echo "Error: Invalid option"
            Help
            exit;;
  esac
done

if [ -z "$EXECUTE_ONLY" ]
then
    mkdir -p ${DB_SNAPSHOT_PATH}

    if [ ! -d "${DB_SNAPSHOT_PATH}/db/full" ] & [ -z "$SYNC" ]
    then
        echo "Downloading the snapshot..."
        pushd ${DB_SNAPSHOT_PATH}
        wget ${DB_SNAPSHOT_URL}
        tar xvzf ${DB_SNAPSHOT_FILE}
        rm ${DB_SNAPSHOT_FILE}
        popd
    fi

    if [ ! -f ${CHAINSPEC_FILE} ]
    then
        echo "Downloading the chainspec..."
        wget -O ${CHAINSPEC_FILE} https://raw.githubusercontent.com/Cardinal-Cryptography/aleph-node/main/bin/node/src/resources/${CHAINSPEC_FILE}
    fi
fi

if [ -z "$ALEPH_IMAGE" ]
then
    echo "Pulling docker image..."
    ALEPH_VERSION=$(cat env/version)
    ALEPH_IMAGE=public.ecr.aws/p6e8q1z1/aleph-node:${ALEPH_VERSION}
    docker pull ${ALEPH_IMAGE}
fi

if [ -z "$BUILD_ONLY" ]
then
    echo "Running the node..."
    if [ -z "$ARCHIVIST" ]
    then
        source env/validator
        RPC_PORT_MAP="127.0.0.1:${RPC_PORT}:${RPC_PORT}"
        WS_PORT_MAP="127.0.0.1:${WS_PORT}:${WS_PORT}"
        eval "echo \"$(cat env/validator)\"" > env/validator.env
        ENV_FILE="env/validator.env"
    else
        source env/archivist
        RPC_PORT_MAP="${RPC_PORT}:${RPC_PORT}"
        WS_PORT_MAP="${WS_PORT}:${WS_PORT}"
        eval "echo \"$(cat env/archivist)\"" > env/archivist.env
        ENV_FILE="env/archivist.env"
    fi

    PORT_MAP="${PORT}:${PORT}"

    # remove the container if it exists
    if [ "$(docker ps -aq -f status=exited -f name=${CONTAINER_NAME})" ]; then
        docker rm ${CONTAINER_NAME}
    fi
    docker run --env-file ${ENV_FILE} -p ${RPC_PORT_MAP} -p ${WS_PORT_MAP} -p ${PORT_MAP} -u $(id -u):$(id -g) --mount type=bind,source=$(pwd),target=${BASE_PATH} --name ${CONTAINER_NAME} -d ${ALEPH_IMAGE}
fi

