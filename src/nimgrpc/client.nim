## Blocking gRPC client.
##
## `unaryCall` covers the common case. `newCall` opens a stream for client-,
## server- and bidirectional streaming: `send` messages, `closeSend`, then
## `recv` until it returns false. A non-OK status is raised as GrpcError from
## whichever call observes the end of the stream.
##
## A `GrpcChannel` is a small handle that may be copied and used from many
## threads; each call is its own HTTP/2 stream on the channel's connection.
## When that connection closes or the server sends GOAWAY, the next call
## dials a new one; calls still running on the old connection finish there.
## A `ClientCall` belongs to one thread and must not outlive its channel.
## `close` of a channel from another thread while a call waits on it is safe:
## the call fails with an error and `close` returns once it has left this
## module (`shutdown` closes the connections without freeing anything, for a
## caller that wants to join its threads first).

import std/[strutils, locks, atomics, os, monotimes, times]
import ./status, ./wire, ./h2/blocking, ./h2/common, ./compress/gzip, ./cleanup
export status, blocking.TlsConfig, blocking.tlsClientConfig, blocking.tlsServerConfig,
       blocking.TlsError, blocking.Keepalive, blocking.CipherOrder,
       blocking.setCipherOrder, blocking.setSessionLifetime, blocking.defaultSessionLifetime, blocking.share

const userAgent = "grpc-nim/0.0.1"

type
  ChannelObj* = object
    lock: Lock
    host*: string
    port*: int
    tls*: TlsConfig
    serverName*: string
    keepalive: Keepalive
    connectTimeoutMs: int
    authority: string
    scheme: string
    conn: Conn              ## the connection new calls use
    retired: seq[Conn]      ## replaced connections, closed once idle
    closed: bool
    interceptors: seq[Intercept]   ## under `lock`; the first added is the outermost
    inflight: Atomic[int]   ## calls inside a procedure of this module on some thread; `close` waits for them

  GrpcChannel* = object
    p*: ptr ChannelObj      ## shared; freed by `close`

  ClientCall* = object
    ch: ptr ChannelObj      ## the channel the call was made on
    st: ClientStream
    msgs: MsgBuf                  ## received bytes not yet decoded
    gotHeaders: bool
    rawHeaders: seq[Header]
    ended: bool             ## the status has been read
    cancelled: bool
    maxMessage: int
    gzipOut: bool           ## the call was opened with compression = "gzip"
    respEncoding: string    ## the server's grpc-encoding
    lastCompressed*: bool   ## whether the last message `recv` returned was compressed
    headers*: Metadata      ## initial metadata, once the first `recv` returned
    trailers*: Metadata     ## trailing metadata, once the call has ended

  UnaryResult* = object
    message*: seq[byte]
    headers*: Metadata
    trailers*: Metadata

  ClientCallInfo* = object
    ## What a `ClientInterceptor` sees of a call.
    path*: string
    metadata*: Metadata      ## sent with the call; may be changed before `proceed`
    timeoutMs*: int          ## the deadline of the call, -1 for none; may be changed before `proceed`
    streaming*: bool
      ## false: the call is a `unaryCall`, and `proceed` returns when it has ended.
      ## true: the call is a `newCall`, and `proceed` returns when the stream is open.
    headers*: Metadata       ## of a unary call that ended with OK, after `proceed`
    trailers*: Metadata      ## the same

  ClientNext* = object
    ## The rest of a call, given to a `ClientInterceptor`: the interceptors added after it and
    ## then the call itself. `proceed` runs it. Valid only while the interceptor runs.
    chain: ptr ClientChain
    level: int

  ClientInterceptor* = proc (info: var ClientCallInfo; next: ClientNext; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].}
    ## Runs around every call made on the channel, on the thread that makes it. It may change
    ## `info.metadata` and `info.timeoutMs`, and either calls `next.proceed(info)` once or
    ## raises GrpcError, which the caller gets without anything being sent. `proceed` raises
    ## what the call raised. `userData` is the pointer given to `addInterceptor`.

  Intercept = object
    fn: ClientInterceptor
    userData: pointer

  ClientChain = object
    ## One call on its way through the interceptors; lives on the stack of the caller.
    list: seq[Intercept]
    run: proc (chain: ptr ClientChain; info: var ClientCallInfo)
           {.nimcall, gcsafe, raises: [CatchableError].}
    ch: ptr ChannelObj
    reached: int
    failure: ref CatchableError
    # the arguments of the call and its result
    request: ptr UncheckedArray[byte]
    requestLen: int
    maxMessage: int
    compression: string
    unary: UnaryResult
    call: ptr ClientCall
    opened: bool                 ## `call[]` holds an open stream

