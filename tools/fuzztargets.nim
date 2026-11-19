## The parsers the fuzzers feed and the seeds they start from, shared by tools/fuzz.nim (a
## mutation fuzzer) and tools/libfuzz.nim (a coverage-guided one, libFuzzer).

import std/os
import nimgrpc/[wire, status, protobuf]
import nimgrpc/compress/gzip
import nimgrpc/h2/session
import ../tests/gen/[codec_pb, legacy_pb, wkt_use_pb]

const protoDir = currentSourcePath.parentDir.parentDir / "tests" / "proto"

proc bytesOf(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))

# ------------------------------------------------------------------ targets

proc tFrames*(d: seq[byte]) =
  ## Frames fed in chunks of varying size, as they arrive.
  var m: MsgBuf
  var payload: seq[byte]
  var compressed: bool
  var i = 0
  try:
    while i < d.len:
      let k = min(d.len - i, 1 + int(d[i]) mod 64 * 7)
      var chunk = d[i ..< i + k]
      i += k
      m.feed(chunk)
      while m.take(4096, payload, compressed): discard
  except GrpcError: discard

proc tGzip*(d: seq[byte]) =
  try: discard gzipDecompress(d, 1 shl 20)
  except GrpcError: discard

proc tEverything*(d: seq[byte]) =
  try: discard Everything.decode(d)
  except ProtobufError: discard

proc tLegacy*(d: seq[byte]) =
  try: discard Legacy.decode(d)
  except ProtobufError: discard

proc tWkt*(d: seq[byte]) =
  try: discard Event.decode(d)
  except ProtobufError: discard

var splitAt* = 0   ## set by the driver: where the h2 input is cut into two reads

proc tH2Server*(d: seq[byte]) =
  let s = newServerSession()
  try:
    let cut = if d.len == 0: 0 else: splitAt mod (d.len + 1)
    s.recv(d[0 ..< cut])
    discard s.takeEvents()
    discard s.takeOutput()
    s.recv(d[cut .. ^1])
    for ev in s.takeEvents():
      if ev.kind == evHeaders:
        discard s.takeOutput()
    discard s.takeOutput()
  except H2Error: discard

proc tH2Client*(d: seq[byte]) =
  ## What a server may send to a client with one call open: the bytes arrive in two reads, the
  ## client credits what it reads (manual flow control) and answers what it must.
  let s = newClientSession(manualFlow = true, maxHeaderListBytes = 2048)
  try:
    let id = s.submitRequest(@[(":method", "POST"), (":scheme", "http"),
                               (":authority", "fuzz"), (":path", "/f.F/Call"),
                               ("content-type", "application/grpc"), ("te", "trailers")])
    s.sendData(id, @[0'u8, 0, 0, 0, 1, 7], endStream = false)
    discard s.takeOutput()
    let cut = if d.len == 0: 0 else: splitAt mod (d.len + 1)
    for part in [d[0 ..< cut], d[cut .. ^1]]:
      s.recv(part)
      for ev in s.takeEvents():
        if ev.kind == evData and ev.data.len > 0:
          s.consume(ev.streamId, ev.data.len)
          s.consumeConnection(ev.data.len)
      discard s.takeOutput()
  except H2Error: discard

# ------------------------------------------------------------------- seeds

proc framed(msg: seq[byte]; flag = 0'u8): seq[byte] =
  result = @[flag, byte(msg.len shr 24), byte(msg.len shr 16), byte(msg.len shr 8), byte(msg.len)]
  result.add msg

proc h2ClientBytes(): seq[seq[byte]] =
  ## What real clients send: preface, SETTINGS, a request, a body, a reset.
  let c = newClientSession()
  let id = c.submitRequest(@[(":method", "POST"), (":scheme", "http"),
                             (":authority", "fuzz"), (":path", "/f.F/Call"),
                             ("content-type", "application/grpc"), ("te", "trailers")])
  c.sendData(id, framed(@[1'u8, 2, 3, 4]), endStream = false)
  var first = c.takeOutput()
  result.add first
  c.sendData(id, framed(bytesOf("more")), endStream = true)
  var second = c.takeOutput()
  result.add first & second
  c.resetStream(id)
  result.add first & second & c.takeOutput()
  result.add c.takeOutput()

proc h2ServerBytes(): seq[seq[byte]] =
  ## What real servers send: SETTINGS, response headers, a message, trailers, a reset, a GOAWAY.
  let c = newClientSession()
  let cid = c.submitRequest(@[(":method", "POST"), (":scheme", "http"),
                              (":authority", "fuzz"), (":path", "/f.F/Call"),
                              ("content-type", "application/grpc"), ("te", "trailers")])
  c.sendData(cid, framed(@[1'u8, 2, 3, 4]), endStream = true)
  let srv = newServerSession()
  srv.recv(c.takeOutput())
  var id = 0'i32
  for ev in srv.takeEvents():
    if ev.kind == evHeaders: id = ev.streamId
  var all = srv.takeOutput()              # SETTINGS and its ACK
  result.add all
  srv.submitResponse(id, @[(":status", "200"), ("content-type", "application/grpc")])
  srv.sendData(id, framed(bytesOf("reply")))
  all.add srv.takeOutput()
  result.add all
  srv.sendTrailers(id, @[("grpc-status", "0"), ("grpc-message", "ok")])
  all.add srv.takeOutput()
  result.add all
  srv.goAway()
  result.add all & srv.takeOutput()
  let r = newServerSession()               # a trailers-only answer, then a reset
  r.recv(c.takeOutput())
  r.ping()
  result.add r.takeOutput()

proc nestedGroups(n: int): seq[byte] =
  ## n nested unknown groups (field 1000), closed: the shape of a stack-depth attack.
  for i in 0 ..< n: result.add [0xC3'u8, 0x3E]
  for i in 0 ..< n: result.add [0xC4'u8, 0x3E]

proc seedsFor*(target: string): seq[seq[byte]] =
  let every = bytesOf(readFile(protoDir / "everything.bin"))
  case target
  of "frames":
    result = @[framed(every), framed(every, 1) & framed(@[]), framed(@[1'u8]) & framed(@[2'u8, 3])]
  of "gzip":
    result = @[gzipCompress(every), gzipCompress(newSeq[byte](5000)), gzipCompress(@[])]
  of "everything": result = @[every, @[], nestedGroups(99), nestedGroups(101)]
  of "legacy": result = @[bytesOf(readFile(protoDir / "legacy.bin")), @[]]
  of "wkt": result = @[bytesOf(readFile(protoDir / "wkt.bin")), @[]]
  of "h2server": result = h2ClientBytes()
  of "h2client": result = h2ServerBytes()
  else: quit "unknown target " & target

