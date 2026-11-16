## The chronos HTTP/2 adapter: async client and server, and both mixed with
## the blocking adapter.

import std/[unittest, strutils, typedthreads, atomics, os, monotimes]
import pkg/chronos
import nimgrpc/h2/async
from nimgrpc/h2/blocking as blk import nil
from std/net as snet import nil
from std/posix import nil

proc toBytes(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))
proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(result[0].addr, b[0].unsafeAddr, b.len)

proc header(hs: seq[Header]; name: string): string =
  for (k, v) in hs:
    if k == name: return v

proc reqHeaders(port: Port; path: string): seq[Header] =
  @[(":method", "POST"), (":scheme", "http"),
    (":authority", "127.0.0.1:" & $port.int), (":path", path),
    ("content-type", "application/grpc"), ("te", "trailers")]

var handlerCancelled = 0

# `check` cannot run inside async procs (its formatter raises Exception), so
# they record failures and the test checks the list afterwards.
var failures: seq[string]
template ck(cond: untyped) =
  if not cond:
    {.cast(gcsafe).}:
      failures.add astToStr(cond) & " (line " & $instantiationInfo().line & ")"
template run(f: untyped) =
  failures = @[]
  waitFor f
  check failures == newSeq[string]()

var slowFirst = 0    ## bytes waiting when the /slow handler first reads
var slowTaken = 0    ## bytes the /slow handler has read

proc echoHandler(st: AsyncH2Stream; ud: pointer): Future[void] {.async.} =
  ## Streams the body back upper-cased as it arrives, path in a trailer.
  let path = st.headers.header(":path")
  if path == "/hang":
    try:
      await sleepAsync(10.seconds)
    except CancelledError as e:
      inc handlerCancelled
      raise e
  st.sendHeaders(@[(":status", "200"), ("content-type", "application/grpc")])
  if path == "/slow":
    await sleepAsync(400.milliseconds)   # reads nothing: the window must fill
    while true:
      let chunk = await st.recvData()
      if chunk.len == 0: break
      if slowTaken == 0: slowFirst = chunk.len
      slowTaken += chunk.len
    st.sendTrailers(@[("grpc-status", "0")])
    return
  while true:
    var chunk = await st.recvData()
    if chunk.len == 0: break
    for b in chunk.mitems:
      if b >= 'a'.byte and b <= 'z'.byte: b -= 32
    await st.send(chunk)
  st.sendTrailers(@[("grpc-status", "0"), ("x-path", path)])

type Reply = object
  headers, trailers: seq[Header]
  body: seq[byte]

proc request(c: AsyncH2Conn; port: Port; path: string; body: seq[byte];
             timeoutMs = -1): Future[Reply] {.async.} =
  let st = c.openStream(reqHeaders(port, path), timeoutMs)
  # Sending and reading overlap: an echo peer stops reading while its own
  # replies are held back by our window, so send-then-read would deadlock.
  let sending = st.send(body, endStream = true)
  try:
    result.headers = await st.recvHeaders()
    while true:
      let chunk = await st.recvData()
      if chunk.len == 0: break
      result.body.add chunk
    result.trailers = await st.recvTrailers()
    await sending
  except CatchableError as e:
    st.release()
    raise e
  st.release()

