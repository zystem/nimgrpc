## Client limits: a server that stays silent, and a server whose headers are too big.

import std/[unittest, strutils, times, net, os]
import pkg/chronos
import nimgrpc/h2/[blocking, nghttp2, common]
import nimgrpc/[asyncclient, status]

proc reqHeaders(port: Port; path: string): seq[blocking.Header] =
  @[(":method", "POST"), (":scheme", "http"),
    (":authority", "127.0.0.1:" & $port.int), (":path", path),
    ("content-type", "application/grpc"), ("te", "trailers")]

proc headerHeavy(req: Request; ud: pointer): Reply {.nimcall, gcsafe, raises: [].} =
  ## 40 response headers of 1 KiB each (about 41 KiB in all); `/small` has none of them.
  result.headers = @[(":status", "200"), ("content-type", "application/grpc")]
  var small = false
  for h in req.headers:
    if h.name == ":path" and h.value == "/small": small = true
  if not small:
    for i in 0 ..< 40: result.headers.add (("x-pad-" & $i), 'a'.repeat(1000))
  result.body = @[byte 1]
  result.trailers = @[("grpc-status", "0")]

proc streamHandler(st: var ServerStream; ud: pointer) {.nimcall, gcsafe, raises: [].} =
  try:
    let req = st.readRequest()
    st.respond(headerHeavy(req, nil))
  except CatchableError: discard

proc silentServer(): tuple[sock: Socket, port: Port] =
  ## Accepts TCP connections (the kernel does) and never says a word.
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  s.listen()
  (s, s.getLocalAddr()[1])

suite "client limits: headers":
  test "a response whose headers weigh more than maxHeaderListBytes resets the stream, not the connection":
    let s = newStreamServer(streamHandler, nil)
    s.start()
    let c = dial("127.0.0.1", s.port, limits = ClientLimits(maxHeaderListBytes: 16 * 1024))
    let big = c.request(reqHeaders(s.port, "/big"), [byte 0])
    check big.errorCode == INTERNAL_ERROR
    check big.body.len == 0
    let ok = c.request(reqHeaders(s.port, "/small"), [byte 0])   # same connection, small headers
    check ok.errorCode == 0
    check ok.body == @[byte 1]
    c.close()
    s.stop()

  test "the default allows 41 KiB of headers, 0 leaves the limit to nghttp2":
    let s = newStreamServer(streamHandler, nil)
    s.start()
    for lim in [ClientLimits(), ClientLimits(maxHeaderListBytes: 0)]:
      let c = dial("127.0.0.1", s.port, limits = lim)
      let r = c.request(reqHeaders(s.port, "/big"), [byte 0])
      check r.errorCode == 0
      check r.body == @[byte 1]
      c.close()
    s.stop()

  test "the limit weighs a header as HTTP/2 does: name, value and 32 bytes":
    let s = newStreamServer(streamHandler, nil)
    s.start()
    # /big weighs 40 * (7 or 8 + 1000 + 32) + the pseudo and ordinary headers: a limit just
    # under it resets, one just over lets it through.
    let c1 = dial("127.0.0.1", s.port, limits = ClientLimits(maxHeaderListBytes: 41_000))
    check c1.request(reqHeaders(s.port, "/big"), [byte 0]).errorCode != 0
    c1.close()
    let c2 = dial("127.0.0.1", s.port, limits = ClientLimits(maxHeaderListBytes: 42_500))
    check c2.request(reqHeaders(s.port, "/big"), [byte 0]).errorCode == 0
    c2.close()
    s.stop()

suite "client limits: a server that stays silent":
  test "blocking: the connection is closed after handshakeTimeoutMs, and a call with no deadline fails":
    let (sock, port) = silentServer()
    let c = dial("127.0.0.1", port, limits = ClientLimits(handshakeTimeoutMs: 500))
    let t0 = epochTime()
    var failed = false
    try:
      discard c.request(reqHeaders(port, "/x"), [byte 0])
    except H2StreamClosed as e:
      failed = true
      check "handshake not completed in 500 ms" in e.msg
    check failed
    check epochTime() - t0 >= 0.4
    check epochTime() - t0 < 5.0
    c.close()
    sock.close()

  test "async: the call fails with UNAVAILABLE after handshakeTimeoutMs":
    let (sock, port) = silentServer()
    var code = scOk
    var took = 0.0
    proc run() {.async.} =
      let ch = await dialAsync("127.0.0.1", port.int, limits = ClientLimits(handshakeTimeoutMs: 500))
      let t0 = epochTime()
      try:
        discard await ch.unaryCall("/x.X/Y", @[byte 0])
      except GrpcError as e:
        code = e.code
      took = epochTime() - t0
      await ch.close()
    waitFor run()
    check code == scUnavailable
    check took >= 0.4
    check took < 5.0
    sock.close()
