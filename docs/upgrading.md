# Upgrading

The latest release is supported ([SECURITY.md](../SECURITY.md)). Read the notes below and in [CHANGELOG.md](../CHANGELOG.md) before upgrading.

General steps: update the package (`nimble install nimgrpc@X.Y.Z` or the new commit); rebuild nghttp2 if [building.md](building.md) names a new version; regenerate the code of your `.proto` files with the new `protoc-gen-nim` (generated code and the library are versioned together); run your tests.

## Unreleased

- **The blocking server refuses calls past `Limits.maxQueuedCalls` (1024 by default)**: calls that wait for a worker used to queue without limit. Past 256 running handlers plus 1024 waiting, a new call is refused (REFUSED_STREAM; a client of this library sees UNAVAILABLE and sends a unary call again). Nothing to change unless you keep more than that many calls open on a blocking server: raise `maxQueuedCalls` (0 means no limit) or use the chronos server.

## 0.7.0

- **A client waits at most 20 s for a server that stays silent**: `ClientLimits.handshakeTimeoutMs` closes a connection whose server accepted the TCP connection and has not finished TLS and sent its first SETTINGS by then, and the call fails with UNAVAILABLE (before, a call with no deadline waited for ever). A server that is only slow to answer is not affected: the limit ends when its first SETTINGS arrives. Pass `limits = ClientLimits(handshakeTimeoutMs: 0)` to `dial` or `dialAsync` for the former behaviour.
- **A client resets a call whose response headers or trailers weigh more than 64 KiB** (`ClientLimits.maxHeaderListBytes`, announced to the server as SETTINGS_MAX_HEADER_LIST_SIZE). Few servers send that much; `ClientLimits(maxHeaderListBytes: 0)` leaves only nghttp2's own limits. This is why the number is 0.7: two defaults are new.
- **Fixed**: a call could wait for ever when nghttp2 reset its stream while the session framed the RST_STREAM and the connection had nothing more to read. Nothing to change in your code.
- **Less memory**: a chronos connection with a call open takes 28 KiB instead of 38. Nothing to change in your code.
- **nghttp2, BearSSL, zlib**: unchanged (nghttp2 1.71.0 in the CI, `bearssl` 0.3.1 the lowest, the system's zlib). Advisories read on 2026-11-19: nghttp2 none after GHSA-6933-cjhr-5qg6 (fixed in 1.68.1; CVE-2026-58055 of 2026 concerns `nghttpx`, the proxy, not the library); zlib none (1.4 was released on 2026-11-05 and has not been tried here: the CI uses the system's 1.3); BearSSL has no advisory channel and its commits since the last release were not read one by one.
- Nothing else changes in behaviour.

## 0.6.0

- **Interceptors** are new ([interceptors.md](interceptors.md)): `addInterceptor` on a server and on a channel, blocking and chronos. A program that adds none behaves as before. This is why the number is 0.6: the API grows; nothing existing changes.
- **chronos: closing a connection** now ends our side first and waits for the peer to end its side, one second at most (and one mebibyte of what the peer still sends), before the socket is closed. A peer that reads its end of stream and closes, as gRPC clients and servers do, sees no difference in time; `AsyncChannel.close` and `AsyncGrpcServer.stop` can take up to a second longer with a peer that never closes its side. `stop` closes all connections at once, so the second is not per connection. Before, a peer that sent a frame right behind the one that ended the connection (a PING behind its GOAWAY) could get a TCP reset, and a connection whose peer had sent GOAWAY could stay open until the peer closed it; both are fixed.
- **A blocking channel holds its own share of the `TlsConfig`** it was dialled with, so it may be closed on another thread than the one that dialled it. Nothing to change in your code.
- **nghttp2 1.71.0**: the CI, [building.md](building.md) and `tools/build-nghttp2.sh` now use 1.71.0. Rebuilding is not required: no security advisory lies between 1.68.1 and 1.71.0, and the library still compiles against 1.61.0 or later. A program that stays on 1.68.1 keeps working; it is no longer what the tests run with.
- **BearSSL**: the two fixes the upstream made in April 2026 (the length check of CBC records, and the decoders of certificates and keys that went on after an error) are in `bearssl` 0.3.1, the lowest version this library accepts. The library offers no CBC suite, and loads certificates and keys only from what the program passes to it, so neither was reachable from the network.
- Nothing else changes in behaviour.

