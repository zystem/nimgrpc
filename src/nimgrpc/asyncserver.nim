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
## GrpcError (any other status); any other error becomes UNKNOWN.
##
## When the call is over for the client (it cancelled, its deadline passed,
## the connection closed, the server stopped) the handler's future is
## cancelled: whatever it awaits fails with CancelledError, so long handlers
## need no polling. A handler that does long synchronous work between awaits
## can still check `ctx.isCancelled`.

import std/[tables, strutils, options, algorithm]
import pkg/chronos
import ./status, ./wire, ./h2/async, ./compress/gzip
export status, options, async.TlsConfig, async.tlsClientConfig, async.tlsServerConfig,
       async.TlsError, async.Keepalive, async.PingPolicy, async.Limits, async.CipherOrder,
       async.setCipherOrder, async.setSessionLifetime, async.defaultSessionLifetime

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
    h2: AsyncH2Server

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

proc handle(s: AsyncGrpcServer; st: AsyncH2Stream): Future[void] {.async: (raises: []).} =
  let ctx = AsyncServerContext(timeoutMs: -1)
  var meth, contentType, encoding = ""
  var acceptsGzip = false
  for (k, v) in st.headers:
    case k
    of ":path": ctx.path = v
    of ":method": meth = v
    of "content-type": contentType = v
    of "grpc-timeout": ctx.timeoutMs = parseTimeout(v)
    of "grpc-encoding": encoding = v
    of "grpc-accept-encoding":
      for e in v.split(','):
        if e.strip == "gzip": acceptsGzip = true
    else: discard
  try:
    if meth != "POST":
      st.sendHeaders(@[(":status", "405")], endStream = true)
      return
    if not contentType.startsWith(grpcContentType):
      st.sendHeaders(@[(":status", "415")], endStream = true)
      return
  except H2Error:
    return
  st.setTimeout(ctx.timeoutMs)
  ctx.stream = st
  ctx.metadata = fromWire(st.headers)
  let call = AsyncServerCall(st: st, ctx: ctx, maxMessage: s.maxMessage,
                             reqEncoding: encoding, clientAcceptsGzip: acceptsGzip)
  if encoding.len > 0 and encoding notin supportedEncodings:
    call.finishCall(scUnimplemented, "grpc-encoding " & encoding.escape &
                    " is not supported", @[])
    return
  if ctx.path notin s.methods:
    call.finishCall(scUnimplemented, "unknown method " & ctx.path, @[])
    return
  let m = s.methods.getOrDefault(ctx.path)
  try:
    await runMethod(m, ctx, call)
    call.finishCall(scOk, "", ctx.trailers)
  except CancelledError:
    discard     # the call is over for the client; the stream is already closed
  except GrpcError as e:
    call.finishCall(e.code, e.msg, ctx.trailers & e.trailers)
  except CatchableError as e:
    call.finishCall(scUnknown, e.msg, ctx.trailers)

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