suite "chronos h2":
  var srv: AsyncH2Server
  setup:
    srv = newAsyncStreamServer(echoHandler)
    handlerCancelled = 0
  teardown:
    waitFor srv.stop()

  test "one request":
    proc go(srv: AsyncH2Server) {.async.} =
      let c = await dial("127.0.0.1", srv.port)
      let r = await c.request(srv.port, "/a.B/C", "ping".toBytes)
      ck r.headers.header(":status") == "200"
      ck r.body.toStr == "PING"
      ck r.trailers.header("x-path") == "/a.B/C"
      await c.close()
    run go(srv)

  test "bodies far larger than the windows, both ways":
    proc go(srv: AsyncH2Server) {.async.} =
      let c = await dial("127.0.0.1", srv.port)
      let r = await c.request(srv.port, "/big", 'q'.repeat(3_000_000).toBytes)
      ck r.body.len == 3_000_000
      ck r.body.toStr == 'Q'.repeat(3_000_000)
      await c.close()
    run go(srv)

  test "a reader that does not read stops the sender":
    proc go(srv: AsyncH2Server) {.async.} =
      slowFirst = 0
      slowTaken = 0
      let c = await dial("127.0.0.1", srv.port)
      let st = c.openStream(reqHeaders(srv.port, "/slow"))
      let chunk = 'z'.repeat(16_384).toBytes
      var sender = proc (): Future[void] {.async.} =
        for i in 0 ..< 128:             # 2 MiB in all
          await st.send(chunk)
        await st.closeSend()
      let f = sender()
      discard await st.recvHeaders()
      discard await st.recvTrailers()
      await f
      # While the handler slept the sender was held to our receive window (1 MiB, of the 2 MiB sent).
      ck slowFirst > 0 and slowFirst <= 1_048_576
      ck slowTaken == 2_097_152
      st.release()
      await c.close()
    run go(srv)

  test "a thousand concurrent streams on one connection, one thread":
    proc go(srv: AsyncH2Server) {.async.} =
      let c = await dial("127.0.0.1", srv.port)
      var fs: seq[Future[Reply]]
      for i in 0 ..< 1000:
        fs.add c.request(srv.port, "/n" & $i, ("m" & $i).toBytes)
      await allFutures(fs)
      var ok = 0
      for i, f in fs:
        if f.read.body.toStr == "M" & $i and f.read.trailers.header("x-path") == "/n" & $i:
          inc ok
      ck ok == 1000
      await c.close()
    run go(srv)

  test "many connections at once":
    proc one(srv: AsyncH2Server; i: int): Future[bool] {.async.} =
      let c = await dial("127.0.0.1", srv.port)
      let r = await c.request(srv.port, "/c", ("x" & $i).toBytes)
      await c.close()
      return r.body.toStr == "X" & $i
    proc go(srv: AsyncH2Server) {.async.} =
      var fs: seq[Future[bool]]
      for i in 0 ..< 200: fs.add one(srv, i)
      await allFutures(fs)
      var ok = 0
      for f in fs:
        if f.read: inc ok
      ck ok == 200
    run go(srv)

  test "client deadline resets the stream and cancels the handler":
    proc go(srv: AsyncH2Server) {.async.} =
      let c = await dial("127.0.0.1", srv.port)
      var timedOut = false
      try:
        discard await c.request(srv.port, "/hang", "x".toBytes, timeoutMs = 100)
      except H2Timeout:
        timedOut = true
      ck timedOut
      await sleepAsync(100.milliseconds)
      ck handlerCancelled == 1
      ck c.activeStreams == 0
      # The connection is still fine.
      let r = await c.request(srv.port, "/after", "ok".toBytes)
      ck r.body.toStr == "OK"
      await c.close()
    run go(srv)

  test "client cancel cancels the handler":
    proc go(srv: AsyncH2Server) {.async.} =
      let c = await dial("127.0.0.1", srv.port)
      let st = c.openStream(reqHeaders(srv.port, "/hang"))
      await sleepAsync(50.milliseconds)
      st.cancel()
      st.release()
      await sleepAsync(100.milliseconds)
      ck handlerCancelled == 1
      await c.close()
    run go(srv)

  test "stop cancels running handlers; clients see the stream closed":
    proc go(srv: AsyncH2Server) {.async.} =
      let c = await dial("127.0.0.1", srv.port)
      let st = c.openStream(reqHeaders(srv.port, "/hang"))
      await sleepAsync(50.milliseconds)
      await srv.stop()
      ck handlerCancelled == 1
      var closed = false
      try:
        discard await st.recvHeaders()
      except H2StreamClosed:
        closed = true
      ck closed
      st.release()
      await c.close()
    run go(srv)
    srv = newAsyncStreamServer(echoHandler)   # for teardown

  test "graceful stop lets a call in progress finish":
    proc go(srv: AsyncH2Server) {.async.} =
      let c = await dial("127.0.0.1", srv.port)
      let st = c.openStream(reqHeaders(srv.port, "/slowclient"))
      await st.send("abc".toBytes)
      await sleepAsync(100.milliseconds)      # the call has started
      let stopping = srv.stop(graceMs = 2000)
      await sleepAsync(200.milliseconds)
      ck not c.isUsable           # GOAWAY arrived
      await st.send("def".toBytes, endStream = true)
      discard await st.recvHeaders()
      var body: seq[byte]
      while true:
        let chunk = await st.recvData()
        if chunk.len == 0: break
        body.add chunk
      ck body.toStr == "ABCDEF"
      ck (await st.recvTrailers()).header("grpc-status") == "0"
      st.release()
      await stopping
      await c.close()
    run go(srv)
    srv = newAsyncStreamServer(echoHandler)

  test "blocking client against the chronos server":
    let port = srv.port
    type Arg = tuple[port: Port; ok: ptr bool; done: ptr Atomic[bool]]
    proc client(a: Arg) {.thread.} =
      let c = blk.dial("127.0.0.1", a.port)
      let r = blk.request(c, reqHeaders(a.port, "/blk"), "hello".toBytes)
      a.ok[] = r.body.toStr == "HELLO" and r.trailers.header("x-path") == "/blk"
      blk.close(c)
      a.done[].store(true)
    var ok = false
    var done: Atomic[bool]
    var th: Thread[Arg]
    createThread(th, client, (port, ok.addr, done.addr))
    # Serve on this thread's loop until the client is done.
    while not done.load:
      waitFor sleepAsync(5.milliseconds)
    joinThread(th)
    check ok

