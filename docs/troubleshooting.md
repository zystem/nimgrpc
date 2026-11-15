# Troubleshooting, by message

Find the text you see, read what it means, do what the last column says. Words that change
(a number, a name, a path) are written in capitals: `N`, `NAME`, `PATH`.

Where a message comes from:

- A client call raises `GrpcError`: `e.code` is the status, `e.msg` the text below.
- A reason for a lost connection reaches a call as UNAVAILABLE with `stream N: ` in front
  (blocking client) and may come after `connection closed: `.
- The library writes no log. A server learns of a handler's exception only through
  `setErrorHook` ([production.md](production.md)).

`tests/tdocs.nim` fails when a message of the library has no line here, and it makes the
failures marked **(run)** happen and compares the text.

## Building

| Message | Meaning | What to do |
|---|---|---|
| `fatal error: nghttp2/nghttp2.h: No such file or directory` (the compiler prints it in the system's language) | nghttp2 is not where the build looks: `/opt/nghttp2`, or `deps/nghttp2` inside this repository. | Build it ([building.md](building.md); `tools/build-nghttp2.sh` in a clone) or pass `-d:nghttp2Prefix=/path`. |
| `nimgrpc needs nghttp2 1.61.0 or later` | The nghttp2 header found is older than 1.61.0. | Build nghttp2 1.68.1 and point the build at it. |
| `cannot open file: bearssl` or `chronos` | A nimble package is missing. | `nimble install bearssl chronos`, or `nimble install -y --depsOnly` in a clone. |
| `unknown option "X" (expected blocking, async and/or descriptor)` | `protoc-gen-nim` got a `--nim_opt` it does not know. | Use `blocking`, `async`, `descriptor`, separated by commas. |
| `'=copy' is not available for type <TlsConfigObj>` and the like | The program copies an object that owns a C resource. | Pass the `ref` (`TlsConfig`), or `share(config)` for another thread. |
| A lost exception: a call returns where it should raise | Nim 2.2.12 and 2.2.14 can drop an exception in `finally` or `defer`. | [nim-compiler-notes.md](nim-compiler-notes.md). |

## Connecting (the client gets UNAVAILABLE)

| Message | Meaning | What to do |
|---|---|---|
| `Connection refused` **(run)** | Nothing listens on that address and port. A server listens on `127.0.0.1` unless told otherwise. | Check the port; start the server with `address = "0.0.0.0"` or `"::"` to be reached from another host. |
| `Name or service not known` (on a second line, after the system's own first line) **(run)**, `cannot resolve NAME` (chronos) | The name does not resolve. | Check the name and the resolver. |
| `no usable address for NAME` | The name resolved to no address the socket can use. | Check the records of the name. |
| `connect to NAME timed out` | No answer to the TCP connection within `connectTimeoutMs` (20 s). | Check the route and the firewall; a smaller `connectTimeoutMs` fails sooner. |
| `connection closed by peer` **(run)** | The other side closed the connection. Seen at the first call it most often means: a plaintext client met a TLS server; a server that requires a client certificate got none; the server is over `maxConnections` or `maxConnectionsPerIp`. | Give `dial` a TLS config; give the client its certificate and key; raise the limit or use fewer connections. |
| `TLS: unsupported protocol version (TLS 1.2 is required)` **(run)** | The peer does not speak TLS 1.2: a TLS client met a plaintext server, or the peer allows only another version. | Use TLS on both sides or on neither; allow TLS 1.2 on the peer. |
| `TLS: certificate not signed by a trusted CA` **(run)** | The server's chain does not end in a CA given to `tlsClientConfig`. | Pass the CA that signed the server's certificate; send the intermediates in the server's chain. |
| `TLS: server name does not match the certificate` **(run)** | The name (`serverName`, or the host given to `dial`) is not among the certificate's DNS names, or the IP address not among its IP entries. | Pass `serverName`, or issue the certificate with that name or address. |
| `TLS: certificate expired or not yet valid` | The dates of a certificate do not cover now. | Renew the certificate; check the clock. |
| `TLS: the client presented no certificate`, `TLS: the peer presented no certificate` | A certificate was required and none came. | Configure the client's certificate and key. |
| `peer did not present a trusted certificate` | The handshake ended without a verified certificate. | As above. |
| `peer did not negotiate ALPN h2` | The peer offered or selected no ALPN protocol `h2`. | Make the peer or the proxy offer `h2` (`openssl s_client -alpn h2`). |
| `TLS: peer sent fatal alert N`, `TLS: sent fatal alert N` | The handshake was refused, by the peer or by this side; `N` is the TLS alert number (40: no cipher suite or key in common, 42 to 48: a certificate was refused). | Read the other side's log. The library takes only ECDHE with AES-GCM or ChaCha20-Poly1305, RSA keys of 2048 bits or more, no MD5 or SHA-1. |
| `TLS error N`, `TLS session closed` | BearSSL's error number `N` (its `bearssl_ssl.h` and `bearssl_x509.h` list them); the session ended. | Look the number up; check both configurations. |
| `handshake not completed in N ms` | A connection did not finish TLS and the first SETTINGS within `Limits.handshakeTimeoutMs` (20 s). | Raise the limit for slow clients; find what holds the client up. |
| `keepalive: no response to PING within N ms` | The peer did not answer a keepalive PING. | The peer or the path is gone; the channel dials again at the next call. |
| `client sent too many pings` | The server's `pingPolicy` counted too many PINGs and sent GOAWAY. | Raise the client's `Keepalive.timeMs`, or lower `PingPolicy.minIntervalMs`. |
| `connection is going away (GOAWAY)` | The server said it takes no new calls on this connection (it is stopping, or the connection is old or idle). | Nothing: the channel dials again. A call that fails with it was not started. |
| `connection drained`, `grace of the connection over` | The server closed a connection after `maxConnectionAgeMs` or `maxConnectionIdleMs`; calls still running after `maxConnectionAgeGraceMs` were cancelled. | Raise the grace if calls are longer than it. |
| `connection closed: REASON`, `closed`, `read error`, `write error`, `session finished` | The connection ended: by `close`, by a socket error, or by an HTTP/2 error. | Call again; the channel dials a new connection. |
| `channel closed` **(run)** | The call was made on a channel after its `shutdown` (blocking), or after `close` of a chronos channel. A blocking channel must not be used at all after `close`: it is freed. | Dial a new channel. |
| `stream reset with HTTP/2 error 7 (REFUSED_STREAM)` | The server did not start the call: over `maxConcurrentStreams`, or it is stopping. `e.unprocessed` is true. | Safe to send again; `unaryCall` already did, twice. Open fewer calls at once or raise the limit. |
| `stream reset with HTTP/2 error N` | The peer reset the call; `N` is the HTTP/2 error code (8: cancelled, 11: ENHANCE_YOUR_CALM). | 8 from a server of this library: `Limits.maxCallMs` passed, or the server stopped. |

## Calls

| Message | Status | Meaning | What to do |
|---|---|---|---|
| `unknown method /PKG.SERVICE/METHOD` **(run)** | UNIMPLEMENTED | The server has no handler at that path. | Register the service before `start`; compare the package and service names of both `.proto` files. |
| `deadline exceeded`, `deadline exceeded on stream N` **(run)** | DEADLINE_EXCEEDED | The call took longer than its `timeoutMs`. | Give it more time, or make the handler faster; a handler sees it through `ctx.checkCancelled()`. |
| `call cancelled`, `call cancelled: REASON` | CANCELLED | The call was closed before it ended: by the client, by a lost connection, by a stopping server, or by `Limits.maxCallMs`. | Expected when a side leaves; otherwise look at the reason. |
| `internal error` **(run)** | UNKNOWN | A handler raised something that is not a `GrpcError`. The text is kept from the client on purpose. | On the server, `setErrorHook` to see it; raise `newGrpcError(code, msg)` for what the client should read. |
| `message of N bytes exceeds the limit of M` **(run)** | RESOURCE_EXHAUSTED | A message is larger than `maxMessage` (4 MiB) of the side that reads it. | Raise `maxMessage` on that side (`newGrpcServer`, or the call), or send smaller messages or a stream. |
| `decompressed message exceeds the limit of N bytes` | RESOURCE_EXHAUSTED | A gzip message grows past `maxMessage`. | As above. |
| `out of memory decompressing a message` | RESOURCE_EXHAUSTED | zlib could not allocate. | The process is out of memory. |
| `invalid gzip data in a compressed message`, `gzip compression failed (N)` | INTERNAL | The gzip stream is damaged; zlib refused to compress. | Check the sender. |
| `unsupported compression "X"` **(run)** | INVALID_ARGUMENT | A call asked for a compression other than `gzip` or `identity`. | Use `compression = "gzip"`. |
| `compressed message with grpc-encoding X`, `compressed message without grpc-encoding`, `a compressed message needs compression = "gzip" on the call` | INTERNAL, UNIMPLEMENTED | A message is marked compressed and the call names no compression this side knows. | Set `compression = "gzip"` on the call; fix the sender. |
| `malformed grpc-timeout` | INTERNAL | The client's `grpc-timeout` header is not a number and a unit. | Fix the client; clients of this library do not send one. |
| `HTTP status N` | by the status: 401 UNAUTHENTICATED, 403 PERMISSION_DENIED, 404 UNIMPLEMENTED, 429, 502, 503, 504 UNAVAILABLE, else UNKNOWN | The answer is not gRPC: a proxy or another server answered. 415 from a server of this library: the content-type is not `application/grpc`. | Check the address and what stands between. |
| `unexpected content-type "X"` | UNKNOWN | The answer is HTTP 200 but not gRPC. | As above. |
| `response without grpc-status`, `server ended the call early with OK` | INTERNAL | The server closed the stream without a status, or with OK before the call was complete. | A fault of the server or of a proxy that drops trailers. |
| `truncated message`, `truncated message header`, `truncated message at end of stream`, `invalid message flag N` | INTERNAL | The stream ended inside a message, or its first byte is not 0 or 1. | The sender is not gRPC, or the stream was cut. |
| `unary call without a request message`, `unary call with more than one request message`, `server-streaming call without a request message`, `server-streaming call with more than one request` | UNIMPLEMENTED | The client sent a number of messages the method's kind does not take. | The client and the server disagree on the kind of the method: regenerate both from one `.proto`. |
| `unary call ended without a response`, `unary call got more than one response`, `client-streaming call ended without a response`, `client-streaming call got more than one response` | INTERNAL | The same, seen by the client. | As above. |
| `send after the call ended` | INTERNAL | `send` on a call that has its status already. | Stop sending when `recv` returns false or raises. |
| `cannot decode TYPE: REASON` | INTERNAL | The bytes are not that Protobuf message. `REASON` is the decoder's (`ProtobufError`): `truncated varint`, `varint too long`, `invalid tag`, `truncated fixed32`, `truncated fixed64`, `length beyond the end of the message`, `mismatched end group`, `unexpected end group`, or `message nested too deeply` (more than 100 levels). | Both sides must use the same `.proto`; the last one is a limit, not a fault of the bytes. |
| `too many Watch calls; use Check, or try later` | RESOURCE_EXHAUSTED | More `Health/Watch` calls than `newHealth(maxWatches = 64)`. | Use `Check`, raise `maxWatches`, or use the chronos server. |
| `too many reflection calls; try later` | RESOURCE_EXHAUSTED | More reflection streams than `newReflection(maxStreams = 16)`. | Raise `maxStreams`. |
| `unknown service NAME` | NOT_FOUND | The health service was asked about a name nobody set. | `h.setStatus(name, hsServing)`, or ask about `""`. |
| `no HealthCheckRequest`, `bad HealthCheckRequest: REASON` | INVALID_ARGUMENT | A health call without a request, or with one that does not decode. | Fix the client. |
| `file not found: X`, `symbol not found: X`, `type not found: X` | in the reflection answer | Reflection was asked for something the server has no descriptor of. | `refl.addFileDescriptor(...)` for the service's file. |
| `extensions are not supported`, `the request names no method`, `bad request: REASON` | in the reflection answer | Reflection was asked for extensions (not done), for nothing, or with bytes that do not decode. | Fix the tool's request; extensions are only considered ([roadmap.md](roadmap.md)). |

## Setting up TLS (`TlsError`)

| Message | Meaning | What to do |
|---|---|---|
| `identity: no certificate in chain` **(run)**, `identity: REASON` | `tlsServerConfig` or `tlsClientConfig` got a certificate or a key that is not PEM, or a key that does not belong to the certificate. | Pass the contents of the files (`readFile`), not their paths; RSA or EC keys. |
| `CA: no certificate in CA bundle` **(run)**, `CA: REASON` | The CA text holds no PEM certificate. | As above. |
| `client session: REASON`, `server session: REASON` | A TLS session could not be made from the config. | A client needs a CA, a server a certificate and a key. |
| `out of memory` | The C side could not allocate. | The process is out of memory. |

## Values and misuse

| Message | Meaning | What to do |
|---|---|---|
| `Timestamp seconds out of range: N`, `Timestamp nanos out of range: N`, `Duration seconds out of range: N`, `Duration nanos invalid: N` (`ValueError`) | A well-known type holds a value outside what Protobuf allows. | Check the value before converting. |
| `Any holds X, not Y` (`ProtobufError`) | `unpack` asked for another type than the `Any` holds. | Test with `isA` first. |
| `not a JSON object` (`ValueError`) | `Struct` is made from a `JsonNode` that is not an object. | Pass an object. |
| `a FileDescriptorProto without a name` | `addFileDescriptor` got bytes that are not a file descriptor. | Pass the constant `fileDescriptorProto` of the generated module. |
| `response HEADERS already sent`, `response already ended`, `stream N: body already ended`, `stream N has no open body`, `stream N body already ended` (`H2Error`) | The program used the HTTP/2 layer out of order: headers twice, data after the end. | Only seen with `nimgrpc/h2` used directly; report it if the gRPC API raises it. |
| `nghttp2_session_callbacks_new failed`, `nghttp2_option_new failed`, `WHAT: REASON` from nghttp2 | nghttp2 refused a call, in practice for lack of memory. | Report it with the text. |

Not here? Search [upgrading.md](upgrading.md) for the version you moved to, then
[faq.md](faq.md), then open an issue with the message, the version and how to see it again.
