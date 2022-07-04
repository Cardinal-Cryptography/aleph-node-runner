#!/bin/bash

set -eo pipefail

echo "Fetching the latest version of this repo..."
git pull origin main
echo "Done!"

