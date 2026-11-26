## Blocking gRPC server.
##
## Every call runs on its own worker thread from the moment its HEADERS
## arrive. Register methods, then `start`; the method table is frozen once the
## server starts, so workers read it without a lock.
##
## * `addUnary`: one request message in, one reply out.
## * `addStreaming`: the handler gets a `ServerCall` and may `recv` and `send`
##   any number of messages in any order; this covers client-, server- and
##   bidirectional streaming.
##
## A handler ends the call by returning (status OK) or by raising GrpcError
## (any other status). Any other CatchableError becomes UNKNOWN with the fixed
## message "internal error": the exception text may hold paths or queries and is
## not sent to the client. `setErrorHook` gives the operator the real exception.

import std/[tables, strutils, algorithm, atomics]
import ./status, ./wire, ./h2/blocking, ./compress/gzip, ./tls/peerid
export status, blocking.TlsConfig, blocking.tlsClientConfig, blocking.tlsServerConfig,
       blocking.TlsError, blocking.Keepalive, blocking.PingPolicy, blocking.Limits, blocking.CipherOrder,
       blocking.setCipherOrder, blocking.setSessionLifetime, blocking.defaultSessionLifetime,
       peerid.PeerIdentity

type
  ServerContext* = object
    path*: string
    metadata*: Metadata      ## from the client, reserved headers removed
    timeoutMs*: int          ## the client's grpc-timeout, or -1
    headers*: Metadata       ## initial metadata to send back (before the first message)
    trailers*: Metadata      ## trailing metadata to send back
    requestCompressed*: bool ## whether the last request message was compressed
    responseCompression*: string
      ## "gzip" to compress responses; set before the first message is sent.
      ## Ignored if the client does not accept gzip.
    peer*: PeerIdentity
      ## Who the client is, when it authenticated with a certificate (mutual TLS, see
      ## `tlsServerConfig(clientCaPem = ...)`): `peer.authenticated`, and the names in the
      ## certificate. Read from the certificate alone, never from `metadata`. Without mutual TLS
      ## it is empty (`authenticated` is false).
    stream: ptr ServerStream

  ServerCall* = object
    st: ptr ServerStream
    ctx: ptr ServerContext
    msgs: MsgBuf                  ## received bytes not yet decoded
    inEnded: bool
    headersSent: bool
    maxMessage: int
    reqEncoding: string      ## the client's grpc-encoding
    clientAcceptsGzip: bool
    gzipOut: bool            ## responses carry grpc-encoding: gzip

  UnaryHandler* = proc (ctx: var ServerContext; request: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].}

  StreamingHandler* = proc (ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].}

  RawUnaryHandler* = proc (ctx: var ServerContext; request: seq[byte];
                           userData: pointer): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].}
    ## Like UnaryHandler, plus the pointer given at registration (used by
    ## generated code to reach the typed handler).

  RawStreamingHandler* = proc (ctx: var ServerContext; call: var ServerCall;
                               userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].}

  MethodKind = enum mkUnary, mkStreaming
  Method = object
    userData: pointer
    case kind: MethodKind
    of mkUnary: unary: RawUnaryHandler
    of mkStreaming: streaming: RawStreamingHandler

  ServerNext* = object
    ## The rest of a call, given to a `ServerInterceptor`: the interceptors added after it and
    ## then the handler. `proceed` runs it. Valid only while the interceptor runs.
    chain: ptr Chain
    level: int

  ServerInterceptor* = proc (ctx: var ServerContext; next: ServerNext; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].}
    ## Runs around every call to a registered method, on the worker thread of the call, before
    ## the request is decoded. It reads `ctx` (path, metadata, deadline), may set
    ## `ctx.headers` and `ctx.trailers`, and either calls `next.proceed(ctx)` once or raises
    ## GrpcError to refuse the call. `proceed` returns when the handler has returned and the
    ## response has been sent, and raises what the handler raised. `userData` is the pointer
    ## given to `addInterceptor`.

  Intercept = object
    fn: ServerInterceptor
    userData: pointer

  Chain = object
    ## One call on its way through the interceptors; lives on the stack of `handle`.
    reg: ptr Registry
    m: ptr Method
    call: ptr ServerCall
    reached: int                 ## how many levels `proceed` has entered
    failure: ref CatchableError  ## what the rest of the call raised, if it did

  ErrorHook* = proc (path: string; e: ref CatchableError) {.nimcall, gcsafe, raises: [].}
    ## Called, on the worker thread, with the method path and the exception of
    ## a handler that failed with anything but a GrpcError.

  Registry = object
    methods: Table[string, Method]
    maxMessage: int
    maxCallMs: int           ## `Limits.maxCallMs`
    maxStreamingCalls: int   ## `Limits.maxStreamingCalls`
    maxStreamingCallMs: int  ## `Limits.maxStreamingCallMs`
    streaming: Atomic[int]   ## streaming handlers that are running
    refusedStreaming: Atomic[int]   ## streaming calls answered RESOURCE_EXHAUSTED: over the quota
    errorHook: ErrorHook     ## read by workers without a lock: set before `start`
    interceptors: seq[Intercept]   ## the same; the first added is the outermost

  GrpcServer* = ref object
    reg: Registry
    h2: Server
    started: bool

