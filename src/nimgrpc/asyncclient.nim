## gRPC client on chronos.
##
## The async twin of `nimgrpc/client`: `unaryCall` for the common case,
## `newCall` for streaming (`send`, `closeSend`, then `recv` until it returns
## `none`). A non-OK status is raised as GrpcError from whichever call sees
## the end of the stream.
##
## A channel and its calls belong to the thread running the event loop.
## Each call is one HTTP/2 stream on the channel's connection; when that
## connection closes or the server sends GOAWAY, the next call dials a new
## one, and calls still running on the old one finish there.

import std/[strutils, options]
import pkg/chronos
import ./status, ./wire, ./h2/async, ./h2/common, ./compress/gzip
export status, options, async.TlsConfig, async.tlsClientConfig, async.TlsError,
       async.Keepalive, async.CipherOrder, async.setCipherOrder, async.setSessionLifetime, async.defaultSessionLifetime

const userAgent = "grpc-nim/0.0.1"

type
  AsyncChannel* = ref object
    host*: string
    port*: int
    tls*: TlsConfig
    serverName*: string
    keepalive: Keepalive
    connectTimeoutMs: int
    authority: string
    scheme: string
    conn: AsyncH2Conn             ## the connection new calls use
    retired: seq[AsyncH2Conn]     ## replaced connections, closed once idle
    connecting: Future[AsyncH2Conn].Raising([CancelledError, GrpcError])
    closed: bool

  AsyncCall* = ref object
    st: AsyncH2Stream
    msgs: MsgBuf                  ## received bytes not yet decoded
    gotHeaders: bool
    rawHeaders: seq[Header]
    ended: bool                   ## the status has been read
    cancelled: bool
    maxMessage: int
    gzipOut: bool                 ## the call was opened with compression = "gzip"
    respEncoding: string          ## the server's grpc-encoding
    lastCompressed*: bool         ## whether the last message `recv` returned was compressed
    headers*: Metadata            ## initial metadata, once the first `recv` returned
    trailers*: Metadata           ## trailing metadata, once the call has ended

  UnaryResult* = object
    message*: seq[byte]
    headers*: Metadata
    trailers*: Metadata

proc connect(ch: AsyncChannel): Future[AsyncH2Conn] {.
    async: (raises: [CancelledError, GrpcError]).} =
  var why = ""
  try:
    return await async.dial(ch.host, Port(ch.port), ch.tls, ch.serverName, ch.keepalive,
                             ch.connectTimeoutMs)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    why = e.msg
  raise newGrpcError(scUnavailable, why)

proc dialAsync*(host: string; port: int; tls: TlsConfig = nil; serverName = "";
                keepalive = Keepalive();
                connectTimeoutMs = async.defaultConnectTimeoutMs): Future[AsyncChannel] {.async.} =
  ## Without `tls`: plaintext HTTP/2 (h2c). With it: TLS 1.2 with ALPN h2,
  ## the server certificate checked against `serverName` (default `host`).
  ## Connects right away and raises GrpcError(UNAVAILABLE) if the server
  ## cannot be reached; later connections are made on demand. Each attempt
  ## to connect gets `connectTimeoutMs` (20 s by default; negative: no limit
  ## beyond the system's) and fails with UNAVAILABLE past it.
  let ch = AsyncChannel(host: host, port: port, tls: tls, serverName: serverName,
                        keepalive: keepalive, connectTimeoutMs: connectTimeoutMs,
                        authority: hostPort(if serverName.len > 0: serverName else: host, port),
                        scheme: if tls != nil: "https" else: "http")
  ch.conn = await ch.connect()
  ch

proc close*(ch: AsyncChannel) {.async: (raises: []).} =
  ## Closes every connection of the channel; calls in progress fail.
  ch.closed = true
  if ch.conn != nil: await ch.conn.close()
  for r in ch.retired: await r.close()
  ch.conn = nil
  ch.retired = @[]

proc connection(ch: AsyncChannel): Future[AsyncH2Conn] {.
    async: (raises: [CancelledError, GrpcError]).} =
  ## The connection for a new call, redialling if the current one is closed
  ## or going away. One dial at a time; concurrent callers share it.
  if ch.closed: raise newGrpcError(scUnavailable, "channel closed")
  var keep: seq[AsyncH2Conn]
  for r in ch.retired:
    if r.activeStreams == 0: asyncSpawn r.close()
    else: keep.add r
  ch.retired = keep
  if ch.conn != nil and ch.conn.isUsable: return ch.conn
  if ch.connecting == nil:
    if ch.conn != nil: ch.retired.add ch.conn
    ch.conn = nil
    ch.connecting = ch.connect()
    try:
      ch.conn = await ch.connecting
    finally:
      ch.connecting = nil
    return ch.conn
  let pending = ch.connecting
  return await pending

