## Long streaming calls against short unary calls on the blocking server, under admission pressure:
## what the unary calls see (latency, refusals), what the server holds, and its resident size.
##
##   nim c -d:release -o:/tmp/admission tools/admission.nim
##   /tmp/admission [--workers 8] [--holders 24] [--seconds 10] [--quota 0]
##                  [--queue 64] [--bytes-mib 32] [--hold-ms 2000] [--unary 4]
##
## `--holders` threads each keep a streaming call open (it waits `--hold-ms`, then is opened
## again), so with more holders than workers the workers are all taken. `--unary` threads call a
## unary method in a loop. `--quota` is `Limits.maxStreamingCalls` (0: none). Server and clients run
## in one process, so the resident size is theirs together; the figures of the server's limits
## (`srv.stats()`) are the server's own.

import std/[os, strutils, times, monotimes, algorithm, typedthreads, atomics]
import nimgrpc

type Config = object
  workers, holders, seconds, quota, queue, bytesMiB, holdMs, unary: int

var cfg: Config
var stopFlag: Atomic[bool]

type Result = object
  latenciesUs: seq[int64]
  ok, unavailable, exhausted, other: int

proc echoUnary(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req

proc hold(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var msg: seq[byte]
  discard call.recv(msg)             # waits for a message that never comes: holds its worker

proc holder(port: int) {.thread.} =
  {.cast(gcsafe).}:
    let ch = dial("127.0.0.1", port)
    while not stopFlag.load:
      var call = newCall(ch, "/t.T/Hold", timeoutMs = cfg.holdMs)
      var msg: seq[byte]
      try: discard recv(call, msg)
      except CatchableError: discard
      close(call)
    ch.close()

proc unaryWorker(args: (int, ptr Result)) {.thread.} =
  {.cast(gcsafe).}:
    let (port, res) = args
    let ch = dial("127.0.0.1", port)
    while not stopFlag.load:
      let t0 = getMonoTime()
      try:
        discard ch.unaryCall("/t.T/Echo", @[1'u8, 2, 3], timeoutMs = 5000)
        res.latenciesUs.add (getMonoTime() - t0).inMicroseconds
        inc res.ok
      except GrpcError as e:
        case e.code
        of scUnavailable: inc res.unavailable
        of scResourceExhausted: inc res.exhausted
        else: inc res.other
      except CatchableError: inc res.other
      sleep(2)
    ch.close()

proc rssMiB(): int =
  try:
    for l in lines("/proc/self/status"):      # not `readFile`: a file of /proc has size 0
      if l.startsWith("VmRSS:"): return parseInt(l.splitWhitespace()[1]) div 1024
  except CatchableError: discard
  -1

proc main() =
  cfg = Config(workers: 8, holders: 24, seconds: 10, quota: 0, queue: 64, bytesMiB: 32,
               holdMs: 2000, unary: 4)
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    inc i
    let v = if i <= paramCount(): parseInt(paramStr(i)) else: 0
    case a
    of "--workers": cfg.workers = v
    of "--holders": cfg.holders = v
    of "--seconds": cfg.seconds = v
    of "--quota": cfg.quota = v
    of "--queue": cfg.queue = v
    of "--bytes-mib": cfg.bytesMiB = v
    of "--hold-ms": cfg.holdMs = v
    of "--unary": cfg.unary = v
    else: quit "unknown option " & a
    inc i
  let srv = newGrpcServer(maxWorkers = cfg.workers,
    limits = Limits(maxQueuedCalls: cfg.queue, maxQueuedBytes: cfg.bytesMiB * 1024 * 1024,
                    maxStreamingCalls: cfg.quota))
  srv.addUnary("/t.T/Echo", echoUnary)
  srv.addStreaming("/t.T/Hold", hold)
  srv.start()
  let rss0 = rssMiB()
  var holders = newSeq[Thread[int]](cfg.holders)
  var unary = newSeq[Thread[(int, ptr Result)]](cfg.unary)
  var results = newSeq[Result](cfg.unary)
  for t in holders.mitems: createThread(t, holder, srv.port)
  sleep(500)
  for k in 0 ..< cfg.unary: createThread(unary[k], unaryWorker, (srv.port, results[k].addr))
  var peakBytes, peakQueued, peakRss = 0
  let until = getMonoTime() + initDuration(seconds = cfg.seconds)
  while getMonoTime() < until:
    let st = srv.stats()
    peakBytes = max(peakBytes, st.queuedBytes)
    peakQueued = max(peakQueued, st.queuedCalls)
    peakRss = max(peakRss, rssMiB())
    sleep(20)
  stopFlag.store(true)
  joinThreads(unary)
  joinThreads(holders)
  var all: seq[int64]
  var ok, unavailable, exhausted, other = 0
  for r in results:
    all.add r.latenciesUs
    ok += r.ok; unavailable += r.unavailable; exhausted += r.exhausted; other += r.other
  all.sort
  proc pct(p: float): string =
    if all.len == 0: "n/a" else: $(float(all[min(all.high, int(p * float(all.len)))]) / 1000.0) & " ms"
  let st = srv.stats()
  echo "config: workers=", cfg.workers, " holders=", cfg.holders, " quota=", cfg.quota,
       " queue=", cfg.queue, " bytes=", cfg.bytesMiB, "MiB hold=", cfg.holdMs, "ms unary threads=", cfg.unary
  echo "unary calls: ", ok, " ok, ", unavailable, " UNAVAILABLE, ", exhausted, " RESOURCE_EXHAUSTED, ", other, " other"
  echo "unary latency: p50 ", pct(0.50), "  p99 ", pct(0.99), "  max ", pct(1.0)
  echo "server: peak waiting calls ", peakQueued, ", peak held bytes ", peakBytes,
       "; refused (queue) ", st.refusedQueue, ", refused (bytes) ", st.refusedBytes,
       ", shed ", st.shedBytes, ", refused streaming ", st.refusedStreaming
  echo "resident size: ", rss0, " MiB before, peak ", peakRss, " MiB (server and clients)"
  srv.stop()

main()