# ---------------------------------------------------------------- ServerCall

proc toGrpc(e: ref H2Error): ref GrpcError =
  if e of H2Timeout: newGrpcError(scDeadlineExceeded, "deadline exceeded")
  else: newGrpcError(scCancelled, "call cancelled: " & e.msg)

proc recv*(call: var ServerCall; msg: var seq[byte]): bool =
  ## The next message from the client; false once the client has half-closed.
  ## Raises GrpcError (CANCELLED, DEADLINE_EXCEEDED, ...) if the call is gone.
  while true:
    var payload: seq[byte]
    var compressed = false
    if call.msgs.take(call.maxMessage, payload, compressed):
      if compressed:
        if call.reqEncoding != "gzip":
          raise newGrpcError(scInternal, "compressed message with grpc-encoding " &
                             call.reqEncoding.escape)
        msg = gzipDecompress(payload, call.maxMessage)
      else:
        msg = move payload
      call.ctx.requestCompressed = compressed
      return true
    if call.inEnded:
      if call.msgs.leftover > 0:
        raise newGrpcError(scInternal, "truncated message at end of stream")
      return false
    var chunk: seq[byte]
    var more: bool
    var err: ref GrpcError
    try:
      more = call.st[].recvData(chunk)
    except H2Error as e:
      err = e.toGrpc       # raised outside the except block (see threadBody)
    if err != nil: raise err
    if more: call.msgs.feed(chunk)
    else: call.inEnded = true

proc sendResponseHeaders(call: var ServerCall) =
  if call.headersSent: return
  var hs = @[(":status", "200"), ("content-type", grpcContentType), acceptEncodingHeader]
  if call.ctx.responseCompression == "gzip" and call.clientAcceptsGzip:
    hs.add ("grpc-encoding", "gzip")
    call.gzipOut = true
  hs.add call.ctx.headers.toWire
  var err: ref GrpcError
  try:
    call.st[].sendHeaders(hs)
  except H2Error as e:
    err = e.toGrpc
  if err != nil: raise err
  call.headersSent = true

proc send*(call: var ServerCall; msg: openArray[byte]; compressed: bool) =
  ## Sends one message, compressed if `compressed` and the response uses gzip
  ## (`ctx.responseCompression`, accepted by the client); otherwise plain.
  call.sendResponseHeaders()
  var err: ref GrpcError
  try:
    if compressed and call.gzipOut:
      let z = gzipCompress(msg)
      call.st[].sendData(z, head = frameHeader(z.len, true))
    else:
      call.st[].sendData(msg, head = frameHeader(msg.len))
  except H2Error as e:
    err = e.toGrpc
  if err != nil: raise err

proc send*(call: var ServerCall; msg: openArray[byte]) =
  ## Sends one message; the initial metadata (`ctx.headers`) goes out first.
  ## Compressed when the response uses gzip (see `ctx.responseCompression`).
  call.sendResponseHeaders()
  call.send(msg, call.gzipOut)

