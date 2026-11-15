#!/bin/sh
# Usage: tools/release.sh <AddonName>     (the folder name, e.g. GaarBagsForever)
# Reads ## Version from addons/<AddonName>/<AddonName>.toc, then creates and pushes the tag
# <AddonName>-v<version>. The push triggers .github/workflows/release-addon.yml, which also zips
# the addon's settings bridge (tools/curseforge-config.json "bridges") while there is one.
set -e
[ $# -eq 1 ] || { echo "usage: $0 <AddonName>"; exit 1; }
name="$1"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
toc="$REPO/addons/$name/$name.toc"
[ -f "$toc" ] || { echo "no such addon: $toc"; exit 1; }
version="$(sed -n 's/^## Version: *//p' "$toc" | head -1 | tr -d '\r ')"
[ -n "$version" ] || { echo "no ## Version in $toc"; exit 1; }
tag="$name-v$version"
cd "$REPO"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "HEAD is not origin/main; release from an up-to-date main"; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "tag $tag already exists"; exit 1; }
prev="$(git tag --list "$name-v*" --sort=-v:refname | head -1)"
old="$(jq -r --arg n "$name" '.bridges[$n] // empty' "$REPO/tools/curseforge-config.json" 2>/dev/null || true)"
# The first Gaar...Forever release follows the last Better...Forever tag.
[ -z "$prev" ] && [ -n "$old" ] && prev="$(git tag --list "$old-v*" --sort=-v:refname | head -1)"
notes="$(git log --no-merges --format='- %s' ${prev:+$prev..}HEAD -- "addons/$name" ${old:+"addons/$old"} | head -30)"
git tag -a "$tag" -m "$name $version

$notes"
git push origin "$tag"
echo "pushed $tag"
