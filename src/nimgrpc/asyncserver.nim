## gRPC server on chronos.
##
## The async twin of `nimgrpc/server`. Every call runs as a future on the event
## loop from the moment its HEADERS arrive, so thousands of calls cost no
## threads. Handlers are closures:
##
## * `addUnary`: one request message in, one reply out.
## * `addStreaming`: the handler gets an `AsyncServerCall` and may `recv`
##   and `send` any number of messages in any order (client-, server- and
##   bidirectional streaming).
##
## A handler ends the call by completing (status OK) or by failing with
## GrpcError (any other status); any other error becomes UNKNOWN with the fixed
## message "internal error" (the exception text is not sent to the client;
## `setErrorHook` gives it to the operator).
##
## When the call is over for the client (it cancelled, its deadline passed,
## the connection closed, the server stopped) the handler's future is
## cancelled: whatever it awaits fails with CancelledError, so long handlers
## need no polling. A handler that does long synchronous work between awaits
## can still check `ctx.isCancelled`.

import std/[tables, strutils, options, algorithm]
import pkg/chronos
import ./status, ./wire, ./h2/async, ./compress/gzip, ./tls/peerid
export status, options, async.TlsConfig, async.tlsClientConfig, async.tlsServerConfig,
       async.TlsError, async.Keepalive, async.PingPolicy, async.Limits, async.CipherOrder,
       async.setCipherOrder, async.setSessionLifetime, async.defaultSessionLifetime,
       peerid.PeerIdentity

type
  AsyncServerContext* = ref object
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
    stream: AsyncH2Stream

  AsyncServerCall* = ref object
    st: AsyncH2Stream
    ctx: AsyncServerContext
    msgs: MsgBuf                  ## received bytes not yet decoded
    inEnded: bool
    headersSent: bool
    maxMessage: int
    reqEncoding: string      ## the client's grpc-encoding
    clientAcceptsGzip: bool
    gzipOut: bool            ## responses carry grpc-encoding: gzip

  AsyncUnaryHandler* = proc (ctx: AsyncServerContext; request: seq[byte]): Future[seq[byte]]
    {.gcsafe, raises: [].}
  AsyncStreamingHandler* = proc (ctx: AsyncServerContext; call: AsyncServerCall): Future[void]
    {.gcsafe, raises: [].}
  ErrorHook* = proc (path: string; e: ref CatchableError) {.gcsafe, raises: [].}
    ## Called with the method path and the exception of a handler that failed
    ## with anything but a GrpcError.

  AsyncServerNext* = proc (): Future[void] {.gcsafe, raises: [].}
    ## The rest of a call, given to an `AsyncServerInterceptor`: the interceptors added after
    ## it and then the handler. Its future completes when the handler has completed and the
    ## response has been sent, and fails with what the handler failed with. To be called once:
    ## a second call fails with GrpcError(INTERNAL) and runs nothing.
  AsyncServerInterceptor* = proc (ctx: AsyncServerContext; next: AsyncServerNext): Future[void]
    {.gcsafe, raises: [].}
    ## Runs around every call to a registered method, before the request is decoded. It reads
    ## `ctx` (path, metadata, deadline), may set `ctx.headers` and `ctx.trailers`, and either
    ## awaits `next()` once or fails with GrpcError to refuse the call.

  MethodKind = enum mkUnary, mkStreaming
  Method = object
    case kind: MethodKind
    of mkUnary: unary: AsyncUnaryHandler
    of mkStreaming: streaming: AsyncStreamingHandler

  AsyncGrpcServer* = ref object
    methods: Table[string, Method]
    maxMessage: int
    port: int
    address: string
    tls: TlsConfig
    ka: Keepalive
    policy: PingPolicy
    limits: Limits
    streamingActive: int     ## streaming handlers that are running (`Limits.maxStreamingCalls`)
    refusedStreaming: int    ## streaming calls answered RESOURCE_EXHAUSTED: over the quota
    errorHook: ErrorHook
    interceptors: seq[AsyncServerInterceptor]   ## the first added is the outermost
    h2: AsyncH2Server

  Chain = ref object
    ## One call on its way through the interceptors.
    s: AsyncGrpcServer
    m: Method
    ctx: AsyncServerContext
    call: AsyncServerCall
    reached: int                 ## how many levels have been entered
    failure: ref CatchableError  ## what the rest of the call failed with, if it did

# ---------------------------------------------------------------- AsyncServerCall

