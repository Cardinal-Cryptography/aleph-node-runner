#!/bin/bash

set -eo pipefail

# for coloring the output
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BGREEN='\033[1;32m'
NC='\033[0m'

function error() {
    echo -e "\n${RED}$*${NC}"
    exit 1
}

function warn() {
    echo -e "\n${YELLOW}$*${NC}"
}

function info() {
    echo -e "${GREEN}$*${NC}"
}


Help()
{
    cat <<EOF
Run the aleph-node as either a validator or an archivist.
Syntax: $0 [--<name> <value>] [--<version> <value>] [--<archivist|mainnet|keep_containers|build_only|sync_from_genesis>] --ip|dns <value>

options:
archivist         Run the node as an archivist (the default is to run as a validator).
ip                The public IP of your node.
dns               The public DNS of your node.
n | name          Set the node's name.
d | data_dir      Specify the directory where all the chain data will be stored (default: ~/.alephzero).
mainnet           Join the mainnet (by default the script will join testnet).
keep_containers   Don't stop existing aleph-node containers.
version           Manually override the version to run (accepts a git tag or a short git commit hash).
build_only        Do not run after the setup.
database_engine   Pick a specific database engine, either paritydb or rocksdb. Defaults to the latter, unless it finds an existing instance of paritydb.
sync_from_genesis Perform a full sync instead of downloading the backup.
help              Print this help.

Example usage:
$0 --name my-aleph-node --ip 123.123.123.123
$0 --name my-aleph-node --dns some.domain --version r-12.1

EOF
}

prepare_directories() {
    mkdir -p "${HOST_BASE_PATH}"
    CHAIN_DATA_DIR=${HOST_BASE_PATH}/${CHAIN_DATA_DIR}
    mkdir -p "${CHAIN_DATA_DIR}"
}

get_version () {
    # In case of testnet and mainnet, we get the version by making the System::version RPC call.
    # The version that is returned by the extrinsic looks like: 0.11.4-ae34eb4213
    # so we take the hash part and use it to identify docker images and commits in the repo.

    echo -n "Getting the version...  "

    if [[ -n "${VERSION}" ]]
    then
        echo ""
        echo -e "Version manually set to ${BGREEN}${VERSION}${NC}."
        echo -e "Are you sure this is the correct version to run on ${BGREEN}${NETWORK}${NC}? [Y/n]"
        read -r CONT

        if [[ "$CONT" == 'n' ]]
        then
            echo "Exiting."
            exit 0
        fi

        ALEPH_VERSION="${VERSION}"
        info "OK"
        return
    fi

    VERSION_URL="https://rest.azero.dev/${NETWORK}-version"

    set +e    # we want to inspect the status of the wget command

    # get the version from this repo (but via wget instead of locally)
    ALEPH_VERSION=$(wget --quiet --output-document - ${VERSION_URL})
    if [[ 0 -ne $? ]]
    then
        error "Failed to reach the version endpoint.\nPlease re-run the script, passing the appropriate version with the --version option."
    fi

    set -e
    info "OK"
}

set_db_engine () {
    if [[ -z ${DB_ENGINE} ]]
    then
        if [[ -d "${CHAIN_DATA_DIR}/${PARITY_DB_PATH}" ]]
        then
         warn "You are running with paritydb as your database, we currently recommend rocksdb."
         echo "You can switch to rocksdb by adding '--database_engine rocksdb' to the arguments of this script. Note that it might take up to an hour to download a new DB snapshot and sync it."
         echo "If you explicitly prefer paritydb add '--database_engine paritydb' to the arguments of this script to silence this warning."
         DB_ENGINE="paritydb"
        else
         info "No database engine explicitly set, defaulting to rocksdb."
         DB_ENGINE="rocksdb"
        fi
    fi
    case "${DB_ENGINE}" in
        paritydb)
            DB_PATH="${PARITY_DB_PATH}"
            SNAPSHOT_NAME="latest-parity-pruned.html"
            ;;
        rocksdb)
            DB_PATH="${ROCKS_DB_PATH}"
            SNAPSHOT_NAME="latest-rocksdb-pruned.html"
            ;;
        *)
            error "Unknown DB engine: ${DB_ENGINE}."
            exit;;
    esac
}

get_snapshot () {
    set_db_engine

    if [[ ! -d "${CHAIN_DATA_DIR}/${DB_PATH}" && -z "$SYNC_FROM_GENESIS" ]]
    then
        echo "Downloading the snapshot...  "
        pushd "${CHAIN_DATA_DIR}" > /dev/null

        set +e
        wget -q --show-progress -O - "${DB_SNAPSHOT_URL}${SNAPSHOT_NAME}" | tar xzf -
        if [[ 0 -ne $? ]]
        then
            error "Failed to download and unpack the snapshot."
        fi
        set -e

        popd > /dev/null
        info "OK"
    fi
}

