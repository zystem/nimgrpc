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
