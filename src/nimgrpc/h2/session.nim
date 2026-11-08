## I/O-free HTTP/2 session on top of nghttp2.
##
## The session never touches a socket. Feed received bytes with `recv`,
## collect what to transmit with `takeOutput`, and read what happened with
## `takeEvents`. Any I/O model (blocking threads, chronos, a test harness that
## pipes two sessions into each other) can drive it.
##
## Memory rules (ORC):
## * nghttp2 gets raw `ptr` to Nim objects, never `ref` casts, so no reference
##   count is touched from C.
## * Every object handed to C as a pointer is owned by the session (`outs`
##   table) for as long as nghttp2 may call back with it.
## * Callbacks never let an exception cross into C: they are `raises: []`.

import std/tables
import ./nghttp2, ../bytebuf

type
  H2Error* = object of CatchableError
    code*: int

  Header* = tuple[name, value: string]

  H2EventKind* = enum
    evHeaders      ## a complete HEADERS block (request, response or trailers)
    evData         ## the payload of one DATA frame
    evStreamClosed ## the stream is gone; `errorCode` is 0 on a clean close
    evGoAway       ## the peer sent GOAWAY (`streamId` is its last stream id)
    evPing         ## the peer sent a PING (nghttp2 has queued the ACK)
    evPingAck      ## the peer acknowledged one of our PINGs

  H2Event* = object
    streamId*: int32
    case kind*: H2EventKind
    of evHeaders:
      headers*: seq[Header]
      headersEndStream*: bool
    of evData:
      data*: seq[byte]
      dataEndStream*: bool
    of evStreamClosed, evGoAway:
      errorCode*: uint32
    of evPing, evPingAck:
      discard

  OutStreamObj = object
    buf: seq[byte]
    pos: int
    eof: bool          ## no more DATA will be queued
    trailers: seq[Header]
    hasTrailers: bool
    deferred: bool     ## the read callback returned DEFERRED
  OutStream = ref OutStreamObj

  H2SessionObj* = object
    raw: ptr Nghttp2Session
    events: seq[H2Event]
    inHeaders: Table[int32, seq[Header]]
    inData: Table[int32, seq[byte]]
    outs: Table[int32, OutStream]
    queued: int        ## body bytes in `outs` that nghttp2 has not framed yet
    peerSettings: bool ## the peer's first SETTINGS frame has arrived: its preface is done
    failure: string    ## first error seen inside a callback
  H2Session* = ref H2SessionObj

proc `=destroy`*(s: H2SessionObj) {.raises: [].} =
  if s.raw != nil:
    nghttp2_session_del(s.raw)
  `=destroy`(s.events.addr[])
  `=destroy`(s.inHeaders.addr[])
  `=destroy`(s.inData.addr[])
  `=destroy`(s.outs.addr[])
  `=destroy`(s.failure.addr[])

proc `=copy`*(dst: var H2SessionObj; src: H2SessionObj) {.error.}

proc raiseH2(code: int; what: string) {.noreturn.} =
  var e = newException(H2Error, what & ": " & $nghttp2_strerror(code.cint))
  e.code = code
  raise e

template sess(userData: pointer): ptr H2SessionObj =
  cast[ptr H2SessionObj](userData)

proc toString(p: ptr uint8; n: csize_t): string =
  result = newString(n.int)
  if n > 0: copyMem(result[0].addr, p, n.int)

# ---------------------------------------------------------------- callbacks

proc onBeginHeaders(session: ptr Nghttp2Session; frame: ptr Nghttp2Frame;
                    userData: pointer): cint {.cdecl, raises: [].} =
  let s = sess(userData)
  s.inHeaders[frame.hd.stream_id] = @[]
  0

proc onHeader(session: ptr Nghttp2Session; frame: ptr Nghttp2Frame;
              name: ptr uint8; namelen: csize_t; value: ptr uint8; valuelen: csize_t;
              flags: uint8; userData: pointer): cint {.cdecl, raises: [].} =
  let s = sess(userData)
  s.inHeaders.mgetOrPut(frame.hd.stream_id, @[]).add(
    (toString(name, namelen), toString(value, valuelen)))
  0