proc isCancelled*(call: ServerCall): bool =
  ## True once the client has gone away or reset the call.
  call.st[].isClosed

# ---------------------------------------------------------------- cancellation
#
# A handler runs on a thread nothing can interrupt, and `stop` waits for it.
# Long handlers should therefore notice when their call is over: the client
# cancelled or went away, the deadline passed, or the server is stopping
# (once the grace period ends the server closes the connections). Use
# `ctx.sleep` instead of `os.sleep`, and `ctx.checkCancelled()` in loops.

proc isCancelled*(ctx: ServerContext): bool =
  ## True once the call is over for the client: it cancelled, the
  ## connection closed (including a server `stop`), or the deadline passed.
  if ctx.stream == nil: return false
  ctx.stream[].isClosed or ctx.stream[].deadlinePassed

proc remainingMs*(ctx: ServerContext): int =
  ## Milliseconds left until the client's deadline, or -1 without one.
  if ctx.stream == nil: -1 else: ctx.stream[].remainingMs

proc checkCancelled*(ctx: ServerContext) =
  ## Raises GrpcError if the call is over: DEADLINE_EXCEEDED once the
  ## deadline passed, CANCELLED otherwise. Returns normally while the call
  ## is still on.
  if ctx.stream == nil: return
  if ctx.stream[].deadlinePassed:
    raise newGrpcError(scDeadlineExceeded, "deadline exceeded")
  if ctx.stream[].isClosed:
    raise newGrpcError(scCancelled, "call cancelled")

proc sleep*(ctx: ServerContext; ms: int) =
  ## Like `os.sleep`, but wakes up and raises (see `checkCancelled`) as soon
  ## as the call is over, instead of keeping the worker for the full `ms`. If
  ## the deadline comes first, raises DEADLINE_EXCEEDED when it is reached.
  if ctx.stream == nil: return
  let left = ctx.stream[].remainingMs
  let hitsDeadline = left >= 0 and left <= ms
  if ctx.stream[].waitClosed(ms):
    ctx.checkCancelled()
    raise newGrpcError(scCancelled, "call cancelled")
  if hitsDeadline:
    # The wait ended at the deadline (possibly a hair before it, by rounding).
    raise newGrpcError(scDeadlineExceeded, "deadline exceeded")

proc finishCall(call: var ServerCall; code: StatusCode; msg: string; md: Metadata) =
  ## Ends the call with a status: trailers after a response, or trailers-only.
  var hs: seq[Header]
  if not call.headersSent:
    hs = @[(":status", "200"), ("content-type", grpcContentType), acceptEncodingHeader]
  hs.add ("grpc-status", $ord(code))
  if msg.len > 0: hs.add ("grpc-message", encodeStatusMessage(msg))
  hs.add md.toWire
  try:
    if call.headersSent: call.st[].sendTrailers(hs)
    else: call.st[].sendHeaders(hs, endStream = true)
  except H2Error:
    discard     # the client is gone; nothing left to tell it

# ---------------------------------------------------------------- dispatch

proc runMethod(m: Method; ctx: var ServerContext; call: var ServerCall)
    {.gcsafe, raises: [CatchableError].} =
  case m.kind
  of mkUnary:
    var req: seq[byte]
    if not call.recv(req):
      raise newGrpcError(scUnimplemented, "unary call without a request message")
    var extra: seq[byte]
    if call.recv(extra):
      raise newGrpcError(scUnimplemented, "unary call with more than one request message")
    let reply = m.unary(ctx, req, m.userData)
    call.send(reply)
  of mkStreaming:
    m.streaming(ctx, call, m.userData)

