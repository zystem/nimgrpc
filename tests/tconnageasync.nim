## The age and the idleness of a connection of the chronos server.

import std/[unittest, strutils]
import pkg/chronos
import nimgrpc/h2/async

var asyncResults: array[4, int]

proc asyncSlow(st: AsyncH2Stream; ud: pointer): Future[void] {.async.} =
  var path = ""
  for (k, v) in st.headers:
    if k == ":path": path = v
  discard await st.recvData()
  if path.startsWith("/slow/"): await sleepAsync(parseInt(path[6 .. ^1]).milliseconds)
  st.sendHeaders(@[(":status", "200"), ("content-type", "application/grpc")])
  st.sendTrailers(@[("grpc-status", "0")])

proc reqHeaders(port: Port; path: string): seq[Header] =
  @[(":method", "POST"), (":scheme", "http"),
    (":authority", "127.0.0.1:" & $port.int), (":path", path),
    ("content-type", "application/grpc"), ("te", "trailers")]

proc asyncRequest(c: AsyncH2Conn; port: Port; path: string): Future[bool] {.async.} =
  try:
    let st = c.openStream(reqHeaders(port, path))
    await st.closeSend()
    discard await st.recvHeaders()
    discard await st.recvTrailers()
    st.release()
    return true
  except CatchableError:
    return false

proc waitClosed(c: AsyncH2Conn; ms: int): Future[bool] {.async.} =
  for i in 0 ..< ms div 20:
    if c.isClosed: return true
    await sleepAsync(20.milliseconds)
  return c.isClosed

proc agePart(port: Port) {.async.} =
  let c = await dial("127.0.0.1", port)
  asyncResults[0] = int(await asyncRequest(c, port, "/x"))
  asyncResults[1] = int(c.isUsable)
  await sleepAsync(700.milliseconds)
  asyncResults[2] = int(not c.isUsable)
  asyncResults[3] = int(await c.waitClosed(1000))
  await c.close()

var inFlight, idleClosed, idleKept: int

proc inFlightPart(port: Port) {.async.} =
  let c = await dial("127.0.0.1", port)
  inFlight = int(await asyncRequest(c, port, "/slow/1200"))   # GOAWAY comes at ~300 ms
  await c.close()

proc idlePart(port: Port) {.async.} =
  let c = await dial("127.0.0.1", port)
  for i in 0 ..< 6:
    if not await asyncRequest(c, port, "/x"): return
    await sleepAsync(250.milliseconds)
  idleKept = int(not c.isClosed and c.isUsable)
  idleClosed = int(await c.waitClosed(2500))
  await c.close()

suite "connections of the chronos server":
  test "age: GOAWAY, closed when it has no calls":
    asyncResults = [0, 0, 0, 0]
    let srv = newAsyncStreamServer(asyncSlow, nil, limits = Limits(maxConnectionAgeMs: 400))
    waitFor agePart(srv.port)
    check asyncResults == [1, 1, 1, 1]
    waitFor srv.stop()

  test "age: a call in progress finishes":
    inFlight = 0
    let srv = newAsyncStreamServer(asyncSlow, nil, limits = Limits(maxConnectionAgeMs: 300))
    waitFor inFlightPart(srv.port)
    check inFlight == 1
    waitFor srv.stop()

  test "idle: a connection in use is kept, an idle one is closed":
    idleKept = 0; idleClosed = 0
    let srv = newAsyncStreamServer(asyncSlow, nil, limits = Limits(maxConnectionIdleMs: 500))
    waitFor idlePart(srv.port)
    check idleKept == 1
    check idleClosed == 1
    waitFor srv.stop()