proc rawFrame(typ, flags: byte; stream: uint32; payload: seq[byte]): seq[byte] =
  result = @[byte(payload.len shr 16), byte(payload.len shr 8), byte(payload.len), typ, flags,
             byte(stream shr 24), byte(stream shr 16), byte(stream shr 8), byte(stream)]
  result.add payload

proc rawConnect(port: Port): snet.Socket =
  ## An ordinary socket with the HTTP/2 preface and SETTINGS sent. chronos' own transport cannot
  ## be the peer here: it reports a TCP reset as an end of stream.
  result = snet.newSocket(buffered = false)
  snet.connect(result, "127.0.0.1", port)
  var hello = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".toBytes
  hello.add rawFrame(4, 0, 0, @[])                                 # SETTINGS
  discard snet.send(result, hello[0].addr, hello.len)

const msgDontWait = 0x40.cint     # MSG_DONTWAIT on Linux; std/posix does not have it

proc sendRaw(s: snet.Socket; data: seq[byte]): bool =
  posix.send(snet.getFd(s), data[0].unsafeAddr, data.len, posix.MSG_NOSIGNAL) == data.len

proc readToEnd(s: snet.Socket; ms: int): Future[string] {.async.} =
  ## How the connection ends for a peer that reads: "eof" for an orderly close, "reset" for a
  ## TCP reset, "open" if it is still open after `ms`. Does not block the loop the server runs on.
  var buf: array[4096, byte]
  let deadline = Moment.now() + ms.milliseconds
  while Moment.now() < deadline:
    let n = posix.recv(snet.getFd(s), buf[0].addr, buf.len, msgDontWait)
    if n == 0: return "eof"
    if n < 0:
      let err = osLastError()
      if err.int32 == posix.ECONNRESET: return "reset"
      if err.int32 notin [posix.EAGAIN, posix.EWOULDBLOCK, posix.EINTR]: return "error " & $err.int32
      await sleepAsync(5.milliseconds)
  return "open"

var goawayPort, goawayRounds, goawayResets: Atomic[int]
var goawayDone: Atomic[bool]

proc goawayThenPing() {.thread.} =
  ## 300 connections: GOAWAY, a gap of 0 to 190 microseconds, PING, then read to the end.
  var rounds, resets = 0
  for round in 0 ..< 300:
    let s = rawConnect(Port(goawayPort.load))
    var buf: array[4096, byte]
    discard posix.recv(snet.getFd(s), buf[0].addr, buf.len, 0)       # the server's SETTINGS
    discard s.sendRaw(rawFrame(7, 0, 0, newSeq[byte](8)))            # GOAWAY, NO_ERROR
    let until = getMonoTime().ticks + int64(round mod 20) * 10_000    # nanoseconds
    while getMonoTime().ticks < until: discard
    discard s.sendRaw(rawFrame(6, 0, 0, newSeq[byte](8)))            # PING
    while true:
      let n = posix.recv(snet.getFd(s), buf[0].addr, buf.len, 0)
      if n > 0: continue
      if n < 0 and osLastError().int32 == posix.ECONNRESET: inc resets
      break
    inc rounds
    snet.close(s)
  goawayRounds.store rounds
  goawayResets.store resets
  goawayDone.store true

