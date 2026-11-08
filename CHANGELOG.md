# Changelog

## Unreleased

### Added
- `shutdown(GrpcChannel)`: closes every connection of the channel and frees nothing. Calls in progress, on any thread, fail at once, and new calls are refused. A program whose threads wait in calls can stop them with it, join them, and only then `close` the channel. Safe from any thread and more than once.
- `nimble coverage` / `tools/coverage.sh`: statement coverage of `src/nimgrpc` from gcov (the Nim compiler's `#line` directives make it report `.nim` lines); 88.8% now, CI fails under 80% (job `tests (coverage, Nim 2.2.12)`). See [docs/building.md](docs/building.md).
- The builds of this repository honour `CC`, `CFLAGS` and `LDFLAGS` from the environment (added to the flags in use); see [docs/building.md](docs/building.md), which also says how debug information, repeatable builds and installation are handled.

### Fixed
- `close(GrpcChannel)` from one thread while a call of another thread was waiting in `recv` freed the connection under that call: the call that then failed touched freed memory (found with AddressSanitizer in a program that closed its channel to end its reader thread; the corrupted heap ended in a thread spinning for ever in the allocator). `close` now waits (up to ten seconds) for the calls that are inside a procedure of the library on another thread to leave it, and does not free the channel if one does not. A call that has not entered the library yet cannot be waited for: do not start calls on a channel that is being closed. Test: `tests/tchannelclose.nim`.

## 0.2.1 — 2026-11-03

### Added
- [docs/releasing.md](docs/releasing.md): how a maintainer makes a release (the release pull request, the signed tag, the GitHub release), and `tools/release_notes.sh X.Y.Z`, which prints the notes of a version from the changelog.
- `nimble lint` (run in CI): the compiler's style check as an error and warnings as failures over the library, the plugin, the tests and the tools. The generated code is exempt from the style check (proto names keep their spelling; `protoc-gen-nim` now writes `{.push styleChecks: off.}`). A release build of the repository compiles its C with `-fstack-protector-strong -D_FORTIFY_SOURCE=2`.
- Release tags are signed (SSH key), from this release on (the tags up to 0.2.0 are not); how to verify one is in [SECURITY.md](SECURITY.md#verifying-a-release), the public key in `docs/allowed_signers`.

### Fixed
- The fuzz workflow took its `seconds` input into the text of a shell command; it is now passed as an environment variable and checked to be a number.
- `tests/tlimits.nim` sometimes failed under AddressSanitizer (a 16 KiB leak of a worker thread's cycle roots, seen in CI on Nim 2.2.14): the test opened its burst of calls on a new connection, the server refused the excess with REFUSED_STREAM (which the test did not check), and the exceptions of the refused calls left cycle roots in the threads of the test. The test now makes one call first and checks every reply. The behaviour itself is documented in [docs/upgrading.md](docs/upgrading.md).
- `examples/static_client.nim` imported `nimgrpc/testing/test_pb`, which the 0.1.0 rename had changed by mistake; it is `grpc/testing/test_pb` (the generated code of the test protos, `-p:tests/gen`).

## 0.2.0 — 2026-11-03

### Added
- `Limits` for both servers (`limits` of `newGrpcServer`, `newAsyncGrpcServer`, `newStreamServer`, `newAsyncStreamServer`): `maxConcurrentStreams` (announced to clients as SETTINGS_MAX_CONCURRENT_STREAMS, 100 by default; a client that ignores it gets REFUSED_STREAM), `maxConnections` (a connection past the limit is closed at once; no limit by default) and `maxConnectionBuffer` (body bytes queued on all streams of a connection that the socket has not taken, 16 MiB by default; a sender waits above it). Tests in `tests/tlimits.nim` and `tests/tasynclimits.nim`.

### Security
- nghttp2 1.57.0 or later is required, which limits the Rapid Reset attack (CVE-2023-44487): the build fails with an `#error` against an older header, and a test checks the linked library's version.

### Changed
- A server now announces 100 concurrent streams per connection; before, nghttp2's default (no limit) applied. Set `Limits(maxConcurrentStreams: 0)` for the old behaviour. See [docs/upgrading.md](docs/upgrading.md).

## 0.1.0 — 2026-11-03

### Changed
- The nimble package is now `nimgrpc` (`nimgrpc.nimble`) and so are the modules: `import grpc` becomes `import nimgrpc`, `import grpc/protobuf` becomes `import nimgrpc/protobuf`, and so on. The name `grpc` in the nimble directory belongs to another project, and two packages with a `grpc` module cannot be used in one build. Regenerate the code of your `.proto` files with the new `protoc-gen-nim`. See [docs/upgrading.md](docs/upgrading.md).

## 0.0.2 — 2026-11-03

### Added
- TLS session resumption (session ids), on by default for ten minutes: `setSessionLifetime(config, seconds)`, 0 to turn it off. A reconnect of a channel with the same `TlsConfig` and server name skips the public-key work: new connection plus first call (`tools/hsbench.nim`) 4.9 ms to 0.9 ms with TLS and 6.9 ms to 0.6 ms with mutual TLS. The server keeps only sessions of peers that were authenticated as required, and drops its cache as a whole when the lifetime has passed. A resumed session is not checked against the certificate again, so a revoked or expired certificate keeps working for a peer that holds a session until the lifetime ends (see `docs/security-requirements.md`).
- Scheduled long checks: a weekly mutation fuzzer over the parsers (`tools/fuzz.nim`, `fuzz.yml`), a nightly ThreadSanitizer run of the whole suite (`tsan.yml`) and a weekly heap profile of the server with its summary (`tools/profile.sh`, `profile.yml`). A shared setup action (`.github/actions/setup`) builds nghttp2 and Nim for them.
- Weekly soak test of the chronos server (`tools/soak.sh`, `.github/workflows/soak.yml`): memory per connection and no growth under churn, plain and TLS. `tools/asyncload.nim` gained `hold`, `churn` and `tls` modes.

### Changed
- Cipher order of TLS: the same six suites (ECDHE with AES-128/256-GCM or ChaCha20-Poly1305), now ordered by the CPU. With AES-NI and PCLMULQDQ AES-GCM comes first, which was about 30% faster on large replies in `tools/tlsbench.nim` (33.5 MB/s with ChaCha20, 42-47 MB/s with AES-GCM, loopback, both ends in one process); otherwise ChaCha20 stays first, as BearSSL's portable AES is slow. A server now enforces its own order instead of following the client's. Choose with `cipherOrder` of `tlsServerConfig` / `tlsClientConfig` (`coAuto`, `coAesGcmFirst`, `coChaChaFirst`) or `setCipherOrder`.
- Fewer copies of a message. On receipt `wire.MsgBuf` (replacing `takeFrame` and `appendData`, which were internal) builds the message straight from the chunks as they arrive, instead of collecting them in a buffer and slicing the message out; a declared length reserves nothing, memory grows with the bytes received. On sending, the 5-byte frame prefix goes in front of the message in the stream buffer (`head` of `sendData` / `send`), so `encodeMessage` is no longer called for each message. Measured in pinned runs (`taskset`, `tools/tlsbench.nim`): 64 KiB over TLS about 4% faster, 1 MiB 1-2%, small messages unchanged.
- CI tests on Nim 2.2.12 (the floor of `nimgrpc.nimble`) and 2.2.14; the soak test runs on 2.2.14. Renovate proposes new Nim versions (`renovate.json`), which Dependabot cannot see.

### Fixed
- A new TLS connection took about twice as long as it had to: BearSSL's "full" profiles verify certificate signatures with the generic prime_i31 code, which was about 60% of a handshake. Certificates and the handshake now use the fast P-256 code (m64 where the CPU has 64x64->128 multiplication, m31 otherwise). New connection plus first call, `tools/hsbench.nim`: TLS 7.7 to 4.2 ms, mutual TLS 9.5 to 5.7 ms.
- The blocking transport woke every thread of a connection on each change (one condition variable for the writer, the senders and the receivers) and sent each piece of output with its own `send`. The writer now has its own condition, wakes happen only when someone waits, and what is ready is sent in one `send`. For a 1 KiB unary call: `futex` calls 60 to 26, `sendto` 6 to 2.3 and `recvfrom` 4.7 to 2.3.
- Bulk data was copied byte by byte, which a profile of a 900 KB echo over TLS showed to be about 72% of the CPU time (AES-GCM itself was about 4%). Appending to the connection, stream and TLS buffers, taking messages out of them and reading TLS plaintext now use one `copyMem` and no longer zero the space they grow into (`src/grpc/bytebuf.nim`). The TLS pumps also stopped shifting the whole pending buffer after every 16 KiB record (quadratic in the message size) and drop two more copies per message (`takeOutputInto`, reading BearSSL output straight into the buffer). In `tools/tlsbench.nim` (1 MiB replies, loopback) TLS went from about 48 MB/s to 136-194 MB/s and plaintext from 108-153 to 237-293 MB/s.
- The chronos transport copied each message element by element at every `async` layer (chronos copies the arguments of an `async` proc into its frame, and `await` hands out a borrowed value): a profile of a 1 MiB echo over TLS on the event loop showed 41% of the time in `seq[byte]` copies. `send` of the async client, server and `AsyncH2Stream` now takes the message as `sink`, puts the 5-byte frame prefix in front in the stream buffer and moves the message into the waiting job only when the buffer is full; `unaryCall` and the unary handler path move replies instead of copying them. `tools/asyncbench.nim`, pinned to 4 cores, one thread for both ends: 1 MiB replies plain 315 to 693 MB/s, over TLS 243 to 415 MB/s; 64 KiB over TLS 242 to 398 MB/s; 1 KiB calls about 5% faster (latency, not copies).
- Every connection advertised the default HTTP/2 window of 64 KiB per stream and per connection, so a large message waited for the peer's WINDOW_UPDATE every 64 KiB, each one a hand-off between threads and a few system calls. A session now announces a window of 1 MiB for each stream and for the connection (`receiveWindow`, `src/grpc/h2/session.nim`), which is also the most unread data a peer can make us hold per connection. CiNim's `shimtransport` (loopback, pinned): 900 KB requests 4.5 to 2.8 ms, 64 KiB 0.34 to 0.28 ms, CPU of the client and the server for the series about 1.1 to 0.85 s (ZeroMQ + CURVE 0.7-0.8 s); `futex` calls of the client for 200 requests of 900 KB 139 000 to 62 000. A larger maximum frame size and a larger socket read buffer were tried and gave nothing.
- A client that sent a large message to a call the chronos server had already ended without reading the request waited forever: the server never told it to stop. The server now resets such a stream with NO_ERROR once its response is complete (as other gRPC servers do), and the client's `send` raises the server's status.
- `dial` and `dialAsync` blocked on connect for as long as the system's TCP timeout (minutes), with no way to bound it. Each connection attempt now gets `connectTimeoutMs`, 20 seconds by default; past it the call fails with UNAVAILABLE. A negative value keeps the old behaviour. Resolving the host name is not covered by the timeout.

## 0.0.1 — 2026-11-02

### Security
- TLS is narrowed to what is safe: only ECDHE key agreement with AES-GCM or ChaCha20-Poly1305 (BearSSL's "full" profile also offered static RSA, CBC and 3DES), RSA certificate keys of 2048 bits or more (the default admitted 1017), and no MD5 or SHA-1 certificate signatures. A peer that supports nothing better cannot connect any more; see [docs/upgrading.md](docs/upgrading.md).

### Added
- Manual HTTP/2 flow control on the chronos adapter: the peer's window reopens only as handlers read, so a slow reader backpressures the sender instead of buffering without bound.
- Project documents for the OpenSSF Best Practices levels: [security policy](SECURITY.md), [governance](GOVERNANCE.md), [contributing](CONTRIBUTING.md), [code of conduct](CODE_OF_CONDUCT.md), DCO sign-off with a check of pull requests, [threat model](docs/threat-model.md), [architecture](docs/architecture.md), [assurance case](docs/assurance-case.md), [security requirements](docs/security-requirements.md), [security policies](docs/security-policies.md), [building](docs/building.md), [roadmap](docs/roadmap.md), [upgrading](docs/upgrading.md).
- CI: all tests plainly and under AddressSanitizer on every push and pull request; Dependency Review, Scorecard, secret scanning configuration, Dependabot for the actions.

## Before 0.0.1

First public state: unary and streaming gRPC over HTTP/2 (plaintext, TLS, mTLS) on a blocking API and on chronos, code generation from `.proto`, gzip, keepalive, graceful shutdown, reconnecting channels, well-known types.
