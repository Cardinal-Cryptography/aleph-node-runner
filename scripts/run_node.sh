#!/bin/bash

set -eo pipefail

Help()
{
    echo "Run the aleph-node as either a validator or an archivist."
    echo "Syntax: ./run_node.sh [--<name|image|stash_account> <value>] [--<archivist|mainnet|build_only|sync_from_genesis>]"
    echo
    echo "options:"
    echo "archivist         Run the node as an archivist (the default is to run as a validator)"
    echo "ip                The public IP of your node."
    echo "dns               The public DNS of your node."
    echo "stash_account     Stash account of your validator: optional but recommended, if you're re-running the script."
    echo "n | name          Set the node's name."
    echo "d | data_dir      Specify the directory where all the chain data will be stored (default: ~/.alephzero)."
    echo "mainnet           Join the mainnet (by default the script will join testnet)."
    echo "i | image         Specify the Docker image to use"
    echo "build_only        Do not run after the setup."
    echo "sync_from_genesis Perform a full sync instead of downloading the backup."
    echo "help              Print this help."
    echo
    echo "Example usage:"
    echo "./run_node.sh --name my-aleph-node --stash_account 5CeeD3MGHCvZecJkvfJVzYvYkoPtw9pTVvskutXAUtZtjcYa"
    echo
    echo "or, shorter:"
    echo "./run_node.sh --n my-aleph-node --stash_account 5CeeD3MGHCvZecJkvfJVzYvYkoPtw9pTVvskutXAUtZtjcYa"
    echo
}


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
        --ip)
            PUBLIC_IP="$2"
            shift 2;;
        --dns)
            PUBLIC_DNS="$2"
            shift 2;;
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
            CLIAIN_ENDPOINT='wss://ws.azero.dev:443'
            MAINNET=true
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
        --proxy_port)
            PROXY_PORT=$2
            shift 2;;
        --proxy_validator_port)
            PROXY_VALIDATOR_PORT=$2
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

if [ -z "${PUBLIC_IP}" ] && [ -z "${PUBLIC_DNS}" ]
then
    echo "You need to provide either a public ip address of your node (--ip) or a public dns address of your node (--dns)."
    exit 1
fi

if  [ -n "${MAINNET}" ]
then
    ALEPH_VERSION=$(cat env/version_mainnet)
else
    ALEPH_VERSION=$(cat env/version)
fi