proc proceed*(next: ServerNext; ctx: var ServerContext) {.gcsafe, raises: [CatchableError].} =
  ## Runs the rest of the call: the next interceptor, or the handler after the last one.
  ## Returns when the handler has returned and its response has been sent; raises what the
  ## handler (or an interceptor further in) raised. To be called once: a second call raises
  ## GrpcError(INTERNAL) and runs nothing.
  let c = next.chain
  if c.reached != next.level:
    raise newGrpcError(scInternal, "an interceptor called proceed twice")
  inc c.reached
  var failure: ref CatchableError
  try:
    if next.level < c.reg.interceptors.len:
      let i = c.reg.interceptors[next.level]
      i.fn(ctx, ServerNext(chain: c, level: next.level + 1), i.userData)
    else:
      runMethod(c.m[], ctx, c.call[])
  except CatchableError as e:
    failure = e
  if failure != nil:       # raised outside the except block (see threadBody)
    c.failure = failure
    raise failure

proc handle(st: var ServerStream; userData: pointer) {.nimcall, gcsafe, raises: [].} =
  let reg = cast[ptr Registry](userData)
  var ctx = ServerContext(timeoutMs: -1)
  var meth, contentType, encoding = ""
  var acceptsGzip, badTimeout = false
  for (k, v) in st.headers:
    case k
    of ":path": ctx.path = v
    of ":method": meth = v
    of "content-type": contentType = v
    of "grpc-timeout":
      ctx.timeoutMs = parseTimeout(v)
      badTimeout = ctx.timeoutMs < 0     # present but malformed: the call ends INTERNAL below
    of "grpc-encoding": encoding = v
    of "grpc-accept-encoding":
      for e in v.split(','):
        if e.strip == "gzip": acceptsGzip = true
    else: discard
  try:
    if meth != "POST":
      st.sendHeaders(@[(":status", "405")], endStream = true)
      return
    if not contentType.isGrpcContentType:
      st.sendHeaders(@[(":status", "415")], endStream = true)
      return
  except H2Error:
    return
  # The server's own limit on how long a call lasts: for a streaming call `maxStreamingCallMs`
  # replaces `maxCallMs` (0: it does not, -1: streaming calls have none).
  let isStreaming = ctx.path in reg.methods and reg.methods.getOrDefault(ctx.path).kind == mkStreaming
  let cap = if isStreaming and reg.maxStreamingCallMs != 0: reg.maxStreamingCallMs
            else: reg.maxCallMs
  if cap > 0 and (ctx.timeoutMs < 0 or ctx.timeoutMs > cap):
    st.setTimeout(cap)                 # the server's own limit; `ctx.timeoutMs` stays the client's
  else:
    st.setTimeout(ctx.timeoutMs, answer = true)   # the client's deadline: answer it with a status
  ctx.stream = st.addr
  ctx.metadata = fromWire(st.headers)
  let clientCert = st.peerCert()
  if clientCert.len > 0: ctx.peer = parsePeerCert(clientCert)
  var call = ServerCall(st: st.addr, ctx: ctx.addr, maxMessage: reg.maxMessage,
                        reqEncoding: encoding, clientAcceptsGzip: acceptsGzip)

  if encoding.len > 0 and encoding notin supportedEncodings:
    call.finishCall(scUnimplemented, "grpc-encoding " & encoding.escape &
                    " is not supported", @[])
    return
  if badTimeout:
    call.finishCall(scInternal, "malformed grpc-timeout", @[])
    return
  if ctx.path notin reg.methods:
    call.finishCall(scUnimplemented, "unknown method " & ctx.path, @[])
    return
  var m = reg.methods.getOrDefault(ctx.path)
  var counted = false
  if m.kind == mkStreaming and reg.maxStreamingCalls > 0:
    # Streaming calls hold their workers for as long as they last: past the quota the rest are
    # answered at once, and the workers they would have held stay for the unary calls.
    if reg.streaming.fetchAdd(1) >= reg.maxStreamingCalls:
      discard reg.streaming.fetchSub(1)
      discard reg.refusedStreaming.fetchAdd(1)
      call.finishCall(scResourceExhausted, "too many streaming calls", @[])
      return
    counted = true
  try:
    if reg.interceptors.len == 0:
      runMethod(m, ctx, call)
    else:
      var chain = Chain(reg: reg, m: m.addr, call: call.addr)
      ServerNext(chain: chain.addr, level: 0).proceed(ctx)
      # An interceptor that swallowed the error of the call (or lost it: Nim 2.2 can drop an
      # exception that passes through `finally`) does not turn the call into OK.
      if chain.failure != nil: raise chain.failure
      if chain.reached <= reg.interceptors.len:
        raise newGrpcError(scInternal, "an interceptor returned without calling proceed")
    call.finishCall(scOk, "", ctx.trailers)
  except GrpcError as e:
    call.finishCall(e.code, e.msg, ctx.trailers & e.trailers)
  except CatchableError as e:
    if reg.errorHook != nil: reg.errorHook(ctx.path, e)
    call.finishCall(scUnknown, "internal error", ctx.trailers)
  if counted: discard reg.streaming.fetchSub(1)

