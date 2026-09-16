#!/bin/sh
# Two checks, both worth running before a commit.
#
# 1. Syntax, with LuaJIT - Lua 5.1, the dialect the game runs.
# 2. Scope. A local used above its own declaration is silently resolved as a global, which is
#    nil at runtime; the parser is perfectly happy with it. This reads the bytecode and lists
#    every global each file touches, so a helper of your own appearing there is the tell.
set -e

LUAJIT="${LUAJIT:-luajit}"
command -v "$LUAJIT" >/dev/null || { echo "luajit not found (brew install luajit)"; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/addons"

fail=0
for f in */*.lua; do
    if ! "$LUAJIT" -bl "$f" /dev/null 2>/dev/null; then
        echo "SYNTAX  $f"
        "$LUAJIT" -bl "$f" /dev/null 2>&1 | head -3
        fail=1
    fi
done
[ "$fail" -eq 0 ] && echo "syntax: all files parse"

echo
echo "globals touched per file - anything here should be a real WoW API, a Lua builtin,"
echo "or a Gaar* global this suite exports on purpose:"
for f in */*.lua; do
    echo "--- $f"
    "$LUAJIT" -bl "$f" 2>&1 \
      | awk '/^[0-9]+ *(=>)? *G(GET|SET)/ { if (match($0, /; "[^"]+"/)) print substr($0, RSTART+3, RLENGTH-4) }' \
      | sort -u | tr '\n' ' '
    echo
done

exit $fail
