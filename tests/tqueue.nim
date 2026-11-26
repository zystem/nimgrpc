## `Limits.maxQueuedCalls`: the calls that wait for a worker on the blocking server. Past the
## limit a new call is refused (REFUSED_STREAM) before it is queued, and a call that is gone (its
## stream reset, its connection closed) leaves the queue at once, so the queue does not fill with
## what nobody waits for.

import std/[unittest, os, net, atomics, typedthreads, strutils]
import nimgrpc
from nimgrpc/h2/blocking as h2 import nil
import nimgrpc/h2/blocking {.all.} as hx      # the internals the new checks reach into

proc quiet(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ## Holds its worker until the client ends or leaves.
  var msg: seq[byte]
  discard call.recv(msg)

proc grpcHeaders(port: int): seq[h2.Header] =
  @[(":method", "POST"), (":scheme", "http"), (":authority", "127.0.0.1:" & $port),
    (":path", "/t.T/Quiet"), ("content-type", "application/grpc"), ("te", "trailers")]

proc open(raw: h2.Conn; port, n: int): seq[h2.ClientStream] =
  for i in 0 ..< n: result.add h2.openStream(raw, grpcHeaders(port))

proc refused(streams: seq[h2.ClientStream]): int =
  for st in streams:
    if h2.errorCode(st) == 7'u32: inc result        # REFUSED_STREAM

proc newServer(limit: int): GrpcServer =
  result = newGrpcServer(maxWorkers = 2, limits = Limits(maxQueuedCalls: limit))
  result.addStreaming("/t.T/Quiet", quiet)
  result.start()

proc newByteServer(bytes: int): GrpcServer =
  ## Two workers, room for 1024 waiting calls, and `bytes` for what they have sent.
  result = newGrpcServer(maxWorkers = 2,
                         limits = Limits(maxQueuedCalls: 1024, maxQueuedBytes: bytes))
  result.addStreaming("/t.T/Quiet", quiet)
  result.start()

proc openSending(raw: h2.Conn; port, n, bytes: int): seq[h2.ClientStream] =
  ## `n` calls, each of which sends `bytes` of body at once and never ends. The body starts with
  ## the header of a message of 1 MiB, so that the handler waits for the rest of it (all zeros
  ## would be a whole, empty message, and the handler would return).
  var body = newSeq[byte](bytes)
  body[2] = 0x10                                # flag 0, length 00 10 00 00: 1 MiB
  for i in 0 ..< n:
    var st = h2.openStream(raw, grpcHeaders(port))
    try: h2.send(st, body, endStream = false)
    except CatchableError: discard          # the server reset it while it was sending
    result.add st

proc waitUntil(srv: GrpcServer; ok: proc (q: tuple[calls, bytes: int]): bool; ms = 3000): bool =
  for _ in 0 ..< ms div 20:
    if ok(srv.queueStats()): return true
    sleep(20)
  false

suite "Limits.maxQueuedCalls (blocking server)":
  test "two workers busy, three calls may wait, the rest are refused":
    let srv = newServer(3)
    defer: srv.stop()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    defer: h2.close(raw)
    var held = open(raw, srv.port, 2)         # take both workers
    sleep(300)
    var more = open(raw, srv.port, 6)         # three queue, three are refused
    sleep(300)
    check refused(held) == 0
    check refused(more) == 3
    check srv.stats().refusedQueue == 3           # and the server counted them
    for st in held.mitems: h2.release(st)
    for st in more.mitems: h2.release(st)

  test "no limit: nothing is refused":
    let srv = newServer(0)
    defer: srv.stop()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    defer: h2.close(raw)
    var held = open(raw, srv.port, 2)
    sleep(300)
    var more = open(raw, srv.port, 20)
    sleep(300)
    check refused(held) + refused(more) == 0
    for st in held.mitems: h2.release(st)
    for st in more.mitems: h2.release(st)

  test "a call that the client resets leaves the queue, and its place is free again":
    let srv = newServer(3)
    defer: srv.stop()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    defer: h2.close(raw)
    var held = open(raw, srv.port, 2)
    sleep(300)
    var queued = open(raw, srv.port, 3)       # the queue is full
    sleep(200)
    for st in queued.mitems: h2.release(st)   # RST_STREAM: they must give their places back
    sleep(300)
    var again = open(raw, srv.port, 3)
    sleep(300)
    check refused(again) == 0
    for st in again.mitems: h2.release(st)
    for st in held.mitems: h2.release(st)

  test "the calls of a connection that closes leave the queue":
    let srv = newServer(3)
    defer: srv.stop()
    let a = h2.dial("127.0.0.1", Port(srv.port))
    var held = open(a, srv.port, 2)           # on one connection: both workers
    sleep(300)
    let b = h2.dial("127.0.0.1", Port(srv.port))
    var queued = open(b, srv.port, 3)         # on another: the queue is full
    sleep(200)
    h2.close(b)                               # it goes away with its three calls
    sleep(500)
    let c = h2.dial("127.0.0.1", Port(srv.port))
    var again = open(c, srv.port, 3)
    sleep(300)
    check refused(again) == 0
    for st in again.mitems: h2.release(st)
    h2.close(c)
    for st in queued.mitems: h2.release(st)
    for st in held.mitems: h2.release(st)
    h2.close(a)

suite "Limits.maxQueuedBytes (blocking server)":
  test "the bytes that waiting calls hold are bounded: past the budget calls are reset":
    let srv = newByteServer(256 * 1024)
    defer: srv.stop()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    defer: h2.close(raw)
    var held = open(raw, srv.port, 2)             # both workers
    sleep(300)
    var more = openSending(raw, srv.port, 6, 100 * 1024)   # 600 KiB offered to a 256 KiB budget
    sleep(500)
    check refused(held) == 0
    check refused(more) == 4                       # two fit (about 200 KiB), the rest are shed
    let st = srv.stats()
    check st.shedBytes == 4                        # counted as shed, not as refused at the headers
    check st.refusedBytes == 0 and st.refusedQueue == 0
    let q = srv.queueStats()
    check q.calls == 2
    check q.bytes <= 256 * 1024
    check q.bytes > 150 * 1024
    for st in held.mitems: h2.release(st)
    for st in more.mitems: h2.release(st)

  test "what a call held is given back: when the client resets it, when the connection closes":
    let srv = newByteServer(256 * 1024)
    defer: srv.stop()
    let a = h2.dial("127.0.0.1", Port(srv.port))
    var held = open(a, srv.port, 2)
    sleep(300)
    var queued = openSending(a, srv.port, 2, 60 * 1024)
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 2 and q.bytes > 100 * 1024)
    for st in queued.mitems: h2.release(st)       # RST_STREAM
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 0 and q.bytes == 0)
    let b = h2.dial("127.0.0.1", Port(srv.port))
    var again = openSending(b, srv.port, 2, 60 * 1024)
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 2 and q.bytes > 100 * 1024)
    h2.close(b)                                   # the connection goes with its two calls
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 0 and q.bytes == 0)
    for st in again.mitems: h2.release(st)
    for st in held.mitems: h2.release(st)
    h2.close(a)
    # and the budget is whole again: calls that fit are accepted
    let c = h2.dial("127.0.0.1", Port(srv.port))
    var fits = open(c, srv.port, 2)
    sleep(200)
    check refused(fits) == 0
    for st in fits.mitems: h2.release(st)
    h2.close(c)

  test "a call whose worker has taken it is no longer counted":
    let srv = newByteServer(256 * 1024)
    defer: srv.stop()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    defer: h2.close(raw)
    var held = open(raw, srv.port, 2)             # both workers
    sleep(300)
    var queued = openSending(raw, srv.port, 2, 60 * 1024)   # their bodies arrive while they wait
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 2 and q.bytes > 110 * 1024)
    h2.release(held[0])                            # a worker is free: it takes the first of them
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool =
      q.calls == 1 and q.bytes > 40 * 1024 and q.bytes < 100 * 1024)
    check refused(queued) == 0
    for st in held.mitems: h2.release(st)
    for st in queued.mitems: h2.release(st)

  test "no limit: 0 counts the bytes and refuses nothing":
    let srv = newByteServer(0)
    defer: srv.stop()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    defer: h2.close(raw)
    var held = open(raw, srv.port, 2)
    sleep(300)
    var more = openSending(raw, srv.port, 6, 100 * 1024)
    sleep(300)
    check refused(held) + refused(more) == 0
    check srv.queueStats().bytes > 500 * 1024
    for st in held.mitems: h2.release(st)
    for st in more.mitems: h2.release(st)