proc wholeRequest(headers: openArray[Header]; userData: pointer): int
    {.nimcall, gcsafe, raises: [].} =
  ## A unary call can do nothing before its one message is there, so it waits for it without a
  ## worker: a client that opens calls and never sends the message uses no thread.
  let reg = cast[ptr Registry](userData)
  for (k, v) in headers:
    if k == ":path":
      let m = reg.methods.getOrDefault(v)
      if m.kind == mkUnary and m.unary != nil: return reg.maxMessage + 5
      return 0
  0

# ---------------------------------------------------------------- server

proc newGrpcServer*(port = 0; address = "127.0.0.1"; maxWorkers = 256;
                    maxMessage = defaultMaxMessage; tls: TlsConfig = nil;
                    keepalive = Keepalive(); pingPolicy = PingPolicy();
                    limits = Limits()): GrpcServer =
  ## `address` is the interface to listen on: "127.0.0.1" (the default), "0.0.0.0", "::1" for
  ## IPv6 loopback, or "::" for IPv6 and IPv4 together.
  ## At most `maxWorkers` calls run at once; more wait for a free worker. A unary call takes
  ## its worker only once its request message has arrived, so calls that are opened and left
  ## without a message use no worker; a streaming call takes one from its start, for as long
  ## as its handler runs (`Limits.maxCallMs` bounds that).
  ## `limits` caps the streams of a connection, the connections and the bytes
  ## queued per connection (see `Limits`; 100 streams by default).
  ## With `tls` (see `tlsServerConfig`) clients must use TLS 1.2 with ALPN h2.
  ## `keepalive` pings idle clients; `pingPolicy` limits how often clients
  ## may ping (gRPC's enforcement policy; off by default).
  result = GrpcServer()
  result.reg.maxMessage = maxMessage
  result.reg.maxCallMs = limits.maxCallMs
  result.reg.maxStreamingCalls = limits.maxStreamingCalls
  result.reg.maxStreamingCallMs = limits.maxStreamingCallMs
  result.h2 = newStreamServer(handle, result.reg.addr, Port(port), address,
                              maxWorkers, tls, keepalive, pingPolicy, limits, wholeRequest)

proc addUnaryRaw*(s: GrpcServer; path: string; handler: RawUnaryHandler;
                  userData: pointer) =
  doAssert not s.started, "methods must be registered before start"
  s.reg.methods[path] = Method(kind: mkUnary, unary: handler, userData: userData)

proc addStreamingRaw*(s: GrpcServer; path: string; handler: RawStreamingHandler;
                      userData: pointer) =
  doAssert not s.started, "methods must be registered before start"
  s.reg.methods[path] = Method(kind: mkStreaming, streaming: handler, userData: userData)

proc setErrorHook*(s: GrpcServer; hook: ErrorHook) =
  ## `hook` sees every handler exception that is not a GrpcError (those are the
  ## handler's own answer); the client only gets UNKNOWN "internal error". It
  ## runs on the worker thread of the call, so it must be thread-safe. Without a
  ## hook nothing is logged. Set it before `start`.
  doAssert not s.started, "the error hook must be set before start"
  s.reg.errorHook = hook

