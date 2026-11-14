## Mutation fuzzer for the parsers that face the network: gRPC framing, gzip,
## Protobuf decoding (several message types) and the HTTP/2 session.
##
##   fuzz TARGET SECONDS [SEED] [OUTDIR]
##   TARGET: frames | gzip | everything | legacy | wkt | h2server | all
##
## Seeds are valid inputs (the fixtures of tests/proto, framed messages, the
## bytes a real client session emits); each round mutates one (bit flips,
## truncation, insertion, deletion, duplication, huge varints) and feeds it to
## the parser. The errors a parser may raise on bad input (ProtobufError,
## GrpcError, H2Error) are fine; anything else, a crash, a sanitizer report or
## a hang, is a finding. The input being run is kept in OUTDIR/current-TARGET.bin,
## so after a crash it is the reproducer. Build with the sanitizers (tools/fuzz.sh).
## This is not coverage-guided: it finds shallow bugs and regressions, and it is
## the reason the parsers have no known crash; a coverage-guided fuzzer
## (libFuzzer, ClusterFuzzLite) is on the roadmap.

import std/[os, strutils, random, times]
import nimgrpc/[wire, status, protobuf]
import nimgrpc/compress/gzip
import nimgrpc/h2/session
import ../tests/gen/[codec_pb, legacy_pb, wkt_use_pb]

const protoDir = currentSourcePath.parentDir.parentDir / "tests" / "proto"

proc bytesOf(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))

proc mutate(rng: var Rand; seed: seq[byte]): seq[byte] =
  result = seed
  for _ in 0 ..< 1 + rng.rand(4):
    if result.len == 0:
      result.add byte(rng.rand(255))
      continue
    case rng.rand(7)
    of 0: result[rng.rand(result.high)] = result[rng.rand(result.high)] xor byte(1 shl rng.rand(7))
    of 1: result[rng.rand(result.high)] = [0'u8, 1, 0x7f, 0x80, 0xff][rng.rand(4)]
    of 2: result.setLen(rng.rand(result.len))
    of 3:
      let at = rng.rand(result.len)
      for _ in 0 ..< 1 + rng.rand(8): result.insert(byte(rng.rand(255)), at)
    of 4:
      let a = rng.rand(result.high)
      let n = 1 + rng.rand(min(16, result.len - a - 1))
      for _ in 0 ..< n: result.delete(a)
    of 5:
      let a = rng.rand(result.high)
      let n = 1 + rng.rand(min(32, result.len - a - 1))
      let piece = result[a ..< a + n]
      let at = rng.rand(result.len)
      result = result[0 ..< at] & piece & result[at .. ^1]
    of 6:
      # a run of 0xff..., the shape of an oversized varint or length
      let at = rng.rand(result.high)
      for k in at ..< min(result.len, at + 5 + rng.rand(6)): result[k] = 0xff
    else:
      result.add byte(rng.rand(255))
    if result.len > 1 shl 20: result.setLen(1 shl 20)

# ------------------------------------------------------------------ targets

proc tFrames(d: seq[byte]) =
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

proc tGzip(d: seq[byte]) =
  try: discard gzipDecompress(d, 1 shl 20)
  except GrpcError: discard

proc tEverything(d: seq[byte]) =
  try: discard Everything.decode(d)
  except ProtobufError: discard

proc tLegacy(d: seq[byte]) =
  try: discard Legacy.decode(d)
  except ProtobufError: discard

proc tWkt(d: seq[byte]) =
  try: discard Event.decode(d)
  except ProtobufError: discard

var splitAt = 0   ## set by the driver: where the h2 input is cut into two reads

proc tH2Server(d: seq[byte]) =
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

proc nestedGroups(n: int): seq[byte] =
  ## n nested unknown groups (field 1000), closed: the shape of a stack-depth attack.
  for i in 0 ..< n: result.add [0xC3'u8, 0x3E]
  for i in 0 ..< n: result.add [0xC4'u8, 0x3E]

proc seedsFor(target: string): seq[seq[byte]] =
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
  else: quit "unknown target " & target

proc run(target: string; seconds: int; seed: int64; outDir: string) =
  var rng = initRand(seed)
  let seeds = seedsFor(target)
  createDir outDir
  var cur = open(outDir / ("current-" & target & ".bin"), fmWrite)
  let until = epochTime() + seconds.float
  var rounds = 0
  while epochTime() < until:
    for _ in 0 ..< 200:
      let input = mutate(rng, seeds[rng.rand(seeds.high)])
      cur.setFilePos(0)
      if input.len > 0: discard cur.writeBytes(input, 0, input.len)
      cur.flushFile()
      splitAt = rng.rand(1 shl 16)
      case target
      of "frames": tFrames(input)
      of "gzip": tGzip(input)
      of "everything": tEverything(input)
      of "legacy": tLegacy(input)
      of "wkt": tWkt(input)
      else: tH2Server(input)
      inc rounds
  cur.close()
  # nothing crashed: drop the scratch file
  removeFile outDir / ("current-" & target & ".bin")
  echo target, ": ", rounds, " inputs, no finding (seed ", seed, ")"

when isMainModule:
  if paramCount() < 2: quit "usage: see the top of tools/fuzz.nim"
  let target = paramStr(1)
  let secs = parseInt(paramStr(2))
  let seed = if paramCount() >= 3: parseBiggestInt(paramStr(3)) else: int64(epochTime())
  let outDir = if paramCount() >= 4: paramStr(4) else: "fuzz-out"
  if target == "all":
    for t in ["frames", "gzip", "everything", "legacy", "wkt", "h2server"]:
      run(t, secs, seed, outDir)
  else:
    run(target, secs, seed, outDir)
