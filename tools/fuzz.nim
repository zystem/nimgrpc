## Mutation fuzzer for the parsers that face the network: gRPC framing, gzip,
## Protobuf decoding (several message types) and the HTTP/2 session.
##
##   fuzz TARGET SECONDS [SEED] [OUTDIR]
##   TARGET: frames | gzip | everything | legacy | wkt | h2server | h2client | tlsserver | tlsclient | all
##
## Seeds are valid inputs (the fixtures of tests/proto, framed messages, the
## bytes a real client session emits); each round mutates one (bit flips,
## truncation, insertion, deletion, duplication, huge varints) and feeds it to
## the parser. The errors a parser may raise on bad input (ProtobufError,
## GrpcError, H2Error) are fine; anything else, a crash, a sanitizer report or
## a hang, is a finding. The input being run is kept in OUTDIR/current-TARGET.bin,
## so after a crash it is the reproducer. Build with the sanitizers (tools/fuzz.sh).
## This is not coverage-guided: it finds shallow bugs and regressions. The coverage-guided
## fuzzer over the same targets is tools/libfuzz.nim (tools/libfuzz.sh).
##
##   fuzz seeds TARGET DIR     writes the seeds of TARGET as files, a starting corpus for libFuzzer

import std/[os, strutils, random, times]
import ./fuzztargets

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
      of "h2client": tH2Client(input)
      of "tlsserver": tTlsServer(input)
      of "tlsclient": tTlsClient(input)
      else: tH2Server(input)
      inc rounds
  cur.close()
  # nothing crashed: drop the scratch file
  removeFile outDir / ("current-" & target & ".bin")
  echo target, ": ", rounds, " inputs, no finding (seed ", seed, ")"

when isMainModule:
  if paramCount() == 3 and paramStr(1) == "seeds":
    createDir paramStr(3)
    for i, sd in seedsFor(paramStr(2)):
      # the h2 target reads the first two bytes as the place where its input is cut in two
      let body = if paramStr(2) in ["h2server", "h2client", "tlsserver", "tlsclient"]: @[0'u8, 0] & sd else: sd
      writeFile(paramStr(3) / ("seed" & $i), cast[string](body))
    quit 0
  if paramCount() < 2: quit "usage: see the top of tools/fuzz.nim"
  let target = paramStr(1)
  let secs = parseInt(paramStr(2))
  let seed = if paramCount() >= 3: parseBiggestInt(paramStr(3)) else: int64(epochTime())
  let outDir = if paramCount() >= 4: paramStr(4) else: "fuzz-out"
  if target == "all":
    for t in ["frames", "gzip", "everything", "legacy", "wkt", "h2server", "h2client", "tlsserver", "tlsclient"]:
      run(t, secs, seed, outDir)
  else:
    run(target, secs, seed, outDir)
