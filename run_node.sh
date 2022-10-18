#!/bin/bash

set -eo pipefail


./scripts/update.sh

./scripts/run_node.sh "$@"

