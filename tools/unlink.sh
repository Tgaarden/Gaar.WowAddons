#!/bin/sh
# Remove the symlinks this repo's link.sh made. Only ever removes links, never real folders.
set -e

FLAVOR="${1:-_classic_era_}"
WOW="${WOW_PATH:-/Applications/World of Warcraft}"
TARGET="$WOW/$FLAVOR/Interface/AddOns"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

for dir in "$REPO"/addons/*/; do
    name=$(basename "$dir")
    dest="$TARGET/$name"
    if [ -L "$dest" ]; then
        rm "$dest"
        echo "  unlinked $name"
        if [ -d "$dest.before-link" ]; then
            mv "$dest.before-link" "$dest"
            echo "    restored the folder that was there first"
        fi
    fi
done