proc onDataChunk(session: ptr Nghttp2Session; flags: uint8; streamId: int32;
                 data: ptr uint8; len: csize_t; userData: pointer): cint
                 {.cdecl, raises: [].} =
  let s = sess(userData)
  var acc = s.inData.mgetOrPut(streamId, @[]).addr
  acc[].appendBytes(data, len.int)
  0

proc onFrameRecv(session: ptr Nghttp2Session; frame: ptr Nghttp2Frame;
                 userData: pointer): cint {.cdecl, raises: [].} =
  let s = sess(userData)
  let id = frame.hd.stream_id
  let endStream = (frame.hd.flags and NGHTTP2_FLAG_END_STREAM) != 0
  case frame.hd.`type`
  of NGHTTP2_SETTINGS:
    if (frame.hd.flags and NGHTTP2_FLAG_ACK) == 0: s.peerSettings = true
  of NGHTTP2_HEADERS:
    var hs: seq[Header]
    discard s.inHeaders.pop(id, hs)
    s.events.add H2Event(streamId: id, kind: evHeaders, headers: move hs,
                         headersEndStream: endStream)
  of NGHTTP2_DATA:
    var d: seq[byte]
    discard s.inData.pop(id, d)
    s.events.add H2Event(streamId: id, kind: evData, data: move d,
                         dataEndStream: endStream)
  of NGHTTP2_GOAWAY:
    s.events.add H2Event(streamId: frame.goaway.last_stream_id, kind: evGoAway,
                         errorCode: frame.goaway.error_code)
  of NGHTTP2_PING:
    if (frame.hd.flags and NGHTTP2_FLAG_ACK) != 0:
      s.events.add H2Event(kind: evPingAck)
    else:
      s.events.add H2Event(kind: evPing)
  else: discard
  0

proc onStreamClose(session: ptr Nghttp2Session; streamId: int32;
                   errorCode: uint32; userData: pointer): cint {.cdecl, raises: [].} =
  let s = sess(userData)
  s.inHeaders.del(streamId)
  s.inData.del(streamId)
  let gone = s.outs.getOrDefault(streamId)
  if gone != nil: s.queued -= gone.buf.len - gone.pos
  s.outs.del(streamId)
  s.events.add H2Event(streamId: streamId, kind: evStreamClosed, errorCode: errorCode)
  0

proc buildNva(hs: openArray[Header]): seq[Nghttp2Nv] =
  ## An nghttp2_nv array that borrows from `hs`; it must not outlive `hs`.
  ## nghttp2 copies names and values on submit (NV_FLAG_NONE).
  result = newSeq[Nghttp2Nv](hs.len)
  for i, (k, v) in hs:
    result[i] = Nghttp2Nv(
      name: cast[ptr uint8](k.cstring), namelen: k.len.csize_t,
      value: cast[ptr uint8](v.cstring), valuelen: v.len.csize_t,
      flags: NGHTTP2_NV_FLAG_NONE)

template nvaPtr(nva: seq[Nghttp2Nv]): ptr Nghttp2Nv =
  (if nva.len > 0: nva[0].unsafeAddr else: nil)

template nvaLen(nva: seq[Nghttp2Nv]): csize_t = nva.len.csize_t

