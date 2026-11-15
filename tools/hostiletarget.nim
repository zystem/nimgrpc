## The server tools/hostile.py attacks: health, reflection, a unary echo and a streaming echo,
## on the blocking or on the chronos server, with the limits a server facing strangers sets.
##   nim c -d:release tools/hostiletarget.nim && tools/hostiletarget blocking 47100

import std/[os, strutils, options]
import pkg/chronos
import nimgrpc
import nimgrpc/[health, reflection, asyncserver]

const callLimitMs = 3000     ## Limits.maxCallMs: what bounds a streaming call left quiet

proc echoUnary(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req

proc echoStream(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var msg: seq[byte]
  while call.recv(msg): call.send(msg)

proc echoUnaryAsync(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} =
  return req

proc echoStreamAsync(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
  while true:
    let m = await call.recv()
    if m.isNone: break
    await call.send(m.get)

if paramCount() != 2 or paramStr(1) notin ["blocking", "async"]:
  quit "usage: hostiletarget blocking|async PORT"
let port = parseInt(paramStr(2))
let limits = Limits(maxCallMs: callLimitMs)
if paramStr(1) == "blocking":
  let srv = newGrpcServer(port, limits = limits)
  srv.addUnary("/t.T/Echo", echoUnary)
  srv.addStreaming("/t.T/Stream", echoStream)
  srv.register(newHealth())
  srv.register(newReflection())
  srv.start()
  echo "listening on ", srv.port
  while true: sleep(1000)
else:
  let srv = newAsyncGrpcServer(port = port, limits = limits)
  srv.addUnary("/t.T/Echo", echoUnaryAsync)
  srv.addStreaming("/t.T/Stream", echoStreamAsync)
  srv.register(newHealth())
  srv.register(newReflection())
  srv.start()
  echo "listening on ", port
  runForever()
