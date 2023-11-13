#!/bin/bash

set -eo pipefail

# for coloring the output
RED='\033[0;31m'
GREEN='\033[0;32m'
BGREEN='\033[1;32m'
NC='\033[0m'

Help()
{
    cat <<EOF
Run the aleph-node as either a validator or an archivist.
Syntax: $0 [--<name|stash_account> <value>] [--<archivist|mainnet|build_only|sync_from_genesis>] --ip|dns <value>

options:
archivist         Run the node as an archivist (the default is to run as a validator).
ip                The public IP of your node.
dns               The public DNS of your node.
n | name          Set the node's name.
d | data_dir      Specify the directory where all the chain data will be stored (default: ~/.alephzero).
mainnet           Join the mainnet (by default the script will join testnet).
version           Manually override the version to run (accepts a git tag or a short git commit hash).
build_only        Do not run after the setup.
sync_from_genesis Perform a full sync instead of downloading the backup.
help              Print this help.

Example usage:
$0 --name my-aleph-node --ip 123.123.123.123

EOF
}

get_version () {
    # In case of testnet and mainnet, we get the version by making the System::version RPC call.
    # The version that is returned by the extrinsic looks like: 0.11.4-ae34eb4213
    # so we take the hash part and use it to identify docker images and commits in the repo.

    if [ -n "${VERSION}" ]
    then
        ALEPH_VERSION="${VERSION}"
        return
    fi

    if  [ -n "${MAINNET}" ]
    then
        VERSION_RPC_URL="https://rpc.azero.dev"
    else
        VERSION_RPC_URL="https://rpc.test.azero.dev"
    fi

    set +e    # we want to inspect the status of the curl command

    # call the RPC endpoint to get the version
    VERSION_INFO=$(curl -s -H "Content-Type: application/json" -d '{"id":1, "jsonrpc":"2.0", "method": "system_version"}' ${VERSION_RPC_URL})
    if [ 0 -ne $? ]
    then
        echo -e "${RED}Failed to reach the version endpoint.${NC}"
        echo "Please re-run the script, passing the appropriate version with the --version option."
        exit 2
    fi

    set -e

    # use jq to parse the resulting json, get the value of the version field and strip quotes
    VERSION_INFO=$(echo "${VERSION_INFO}" | docker run --quiet -i "${JQ_IMAGE}" '.result' | tr -d '"')
    # only return the commit hash that comes after a '-'
    ALEPH_VERSION=${VERSION_INFO##*-}
}

check_default_dir () {
    # Since at some point we moved the data directory out of the repo, we check if the target path exists and,
    # if necessary, move existing data.
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
            echo -e "${RED}Please re-run the script, supplying the '--data_dir' argument, exiting.${NC}"
            exit 0
        fi

        echo "Moving the data from ${DB_SNAPSHOT_PATH} into ${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}..."
        mkdir -p "${HOST_BASE_PATH}"/${DB_SNAPSHOT_PATH}
        mv ${DB_SNAPSHOT_PATH}/* "${HOST_BASE_PATH}"/${DB_SNAPSHOT_PATH}
        echo -e "${GREEN}Finished moving the data.${NC}"
    fi
}

get_snapshot () {
    # If the snapshot doesn't exist, we download it from the specified path.
    mkdir -p "${HOST_BASE_PATH}"
    DB_SNAPSHOT_PATH=${HOST_BASE_PATH}/${DB_SNAPSHOT_PATH}
    mkdir -p "${DB_SNAPSHOT_PATH}"

    if [ ! -d "${DB_SNAPSHOT_PATH}/db/full" ] && [ -z "$SYNC" ]
    then
        echo "Downloading the snapshot..."
        pushd "${DB_SNAPSHOT_PATH}" > /dev/null
        wget -q -O ${DB_SNAPSHOT_FILE} ${DB_SNAPSHOT_URL}
        tar xvzf ${DB_SNAPSHOT_FILE}
        rm ${DB_SNAPSHOT_FILE}
        popd > /dev/null
    fi
}

get_chainspec () {
    # For testnet and mainnet we get the chainspec from the repo (with the commit identified by the hash we get from System::version RPC call)
    echo "Downloading the chainspec..."
    pushd "${HOST_BASE_PATH}" > /dev/null
    wget -q -O ${CHAINSPEC_FILE} https://raw.githubusercontent.com/Cardinal-Cryptography/aleph-node/"${ALEPH_VERSION}"/bin/node/src/resources/${CHAINSPEC_FILE}
    popd > /dev/null
}

get_docker_image () {
    echo "Pulling docker image..."
    ALEPH_IMAGE=public.ecr.aws/p6e8q1z1/aleph-node:${ALEPH_VERSION:0:7}
    docker pull --quiet "${ALEPH_IMAGE}"
}

run_validator () {
    if [ -n "${MAINNET}" ]
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

    echo -e "Running with public P2P address: ${GREEN}${PUBLIC_ADDR}${NC}"
    echo -e "And validator address: ${GREEN}${PUBLIC_VALIDATOR_ADDRESS}${NC}"

    PORT_MAP="${PORT}:${PORT}"
    VALIDATOR_PORT_MAP="${VALIDATOR_PORT}":"${VALIDATOR_PORT}"

    # we store the port mapping arguments in an array
    # this allows us to append the WS_PORT_MAP argument only for Mainnet
    PORT_ARGS=(-p "${PORT_MAP}" -p "${VALIDATOR_PORT_MAP}" -p "${RPC_PORT_MAP}" -p "${METRICS_PORT_MAP}")
    [[ -n "${MAINNET}" ]] && PORT_ARGS+=(-p "${WS_PORT_MAP}")

    docker run --env-file ${ENV_FILE} \
                --env PUBLIC_ADDR="${PUBLIC_ADDR}" \
                --env PUBLIC_VALIDATOR_ADDRESS="${PUBLIC_VALIDATOR_ADDRESS}" \
                "${PORT_ARGS[@]}" \
                -u "$(id -u):$(id -g)" \
                --mount type=bind,source=${HOST_BASE_PATH},target=${BASE_PATH} \
                --name "${NAME}" \
                --restart unless-stopped \
                -d "${ALEPH_IMAGE}"
}

run_archivist () {
    if [ -n "${MAINNET}" ] && [ "${MAINNET}" = 'true' ]
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

    echo -e "Running with public P2P address: ${GREEN}${PUBLIC_ADDR}${NC}"

    PORT_MAP="${PORT}:${PORT}"

    # we store the port mapping arguments in an array
    # this allows us to append the WS_PORT_MAP argument only for Mainnet
    PORT_ARGS=(-p "${PORT_MAP}" -p "${RPC_PORT_MAP}" -p "${METRICS_PORT_MAP}")
    [[ -n "${MAINNET}" ]] && PORT_ARGS+=(-p "${WS_PORT_MAP}")

    docker run --env-file ${ENV_FILE} \
                --env PUBLIC_ADDR="${PUBLIC_ADDR}" \
                "${PORT_ARGS[@]}" \
                -u "$(id -u):$(id -g)" \
                --mount type=bind,source=${HOST_BASE_PATH},target=${BASE_PATH} \
                --name "${NAME}" \
                --restart unless-stopped \
                -d "${ALEPH_IMAGE}"
}


# The defaults
NAME="aleph-node-$(xxd -l "16" -p /dev/urandom | tr -d " \n" ; echo)"
BASE_PATH="/data"
HOST_BASE_PATH="${HOME}/.alephzero"
DB_SNAPSHOT_FILE="db_backup.tar.gz"
DB_SNAPSHOT_URL="http://db.test.azero.dev.s3-website.eu-central-1.amazonaws.com/latest.html"
MAINNET_DB_SNAPSHOT_URL="http://db.azero.dev.s3-website.eu-central-1.amazonaws.com/latest.html"
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
            MAINNET=true
            shift;;
        --version) # Run a specific version of the binary
            VERSION="$2"
            shift 2;;
        --build_only)
            BUILD_ONLY=true
            shift;;
        --sync_from_genesis)
            SYNC=true
            shift;;
        --proxy_port)
            PROXY_PORT=$2
            shift 2;;
        --proxy_validator_port)
            PROXY_VALIDATOR_PORT=$2
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

if [ -z "${PUBLIC_IP}" ] && [ -z "${PUBLIC_DNS}" ]
then
    echo -e "${RED}You need to provide either a public ip address of your node (--ip) or a public dns address of your node (--dns).${NC}"
    exit 3
fi

### Figure out the version to run
# Check the external jq image
JQ_IMAGE='stedolan/jq:latest'
docker image inspect "${JQ_IMAGE}" > /dev/null && echo -e "JQ image check: ${GREEN}OK${NC}"

get_version

check_default_dir

get_snapshot

get_chainspec

get_docker_image

if [ -z "$BUILD_ONLY" ]
then
    echo ""
    echo "Running the node..."

    # remove the container if it exists
    if [ "$(docker ps -aq -f status=exited -f name="${NAME}")" ]; then
        docker rm "${NAME}"
    fi

    if [ -z "$ARCHIVIST" ]
    then
        run_validator

    else
        run_archivist
    fi
fi

echo ""
echo -e "${BGREEN}Launched the node!${NC}"
echo ""
echo "Please check if the node is running correctly by first running:"
echo -e "  ${GREEN}docker ps${NC}"
echo "And then, if the status is 'Up', inspect the logs by running:"
echo -e "  ${GREEN}docker logs ${NAME}${NC}"