template inFlight(chan: ptr ChannelObj) =
  ## The first statement of a procedure that uses a call or the channel: `close` of the channel
  ## waits until the procedure has returned, so the connection it uses is not freed under it.
  ## The `defer` is one atomic operation with no `try/except` in it, so an exception on its way out is not lost
  ## (docs/nim-compiler-notes.md, 1); tests/tchannelclose.nim sees a call that returned instead of raising.
  let tracked = chan
  if tracked != nil: discard tracked.inflight.fetchAdd(1)
  defer:
    if tracked != nil: discard tracked.inflight.fetchSub(1)

proc connect(c: ptr ChannelObj): Conn =
  var why = ""
  try:
    result = blocking.dial(c.host, Port(c.port), c.tls, c.serverName, c.keepalive,
                           c.connectTimeoutMs)
  except CatchableError as e:
    why = e.msg
  if why.len > 0: raise newGrpcError(scUnavailable, why)

proc dial*(host: string; port: int; tls: TlsConfig = nil; serverName = "";
           keepalive = Keepalive();
           connectTimeoutMs = blocking.defaultConnectTimeoutMs): GrpcChannel =
  ## `host` is a name or an address, IPv4 or IPv6 ("::1" or "[::1]"); a name is tried at
  ## every address it resolves to, IPv6 ones included, in the resolver's order.
  ## Without `tls`: plaintext HTTP/2 (h2c) with prior knowledge. With it:
  ## TLS 1.2 with ALPN h2; the server certificate must match `serverName`
  ## (default `host`): a DNS name is checked against the certificate's dNSName entries (and CN),
  ## an IP address ("10.0.0.5", "::1", "[::1]") against its iPAddress entries; no SNI is sent
  ## for an IP address. Connects right away and raises
  ## GrpcError(UNAVAILABLE) if the server cannot be reached; a failed
  ## handshake is reported by the first call. Later connections are made on
  ## demand. Each attempt to connect gets `connectTimeoutMs` (20 s by default;
  ## negative: no limit beyond the system's) and fails with UNAVAILABLE past it.
  let c = createShared(ChannelObj)
  initLock(c.lock)
  c.host = host
  c.port = port
  c.tls = tls
  c.serverName = serverName
  c.keepalive = keepalive
  c.connectTimeoutMs = connectTimeoutMs
  c.authority = hostPort(if serverName.len > 0: serverName else: host, port)
  c.scheme = if tls != nil: "https" else: "http"
  var why: ref GrpcError
  try:
    c.conn = c.connect()
  except GrpcError as e:
    why = e
  if why != nil:
    `=destroy`(c[])
    deinitLock(c.lock)
    deallocShared(c)
    raise why
  GrpcChannel(p: c)

proc shutdown*(ch: GrpcChannel) =
  ## Closes every connection of the channel and frees nothing: calls in progress, on any thread,
  ## fail at once with an error, and new calls are refused. Safe to call from any thread, more than
  ## once; `close` frees the channel afterwards. A thread that waits in a call can be told to
  ## stop with it, joined, and only then is the channel closed.
  let c = ch.p
  acquire(c.lock)
  c.closed = true
  if c.conn != nil: c.conn.close()
  for r in c.retired: r.close()
  release(c.lock)

const closeWaitMs = 10_000

