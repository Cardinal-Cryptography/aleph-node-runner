#!/bin/bash

set -eo pipefail

Help()
{
    echo "Run the aleph-node as either a validator or an archivist."
    echo "Syntax: ./run_node.sh [--<name|image|stash_account> <value>] [--<archivist|mainnet|build_only|sync_from_genesis>]"
    echo
    echo "options:"
    echo "archivist         Run the node as an archivist (the default is to run as a validator)"
    echo "stash_account     Stash account of your validator: optional but recommended, if you're re-running the script."
    echo "n | name          Set the node's name."
    echo "d | data_dir      Specify the directory where all the chain data will be stored (default: ~/.alephzero)."
    echo "mainnet           Join the mainnet (by default the script will join testnet)."
    echo "i | image         Specify the Docker image to use"
    echo "build_only        Do not run after the setup."
    echo "sync_from_genesis Perform a full sync instead of downloading the backup."
    echo "no_prompts        Auto-select the default value in all cases instead of prompting."
    echo "help              Print this help."
    echo
    echo "Example usage:"
    echo "./run_node.sh --name my-aleph-node --mainnet --stash_account 5CeeD3MGHCvZecJkvfJVzYvYkoPtw9pTVvskutXAUtZtjcYa"
    echo
    echo "or, shorter:"
    echo "./run_node.sh --n my-aleph-node --mainnet --stash_account 5CeeD3MGHCvZecJkvfJVzYvYkoPtw9pTVvskutXAUtZtjcYa"
    echo
}




# The defaults
export NAME="aleph-node-$(xxd -l "16" -p /dev/urandom | tr -d " \n" ; echo)"
export BASE_PATH="/data"
export HOST_BASE_PATH="${HOME}/.alephzero"
export DB_SNAPSHOT_FILE="db_backup.tar.gz"
export DB_SNAPSHOT_URL="https://db.test.azero.dev/latest.html"
export MAINNET_DB_SNAPSHOT_URL="https://db.azero.dev/latest.html"
export DB_SNAPSHOT_PATH="chains/testnet/"     # testnet by default
export CHAINSPEC_FILE="testnet_chainspec.json"
export PROMPTS=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) # display Help
            Help
            exit;;
        --archivist) # Run as an archivist
            export ARCHIVIST=true
            shift;;
        -n | --name) # Enter a name
            export NAME="$2"
            shift 2;;
        -d | --data_dir) # Choose the data directory
            export HOST_BASE_PATH="$2"
            shift 2;;
        --mainnet) # Join the mainnet
            export DB_SNAPSHOT_PATH="chains/mainnet/"
            export CHAINSPEC_FILE="mainnet_chainspec.json"
            export DB_SNAPSHOT_URL="${MAINNET_DB_SNAPSHOT_URL}"
            shift;;
        -i | --image) # Enter a base path
            export ALEPH_IMAGE="$2"
            export PULL_IMAGE=false
            shift 2;;
        --build_only)
            export BUILD_ONLY=true
            shift;;
        --sync_from_genesis)
            export SYNC=true
            shift;;
        --stash_account)
            export STASH_ACCOUNT=$2
            shift 2;;
        --no_prompts)
            export PROMPTS=false
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

./scripts/update.sh

./scripts/run_node.sh "$@"

