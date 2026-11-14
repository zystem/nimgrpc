## Clients that hold on to what a server gives them: calls opened and left without a message,
## streaming calls that go quiet, many Watch calls, many connections from one address.

import std/[unittest, os, monotimes, times, typedthreads, options]
import pkg/chronos
import nimgrpc
import nimgrpc/[health, healthclient, reflection]
import nimgrpc/[asyncclient, asyncserver]
from nimgrpc/client as bc import nil
from nimgrpc/h2/blocking as h2 import nil

proc echoUnary(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req

proc quiet(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ## A streaming call that waits for a message that never comes.
  var msg: seq[byte]
  discard call.recv(msg)

proc grpcHeaders(port: int; path: string): seq[h2.Header] =
  @[(":method", "POST"), (":scheme", "http"), (":authority", "127.0.0.1:" & $port),
    (":path", path), ("content-type", "application/grpc"), ("te", "trailers")]

proc codeOf(f: proc () {.raises: [CatchableError].}): StatusCode =
  try:
    f()
    scOk
  except GrpcError as e: e.code
  except CatchableError: scUnknown

suite "the blocking server and calls left without a message":
  test "unary calls that never send their message use no worker":
    let srv = newGrpcServer(maxWorkers = 2)
    srv.addUnary("/t.T/Echo", echoUnary)
    srv.start()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    var held: seq[h2.ClientStream]
    for i in 0 ..< 20:                       # ten times the workers
      held.add h2.openStream(raw, grpcHeaders(srv.port, "/t.T/Echo"))
    sleep(200)
    let ch = bc.dial("127.0.0.1", srv.port)
    let t0 = getMonoTime()
    check bc.unaryCall(ch, "/t.T/Echo", @[1'u8, 2, 3], timeoutMs = 3000).message == @[1'u8, 2, 3]
    check (getMonoTime() - t0).inMilliseconds < 1000
    for st in held.mitems: h2.release(st)
    ch.close()
    h2.close(raw)
    srv.stop()

  test "large unary messages still arrive whole, several at once on one connection":
    # each is larger than a stream window, together they are larger than what a connection
    # may hold unread: the calls that wait for their bodies must not wait for ever
    let srv = newGrpcServer()
    srv.addUnary("/t.T/Echo", echoUnary)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    type Arg = tuple[ch: GrpcChannel; n: ptr int]
    proc big(a: Arg) {.thread.} =
      try: a.n[] = bc.unaryCall(a.ch, "/t.T/Echo", newSeq[byte](3_500_000), timeoutMs = 20_000).message.len
      except CatchableError: a.n[] = -1
    var ths: array[5, Thread[Arg]]
    var ns: array[5, int]
    for i in 0 ..< ths.len: createThread(ths[i], big, (ch, ns[i].addr))
    joinThreads(ths)
    check ns == [3_500_000, 3_500_000, 3_500_000, 3_500_000, 3_500_000]
    ch.close()
    srv.stop()

  test "a message over the limit is still refused":
    let srv = newGrpcServer(maxMessage = 100_000)
    srv.addUnary("/t.T/Echo", echoUnary)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    check codeOf(proc () = discard bc.unaryCall(ch, "/t.T/Echo", newSeq[byte](300_000),
                                                timeoutMs = 5000)) == scResourceExhausted
    check bc.unaryCall(ch, "/t.T/Echo", @[7'u8], timeoutMs = 3000).message == @[7'u8]
    ch.close()
    srv.stop()

suite "Limits.maxCallMs":
  test "blocking: a streaming call that goes quiet is reset (the client sees CANCELLED)":
    let srv = newGrpcServer(limits = Limits(maxCallMs: 300))
    srv.addStreaming("/t.T/Quiet", quiet)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    var call = bc.newCall(ch, "/t.T/Quiet")          # no deadline of its own
    let t0 = getMonoTime()
    var msg: seq[byte]
    check codeOf(proc () = discard bc.recv(call, msg)) == scCancelled
    let ms = (getMonoTime() - t0).inMilliseconds
    check ms >= 250
    check ms < 2000
    bc.close(call)
    ch.close()
    srv.stop()

  test "chronos: the same":
    proc quietAsync(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
      discard await call.recv()
    let srv = newAsyncGrpcServer(limits = Limits(maxCallMs: 300))
    srv.addStreaming("/t.T/Quiet", quietAsync)
    srv.start()
    proc run(port: int): Future[(StatusCode, int64)] {.async.} =
      let ch = await dialAsync("127.0.0.1", port)
      let call = await ch.newCall("/t.T/Quiet")
      let t0 = Moment.now()
      var code = scOk
      try: discard await call.recv()
      except GrpcError as e: code = e.code
      let ms = (Moment.now() - t0).milliseconds
      call.close()
      await ch.close()
      return (code, ms)
    let (code, ms) = waitFor run(srv.port)
    check code == scCancelled
    check ms >= 250
    check ms < 2000
    waitFor srv.stop()

suite "the built-in services do not use the workers up":
  test "health: one Watch more than maxWatches is RESOURCE_EXHAUSTED; a slot that is freed is given again":
    let h = newHealth(maxWatches = 2)
    let srv = newGrpcServer()
    srv.register(h)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    var w1 = ch.watchHealth()
    var w2 = ch.watchHealth()
    check w1.next() == some(hsServing)
    check w2.next() == some(hsServing)
    var w3 = ch.watchHealth()
    check codeOf(proc () = discard w3.next()) == scResourceExhausted
    w3.close()
    check ch.isServing()                       # Check is not a Watch
    w1.close()
    var again = false
    for attempt in 0 ..< 30:                   # the server notices within a poll
      var w4 = ch.watchHealth()
      let ok = codeOf(proc () = discard w4.next()) == scOk
      w4.close()
      if ok:
        again = true
        break
      sleep(100)
    check again
    w2.close()
    ch.close()
    srv.stop()
    h.close()

  test "reflection: one call more than maxStreams is RESOURCE_EXHAUSTED":
    let r = newReflection(maxStreams = 1)
    let srv = newGrpcServer()
    srv.register(r)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    const path = "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo"
    const listServices = [0x3a'u8, 0x00]       # list_services = ""
    var a = bc.newCall(ch, path)
    bc.send(a, listServices)
    var msg: seq[byte]
    check bc.recv(a, msg)                      # the first call holds the only slot
    var b = bc.newCall(ch, path)
    bc.send(b, listServices)
    check codeOf(proc () = discard bc.recv(b, msg)) == scResourceExhausted
    bc.close(b)
    bc.close(a)
    ch.close()
    srv.stop()
    r.close()

suite "Limits.maxConnectionsPerIp":
  test "blocking: the third connection of an address is closed; a freed place is given again":
    let srv = newGrpcServer(limits = Limits(maxConnectionsPerIp: 2))
    srv.addUnary("/t.T/Echo", echoUnary)
    srv.start()
    proc works(): bool =
      try:
        let ch = bc.dial("127.0.0.1", srv.port)
        defer: ch.close()
        bc.unaryCall(ch, "/t.T/Echo", @[1'u8], timeoutMs = 2000).message == @[1'u8]
      except CatchableError: false
    let a = bc.dial("127.0.0.1", srv.port)
    let b = bc.dial("127.0.0.1", srv.port)
    check bc.unaryCall(a, "/t.T/Echo", @[1'u8], timeoutMs = 2000).message == @[1'u8]
    check bc.unaryCall(b, "/t.T/Echo", @[1'u8], timeoutMs = 2000).message == @[1'u8]
    check not works()
    a.close()
    var served = false
    for attempt in 0 ..< 50:                   # a closed connection is reaped at the next accept
      if works():
        served = true
        break
      sleep(100)
    check served
    b.close()
    srv.stop()

  test "chronos: the same":
    proc asyncEcho(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} = return req
    let srv = newAsyncGrpcServer(limits = Limits(maxConnectionsPerIp: 2))
    srv.addUnary("/t.T/Echo", asyncEcho)
    srv.start()
    proc run(port: int): Future[(bool, bool, bool)] {.async.} =
      proc works(): Future[bool] {.async.} =
        try:
          let ch = await dialAsync("127.0.0.1", port)
          let r = await ch.unaryCall("/t.T/Echo", @[1'u8], timeoutMs = 2000)
          await ch.close()
          return r.message == @[1'u8]
        except CatchableError: return false
      let a = await dialAsync("127.0.0.1", port)
      let b = await dialAsync("127.0.0.1", port)
      let both = (await a.unaryCall("/t.T/Echo", @[1'u8], timeoutMs = 2000)).message == @[1'u8] and
                 (await b.unaryCall("/t.T/Echo", @[1'u8], timeoutMs = 2000)).message == @[1'u8]
      let third = await works()
      await a.close()
      var served = false
      for attempt in 0 ..< 50:
        if await works():
          served = true
          break
        await sleepAsync(chronos.milliseconds(100))
      await b.close()
      return (both, third, served)
    let (both, third, served) = waitFor run(srv.port)
    check both
    check not third
    check served
    waitFor srv.stop()
