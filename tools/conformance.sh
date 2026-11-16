#!/bin/bash
# What other people's tools say about the servers: h2spec against both HTTP/2 adapters, and
# grpcurl (a real client of server reflection) against tools/hostiletarget.
#   tools/conformance.sh
# Needs h2spec 2.6.0 and grpcurl on PATH (.github/workflows/hostile.yml shows how CI builds
# them). Environment: NIMFLAGS, PORT.
set -u
for tool in h2spec grpcurl; do
  command -v "$tool" > /dev/null || { echo "$tool is not on PATH" >&2; exit 2; }
done
cd "$(dirname "$0")/.."
PORT=${PORT:-47200}
OUT=${OUT:-conformance-out}
mkdir -p "$OUT"
build() { nim c -d:release --hints:off --mm:orc --panics:on --path:src --nimcache:"nimcache/$1" ${NIMFLAGS:-} -o:"/tmp/$1" "tools/$1.nim" || exit 2; }
build h2specserver; build h2specasync; build hostiletarget
status=0

# Both servers wait 100 ms before each answer, so that the stray frame h2spec sends after a
# request is there before the answer closes the stream (docs/h2spec.md).
for pair in "blocking h2specserver 100" "async h2specasync 100"; do
  set -- $pair
  echo "== h2spec, $1 adapter"
  "/tmp/$2" "$PORT" ${3:-} > /dev/null 2>&1 &
  pid=$!
  sleep 1
  h2spec -h 127.0.0.1 -p "$PORT" -o 2 -j "$OUT/h2spec-$1.xml" > "$OUT/h2spec-$1.txt" 2>&1
  tail -n 3 "$OUT/h2spec-$1.txt"
  python3 tools/h2spec_check.py "$OUT/h2spec-$1.xml" "$1" || status=1
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  PORT=$((PORT + 1))
done

for mode in blocking async; do
  echo "== grpcurl, $mode server"
  /tmp/hostiletarget "$mode" "$PORT" > /dev/null 2>&1 &
  pid=$!
  sleep 1
  list=$(grpcurl -plaintext "127.0.0.1:$PORT" list 2>&1)
  echo "$list"
  for want in grpc.health.v1.Health grpc.reflection.v1.ServerReflection t.T; do
    echo "$list" | grep -qx "$want" || { echo "grpcurl list: $want is missing"; status=1; }
  done
  desc=$(grpcurl -plaintext "127.0.0.1:$PORT" describe google.protobuf.Timestamp 2>&1)
  echo "$desc" | grep -q "int64 seconds" || { echo "grpcurl describe google.protobuf.Timestamp: $desc"; status=1; }
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  PORT=$((PORT + 1))
done
exit $status
