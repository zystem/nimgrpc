#!/bin/bash
# Builds tools/hostiletarget (release) and runs tools/hostile.py against the blocking and the
# chronos server. Exit status 1 if an attack stops a server or makes it grow past its bound.
#   tools/hostile.sh [ATTACK ...]
# Environment: NIMFLAGS (e.g. -d:nghttp2Prefix=$HOME/.local/nghttp2), PORT (default 47100).
set -u
cd "$(dirname "$0")/.."
BIN=${HOSTILE_BIN:-/tmp/hostiletarget}
PORT=${PORT:-47100}
nim c -d:release --hints:off --mm:orc --panics:on --path:src --nimcache:nimcache/hostile \
  ${NIMFLAGS:-} -o:"$BIN" tools/hostiletarget.nim || exit 2
status=0
for mode in blocking async; do
  echo "== $mode server"
  "$BIN" "$mode" "$PORT" > /dev/null 2>&1 &
  pid=$!
  sleep 1
  python3 tools/hostile.py "$PORT" "$pid" "$@" || status=1
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  PORT=$((PORT + 1))
done
exit $status
