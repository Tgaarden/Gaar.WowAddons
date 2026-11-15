#!/bin/sh
# Usage: tools/curseforge-upload.sh <AddonName> <zip> <changelog-file>
# Env: CF_API_KEY. Skips (exit 0, with a notice) when the key or the project ID is missing.
set -e
name="$1"; zip="$2"; notes="$3"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pid="$(jq -r --arg n "$name" '.[$n] // empty' "$REPO/tools/curseforge-projects.json")"
if [ -z "$pid" ]; then echo "::notice::$name has no CurseForge project ID in tools/curseforge-projects.json; skipping CurseForge."; exit 0; fi
if [ -z "$CF_API_KEY" ]; then echo "::notice::Secret CF_API_KEY is not set; skipping CurseForge."; exit 0; fi

cfg="$REPO/tools/curseforge-config.json"
api="https://wow.curseforge.com/api"
ids="$(jq -c '.gameVersionIds' "$cfg")"
if [ "$ids" = "[]" ]; then
  names="$(jq -c '.gameVersionNames' "$cfg")"
  all="$(curl -fsS -H "X-Api-Token: $CF_API_KEY" "$api/game/versions")"
  ids="$(echo "$all" | jq -c --argjson n "$names" '[.[] | select(.name as $x | $n | index($x)) | .id]')"
  if [ "$ids" = "[]" ] || [ "$(echo "$ids" | jq length)" != "$(echo "$names" | jq length)" ]; then
    echo "::error::Could not resolve game versions $names. Set gameVersionIds in tools/curseforge-config.json. Candidates (id name type):"
    echo "$all" | jq -r '.[] | "\(.id)\t\(.name)\t\(.gameVersionTypeID)"' | tail -60
    exit 1
  fi
fi

meta="$(jq -n --argjson gv "$ids" --rawfile cl "$notes" '{changelog:$cl, changelogType:"markdown", displayName:null, gameVersions:$gv, releaseType:"release"}' | jq 'del(.displayName)')"
dep_addon="$(jq -r '.requiredDependencyAddon' "$cfg")"; slug="$(jq -r '.requiredDependencySlug // empty' "$cfg")"
if [ -n "$slug" ] && grep -qE "^## Dependencies:.*\b$dep_addon\b" "$REPO/addons/$name/$name.toc"; then
  meta="$(echo "$meta" | jq --arg s "$slug" '.relations={projects:[{slug:$s,type:"requiredDependency"}]}')"
fi
echo "Uploading $zip to CurseForge project $pid with metadata:"; echo "$meta" | jq -c 'del(.changelog)'
out="$(mktemp)"
code="$(curl -sS -o "$out" -w '%{http_code}' -X POST -H "X-Api-Token: $CF_API_KEY" --form-string "metadata=$meta" -F "file=@$zip" "$api/projects/$pid/upload-file")"
cat "$out"; echo
case "$code" in 2*) ;; *) echo "::error::CurseForge upload failed: HTTP $code"; exit 1;; esac