proc close*(ch: GrpcChannel) =
  ## Closes every connection of the channel and frees it. Calls still in progress fail; the
  ## channel and its copies must not be used afterwards. A call that is inside a procedure of this
  ## module on another thread (it waits in `recv`, say) is let leave it first, for up to ten
  ## seconds; if one does not, the channel is not freed (it leaks, which a use after free would
  ## not) and `close` returns. A call that has not entered the module yet cannot be waited for:
  ## do not start calls on a channel that is being closed.
  ch.shutdown()
  let c = ch.p
  var waited = 0
  while c.inflight.load > 0 and waited < closeWaitMs:
    sleep 1
    inc waited
  if c.inflight.load > 0: return
  `=destroy`(c[])
  deinitLock(c.lock)
  deallocShared(c)

proc connectionLocked(c: ptr ChannelObj): Conn =
  ## The connection for a new call, redialling if the current one is closed
  ## or going away. Replaced connections are closed once no call uses them.
  if c.closed: raise newGrpcError(scUnavailable, "channel closed")
  var keep: seq[Conn]
  for r in c.retired:
    if r.activeStreams == 0: r.close()
    else: keep.add r
  c.retired = keep
  if c.conn == nil or not c.conn.isUsable:
    if c.conn != nil: c.retired.add c.conn
    c.conn = nil
    c.conn = c.connect()
  c.conn

proc rstToStatus(code: uint32): StatusCode =
  case code
  of 7: scUnavailable          # REFUSED_STREAM: safe to retry
  of 8: scCancelled            # CANCEL
  of 11: scResourceExhausted   # ENHANCE_YOUR_CALM
  of 12: scPermissionDenied    # INADEQUATE_SECURITY
  else: scInternal

proc addInterceptor*(ch: GrpcChannel; interceptor: ClientInterceptor; userData: pointer = nil) =
  ## `interceptor` runs around every `unaryCall` and `newCall` on the channel from now on,
  ## those of generated clients and of the health client included. The first one added is the
  ## outermost. It runs on the thread that makes the call, so with a channel used from several
  ## threads it and what `userData` points to must be thread-safe; `userData` must stay valid
  ## until the channel is closed.
  doAssert interceptor != nil, "the interceptor is nil"
  let c = ch.p
  acquire(c.lock)
  c.interceptors.add Intercept(fn: interceptor, userData: userData)
  release(c.lock)

proc interceptorsOf(c: ptr ChannelObj): seq[Intercept] =
  acquire(c.lock)
  result = c.interceptors
  release(c.lock)

proc proceed*(next: ClientNext; info: var ClientCallInfo) {.gcsafe, raises: [CatchableError].} =
  ## Runs the rest of the call: the next interceptor, or the call itself after the last one.
  ## For a unary call it returns when the call has ended with OK; for a streaming call, when the
  ## stream is open. It raises what the call raised. To be called once: a second call raises
  ## GrpcError(INTERNAL) and sends nothing.
  let c = next.chain
  if c.reached != next.level:
    raise newGrpcError(scInternal, "an interceptor called proceed twice")
  inc c.reached
  var failure: ref CatchableError
  try:
    if next.level < c.list.len:
      let i = c.list[next.level]
      i.fn(info, ClientNext(chain: c, level: next.level + 1), i.userData)
    else:
      c.run(c, info)
  except CatchableError as e:
    failure = e
  if failure != nil:       # raised outside the except block (see `mapErrors`)
    c.failure = failure
    raise failure

proc runChain(chain: var ClientChain; info: var ClientCallInfo) =
  ## Runs the interceptors and then `chain.run`. An interceptor that swallowed the error of the
  ## call does not make it succeed.
  ClientNext(chain: chain.addr, level: 0).proceed(info)
  if chain.failure != nil: raise chain.failure
  if chain.reached <= chain.list.len:
    raise newGrpcError(scInternal, "an interceptor returned without calling proceed")

