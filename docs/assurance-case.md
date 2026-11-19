# Assurance case

Why the security requirements of [security-requirements.md](security-requirements.md) are met. It is an argument, with the evidence in the repository; it is reviewed at each release.

## 1. Threat model

[threat-model.md](threat-model.md): assets, attackers and entry points, the mitigation of each and the residual risk; the actors and actions are in [architecture.md](architecture.md).

## 2. Trust boundaries

1. **Network to the HTTP/2 session**: untrusted bytes meet nghttp2 (and BearSSL first, with TLS). Nothing from the wire is used before nghttp2 has decoded it into an event.
2. **Session to gRPC layer**: events only; the gRPC layer checks framing, `maxMessage`, status and deadlines.
3. **gRPC layer to handler**: a decoded message and metadata; a handler failure becomes a status, never a crash of the connection loop.
4. **Library to program**: the program owns authentication, authorization and limits.
5. **Build to user**: source from a tag; the user builds it with their own compiler.

## 3. Secure design principles (Saltzer and Schroeder)

| Principle | How it is applied |
|---|---|
| Economy of mechanism | a few dependencies (nghttp2, BearSSL, zlib, chronos for the async API); the session layer is I/O-free and small |
| Fail-safe defaults | unset methods answer `UNIMPLEMENTED`; message size limited by default; the client verifies the server by default |
| Complete mediation | every message goes through framing and limit checks, on every stream |
| Open design | gRPC and HTTP/2 are public standards; the security does not rest on secrecy |
| Least common mechanism | each connection has its own session; streams do not share buffers |
| Psychological acceptability | one call to dial or serve; generated typed stubs |
| Fail closed | a connection error sends GOAWAY and closes; a failed handler returns a status |

## 4. Common weaknesses countered

| Weakness | Counter | Evidence |
|---|---|---|
| Malformed input (CWE-20) | nghttp2 for frames; checked lengths in framing and Protobuf; errors become statuses | `tests/tgrpc.nim`, `tests/tcodec.nim`, `tests/th2session.nim`, h2spec ([h2spec.md](h2spec.md)) |
| Memory errors (CWE-119, 416) | Nim with ORC; sanitizers on the whole suite; a weekly mutation fuzzer and a weekly coverage-guided one (libFuzzer) over the parsers | `nimble asan` on every change, `nimble tsan` nightly, `tools/fuzz.nim` and `tools/libfuzz.nim` weekly |
| Resource exhaustion (CWE-400, 409) | `maxMessage`, decompression cap, flow control, deadlines, keepalive | `tests/tasynch2.nim` (a reader that does not read stops the sender), `tests/tkeepalive.nim`, `tests/tgrpc.nim` |
| Weak transport security (CWE-319, 295) | TLS with certificate verification, mTLS | `tests/ttls.nim` |
| Vulnerable components | Dependabot for the actions, Dependency Review, review of nghttp2/BearSSL/zlib releases | [security-policies.md](security-policies.md) |
| Compiler bugs losing errors | a documented workaround and a regression test | [nim-compiler-notes.md](nim-compiler-notes.md), `tests/nimbug_finally.nim` |

## 5. Hardening

Static musl builds are possible ([static-build.md](static-build.md)); no run-time files, environment variables or command line are read by the library.

## 6. Gaps (known)

Single maintainer (no second reviewer); the coverage-guided fuzzer instruments our code and BearSSL (compiled with it), not nghttp2 or zlib as linked (see [roadmap.md](roadmap.md)); no static analysis tool for Nim beyond the compiler's warnings; no code-coverage measurement; `Limits.maxConnections` and `maxConnectionsPerIp` are off by default. A gap is a reason to read [threat-model.md](threat-model.md), not a hidden risk.
