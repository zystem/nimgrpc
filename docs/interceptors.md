# Run code around every call

A how-to: check a token, log or time every call, or add metadata to every call, in one place instead of in each handler or at each call site. An **interceptor** is a procedure the library runs around each call; it decides whether the call goes on (it calls `proceed`) or is refused (it raises `GrpcError`). A program that adds none pays nothing: no interceptor runs and no code is added to the call path except a test of an empty list.

[examples/interceptors.nim](../examples/interceptors.nim) is a whole program that does all of this; its output is in step 6 of [examples/README.md](../examples/README.md). The samples below were compiled and run as parts of programs (see "What was run").

## On a blocking server

An interceptor is a `nimcall` procedure with the same pragmas as a handler. It gets the `ServerContext`, the `next` object and the `userData` pointer given to `addInterceptor`:

```nim
import nimgrpc

proc checkToken(ctx: var ServerContext; next: ServerNext; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  let token = cast[ptr string](userData)[]
  if ctx.metadata.get("authorization") != "Bearer " & token:
    raise newGrpcError(scUnauthenticated, "missing or wrong token")
  next.proceed(ctx)

var token = "s3cret"                     # must stay valid while the server runs
srv.addInterceptor(checkToken, token.addr)   # before srv.start()
```

To do something after the call (log it, time it), catch what `proceed` raises into a variable and raise it again after the `except` block. Do not use `finally` or `defer`: Nim 2.2.12 and 2.2.14 can lose an exception that passes through them ([nim-compiler-notes.md](nim-compiler-notes.md)).

```nim
proc logCalls(ctx: var ServerContext; next: ServerNext; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var failure: ref CatchableError
  try:
    next.proceed(ctx)
  except CatchableError as e:        # not `finally`
    failure = e
  let code = if failure == nil: scOk
             elif failure of GrpcError: (ref GrpcError)(failure).code
             else: scUnknown
  echo "log: ", ctx.path, " ", code
  if failure != nil: raise failure   # outside the `except` block
```

With `logCalls` added first (so it is the outermost) and `checkToken` second, a call with the token and then one without print these two lines (the sample program prints other lines too; they are left out):

```console
log: /demo.Echo/Say scOk
log: /demo.Echo/Say scUnauthenticated
```

The server's interceptors run on the worker thread of each call, at the same time for different calls, so a procedure and what its `userData` points to must be thread-safe. A closure cannot be one.

## On a chronos server

An interceptor is a closure that returns a future, and `next` is a proc that returns one:

```nim
import pkg/chronos
import nimgrpc/asyncserver

srv.addInterceptor proc (ctx: AsyncServerContext; next: AsyncServerNext) {.async.} =
  if ctx.metadata.get("authorization") != "Bearer " & token:
    raise newGrpcError(scUnauthenticated, "missing or wrong token")
  await next()
```

It runs on the event loop's thread, so it needs no lock. It is cancelled together with the handler when the call is over for the client (cancel, deadline, lost connection), so code after `await next()` may not run then.

## On a client

A client interceptor sees the call before it is sent. It may change `info.metadata` and `info.timeoutMs`:

```nim
proc addToken(info: var ClientCallInfo; next: ClientNext; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  info.metadata.add ("authorization", "Bearer " & cast[ptr string](userData)[])
  next.proceed(info)

ch.addInterceptor(addToken, token.addr)   # any time; affects the calls made after it
```

The interceptors of a blocking channel run on the thread that makes the call, so a channel shared by threads needs thread-safe ones. On chronos they are closures:

```nim
import nimgrpc/asyncclient

ch.addInterceptor proc (info: AsyncCallInfo; next: AsyncClientNext) {.async.} =
  info.metadata.add ("authorization", "Bearer " & token)
  await next()
```

## What the rules are

Server and client:

