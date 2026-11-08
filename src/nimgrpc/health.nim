## The gRPC health checking protocol (grpc.health.v1.Health), for both servers.
##
## Kubernetes (the native `grpc` probe), Envoy, grpc_health_probe and the health checking of
## gRPC clients ask a server whether it is ready with this service:
##
## ```nim
## let health = newHealth()                   # "" (the whole server) is SERVING
## srv.register(health)                       # GrpcServer or AsyncGrpcServer
## health.setStatus("my.pkg.Greeter", hsNotServing)   # while it warms up, say
## ...
## health.shutdown()                          # before `stop`: every service NOT_SERVING
## ```
##
## `Check` answers with the status of a service, or NOT_FOUND for a name nobody has set;
## `Watch` sends the status and then every change, until the client leaves; `List` gives all
## the services and their statuses at once.
## Thread-safe: set statuses from any thread.

import std/[locks, tables, options]
import ./protobuf, ./status, ./server, ./asyncserver
import pkg/chronos

export status

type
  HealthStatus* = enum
    hsUnknown = 0         ## UNKNOWN
    hsServing = 1         ## SERVING
    hsNotServing = 2      ## NOT_SERVING
    hsServiceUnknown = 3  ## SERVICE_UNKNOWN: only in an answer to `Watch` for a name nobody set

  HealthObj = object
    lock: Lock
    statuses: Table[string, HealthStatus]
    version: int          ## raised by every change, so that a `Watch` sees there was one
    shuttingDown: bool

  Health* = ref HealthObj
    ## The statuses of the services of a server. Keep it alive as long as the server runs.

const
  checkPath* = "/grpc.health.v1.Health/Check"
  watchPath* = "/grpc.health.v1.Health/Watch"
  listPath* = "/grpc.health.v1.Health/List"
  watchPollMs = 200      ## how often a `Watch` looks for a change

proc newHealth*(): Health =
  ## A health service that says SERVING for the server as a whole (the empty name).
  result = Health()
  initLock(result.lock)
  result.statuses = {"": hsServing}.toTable

proc setStatus*(h: Health; service: string; status: HealthStatus) =
  ## Sets the status of `service` ("" is the server as a whole). Ignored after `shutdown`.
  acquire(h.lock)
  if not h.shuttingDown and h.statuses.getOrDefault(service, hsServiceUnknown) != status:
    h.statuses[service] = status
    inc h.version
  release(h.lock)

proc clearStatus*(h: Health; service: string) =
  ## Forgets `service`: it is unknown again (`Check` answers NOT_FOUND).
  acquire(h.lock)
  if not h.shuttingDown and service in h.statuses:
    h.statuses.del service
    inc h.version
  release(h.lock)

proc shutdown*(h: Health) =
  ## Every service becomes NOT_SERVING and stays so: `setStatus` no longer changes anything.
  ## Call it first when the server is going down, so that load balancers and probes stop sending
  ## traffic before `stop` ends the calls.
  acquire(h.lock)
  for k, v in h.statuses.mpairs: v = hsNotServing
  h.shuttingDown = true
  inc h.version
  release(h.lock)

proc statusOf*(h: Health; service: string): HealthStatus =
  ## The status of `service`; `hsServiceUnknown` if nobody set it.
  acquire(h.lock)
  result = h.statuses.getOrDefault(service, hsServiceUnknown)
  release(h.lock)

# ---------------------------------------------------------------- the messages

proc encodeHealthRequest*(service: string): seq[byte] =
  ## HealthCheckRequest { string service = 1; }
  var w = PbWriter()
  if service.len > 0:
    w.putTag(1, wtLen)
    w.putString(service)
  w.buf

proc decodeHealthRequest*(data: openArray[byte]): string =
  var r = initReader(data)
  while r.pos < r.len:
    let tag = r.getVarint()
    let field = int(tag shr 3)
    let wt = WireType(int(tag and 7))
    if field == 1 and wt == wtLen: result = r.getString()
    else: r.skipField(wt, field)

proc encodeHealthResponse*(status: HealthStatus): seq[byte] =
  ## HealthCheckResponse { ServingStatus status = 1; }
  var w = PbWriter()
  if status != hsUnknown:
    w.putTag(1, wtVarint)
    w.putVarint(uint64(ord(status)))
  w.buf

proc decodeHealthResponse*(data: openArray[byte]): HealthStatus =
  var r = initReader(data)
  while r.pos < r.len:
    let tag = r.getVarint()
    let field = int(tag shr 3)
    let wt = WireType(int(tag and 7))
    if field == 1 and wt == wtVarint:
      let v = int(r.getVarint())
      result = if v in 0 .. 3: HealthStatus(v) else: hsUnknown
    else: r.skipField(wt, field)

