# gRPC on chronos

`nimgrpc/asyncclient`, `nimgrpc/asyncserver` and `nimgrpc/asynctyped` are the
[chronos](https://github.com/status-im/nim-chronos) twins of the blocking API.
They run on the same HTTP/2 core, TLS engine, codec and gzip; only the I/O
adapter differs (`nimgrpc/h2/async`).

## When to use which

| | blocking (`nimgrpc`) | chronos (`nimgrpc/asynctyped`) |
|:---|:---|:---|
| Per connection | a reader and a writer task on a shared thread pool | three futures on the event loop |
| Per call (server) | a worker thread for as long as the handler runs | a future |
| Handler code | ordinary blocking code | `{.async.}` procs; must not block the loop |
| Cancellation | the handler polls `ctx.isCancelled` / `ctx.sleep` | the handler future is cancelled |
| Sharing | channels can be used from many threads | everything stays on the loop's thread |

The blocking API is simpler to call from ordinary code, and a server with tens
or hundreds of concurrent calls costs a few threads. The chronos API is for
thousands of connections or calls, or for programs that already run on chronos.
The two speak the same protocol and interoperate in both directions.

## Server

```nim
import pkg/chronos
import nimgrpc/asynctyped, gen/helloworld_pb      # generated with --nim_opt=async

proc sayHello(ctx: AsyncServerContext; req: HelloRequest): Future[HelloReply] {.async.} =
  await sleepAsync(10.milliseconds)            # cancelled if the call ends first
  return HelloReply(message: "Hello, " & req.name)

let srv = newAsyncGrpcServer(port = 50051)
srv.registerGreeter(GreeterAsyncHandlers(sayHello: sayHello))
srv.start()
runForever()
```

Handlers are closures, so they may capture state. Streaming handlers get
`AsyncServerWriter` / `AsyncServerReader` / `AsyncServerBidi`; `recv` returns
`Option[T]` (`none` at the end of the stream).

Untyped, on message bytes:

```nim
proc echo(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
  while true:
    let m = await call.recv()
    if m.isNone: break
    await call.send(m.get)

srv.addStreaming("/demo.Chat/Talk", echo)
```

A handler ends the call by completing (OK) or by failing with GrpcError;
any other error becomes UNKNOWN with the message `internal error` (the text
of the error is not sent to the client; `srv.setErrorHook(hook)`, set before
`start`, receives the method path and the error). `ctx.headers`, `ctx.trailers`,
`ctx.responseCompression`, `ctx.metadata` and `ctx.timeoutMs` work as in the
blocking server.

`await srv.stop(graceMs = 5000)` sends GOAWAY, lets running calls finish for
up to 5 s, then cancels the rest.

## Cancellation

When a call is over for the client (it cancelled, its deadline passed, the
connection dropped, the server stopped), the handler's future is cancelled.
Whatever it awaits at that moment fails with `CancelledError`, so a handler
waiting on a timer, a database or another RPC stops at once, with no polling.
Code that runs for a long time between awaits can still check
`ctx.isCancelled` or call `ctx.checkCancelled()`.

A handler that wants to clean up catches `CancelledError`, does so, and
re-raises it.

## Client

```nim
proc main() {.async.} =
  let ch = await dialAsync("127.0.0.1", 50051)
  let greeter = newGreeterAsyncClient(ch)
  echo (await greeter.sayHello(HelloRequest(name: "Nim"), timeoutMs = 1000)).message

  # Many calls at once share the channel's connection:
  var fs: seq[Future[HelloReply]]
  for i in 0 ..< 1000:
    fs.add greeter.sayHello(HelloRequest(name: $i))
  await allFutures(fs)
  await ch.close()

waitFor main()
```

Streaming calls return `AsyncClientReader` / `AsyncClientWriter` /
`AsyncClientBidi`; untyped calls use `ch.newCall`, `send`, `closeSend` and
`recv`. A channel redials after its connection closes or the server sends
GOAWAY, as in the blocking client; concurrent calls that need a new
connection share one dial.

TLS, mutual TLS, gzip and keepalive take the same arguments as in the
blocking API (`dialAsync(host, port, tlsClientConfig(...), serverName,
keepalive)`, `newAsyncGrpcServer(..., tls, keepalive, pingPolicy)`).

## Code generation

```sh
protoc --plugin=protoc-gen-nim=... --nim_out=gen --nim_opt=async -Iproto a.proto
```

`--nim_opt` takes a comma-separated list: `blocking` (the default), `async`,
or `blocking,async` for both. With `async` a service `S` gets
`SAsyncClient`, `newSAsyncClient`, `SAsyncHandlers` and an overload of
`registerS` for `AsyncGrpcServer`. Message types are the same either way.

## Rules

- Everything (channels, calls, servers) belongs to the thread that runs the
  event loop. Run one loop per thread if you need several.
- Never block in a handler: `os.sleep`, blocking sockets or long CPU work stall
  every connection on the loop. Use chronos' async I/O, or hand the work to a
  thread and await the result.
- `send` waits while the stream already has 256 KiB unsent, so a slow peer
  slows the sender instead of filling memory.

## Numbers

Linux x86-64, `-d:release`, one thread (`tools/asyncload.nim`):

- Server RSS with 1,000 connections, each with a bidirectional call open:
  40 MiB; with 5,000: 190 MiB. About 38 KiB per connection with an open call,
  of which about 9 KiB is the nghttp2 session and 4 KiB chronos' read buffer.
  With TLS about 75 KiB (BearSSL's two 16 KiB record buffers live in each
  connection). `.github/workflows/soak.yml` repeats the measurement each week
  (`tools/soak.sh`, plain and TLS) and fails when it passes 60 and 100 KiB, or when
  the server's memory or descriptors grow during connection churn.
- Where it goes (heaptrack, `tools/profile.sh`, weekly in `.github/workflows/profile.yml`;
  1000 held connections, peak heap about 41 KiB each without TLS): 16 KiB is nghttp2's frame
  buffer, allocated with each session whether or not it is used; about 12 KiB is Nim
  sequences (read and write buffers and queues); about 5 KiB Nim objects (futures, streams,
  the connection); 2.8 KiB the nghttp2 session itself; 1 KiB each for the HPACK encoder
  and decoder tables. With TLS the connection grows to about 84 KiB, of which 40 KiB is
  the BearSSL engine and its two record buffers (`gtls_conn`, `src/nimgrpc/tls/gtls.c`).
  The frame buffer and the TLS record buffers are the two places to save memory.
  The connection reads straight from that buffer, with no buffer of its own.
- 5,000 concurrent unary calls on one channel, and 1,000 concurrent streams on
  one connection, from one thread (`tests/tasyncgrpc.nim`, `tests/tasynch2.nim`).
- h2spec against `tools/h2specasync`: 134 of 146 passed; see
  [h2spec.md](h2spec.md).
- Interop: every case in every direction and mode, including against grpc-go
  ([interop.md](interop.md)).
