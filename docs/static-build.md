# Static build with musl

A fully static client: no libc, OpenSSL or zlib needed on the target. For
example a binary dropped into a container image it does not control.

## Measured (2026-11-01, x86-64)

`examples/static_client.nim` does mTLS with keepalive, one gzip-compressed
unary call and one client-streaming call, through code generated from the
interop protos.

| Build | Size |
|:---|---:|
| static, musl 1.2.5, `-d:release --opt:size`, stripped | 707 KB |
| the same, packed with `upx --best --lzma` | 286 KB |
| dynamic glibc build of a minimal TLS client, stripped | ~600 KB |

The static binary has an RSS of 1.1 MiB after its calls, against 2.9 MiB for
the glibc build. The packed binary runs the same.

## Recipe

musl, zlib and nghttp2 are built from source once:

```sh
# musl (any mirror of git.musl-libc.org; v1.2.5 used here)
git clone --depth 1 --branch v1.2.5 https://github.com/ifduyue/musl
(cd musl && ./configure --prefix=/opt/musl --disable-shared && make -j && make install)
export CC=/opt/musl/bin/musl-gcc

# zlib
git clone --depth 1 --branch v1.3.1 https://github.com/madler/zlib
(cd zlib && ./configure --static --prefix=/opt/musl-deps && make -j && make install)

# nghttp2
tar xf nghttp2-1.71.0.tar.xz && cd nghttp2-1.71.0
cmake -S . -B build -DCMAKE_C_COMPILER=$CC -DENABLE_LIB_ONLY=ON \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_INSTALL_PREFIX=/opt/musl-deps
cmake --build build -j && cmake --install build
```

Then the program (BearSSL is compiled from source by nim-bearssl):

```sh
nim c -d:release --opt:size \
  --cc:gcc --gcc.exe:/opt/musl/bin/musl-gcc --gcc.linkerexe:/opt/musl/bin/musl-gcc \
  --passC:-I/opt/musl-deps/include --passL:-static \
  -d:nghttp2Prefix=/opt/musl-deps \
  -d:zlibStatic -d:zlibLib=/opt/musl-deps/lib/libz.a \
  -o:client examples/static_client.nim
strip client
upx --best --lzma client      # optional
```

DNS: musl's resolver reads `/etc/resolv.conf` and `/etc/hosts` and needs no
NSS modules, so name resolution works in a bare container.
