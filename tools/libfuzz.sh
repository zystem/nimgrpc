#!/bin/bash
# Build the coverage-guided fuzzer (libFuzzer, needs clang) for one target and run it.
#   tools/libfuzz.sh TARGET [SECONDS]      TARGET: frames gzip everything legacy wkt h2server h2client tlsserver tlsclient
# Environment: OUT (default fuzz-out: the corpus, and a crash-* file when there is a finding),
# CLANG (default: clang, else clang-18), NIMFLAGS (for example -d:nghttp2Prefix=...).
# The fuzzer links an nghttp2 built with the sanitizers when deps/nghttp2-fuzz exists (make it with
# FUZZ=1 tools/build-nghttp2.sh; FUZZ_NGHTTP2 gives another prefix, "none" turns it off), so the
# coverage reaches into nghttp2; without it nghttp2 is linked as built and only our code is seen.
# The same for zlib: deps/zlib-fuzz, made by tools/build-zlib-fuzz.sh (FUZZ_ZLIB, "none").
# The corpus in OUT/corpus-TARGET grows between runs; keep it between runs to go further.
# Exit status is not 0 when libFuzzer found something.
set -eu
TARGET=${1:?usage: tools/libfuzz.sh TARGET [SECONDS]}
SECS=${2:-60}
OUT=${OUT:-fuzz-out}
CLANG=${CLANG:-$(command -v clang || command -v clang-18)}
BIN=${FUZZ_BIN:-/tmp/libfuzz-$TARGET}
SAN=fuzzer-no-link,address,undefined
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NGF=${FUZZ_NGHTTP2:-$ROOT/deps/nghttp2-fuzz}
FUZZFLAGS=
ZF=${FUZZ_ZLIB:-$ROOT/deps/zlib-fuzz}
if [ "$ZF" != none ] && [ -f "$ZF/lib/libz.a" ]; then FUZZFLAGS="$FUZZFLAGS -d:zlibStatic -d:zlibLib=$ZF/lib/libz.a"; fi
if [ "$NGF" != none ] && [ -f "$NGF/lib/libnghttp2.a" ]; then FUZZFLAGS="$FUZZFLAGS -d:nghttp2Prefix=$NGF"; fi
nim c -d:useMalloc --debugger:native --hints:off --cc:clang --noMain:on \
  --clang.exe:"$CLANG" --clang.linkerexe:"$CLANG" -d:fuzzTarget="$TARGET" \
  --passC:"-fsanitize=$SAN -fno-sanitize=function" --passL:"-fsanitize=fuzzer,address,undefined" \
  --nimcache:nimcache/libfuzz-"$TARGET" ${NIMFLAGS:-} $FUZZFLAGS -o:"$BIN" tools/libfuzz.nim
SEEDS=$(mktemp -d)
trap 'rm -rf "$SEEDS"' EXIT
nim c -d:release --hints:off --nimcache:nimcache/fuzzseeds ${NIMFLAGS:-} -o:/tmp/fuzzseeds tools/fuzz.nim
/tmp/fuzzseeds seeds "$TARGET" "$SEEDS"
mkdir -p "$OUT/corpus-$TARGET"
exec "$BIN" "$OUT/corpus-$TARGET" "$SEEDS" -max_total_time="$SECS" -max_len=65536 -timeout=10 \
  -artifact_prefix="$OUT/" -print_final_stats=1