proc readOut(session: ptr Nghttp2Session; streamId: int32; buf: ptr uint8;
             length: csize_t; dataFlags: ptr uint32; source: ptr Nghttp2DataSource;
             userData: pointer): Nghttp2Ssize {.cdecl, raises: [].} =
  let o = cast[ptr OutStreamObj](source.`ptr`)
  let ss = sess(userData)
  let avail = o.buf.len - o.pos
  if avail == 0 and not o.eof:
    o.deferred = true
    return NGHTTP2_ERR_DEFERRED
  let n = min(avail, length.int)
  if n > 0:
    copyMem(buf, o.buf[o.pos].addr, n)
    o.pos += n
    ss.queued -= n
    if o.pos == o.buf.len:          # drop what has been sent
      o.buf.setLen(0)
      o.pos = 0
    elif o.pos >= 65536 and o.pos * 2 >= o.buf.len:
      # A producer that keeps the buffer non-empty would otherwise grow it
      # forever; shift the unsent tail to the front.
      let rest = o.buf.len - o.pos
      moveMem(o.buf[0].addr, o.buf[o.pos].addr, rest)
      o.buf.setLen(rest)
      o.pos = 0
  if o.eof and o.buf.len == 0:
    dataFlags[] = dataFlags[] or NGHTTP2_DATA_FLAG_EOF
    if o.hasTrailers:
      dataFlags[] = dataFlags[] or NGHTTP2_DATA_FLAG_NO_END_STREAM
      let nva = buildNva(o.trailers)
      if nghttp2_submit_trailer(session, streamId, nvaPtr(nva), nvaLen(nva)) != 0:
        return NGHTTP2_ERR_CALLBACK_FAILURE
  n

# ---------------------------------------------------------------- public API

const
  maxContinuations* = 8
    ## CONTINUATION frames allowed after one HEADERS frame; one more is a
    ## connection error (CONTINUATION flood, CVE-2024-28182).
  resetBurst = 1000'u64
  resetRate = 33'u64
    ## RST_STREAM frames a peer may send: a burst, then a rate per second;
    ## past them the connection gets ENHANCE_YOUR_CALM (Rapid Reset, CVE-2023-44487).

const receiveWindow* = 1024 * 1024
  ## What a peer may send us per stream, and per connection, before we credit
  ## it again; also the most a stream's unread data can grow to.