## 0.5.1

- **Upgrade from 0.4.0 or 0.5.0 if a blocking server can get a unary request much larger than `maxMessage`**: such a client waited until its deadline (for ever without one) instead of getting RESOURCE_EXHAUSTED at once. Nothing to change in your code.
- **Large `bytes` and `string` fields** are encoded with one copy less. The wire form is the same; generated code does not have to be regenerated for this.
- Nothing else changes in behaviour. New documents: [troubleshooting.md](troubleshooting.md), [faq.md](faq.md), [production.md](production.md), [supported-versions.md](supported-versions.md), and the examples in [../examples/README.md](../examples/README.md).

## 0.5.0

- **nghttp2 1.68.1**: rebuild nghttp2 at 1.68.1 ([building.md](building.md)); it fixes CVE-2026-27135. The library still compiles against 1.61.0 or later.
- **ALPN is required**: a TLS client that offers no ALPN protocol is refused by the server in the handshake, and a client refuses a server that selects none. Clients of this library always offer `h2`; a tool or proxy that talks TLS to a server of this library must offer ALPN `h2` (`openssl s_client -alpn h2`).
- **Content-type**: only `application/grpc`, `application/grpc+...` and `application/grpc;...` are gRPC. A look-alike such as `application/grpcx` gets HTTP 415 from a server, and a client call that receives one fails with UNKNOWN.
- **Malformed `grpc-timeout`**: a call whose `grpc-timeout` is present but malformed now ends with INTERNAL ("malformed grpc-timeout"); before, it ran without a deadline. A client of this library never sends one.
- **UNKNOWN says `internal error`**: when a handler raises something that is not a `GrpcError`, the client gets UNKNOWN with the message `internal error`, not the text of the exception. A program that read that text on the client side must raise a `GrpcError` with the message it wants to send. To see the real exception on the server, call `srv.setErrorHook(hook)` before `start` (blocking: `proc (path: string; e: ref CatchableError) {.nimcall, gcsafe, raises: [].}`, called on the worker thread; chronos: a closure of the same shape); without a hook nothing is logged.

## 0.4.0

- **Handshake limit**: `Limits.handshakeTimeoutMs` is 20 s by default (was 120 s). A client that needs longer than that to finish TLS and send its first SETTINGS is cut off: raise the limit for such clients.
- **`Health/Watch` and reflection on the blocking server** are limited to 64 and 16 calls at once (`newHealth(maxWatches = ...)`, `newReflection(maxStreams = ...)`; 0 for no limit). A server whose clients all watch its health needs a larger `maxWatches` and as many workers, or the chronos server, where a `Watch` costs no thread.
- **Unary calls on the blocking server** start their handler when the request message has arrived, not when the HEADERS did. Nothing to change. One difference can be seen: a message larger than `maxMessage` is refused once that many bytes have arrived, not at its first bytes.
- **Flow control of the blocking adapter** is manual now: a handler (or a client) that stops reading a stream stops its peer after 1 MiB. Nothing to change in a program that reads what it is sent.
- **Facing clients you do not trust** (new settings, off by default): set `Limits.maxCallMs` unless the server has calls that are meant to stay open, `Limits.maxConnectionsPerIp` where clients connect directly (not behind a proxy that hides their addresses), and `maxConnections`.

## 0.3.1

- **Nesting limit**: a message nested deeper than 100 levels (`maxNestingDepth` in `nimgrpc/protobuf`), counting sub-messages and groups, is now rejected with `ProtobufError`; a server answers INTERNAL. Real messages are far shallower (protobuf-go and C++ protobuf use the same limit). Hand-written code that builds a `PbReader` for a nested message from copied bytes should use `childReader` (or `subReader`) so that the depth carries over. The generator did not change, so generated code does not have to be regenerated for this (regenerate as usual with each release).
- **Upgrade from 0.3.0 at once if a server registers `nimgrpc/health`**: a request of a few bytes stops it (see the changelog). Nothing to change in your code.
- **`TlsConfig` and threads**: a program that hands one `TlsConfig` to several threads should give each thread (or each connection) `share(config)` instead of the object itself.
- **TLS by IP address**: `dial("10.0.0.5", ..., tls)` now verifies the certificate against its IP entries; a `serverName` that was set only to work around this may be dropped.

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