# ---------------------------------------------------------------- the budget under concurrency

type ReserveJob = object
  budget: ptr Atomic[int]
  limit, attempts, size: int
  taken: int                    ## bytes this thread got

proc reserveWorker(j: ptr ReserveJob) {.thread.} =
  for i in 0 ..< j.attempts:
    if hx.reserveBudget(j.budget[], j.limit, j.size): j.taken += j.size

suite "the byte budget is taken in one atomic step":
  test "many threads against a small limit never take more than the limit":
    # Readers of different connections run under different locks. A check of the figure and a
    # later addition would let all of them see room for the same bytes.
    let limit = 100_003
    var budget: Atomic[int]
    var jobs: array[8, ReserveJob]
    var threads: array[8, Thread[ptr ReserveJob]]
    for i in 0 ..< 8:
      jobs[i] = ReserveJob(budget: budget.addr, limit: limit, attempts: 50_000, size: 7)
      createThread(threads[i], reserveWorker, jobs[i].addr)
    joinThreads(threads)
    var taken = 0
    for j in jobs: taken += j.taken
    check budget.load == taken                  # nothing is counted twice, nothing is lost
    check taken <= limit
    check taken >= limit - 7                    # and the room that there was is all used

  test "no limit: the bytes are counted, and nothing is refused":
    var budget: Atomic[int]
    var jobs: array[4, ReserveJob]
    var threads: array[4, Thread[ptr ReserveJob]]
    for i in 0 ..< 4:
      jobs[i] = ReserveJob(budget: budget.addr, limit: 0, attempts: 10_000, size: 5)
      createThread(threads[i], reserveWorker, jobs[i].addr)
    joinThreads(threads)
    check budget.load == 4 * 10_000 * 5

