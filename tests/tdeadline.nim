## What a client sees when the deadline it sent (the `grpc-timeout` header) passes on the server:
## the status DEADLINE_EXCEEDED, in trailers, not a reset of the stream. A reset says only
## CANCELLED, and gRPC's C core reports that, not DEADLINE_EXCEEDED, when the reset reaches it
## before its own timer (found with its Python interop client, `timeout_on_sleeping_server`).
## The raw HTTP/2 clients here send the header and never enforce the deadline themselves.

import std/[unittest, monotimes, times]
import pkg/chronos
import nimgrpc
import nimgrpc/asyncserver
from nimgrpc/h2/blocking as h2 import nil
from nimgrpc/h2/async as ah2 import nil

proc grpcHeaders(port: int; path, timeout: string): seq[h2.Header] =
  @[(":method", "POST"), (":scheme", "http"), (":authority", "127.0.0.1:" & $port),
    (":path", path), ("content-type", "application/grpc"), ("te", "trailers"),
    ("grpc-timeout", timeout)]

proc statusOf(hs: seq[h2.Header]): string =
  for (k, v) in hs:
    if k == "grpc-status": return v

proc quiet(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ## Waits for a message that never comes.
  var msg: seq[byte]
  discard call.recv(msg)

proc answerThenQuiet(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ## Sends a message (so the response HEADERS are out), then waits for one that never comes.
  call.send(@[1'u8])
  var msg: seq[byte]
  discard call.recv(msg)

proc runBlocking(port: int; path: string; thenTrailers: bool): (string, string, int64) =
  ## The status of the response HEADERS and, with `thenTrailers`, of the trailers; how long
  ## it took. A reset stream (or any failure) comes back as "error: ...", so the checks fail
  ## on it instead of the test stopping.
  let raw = h2.dial("127.0.0.1", Port(port))
  var st = h2.openStream(raw, grpcHeaders(port, path, "300m"), timeoutMs = 5000)
  let t0 = getMonoTime()
  var first, last = ""
  try:
    first = statusOf(h2.recvHeaders(st))
    if thenTrailers: last = statusOf(h2.recvTrailers(st))
  except CatchableError as e:
    first = "error: " & e.msg
  let ms = (getMonoTime() - t0).inMilliseconds
  h2.release(st)
  h2.close(raw)
  (first, last, ms)

suite "the client's deadline passes on the blocking server":
  test "no response yet: trailers-only DEADLINE_EXCEEDED, the stream is not reset":
    let srv = newGrpcServer()
    srv.addStreaming("/t.T/Quiet", quiet)
    srv.start()
    defer: srv.stop()
    let (first, _, ms) = runBlocking(srv.port, "/t.T/Quiet", false)
    check first == "4"
    check ms >= 250
    check ms < 2000

  test "a response has begun: the trailers say DEADLINE_EXCEEDED":
    let srv = newGrpcServer()
    srv.addStreaming("/t.T/AnswerThenQuiet", answerThenQuiet)
    srv.start()
    defer: srv.stop()
    let (first, last, ms) = runBlocking(srv.port, "/t.T/AnswerThenQuiet", true)
    check first == ""                        # the response HEADERS: no status yet
    check last == "4"
    check ms >= 250

suite "the client's deadline passes on the chronos server":
  proc quietAsync(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
    discard await call.recv()

  proc answerThenQuietAsync(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
    await call.send(@[1'u8])
    discard await call.recv()

  proc run(port: int; path: string; thenTrailers: bool): Future[(string, string, int64)] {.async.} =
    let raw = await ah2.dial("127.0.0.1", Port(port))
    let st = ah2.openStream(raw, grpcHeaders(port, path, "300m"), timeoutMs = 5000)
    let t0 = Moment.now()
    var first, last = ""
    try:
      first = statusOf(await ah2.recvHeaders(st))
      if thenTrailers: last = statusOf(await ah2.recvTrailers(st))
    except CatchableError as e:
      first = "error: " & e.msg           # a reset stream, say: the checks below fail
    let ms = (Moment.now() - t0).milliseconds
    ah2.release(st)
    await ah2.close(raw)
    return (first, last, ms)

  test "no response yet: trailers-only DEADLINE_EXCEEDED, the stream is not reset":
    let srv = newAsyncGrpcServer()
    srv.addStreaming("/t.T/Quiet", quietAsync)
    srv.start()
    defer: waitFor srv.stop()
    let (first, _, ms) = waitFor run(srv.port, "/t.T/Quiet", false)
    check first == "4"
    check ms >= 250
    check ms < 2000

  test "a response has begun: the trailers say DEADLINE_EXCEEDED":
    let srv = newAsyncGrpcServer()
    srv.addStreaming("/t.T/AnswerThenQuiet", answerThenQuietAsync)
    srv.start()
    defer: waitFor srv.stop()
    let (first, last, ms) = waitFor run(srv.port, "/t.T/AnswerThenQuiet", true)
    check first == ""
    check last == "4"
    check ms >= 200
