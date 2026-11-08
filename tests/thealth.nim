## The gRPC health checking protocol: Check, Watch and shutdown, on both servers.

import std/[unittest, options, monotimes, times, tables]
import pkg/chronos
import nimgrpc
import nimgrpc/health
import nimgrpc/[asyncclient, asyncserver]
from nimgrpc/client as bc import nil

proc checkOf(ch: GrpcChannel; service: string): HealthStatus =
  let r = ch.unaryCall(checkPath, encodeHealthRequest(service), timeoutMs = 3000)
  decodeHealthResponse(r.message)

proc codeOfCheck(ch: GrpcChannel; service: string): StatusCode =
  try:
    discard ch.checkOf(service)
    scOk
  except GrpcError as e:
    e.code

proc nextStatus(call: var ClientCall): HealthStatus =
  var msg: seq[byte]
  doAssert call.recv(msg)
  decodeHealthResponse(msg)

suite "the messages":
  test "bytes as the health.proto has them":
    check encodeHealthRequest("foo") == @[0x0a'u8, 3, 0x66, 0x6f, 0x6f]
    check encodeHealthRequest("").len == 0
    check encodeHealthResponse(hsServing) == @[0x08'u8, 1]
    check encodeHealthResponse(hsServiceUnknown) == @[0x08'u8, 3]
    check encodeHealthResponse(hsUnknown).len == 0           # the default is not written
    check decodeHealthRequest(@[0x0a'u8, 3, 0x66, 0x6f, 0x6f]) == "foo"
    check decodeHealthResponse(@[0x08'u8, 2]) == hsNotServing
    check decodeHealthResponse(newSeq[byte]()) == hsUnknown
    check decodeHealthResponse(@[0x08'u8, 9]) == hsUnknown    # a status this version does not know
    # a map entry is a message: the name (1), the HealthCheckResponse (2)
    check encodeHealthList(@[("", hsServing)]) == @[0x0a'u8, 6, 0x0a, 0, 0x12, 2, 0x08, 1]
    let list = decodeHealthList(encodeHealthList(@[("a.B", hsNotServing), ("", hsServing)]))
    check list.len == 2
    check list["a.B"] == hsNotServing
    check list[""] == hsServing

suite "the blocking server":
  test "Check: the server as a whole is SERVING, a service is what was set, a stranger is NOT_FOUND":
    let health = newHealth()
    let srv = newGrpcServer()
    srv.register(health)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    check ch.checkOf("") == hsServing
    check ch.codeOfCheck("a.B") == scNotFound
    health.setStatus("a.B", hsNotServing)
    check ch.checkOf("a.B") == hsNotServing
    health.setStatus("a.B", hsServing)
    check ch.checkOf("a.B") == hsServing
    health.clearStatus("a.B")
    check ch.codeOfCheck("a.B") == scNotFound
    ch.close()
    srv.stop()

  test "List: every service and its status":
    let health = newHealth()
    health.setStatus("a.B", hsNotServing)
    health.setStatus("c.D", hsServing)
    let srv = newGrpcServer()
    srv.register(health)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    let r = ch.unaryCall(listPath, newSeq[byte](), timeoutMs = 3000)
    let list = decodeHealthList(r.message)
    check list.len == 3
    check list[""] == hsServing
    check list["a.B"] == hsNotServing
    check list["c.D"] == hsServing
    ch.close()
    srv.stop()

  test "Watch: the status now, then each change; the client can leave":
    let health = newHealth()
    health.setStatus("a.B", hsNotServing)
    let srv = newGrpcServer()
    srv.register(health)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    var call = ch.newCall(watchPath, timeoutMs = 20000)
    call.send(encodeHealthRequest("a.B"))
    check call.nextStatus == hsNotServing
    health.setStatus("a.B", hsServing)
    let t0 = getMonoTime()
    check call.nextStatus == hsServing
    check (getMonoTime() - t0).inMilliseconds < 1500
    health.setStatus("a.B", hsNotServing)
    check call.nextStatus == hsNotServing
    call.cancel()
    call.close()
    # a name nobody has set: SERVICE_UNKNOWN, then the status once it is set
    var other = ch.newCall(watchPath, timeoutMs = 20000)
    other.send(encodeHealthRequest("later.C"))
    check other.nextStatus == hsServiceUnknown
    health.setStatus("later.C", hsServing)
    check other.nextStatus == hsServing
    other.cancel()
    other.close()
    ch.close()
    srv.stop()                           # does not hang on the watchers

  test "shutdown: everything NOT_SERVING, and it stays so":
    let health = newHealth()
    health.setStatus("a.B", hsServing)
    let srv = newGrpcServer()
    srv.register(health)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    var call = ch.newCall(watchPath, timeoutMs = 20000)
    call.send(encodeHealthRequest(""))
    check call.nextStatus == hsServing
    health.shutdown()
    check call.nextStatus == hsNotServing         # the watcher is told
    check ch.checkOf("") == hsNotServing
    check ch.checkOf("a.B") == hsNotServing
    health.setStatus("a.B", hsServing)            # ignored
    check ch.checkOf("a.B") == hsNotServing
    call.cancel()
    call.close()
    ch.close()
    srv.stop()

proc asyncPart(port: int; health: Health): Future[(seq[HealthStatus], seq[StatusCode])] {.async.} =
  var got: seq[HealthStatus]
  var codes: seq[StatusCode]
  let ch = await dialAsync("127.0.0.1", port)
  let r = await ch.unaryCall(checkPath, encodeHealthRequest(""), timeoutMs = 3000)
  got.add decodeHealthResponse(r.message)
  try:
    discard await ch.unaryCall(checkPath, encodeHealthRequest("nobody"), timeoutMs = 3000)
    codes.add scOk
  except GrpcError as e:
    codes.add e.code
  let listed = await ch.unaryCall(listPath, newSeq[byte](), timeoutMs = 3000)
  got.add decodeHealthList(listed.message).getOrDefault("", hsUnknown)
  let call = await ch.newCall(watchPath, timeoutMs = 20000)
  await call.send(encodeHealthRequest("s"))
  var m = await call.recv()
  got.add decodeHealthResponse(m.get)           # SERVICE_UNKNOWN
  health.setStatus("s", hsServing)
  m = await call.recv()
  got.add decodeHealthResponse(m.get)           # SERVING
  health.shutdown()
  m = await call.recv()
  got.add decodeHealthResponse(m.get)           # NOT_SERVING
  call.cancel()
  await ch.close()
  return (got, codes)

suite "the chronos server":
  test "Check, Watch and shutdown":
    let health = newHealth()
    let srv = newAsyncGrpcServer()
    srv.register(health)
    srv.start()
    let (got, codes) = waitFor asyncPart(srv.port, health)
    check got == @[hsServing, hsServing, hsServiceUnknown, hsServing, hsNotServing]
    check codes == @[scNotFound]
    waitFor srv.stop()