proc toGrpc(e: ref H2Error): ref GrpcError =
  if e of H2Timeout: newGrpcError(scDeadlineExceeded, "deadline exceeded")
  else: newGrpcError(scCancelled, "call cancelled: " & e.msg)

proc recv*(call: AsyncServerCall): Future[Option[seq[byte]]] {.async.} =
  ## The next message from the client; `none` once the client has
  ## half-closed. Raises GrpcError (CANCELLED, DEADLINE_EXCEEDED, ...) if the
  ## call is gone.
  while true:
    var payload: seq[byte]
    var compressed = false
    if call.msgs.take(call.maxMessage, payload, compressed):
      var msg: seq[byte]
      if compressed:
        if call.reqEncoding != "gzip":
          raise newGrpcError(scInternal, "compressed message with grpc-encoding " &
                             call.reqEncoding.escape)
        msg = gzipDecompress(payload, call.maxMessage)
      else:
        msg = move payload
      call.ctx.requestCompressed = compressed
      return some(move msg)
    if call.inEnded:
      if call.msgs.leftover > 0:
        raise newGrpcError(scInternal, "truncated message at end of stream")
      return none(seq[byte])
    var chunk: seq[byte]
    var err: ref GrpcError
    try:
      chunk = await call.st.recvData()
    except H2Error as e:
      err = e.toGrpc
    if err != nil: raise err
    if chunk.len > 0: call.msgs.feed(chunk)
    else: call.inEnded = true

proc sendResponseHeaders(call: AsyncServerCall) =
  if call.headersSent: return
  var hs = @[(":status", "200"), ("content-type", grpcContentType), acceptEncodingHeader]
  if call.ctx.responseCompression == "gzip" and call.clientAcceptsGzip:
    hs.add ("grpc-encoding", "gzip")
    call.gzipOut = true
  hs.add call.ctx.headers.toWire
  var err: ref GrpcError
  try:
    call.st.sendHeaders(hs)
  except H2Error as e:
    err = e.toGrpc
  if err != nil: raise err
  call.headersSent = true

proc finishSend(call: AsyncServerCall; job: SendJob) {.async.} =
  var err: ref GrpcError
  try:
    await call.st.finish(job)
  except H2Error as e:
    err = e.toGrpc
  if err != nil: raise err

proc failed(e: ref CatchableError): Future[void] =
  result = newFuture[void]("grpc.send")
  result.fail(e)

proc send*(call: AsyncServerCall; msg: sink seq[byte]; compressed: bool): Future[void] =
  ## Sends one message, compressed if `compressed` and the response uses gzip
  ## (`ctx.responseCompression`, accepted by the client); otherwise plain.
  ## The message is handed to the connection without a copy.
  try:
    call.sendResponseHeaders()
    var body = if compressed and call.gzipOut: gzipCompress(msg) else: move msg
    let head = frameHeader(body.len, compressed and call.gzipOut)
    let job = try: call.st.push(body, head)
              except H2Error as e: raise e.toGrpc
    if job == nil: completed() else: call.finishSend(job)
  except GrpcError as e:
    failed(e)

proc send*(call: AsyncServerCall; msg: sink seq[byte]): Future[void] =
  ## Sends one message; the initial metadata (`ctx.headers`) goes out first.
  ## Compressed when the response uses gzip (see `ctx.responseCompression`).
  try:
    call.sendResponseHeaders()
  except GrpcError as e:
    return failed(e)
  call.send(msg, call.gzipOut)

proc isCancelled*(call: AsyncServerCall): bool =
  ## True once the client has gone away or reset the call.
  call.st.isClosed

# ---------------------------------------------------------------- cancellation

proc isCancelled*(ctx: AsyncServerContext): bool =
  ## True once the call is over for the client: it cancelled, the
  ## connection closed (including a server `stop`), or the deadline passed.
  if ctx.stream == nil: return false
  ctx.stream.isClosed or ctx.stream.deadlinePassed

proc remainingMs*(ctx: AsyncServerContext): int =
  ## Milliseconds left until the client's deadline, or -1 without one.
  if ctx.stream == nil: -1 else: ctx.stream.remainingMs

proc checkCancelled*(ctx: AsyncServerContext) =
  ## Raises GrpcError if the call is over: DEADLINE_EXCEEDED once the
  ## deadline passed, CANCELLED otherwise.
  if ctx.stream == nil: return
  if ctx.stream.deadlinePassed:
    raise newGrpcError(scDeadlineExceeded, "deadline exceeded")
  if ctx.stream.isClosed:
    raise newGrpcError(scCancelled, "call cancelled")

