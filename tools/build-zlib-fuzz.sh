#!/bin/sh
# Builds a static zlib with the fuzzing sanitizers for tools/libfuzz.sh, so that the coverage
# reaches into inflate and deflate:
#   tools/build-zlib-fuzz.sh [PREFIX]
# Without PREFIX it goes to deps/zlib-fuzz in this repository (libfuzz.sh looks there). Needs
# curl, tar with xz, clang (CLANG, default clang or clang-18) and sha256sum. The normal build of
# the library uses the system zlib (-lz) and is not touched by this.
set -eu
VERSION=1.3.1
SHA256=38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32
root=$(cd "$(dirname "$0")/.." && pwd)
prefix=${1:-$root/deps/zlib-fuzz}
case $prefix in /*) ;; *) prefix=$(pwd)/$prefix ;; esac
CC=${CLANG:-$(command -v clang || command -v clang-18)}
export CC
export CFLAGS="-O1 -g -fPIC -fsanitize=fuzzer-no-link,address,undefined -fno-sanitize=function"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
tarball=zlib-$VERSION.tar.xz
curl -fsSLO "https://github.com/madler/zlib/releases/download/v$VERSION/$tarball"
echo "$SHA256  $tarball" | sha256sum -c - >/dev/null || { echo "$tarball: wrong checksum" >&2; exit 1; }
tar xf "$tarball"
cd "zlib-$VERSION"
{ ./configure --static --prefix="$prefix" && make -j"$(nproc)" && make install; } \
  >"$work/build.log" 2>&1 ||
  { cat "$work/build.log" >&2; echo "building zlib $VERSION failed" >&2; exit 1; }
echo "zlib $VERSION installed in $prefix"
