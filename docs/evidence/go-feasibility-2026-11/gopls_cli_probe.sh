#!/bin/bash
# usage: [ENV=..] p2.sh <proj> <cache> "<gopls args>"...   (extra env passed through)
set -u
PROJ="$(cd "$1" && pwd -P)"; CACHE="$2"; shift 2
rm -rf "$CACHE"; mkdir -p "$CACHE/tmp"; CACHE="$(cd "$CACHE" && pwd -P)"
PROFILE="(version 1)(deny default)(import \"system.sb\")(allow file-read*)(allow process*)(allow file-write* (subpath \"$CACHE\") (literal \"/dev/null\"))(deny network*)"
export TMPDIR="$CACHE/tmp" XDG_CACHE_HOME="$CACHE" GOCACHE="$CACHE/go-build" GOPLSCACHE="$CACHE/gopls" GOPROXY=off
[ -n "${EMPTY_MODCACHE:-}" ] && { mkdir -p "$CACHE/emptymod"; export GOMODCACHE="$CACHE/emptymod"; }
cd "$PROJ"
for cmd in "$@"; do
  echo "--- gopls $cmd"; t0=$(date +%s)
  /usr/bin/sandbox-exec -p "$PROFILE" /bin/sh -c 'ulimit -S -v "$1" || exit 125; shift; exec "$@"' rl 536870912 "$(command -v gopls)" $cmd 2>&1 | sed "s#$PROJ/##g" | cut -c1-260 | head -8
  echo "    [exit ${PIPESTATUS[0]}, $(( $(date +%s) - t0 ))s]"
done
