# Threat model

nimgrpc is a library: it runs inside the program of its user, as a gRPC client, as a server, or both. It holds no keys or data of its own except what TLS needs for a connection (the private key given by the program). What it protects is the program that links it.

## Assets

- The memory safety and availability of the process that embeds the server: a malformed request must not crash it, corrupt memory or make it allocate without bound.
- The confidentiality and integrity of the traffic when TLS is on (the keys are the program's; the library only uses them).
- The correctness of the gRPC status and of the data handed to handlers.

## Attackers and entry points

| Attacker | Entry | Mitigation | Residual risk |
|---|---|---|---|
| Unauthenticated network peer, server side | bytes of an HTTP/2 connection | nghttp2 (a maintained C parser, h2spec 135/146 passing, the rest justified in [h2spec.md](h2spec.md)) parses frames; the library only sees decoded events; connection errors send GOAWAY and close | a bug in nghttp2 or in the glue code; the C parts are built and tested under AddressSanitizer in CI |
| The same, gRPC layer | length-prefixed messages | `maxMessage` (4 MiB by default) bounds a message before it is buffered and after gzip decompression | a message limit is per message, not per connection: many streams multiply it, up to `Limits.maxConcurrentStreams` (100 by default) times `maxMessage` |
| The same, Protobuf layer | message bodies | the decoder checks lengths and field numbers against the buffer and raises on malformed input ([../src/nimgrpc/protobuf.nim](../src/nimgrpc/protobuf.nim)); tests include malformed input | deeply nested recursive messages are bounded only by `maxMessage` |
| A decompression bomb | gzip messages | decompression is capped at `maxMessage` | none known |
| Network attacker (man in the middle) | the connection | TLS 1.2 only, on BearSSL, with ALPN `h2`; only ECDHE key agreement with AES-GCM or ChaCha20-Poly1305 (no static RSA, CBC or 3DES); certificates with RSA keys of 2048 bits or more and no MD5 or SHA-1 signatures; the client trusts only the CA certificates it is given, checks the chain and the server name, and has no switch to turn that off; mTLS is available. Plaintext HTTP/2 is available for tests and trusted networks and says so | a program that chooses plaintext is exposed; the choice is the program's |
| A slow or stalled peer | open streams, unread data | per-stream and per-connection flow control (1 MiB each; on the chronos adapter the window reopens only as data is read), keepalive pings and their policy, deadlines (`grpc-timeout`), graceful shutdown | a connection that never finishes its handshake is closed after `Limits.handshakeTimeoutMs` (120 s); the system's TCP keepalive (`Keepalive.tcpSecs`, 15 s) finds a vanished peer; `Limits` (server): `maxConnectionAgeMs` and `maxConnectionIdleMs` (rotate old or idle connections, off by default), `maxConcurrentStreams` (100 by default), `maxConnections` (no limit by default: set one on a public server; the blocking server uses two threads per connection) and `maxConnectionBuffer` (16 MiB queued per connection) |
| A misbehaving server, client side | replies | message limit, deadlines, cancellation, GOAWAY handling, reconnect with backoff | none known |
| A malicious `.proto` file | `protoc-gen-nim` input | the plugin runs at build time on files the developer chose; it writes Nim source | do not run it on proto files you do not trust, as with any code generator |
| A malicious dependency | nimble packages (`bearssl`, `chronos` and theirs) | few dependencies, pinned by minimum version in `nimgrpc.nimble`; see [security-policies.md](security-policies.md) | nimble has no lock file here; the user's program decides the exact versions |

## Out of scope

Authentication and authorization of calls beyond TLS and metadata: the library gives handlers the peer certificate and the metadata, and the program decides. Rate limiting per client. Protection from a compromised host.

## Attack surface

The listening port of a server (HTTP/2 over TCP, optionally TLS); `protoc-gen-nim` (a build-time tool); nothing else: no files read at run time, no environment variables, no command line, no other sockets.
