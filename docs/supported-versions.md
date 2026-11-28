# Supported versions

What the library is built and run with. "Run" means the test suite passed there; anything
else is marked "not run". `tests/tdocs.nim` compares the figures marked ✔ with
`nimgrpc.nimble`, the CI workflow and the source.

## The library

| Version | State |
|---|---|
| 0.9.0 ✔ (the latest release) and the head of `main` | supported: fixes are made here |
| earlier releases | not supported: update ([upgrading.md](upgrading.md)) |

A release is supported until the next one is made; there is no long-term line
([../SECURITY.md](../SECURITY.md)). While the version is 0.x, a change of behaviour raises
the second number and a fix the third ([releasing.md](releasing.md)).

## What it needs

| Part | Required | Run with | Notes |
|---|---|---|---|
| Nim | 2.2.12 ✔ or later | 2.2.12, 2.2.14, 2.4.0 ✔ in CI on every pull request | `--mm:orc`; [nim-compiler-notes.md](nim-compiler-notes.md) for 2.2.12 and 2.2.14 |
| nghttp2 | 1.61.0 ✔ or later (an older header fails the build) | 1.71.0 ✔ in CI | linked statically; 1.68.1 or later has the fix of CVE-2026-27135 |
| bearssl (nimble) | 0.3.1 ✔ or later | 0.3.1 | BearSSL itself is compiled from the package's source |
| chronos (nimble) | 4.0.4 ✔ or later | 4.4.1 | only for the chronos API |
| zlib | the system's (`-lz`), or `-d:zlibStatic` | 1.3 (Ubuntu 24.04's package) | |
| C compiler | gcc | gcc 13.3 | clang: not run |
| protoc | 3.x or later, only to generate code | 3.21.12 | |

The lowest versions of bearssl and chronos that `nimgrpc.nimble` allows are not run in CI:
nimble installs the newest.

## Where it runs

| Platform | State |
|---|---|
| Linux x86-64, glibc | run: CI (GitHub's `ubuntu-latest`) on every pull request; Linux Mint 22.3, kernel 6.8, on 2026-11-15 |
| Linux x86-64, musl, static | run by hand, client only ([static-build.md](static-build.md)) |
| Linux on arm64 | the test suite in CI on every pull request (Ubuntu 24.04, Nim 2.4.0; nim-lang.org has no arm64 binary, CI uses [one built from the release source](https://github.com/zystem/Nim/releases/tag/arm64-nim-2.4.0)); the sanitizers, the soak and the benchmarks: not run |
| Linux on other CPUs | not run |
| macOS, the BSDs | not run |
| Windows | not run; the blocking adapter uses POSIX calls |

## What it speaks

| Protocol | State |
|---|---|
| gRPC over HTTP/2, plaintext (h2c, prior knowledge) and TLS | run: 18 interop cases against grpc-go v1.76.0 ([interop.md](interop.md)); h2spec 135 of 146 ([h2spec.md](h2spec.md)) |
| TLS | 1.2 only, ALPN `h2` required; 1.3: no |
| Compression | gzip and identity |
| Health checking `grpc.health.v1`, reflection `v1` and `v1alpha` | run against grpcurl (`tools/conformance.sh`) |
| gRPC-Web, HTTP/1.1 | no |
