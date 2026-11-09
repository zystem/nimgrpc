# Upgrading

The latest release is supported ([SECURITY.md](../SECURITY.md)). Read the notes below and in [CHANGELOG.md](../CHANGELOG.md) before upgrading.

General steps: update the package (`nimble install nimgrpc@X.Y.Z` or the new commit); rebuild nghttp2 if [building.md](building.md) names a new version; regenerate the code of your `.proto` files with the new `protoc-gen-nim` (generated code and the library are versioned together); run your tests.

## Unreleased

## 0.3.0

- **Connection age and idleness** (new, off by default): `Limits.maxConnectionAgeMs`, `maxConnectionIdleMs` and `maxConnectionAgeGraceMs` drain old or idle connections with GOAWAY. Nothing changes unless you set them; a client that does not redial after GOAWAY would fail its next call, which the clients of this library do not.

- **nghttp2**: 1.61.0 or later is now required (was 1.57.0): earlier versions are open to the CONTINUATION flood (CVE-2024-28182). An older header fails the build, with a message saying so.
- **Timeouts**: deadlines and timed waits of the blocking adapter count on the monotonic clock (Linux), so a step of the system clock no longer shortens or stretches them. Nothing to do.
- **IPv6**: the blocking `dial` now tries IPv6 addresses of a name too (before, IPv4 only). The addresses are tried as Happy Eyeballs (RFC 8305) says, the next one alongside the previous after 250 ms, so a name with an AAAA record that leads nowhere costs about a quarter of a second, not `connectTimeoutMs`. A server listens on one family unless you pass `address = "::"` (both).
- **Handshake limit and TCP keepalive**: a server now closes a connection that has not completed the TLS handshake and sent its HTTP/2 preface and first SETTINGS within two minutes (`Limits.handshakeTimeoutMs`; 0 turns it off), and every connection gets the system's TCP keepalive after 15 seconds of silence (`Keepalive.tcpSecs`; 0 turns it off). A client that is slower than two minutes to start talking must raise the limit.

- **Retries**: `unaryCall` sends a call again (twice at most, within its deadline) when the server refused it without starting on it; `GrpcError.unprocessed` tells such an error. Streaming calls are not retried. Nothing to do; a program that retried UNAVAILABLE itself may now see a call arrive later than before.

## 0.2.1

- **Limits, first burst (0.2.0)**: a server refuses (REFUSED_STREAM, which the clients of this library report as UNAVAILABLE; it is safe to retry, the call did not run) the calls over `maxConcurrentStreams` that arrive in the first flight of a connection, before the client has read the server's SETTINGS; once SETTINGS are in, nghttp2 holds the excess back by itself. A client that opens more than the limit of calls at once on a connection it has just made should retry such a call, send one call first, or the server should raise the limit.

## 0.2.0

- **Limits**: a server announces at most 100 concurrent streams per connection (`Limits.maxConcurrentStreams`); a client library that respects SETTINGS (nghttp2, grpc-go) queues the rest, so only a program that needs more than 100 calls at once on one connection notices. Pass `limits = Limits(maxConcurrentStreams: 0)` to keep the former, unlimited behaviour. New `maxConnections` (off) and `maxConnectionBuffer` (16 MiB) are described in [threat-model.md](threat-model.md).
- **nghttp2**: 1.57.0 or later is required; an older header fails the build.

## 0.1.0

- **The package and the modules are called `nimgrpc`** (the name `grpc` in the nimble directory belongs to another project). Install with `nimble install nimgrpc`, and in a `.nimble` file write `requires "nimgrpc >= 0.1.0"`. In your code replace `import grpc` with `import nimgrpc` and `grpc/...` with `nimgrpc/...` in every import (`grpc/protobuf`, `grpc/typed`, `grpc/h2/blocking`, `grpc/wkt/...`), for example `sed -i -E 's/\b(import|from) grpc\b/\1 nimgrpc/; s/\bgrpc\/(protobuf|typed|asynctyped|wkt|h2|tls|compress|client|server|asyncclient|asyncserver|wire|status)/nimgrpc\/\1/g'`. The generated code of your `.proto` files imports the library too: regenerate it with the new `protoc-gen-nim`. Nothing else changes in the API.

## 0.0.2

- **Session resumption**: a `TlsConfig` now resumes TLS sessions for ten minutes (`setSessionLifetime`, 0 turns it off). A resumed session is not checked against the certificate again, so a revoked or expired certificate keeps working for a peer that holds a session until the lifetime ends. If revocation must take effect at once, set the lifetime to 0 or restart the server. Reuse one `TlsConfig` for the channels to one server to get the benefit.
- **HTTP/2 window**: every connection now announces 1 MiB per stream and per connection (before: 64 KiB). A peer can leave up to 1 MiB unread on a connection, about 5 MB more resident memory per busy process in our measurements; large messages are 20-40% faster.
- **Server and unfinished requests**: a chronos server resets a stream with NO_ERROR once its response is complete and the client is still sending; the client's `send` then raises the server's status instead of waiting.
- **`send` takes `sink`**: `send` of the async client, server and `AsyncH2Stream` moves its message when the caller does not use it again (no source change needed); keep a copy if you read the variable afterwards.

- **Cipher order**: TLS now prefers AES-GCM on a CPU with AES-NI and PCLMULQDQ and ChaCha20-Poly1305 elsewhere (before: ChaCha20 first everywhere), and a server's order wins over the client's. The set of suites is unchanged, so every peer that connected before still connects. Pin the old order with `cipherOrder = coChaChaFirst`.

- **Connect timeout**: `dial`, `dialAsync` and the reconnects of a channel give up on a server that does not accept the TCP connection after 20 seconds (`connectTimeoutMs`, UNAVAILABLE). Pass `connectTimeoutMs = -1` for the previous behaviour, or a smaller figure to fail faster. The name resolver is not bounded by it.
- **TLS suites and certificates**: the library now negotiates only TLS 1.2 with ECDHE and AES-GCM or ChaCha20-Poly1305, and verifies certificates with RSA keys of 2048 bits or more and no MD5 or SHA-1 signatures. A peer or certificate that does not meet this fails the handshake. Reissue such certificates (a SHA-256 or better signature, an RSA key of 2048 bits or an EC key).

- **Chronos adapter, flow control**: the peer's window now reopens only as a handler reads (`recvData`). A client that sends a large body and only then reads an answer from a peer that replies while it still receives can stall; send and read concurrently, as in `request` of `tests/tasynch2.nim`. The blocking adapter is unchanged.
