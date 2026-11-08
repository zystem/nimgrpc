## Server limits of the blocking server: streams per connection, connections, queued bytes.

import std/[unittest, strutils, typedthreads, atomics, os]
import nimgrpc/h2/[blocking, session, nghttp2]

proc toBytes(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))
proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(result[0].addr, b[0].unsafeAddr, b.len)

proc reqHeaders(port: Port; path: string): seq[blocking.Header] =
  @[(":method", "POST"), (":scheme", "http"),
    (":authority", "127.0.0.1:" & $port.int), (":path", path),
    ("content-type", "application/grpc"), ("te", "trailers")]

var running, peak: Atomic[int]

proc noteStart() =
  let now = running.fetchAdd(1) + 1
  var p = peak.load
  while now > p and not peak.compareExchange(p, now): discard

proc slowHandler(req: Request; ud: pointer): Reply {.nimcall, gcsafe, raises: [].} =
  ## Counts how many handlers run at once, and holds each for a while.
  noteStart()
  sleep(150)
  discard running.fetchSub(1)
  result.headers = @[(":status", "200"), ("content-type", "application/grpc")]
  result.body = req.body
  result.trailers = @[("grpc-status", "0")]

proc bigHandler(req: Request; ud: pointer): Reply {.nimcall, gcsafe, raises: [].} =
  ## 1.5 MB per reply.
  result.headers = @[(":status", "200"), ("content-type", "application/grpc")]
  result.body = toBytes('z'.repeat(1_500_000))
  result.trailers = @[("grpc-status", "0")]

suite "limits of the blocking server":
  test "no more streams run at once than maxConcurrentStreams":
    running.store(0)
    peak.store(0)
    proc streamHandler(st: var ServerStream; ud: pointer)
        {.nimcall, gcsafe, raises: [].} =
      try:
        let req = st.readRequest()
        st.respond(slowHandler(req, nil))
      except CatchableError: discard
    let s = newStreamServer(streamHandler, nil, limits = Limits(maxConcurrentStreams: 2))
    s.start()
    let c = dial("127.0.0.1", s.port)
    # A burst on a connection that has just been opened would reach the server
    # before the client has seen its SETTINGS, and the server refuses what is
    # over the limit (REFUSED_STREAM); once SETTINGS are in, nghttp2 holds
    # the excess back by itself.
    check c.request(reqHeaders(s.port, "/w"), "x".toBytes).body.toStr == "x"
    type Arg = tuple[c: ptr Conn; port: Port; ok: ptr int]
    proc worker(a: Arg) {.thread.} =
      let r = a.c[].request(reqHeaders(a.port, "/w"), "x".toBytes)
      a.ok[] = if r.body.toStr == "x": 1 else: 100 + r.errorCode.int
    var ths: array[6, Thread[Arg]]
    var oks: array[6, int]
    for i in 0 ..< ths.len: createThread(ths[i], worker, (c.addr, s.port, oks[i].addr))
    joinThreads(ths)
    check oks == [1, 1, 1, 1, 1, 1]
    check peak.load <= 2
    check peak.load >= 1
    c.close()
    s.stop()

  test "a connection past maxConnections is closed, a free slot is reused":
    proc streamHandler(st: var ServerStream; ud: pointer)
        {.nimcall, gcsafe, raises: [].} =
      try:
        let req = st.readRequest()
        st.respond(slowHandler(req, nil))
      except CatchableError: discard
    let s = newStreamServer(streamHandler, nil, limits = Limits(maxConnections: 2))
    s.start()
    let a = dial("127.0.0.1", s.port)
    let b = dial("127.0.0.1", s.port)
    check a.request(reqHeaders(s.port, "/a"), "1".toBytes).body.toStr == "1"
    check b.request(reqHeaders(s.port, "/b"), "2".toBytes).body.toStr == "2"
    var refused = false
    try:
      let c = dial("127.0.0.1", s.port)
      try: discard c.request(reqHeaders(s.port, "/c"), "3".toBytes)
      except CatchableError: refused = true
      c.close()
    except CatchableError: refused = true
    check refused
    a.close()
    var served = false
    for attempt in 0 ..< 50:         # the closed connection is reaped on the next accept
      try:
        let d = dial("127.0.0.1", s.port)
        defer: d.close()
        if d.request(reqHeaders(s.port, "/d"), "4".toBytes).body.toStr == "4":
          served = true
          break
      except CatchableError: sleep(100)
    check served
    b.close()
    s.stop()

  test "replies larger than maxConnectionBuffer still arrive whole, side by side":
    proc streamHandler(st: var ServerStream; ud: pointer)
        {.nimcall, gcsafe, raises: [].} =
      try:
        let req = st.readRequest()
        st.respond(bigHandler(req, nil))
      except CatchableError: discard
    let s = newStreamServer(streamHandler, nil,
                            limits = Limits(maxConnectionBuffer: 100_000))
    s.start()
    let c = dial("127.0.0.1", s.port)
    type Arg = tuple[c: ptr Conn; port: Port; n: ptr int]
    proc worker(a: Arg) {.thread.} =
      let r = a.c[].request(reqHeaders(a.port, "/big"), "x".toBytes)
      a.n[] = r.body.len
    var ths: array[4, Thread[Arg]]
    var ns: array[4, int]
    for i in 0 ..< ths.len: createThread(ths[i], worker, (c.addr, s.port, ns[i].addr))
    joinThreads(ths)
    check ns == [1_500_000, 1_500_000, 1_500_000, 1_500_000]
    c.close()
    s.stop()

suite "limits of the session":
  test "queuedBytes follows what is queued and what nghttp2 has framed":
    let srv = newServerSession()
    let cli = newClientSession()
    # complete the handshake
    srv.recv(cli.takeOutput())
    cli.recv(srv.takeOutput())
    let id = cli.submitRequest(reqHeaders(Port(1), "/x"))
    srv.recv(cli.takeOutput())
    srv.submitResponse(id, @[(":status", "200")])
    check srv.queuedBytes == 0
    srv.sendData(id, toBytes('a'.repeat(1000)))
    check srv.queuedBytes == 1000
    discard srv.takeOutput()
    check srv.queuedBytes == 0

suite "nghttp2":
  test "the linked library is 1.61.0 or later (CONTINUATION flood CVE-2024-28182, Rapid Reset CVE-2023-44487)":
    let v = nghttp2_version(0)
    check v.versionNum >= 0x013d00
    echo "  nghttp2 ", v.versionStr