proc padTrailers(weight: int): seq[h2.Header] =
  ## A block of headers of about `weight` bytes as HTTP/2 counts them.
  var left = weight
  var i = 0
  while left > 0:
    let n = min(left - 40, 3000)
    result.add (("x-pad-" & $i), 'a'.repeat(max(n, 1)))
    left -= n + 40
    inc i

suite "headers that come after the first block are charged too":
  test "trailers of a waiting call count against the budget":
    let srv = newByteServer(256 * 1024)
    defer: srv.stop()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    defer: h2.close(raw)
    var held = open(raw, srv.port, 2)             # both workers
    sleep(300)
    var queued = openSending(raw, srv.port, 1, 10 * 1024)
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 1 and q.bytes > 10 * 1024)
    let before = srv.queueStats().bytes
    h2.sendTrailers(queued[0], padTrailers(30 * 1024))
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.bytes >= before + 25 * 1024)
    check refused(queued) == 0
    for st in queued.mitems: h2.release(st)
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 0 and q.bytes == 0)
    for st in held.mitems: h2.release(st)

  test "trailers that take a waiting call past the budget reset it":
    let srv = newByteServer(60 * 1024)
    defer: srv.stop()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    defer: h2.close(raw)
    var held = open(raw, srv.port, 2)
    sleep(300)
    var queued = openSending(raw, srv.port, 1, 20 * 1024)
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 1)
    h2.sendTrailers(queued[0], padTrailers(50 * 1024))        # 20 KiB held + 50 KiB: over 60 KiB
    sleep(500)
    check refused(queued) == 1
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 0 and q.bytes == 0)
    for st in queued.mitems: h2.release(st)
    for st in held.mitems: h2.release(st)

proc rssKiB(): int =
  ## The resident size of this process (clients and server together, in one process), Linux only.
  try:
    for l in lines("/proc/self/status"):      # not `readFile`: a file of /proc has size 0
      if l.startsWith("VmRSS:"): return parseInt(l.splitWhitespace()[1])
  except CatchableError: discard
  -1

var stormDone: Atomic[int]      ## workers of the storm that are finished (`Thread.running` is not atomic)

type StormJob = object
  port: int
  streams, bytes: int

proc stormWorker(j: ptr StormJob) {.thread.} =
  {.cast(gcsafe).}:
    let raw = h2.dial("127.0.0.1", Port(j.port))
    var all: seq[h2.ClientStream]
    let body = newSeq[byte](j.bytes)
    for i in 0 ..< j.streams:
      var st = h2.openStream(raw, grpcHeaders(j.port))
      try: h2.send(st, body, endStream = false)
      except CatchableError: discard
      all.add st
    sleep(300)
    for st in all.mitems: h2.release(st)
    h2.close(raw)
    discard stormDone.fetchAdd(1)

suite "the byte budget under many connections":
  test "connections that all send at once: the bytes held never pass the budget, and go back to zero":
    let budget = 256 * 1024
    let srv = newByteServer(budget)
    defer: srv.stop()
    let raw = h2.dial("127.0.0.1", Port(srv.port))
    defer: h2.close(raw)
    var held = open(raw, srv.port, 2)             # both workers: everything below waits
    sleep(300)
    var jobs: array[8, StormJob]
    var threads: array[8, Thread[ptr StormJob]]
    stormDone.store(0)
    for i in 0 ..< 8:
      jobs[i] = StormJob(port: srv.port, streams: 12, bytes: 40 * 1024)    # 3.8 MiB offered
      createThread(threads[i], stormWorker, jobs[i].addr)
    var peak = 0
    while stormDone.load < 8:                     # watch the figure while the connections send
      peak = max(peak, srv.queueStats().bytes)
    joinThreads(threads)
    checkpoint "peak of the bytes held: " & $peak & " of " & $budget &
               "; the resident size of the process now: " & $rssKiB() & " KiB (server and clients)"
    check peak <= budget
    check peak > 100 * 1024                       # the storm did fill it
    check srv.waitUntil(proc (q: tuple[calls, bytes: int]): bool = q.calls == 0 and q.bytes == 0)
    for st in held.mitems: h2.release(st)
