#!/bin/bash

set -eo pipefail

Help()
{
    echo "Run the aleph-node as either a validator or an archivist."
    echo "Syntax: ./run_node.sh [--<name|image|stash_account> <value>] [--<archivist|mainnet|build_only|sync_from_genesis>]"
    echo
    echo "options:"
    echo "archivist         Run the node as an archivist (the default is to run as a validator)."
    echo "stash_account     Stash account of your validator: optional but recommended, if you're re-running the script."
    echo "n | name          Set the node's name."
    echo "mainnet           Join the mainnet (by default the script will join testnet)."
    echo "i | image         Specify the Docker image to use"
    echo "build_only        Do not run after the setup."
    echo "sync_from_genesis Perform a full sync instead of downloading the backup."
    echo "help              Print this help."
    echo
    echo "Example usage:"
    echo "./run_node.sh --name my-aleph-node --mainnet --stash_account 5CeeD3MGHCvZecJkvfJVzYvYkoPtw9pTVvskutXAUtZtjcYa"
    echo
    echo "or, shorter:"
    echo "./run_node.sh --n my-aleph-node --mainnet --stash_account 5CeeD3MGHCvZecJkvfJVzYvYkoPtw9pTVvskutXAUtZtjcYa"
    echo
}

echo "Updating this repo..."
git pull origin main
echo "Done"


# The defaults
NAME="aleph-node-$(xxd -l "16" -p /dev/urandom | tr -d " \n" ; echo)"
BASE_PATH="/data"
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
        --stash_account)
            STASH_ACCOUNT=$2
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

ALEPH_VERSION=$(cat env/version)

mkdir -p ${DB_SNAPSHOT_PATH}

if [ ! -d "${DB_SNAPSHOT_PATH}/db/full" ] && [ -z "${SYNC}" ]
then
    echo "Downloading the snapshot..."
    pushd ${DB_SNAPSHOT_PATH}
    wget -O ${DB_SNAPSHOT_FILE} ${DB_SNAPSHOT_URL}
    tar xvzf ${DB_SNAPSHOT_FILE}
    rm ${DB_SNAPSHOT_FILE}
    popd
fi

echo "Downloading the chainspec..."
wget -O ${CHAINSPEC_FILE} https://raw.githubusercontent.com/Cardinal-Cryptography/aleph-node/${ALEPH_VERSION}/bin/node/src/resources/${CHAINSPEC_FILE}

if [ -z "${ALEPH_IMAGE}" ]
then
    echo "Pulling docker image..."
    ALEPH_IMAGE=public.ecr.aws/p6e8q1z1/aleph-node:${ALEPH_VERSION}
    docker pull ${ALEPH_IMAGE}
fi

if [ -z "${BUILD_ONLY}" ]
then
    echo "Running the node..."
    if [ -z "${ARCHIVIST}" ]
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
               --mount type=bind,source=$(pwd),target=${BASE_PATH} \
               --name ${NAME} \
               --restart unless-stopped \
               -d ${ALEPH_IMAGE}
fi

echo 'Performing session key checks...'

if [[ -n "${ARCHIVIST}" ]]
then
    echo 'Node run as archivist: no need to check session keys.'
    exit 0
fi

if [[ -z "${STASH_ACCOUNT}" ]]
then
    echo "Stash account not provided. This is ok if you're running the script for the first time but recommended for subsequent runs."
    read -p "Are you sure you want to skip the session keys check? [y/N]" -r -n 1
    echo ""

    if [[ "${REPLY}" =~ ^[Yy] ]]
    then
        echo "Skipping the session keys check."
        exit 0
    fi

    read -p "Please provide your stash account: " -r STASH_ACCOUNT
fi

## Now we will attempt to check validator's session keys
CLIAIN_IMAGE='public.ecr.aws/p6e8q1z1/cliain:f0688f5'
JQ_IMAGE='stedolan/jq:latest'

# Pull cliain from ecr
docker pull "${CLIAIN_IMAGE}"

# Try to retrieve set session keys from chain's storage
if ! SESSION_KEYS_JSON=$(docker run --network="host" "${CLIAIN_IMAGE}" --node 127.0.0.1:"${WS_PORT}" \
    next-session-keys --account-id "${STASH_ACCOUNT}" 2> '/tmp/.alephzero_cliain.log');
then
    # This should not happen even if the keys are not set
    echo "Cliain failed when trying to retrieve keys for this stash account. Logs:"
    cat "/tmp/.alephzero_cliain.log"
fi

# Check if there are any session keys set for the specified stash account
if [[ -n "${SESSION_KEYS_JSON}" ]]
then
    # Check the external jq image
    docker image inspect "${JQ_IMAGE}" > /dev/null && echo "JQ image check: OK"
    # Read keys from the JSON
    AURA_KEY=$(echo "${SESSION_KEYS_JSON}" | docker run -i "${JQ_IMAGE}" '.aura' | tr -d '"')
    ALEPH_KEY=$(echo "${SESSION_KEYS_JSON}" | docker run -i "${JQ_IMAGE}" '.aleph' | tr -d '"')

    # Format keys into string notation
    ALEPH_KEY_TRUNCATED="${ALEPH_KEY#"0x"}"
    SESSION_KEYS_STRING="${AURA_KEY}${ALEPH_KEY_TRUNCATED}"

    # Perform an RPC call to the local node to check whether it has access to the keys
    HAS_KEYS_RESULT_JSON=$(curl -H "Content-Type: application/json" \
        -d '{"id":1, "jsonrpc":"2.0", "method": "author_hasSessionKeys",
            "params":["'"${SESSION_KEYS_STRING}"'"]}' http://127.0.0.1:"${RPC_PORT}" 2> /dev/null)

    HAS_KEYS_RESULT=$(echo "${HAS_KEYS_RESULT_JSON}" | docker run -i "${JQ_IMAGE}" '.result')

    if [[ "${HAS_KEYS_RESULT}" == false ]]
    then
        # If the keys are not present, then we stop the node and print the message
        # (the node would not be able to validate properly anyway)

        RED='\033[0;31m'
        NC='\033[0m'

        >&2 echo -e "${RED}"
        >&2 echo "Session keys are set for this stash account, but it seems like you do not have access to them."
        >&2 echo "You might want to generate new keys and set them for your stash account."
        >&2 echo "Stopping the node..."
        >&2 echo -e "${NC}"

        # Stop the node
        docker stop "${NAME}"
        exit 1
    fi
else
    echo ""
    echo "Specified account do not have any session keys set."
    echo "You should generate and set the keys to be able to validate."
fi

exit 0