proc finishCall(call: AsyncServerCall; code: StatusCode; msg: string; md: Metadata) =
  ## Ends the call with a status: trailers after a response, or trailers-only.
  var hs: seq[Header]
  if not call.headersSent:
    hs = @[(":status", "200"), ("content-type", grpcContentType), acceptEncodingHeader]
  hs.add ("grpc-status", $ord(code))
  if msg.len > 0: hs.add ("grpc-message", encodeStatusMessage(msg))
  hs.add md.toWire
  try:
    if call.headersSent: call.st.sendTrailers(hs)
    else: call.st.sendHeaders(hs, endStream = true)
  except H2Error:
    discard     # the client is gone; nothing left to tell it

# ---------------------------------------------------------------- dispatch

proc runMethod(m: Method; ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
  case m.kind
  of mkUnary:
    let rf = call.recv()
    discard await rf
    if rf.read.isNone:
      raise newGrpcError(scUnimplemented, "unary call without a request message")
    var req = move rf.internalValue.get         # the future is not read again
    if (await call.recv()).isSome:
      raise newGrpcError(scUnimplemented, "unary call with more than one request message")
    let uf = m.unary(ctx, move req)
    discard await uf
    await call.send(move uf.internalValue)
  of mkStreaming:
    await m.streaming(ctx, call)

proc step(c: Chain; level: int): Future[void] {.async.} =
  ## Level `level` of the chain: an interceptor, or the handler after the last one.
  if c.reached != level:
    raise newGrpcError(scInternal, "an interceptor called proceed twice")
  inc c.reached
  var failure: ref CatchableError
  try:
    if level < c.s.interceptors.len:
      proc next(): Future[void] {.gcsafe, raises: [].} = c.step(level + 1)
      await c.s.interceptors[level](c.ctx, next)
    else:
      await runMethod(c.m, c.ctx, c.call)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    failure = e
  if failure != nil:
    c.failure = failure
    raise failure

proc handle(s: AsyncGrpcServer; st: AsyncH2Stream): Future[void] {.async: (raises: []).} =
  let ctx = AsyncServerContext(timeoutMs: -1)
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
  let isStreaming = ctx.path in s.methods and s.methods.getOrDefault(ctx.path).kind == mkStreaming
  let cap = if isStreaming and s.limits.maxStreamingCallMs != 0: s.limits.maxStreamingCallMs
            else: s.limits.maxCallMs
  if cap > 0 and (ctx.timeoutMs < 0 or ctx.timeoutMs > cap):
    st.setTimeout(cap)                 # the server's own limit; `ctx.timeoutMs` stays the client's
  else:
    st.setTimeout(ctx.timeoutMs, answer = true)   # the client's deadline: answer it with a status
  ctx.stream = st
  ctx.metadata = fromWire(st.headers)
  let clientCert = st.peerCert()
  if clientCert.len > 0: ctx.peer = parsePeerCert(clientCert)
  let call = AsyncServerCall(st: st, ctx: ctx, maxMessage: s.maxMessage,
                             reqEncoding: encoding, clientAcceptsGzip: acceptsGzip)
  if encoding.len > 0 and encoding notin supportedEncodings:
    call.finishCall(scUnimplemented, "grpc-encoding " & encoding.escape &
                    " is not supported", @[])
    return
  if badTimeout:
    call.finishCall(scInternal, "malformed grpc-timeout", @[])
    return
  if ctx.path notin s.methods:
    call.finishCall(scUnimplemented, "unknown method " & ctx.path, @[])
    return
  let m = s.methods.getOrDefault(ctx.path)
  var counted = false
  if m.kind == mkStreaming and s.limits.maxStreamingCalls > 0:
    if s.streamingActive >= s.limits.maxStreamingCalls:
      inc s.refusedStreaming
      call.finishCall(scResourceExhausted, "too many streaming calls", @[])
      return
    inc s.streamingActive
    counted = true
  try:
    if s.interceptors.len == 0:
      await runMethod(m, ctx, call)
    else:
      let chain = Chain(s: s, m: m, ctx: ctx, call: call)
      await chain.step(0)
      # An interceptor that swallowed the error of the call does not turn it into OK.
      if chain.failure != nil: raise chain.failure
      if chain.reached <= s.interceptors.len:
        raise newGrpcError(scInternal, "an interceptor returned without calling proceed")
    call.finishCall(scOk, "", ctx.trailers)
  except CancelledError:
    # The call is over for the client and its stream is closed, unless the client's deadline
    # passed: that stream is still open, and the client is told.
    if st.deadlinePassed and not st.isClosed:
      call.finishCall(scDeadlineExceeded, "deadline exceeded", ctx.trailers)
  except GrpcError as e:
    call.finishCall(e.code, e.msg, ctx.trailers & e.trailers)
  except CatchableError as e:
    if s.errorHook != nil: s.errorHook(ctx.path, e)
    call.finishCall(scUnknown, "internal error", ctx.trailers)
  if counted: dec s.streamingActive

# ---------------------------------------------------------------- server

proc newAsyncGrpcServer*(port = 0; address = "127.0.0.1";
                         maxMessage = defaultMaxMessage; tls: TlsConfig = nil;
                         keepalive = Keepalive(); pingPolicy = PingPolicy();
                         limits = Limits()): AsyncGrpcServer =
  ## `address` as for `newGrpcServer`: "::" listens on IPv6 and IPv4.
  ## Register methods, then `start`. With `tls` (see `tlsServerConfig`)
  ## clients must use TLS 1.2 with ALPN h2. `keepalive` pings idle clients;
  ## `pingPolicy` limits how often clients may ping. `limits` caps the streams
  ## of a connection, the connections and the bytes queued per connection
  ## (see `Limits`; 100 streams by default).
  AsyncGrpcServer(maxMessage: maxMessage, port: port, address: address, tls: tls,
                  ka: keepalive, policy: pingPolicy, limits: limits)

proc addUnary*(s: AsyncGrpcServer; path: string; handler: AsyncUnaryHandler) =
  ## `path` is "/package.Service/Method".
  doAssert s.h2 == nil, "methods must be registered before start"
  s.methods[path] = Method(kind: mkUnary, unary: handler)

proc addStreaming*(s: AsyncGrpcServer; path: string; handler: AsyncStreamingHandler) =
  doAssert s.h2 == nil, "methods must be registered before start"
  s.methods[path] = Method(kind: mkStreaming, streaming: handler)

proc setErrorHook*(s: AsyncGrpcServer; hook: ErrorHook) =
  ## `hook` sees every handler exception that is not a GrpcError (those are the
  ## handler's own answer); the client only gets UNKNOWN "internal error".
  ## Without a hook nothing is logged. Set it before `start`.
  doAssert s.h2 == nil, "the error hook must be set before start"
  s.errorHook = hook

type AsyncServerStats* = object
  ## What the quota of streaming calls holds and has refused, for monitoring (the chronos server has
  ## no queue of calls: the other figures of the blocking server do not exist here).
  refusedStreaming*: int  ## counter: streaming calls answered RESOURCE_EXHAUSTED (`maxStreamingCalls`)
  runningStreaming*: int  ## gauge: streaming handlers that are running

proc stats*(s: AsyncGrpcServer): AsyncServerStats =
  AsyncServerStats(refusedStreaming: s.refusedStreaming, runningStreaming: s.streamingActive)

proc addInterceptor*(s: AsyncGrpcServer; interceptor: AsyncServerInterceptor) =
  ## `interceptor` runs around every call to a registered method; a call to an unknown method
  ## does not reach it. The first one added is the outermost. When the call is over for the
  ## client, the interceptor is cancelled with the handler. Add interceptors before `start`.
  doAssert s.h2 == nil, "interceptors must be added before start"
  doAssert interceptor != nil, "the interceptor is nil"
  s.interceptors.add interceptor

proc start*(s: AsyncGrpcServer) =
  ## Starts listening; calls are served while the event loop runs.
  proc onStream(st: AsyncH2Stream; ud: pointer): Future[void] {.gcsafe, raises: [].} =
    s.handle(st)
  s.h2 = newAsyncStreamServer(onStream, nil, Port(s.port), s.address,
                              s.tls, s.ka, s.policy, s.limits)

proc serviceNames*(s: AsyncGrpcServer): seq[string] =
  ## The services that have a method registered, sorted.
  for path in s.methods.keys:
    if path.len > 1 and path[0] == '/':
      let slash = path.rfind('/')
      if slash > 1:
        let name = path[1 ..< slash]
        if name notin result: result.add name
  result.sort()

proc port*(s: AsyncGrpcServer): int =
  if s.h2 != nil: s.h2.port.int else: s.port

proc stop*(s: AsyncGrpcServer; graceMs = 0) {.async: (raises: []).} =
  ## Stops the server. With `graceMs` > 0 clients get GOAWAY and calls in
  ## progress may finish for up to that long; then the rest are cancelled.
  if s.h2 != nil: await s.h2.stop(graceMs)