proc rstToStatus(code: uint32): StatusCode =
  case code
  of 7: scUnavailable          # REFUSED_STREAM: safe to retry
  of 8: scCancelled            # CANCEL
  of 11: scResourceExhausted   # ENHANCE_YOUR_CALM
  of 12: scPermissionDenied    # INADEQUATE_SECURITY
  else: scInternal

proc newCall*(ch: AsyncChannel; path: string; metadata: Metadata = @[];
              timeoutMs = -1; maxMessage = defaultMaxMessage;
              compression = ""): Future[AsyncCall] {.async.} =
  ## Opens a call to `path` ("/package.Service/Method"). `timeoutMs` bounds
  ## the whole call. With `compression = "gzip"` messages are sent
  ## compressed; compressed replies are always accepted, and `maxMessage`
  ## limits them after decompression.
  if compression notin ["", "identity", "gzip"]:
    raise newGrpcError(scInvalidArgument, "unsupported compression " & compression.escape)
  var headers = @[(":method", "POST"), (":scheme", ch.scheme), (":path", path),
                  (":authority", ch.authority), ("content-type", grpcContentType),
                  ("te", "trailers"), ("user-agent", userAgent), acceptEncodingHeader]
  if compression == "gzip": headers.add ("grpc-encoding", "gzip")
  if timeoutMs >= 0: headers.add ("grpc-timeout", encodeTimeout(timeoutMs))
  headers.add metadata.toWire
  let call = AsyncCall(maxMessage: maxMessage, gzipOut: compression == "gzip")
  var why = ""
  # A connection can turn out to be going away between the check and the
  # stream: then try once more on a fresh one.
  for attempt in 0 .. 1:
    let conn = await ch.connection()
    try:
      call.st = conn.openStream(headers, timeoutMs)
      return call
    except H2Error as e:
      why = e.msg
  raise newGrpcError(scUnavailable, why)

proc close*(call: AsyncCall) =
  ## Releases the stream; an unfinished call is cancelled.
  if call.st != nil: call.st.release()

proc cancel*(call: AsyncCall) =
  ## Resets the call; later `send` and `recv` raise CANCELLED.
  if not call.ended:
    call.st.cancel()
    call.cancelled = true
  call.ended = true
  call.st.release()

proc failure(call: AsyncCall; code: StatusCode; msg: string;
             trailers: Metadata = @[]): ref GrpcError =
  call.ended = true
  call.st.release()
  newGrpcError(code, msg, trailers)

proc headersError(call: AsyncCall; hs: seq[Header]): ref GrpcError =
  ## Records the response HEADERS; an error if they do not start a gRPC response.
  call.gotHeaders = true
  call.rawHeaders = hs
  var httpStatus, contentType = ""
  for (k, v) in hs:
    if k == ":status": httpStatus = v
    elif k == "content-type": contentType = v
    elif k == "grpc-encoding": call.respEncoding = v
  call.headers = fromWire(hs)
  if httpStatus != "200":
    return call.failure(httpToStatus(httpStatus), "HTTP status " & httpStatus)
  if not contentType.startsWith(grpcContentType):
    return call.failure(scUnknown, "unexpected content-type " & contentType.escape)

proc statusError(call: AsyncCall; tr: seq[Header]): ref GrpcError =
  ## The status from the trailers; nil for OK.
  let statusBlock = if tr.len > 0: tr else: call.rawHeaders   # trailers-only
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
    return newGrpcError(scInternal, "response without grpc-status", call.trailers)
  var code = scUnknown
  try: code = toStatusCode(parseInt(grpcStatus))
  except ValueError: discard
  if code != scOk:
    return newGrpcError(code, grpcMessage, call.trailers)

proc readHeaders(call: AsyncCall) {.async.} =
  if call.gotHeaders: return
  let err = call.headersError(await call.st.recvHeaders())
  if err != nil: raise err

proc finish(call: AsyncCall) {.async.} =
  ## Reads the status. Raises GrpcError unless it is OK.
  let err = call.statusError(await call.st.recvTrailers())
  if err != nil: raise err

proc mapped(call: AsyncCall; e: ref H2Error): ref GrpcError =
  ## The GrpcError for a transport error (the server's status if it ended first).
  if e of H2Timeout:
    return call.failure(scDeadlineExceeded, "deadline exceeded")
  if e of H2StreamClosed:
    let code = call.st.errorCode
    if code == 8 and call.st.deadlinePassed:
      return call.failure(scDeadlineExceeded, "deadline exceeded")
    if code != 0: return call.failure(rstToStatus(code), "stream reset with HTTP/2 error " & $code)
    return call.failure(scUnavailable, e.msg)
  call.failure(scInternal, e.msg)

