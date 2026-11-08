## IPv6: servers listen on it, clients dial it, and the :authority of an IPv6 literal is
## bracketed. The tests that need an IPv6 loopback skip themselves without one.

import std/[unittest, net, nativesockets]
import pkg/chronos
import nimgrpc
import nimgrpc/h2/common
import nimgrpc/[asyncclient, asyncserver]
from nimgrpc/client as bc import nil

proc hasIpv6Loopback(): bool =
  try:
    let s = newSocket(Domain.AF_INET6, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
    defer: s.close()
    s.bindAddr(Port(0), "::1")
    true
  except CatchableError:
    false

let ipv6 = hasIpv6Loopback()

proc echoUnary(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req

proc asyncEcho(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} =
  return req

proc call(host: string; port: int): bool =
  ## One unary call over the blocking client; false if it cannot be made.
  try:
    let ch = bc.dial(host, port, connectTimeoutMs = 3000)
    defer: ch.close()
    ch.unaryCall("/t.T/E", [7'u8], timeoutMs = 3000).message == @[7'u8]
  except CatchableError:
    false

proc asyncCall(host: string; port: int): Future[bool] {.async.} =
  try:
    let ch = await dialAsync(host, port, connectTimeoutMs = 3000)
    let r = await ch.unaryCall("/t.T/E", @[7'u8], timeoutMs = 3000)
    await ch.close()
    return r.message == @[7'u8]
  except CatchableError:
    return false

suite "IPv6 addresses":
  test "an IPv6 literal gets brackets in :authority; brackets are taken off to resolve":
    check hostPort("::1", 50051) == "[::1]:50051"
    check hostPort("[::1]", 50051) == "[::1]:50051"
    check hostPort("example.com", 443) == "example.com:443"
    check hostPort("127.0.0.1", 1) == "127.0.0.1:1"
    check stripBrackets("[::1]") == "::1"
    check stripBrackets("::1") == "::1"
    check stripBrackets("localhost") == "localhost"

suite "IPv6 over the blocking adapter":
  test "a server on ::1 is dialled as ::1 and as [::1]":
    if not ipv6: skip()
    else:
      let srv = newGrpcServer(address = "::1")
      srv.addUnary("/t.T/E", echoUnary)
      srv.start()
      check call("::1", srv.port)
      check call("[::1]", srv.port)
      check not call("127.0.0.1", srv.port)     # IPv6 only: the IPv4 loopback has no listener
      srv.stop()

  test "a server on :: takes IPv6 and IPv4 clients":
    if not ipv6: skip()
    else:
      let srv = newGrpcServer(address = "::")
      srv.addUnary("/t.T/E", echoUnary)
      srv.start()
      check call("::1", srv.port)
      check call("127.0.0.1", srv.port)
      srv.stop()

  test "a server on an IPv4 address still serves IPv4 and refuses IPv6":
    let srv = newGrpcServer(address = "127.0.0.1")
    srv.addUnary("/t.T/E", echoUnary)
    srv.start()
    check call("127.0.0.1", srv.port)
    if ipv6: check not call("::1", srv.port)
    srv.stop()

suite "IPv6 over the chronos adapter":
  test "the async server and client on ::1":
    if not ipv6: skip()
    else:
      let srv = newAsyncGrpcServer(address = "::1")
      srv.addUnary("/t.T/E", asyncEcho)
      srv.start()
      var viaAsync = false
      proc go(port: int) {.async.} = viaAsync = await asyncCall("::1", port)
      waitFor go(srv.port)
      check viaAsync
      waitFor srv.stop()
