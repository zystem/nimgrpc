## The health client: checkHealth, isServing, waitServing and watchHealth, blocking and chronos.

import std/[unittest, options, monotimes, times, os]
import pkg/chronos
import nimgrpc
import nimgrpc/[health, healthclient]
import nimgrpc/[asyncclient, asyncserver]
from nimgrpc/client as bc import nil

suite "the blocking health client":
  test "checkHealth, isServing and a name nobody set":
    let h = newHealth()
    h.setStatus("a.B", hsNotServing)
    let srv = newGrpcServer()
    srv.register(h)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    check ch.checkHealth() == hsServing
    check ch.checkHealth("a.B") == hsNotServing
    check ch.checkHealth("nobody") == hsServiceUnknown        # NOT_FOUND is an answer
    check ch.isServing()
    check not ch.isServing("a.B")
    check not ch.isServing("nobody")
    ch.close()
    srv.stop()

  test "a server without the service: UNIMPLEMENTED is raised, isServing is false":
    let srv = newGrpcServer()
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    var code = scOk
    try: discard ch.checkHealth()
    except GrpcError as e: code = e.code
    check code == scUnimplemented
    check not ch.isServing()
    ch.close()
    srv.stop()

  test "waitServing waits for the status, and gives up":
    let h = newHealth()
    h.setStatus("slow.S", hsNotServing)
    let srv = newGrpcServer()
    srv.register(h)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    var th: Thread[Health]
    proc later(hh: Health) {.thread.} =
      sleep 400
      hh.setStatus("slow.S", hsServing)    # a handle: usable from any thread
    createThread(th, later, h)
    let t0 = getMonoTime()
    check ch.waitServing("slow.S", timeoutMs = 5000, pollMs = 50)
    check (getMonoTime() - t0).inMilliseconds >= 300
    joinThread(th)
    h.setStatus("never.N", hsNotServing)
    let t1 = getMonoTime()
    check not ch.waitServing("never.N", timeoutMs = 400, pollMs = 50)
    check (getMonoTime() - t1).inMilliseconds >= 350
    ch.close()
    srv.stop()

  test "watchHealth: the status now and each change; none once the server ends the call":
    let h = newHealth()
    let srv = newGrpcServer()
    srv.register(h)
    srv.start()
    let ch = bc.dial("127.0.0.1", srv.port)
    var w = ch.watchHealth("")
    check w.next == some(hsServing)
    h.setStatus("", hsNotServing)
    check w.next == some(hsNotServing)
    w.close()
    check w.next.isNone                                       # closed
    ch.close()
    srv.stop()

var asyncResults: seq[string]

proc asyncPart(port: int; h: Health): Future[seq[string]] {.async.} =
  var res: seq[string]
  let ch = await dialAsync("127.0.0.1", port)
  res.add $(await ch.checkHealth())
  res.add $(await ch.checkHealth("nobody"))
  res.add $(await ch.isServing())
  h.setStatus("w.W", hsNotServing)
  let w = await ch.watchHealth("w.W")
  var m = await w.next()
  res.add $m.get
  h.setStatus("w.W", hsServing)
  m = await w.next()
  res.add $m.get
  w.close()
  res.add $(await ch.waitServing("w.W", timeoutMs = 2000))
  h.setStatus("w.W", hsNotServing)
  res.add $(await ch.waitServing("w.W", timeoutMs = 300, pollMs = 50))
  await ch.close()
  return res

suite "the chronos health client":
  test "the same on a chronos channel":
    let h = newHealth()
    let srv = newAsyncGrpcServer()
    srv.register(h)
    srv.start()
    let res = waitFor asyncPart(srv.port, h)
    check res == @["hsServing", "hsServiceUnknown", "true", "hsNotServing", "hsServing", "true", "false"]
    waitFor srv.stop()
