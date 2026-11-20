#!/bin/sh
# Builds the static mbedTLS that the prototype TLS backend links (-d:tlsMbed, src/nimgrpc/tls/gtls_mbed.c):
#   tools/build-mbedtls.sh [PREFIX]
# Without PREFIX it goes to deps/mbedtls in this repository, where config.nims finds it, so no
# root is needed. Needs curl, tar with bzip2, cmake, python3, a C compiler and sha256sum.
# The checksum is the one published with the release (mbedtls-4.3.0-sha256sum.txt); it comes from
# the same place as the archive, so it finds a damaged download, not a replaced release.
set -eu
VERSION=4.3.0
SHA256=1c87cba094cb40f097ebe0eba440a74939b71dab4e1d0d566bc90749ff381d18
root=$(cd "$(dirname "$0")/.." && pwd)
prefix=${1:-$root/deps/mbedtls}
case $prefix in /*) ;; *) prefix=$(pwd)/$prefix ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
tarball=mbedtls-$VERSION.tar.bz2
curl -fsSLO "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$VERSION/$tarball"
echo "$SHA256  $tarball" | sha256sum -c - >/dev/null || { echo "$tarball: wrong checksum" >&2; exit 1; }
tar xf "$tarball"
cd "mbedtls-$VERSION"
# The library is used from several threads: mbedTLS's PSA layer needs its threading support for that.
python3 tf-psa-crypto/scripts/config.py -f tf-psa-crypto/include/psa/crypto_config.h set MBEDTLS_THREADING_C
python3 tf-psa-crypto/scripts/config.py -f tf-psa-crypto/include/psa/crypto_config.h set MBEDTLS_THREADING_PTHREAD
# cmake's output is kept in a file and shown only when a step fails
{ cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$prefix" &&
  cmake --build build -j && cmake --install build; } >"$work/build.log" 2>&1 ||
  { cat "$work/build.log" >&2; echo "building mbedTLS $VERSION failed" >&2; exit 1; }
echo "mbedTLS $VERSION installed in $prefix"
