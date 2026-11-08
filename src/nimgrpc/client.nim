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

import std/[strutils, locks, atomics, os]
import ./status, ./wire, ./h2/blocking, ./h2/common, ./compress/gzip, ./cleanup
export status, blocking.TlsConfig, blocking.tlsClientConfig, blocking.tlsServerConfig,
       blocking.TlsError, blocking.Keepalive, blocking.CipherOrder,
       blocking.setCipherOrder, blocking.setSessionLifetime, blocking.defaultSessionLifetime

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
  ## (default `host`; DNS names only, so use a name such as "localhost"
  ## rather than an IP address). Connects right away and raises
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

proc newCall*(ch: GrpcChannel; path: string; metadata: Metadata = @[];
              timeoutMs = -1; maxMessage = defaultMaxMessage;
              compression = ""): ClientCall =
  ## Opens a call to `path` ("/package.Service/Method"). `timeoutMs` bounds
  ## the whole call. With `compression = "gzip"` messages are sent
  ## compressed (see `send`); compressed replies are always accepted, and
  ## `maxMessage` limits them after decompression.
  if compression notin ["", "identity", "gzip"]:
    raise newGrpcError(scInvalidArgument, "unsupported compression " & compression.escape)
  let c = ch.p
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
  if not contentType.startsWith(grpcContentType):
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

proc unaryCall*(ch: GrpcChannel; path: string; request: openArray[byte];
                metadata: Metadata = @[]; timeoutMs = -1;
                maxMessage = defaultMaxMessage; compression = ""): UnaryResult =
  ## Sends one message and returns the one reply. Raises GrpcError for any
  ## status other than OK.
  inFlight(ch.p)
  var call = ch.newCall(path, metadata, timeoutMs, maxMessage, compression)
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
