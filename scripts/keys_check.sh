echo ""
echo 'Performing session key checks...'

source ./env/validator

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
CLIAIN_ENDPOINT='wss://ws.test.azero.dev/'
JQ_IMAGE='stedolan/jq:latest'

# Pull cliain from ecr
docker pull "${CLIAIN_IMAGE}"

# Try to retrieve set session keys from chain's storage
if ! SESSION_KEYS_JSON=$(docker run --network="host" "${CLIAIN_IMAGE}" --node "${CLIAIN_ENDPOINT}" \
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

    read -p "Do you want to generate new session keys? [y/N] " -n 1 -r
    if [[ ${REPLY} =~ ^[Yy]$ ]]
    then
        echo ""
        echo "Generating new session keys..."
        NEW_KEYS_JSON=$(curl -H "Content-Type: application/json" -d '{"id":1,
            "jsonrpc":"2.0", "method": "author_rotateKeys"}' http://127.0.0.1:"${RPC_PORT}")

        NEW_KEYS=$(echo ${NEW_KEYS_JSON} | docker run -i "${JQ_IMAGE}" '.result' | tr -d '"')
        echo "New session keys: ${NEW_KEYS}"

        echo "Now, you should set those newly generated keys for your stash account."
        echo "You may do it your preferred way, eg. using web wallet, or set them now by providing mnemonic seed to your stash account."
        read -p "Do you want to set your keys using mnemonic seed for ${STASH_ACCOUNT}? [y/N] " -n 1 -r
        echo
        if [[ ${REPLY} =~ ^[Yy]$ ]]
        then
            # Try to set, tell if the operation was successful
            if docker run -it --network="host" ${CLIAIN_IMAGE} --node "${CLIAIN_ENDPOINT}" \
                set-keys --new-keys "${NEW_KEYS}";
            then
                echo ""
                echo "Session keys succesfully set."
            else
                echo ""
                echo "Set keys failed. You will need to set them manualy."
                exit 1
            fi
        fi
    fi
fi

exit 0