get_chainspec () {
    # For testnet and mainnet we get the chainspec from the repo (with the commit identified by the hash we get from System::version RPC call)
    echo "Downloading the chainspec...   "
    pushd "${HOST_BASE_PATH}" > /dev/null
    set +e
    wget --quiet --show-progress -O ${CHAINSPEC_FILE} https://raw.githubusercontent.com/Cardinal-Cryptography/aleph-node/"${ALEPH_VERSION}"/bin/node/src/resources/${CHAINSPEC_FILE}
    if [[ 0 -ne $? ]]
    then
        error "Failed to reach the chainspec endpoint."
    fi
    set -e
    popd > /dev/null
    info "OK"
}

get_docker_image () {
    echo -n "Pulling docker image...  "
    ALEPH_IMAGE=${ALEPH_IMAGE_NAME}:${ALEPH_VERSION}
    docker pull --quiet "${ALEPH_IMAGE}"
    if [[ 0 -ne $? ]]
    then
        error "Failed to pull the aleph-node docker image."
    fi

    info "OK"
}

shutdown_other_aleph_containers() {
    for image in $(docker image ls -q -f reference=${ALEPH_IMAGE_NAME}); do
        for container in $(docker ps -aq -f ancestor="${image}"); do

            # stop the container if it's running
            if [[ "$(docker ps -aq -f id="${container}")" && -z "$(docker ps -aq -f status=exited -f id="${container}")" ]]
            then
                echo -n "Stopping the container ${container}... "
                docker stop "${container}" > /dev/null
                info "OK"
            fi

            # remove the container if it exists
            if [[ "$(docker ps -aq -f status=exited -f id="${container}")" ]]
            then
                echo -n "Removing the container ${container}... "
                docker rm "${container}" > /dev/null
                info "OK"
            fi
        done
    done
}

run_validator () {
    source "env/validator_${NETWORK}"
    eval "echo \"$(cat env/validator_${NETWORK})\"" > "env/validator_${NETWORK}.env"
    ENV_FILE="env/validator_${NETWORK}.env"

    PROXY_PORT=${PROXY_PORT:-$PORT}
    PROXY_VALIDATOR_PORT=${PROXY_VALIDATOR_PORT:-$VALIDATOR_PORT}

    # setup public addresses
    PUBLIC_ADDR="/${ADDRESS_TYPE}/${NODE_ADDRESS}/tcp/${PROXY_PORT}"
    PUBLIC_VALIDATOR_ADDRESS="${NODE_ADDRESS}:${PROXY_VALIDATOR_PORT}"

    echo -e "Running with public P2P address: ${GREEN}${PUBLIC_ADDR}${NC}"
    echo -e "And validator address: ${GREEN}${PUBLIC_VALIDATOR_ADDRESS}${NC}"

    PORT_MAP="${PORT}:${PORT}"
    VALIDATOR_PORT_MAP="${VALIDATOR_PORT}":"${VALIDATOR_PORT}"

    docker run --env-file ${ENV_FILE} \
                --env PUBLIC_ADDR="${PUBLIC_ADDR}" \
                --env PUBLIC_VALIDATOR_ADDRESS="${PUBLIC_VALIDATOR_ADDRESS}" \
                -p "${PORT_MAP}" \
                -p "${VALIDATOR_PORT_MAP}" \
                -p "${RPC_PORT_MAP}" \
                -p "${METRICS_PORT_MAP}" \
                -u "$(id -u):$(id -g)" \
                --mount type=bind,source=${HOST_BASE_PATH},target=${BASE_PATH} \
                --name "${NAME}" \
                --restart unless-stopped \
                -d "${ALEPH_IMAGE}"
}

run_archivist () {
    source "env/archivist_${NETWORK}"
    eval "echo \"$(cat env/archivist_${NETWORK})\"" > "env/archivist_${NETWORK}.env"
    ENV_FILE="env/archivist_${NETWORK}.env"

    PROXY_PORT=${PROXY_PORT:-$PORT}
    PUBLIC_ADDR="/${ADDRESS_TYPE}/${NODE_ADDRESS}/tcp/${PROXY_PORT}"

    echo -e "Running with public P2P address: ${GREEN}${PUBLIC_ADDR}${NC}"

    PORT_MAP="${PORT}:${PORT}"

    docker run --env-file ${ENV_FILE} \
                --env PUBLIC_ADDR="${PUBLIC_ADDR}" \
                -p "${PORT_MAP}" \
                -p "${RPC_PORT_MAP}" \
                -p "${METRICS_PORT_MAP}" \
                -u "$(id -u):$(id -g)" \
                --mount type=bind,source=${HOST_BASE_PATH},target=${BASE_PATH} \
                --name "${NAME}" \
                --restart unless-stopped \
                -d "${ALEPH_IMAGE}"
}


