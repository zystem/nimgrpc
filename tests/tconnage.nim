## The age and the idleness of a server connection: GOAWAY, calls in progress finish, the
## connection closes; the grace cuts what does not finish.

import std/[unittest, strutils, os, monotimes, times]
import nimgrpc
import nimgrpc/h2/blocking

proc reqHeaders(port: Port; path: string): seq[blocking.Header] =
  @[(":method", "POST"), (":scheme", "http"),
    (":authority", "127.0.0.1:" & $port.int), (":path", path),
    ("content-type", "application/grpc"), ("te", "trailers")]

proc slowHandler(st: var ServerStream; ud: pointer) {.nimcall, gcsafe, raises: [].} =
  ## "/slow/N" takes N milliseconds to answer.
  try:
    let req = st.readRequest()
    var path = ""
    for (k, v) in req.headers:
      if k == ":path": path = v
    if path.startsWith("/slow/"): sleep(parseInt(path[6 .. ^1]))
    st.respond(Reply(headers: @[(":status", "200"), ("content-type", "application/grpc")],
                     body: req.body, trailers: @[("grpc-status", "0")]))
  except CatchableError:
    discard

proc echoUnary(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req

proc startServer(limits: Limits): Server =
  result = newStreamServer(slowHandler, nil, limits = limits)
  result.start()

proc closedWithin(c: Conn; ms: int): bool =
  for i in 0 ..< ms div 20:
    if c.isClosed: return true
    sleep 20
  c.isClosed

suite "the age of a connection (blocking)":
  test "a connection past its age gets GOAWAY and closes when it has no calls":
    let srv = startServer(Limits(maxConnectionAgeMs: 400))
    let c = dial("127.0.0.1", srv.port)
    check c.request(reqHeaders(srv.port, "/x"), @[1'u8]).body == @[1'u8]
    check c.isUsable
    sleep 700                          # 400 ms +-10%, and the notice before the final GOAWAY
    check not c.isUsable               # GOAWAY received: no new streams
    check c.closedWithin(1000)         # and no calls left, so it is closed
    c.close()
    srv.stop()

  test "a call in progress finishes after the GOAWAY, then the connection closes":
    let srv = startServer(Limits(maxConnectionAgeMs: 300))
    let c = dial("127.0.0.1", srv.port)
    let r = c.request(reqHeaders(srv.port, "/slow/1200"), @[7'u8])   # GOAWAY comes at ~300 ms
    check r.body == @[7'u8]
    check r.errorCode == 0
    check not c.isUsable
    check c.closedWithin(1000)
    c.close()
    srv.stop()

  test "the grace ends a call that does not finish":
    let srv = startServer(Limits(maxConnectionAgeMs: 300, maxConnectionAgeGraceMs: 400))
    let c = dial("127.0.0.1", srv.port)
    let t0 = getMonoTime()
    var cut = false
    try:
      let r = c.request(reqHeaders(srv.port, "/slow/6000"), @[7'u8])
      cut = r.body.len == 0               # a reset stream comes back with an error code
    except H2StreamClosed:
      cut = true
    let ms = (getMonoTime() - t0).inMilliseconds
    check cut
    check ms >= 500                       # not before the age and the grace (300 + 400, -10%)
    check ms < 3000                       # and long before the call would have answered
    c.close()
    srv.stop()

  test "a channel goes on across the age of its connection":
    let srv = newGrpcServer(limits = Limits(maxConnectionAgeMs: 300))
    srv.addUnary("/t.T/E", echoUnary)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    var ok = 0
    for i in 0 ..< 20:                    # 1.6 s: several connections
      if ch.unaryCall("/t.T/E", [1'u8], timeoutMs = 2000).message == @[1'u8]: inc ok
      sleep 80
    check ok == 20
    ch.close()
    srv.stop()

suite "the idleness of a connection (blocking)":
  test "an idle connection is closed, one in use is not":
    let srv = startServer(Limits(maxConnectionIdleMs: 500))
    let c = dial("127.0.0.1", srv.port)
    for i in 0 ..< 6:                     # calls every 250 ms for 1.5 s: never idle for 500 ms
      check c.request(reqHeaders(srv.port, "/x"), @[1'u8]).body == @[1'u8]
      sleep 250
    check not c.isClosed
    check c.isUsable
    check c.closedWithin(2500)            # and then 500 ms of nothing
    c.close()
    srv.stop()
