# Building, testing and dependencies

## Build

Requirements: Nim 2.2.12 or later (tested on 2.2.12 and 2.2.14), a C compiler, [nim-bearssl](https://github.com/status-im/nim-bearssl) (`nimble install bearssl`; BearSSL is compiled from source), zlib (`-lz`, or `-d:zlibStatic`), nghttp2 1.61.0 or later (1.57 limits the Rapid Reset attack, CVE-2023-44487; 1.61 limits CONTINUATION frames, the CONTINUATION flood, CVE-2024-28182; the build fails with an `#error` if the header is older) linked statically, and [chronos](https://github.com/status-im/nim-chronos) for the async API.

```sh
git clone https://github.com/zystem/nimgrpc && cd nimgrpc
nimble install -y --depsOnly
# nghttp2, once (the same steps as the CI, .github/workflows/ci.yml):
curl -LO https://github.com/nghttp2/nghttp2/releases/download/v1.68.0/nghttp2-1.68.0.tar.xz
tar xf nghttp2-1.68.0.tar.xz && cd nghttp2-1.68.0
cmake -S . -B build -DENABLE_LIB_ONLY=ON -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_STATIC_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=/opt/nghttp2
cmake --build build -j && cmake --install build
cd .. && nimble test
```

A different prefix is passed with `-d:nghttp2Prefix=/path`. The README has the variant without nimble (`NIM_BEARSSL`, `NIM_PATHS`) and the footprint figures; a static musl build is in [static-build.md](static-build.md).

## Tests

`nimble lint` runs the compiler's style check as an error and warnings as failures over the library, the plugin, the tests and the tools (add compiler flags in `NIMGRPC_FLAGS`, for example `-d:nghttp2Prefix=/path`). `nimble test` runs every test file (`nimgrpc.nimble` lists them); `nimble asan` and `nimble tsan` run the same under the sanitizers. ThreadSanitizer needs a smaller address-space randomisation on recent Linux kernels (it stops with "unexpected memory mapping"): `sudo sysctl vm.mmap_rnd_bits=28`, or run a test binary as `setarch $(uname -m) -R ./binary`. `tools/fuzz.sh` builds and runs the mutation fuzzer under AddressSanitizer, `tools/soak.sh` the soak test and `tools/profile.sh` the heap profile (which needs `heaptrack`). Interop with grpc-go ([interop.md](interop.md)) and h2spec ([h2spec.md](h2spec.md)) need Go and the h2spec binary and are run by hand. What runs when: [CONTRIBUTING.md](../CONTRIBUTING.md).

## How dependencies are chosen, obtained and tracked

- **Choice**: few. TLS is BearSSL, HTTP/2 is nghttp2, gzip is zlib; the async API uses chronos. A new dependency is added only when nothing in the standard library or in those does the job, and it is named with the reason in the change.
- **Obtaining**: nimble packages from their repositories (`nimgrpc.nimble` states the minimum versions); nghttp2 from its release tarball, built from source; no vendored binaries.
- **Tracking**: Dependabot proposes updates of the GitHub Actions each week, and Renovate (`renovate.json`) proposes a new Nim for the CI when one is released (the CI tests the oldest Nim that `nimgrpc.nimble` allows and the current stable one); Dependency Review checks pull requests; the advisories of nghttp2, BearSSL and zlib are read at each release. The policy for findings is in [security-policies.md](security-policies.md).

## Hardening

A release build of this repository (`-d:release`) compiles its C with `-fstack-protector-strong -D_FORTIFY_SOURCE=2` (`config.nims`). That file applies only when building inside the repository: a program that links the library should pass the same flags (`--passC`) and, for an executable, position-independent code and full RELRO (`--passC:-fPIE --passL:"-pie -Wl,-z,relro,-z,now"`). The memory-safety of the Nim code is the compiler's (`--mm:orc --panics:on`), and the whole suite runs under AddressSanitizer and ThreadSanitizer in CI.

## Coverage

`nimble coverage` (or `tools/coverage.sh`) builds every test file with gcov instrumentation, runs it and prints the statement coverage of `src/nimgrpc`; it fails under 80% (`THRESHOLD=85` changes the limit, `OUT` the directory, `NIMGRPC_FLAGS` adds compiler flags). It works because the Nim compiler writes `#line` directives into the C it generates, so `gcov` reports the lines of the `.nim` files; it needs `gcc` with `gcov` 9 or later and `python3`. The figure counts the lines the tests ran in the Nim and C files of the library, the generated well-known types included (88.8% on 2026-11-04), and CI runs it on every pull request (the job `tests (coverage, Nim 2.2.12)`).

## Build variables, debug information, repeatability

- **`CC`, `CFLAGS`, `LDFLAGS`** set in the environment reach the C compiler and the linker of every build made in this repository (tests, tools, `protoc_gen_nim`; `config.nims`). They are added to the flags the build uses, never replacing them. A program that links the library passes its own flags through `--passC` and `--passL`, the Nim way.
- **Debug information** is not removed by the build or by `nimble install`: add `--debugger:native` (or `-g` in `CFLAGS`) and the binary keeps it (`file` says "not stripped"). Nothing in the repository strips.
- **Repeatable builds**: the same source, the same Nim and C compiler and the same flags give a bit-identical binary; two builds of `tests/tcodec.nim` with `-d:release`, with different `--nimcache` directories, have the same SHA-256.
- **No recursive builds**: the Nim compiler builds the whole program in one run; there are no makefiles in subdirectories.
- **Installation**: the library is installed by nimble, into the directory the user chooses (`--nimbleDir`, `NIMBLE_DIR`); the repository has no installer of its own.