proc serverStatus(call: AsyncCall): ref GrpcError =
  ## The server ended its side first (say, with an error status before
  ## reading our messages): its status is the answer, if it has one.
  if not call.st.peerEnded: return nil
  if not call.gotHeaders:
    let blocks = call.st.recvHeaders()     # already received: completes at once
    if not blocks.finished: return nil
    try:
      let err = call.headersError(blocks.read)
      if err != nil: return err
    except CatchableError: return nil
  let tr = call.st.recvTrailers()
  if not tr.finished: return nil
  try:
    result = call.statusError(tr.read)
  except CatchableError: return nil
  if result == nil: result = newGrpcError(scInternal, "server ended the call early with OK")

proc finishSend(call: AsyncCall; job: SendJob) {.async.} =
  var err: ref GrpcError
  try:
    await call.st.finish(job)
  except H2Error as e:
    err = call.serverStatus()
    if err == nil: err = call.mapped(e)
  if err != nil: raise err

proc failedSend(e: ref CatchableError): Future[void] =
  result = newFuture[void]("grpc.send")
  result.fail(e)

proc send*(call: AsyncCall; msg: sink seq[byte]; compressed: bool): Future[void] =
  ## Sends one message, compressed or not. Compressing needs a call opened
  ## with `compression = "gzip"`. If the server has already ended the call,
  ## raises its status (GrpcError). The message is handed to the connection
  ## without a copy.
  try:
    if call.cancelled: raise newGrpcError(scCancelled, "call cancelled")
    if call.ended: raise newGrpcError(scInternal, "send after the call ended")
    if compressed and not call.gzipOut:
      raise newGrpcError(scInternal, "a compressed message needs compression = \"gzip\" on the call")
    var body = if compressed: gzipCompress(msg) else: move msg
    let head = frameHeader(body.len, compressed)
    let job = try: call.st.push(body, head)
              except H2Error as e:
                var err = call.serverStatus()
                if err == nil: err = call.mapped(e)
                raise err
    if job == nil: completed() else: call.finishSend(job)
  except GrpcError as e:
    failedSend(e)

proc send*(call: AsyncCall; msg: sink seq[byte]): Future[void] =
  ## Sends one message, compressed if the call was opened with compression.
  call.send(msg, call.gzipOut)

proc closeSend*(call: AsyncCall) {.async.} =
  ## No more messages from the client.
  if call.ended: return
  var err: ref GrpcError
  try:
    await call.st.closeSend()
  except H2Error as e:
    err = call.serverStatus()
    if err == nil: err = call.mapped(e)
  if err != nil: raise err

proc recv*(call: AsyncCall): Future[Option[seq[byte]]] {.async.} =
  ## The next message from the server; `none` once the server has ended the
  ## call with OK. Any other status is raised as GrpcError.
  if call.cancelled: raise newGrpcError(scCancelled, "call cancelled")
  if call.ended: return none(seq[byte])
  var err: ref GrpcError
  try:
    await call.readHeaders()
    while true:
      var payload: seq[byte]
      var compressed = false
      if call.msgs.take(call.maxMessage, payload, compressed):
        var msg: seq[byte]
        if compressed:
          if call.respEncoding != "gzip":
            raise newGrpcError(scInternal, "compressed message with grpc-encoding " &
                               call.respEncoding.escape)
          msg = gzipDecompress(payload, call.maxMessage)
        else:
          msg = move payload
        call.lastCompressed = compressed
        result = some(move msg)
        return
      var chunk = await call.st.recvData()
      if chunk.len > 0:
        call.msgs.feed(chunk)
      else:
        if call.msgs.leftover > 0:
          raise call.failure(scInternal, "truncated message at end of stream")
        break
    await call.finish()
    return none(seq[byte])
  except H2Error as e:
    err = call.serverStatus()
    if err == nil: err = call.mapped(e)
  except GrpcError as e:
    if not call.ended: call.cancel()   # a bad message: give up on the call
    err = e
  raise err

proc unaryCall*(ch: AsyncChannel; path: string; request: seq[byte];
                metadata: Metadata = @[]; timeoutMs = -1;
                maxMessage = defaultMaxMessage; compression = ""): Future[UnaryResult] {.async.} =
  ## Sends one message and returns the one reply. Raises GrpcError for any
  ## status other than OK.
  let call = await ch.newCall(path, metadata, timeoutMs, maxMessage, compression)
  var err: ref CatchableError
  try:
    await call.send(request)
    await call.closeSend()
    let rf = call.recv()
    discard await rf
    if rf.read.isNone:
      raise newGrpcError(scInternal, "unary call ended without a response")
    result.message = move rf.internalValue.get       # the future is not read again
    if (await call.recv()).isSome:
      raise newGrpcError(scInternal, "unary call got more than one response")
    result.headers = call.headers
    result.trailers = call.trailers
  except CancelledError as e:
    call.close()
    raise e
  except CatchableError as e:
    err = e
  call.close()
  if err != nil: raise err
