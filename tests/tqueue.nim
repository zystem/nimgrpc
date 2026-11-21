## `Limits.maxQueuedCalls`: the calls that wait for a worker on the blocking server. Past the
## limit a new call is refused (REFUSED_STREAM) before it is queued, and a call that is gone (its
## stream reset, its connection closed) leaves the queue at once, so the queue does not fill with
## what nobody waits for.

import std/[unittest, os, net]
import nimgrpc
from nimgrpc/h2/blocking as h2 import nil

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
