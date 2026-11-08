## Two I/O-free sessions wired back to back in memory.

import std/[unittest, strutils]
import nimgrpc/h2/session

proc toBytes(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))
proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(result[0].addr, b[0].unsafeAddr, b.len)

proc pump(c, s: H2Session) =
  ## Moves bytes both ways until neither side has anything to say.
  for _ in 0 ..< 1000:
    let a = c.takeOutput()
    if a.len > 0: s.recv(a)
    let b = s.takeOutput()
    if b.len > 0: c.recv(b)
    if a.len == 0 and b.len == 0: return
  doAssert false, "pump did not settle"

proc header(hs: seq[Header]; name: string): string =
  for (k, v) in hs:
    if k == name: return v

suite "h2 session":
  test "request, response body and trailers":
    let c = newClientSession()
    let s = newServerSession()
    let id = c.submitRequest(@[
      (":method", "POST"), (":scheme", "http"), (":authority", "test"),
      (":path", "/pkg.Svc/Method"), ("content-type", "application/grpc"),
      ("te", "trailers")])
    c.sendData(id, "hello".toBytes, endStream = true)
    pump(c, s)

    var reqHeaders: seq[Header]
    var reqBody = ""
    var reqEnded = false
    for ev in s.takeEvents():
      case ev.kind
      of evHeaders: reqHeaders = ev.headers
      of evData:
        reqBody.add ev.data.toStr
        reqEnded = reqEnded or ev.dataEndStream
      else: discard
    check reqHeaders.header(":path") == "/pkg.Svc/Method"
    check reqBody == "hello"
    check reqEnded

    s.submitResponse(id, @[(":status", "200"), ("content-type", "application/grpc")])
    s.sendData(id, "world".toBytes)
    s.sendTrailers(id, @[("grpc-status", "0")])
    pump(c, s)

    var blocks: seq[seq[Header]]
    var body = ""
    var closed = false
    for ev in c.takeEvents():
      case ev.kind
      of evHeaders: blocks.add ev.headers
      of evData: body.add ev.data.toStr
      of evStreamClosed:
        closed = true
        check ev.errorCode == 0
      else: discard
    check blocks.len == 2
    check blocks[0].header(":status") == "200"
    check blocks[1].header("grpc-status") == "0"
    check body == "world"
    check closed

  test "body larger than the flow-control window is delivered whole":
    let c = newClientSession()
    let s = newServerSession()
    let id = c.submitRequest(@[(":method", "POST"), (":scheme", "http"),
                               (":authority", "t"), (":path", "/big")])
    let big = 'x'.repeat(200_000)   # > 65 535 initial window
    c.sendData(id, big.toBytes, endStream = true)
    pump(c, s)
    var got = 0
    var ended = false
    for ev in s.takeEvents():
      if ev.kind == evData:
        got += ev.data.len
        ended = ended or ev.dataEndStream
    check got == big.len
    check ended

  test "deferred body resumes when data arrives later":
    let c = newClientSession()
    let s = newServerSession()
    let id = c.submitRequest(@[(":method", "POST"), (":scheme", "http"),
                               (":authority", "t"), (":path", "/stream")])
    pump(c, s)                       # HEADERS only, body deferred
    for i in 1..3:
      c.sendData(id, ("msg" & $i).toBytes, endStream = i == 3)
      pump(c, s)
    var body = ""
    for ev in s.takeEvents():
      if ev.kind == evData: body.add ev.data.toStr
    check body == "msg1msg2msg3"

  test "garbage from the peer is a connection error":
    let s = newServerSession()
    expect H2Error:
      s.recv("GET / HTTP/1.1\r\n\r\n".toBytes)

  test "reset stream reaches the peer":
    let c = newClientSession()
    let s = newServerSession()
    let id = c.submitRequest(@[(":method", "POST"), (":scheme", "http"),
                               (":authority", "t"), (":path", "/x")])
    pump(c, s)
    discard s.takeEvents()
    c.resetStream(id)
    pump(c, s)
    var code = 0'u32
    for ev in s.takeEvents():
      if ev.kind == evStreamClosed: code = ev.errorCode
    check code == 8   # CANCEL

proc frame(typ, flags: byte; stream: uint32; payload: seq[byte]): seq[byte] =
  let n = payload.len
  result = @[byte(n shr 16), byte(n shr 8), byte(n), typ, flags,
             byte(stream shr 24), byte(stream shr 16), byte(stream shr 8), byte(stream)]
  result.add payload

proc continuationStream(frames: int): seq[byte] =
  ## The client preface, a HEADERS frame that does not end its header block,
  ## and `frames` CONTINUATION frames (each one more header, "a: x").
  for ch in "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n": result.add byte(ch)
  result.add frame(4, 0, 0, @[])                        # SETTINGS
  result.add frame(1, 0, 1, @[0x83'u8])                 # HEADERS ":method: POST", no END_HEADERS
  for i in 0 ..< frames:
    result.add frame(9, 0, 1, @[0x00'u8, 0x01, 0x61, 0x01, 0x78])

suite "flood limits":
  test "CONTINUATION frames up to the limit are accepted, one more ends the connection (CVE-2024-28182)":
    let ok = newServerSession()
    ok.recv(continuationStream(maxContinuations))
    let tooMany = newServerSession()
    expect H2Error:
      tooMany.recv(continuationStream(maxContinuations + 1))
