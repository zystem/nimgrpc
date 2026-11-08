## A connection that never finishes its handshake is closed, a peer that does is kept, and the
## sockets of both ends carry the system's TCP keepalive.

import std/[unittest, net, os, strutils, monotimes, times, nativesockets]
import pkg/chronos
import nimgrpc
import nimgrpc/[asyncclient, asyncserver]

proc echoUnary(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req

proc asyncEcho(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} =
  return req

proc frame(typ, flags: byte; stream: uint32; payload: seq[byte]): string =
  let n = payload.len
  result = newString(9 + n)
  result[0] = char(n shr 16); result[1] = char(n shr 8); result[2] = char(n)
  result[3] = char(typ); result[4] = char(flags)
  result[5] = char(stream shr 24); result[6] = char(stream shr 16)
  result[7] = char(stream shr 8); result[8] = char(stream)
  for i, b in payload: result[9 + i] = char(b)

const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

proc keepaliveTimers(port: int): int =
  ## How many TCP sockets of `port` (either end) have the system's keepalive timer running,
  ## from /proc/net/tcp and tcp6; -1 where the file is not there.
  var any = false
  let hexPort = toHex(port, 4)
  for file in ["/proc/net/tcp", "/proc/net/tcp6"]:
    if not fileExists(file): continue
    any = true
    var first = true
    for line in lines(file):
      if first:
        first = false
        continue
      let f = line.splitWhitespace
      if f.len < 6 or f[3] != "01": continue          # established only
      if not (f[1].endsWith(":" & hexPort) or f[2].endsWith(":" & hexPort)): continue
      if f[5].startsWith("02:"): inc result
  if not any: result = -1

proc readable(s: Socket; ms: int): bool =
  ## Whether a read would not block (data, or the end of the stream). The tests wait with it
  ## instead of `recv(timeout = ...)`, which raises on a timeout and leaves a string behind
  ## that LeakSanitizer reports.
  var rs = @[s.getFd]
  selectRead(rs, ms) > 0

proc readSome(s: Socket): int =
  ## One read of whatever is there (0: the end of the stream). `recv(size)` of std/net would wait
  ## for all the bytes it is asked for.
  var buf: array[1024, byte]
  s.recv(buf[0].addr, buf.len)

proc settledTimers(port: int; want: int): int =
  ## `keepaliveTimers`, looked at again for up to two seconds until it shows `want`: right after
  ## a call a socket may still hold its delayed-ACK timer instead.
  for i in 0 ..< 40:
    result = keepaliveTimers(port)
    if result == want or result < 0: return
    sleep 50

proc blockingCall(port: int; keepalive = Keepalive()): bool =
  let ch = dial("127.0.0.1", port, keepalive = keepalive)
  defer: ch.close()
  ch.unaryCall("/t.T/E", [1'u8], timeoutMs = 3000).message == @[1'u8]

suite "the handshake guard of the blocking server":
  test "a connection that sends nothing is closed after the limit":
    let srv = newGrpcServer(limits = Limits(handshakeTimeoutMs: 300))
    srv.addUnary("/t.T/E", echoUnary)
    srv.start()
    let s = newSocket(buffered = false)
    s.connect("127.0.0.1", Port(srv.port))
    let t0 = getMonoTime()
    var closed = false
    while readable(s, 3000):                            # the server's own SETTINGS come first
      if s.readSome == 0:
        closed = true                                   # end of stream: the server closed it
        break
    let ms = (getMonoTime() - t0).inMilliseconds
    s.close()
    check closed
    check ms >= 250
    check ms < 2000
    srv.stop()

  test "a peer that has sent its preface and SETTINGS is kept":
    let srv = newGrpcServer(limits = Limits(handshakeTimeoutMs: 300))
    srv.addUnary("/t.T/E", echoUnary)
    srv.start()
    let s = newSocket(buffered = false)
    s.connect("127.0.0.1", Port(srv.port))
    s.send(preface & frame(4, 0, 0, @[]))
    while readable(s, 200): discard s.readSome          # the server's own SETTINGS, then silence
    sleep 900                                           # three times the limit
    var stillOpen = true
    if readable(s, 300):                                # data or the end of the stream
      stillOpen = s.readSome > 0                        # an empty read is the end
    s.close()
    check stillOpen
    srv.stop()

  test "an ordinary client is not affected by a short limit":
    let srv = newGrpcServer(limits = Limits(handshakeTimeoutMs: 300))
    srv.addUnary("/t.T/E", echoUnary)
    srv.start()
    check blockingCall(srv.port)
    sleep 600
    check blockingCall(srv.port)
    srv.stop()

suite "TCP keepalive of the blocking adapter":
  test "both ends of a connection have the keepalive timer; tcpSecs 0 leaves it off":
    let srv = newGrpcServer()
    srv.addUnary("/t.T/E", echoUnary)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    discard ch.unaryCall("/t.T/E", [1'u8], timeoutMs = 3000)
    let n = settledTimers(srv.port, 2)
    if n < 0: skip()
    else:
      check n == 2
      let off = newGrpcServer(keepalive = Keepalive(tcpSecs: 0))
      off.addUnary("/t.T/E", echoUnary)
      off.start()
      let ch2 = dial("127.0.0.1", off.port, keepalive = Keepalive(tcpSecs: 0))
      discard ch2.unaryCall("/t.T/E", [1'u8], timeoutMs = 3000)
      sleep 300
      check keepaliveTimers(off.port) == 0
      ch2.close()
      off.stop()
    ch.close()
    srv.stop()

var silentClosed, silentMs, keptOpen, timers: int

proc asyncSilent(port: int) {.async.} =
  let tr = await connect(initTAddress("127.0.0.1", port))
  let t0 = Moment.now()
  try:
    discard await tr.read().wait(chronos.seconds(3))    # to the end of the stream
  except CatchableError:
    discard
  silentMs = (Moment.now() - t0).milliseconds.int
  silentClosed = int(tr.atEof)
  await tr.closeWait()

proc asyncKept(port: int) {.async.} =
  let tr = await connect(initTAddress("127.0.0.1", port))
  discard await tr.write(preface & frame(4, 0, 0, @[]))
  await sleepAsync(chronos.milliseconds(900))            # three times the limit
  try:
    discard await tr.read().wait(chronos.milliseconds(300))   # it would end at once if closed
  except AsyncTimeoutError:
    keptOpen = 1
  except CatchableError:
    discard
  await tr.closeWait()

proc asyncTimers(port: int) {.async.} =
  let ch = await dialAsync("127.0.0.1", port)
  discard await ch.unaryCall("/t.T/E", @[1'u8], timeoutMs = 3000)
  timers = settledTimers(port, 2)
  await ch.close()

suite "the chronos adapter":
  test "a silent connection is closed, one with SETTINGS is kept":
    silentClosed = 0; silentMs = 0; keptOpen = 0
    let srv = newAsyncGrpcServer(limits = Limits(handshakeTimeoutMs: 300))
    srv.addUnary("/t.T/E", asyncEcho)
    srv.start()
    waitFor asyncSilent(srv.port)
    waitFor asyncKept(srv.port)
    check silentClosed == 1
    check silentMs >= 250
    check silentMs < 2000
    check keptOpen == 1
    waitFor srv.stop()

  test "both ends have the TCP keepalive timer":
    timers = 0
    let srv = newAsyncGrpcServer()
    srv.addUnary("/t.T/E", asyncEcho)
    srv.start()
    waitFor asyncTimers(srv.port)
    if timers < 0: skip()
    else: check timers == 2
    waitFor srv.stop()