proc encodeHealthList*(statuses: openArray[(string, HealthStatus)]): seq[byte] =
  ## HealthListResponse { map<string, HealthCheckResponse> statuses = 1; }: one entry per service,
  ## each a message with the name (1) and a HealthCheckResponse (2).
  var w = PbWriter()
  for (service, st) in statuses:
    var entry = PbWriter()
    entry.putTag(1, wtLen)
    entry.putString(service)
    entry.putTag(2, wtLen)
    entry.putBytes(encodeHealthResponse(st))
    w.putTag(1, wtLen)
    w.putBytes(entry.buf)
  w.buf

proc decodeHealthList*(data: openArray[byte]): Table[string, HealthStatus] =
  var r = initReader(data)
  while r.pos < r.len:
    let tag = r.getVarint()
    let field = int(tag shr 3)
    let wt = WireType(int(tag and 7))
    if field == 1 and wt == wtLen:
      let entry = r.getBytes()
      var e = initReader(entry)
      var name = ""
      var st = hsUnknown
      while e.pos < e.len:
        let t2 = e.getVarint()
        let f2 = int(t2 shr 3)
        let w2 = WireType(int(t2 and 7))
        if f2 == 1 and w2 == wtLen: name = e.getString()
        elif f2 == 2 and w2 == wtLen: st = decodeHealthResponse(e.getBytes())
        else: e.skipField(w2, f2)
      result[name] = st
    else: r.skipField(wt, field)

proc snapshot(h: ptr HealthObj): seq[(string, HealthStatus)] =
  acquire(h.lock)
  for k, v in h.statuses.pairs: result.add (k, v)
  release(h.lock)

# ---------------------------------------------------------------- the blocking server

proc healthOf(userData: pointer): ptr HealthObj = cast[ptr HealthObj](userData)

proc requested(request: seq[byte]): string {.raises: [CatchableError].} =
  try: decodeHealthRequest(request)
  except ProtobufError as e: raise newGrpcError(scInvalidArgument, "bad HealthCheckRequest: " & e.msg)

proc rawCheck(ctx: var ServerContext; request: seq[byte]; userData: pointer): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  let h = healthOf(userData)
  let service = requested(request)
  acquire(h.lock)
  let known = service in h.statuses
  let st = h.statuses.getOrDefault(service, hsServiceUnknown)
  release(h.lock)
  if not known: raise newGrpcError(scNotFound, "unknown service " & service)
  encodeHealthResponse(st)

proc rawWatch(ctx: var ServerContext; call: var ServerCall; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  let h = healthOf(userData)
  var request: seq[byte]
  if not call.recv(request): raise newGrpcError(scInvalidArgument, "no HealthCheckRequest")
  let service = requested(request)
  var sent = -1
  var last = hsUnknown
  while true:
    acquire(h.lock)
    let version = h.version
    let st = h.statuses.getOrDefault(service, hsServiceUnknown)
    release(h.lock)
    if version != sent and (sent < 0 or st != last):
      call.send(encodeHealthResponse(st))
      last = st
    sent = version
    ctx.sleep(watchPollMs)           # raises once the client has gone, or the deadline passed

proc rawList(ctx: var ServerContext; request: seq[byte]; userData: pointer): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  encodeHealthList(snapshot(healthOf(userData)))

proc register*(srv: GrpcServer; h: Health) =
  ## Adds `Check` and `Watch` to a blocking server (before `start`).
  GC_ref(h)                          # the handlers reach it through a pointer
  let p = cast[pointer](h)
  srv.addUnaryRaw(checkPath, rawCheck, p)
  srv.addStreamingRaw(watchPath, rawWatch, p)
  srv.addUnaryRaw(listPath, rawList, p)

# ---------------------------------------------------------------- the chronos server

proc register*(srv: AsyncGrpcServer; h: Health) =
  ## Adds `Check` and `Watch` to a chronos server (before `start`).
  let hp = cast[ptr HealthObj](h)
  proc check(ctx: AsyncServerContext; request: seq[byte]): Future[seq[byte]] {.async.} =
    let service = requested(request)
    acquire(hp.lock)
    let known = service in hp.statuses
    let st = hp.statuses.getOrDefault(service, hsServiceUnknown)
    release(hp.lock)
    if not known: raise newGrpcError(scNotFound, "unknown service " & service)
    return encodeHealthResponse(st)
  proc watch(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
    let first = await call.recv()
    if first.isNone: raise newGrpcError(scInvalidArgument, "no HealthCheckRequest")
    let service = requested(first.get)
    var sent = -1
    var last = hsUnknown
    while not ctx.isCancelled:
      acquire(hp.lock)
      let version = hp.version
      let st = hp.statuses.getOrDefault(service, hsServiceUnknown)
      release(hp.lock)
      if version != sent and (sent < 0 or st != last):
        await call.send(encodeHealthResponse(st))
        last = st
      sent = version
      await sleepAsync(watchPollMs.milliseconds)
    ctx.checkCancelled()
  proc list(ctx: AsyncServerContext; request: seq[byte]): Future[seq[byte]] {.async.} =
    return encodeHealthList(snapshot(hp))
  GC_ref(h)
  srv.addUnary(checkPath, check)
  srv.addStreaming(watchPath, watch)
  srv.addUnary(listPath, list)
