## Per-call interceptors: server and client, blocking and chronos.
##
## Server side: order, refusing a call, reading and setting metadata, what `proceed` raises,
## swallowing or replacing an error, no `proceed` / two `proceed`, non-gRPC errors, unknown
## methods, streaming handlers, health. Client side: metadata and deadline, `streaming`,
## errors, `newCall`, generated clients, and (blocking) one channel on many threads.

import std/[unittest, atomics, locks, typedthreads]
import pkg/chronos
import nimgrpc
import nimgrpc/[asyncclient, asyncserver, health]
import ./gen/echo_pb

proc toBytes(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))
proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(result[0].addr, b[0].unsafeAddr, b.len)

# ---------------------------------------------------------------- shared state

var logLock: Lock
logLock.initLock()
var logItems: seq[string]
var handlerRuns, interceptorCalls: Atomic[int]
var handlerCancelled, interceptorCancelled: Atomic[bool]

proc logAdd(s: string) {.gcsafe, raises: [].} =
  withLock logLock:
    {.cast(gcsafe).}:
      logItems.add s

proc logTake(): seq[string] =
  withLock logLock:
    {.cast(gcsafe).}:
      result = logItems
      logItems = @[]

proc resetState() =
  discard logTake()
  handlerRuns.store 0
  interceptorCalls.store 0
  handlerCancelled.store false
  interceptorCancelled.store false

type Outcome = object
  ## What a unary call gave: the reply, or the error.
  code: StatusCode
  msg, message: string
  headers, trailers: Metadata

proc recordError(path: string; e: ref CatchableError) {.nimcall, gcsafe, raises: [].} =
  logAdd "hook " & path & " " & e.msg

# chronos: `check` cannot run inside async procs (its formatter raises Exception).
var failures: seq[string]
template ck(cond: untyped) =
  if not cond:
    {.cast(gcsafe).}:
      failures.add astToStr(cond) & " (line " & $instantiationInfo().line & ")"
template run(f: untyped) =
  failures = @[]
  waitFor f
  check failures == newSeq[string]()

# ---------------------------------------------------------------- blocking side