- **Order.** The interceptor added first is the outermost: it runs first before the call and last after it.
- **One `proceed`.** An interceptor calls `proceed` (`next()` on chronos) once, or raises `GrpcError` to refuse the call. Raising before `proceed` on a client gives the caller the error and sends nothing.
- **Errors go out through `proceed`.** `proceed` raises what the handler (or the call) raised.
- **A swallowed error stays.** An interceptor that catches the error of the call and returns normally does not turn the call into OK: the original error is used. One that raises a different `GrpcError` replaces it.
- **Returning without `proceed`.** The caller gets INTERNAL `an interceptor returned without calling proceed`, and the handler did not run.
- **A second `proceed`.** It raises INTERNAL `an interceptor called proceed twice` and nothing runs twice.
- **Other exceptions.** On a server, an exception that is not a `GrpcError` is treated like one from a handler: the client gets UNKNOWN `internal error` and `setErrorHook` gets the exception.
- **No `finally`.** Nim 2.2.12 and 2.2.14 can lose an exception that passes through `finally` or `defer`. The library still ends the call with the right status if an interceptor loses the error this way (the "swallowed error" rule), but the interceptor itself would act as if the call had succeeded.
- **`userData`.** `addInterceptor` of the blocking server and channel takes a `pointer` (nil by default) and gives it back to the procedure; on chronos a closure holds what it needs.

On a server:

- **Which calls.** An interceptor runs around every call to a registered method, the health and reflection services too (tell them by `ctx.path`). A call that fails before the method is found does not reach it: an unknown method, an unsupported `grpc-encoding`, a malformed `grpc-timeout`, a wrong HTTP method or content type.
- **When.** It runs before the request message is decoded. It reads `ctx.path`, `ctx.metadata`, `ctx.timeoutMs` and `ctx.remainingMs`. It may set `ctx.trailers` before or after `proceed`, and `ctx.headers` only before it (after it the response has been sent).
- **When `proceed` returns.** When the handler has returned and its response has been sent.
- **Before `start`.** Add interceptors before `srv.start()`; later is an assertion failure.
- **A refused call was still received.** On the blocking server a unary call gets its worker only once its request message has arrived (up to `maxMessage`), so refusing it in an interceptor does not save the server from receiving it ([newGrpcServer](../src/nimgrpc/server.nim)). On chronos the interceptor runs as soon as the request headers arrive.

On a client:

- **Which calls.** Every `unaryCall` and `newCall` on the channel, so also the calls of generated clients (`typed`, `asynctyped`) and of the health client. Interceptors added later affect later calls.
- **Unary calls** (`info.streaming == false`): `proceed` returns when the call has ended with OK, and then `info.headers` and `info.trailers` are filled; it raises the error of the call otherwise. The interceptor runs once around the whole call, also when the library sends a refused call again.
- **Streaming calls** (`info.streaming == true`): `proceed` returns when the stream is open. The interceptor sees neither the messages nor the final status.

## What an interceptor cannot do

- Read or change a message, the request or the response. It sees no messages (for a stream either).
- Run for one method only: test `ctx.path` (server) or `info.path` (client) and call `proceed` at once for the others.
- See the peer's certificate or address, so it can authenticate by metadata only. Mutual TLS decides who may connect, but not which client a call is from ([threat-model.md](threat-model.md)).
- Set `ctx.headers` after `proceed`, or `proceed` twice.
- Run for a call that failed before its method was found (the list under "Which calls").
- Be a closure on a blocking server or channel.

## What was run

On 2026-11-16 (Linux x86-64, Nim 2.4.0, nghttp2 1.68.0): `examples/interceptors.nim` and the blocking and chronos samples above, each as part of a program that serves and calls over loopback. They printed what is shown, and the example's output was the same on ten runs. The rules were read from the source, and a smoke program of the blocking and one of the chronos server and client (a swallowed error, no `proceed`, a second `proceed`, order, trailers, a streaming call, an unknown method) were run again. `tests/tinterceptors.nim` (51 tests: every rule above on the blocking and the chronos side, a generated client and a health check through interceptors, one channel with an interceptor on four threads) passed on the same day and machine. Not run locally: Nim 2.2.x and AddressSanitizer (CI runs both), a server behind TLS.
