#!/bin/sh
# Point a WoW client's AddOns folder at this repo, so editing here is editing what the game
# loads. Takes the client folder name, e.g. _classic_era_ or _retail_.
set -e

FLAVOR="${1:-_classic_era_}"
WOW="${WOW_PATH:-/Applications/World of Warcraft}"
TARGET="$WOW/$FLAVOR/Interface/AddOns"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

[ -d "$TARGET" ] || { echo "No AddOns folder at: $TARGET"; exit 1; }

for dir in "$REPO"/addons/*/; do
    name=$(basename "$dir")
    dest="$TARGET/$name"
    if [ -L "$dest" ]; then
        rm "$dest"
    elif [ -e "$dest" ]; then
        # A real folder is somebody's actual addon. Move it aside rather than destroy it.
        mv "$dest" "$dest.before-link"
        echo "  kept existing $name as $name.before-link"
    fi
    ln -s "$dir" "$dest"
    echo "  linked $name"
done

echo "Linked into $FLAVOR. Log out to character select so the client rescans."