proc echoHandler(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  discard handlerRuns.fetchAdd(1)
  logAdd "handler"
  ctx.headers.add ("x-h", "1")
  ctx.trailers.add ("x-t", "1")
  let s = req.toStr
  if s == "fail": raise newGrpcError(scNotFound, "nope")
  if s == "sleep": ctx.sleep(5000)
  toBytes("hi " & s & "|" & ctx.metadata.get("authorization"))

proc countHandler(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var m: seq[byte]
  discard call.recv(m)
  for i in 1 .. 3:
    call.send(toBytes($i & ":" & m.toStr & ":" & ctx.metadata.get("authorization")))
  discard handlerRuns.fetchAdd(1)
  logAdd "handler"

proc newBase(): GrpcServer =
  result = newGrpcServer()
  result.addUnary("/t.T/Echo", echoHandler)
  result.addStreaming("/t.T/Count", countHandler)
  result.setErrorHook(recordError)

proc named(ctx: var ServerContext; next: ServerNext; ud: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  let n = cast[ptr string](ud)[]
  logAdd n & "-before"
  next.proceed(ctx)
  logAdd n & "-after"

proc modal(ctx: var ServerContext; next: ServerNext; ud: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ## Does what the request's x-mode says.
  discard interceptorCalls.fetchAdd(1)
  case ctx.metadata.get("x-mode")
  of "refuse":
    ctx.trailers.add ("x-refused", "yes")
    raise newGrpcError(scPermissionDenied, "refused by interceptor")
  of "observe":
    logAdd "path=" & ctx.path & " probe=" & ctx.metadata.get("x-probe")
    ctx.headers.add ("x-early", "1")
    next.proceed(ctx)
    ctx.trailers.add ("x-late", "1")
  of "see":
    try: next.proceed(ctx)
    except GrpcError as e:
      logAdd "saw " & $e.code
      raise
  of "catch":
    try: next.proceed(ctx)
    except GrpcError as e: logAdd "caught " & $e.code
  of "replace":
    try: next.proceed(ctx)
    except GrpcError: raise newGrpcError(scDataLoss, "replaced")
  of "skip": discard
  of "twice":
    next.proceed(ctx)
    next.proceed(ctx)
  of "valueerr": raise newException(ValueError, "interceptor broke")
  else: next.proceed(ctx)

proc withToken(ctx: var ServerContext; next: ServerNext; ud: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ctx.trailers.add ("x-ud", cast[ptr string](ud)[])
  next.proceed(ctx)

proc pathLogger(ctx: var ServerContext; next: ServerNext; ud: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  logAdd "path " & ctx.path
  next.proceed(ctx)

var nameA = "A"
var nameB = "B"
var nameC = "C"
var token = "tok-1"

proc call(ch: GrpcChannel; path = "/t.T/Echo"; req = "x"; md: Metadata = @[];
          timeoutMs = -1): Outcome =
  try:
    let r = ch.unaryCall(path, toBytes(req), md, timeoutMs)
    result.message = r.message.toStr
    result.headers = r.headers
    result.trailers = r.trailers
  except GrpcError as e:
    result.code = e.code
    result.msg = e.msg
    result.trailers = e.trailers

suite "blocking server interceptors":
  setup:
    resetState()

  test "order: the first added is the outermost":
    let srv = newBase()
    srv.addInterceptor(named, nameA.addr)
    srv.addInterceptor(named, nameB.addr)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let o = ch.call()
    check o.code == scOk
    check o.message == "hi x|"
    check logTake() == @["A-before", "B-before", "handler", "B-after", "A-after"]
    ch.close()
    srv.stop()

  test "refusing before proceed: code, message and trailers reach the client, no handler":
    let srv = newBase()
    srv.addInterceptor(modal)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let o = ch.call(md = @[("x-mode", "refuse")])
    check o.code == scPermissionDenied
    check o.msg == "refused by interceptor"
    check o.trailers.get("x-refused") == "yes"
    check handlerRuns.load == 0
    ch.close()
    srv.stop()

  test "reads path and metadata; headers set before and trailers set after proceed arrive":
    let srv = newBase()
    srv.addInterceptor(modal)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let o = ch.call(md = @[("x-mode", "observe"), ("x-probe", "p1")])
    check o.code == scOk
    check logTake() == @["path=/t.T/Echo probe=p1", "handler"]
    check o.headers.get("x-early") == "1"
    check o.headers.get("x-h") == "1"
    check o.trailers.get("x-late") == "1"
    check o.trailers.get("x-t") == "1"
    ch.close()
    srv.stop()

  test "proceed raises what the handler raised; the client gets it unchanged":
    let srv = newBase()
    srv.addInterceptor(modal)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let o = ch.call(req = "fail", md = @[("x-mode", "see")])
    check o.code == scNotFound
    check o.msg == "nope"
    check logTake() == @["handler", "saw scNotFound"]
    ch.close()
    srv.stop()

  test "an interceptor that swallows the handler's error does not make the call OK":
    let srv = newBase()
    srv.addInterceptor(modal)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let o = ch.call(req = "fail", md = @[("x-mode", "catch")])
    check o.code == scNotFound
    check o.msg == "nope"
    check logTake() == @["handler", "caught scNotFound"]
    ch.close()
    srv.stop()

  test "an interceptor that raises a different GrpcError replaces the handler's":
    let srv = newBase()
    srv.addInterceptor(modal)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let o = ch.call(req = "fail", md = @[("x-mode", "replace")])
    check o.code == scDataLoss
    check o.msg == "replaced"
    ch.close()
    srv.stop()

  test "returning without proceed is INTERNAL and the handler does not run":
    let srv = newBase()
    srv.addInterceptor(modal)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let o = ch.call(md = @[("x-mode", "skip")])
    check o.code == scInternal
    check o.msg == "an interceptor returned without calling proceed"
    check handlerRuns.load == 0
    ch.close()
    srv.stop()

  test "proceed twice is INTERNAL and the handler ran once":
    let srv = newBase()
    srv.addInterceptor(modal)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let o = ch.call(md = @[("x-mode", "twice")])
    check o.code == scInternal
    check o.msg == "an interceptor called proceed twice"
    check handlerRuns.load == 1
    ch.close()
    srv.stop()

  test "an interceptor that raises a non-gRPC error: UNKNOWN to the client, the hook sees it":
    let srv = newBase()
    srv.addInterceptor(modal)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let o = ch.call(md = @[("x-mode", "valueerr")])
    check o.code == scUnknown
    check o.msg == "internal error"
    check logTake() == @["hook /t.T/Echo interceptor broke"]
    check handlerRuns.load == 0
    ch.close()
    srv.stop()

  test "an unknown method does not reach the interceptors":
    let srv = newBase()
    srv.addInterceptor(modal)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    check ch.call(path = "/t.T/Nope").code == scUnimplemented
    check interceptorCalls.load == 0
    check ch.call().code == scOk
    check interceptorCalls.load == 1
    ch.close()
    srv.stop()

  test "interceptors wrap a streaming handler; the code after proceed runs after it":
    let srv = newBase()
    srv.addInterceptor(named, nameA.addr)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    var c = ch.newCall("/t.T/Count")
    c.send(toBytes("q"))
    c.closeSend()
    var got: seq[string]
    var m: seq[byte]
    while c.recv(m): got.add m.toStr
    c.close()
    check got == @["1:q:", "2:q:", "3:q:"]
    check logTake() == @["A-before", "handler", "A-after"]
    ch.close()
    srv.stop()

  test "userData reaches the interceptor":
    let srv = newBase()
    srv.addInterceptor(withToken, token.addr)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    check ch.call().trailers.get("x-ud") == "tok-1"
    ch.close()
    srv.stop()

  test "a health Check goes through the interceptor":
    let srv = newBase()
    let h = newHealth()
    srv.register(h)
    srv.addInterceptor(pathLogger)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let r = ch.unaryCall(checkPath, encodeHealthRequest(""), timeoutMs = 5000)
    check decodeHealthResponse(r.message) == hsServing
    check logTake() == @["path /grpc.health.v1.Health/Check"]
    ch.close()
    srv.stop()
    h.close()

# ---------------------------------------------------------------- blocking client side

var clientCalls: Atomic[int]

proc cnamed(info: var ClientCallInfo; next: ClientNext; ud: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  let n = cast[ptr string](ud)[]
  logAdd n & "-before"
  next.proceed(info)
  logAdd n & "-after"

proc cmodal(info: var ClientCallInfo; next: ClientNext; ud: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ## Does what the call's x-cmode says; `ud` is the token.
  discard clientCalls.fetchAdd(1)
  case info.metadata.get("x-cmode")
  of "refuse": raise newGrpcError(scPermissionDenied, "client refused")
  of "observe":
    logAdd "streaming=" & $info.streaming & " path=" & info.path
    next.proceed(info)
    logAdd "after headers=" & info.headers.get("x-h") & " trailers=" & info.trailers.get("x-t")
  of "see":
    try: next.proceed(info)
    except GrpcError as e:
      logAdd "saw " & $e.code
      raise
  of "catch":
    try: next.proceed(info)
    except GrpcError as e: logAdd "caught " & $e.code
  of "skip": discard
  of "twice":
    next.proceed(info)
    next.proceed(info)
  of "afterraise":
    next.proceed(info)
    raise newGrpcError(scAborted, "raised after proceed")
  of "short":
    info.timeoutMs = 200
    next.proceed(info)
  of "token":
    info.metadata.add ("authorization", cast[ptr string](ud)[])
    next.proceed(info)
  else: next.proceed(info)

suite "blocking client interceptors":
  setup:
    resetState()

  test "adds metadata the handler sees":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    let o = ch.call(md = @[("x-cmode", "token")])
    check o.code == scOk
    check o.message == "hi x|tok-1"
    ch.close()
    srv.stop()

  test "changes the deadline":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    let o = ch.call(req = "sleep", md = @[("x-cmode", "short")])
    check o.code == scDeadlineExceeded
    ch.close()
    srv.stop()

  test "streaming is false for unaryCall and true for newCall; unary headers and trailers are filled":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    check ch.call(md = @[("x-cmode", "observe")]).code == scOk
    check logTake() == @["streaming=false path=/t.T/Echo", "handler",
                         "after headers=1 trailers=1"]
    var c = ch.newCall("/t.T/Count", @[("x-cmode", "observe")])
    c.send(toBytes("q"))
    c.closeSend()
    var m: seq[byte]
    while c.recv(m): discard
    c.close()
    let log = logTake()
    check log[0] == "streaming=true path=/t.T/Count"
    check "after headers= trailers=" in log   # proceed returns when the stream is open: before the handler
    ch.close()
    srv.stop()

  test "raising before proceed: the caller gets it and nothing is sent":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    let o = ch.call(md = @[("x-cmode", "refuse")])
    check o.code == scPermissionDenied
    check o.msg == "client refused"
    check handlerRuns.load == 0
    ch.close()
    srv.stop()

  test "proceed raises the call's error; the caller gets the same":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    let o = ch.call(req = "fail", md = @[("x-cmode", "see")])
    check o.code == scNotFound
    check o.msg == "nope"
    check logTake() == @["handler", "saw scNotFound"]
    ch.close()
    srv.stop()

  test "swallowing the error does not make the call succeed":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    let o = ch.call(req = "fail", md = @[("x-cmode", "catch")])
    check o.code == scNotFound
    check o.msg == "nope"
    ch.close()
    srv.stop()

  test "returning without proceed is INTERNAL; nothing is sent":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    let o = ch.call(md = @[("x-cmode", "skip")])
    check o.code == scInternal
    check o.msg == "an interceptor returned without calling proceed"
    check handlerRuns.load == 0
    ch.close()
    srv.stop()

  test "proceed twice is INTERNAL and the handler ran once":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    let o = ch.call(md = @[("x-cmode", "twice")])
    check o.code == scInternal
    check o.msg == "an interceptor called proceed twice"
    check handlerRuns.load == 1
    ch.close()
    srv.stop()

  test "order of two interceptors: the first added is the outermost":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cnamed, nameA.addr)
    ch.addInterceptor(cnamed, nameB.addr)
    check ch.call().code == scOk
    check logTake() == @["A-before", "B-before", "handler", "B-after", "A-after"]
    ch.close()
    srv.stop()

  test "newCall works end to end and the metadata reached the server":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    var c = ch.newCall("/t.T/Count", @[("x-cmode", "token")])
    c.send(toBytes("q"))
    c.closeSend()
    var got: seq[string]
    var m: seq[byte]
    while c.recv(m): got.add m.toStr
    c.close()
    check got == @["1:q:tok-1", "2:q:tok-1", "3:q:tok-1"]
    ch.close()
    srv.stop()

  test "raising after proceed on a newCall: the caller gets the error and the channel still works":
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    var code = scOk
    try:
      var c = ch.newCall("/t.T/Count", @[("x-cmode", "afterraise")])
      c.close()
    except GrpcError as e:
      code = e.code
    check code == scAborted
    let o = ch.call()
    check o.code == scOk
    check o.message == "hi x|"
    ch.close()
    srv.stop()

  test "a typed generated client goes through the interceptors":
    proc say(ctx: var ServerContext; req: EchoRequest): EchoReply {.nimcall, gcsafe.} =
      EchoReply(text: req.text & "|" & ctx.metadata.get("authorization"))
    let srv = newBase()
    srv.registerEcho(EchoHandlers(say: say))
    srv.addInterceptor(pathLogger)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    let r = newEchoClient(ch).say(EchoRequest(text: "hey"), @[("x-cmode", "token")])
    check r.text == "hey|tok-1"
    check logTake() == @["path /reflect.test.Echo/Say"]
    ch.close()
    srv.stop()

  test "one channel on several threads":
    type Arg = tuple[ch: GrpcChannel; ok: ptr Atomic[int]]
    proc worker(a: Arg) {.thread.} =
      for i in 0 ..< 50:
        try:
          let r = a.ch.unaryCall("/t.T/Echo", toBytes("t"), timeoutMs = 20000)
          if r.message.toStr == "hi t|": discard a.ok[].fetchAdd(1)
        except CatchableError:
          discard
    let srv = newBase()
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    ch.addInterceptor(cmodal, token.addr)
    clientCalls.store 0
    var ok: Atomic[int]
    var threads: array[4, Thread[Arg]]
    for t in threads.mitems: createThread(t, worker, (ch, ok.addr))
    for t in threads.mitems: joinThread(t)
    check ok.load == 200
    check clientCalls.load == 200
    ch.close()
    srv.stop()

# ---------------------------------------------------------------- chronos side

proc aEcho(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} =
  discard handlerRuns.fetchAdd(1)
  logAdd "handler"
  ctx.headers.add ("x-h", "1")
  ctx.trailers.add ("x-t", "1")
  let s = req.toStr
  if s == "fail": raise newGrpcError(scNotFound, "nope")
  if s == "sleep":
    try:
      await sleepAsync(10.seconds)
    except CancelledError as e:
      handlerCancelled.store true
      raise e
  return toBytes("hi " & s & "|" & ctx.metadata.get("authorization"))

proc aCount(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
  let m = await call.recv()
  for i in 1 .. 3:
    await call.send(toBytes($i & ":" & m.get.toStr & ":" & ctx.metadata.get("authorization")))
  discard handlerRuns.fetchAdd(1)
  logAdd "handler"

proc newABase(): AsyncGrpcServer =
  result = newAsyncGrpcServer()
  result.addUnary("/t.T/Echo", aEcho)
  result.addStreaming("/t.T/Count", aCount)
  result.setErrorHook(recordError)

proc aNamed(name: string): AsyncServerInterceptor =
  result = proc (ctx: AsyncServerContext; next: AsyncServerNext) {.async.} =
    logAdd name & "-before"
    await next()
    logAdd name & "-after"

proc aModal(ctx: AsyncServerContext; next: AsyncServerNext) {.async.} =
  ## Does what the request's x-mode says.
  discard interceptorCalls.fetchAdd(1)
  case ctx.metadata.get("x-mode")
  of "refuse":
    ctx.trailers.add ("x-refused", "yes")
    raise newGrpcError(scPermissionDenied, "refused by interceptor")
  of "observe":
    logAdd "path=" & ctx.path & " probe=" & ctx.metadata.get("x-probe")
    ctx.headers.add ("x-early", "1")
    await next()
    ctx.trailers.add ("x-late", "1")
  of "see":
    try: await next()
    except GrpcError as e:
      logAdd "saw " & $e.code
      raise e
  of "catch":
    try: await next()
    except GrpcError as e: logAdd "caught " & $e.code
  of "replace":
    try: await next()
    except GrpcError: raise newGrpcError(scDataLoss, "replaced")
  of "skip": discard
  of "twice":
    await next()
    await next()
  of "valueerr": raise newException(ValueError, "interceptor broke")
  of "watch":
    try: await next()
    except CancelledError as e:
      interceptorCancelled.store true
      raise e
  else: await next()

proc aPathLogger(ctx: AsyncServerContext; next: AsyncServerNext) {.async.} =
  logAdd "path " & ctx.path
  await next()

proc acall(ch: AsyncChannel; path = "/t.T/Echo"; req = "x"; md: Metadata = @[];
           timeoutMs = -1): Future[Outcome] {.async.} =
  var o: Outcome
  try:
    let r = await ch.unaryCall(path, toBytes(req), md, timeoutMs)
    o.message = r.message.toStr
    o.headers = r.headers
    o.trailers = r.trailers
  except GrpcError as e:
    o.code = e.code
    o.msg = e.msg
    o.trailers = e.trailers
  return o

proc aCountAll(ch: AsyncChannel; md: Metadata = @[]): Future[seq[string]] {.async.} =
  ## A whole Count call; the messages it gave.
  let c = await ch.newCall("/t.T/Count", md)
  await c.send(toBytes("q"))
  await c.closeSend()
  var got: seq[string]
  while true:
    let m = await c.recv()
    if m.isNone: break
    got.add m.get.toStr
  c.close()
  return got

suite "chronos server interceptors":
  setup:
    resetState()

  test "order: the first added is the outermost":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aNamed("A"))
      srv.addInterceptor(aNamed("B"))
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall()
      ck o.code == scOk
      ck o.message == "hi x|"
      ck logTake() == @["A-before", "B-before", "handler", "B-after", "A-after"]
      await ch.close()
      await srv.stop()
    run go()

  test "refusing before proceed: code, message and trailers reach the client, no handler":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall(md = @[("x-mode", "refuse")])
      ck o.code == scPermissionDenied
      ck o.msg == "refused by interceptor"
      ck o.trailers.get("x-refused") == "yes"
      ck handlerRuns.load == 0
      await ch.close()
      await srv.stop()
    run go()

  test "reads path and metadata; headers set before and trailers set after proceed arrive":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall(md = @[("x-mode", "observe"), ("x-probe", "p1")])
      ck o.code == scOk
      ck logTake() == @["path=/t.T/Echo probe=p1", "handler"]
      ck o.headers.get("x-early") == "1"
      ck o.headers.get("x-h") == "1"
      ck o.trailers.get("x-late") == "1"
      ck o.trailers.get("x-t") == "1"
      await ch.close()
      await srv.stop()
    run go()

  test "next() raises what the handler raised; the client gets it unchanged":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall(req = "fail", md = @[("x-mode", "see")])
      ck o.code == scNotFound
      ck o.msg == "nope"
      ck logTake() == @["handler", "saw scNotFound"]
      await ch.close()
      await srv.stop()
    run go()

  test "an interceptor that swallows the handler's error does not make the call OK":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall(req = "fail", md = @[("x-mode", "catch")])
      ck o.code == scNotFound
      ck o.msg == "nope"
      ck logTake() == @["handler", "caught scNotFound"]
      await ch.close()
      await srv.stop()
    run go()

  test "an interceptor that raises a different GrpcError replaces the handler's":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall(req = "fail", md = @[("x-mode", "replace")])
      ck o.code == scDataLoss
      ck o.msg == "replaced"
      await ch.close()
      await srv.stop()
    run go()

  test "returning without next() is INTERNAL and the handler does not run":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall(md = @[("x-mode", "skip")])
      ck o.code == scInternal
      ck o.msg == "an interceptor returned without calling proceed"
      ck handlerRuns.load == 0
      await ch.close()
      await srv.stop()
    run go()

  test "next() twice is INTERNAL and the handler ran once":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall(md = @[("x-mode", "twice")])
      ck o.code == scInternal
      ck o.msg == "an interceptor called proceed twice"
      ck handlerRuns.load == 1
      await ch.close()
      await srv.stop()
    run go()

  test "an interceptor that raises a non-gRPC error: UNKNOWN to the client, the hook sees it":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall(md = @[("x-mode", "valueerr")])
      ck o.code == scUnknown
      ck o.msg == "internal error"
      ck logTake() == @["hook /t.T/Echo interceptor broke"]
      ck handlerRuns.load == 0
      await ch.close()
      await srv.stop()
    run go()

  test "an unknown method does not reach the interceptors":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ck (await ch.acall(path = "/t.T/Nope")).code == scUnimplemented
      ck interceptorCalls.load == 0
      ck (await ch.acall()).code == scOk
      ck interceptorCalls.load == 1
      await ch.close()
      await srv.stop()
    run go()

  test "interceptors wrap a streaming handler; the code after next() runs after it":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aNamed("A"))
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ck (await ch.aCountAll()) == @["1:q:", "2:q:", "3:q:"]
      ck logTake() == @["A-before", "handler", "A-after"]
      await ch.close()
      await srv.stop()
    run go()

  test "the client's deadline passes during the handler: DEADLINE_EXCEEDED, the interceptor is cancelled":
    proc go() {.async.} =
      let srv = newABase()
      srv.addInterceptor(aModal)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let o = await ch.acall(req = "sleep", md = @[("x-mode", "watch")], timeoutMs = 200)
      ck o.code == scDeadlineExceeded
      # the server notices a little later; wait for it, bounded
      var waited = 0
      while not (interceptorCancelled.load and handlerCancelled.load) and waited < 3000:
        await sleepAsync(10.milliseconds)
        waited += 10
      ck interceptorCancelled.load
      ck handlerCancelled.load
      await ch.close()
      await srv.stop()
    run go()

  test "a health Check goes through the interceptor":
    proc go() {.async.} =
      let srv = newABase()
      let h = newHealth()
      srv.register(h)
      srv.addInterceptor(aPathLogger)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      let r = await ch.unaryCall(checkPath, encodeHealthRequest(""), timeoutMs = 5000)
      ck decodeHealthResponse(r.message) == hsServing
      ck logTake() == @["path /grpc.health.v1.Health/Check"]
      await ch.close()
      await srv.stop()
      h.close()
    run go()

# ---------------------------------------------------------------- chronos client side

proc aCNamed(name: string): AsyncClientInterceptor =
  result = proc (info: AsyncCallInfo; next: AsyncClientNext) {.async.} =
    logAdd name & "-before"
    await next()
    logAdd name & "-after"

proc aCModal(info: AsyncCallInfo; next: AsyncClientNext) {.async.} =
  ## Does what the call's x-cmode says.
  case info.metadata.get("x-cmode")
  of "refuse": raise newGrpcError(scPermissionDenied, "client refused")
  of "observe":
    logAdd "streaming=" & $info.streaming & " path=" & info.path
    await next()
    logAdd "after headers=" & info.headers.get("x-h") & " trailers=" & info.trailers.get("x-t")
  of "see":
    try: await next()
    except GrpcError as e:
      logAdd "saw " & $e.code
      raise e
  of "catch":
    try: await next()
    except GrpcError as e: logAdd "caught " & $e.code
  of "skip": discard
  of "twice":
    await next()
    await next()
  of "afterraise":
    await next()
    raise newGrpcError(scAborted, "raised after proceed")
  of "short":
    info.timeoutMs = 200
    await next()
  of "token":
    info.metadata.add ("authorization", "tok-1")
    await next()
  else: await next()

suite "chronos client interceptors":
  setup:
    resetState()

  test "adds metadata the handler sees":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      let o = await ch.acall(md = @[("x-cmode", "token")])
      ck o.code == scOk
      ck o.message == "hi x|tok-1"
      await ch.close()
      await srv.stop()
    run go()

  test "changes the deadline":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      let o = await ch.acall(req = "sleep", md = @[("x-cmode", "short")])
      ck o.code == scDeadlineExceeded
      await ch.close()
      await srv.stop()
    run go()

  test "streaming is false for unaryCall and true for newCall; unary headers and trailers are filled":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      ck (await ch.acall(md = @[("x-cmode", "observe")])).code == scOk
      ck logTake() == @["streaming=false path=/t.T/Echo", "handler",
                        "after headers=1 trailers=1"]
      discard await ch.aCountAll(@[("x-cmode", "observe")])
      let log = logTake()
      ck log[0] == "streaming=true path=/t.T/Count"
      ck "after headers= trailers=" in log   # proceed returns when the stream is open
      await ch.close()
      await srv.stop()
    run go()

  test "raising before proceed: the caller gets it and nothing is sent":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      let o = await ch.acall(md = @[("x-cmode", "refuse")])
      ck o.code == scPermissionDenied
      ck o.msg == "client refused"
      ck handlerRuns.load == 0
      await ch.close()
      await srv.stop()
    run go()

  test "next() raises the call's error; the caller gets the same":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      let o = await ch.acall(req = "fail", md = @[("x-cmode", "see")])
      ck o.code == scNotFound
      ck o.msg == "nope"
      ck logTake() == @["handler", "saw scNotFound"]
      await ch.close()
      await srv.stop()
    run go()

  test "swallowing the error does not make the call succeed":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      let o = await ch.acall(req = "fail", md = @[("x-cmode", "catch")])
      ck o.code == scNotFound
      ck o.msg == "nope"
      await ch.close()
      await srv.stop()
    run go()

  test "returning without next() is INTERNAL; nothing is sent":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      let o = await ch.acall(md = @[("x-cmode", "skip")])
      ck o.code == scInternal
      ck o.msg == "an interceptor returned without calling proceed"
      ck handlerRuns.load == 0
      await ch.close()
      await srv.stop()
    run go()

  test "next() twice is INTERNAL and the handler ran once":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      let o = await ch.acall(md = @[("x-cmode", "twice")])
      ck o.code == scInternal
      ck o.msg == "an interceptor called proceed twice"
      ck handlerRuns.load == 1
      await ch.close()
      await srv.stop()
    run go()

  test "order of two interceptors: the first added is the outermost":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCNamed("A"))
      ch.addInterceptor(aCNamed("B"))
      ck (await ch.acall()).code == scOk
      ck logTake() == @["A-before", "B-before", "handler", "B-after", "A-after"]
      await ch.close()
      await srv.stop()
    run go()

  test "newCall works end to end and the metadata reached the server":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      ck (await ch.aCountAll(@[("x-cmode", "token")])) == @["1:q:tok-1", "2:q:tok-1", "3:q:tok-1"]
      await ch.close()
      await srv.stop()
    run go()

  test "raising after proceed on a newCall: the caller gets the error and the channel still works":
    proc go() {.async.} =
      let srv = newABase()
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      var code = scOk
      try:
        let c = await ch.newCall("/t.T/Count", @[("x-cmode", "afterraise")])
        c.close()
      except GrpcError as e:
        code = e.code
      ck code == scAborted
      let o = await ch.acall()
      ck o.code == scOk
      ck o.message == "hi x|"
      await ch.close()
      await srv.stop()
    run go()

  test "a typed generated client goes through the interceptors":
    proc say(ctx: AsyncServerContext; req: EchoRequest): Future[EchoReply] {.async.} =
      return EchoReply(text: req.text & "|" & ctx.metadata.get("authorization"))
    proc go() {.async.} =
      let srv = newABase()
      srv.registerEcho(EchoAsyncHandlers(say: say))
      srv.addInterceptor(aPathLogger)
      srv.start()
      let ch = await dialAsync("127.0.0.1", srv.port)
      ch.addInterceptor(aCModal)
      let r = await newEchoAsyncClient(ch).say(EchoRequest(text: "hey"), @[("x-cmode", "token")])
      ck r.text == "hey|tok-1"
      ck logTake() == @["path /reflect.test.Echo/Say"]
      await ch.close()
      await srv.stop()
    run go()