suite "chronos h2: how a connection is closed":
  test "a frame the server has not read when it closes gets no TCP reset":
    # The peer says GOAWAY and sends a PING right behind it (what h2spec does in its test 7).
    # The server has nothing left to do after the GOAWAY and closes. Closing a socket that
    # holds unread bytes makes the kernel send a reset instead of an orderly end, and a reset
    # can cost the peer what it has not read yet. Whether the PING is in between the server's
    # last read and its close is a matter of timing, so a thread tries it many times with
    # different gaps: before the fix about one round in ten was reset.
    proc go() {.async.} =
      let srv = newAsyncStreamServer(echoHandler)
      goawayPort.store srv.port.int
      goawayDone.store false
      var th: Thread[void]
      createThread(th, goawayThenPing)
      while not goawayDone.load: await sleepAsync(5.milliseconds)
      joinThread(th)
      ck goawayRounds.load == 300
      ck goawayResets.load == 0
      await srv.stop()
    run go()

  test "a peer that never closes its side does not keep the connection":
    proc go() {.async.} =
      let srv = newAsyncStreamServer(echoHandler)
      let s = rawConnect(srv.port)
      await sleepAsync(50.milliseconds)
      let t0 = Moment.now()
      await srv.stop()                      # the peer holds its side open and reads nothing
      ck Moment.now() - t0 < 3.seconds
      ck (await s.readToEnd(2000)) == "eof"
      snet.close(s)
    run go()

  test "stop closes many connections at once, not one after another":
    proc go() {.async.} =
      let srv = newAsyncStreamServer(echoHandler)
      var held: seq[snet.Socket]
      for i in 1 .. 20: held.add rawConnect(srv.port)
      await sleepAsync(50.milliseconds)
      let t0 = Moment.now()
      await srv.stop()
      ck Moment.now() - t0 < 3.seconds
      for s in held: snet.close(s)
    run go()

suite "chronos client, blocking server":
  test "request against the blocking server":
    proc handler(req: blk.Request; ud: pointer): blk.Reply {.nimcall, gcsafe, raises: [].} =
      result.headers = @[(":status", "200"), ("content-type", "application/grpc")]
      result.body = req.body & req.body
      result.trailers = @[("grpc-status", "0")]
    let s = blk.newServer(handler)
    blk.start(s)
    proc go(s: blk.Server) {.async.} =
      let c = await dial("127.0.0.1", blk.port(s))
      let r = await c.request(blk.port(s), "/x", "ab".toBytes)
      ck r.body.toStr == "abab"
      await c.close()
    run go(s)
    blk.stop(s)

suite "chronos h2 over TLS":
  test "TLS both ways":
    let dir = currentSourcePath().parentDir / "certs"
    let srvConf = tlsServerConfig(readFile(dir / "server.pem"), readFile(dir / "server.key"))
    let cliConf = tlsClientConfig(readFile(dir / "ca.pem"))
    let s = newAsyncStreamServer(echoHandler, tls = srvConf)
    proc go(s: AsyncH2Server; cliConf: TlsConfig) {.async.} =
      let c = await dial("127.0.0.1", s.port, cliConf, serverName = "localhost")
      var fs: seq[Future[Reply]]
      for i in 0 ..< 50:
        fs.add c.request(s.port, "/t", ("tls" & $i).repeat(1000).toBytes)
      await allFutures(fs)
      var ok = 0
      for i, f in fs:
        if f.read.body.toStr == ("TLS" & $i).repeat(1000): inc ok
      ck ok == 50
      await c.close()
    run go(s, cliConf)
    waitFor s.stop()