proc newSession(server, manualFlow: bool; maxStreams: int): H2Session =
  result = H2Session()
  var cbs: ptr Nghttp2SessionCallbacks
  if nghttp2_session_callbacks_new(cbs.addr) != 0:
    raise newException(H2Error, "nghttp2_session_callbacks_new failed")
  nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, cast[pointer](onBeginHeaders))
  nghttp2_session_callbacks_set_on_header_callback(cbs, cast[pointer](onHeader))
  nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, cast[pointer](onFrameRecv))
  nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, cast[pointer](onDataChunk))
  nghttp2_session_callbacks_set_on_stream_close_callback(cbs, cast[pointer](onStreamClose))
  let ud = cast[pointer](result[].addr)
  var opt: ptr Nghttp2Option
  if nghttp2_option_new(opt.addr) != 0:
    nghttp2_session_callbacks_del(cbs)
    raise newException(H2Error, "nghttp2_option_new failed")
  # What nghttp2 does by default today, written down so that a later default
  # cannot loosen it unnoticed.
  nghttp2_option_set_max_continuations(opt, maxContinuations.csize_t)
  nghttp2_option_set_stream_reset_rate_limit(opt, resetBurst, resetRate)
  if manualFlow: nghttp2_option_set_no_auto_window_update(opt, 1)
  let rv =
    if server: nghttp2_session_server_new2(result.raw.addr, cbs, ud, opt)
    else: nghttp2_session_client_new2(result.raw.addr, cbs, ud, opt)
  nghttp2_session_callbacks_del(cbs)
  if opt != nil: nghttp2_option_del(opt)
  if rv != 0: raiseH2(rv, "session_new")
  # The default window of 64 KiB makes a large message wait for the peer's
  # WINDOW_UPDATE every 64 KiB, each a round trip of threads and syscalls.
  var iv: array[2, tuple[id: int32, value: uint32]]
  iv[0] = (4'i32, receiveWindow.uint32)           # SETTINGS_INITIAL_WINDOW_SIZE
  var nIv = 1
  if maxStreams > 0:
    iv[1] = (3'i32, maxStreams.uint32)            # SETTINGS_MAX_CONCURRENT_STREAMS
    nIv = 2
  let rs = nghttp2_submit_settings(result.raw, NGHTTP2_FLAG_NONE, iv.addr, nIv.csize_t)
  if rs != 0: raiseH2(rs, "submit_settings")
  let rw = nghttp2_submit_window_update(result.raw, NGHTTP2_FLAG_NONE, 0,
                                        (receiveWindow - 65535).int32)
  if rw != 0: raiseH2(rw, "window_update")

proc newClientSession*(manualFlow = false): H2Session = newSession(false, manualFlow, 0)
proc newServerSession*(manualFlow = false; maxConcurrentStreams = 0): H2Session =
  ## With `maxConcurrentStreams` > 0 the server announces that limit.
  ## With `manualFlow` nghttp2 sends no WINDOW_UPDATE by itself: the peer's
  ## window only reopens as the application calls `consume`, so a slow reader
  ## backpressures the sender instead of buffering without bound.
  newSession(true, manualFlow, maxConcurrentStreams)

proc consume*(s: H2Session; streamId: int32; n: int) =
  ## Reports `n` received DATA bytes as processed (manual flow control only).
  ## Pass `streamId` 0 for bytes of a stream that is gone: only the
  ## connection window is credited.
  if n <= 0: return
  let rc = nghttp2_session_consume_connection(s.raw, n.csize_t)
  if rc != 0: raiseH2(rc, "consume_connection")
  if streamId != 0:
    let rs = nghttp2_session_consume(s.raw, streamId, n.csize_t)
    # The stream may have closed since the data arrived; that is not an error.
    if rs != 0 and rs != NGHTTP2_ERR_INVALID_ARGUMENT: raiseH2(rs, "consume")

proc recv*(s: H2Session; data: openArray[byte]) =
  ## Feeds bytes read from the transport. Raises H2Error on a fatal
  ## connection error (the caller should then send `takeOutput` and close).
  if data.len == 0: return
  let rv = nghttp2_session_mem_recv2(s.raw, data[0].unsafeAddr, data.len.csize_t)
  if rv < 0: raiseH2(rv, "mem_recv")

proc takeOutputInto*(s: H2Session; dst: var seq[byte]) =
  ## Like `takeOutput`, appending to `dst` and so saving a copy.
  while true:
    var p: ptr uint8
    let n = nghttp2_session_mem_send2(s.raw, p.addr)
    if n < 0: raiseH2(n, "mem_send")
    if n == 0: break
    dst.appendBytes(p, n.int)

proc takeOutput*(s: H2Session): seq[byte] =
  ## Everything nghttp2 wants to transmit right now.
  s.takeOutputInto(result)

proc takeEvents*(s: H2Session): seq[H2Event] =
  result = move s.events
  s.events = @[]

proc wantRead*(s: H2Session): bool = nghttp2_session_want_read(s.raw) != 0
proc wantWrite*(s: H2Session): bool = nghttp2_session_want_write(s.raw) != 0

proc provider(o: OutStream): Nghttp2DataProvider2 =
  result.source.`ptr` = cast[pointer](o[].addr)
  result.read_callback = readOut

proc submitRequest*(s: H2Session; headers: openArray[Header];
                    endStream = false): int32 =
  ## Opens a stream. With `endStream = false` the body follows via `sendData`.
  var o: OutStream
  var prd: Nghttp2DataProvider2
  if not endStream:
    o = OutStream()
    prd = provider(o)
  let nva = buildNva(headers)
  let id = nghttp2_submit_request2(s.raw, nil, nvaPtr(nva), nvaLen(nva),
                                   if endStream: nil else: prd.addr, nil)
  if id < 0: raiseH2(id, "submit_request")
  if o != nil: s.outs[id] = o
  id

proc submitResponse*(s: H2Session; streamId: int32; headers: openArray[Header];
                     endStream = false) =
  var o: OutStream
  var prd: Nghttp2DataProvider2
  if not endStream:
    o = OutStream()
    prd = provider(o)
    s.outs[streamId] = o
  let nva = buildNva(headers)
  let rv = nghttp2_submit_response2(s.raw, streamId, nvaPtr(nva), nvaLen(nva),
                                    if endStream: nil else: prd.addr)
  if rv != 0:
    s.outs.del(streamId)
    raiseH2(rv, "submit_response")

proc outStream(s: H2Session; streamId: int32): OutStream =
  result = s.outs.getOrDefault(streamId)
  if result == nil:
    raise newException(H2Error, "stream " & $streamId & " has no open body")
  if result.eof:
    raise newException(H2Error, "stream " & $streamId & " body already ended")

proc wake(s: H2Session; streamId: int32; o: OutStream) =
  if o.deferred:
    o.deferred = false
    discard nghttp2_session_resume_data(s.raw, streamId)

proc sendData*(s: H2Session; streamId: int32; head, data: openArray[byte];
               endStream = false) =
  ## Queues body bytes (`head` then `data`, so a caller can put a message
  ## prefix in front without copying the message); nghttp2 frames them subject
  ## to flow control.
  let o = s.outStream(streamId)
  o.buf.appendBytes head
  o.buf.appendBytes data
  s.queued += head.len + data.len
  if endStream: o.eof = true
  s.wake(streamId, o)

proc sendData*(s: H2Session; streamId: int32; data: openArray[byte];
               endStream = false) =
  s.sendData(streamId, [], data, endStream)

proc sendTrailers*(s: H2Session; streamId: int32; trailers: openArray[Header]) =
  ## Ends the body and closes the stream with a trailing HEADERS block.
  let o = s.outStream(streamId)
  o.trailers = @trailers
  o.hasTrailers = true
  o.eof = true
  s.wake(streamId, o)

proc buffered*(s: H2Session; streamId: int32): int =
  ## Body bytes queued on `streamId` that nghttp2 has not framed yet.
  let o = s.outs.getOrDefault(streamId)
  if o != nil: o.buf.len - o.pos else: 0

proc gotPeerSettings*(s: H2Session): bool =
  ## True once the peer has sent its first SETTINGS frame, which every HTTP/2 peer sends first.
  s.peerSettings

proc queuedBytes*(s: H2Session): int =
  ## Body bytes queued on all streams that nghttp2 has not framed yet.
  s.queued

proc resetStream*(s: H2Session; streamId: int32; errorCode = NGHTTP2_CANCEL) =
  let rv = nghttp2_submit_rst_stream(s.raw, NGHTTP2_FLAG_NONE, streamId, errorCode)
  if rv != 0: raiseH2(rv, "submit_rst_stream")

proc ping*(s: H2Session) =
  let rv = nghttp2_submit_ping(s.raw, NGHTTP2_FLAG_NONE, nil)
  if rv != 0: raiseH2(rv, "submit_ping")

proc shutdownNotice*(s: H2Session) =
  ## Server: the first, advisory GOAWAY of a graceful shutdown; streams
  ## already opened by the client in the meantime are still served.
  let rv = nghttp2_submit_shutdown_notice(s.raw)
  if rv != 0: raiseH2(rv, "submit_shutdown_notice")

proc requestAllowed*(s: H2Session): bool =
  ## Client: false once a new stream cannot be opened (GOAWAY received or sent).
  nghttp2_session_check_request_allowed(s.raw) != 0

proc goAway*(s: H2Session; errorCode = NGHTTP2_NO_ERROR; debug = "") =
  ## GOAWAY naming the last stream this side processed. `debug` goes in the
  ## frame's opaque data (gRPC uses "too_many_pings").
  let last = nghttp2_session_get_last_proc_stream_id(s.raw)
  let rv = nghttp2_submit_goaway(s.raw, NGHTTP2_FLAG_NONE, last, errorCode,
                                 if debug.len > 0: cast[ptr uint8](debug.cstring) else: nil,
                                 debug.len.csize_t)
  if rv != 0: raiseH2(rv, "submit_goaway")
