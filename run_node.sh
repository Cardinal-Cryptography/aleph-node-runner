#!/bin/bash

Help()
{
    echo "Run the aleph-node as either a validator or an archivist."
    echo
    echo "Syntax: run_node.sh [-a|n|m||i|b|h]"
    echo "options:"
    echo "a | archivist   Run the node as an archivist (the default is to run as a validator)"
    echo "n | name        Set the node's name."
    echo "m | mainnet     Join the mainnet (by default the script will join testnet)."
    echo "i | image       Specify the Docker image to use"
    echo "r | release     Set the version/release tag to use."
    echo "b | build_only  Do not run after the setup."
    echo "s | sync        Perform a full sync instead of downloading the backup"
    echo "h | help     Print this Help."
    echo
    echo "Example usage:"
    echo "./run_node.sh --name my-aleph-node --mainnet --release r-5.1"
    echo
    echo "or, shorter:"
    echo "./run_node.sh --n my-aleph-node -m --r r-5.1"
    echo
}


# The defaults
NAME="aleph-node-$(whoami)"
BASE_PATH="/data"
ALEPH_VERSION="r-5.2"
DATE=$(date -d "yesterday" '+%Y-%m-%d')  # yesterday's date to make sure the snapshot is already uploaded (it happens once a day)
DB_SNAPSHOT_FILE="db_backup_${DATE}.tar.gz"
DB_SNAPSHOT_URL="https://db.test.azero.dev/${DATE}/${DB_SNAPSHOT_FILE}"
MAINNET_DB_SNAPSHOT_URL_BASE="https://db-chain-exchange-bucket.s3.ap-northeast-1.amazonaws.com/${DATE}/"
DB_SNAPSHOT_PATH="chains/testnet/"     # testnet by default
CHAINSPEC_FILE="testnet_chainspec.json"


while getopts h:n:m:p:i:r:b:-: OPT; do
    if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
        OPT="${OPTARG%%=*}"       # extract long option name
        OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
        OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
    fi
    echo ""
    case "$OPT" in
        h | help) # display Help
            Help
            exit;;
        a | archivist) # Run as an archivist
            ARCHIVIST=true;;
        n | name) # Enter a name
            NAME=$OPTARG;;
        m | mainnet) # Join the mainnet
            DB_SNAPSHOT_PATH="chains/mainnet/"
            CHAINSPEC_FILE="mainnet_chainspec.json"
            DB_SNAPSHOT_FILE="db_chain_backup.tar.gz"
            DB_SNAPSHOT_URL="${MAINNET_DB_SNAPSHOT_URL_BASE}/${DB_SNAPSHOT_FILE}";;
        i | image) # Enter a base path
            ALEPH_IMAGE=$OPTARG
            PULL_IMAGE=false;;
        r | release) # Enter a release
            ALEPH_VERSION=$OPTARG;;
        b | build_only)
            BUILD_ONLY=true;;
        s | sync)
            SYNC=true;;
        *) # Invalid option
            echo "Error: Invalid option"
            Help
            exit;;
  esac
done

if [ -z "$ARCHIVIST" ]
then
    eval "echo \"$(cat env/validator)\"" > env/validator.env
    ENV_FILE="./env/validator.env"
else
    eval "echo \"$(cat env/archivist)\"" > env/archivist.env
    ENV_FILE="./env/archivist.env"
fi

mkdir -p ${DB_SNAPSHOT_PATH}

if [ ! -f ${DB_SNAPSHOT_PATH}/${DB_SNAPSHOT_FILE} ] && [ -z "$SYNC" ]
then
    echo "Downloading the snapshot..."
    pushd ${DB_SNAPSHOT_PATH}
    wget ${DB_SNAPSHOT_URL}
    tar xvzf ${DB_SNAPSHOT_FILE}
    popd
fi

if [ ! -f chainspec.json ]
then
    echo "Downloading the chainspec..."
    wget -O chainspec.json https://raw.githubusercontent.com/Cardinal-Cryptography/aleph-node/main/bin/node/src/resources/${CHAINSPEC_FILE}
fi

if [ -z "$ALEPH_IMAGE" ]
then
    echo "Pulling docker image..."
    ALEPH_IMAGE=public.ecr.aws/p6e8q1z1/aleph-node:${ALEPH_VERSION}
    docker pull ${ALEPH_IMAGE}
fi

if [ -z "$BUILD_ONLY" ]
then
    echo "Running the node..."
    docker run --env-file ${ENV_FILE} -p 9933:9933 -p 9944:9944 -p 30333:30333  --mount type=bind,source=$(pwd),target=/data ${ALEPH_IMAGE}
fi

