#!/bin/bash
# Remove generated config files (contain secrets).
# Does NOT touch Docker volumes or backups.
set -e
cd "$(dirname "$0")"

rm -f compose.yml garage.toml
echo "Cleaned generated files. Run ./setup.sh to regenerate."
