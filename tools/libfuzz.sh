#!/bin/bash
# Build the coverage-guided fuzzer (libFuzzer, needs clang) for one target and run it.
#   tools/libfuzz.sh TARGET [SECONDS]      TARGET: frames gzip everything legacy wkt h2server h2client tlsserver tlsclient
# Environment: OUT (default fuzz-out: the corpus, and a crash-* file when there is a finding),
# CLANG (default: clang, else clang-18), NIMFLAGS (for example -d:nghttp2Prefix=...).
# The corpus in OUT/corpus-TARGET grows between runs; keep it between runs to go further.
# Exit status is not 0 when libFuzzer found something.
set -eu
TARGET=${1:?usage: tools/libfuzz.sh TARGET [SECONDS]}
SECS=${2:-60}
OUT=${OUT:-fuzz-out}
CLANG=${CLANG:-$(command -v clang || command -v clang-18)}
BIN=${FUZZ_BIN:-/tmp/libfuzz-$TARGET}
SAN=fuzzer-no-link,address,undefined
nim c -d:useMalloc --debugger:native --hints:off --cc:clang --noMain:on \
  --clang.exe:"$CLANG" --clang.linkerexe:"$CLANG" -d:fuzzTarget="$TARGET" \
  --passC:"-fsanitize=$SAN" --passL:"-fsanitize=fuzzer,address,undefined" \
  --nimcache:nimcache/libfuzz-"$TARGET" ${NIMFLAGS:-} -o:"$BIN" tools/libfuzz.nim
SEEDS=$(mktemp -d)
trap 'rm -rf "$SEEDS"' EXIT
nim c -d:release --hints:off --nimcache:nimcache/fuzzseeds ${NIMFLAGS:-} -o:/tmp/fuzzseeds tools/fuzz.nim
/tmp/fuzzseeds seeds "$TARGET" "$SEEDS"
mkdir -p "$OUT/corpus-$TARGET"
exec "$BIN" "$OUT/corpus-$TARGET" "$SEEDS" -max_total_time="$SECS" -max_len=65536 -timeout=10 \
  -artifact_prefix="$OUT/" -print_final_stats=1
