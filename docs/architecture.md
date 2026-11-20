# Architecture: actors and actions

What is in the system, who acts, and what each action does. Details: [threat-model.md](threat-model.md).

```
 caller code ── typed stubs (generated) ──┐
                                          ▼
                  nimgrpc/client.nim, nimgrpc/server.nim            (blocking API, threads)
                  nimgrpc/asyncclient.nim, asyncserver.nim       (chronos API, one thread)
                         │ gRPC: framing, status, metadata, deadlines, gzip
                         ▼
                  nimgrpc/h2/blocking.nim | nimgrpc/h2/async.nim    (I/O adapters, TLS, keepalive)
                         │ bytes in, bytes out, events
                         ▼
                  nimgrpc/h2/session.nim ──── nghttp2 (C, static)    TLS: BearSSL    gzip: zlib
```

The HTTP/2 session (`h2/session.nim`) never touches a socket: bytes go in, bytes and events come out, so the blocking adapter, the chronos adapter and the tests all drive it the same way.

## Actors

| Actor | Is | May |
|---|---|---|
| Program | the user's code that links the library | open channels, make calls, register handlers, start and stop a server |
| Peer | the other end of a connection | send HTTP/2 frames; see [threat-model.md](threat-model.md) |
| Developer | runs `protoc-gen-nim` | turn `.proto` files into Nim source |
| Maintainer | the owner of the repository | merge and tag |

## Actions

| Action | By | What happens |
|---|---|---|
| Unary / streaming call | program | headers and length-prefixed messages go out on a stream; replies and trailers (`grpc-status`) come back; a deadline resets the stream on the client; on a server the call ends with DEADLINE_EXCEEDED in trailers |
| Serve | program | a listener accepts connections; each request stream runs a handler; unset methods answer `UNIMPLEMENTED` |
| Cancel | either side | RST_STREAM; the handler sees `ctx.isCancelled` |
| Keepalive, GOAWAY, shutdown | library | pings on idle connections, graceful drain on stop, reconnecting channels |
| Generate code | developer | `protoc` runs the plugin, which writes message types, client stubs and server handler sets |
