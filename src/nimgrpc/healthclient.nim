## Asking a server whether it is healthy, with the gRPC health checking protocol
## (grpc.health.v1.Health), on the blocking and the chronos channels.
##
## ```nim
## let ch = dial("127.0.0.1", 50051)
## if ch.isServing("my.pkg.Greeter"): ...          # false on NOT_SERVING, unknown, or any error
## let st = ch.checkHealth()                       # hsServing, hsNotServing, hsServiceUnknown
## discard ch.waitServing(timeoutMs = 10_000)      # until the server as a whole is SERVING
## var w = ch.watchHealth("my.pkg.Greeter")        # the status now, then each change
## while (let s = w.next(); s.isSome): echo s.get
## ```

import std/[options, os, monotimes, times]
import pkg/chronos
import ./health, ./status
import ./client as bc
import ./asyncclient as ac

export health.HealthStatus

# ---------------------------------------------------------------- blocking

proc checkHealth*(ch: bc.GrpcChannel; service = ""; timeoutMs = 3000): HealthStatus =
  ## The status of `service` ("" for the server as a whole). A name the server does not know is
  ## `hsServiceUnknown`; any other failure (UNAVAILABLE, a deadline, UNIMPLEMENTED) is raised as
  ## GrpcError.
  try:
    let r = bc.unaryCall(ch, checkPath, encodeHealthRequest(service), timeoutMs = timeoutMs)
    decodeHealthResponse(r.message)
  except GrpcError as e:
    if e.code == scNotFound: hsServiceUnknown else: raise e

proc isServing*(ch: bc.GrpcChannel; service = ""; timeoutMs = 3000): bool =
  ## True only when the answer is SERVING; every other answer and every failure is false, which
  ## is how a probe reads it.
  try: ch.checkHealth(service, timeoutMs) == hsServing
  except CatchableError: false

proc waitServing*(ch: bc.GrpcChannel; service = ""; timeoutMs = 10_000; pollMs = 200): bool =
  ## Asks until `service` is SERVING or `timeoutMs` has passed; true when it is.
  let t0 = getMonoTime()
  while true:
    if ch.isServing(service, min(timeoutMs, 3000)): return true
    if (getMonoTime() - t0).inMilliseconds >= timeoutMs: return false
    sleep pollMs

type HealthWatch* = object
  call: bc.ClientCall
  open: bool

proc watchHealth*(ch: bc.GrpcChannel; service = ""; timeoutMs = -1): HealthWatch =
  ## Starts `Watch`: `next` gives the status now and then each change.
  result.call = bc.newCall(ch, watchPath, timeoutMs = timeoutMs)
  bc.send(result.call, encodeHealthRequest(service))
  result.open = true

proc next*(w: var HealthWatch): Option[HealthStatus] =
  ## The next status, waiting for it; `none` when the server ended the call (the caller may watch
  ## again after a while). Failures are raised as GrpcError.
  if not w.open: return none(HealthStatus)
  var msg: seq[byte]
  if bc.recv(w.call, msg): some(decodeHealthResponse(msg))
  else:
    w.open = false
    none(HealthStatus)

proc close*(w: var HealthWatch) =
  if w.open:
    bc.cancel(w.call)
    w.open = false
  bc.close(w.call)

# ---------------------------------------------------------------- chronos

proc checkHealth*(ch: ac.AsyncChannel; service = ""; timeoutMs = 3000): Future[HealthStatus] {.async.} =
  ## As for the blocking channel.
  try:
    let r = await ac.unaryCall(ch, checkPath, encodeHealthRequest(service), timeoutMs = timeoutMs)
    return decodeHealthResponse(r.message)
  except GrpcError as e:
    if e.code == scNotFound: return hsServiceUnknown
    raise e

proc isServing*(ch: ac.AsyncChannel; service = ""; timeoutMs = 3000): Future[bool] {.async.} =
  try: return (await ch.checkHealth(service, timeoutMs)) == hsServing
  except CatchableError: return false

proc waitServing*(ch: ac.AsyncChannel; service = ""; timeoutMs = 10_000;
                  pollMs = 200): Future[bool] {.async.} =
  let t0 = Moment.now()
  while true:
    if await ch.isServing(service, min(timeoutMs, 3000)): return true
    if Moment.now() - t0 >= chronos.milliseconds(timeoutMs): return false
    await sleepAsync(chronos.milliseconds(pollMs))

type AsyncHealthWatch* = ref object
  call: ac.AsyncCall
  open: bool

proc watchHealth*(ch: ac.AsyncChannel; service = ""; timeoutMs = -1): Future[AsyncHealthWatch] {.async.} =
  let call = await ac.newCall(ch, watchPath, timeoutMs = timeoutMs)
  await ac.send(call, encodeHealthRequest(service))
  return AsyncHealthWatch(call: call, open: true)

proc next*(w: AsyncHealthWatch): Future[Option[HealthStatus]] {.async.} =
  if not w.open: return none(HealthStatus)
  let m = await ac.recv(w.call)
  if m.isSome: return some(decodeHealthResponse(m.get))
  w.open = false
  return none(HealthStatus)

proc close*(w: AsyncHealthWatch) =
  if w.open:
    ac.cancel(w.call)
    w.open = false
  ac.close(w.call)