proc openCall(c: ptr ChannelObj; path: string; metadata: Metadata;
              timeoutMs: int; maxMessage: int; compression: string): ClientCall
    {.gcsafe, raises: [CatchableError].} =
  ## `newCall` without the interceptors.
  if compression notin ["", "identity", "gzip"]:
    raise newGrpcError(scInvalidArgument, "unsupported compression " & compression.escape)
  inFlight(c)
  var headers = @[(":method", "POST"), (":scheme", c.scheme), (":path", path),
                  (":authority", c.authority), ("content-type", grpcContentType),
                  ("te", "trailers"), ("user-agent", userAgent), acceptEncodingHeader]
  if compression == "gzip": headers.add ("grpc-encoding", "gzip")
  if timeoutMs >= 0: headers.add ("grpc-timeout", encodeTimeout(timeoutMs))
  headers.add metadata.toWire
  result.ch = c
  result.maxMessage = maxMessage
  result.gzipOut = compression == "gzip"
  var why = ""
  acquire(c.lock)
  try:
    # A connection can turn out to be going away between the check and the
    # stream: then try once more on a fresh one.
    for attempt in 0 .. 1:
      let conn = c.connectionLocked()
      try:
        result.st = conn.openStream(headers, timeoutMs)
        why = ""
        break
      except H2Error as e:
        why = e.msg
  except GrpcError as e:
    why = e.msg
  finally:
    release(c.lock)
  if why.len > 0: raise newGrpcError(scUnavailable, why)

proc runOpen(chain: ptr ClientChain; info: var ClientCallInfo)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var opened = openCall(chain.ch, info.path, info.metadata, info.timeoutMs,
                        chain.maxMessage, chain.compression)
  chain.call[] = move opened
  chain.opened = true

proc newCall*(ch: GrpcChannel; path: string; metadata: Metadata = @[];
              timeoutMs = -1; maxMessage = defaultMaxMessage;
              compression = ""): ClientCall =
  ## Opens a call to `path` ("/package.Service/Method"). `timeoutMs` bounds
  ## the whole call. With `compression = "gzip"` messages are sent
  ## compressed (see `send`); compressed replies are always accepted, and
  ## `maxMessage` limits them after decompression. The channel's interceptors
  ## (`addInterceptor`) run first and may change the metadata and the deadline.
  let c = ch.p
  inFlight(c)
  let list = c.interceptorsOf()
  if list.len == 0:
    return openCall(c, path, metadata, timeoutMs, maxMessage, compression)
  var info = ClientCallInfo(path: path, metadata: metadata, timeoutMs: timeoutMs, streaming: true)
  var chain = ClientChain(list: list, run: runOpen, ch: c, maxMessage: maxMessage,
                          compression: compression, call: result.addr)
  var failure: ref CatchableError
  try:
    runChain(chain, info)
  except CatchableError as e:
    failure = e
  if failure != nil:
    # An interceptor failed after the stream was opened: the caller gets no call to close.
    if chain.opened: result.st.release()
    raise failure

proc close*(call: var ClientCall) =
  ## Releases the stream; an unfinished call is cancelled.
  inFlight(call.ch)
  call.st.release()

proc cancel*(call: var ClientCall) =
  ## Resets the call; later `send` and `recv` raise CANCELLED.
  inFlight(call.ch)
  if not call.ended:
    call.st.cancel()
    call.cancelled = true
  call.ended = true
  call.st.release()

proc fail(call: var ClientCall; code: StatusCode; msg: string;
          trailers: Metadata = @[]) {.noreturn.} =
  call.ended = true
  call.st.release()
  raise newGrpcError(code, msg, trailers)

proc readHeaders(call: var ClientCall) =
  if call.gotHeaders: return
  let hs = call.st.recvHeaders()
  call.gotHeaders = true
  call.rawHeaders = hs
  var httpStatus, contentType = ""
  for (k, v) in hs:
    if k == ":status": httpStatus = v
    elif k == "content-type": contentType = v
    elif k == "grpc-encoding": call.respEncoding = v
  call.headers = fromWire(hs)
  if httpStatus != "200":
    call.fail(httpToStatus(httpStatus), "HTTP status " & httpStatus)
  if not contentType.isGrpcContentType:
    call.fail(scUnknown, "unexpected content-type " & contentType.escape)

