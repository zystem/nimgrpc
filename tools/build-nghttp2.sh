#!/bin/sh
# Builds the static nghttp2 the library links, the same way as docs/building.md and the CI:
#   tools/build-nghttp2.sh [PREFIX]
# Without PREFIX it goes to deps/nghttp2 in this repository, where config.nims finds it, so no
# root is needed and nothing outside the repository changes. Needs curl, tar with xz, cmake,
# a C compiler and sha256sum.
set -eu
VERSION=1.71.0
SHA256=c0f55121d88650e4b9227aec28cebaf664d2417ca60fe70be0f8d38829f52116
root=$(cd "$(dirname "$0")/.." && pwd)
prefix=${1:-$root/deps/nghttp2}
case $prefix in /*) ;; *) prefix=$(pwd)/$prefix ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
tarball=nghttp2-$VERSION.tar.xz
curl -fsSLO "https://github.com/nghttp2/nghttp2/releases/download/v$VERSION/$tarball"
echo "$SHA256  $tarball" | sha256sum -c - >/dev/null || { echo "$tarball: wrong checksum" >&2; exit 1; }
tar xf "$tarball"
cd "nghttp2-$VERSION"
# cmake's output is kept in a file and shown only when a step fails
{ cmake -S . -B build -DENABLE_LIB_ONLY=ON -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$prefix" &&
  cmake --build build -j && cmake --install build; } >"$work/build.log" 2>&1 ||
  { cat "$work/build.log" >&2; echo "building nghttp2 $VERSION failed" >&2; exit 1; }
echo "nghttp2 $VERSION installed in $prefix"
