## gRPC on chronos: async client and server, and both mixed with the
## blocking API.

import std/[unittest, strutils, typedthreads, atomics]
import pkg/chronos
import nimgrpc/[asyncclient, asyncserver]
from nimgrpc/client as bc import nil
import nimgrpc/decode
import ./gen/codec_pb

proc toBytes(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))
proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(result[0].addr, b[0].unsafeAddr, b.len)

# `check` cannot run inside async procs (its formatter raises Exception).
var failures: seq[string]
template ck(cond: untyped) =
  if not cond:
    {.cast(gcsafe).}:
      failures.add astToStr(cond) & " (line " & $instantiationInfo().line & ")"
template run(f: untyped) =
  failures = @[]
  waitFor f
  check failures == newSeq[string]()

template expectStatus(want: StatusCode; body: untyped) =
  block:
    var got = scOk
    try:
      body
    except GrpcError as e:
      got = e.code
    ck got == want

var cancelledHandlers = 0

proc echoUnary(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} =
  let s = req.toStr
  if s.startsWith("fail:"):
    ctx.trailers.add ("x-why", "asked")
    raise newGrpcError(scFailedPrecondition, s[5 .. ^1])
  if s == "boom": raise newException(ValueError, "not a grpc error")
  if s == "sleep":
    try:
      await sleepAsync(10.seconds)
    except CancelledError as e:
      inc cancelledHandlers
      raise e
  if s == "gzip": ctx.responseCompression = "gzip"
  let md = ctx.metadata.get("x-echo")
  if md.len > 0:
    ctx.headers.add ("x-echo", md)
    ctx.trailers.add ("x-echo-trailer", md)
  return s.toUpperAscii.toBytes

