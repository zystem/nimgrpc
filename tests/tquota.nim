## The limits that depend on the kind of a method: `Limits.maxStreamingCalls` (the streaming
## handlers that may run at once, so that they leave workers for the unary calls) and
## `Limits.maxStreamingCallMs` (how long a streaming call may last, in place of `maxCallMs`),
## on the blocking and on the chronos server.

import std/[unittest, os, monotimes, times]
import pkg/chronos
import nimgrpc
import nimgrpc/[asyncclient, asyncserver]
from nimgrpc/client as bc import nil

proc echoUnary(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req

proc quiet(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ## Waits for a message that never comes: a streaming handler that holds its worker.
  var msg: seq[byte]
  discard call.recv(msg)

proc codeOf(f: proc () {.raises: [CatchableError].}): StatusCode =
  try:
    f()
    scOk
  except GrpcError as e: e.code
  except CatchableError: scUnknown

proc recvCode(ch: GrpcChannel; timeoutMs = -1): (StatusCode, int64) =
  ## The status a streaming call to /t.T/Quiet ends with, and after how long.
  var call = bc.newCall(ch, "/t.T/Quiet", timeoutMs = timeoutMs)
  let t0 = getMonoTime()
  var msg: seq[byte]
  let code = codeOf(proc () = discard bc.recv(call, msg))
  let ms = (getMonoTime() - t0).inMilliseconds
  bc.close(call)
  (code, ms)

suite "maxStreamingCalls (blocking server)":
  test "past the quota a streaming call is answered at once, and unary calls still have workers":
    let srv = newGrpcServer(maxWorkers = 4, limits = Limits(maxStreamingCalls: 2))
    srv.addStreaming("/t.T/Quiet", quiet)
    srv.addUnary("/t.T/Echo", echoUnary)
    srv.start()
    defer: srv.stop()
    let ch = bc.dial("127.0.0.1", srv.port)
    defer: ch.close()
    var a = bc.newCall(ch, "/t.T/Quiet")
    var b = bc.newCall(ch, "/t.T/Quiet")
    sleep(300)                                    # both handlers are running
    let (code, ms) = recvCode(ch, timeoutMs = 5000)
    check code == scResourceExhausted
    check ms < 1000                               # at once, not at the deadline
    check srv.stats().refusedStreaming == 1
    check srv.stats().runningStreaming == 2
    # the third did not take a worker: unary calls are served as before
    for i in 0 ..< 10:
      check bc.unaryCall(ch, "/t.T/Echo", @[1'u8], timeoutMs = 3000).message == @[1'u8]
    bc.close(a)                                   # a handler ends: its place is free again
    sleep(300)
    let (code2, _) = recvCode(ch, timeoutMs = 400)
    check code2 == scDeadlineExceeded              # accepted: it waited for its own deadline
    bc.close(b)

  test "0 is no quota":
    let srv = newGrpcServer(maxWorkers = 8)
    srv.addStreaming("/t.T/Quiet", quiet)
    srv.start()
    defer: srv.stop()
    let ch = bc.dial("127.0.0.1", srv.port)
    defer: ch.close()
    var calls: seq[bc.ClientCall]
    for i in 0 ..< 5: calls.add bc.newCall(ch, "/t.T/Quiet")
    sleep(300)
    let (code, _) = recvCode(ch, timeoutMs = 300)
    check code == scDeadlineExceeded
    for c in calls.mitems: bc.close(c)

suite "maxStreamingCallMs (blocking server)":
  proc server(limits: Limits): GrpcServer =
    result = newGrpcServer(limits = limits)
    result.addStreaming("/t.T/Quiet", quiet)
    result.start()

  test "it replaces maxCallMs for streaming calls: shorter":
    let srv = server(Limits(maxStreamingCallMs: 250))
    defer: srv.stop()
    let ch = bc.dial("127.0.0.1", srv.port)
    defer: ch.close()
    let (code, ms) = recvCode(ch, timeoutMs = 5000)   # a deadline far past the server's limit
    check code == scCancelled                      # reset by the server, as with maxCallMs
    check ms >= 200 and ms < 2000

  test "it replaces maxCallMs for streaming calls: longer":
    let srv = server(Limits(maxCallMs: 200, maxStreamingCallMs: 700))
    defer: srv.stop()
    let ch = bc.dial("127.0.0.1", srv.port)
    defer: ch.close()
    let (code, ms) = recvCode(ch, timeoutMs = 5000)
    check code == scCancelled
    check ms >= 600 and ms < 3000                  # not at 200

  test "-1: streaming calls have no limit, whatever maxCallMs is":
    let srv = server(Limits(maxCallMs: 200, maxStreamingCallMs: -1))
    defer: srv.stop()
    let ch = bc.dial("127.0.0.1", srv.port)
    defer: ch.close()
    let (code, ms) = recvCode(ch, timeoutMs = 800)  # only its own deadline ends it
    check code == scDeadlineExceeded
    check ms >= 700

  test "0: maxCallMs applies to streaming calls too":
    let srv = server(Limits(maxCallMs: 250))
    defer: srv.stop()
    let ch = bc.dial("127.0.0.1", srv.port)
    defer: ch.close()
    let (code, ms) = recvCode(ch, timeoutMs = 5000)
    check code == scCancelled
    check ms >= 200 and ms < 2000

suite "the same limits on the chronos server":
  proc quietAsync(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
    discard await call.recv()

  proc run(port: int; timeoutMs: int): Future[(StatusCode, int64)] {.async.} =
    let ch = await dialAsync("127.0.0.1", port)
    let call = await ch.newCall("/t.T/Quiet", timeoutMs = timeoutMs)
    let t0 = Moment.now()
    var code = scOk
    try: discard await call.recv()
    except GrpcError as e: code = e.code
    let ms = (Moment.now() - t0).milliseconds
    call.close()
    await ch.close()
    return (code, ms)

  test "maxStreamingCalls: the third streaming call is answered at once":
    let srv = newAsyncGrpcServer(limits = Limits(maxStreamingCalls: 2))
    srv.addStreaming("/t.T/Quiet", quietAsync)
    srv.start()
    defer: waitFor srv.stop()
    proc scenario(port: int): Future[(StatusCode, int64)] {.async.} =
      let ch = await dialAsync("127.0.0.1", port)
      let a = await ch.newCall("/t.T/Quiet")
      let b = await ch.newCall("/t.T/Quiet")
      await sleepAsync(chronos.milliseconds(300))
      let c = await ch.newCall("/t.T/Quiet", timeoutMs = 5000)
      let t0 = Moment.now()
      var code = scOk
      try: discard await c.recv()
      except GrpcError as e: code = e.code
      let ms = (Moment.now() - t0).milliseconds
      a.close(); b.close(); c.close()
      await ch.close()
      return (code, ms)
    let (code, ms) = waitFor scenario(srv.port)
    check code == scResourceExhausted
    check ms < 1000
    check srv.stats().refusedStreaming == 1

  test "maxStreamingCallMs replaces maxCallMs, and -1 lifts it":
    let shorter = newAsyncGrpcServer(limits = Limits(maxStreamingCallMs: 250))
    shorter.addStreaming("/t.T/Quiet", quietAsync)
    shorter.start()
    let (code, ms) = waitFor run(shorter.port, 5000)
    check code == scCancelled
    check ms >= 200 and ms < 2000
    waitFor shorter.stop()
    let lifted = newAsyncGrpcServer(limits = Limits(maxCallMs: 200, maxStreamingCallMs: -1))
    lifted.addStreaming("/t.T/Quiet", quietAsync)
    lifted.start()
    let (code2, ms2) = waitFor run(lifted.port, 800)
    check code2 == scDeadlineExceeded
    check ms2 >= 700
    waitFor lifted.stop()