proc finish(call: var ClientCall) =
  ## Reads the status. Raises GrpcError unless it is OK.
  let tr = call.st.recvTrailers()
  # A trailers-only response carries the status in its only HEADERS block.
  let statusBlock = if tr.len > 0: tr else: call.rawHeaders
  var grpcStatus, grpcMessage = ""
  var have = false
  for (k, v) in statusBlock:
    if k == "grpc-status":
      grpcStatus = v
      have = true
    elif k == "grpc-message":
      grpcMessage = decodeStatusMessage(v)
  call.trailers = fromWire(statusBlock)
  call.ended = true
  call.st.release()
  if not have:
    raise newGrpcError(scInternal, "response without grpc-status", call.trailers)
  var code = scUnknown
  try: code = toStatusCode(parseInt(grpcStatus))
  except ValueError: discard
  if code != scOk:
    raise newGrpcError(code, grpcMessage, call.trailers)

proc raiseMapped(call: var ClientCall; e: ref H2Error) {.noreturn.} =
  if e of H2Timeout:
    call.fail(scDeadlineExceeded, "deadline exceeded")
  if e of H2StreamClosed:
    if call.st.peerEnded:
      # The server finished first (say, with an error status before reading
      # our messages); its status is the answer.
      call.readHeaders()
      call.finish()
      call.fail(scInternal, "server ended the call early with OK")
    let code = call.st.errorCode
    if code == 8 and call.st.deadlinePassed:
      # The server's copy of our deadline fired first and it reset the stream.
      call.fail(scDeadlineExceeded, "deadline exceeded")
    if code == 7:
      call.ended = true
      call.st.release()
      let refused = newGrpcError(scUnavailable, "stream reset with HTTP/2 error 7 (REFUSED_STREAM)")
      refused.unprocessed = true
      raise refused
    if code != 0: call.fail(rstToStatus(code), "stream reset with HTTP/2 error " & $code)
    call.fail(scUnavailable, e.msg)
  call.fail(scInternal, e.msg)

template mapErrors(call: var ClientCall; body: untyped) =
  ## Turns transport errors into GrpcError. The new error is raised after the
  ## `except` block: raising inside one leaves the thread's current-exception
  ## slot pointing at the old error for good.
  var h2err: ref H2Error
  try:
    body
  except H2Error as e:
    h2err = e
  if h2err != nil: call.raiseMapped(h2err)

proc send*(call: var ClientCall; msg: openArray[byte]; compressed: bool) =
  ## Sends one message, compressed or not. Compressing needs a call opened
  ## with `compression = "gzip"`. If the server has already ended the call,
  ## raises its status (GrpcError).
  inFlight(call.ch)
  if call.cancelled: raise newGrpcError(scCancelled, "call cancelled")
  if call.ended: raise newGrpcError(scInternal, "send after the call ended")
  if compressed and not call.gzipOut:
    raise newGrpcError(scInternal, "a compressed message needs compression = \"gzip\" on the call")
  if compressed:
    let z = gzipCompress(msg)
    call.mapErrors:
      call.st.send(z, head = frameHeader(z.len, true))
  else:
    call.mapErrors:
      call.st.send(msg, head = frameHeader(msg.len))

proc send*(call: var ClientCall; msg: openArray[byte]) =
  ## Sends one message, compressed if the call was opened with compression.
  call.send(msg, call.gzipOut)

proc closeSend*(call: var ClientCall) =
  ## No more messages from the client.
  inFlight(call.ch)
  if call.ended: return
  call.mapErrors:
    call.st.closeSend()

proc recv*(call: var ClientCall; msg: var seq[byte]): bool =
  ## The next message from the server; false once the server has ended the
  ## call with OK. Any other status is raised as GrpcError.
  inFlight(call.ch)
  if call.cancelled: raise newGrpcError(scCancelled, "call cancelled")
  if call.ended: return false
  call.mapErrors:
    call.readHeaders()
    while true:
      var payload: seq[byte]
      var compressed = false
      var bad: ref GrpcError
      try:
        if call.msgs.take(call.maxMessage, payload, compressed):
          if compressed:
            if call.respEncoding != "gzip":
              raise newGrpcError(scInternal, "compressed message with grpc-encoding " &
                                 call.respEncoding.escape)
            msg = gzipDecompress(payload, call.maxMessage)
          else:
            msg = move payload
          call.lastCompressed = compressed
          return true
      except GrpcError as e:
        bad = e
      if bad != nil:
        call.cancel()
        raise bad
      var chunk: seq[byte]
      if call.st.recvData(chunk):
        call.msgs.feed(chunk)
      else:
        if call.msgs.leftover > 0:
          call.fail(scInternal, "truncated message at end of stream")
        break
    call.finish()
    return false