proc counter(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
  ## Bidi: replies to every message with its running index; then the total.
  var n = 0
  while true:
    let m = await call.recv()
    if m.isNone: break
    inc n
    await call.send(($n & ":" & m.get.toStr).toBytes)
  await call.send(("total " & $n).toBytes)

proc flood(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
  ## Server streaming: as many 1 KiB messages as the request says.
  let m = await call.recv()
  let n = parseInt(m.get.toStr)
  for i in 0 ..< n:
    await call.send(newSeq[byte](1024))

proc rawEcho(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} =
  return req

proc nodeName(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} =
  ## What a typed unary handler does with its request: decode, and INTERNAL if that fails.
  return decodeMsg[Node](req, scInternal).name.toBytes

proc refuse(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
  ## Ends the call at once, without reading the request.
  raise newGrpcError(scResourceExhausted, "no")

proc pattern(n, seed: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n: result[i] = byte((i * 31 + seed) and 0xff)

proc newTestServer(): AsyncGrpcServer =
  result = newAsyncGrpcServer(maxMessage = 16 * 1024 * 1024)
  result.addUnary("/t.S/Raw", rawEcho)
  result.addStreaming("/t.S/Refuse", refuse)
  result.addUnary("/t.S/Echo", echoUnary)
  result.addUnary("/t.S/NodeName", nodeName)
  result.addStreaming("/t.S/Counter", counter)
  result.addStreaming("/t.S/Flood", flood)
  result.start()

suite "async gRPC":
  var srv: AsyncGrpcServer
  setup:
    srv = newTestServer()
    cancelledHandlers = 0
  teardown:
    waitFor srv.stop()

  test "unary, metadata both ways":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      let r = await ch.unaryCall("/t.S/Echo", "hi".toBytes, @[("x-echo", "v")])
      ck r.message.toStr == "HI"
      ck r.headers.get("x-echo") == "v"
      ck r.trailers.get("x-echo-trailer") == "v"
      await ch.close()
    run go(srv)

  test "statuses: GrpcError, other errors, unknown method":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      var code = scOk
      var trailers: Metadata
      var msg = ""
      try:
        discard await ch.unaryCall("/t.S/Echo", "fail:nope".toBytes)
      except GrpcError as e:
        code = e.code
        msg = e.msg
        trailers = e.trailers
      ck code == scFailedPrecondition
      ck msg == "nope"
      ck trailers.get("x-why") == "asked"
      expectStatus(scUnknown):
        discard await ch.unaryCall("/t.S/Echo", "boom".toBytes)
      expectStatus(scUnimplemented):
        discard await ch.unaryCall("/t.S/Nope", "x".toBytes)
      await ch.close()
    run go(srv)

  test "a request of 100 000 nested groups is INTERNAL and the server goes on":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      var bomb: seq[byte]
      for i in 0 ..< 100_000: bomb.add [0xC3'u8, 0x3E]   # field 1000, start-group
      expectStatus(scInternal):
        discard await ch.unaryCall("/t.S/NodeName", bomb)
      let r = await ch.unaryCall("/t.S/NodeName", Node(name: "ok").encode)
      ck r.message.toStr == "ok"
      let e = await ch.unaryCall("/t.S/Echo", "hi".toBytes)
      ck e.message.toStr == "HI"
      await ch.close()
    run go(srv)

  test "deadline: client gets DEADLINE_EXCEEDED, handler is cancelled":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      let t0 = Moment.now()
      expectStatus(scDeadlineExceeded):
        discard await ch.unaryCall("/t.S/Echo", "sleep".toBytes, timeoutMs = 200)
      ck Moment.now() - t0 < 2.seconds
      await sleepAsync(100.milliseconds)
      ck cancelledHandlers == 1
      await ch.close()
    run go(srv)

  test "client cancel: handler is cancelled":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      let call = await ch.newCall("/t.S/Echo")
      await call.send("sleep".toBytes)
      await call.closeSend()
      await sleepAsync(100.milliseconds)
      call.cancel()
      expectStatus(scCancelled):
        discard await call.recv()
      await sleepAsync(100.milliseconds)
      ck cancelledHandlers == 1
      await ch.close()
    run go(srv)

  test "bidirectional streaming":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      let call = await ch.newCall("/t.S/Counter")
      for w in ["a", "b", "c"]:
        await call.send(w.toBytes)
        ck (await call.recv()).get.toStr.endsWith(":" & w)
      await call.closeSend()
      ck (await call.recv()).get.toStr == "total 3"
      ck (await call.recv()).isNone
      call.close()
      await ch.close()
    run go(srv)

  test "compression both ways":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      let call = await ch.newCall("/t.S/Echo", compression = "gzip")
      await call.send("gzip".toBytes)
      await call.closeSend()
      ck (await call.recv()).get.toStr == "GZIP"
      ck call.lastCompressed
      ck (await call.recv()).isNone
      call.close()
      await ch.close()
    run go(srv)

  test "messages larger than the stream buffer, alone and side by side":
    proc one(ch: AsyncChannel; n, seed: int) {.async.} =
      let want = pattern(n, seed)
      let got = await ch.unaryCall("/t.S/Raw", want, maxMessage = 16 * 1024 * 1024)
      ck got.message == want
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      await one(ch, 0, 1)
      await one(ch, 1, 2)
      await one(ch, 256 * 1024 - 5, 3)     # just under, exactly at and over the buffer
      await one(ch, 256 * 1024, 4)
      await one(ch, 256 * 1024 + 1, 5)
      await one(ch, 3 * 1024 * 1024 + 7, 6)
      var fs: seq[Future[void]]
      for i in 0 ..< 8: fs.add one(ch, 300_000 + i * 250_001, 10 + i)
      await allFutures(fs)
      await ch.close()
    run go(srv)

  test "a large compressed message in both directions":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      let call = await ch.newCall("/t.S/Raw", compression = "gzip",
                                  maxMessage = 16 * 1024 * 1024)
      let want = newSeq[byte](2 * 1024 * 1024)      # compresses well
      await call.send(want)
      await call.closeSend()
      ck (await call.recv()).get == want
      ck call.lastCompressed == false or call.lastCompressed    # the server decides
      call.close()
      await ch.close()
    run go(srv)

  test "sending a large message to a call the server has already ended":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      let call = await ch.newCall("/t.S/Refuse")
      expectStatus scResourceExhausted:
        for _ in 0 ..< 4:
          await call.send(newSeq[byte](1024 * 1024))
        await call.closeSend()
        discard await call.recv()
      call.close()
      await ch.close()
    run go(srv)

  test "20 MiB server stream to a slow reader":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      let call = await ch.newCall("/t.S/Flood")
      await call.send("20000".toBytes)       # 20 MiB
      await call.closeSend()
      var got = 0
      while true:
        let m = await call.recv()
        if m.isNone: break
        got += m.get.len
        if got mod (1024 * 1024) == 0: await sleepAsync(1.milliseconds)
      ck got == 20000 * 1024
      call.close()
      await ch.close()
    run go(srv)

  test "thousands of concurrent calls on one channel":
    proc go(srv: AsyncGrpcServer) {.async.} =
      let ch = await dialAsync("127.0.0.1", srv.port)
      var fs: seq[Future[UnaryResult]]
      for i in 0 ..< 5000:
        fs.add ch.unaryCall("/t.S/Echo", ("m" & $i).toBytes, timeoutMs = 30_000)
      await allFutures(fs)
      var ok = 0
      for i, f in fs:
        if f.completed and f.read.message.toStr == "M" & $i: inc ok
      ck ok == 5000
      await ch.close()
    run go(srv)

  test "a stopped server comes back; the channel redials":
    proc go(srv: AsyncGrpcServer): Future[AsyncGrpcServer] {.async.} =
      let port = srv.port
      let ch = await dialAsync("127.0.0.1", port)
      ck (await ch.unaryCall("/t.S/Echo", "a".toBytes)).message.toStr == "A"
      await srv.stop(graceMs = 500)
      await sleepAsync(100.milliseconds)
      expectStatus(scUnavailable):
        discard await ch.unaryCall("/t.S/Echo", "b".toBytes)
      let again = newAsyncGrpcServer(port)
      again.addUnary("/t.S/Echo", echoUnary)
      again.start()
      ck (await ch.unaryCall("/t.S/Echo", "c".toBytes)).message.toStr == "C"
      await ch.close()
      return again
    failures = @[]
    srv = waitFor go(srv)
    check failures == newSeq[string]()

  test "blocking client against the async server":
    type Arg = tuple[port: int; ok: ptr bool; done: ptr Atomic[bool]]
    proc client(a: Arg) {.thread.} =
     {.cast(gcsafe).}:
      try:
        let ch = bc.dial("127.0.0.1", a.port)
        let r = bc.unaryCall(ch, "/t.S/Echo", "blocking".toBytes)
        a.ok[] = r.message.toStr == "BLOCKING"
        bc.close(ch)
      except CatchableError:
        discard
      a.done[].store(true)
    var ok = false
    var done: Atomic[bool]
    var th: Thread[Arg]
    createThread(th, client, (srv.port, ok.addr, done.addr))
    while not done.load: waitFor sleepAsync(5.milliseconds)
    joinThread(th)
    check ok

when defined(linux):
  import std/net as snet

  suite "async connect timeout":
    test "dialAsync gives up on a server that never accepts":
      # A listener that never accepts, with its queue full: further SYNs are dropped.
      let lst = snet.newSocket()
      lst.setSockOpt(snet.OptReuseAddr, true)
      lst.bindAddr(Port(0), "127.0.0.1")
      lst.listen(1)
      let port = lst.getLocalAddr()[1]
      var fillers: seq[snet.Socket]
      for _ in 0 ..< 8:
        let f = snet.newSocket()
        try:
          f.connect("127.0.0.1", port, 200)
          fillers.add f
        except CatchableError:
          f.close()
          break
      defer:
        for f in fillers: f.close()
        lst.close()
      if fillers.len >= 8:
        skip()
      else:
        proc go(port: int) {.async.} =
          let started = Moment.now()
          var code = scOk
          try:
            discard await dialAsync("127.0.0.1", port, connectTimeoutMs = 300)
          except GrpcError as e:
            code = e.code
          let took = Moment.now() - started
          ck code == scUnavailable
          ck took >= 250.milliseconds and took < 3.seconds
        run go(port.int)
