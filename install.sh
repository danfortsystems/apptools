#!/bin/sh

# One-liner installer for apptools
# Usage: curl -sSL https://gist.githubusercontent.com/yourusername/yourgistid/raw/install.sh | sh

set -eu

# Temporary directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "Installing apptools..."

# Clone repository
cd "$TEMP_DIR"
git clone git@github.com:danfortsystems/apptools.git

# Run deploy script
cd apptools
# chmod +x _deploy
bash _deploy

echo "Apptools installed successfully!"
echo "You can now use the apptools 'project [build | test | serve | dev | deploy]' command from the root a target project"