# The defaults and other constants.
NAME="aleph-node-$(xxd -l "16" -p /dev/urandom | tr -d " \n" ; echo)"
NETWORK="testnet"
BASE_PATH="/data"
PARITY_DB_PATH="paritydb/full"
ROCKS_DB_PATH="db/full"
HOST_BASE_PATH="${HOME}/.alephzero"
DB_SNAPSHOT_URL=${DB_SNAPSHOT_URL:-"http://db.test.azero.dev.s3-website.eu-central-1.amazonaws.com/"}
MAINNET_DB_SNAPSHOT_URL=${MAINNET_DB_SNAPSHOT_URL:-"http://db.azero.dev.s3-website.eu-central-1.amazonaws.com/"}
CHAIN_DATA_DIR="chains/testnet"     # testnet by default
CHAINSPEC_FILE="testnet_chainspec.json"
ALEPH_IMAGE_NAME=public.ecr.aws/p6e8q1z1/aleph-node

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) # display Help
            Help
            exit;;
        --archivist) # Run as an archivist
            ARCHIVIST=true
            shift;;
        --ip)
            NODE_ADDRESS="$2"
            ADDRESS_TYPE="ip4"
            shift 2;;
        --dns)
            NODE_ADDRESS="$2"
            ADDRESS_TYPE="dns4"
            shift 2;;
        -n | --name) # Enter a name
            NAME="$2"
            shift 2;;
        -d | --data_dir) # Choose the data directory
            HOST_BASE_PATH="$2"
            shift 2;;
        --mainnet) # Join the mainnet
            CHAIN_DATA_DIR="chains/mainnet"
            CHAINSPEC_FILE="mainnet_chainspec.json"
            DB_SNAPSHOT_URL="${MAINNET_DB_SNAPSHOT_URL}"
            NETWORK="mainnet"
            shift;;
        --version) # Run a specific version of the binary
            VERSION="$2"
            shift 2;;
        --keep_containers) #) Don't stop or remove any containers
            KEEP_CONTAINERS=true
            shift;;
        --build_only)
            BUILD_ONLY=true
            shift;;
        --sync_from_genesis)
            SYNC_FROM_GENESIS=true
            shift;;
        --proxy_port)
            PROXY_PORT=$2
            shift 2;;
        --proxy_validator_port)
            PROXY_VALIDATOR_PORT=$2
            shift 2;;
        --database_engine)
            DB_ENGINE=$2
            shift 2;;
        -* )
            echo "Warning: unrecognized option: $1"
            exit;;
        *)
            echo "Unrecognized command"
            Help
            exit;;
  esac
done

if [[ -z "${NODE_ADDRESS}" ]]
then
    error "You need to provide either a public ip address of your node (--ip) or a public dns address of your node (--dns)."
fi

prepare_directories

get_version

get_snapshot

get_chainspec

get_docker_image

if [[ -z "$BUILD_ONLY" ]]
then
    if [[ -z "$KEEP_CONTAINERS" ]]
    then
        shutdown_other_aleph_containers
    fi

    echo "Running the container..."
    if [[ -z "$ARCHIVIST" ]]
    then
        run_validator

    else
        run_archivist
    fi
fi

echo ""
echo -e "${BGREEN}Launched the ${NETWORK} node!${NC}"
echo ""
echo "Please check if the node is running correctly by first running:"
info "  docker ps"
echo "And then, if the status is 'Up', inspect the logs by running:"
info "  docker logs ${NAME}"

if [[ -d "${CHAIN_DATA_DIR}/${PARITY_DB_PATH}" && -d "${CHAIN_DATA_DIR}/${ROCKS_DB_PATH}" ]]
then
    echo ""
				warn "You have two copies of the database on your filesystem."
    echo "You can remove the old (unnecessary) database by running:"
    if [[ "${DB_ENGINE}" == "paritydb" ]]
    then
        info "  rm -rf ${CHAIN_DATA_DIR}/${ROCKS_DB_PATH}"
    else
        info "  rm -rf ${CHAIN_DATA_DIR}/${PARITY_DB_PATH}"
    fi
fi