if [ ! -d "${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}" ] && [ -d "${DB_SNAPSHOT_PATH}/keystore" ]
then
    echo "The default location of the data directory has changed."
    echo "Your files will be copied automatically to ${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}."
    echo "If you wish to customize the directory, select 'n' and re-run the script"
    echo "with the '--data_dir' argument."
    echo "Do you want to continue? [Y/n]"
    read -r CONT

    if [[ "$CONT" == 'n' ]]
    then
        echo "Please re-run the script, supplying the '--data_dir' argument, exiting."
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

    # remove the container if it exists
    if [ "$(docker ps -aq -f status=exited -f name=${NAME})" ]; then
        docker rm ${NAME}
    fi

    if [ -z "$ARCHIVIST" ]
    then
        ###### VALIDATOR ######
        if [ -n "$MAINNET" ]
        then
            source env/validator_mainnet
            eval "echo \"$(cat env/validator_mainnet)\"" > env/validator_mainnet.env
            ENV_FILE="env/validator_mainnet.env"
        else
            source env/validator
            eval "echo \"$(cat env/validator)\"" > env/validator.env
            ENV_FILE="env/validator.env"
        fi

        PROXY_PORT=${PROXY_PORT:-$PORT}
        PROXY_VALIDATOR_PORT=${PROXY_VALIDATOR_PORT:-$VALIDATOR_PORT}

        # setup public addresses
        if [[ -n "${PUBLIC_DNS}" ]]
        then
            PUBLIC_ADDR="/dns4/${PUBLIC_DNS}/tcp/${PROXY_PORT}"
            PUBLIC_VALIDATOR_ADDRESS="${PUBLIC_DNS}:${PROXY_VALIDATOR_PORT}"
        else
            PUBLIC_ADDR="/ip4/${PUBLIC_IP}/tcp/${PROXY_PORT}"
            PUBLIC_VALIDATOR_ADDRESS="${PUBLIC_IP}:${PROXY_VALIDATOR_PORT}"
        fi

        echo "Running with public P2P address: ${PUBLIC_ADDR}"
        echo "And validator address: ${PUBLIC_VALIDATOR_ADDRESS}"

        PORT_MAP="${PORT}:${PORT}"
        VALIDATOR_PORT_MAP="${VALIDATOR_PORT}":"${VALIDATOR_PORT}"

        docker run --env-file ${ENV_FILE} \
                   --env PUBLIC_ADDR="${PUBLIC_ADDR}" \
                   --env PUBLIC_VALIDATOR_ADDRESS="${PUBLIC_VALIDATOR_ADDRESS}" \
                   -p ${RPC_PORT_MAP} \
                   -p ${WS_PORT_MAP} \
                   -p ${PORT_MAP} \
                   -p ${VALIDATOR_PORT_MAP} \
                   -p ${METRICS_PORT_MAP} \
                   -u $(id -u):$(id -g) \
                   --mount type=bind,source=${HOST_BASE_PATH},target=${BASE_PATH} \
                   --name ${NAME} \
                   --restart unless-stopped \
                   -d ${ALEPH_IMAGE}

    else
        ###### ARCHIVIST #######
        if [ -n "$MAINNET" ]
        then
            source env/archivist_mainnet
            eval "echo \"$(cat env/archivist_mainnet)\"" > env/archivist_mainnet.env
            ENV_FILE="env/archivist_mainnet.env"
        else
            source env/archivist
            eval "echo \"$(cat env/archivist)\"" > env/archivist.env
            ENV_FILE="env/archivist.env"
        fi


        PROXY_PORT=${PROXY_PORT:-$PORT}

        if [[ -n "${PUBLIC_DNS}" ]]
        then
            PUBLIC_ADDR="/dns4/${PUBLIC_DNS}/tcp/${PROXY_PORT}"
        else
            PUBLIC_ADDR="/ip4/${PUBLIC_IP}/tcp/${PROXY_PORT}"
        fi

        echo "Running with public P2P address: ${PUBLIC_ADDR}"

        PORT_MAP="${PORT}:${PORT}"

        docker run --env-file ${ENV_FILE} \
                   --env PUBLIC_ADDR="${PUBLIC_ADDR}" \
                   -p ${RPC_PORT_MAP} \
                   -p ${WS_PORT_MAP} \
                   -p ${PORT_MAP} \
                   -p ${METRICS_PORT_MAP} \
                   -u $(id -u):$(id -g) \
                   --mount type=bind,source=${HOST_BASE_PATH},target=${BASE_PATH} \
                   --name ${NAME} \
                   --restart unless-stopped \
                   -d ${ALEPH_IMAGE}
    fi
fi

if [[ -n "${ARCHIVIST}" ]]
then
    echo 'Node run as archivist: no need to check session keys.'
    exit 0
fi

echo ""
echo 'Performing session key checks...'

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
CLIAIN_IMAGE='public.ecr.aws/p6e8q1z1/cliain:latest'
CLIAIN_ENDPOINT=${CLIAIN_ENDPOINT:-'wss://ws.test.azero.dev:443'}
JQ_IMAGE='stedolan/jq:latest'

# Pull cliain from ecr
docker pull "${CLIAIN_IMAGE}"

# Try to retrieve set session keys from chain's storage
CLIAIN_NAME="cliain-$(xxd -l "16" -p /dev/urandom | tr -d " \n" ; echo)"
if ! SESSION_KEYS_JSON=$(docker run --name="${CLIAIN_NAME}" "${CLIAIN_IMAGE}" --node "${CLIAIN_ENDPOINT}" \
    next-session-keys --account-id "${STASH_ACCOUNT}" 2> /dev/null);
then
    # This should not happen even if the keys are not set
    echo "Cliain failed when trying to retrieve keys for this stash account. Logs:"
    docker logs "${CLIAIN_NAME}"
    docker rm "${CLIAIN_NAME}"
    exit 0
fi

docker rm "${CLIAIN_NAME}"

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
    echo "Check https://docs.alephzero.org/aleph-zero/validate/troubleshooting#generating-your-session-keys for details"
fi

exit 0