proc addInterceptor*(s: GrpcServer; interceptor: ServerInterceptor; userData: pointer = nil) =
  ## `interceptor` runs around every call to a registered method, the health and reflection
  ## services included (it can tell them by `ctx.path`); a call to an unknown method does not
  ## reach it. The first one added is the outermost. It runs on the worker thread of the call,
  ## so it and what `userData` points to must be thread-safe, and `userData` must stay valid
  ## while the server runs. Add interceptors before `start`.
  doAssert not s.started, "interceptors must be added before start"
  doAssert interceptor != nil, "the interceptor is nil"
  s.reg.interceptors.add Intercept(fn: interceptor, userData: userData)

proc callUnary(ctx: var ServerContext; request: seq[byte]; userData: pointer): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  cast[UnaryHandler](userData)(ctx, request)

proc callStreaming(ctx: var ServerContext; call: var ServerCall; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  cast[StreamingHandler](userData)(ctx, call)

proc addUnary*(s: GrpcServer; path: string; handler: UnaryHandler) =
  ## `path` is "/package.Service/Method".
  s.addUnaryRaw(path, callUnary, cast[pointer](handler))

proc addStreaming*(s: GrpcServer; path: string; handler: StreamingHandler) =
  s.addStreamingRaw(path, callStreaming, cast[pointer](handler))

proc serviceNamesOf(reg: ptr Registry): seq[string] =
  ## The services of the registered methods ("/pkg.Svc/Method" -> "pkg.Svc"), sorted.
  for path in reg.methods.keys:
    if path.len > 1 and path[0] == '/':
      let slash = path.rfind('/')
      if slash > 1:
        let name = path[1 ..< slash]
        if name notin result: result.add name
  result.sort()

proc serviceNames*(s: GrpcServer): seq[string] =
  ## The services that have a method registered, sorted.
  serviceNamesOf(s.reg.addr)

proc registryHandle*(s: GrpcServer): pointer =
  ## For a handler that has to list the services of its own server later (see `servicesIn`):
  ## stable for as long as the server lives.
  cast[pointer](s.reg.addr)

proc servicesIn*(handle: pointer): seq[string] {.gcsafe.} =
  ## `serviceNames` of the server whose `registryHandle` this is; callable from a handler.
  serviceNamesOf(cast[ptr Registry](handle))

proc port*(s: GrpcServer): int = s.h2.port.int

type GrpcServerStats* = object
  ## What the limits hold and have refused, for monitoring: gauges go up and down, counters only grow.
  queuedCalls*: int       ## gauge, blocking server: calls waiting for a worker
  queuedBytes*: int       ## gauge, blocking server: bytes held for calls that have no worker
  refusedQueue*: int      ## counter, blocking server: refused, `maxQueuedCalls` were waiting
  refusedBytes*: int      ## counter, blocking server: refused at their headers, `maxQueuedBytes` held
  shedBytes*: int         ## counter, blocking server: waiting calls reset over `maxQueuedBytes`
  refusedStreaming*: int  ## counter: streaming calls answered RESOURCE_EXHAUSTED (`maxStreamingCalls`)
  runningStreaming*: int  ## gauge: streaming handlers that are running (counted with `maxStreamingCalls`)

proc stats*(s: GrpcServer): GrpcServerStats =
  ## The figures to put on a dashboard or an alert. A refusal rate that is not zero for long says a
  ## limit is too low, or that clients come in faster than the server can take them.
  let h = s.h2.stats()
  GrpcServerStats(queuedCalls: h.queuedCalls, queuedBytes: h.queuedBytes,
                  refusedQueue: h.refusedQueue, refusedBytes: h.refusedBytes,
                  shedBytes: h.shedBytes, refusedStreaming: s.reg.refusedStreaming.load,
                  runningStreaming: s.reg.streaming.load)

proc queueStats*(s: GrpcServer): tuple[calls, bytes: int] =
  ## Calls waiting for a worker, and the bytes held for the calls that have none (see
  ## `Limits.maxQueuedBytes`): a gauge for monitoring, and what the limits bound.
  s.h2.queueStats()

proc start*(s: GrpcServer) =
  s.started = true
  s.h2.start()

proc stop*(s: GrpcServer; graceMs = 0) =
  ## Stops the server. With `graceMs` > 0 clients get GOAWAY and calls in
  ## progress may finish for up to that long before they are cancelled.
  s.h2.stop(graceMs)