proc unaryOnce(c: ptr ChannelObj; path: string; request: openArray[byte]; metadata: Metadata;
               timeoutMs: int; maxMessage: int; compression: string): UnaryResult
    {.gcsafe, raises: [CatchableError].} =
  inFlight(c)
  var call = openCall(c, path, metadata, timeoutMs, maxMessage, compression)
  var res: UnaryResult
  withCleanup:
    call.send(request)
    call.closeSend()
    if not call.recv(res.message):
      raise newGrpcError(scInternal, "unary call ended without a response")
    var extra: seq[byte]
    if call.recv(extra):
      raise newGrpcError(scInternal, "unary call got more than one response")
    res.headers = call.headers
    res.trailers = call.trailers
  do:
    call.close()
  res

const
  refusedRetries* = 2        ## how many more times `unaryCall` sends a call the server refused
  refusedBackoffMs = 20      ## the wait before the first of them, doubled for each next

proc unaryRetrying(c: ptr ChannelObj; path: string; request: openArray[byte];
                   metadata: Metadata; timeoutMs: int; maxMessage: int;
                   compression: string): UnaryResult {.gcsafe, raises: [CatchableError].} =
  let t0 = getMonoTime()
  var attempt = 0
  while true:
    var left = timeoutMs
    if timeoutMs >= 0:
      left = max(0, timeoutMs - int((getMonoTime() - t0).inMilliseconds))
    var failure: ref GrpcError
    try:
      return unaryOnce(c, path, request, metadata, left, maxMessage, compression)
    except GrpcError as e:
      failure = e
    if not failure.unprocessed or attempt >= refusedRetries or
       (timeoutMs >= 0 and left <= refusedBackoffMs shl attempt):
      raise failure
    sleep(refusedBackoffMs shl attempt)
    inc attempt

proc runUnary(chain: ptr ClientChain; info: var ClientCallInfo)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  chain.unary = unaryRetrying(chain.ch, info.path,
                              toOpenArray(chain.request, 0, chain.requestLen - 1),
                              info.metadata, info.timeoutMs, chain.maxMessage, chain.compression)
  info.headers = chain.unary.headers
  info.trailers = chain.unary.trailers

proc unaryCall*(ch: GrpcChannel; path: string; request: openArray[byte];
                metadata: Metadata = @[]; timeoutMs = -1;
                maxMessage = defaultMaxMessage; compression = ""): UnaryResult =
  ## Sends one message and returns the one reply. Raises GrpcError for any
  ## status other than OK. A call the server refused without starting on it (REFUSED_STREAM, or
  ## a GOAWAY that came before it, as when a server drains or has not yet told its limits) is
  ## sent again, on a new connection if the old one is going away, up to `refusedRetries` times,
  ## within `timeoutMs`; the error then has `unprocessed` set. Calls that may have run are never
  ## repeated. The channel's interceptors (`addInterceptor`) run once around all of it.
  let c = ch.p
  inFlight(c)
  let list = c.interceptorsOf()
  if list.len == 0:
    return unaryRetrying(c, path, request, metadata, timeoutMs, maxMessage, compression)
  var info = ClientCallInfo(path: path, metadata: metadata, timeoutMs: timeoutMs)
  var chain = ClientChain(list: list, run: runUnary, ch: c, maxMessage: maxMessage,
                          compression: compression, requestLen: request.len)
  if request.len > 0:
    chain.request = cast[ptr UncheckedArray[byte]](request[0].unsafeAddr)
  runChain(chain, info)
  move chain.unary
