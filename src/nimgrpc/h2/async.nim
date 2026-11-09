## HTTP/2 over chronos: the same sans-I/O session as the blocking adapter,
## driven by one event loop instead of threads.
##
## Per connection three tasks run on the loop: a reader (socket -> TLS ->
## session -> stream events), a writer (session -> TLS -> socket, one write in
## flight, at most `maxOutQueue` bytes framed ahead) and, with keepalive, a
## pinger. A sender awaits while its stream holds more than `maxStreamBuffer`
## unsent bytes, so a slow peer slows the producer down.
##
## Everything here runs on the thread that owns the event loop; nothing may
## be shared with other threads.
##
## Server handlers are futures. When a call ends abnormally (the client reset
## it, its deadline passed, the connection closed) its handler future is
## cancelled, so whatever it awaits stops right away.

import std/[tables, deques]
import pkg/chronos
import ./session, ./common, ./tcpopts, ../tls/tls, ../bytebuf

export session.Header, session.H2Error, tls, common.H2Timeout,
       common.H2StreamClosed, common.Keepalive, common.PingPolicy, common.Limits

type
  Task = Future[void].Raising([])   ## a loop task or handler; never fails

  AsyncH2Stream* = ref object
    ## One request stream: opened by `openStream` on a client, handed to the
    ## handler on a server.
    conn: AsyncH2Conn
    id*: int32
    headers*: seq[Header]      ## server: the request HEADERS
    blocks: seq[seq[Header]]   ## HEADERS blocks received
    inbuf: seq[byte]           ## body bytes received and not yet taken
    inEnded: bool              ## END_STREAM received
    outEnded: bool             ## we sent END_STREAM (or trailers)
    responded: bool            ## server: response HEADERS submitted
    closed: bool
    timedOut: bool             ## closed by its deadline
    released: bool
    errorCode: uint32          ## RST_STREAM / GOAWAY code, 0 on a clean close
    hasDeadline: bool
    deadline: Moment
    timer: TimerCallback
    waiters: seq[Future[void]]
    handler: Task              ## server: the running handler

  AsyncH2Conn* = ref object
    transp: StreamTransport
    sess: H2Session
    tls: TlsConn
    tlsConf: TlsConfig
    tlsIn: seq[byte]
    tlsInPos: int
    plainOut: seq[byte]
    plainPos: int
    outQ: Deque[seq[byte]]
    outQBytes: int
    writeEv: AsyncEvent
    closedEv: AsyncEvent
    roomWaiters: seq[Future[void]]
    streams: Table[int32, AsyncH2Stream]
    closed: bool
    failure: string
    server: AsyncH2Server      ## nil for a client connection
    maxBuffer: int             ## `Limits.maxConnectionBuffer`; 0 for no limit
    lastDispatched: int32
    ka: Keepalive
    policy: PingPolicy
    lastRead: Moment
    created: Moment
    activity: Moment           ## server: when a call last began or ended
    handshakeMs: int           ## server: how long the peer has to send its first SETTINGS; 0 for no limit
    maxAgeMs, maxIdleMs, graceMs: int   ## server: `Limits.maxConnection...Ms`; 0 for no limit
    pingOutstanding: bool
    pingSent: Moment
    lastPingRecv: Moment
    pingStrikes: int
    goawayReceived: bool
    readerF, writerF, pingerF, guardF, lifeF: Task

  AsyncStreamHandler* = proc (st: AsyncH2Stream; userData: pointer): Future[void]
    {.gcsafe, raises: [].}
    ## Starts on the loop when the request HEADERS arrive. If its future
    ## completes without the response having ended, the stream is reset with
    ## INTERNAL_ERROR.

  AsyncH2Server* = ref object
    srv: StreamServer
    handler: AsyncStreamHandler
    userData: pointer
    tls: TlsConfig
    ka: Keepalive
    policy: PingPolicy
    limits: Limits
    conns: seq[AsyncH2Conn]
    stopping: bool

# ------------------------------------------------------------ waiting

proc notify(st: AsyncH2Stream) =
  if st.waiters.len == 0: return
  let ws = move st.waiters
  st.waiters = @[]
  for f in ws:
    if not f.finished: f.complete()

proc notifyRoom(c: AsyncH2Conn) =
  if c.roomWaiters.len == 0: return
  let ws = move c.roomWaiters
  c.roomWaiters = @[]
  for f in ws:
    if not f.finished: f.complete()

proc changed(st: AsyncH2Stream; room = false): Future[void] =
  ## Completes at the next change to the stream (or, with `room`, when the
  ## writer has drained some output).
  result = newFuture[void]("h2.stream.changed")
  st.waiters.add result
  if room: st.conn.roomWaiters.add result

# ------------------------------------------------------------ connection internals

proc queueOutput(c: AsyncH2Conn; force = false) =
  ## Moves what the session produced (encrypted, with TLS) to the writer.
  if c.outQBytes >= maxOutQueue and not force: return
  if c.tls == nil:
    let o = c.sess.takeOutput()
    if o.len > 0:
      c.outQBytes += o.len
      c.outQ.addLast o
  else:
    c.sess.takeOutputInto(c.plainOut)
    while true:
      var progressed = false
      if c.plainPos < c.plainOut.len:
        let n = c.tls.pushApp(c.plainOut.toOpenArray(c.plainPos, c.plainOut.high))
        if n > 0:
          c.plainOut.consumed(c.plainPos, n)
          progressed = true
      if c.plainOut.len == 0: c.tls.flush()
      let recs = c.tls.pullRecords()
      if recs.len > 0:
        c.outQBytes += recs.len
        c.outQ.addLast recs
        progressed = true
      if not progressed or (c.outQBytes >= maxOutQueue and not force): break
  if c.outQ.len > 0: c.writeEv.fire()

proc cancelHandler(st: AsyncH2Stream) =
  ## Server: the call is over for the client before the handler ended it.
  if st.handler != nil and not st.handler.finished and not st.outEnded:
    st.handler.cancelSoon()

proc fail(c: AsyncH2Conn; why: string) =
  if c.closed: return
  c.closed = true
  if c.failure.len == 0: c.failure = why
  for st in c.streams.values:
    st.closed = true
    st.notify()
    st.cancelHandler()
  c.notifyRoom()
  c.writeEv.fire()
  c.closedEv.fire()

proc onDeadline(st: AsyncH2Stream) =
  st.timer = nil
  if st.closed: return
  st.timedOut = true
  let c = st.conn
  if not c.closed and not st.released:
    try:
      c.sess.resetStream(st.id, CANCEL)
      c.queueOutput()
    except CatchableError: discard
  st.closed = true
  st.errorCode = CANCEL
  st.notify()
  st.cancelHandler()

proc armDeadline(st: AsyncH2Stream; ms: int) =
  if ms < 0: return
  st.hasDeadline = true
  st.deadline = Moment.now() + ms.milliseconds
  if st.timer != nil: clearTimer(st.timer)
  st.timer = setTimer(st.deadline, proc (arg: pointer) {.gcsafe, raises: [].} =
    st.onDeadline())

proc credit(c: AsyncH2Conn; streamId: int32; n: int) =
  ## Gives `n` processed (or discarded) body bytes back to the peer's window.
  if n <= 0 or c.closed: return
  try:
    c.sess.consume(streamId, n)
    c.queueOutput()
  except CatchableError: discard

proc forget(c: AsyncH2Conn; st: AsyncH2Stream) =
  if st.inbuf.len > 0:
    c.credit(0, st.inbuf.len)    # unread bytes must not hold the connection window
    st.inbuf = @[]
  if st.timer != nil:
    clearTimer(st.timer)
    st.timer = nil
  c.streams.del(st.id)

proc runHandler(c: AsyncH2Conn; st: AsyncH2Stream) {.async: (raises: []).}

proc handleEvents(c: AsyncH2Conn) =
  let isServer = c.server != nil
  var events = c.sess.takeEvents()
  for ev in events.mitems:
    let st = c.streams.getOrDefault(ev.streamId)
    case ev.kind
    of evHeaders:
      if st != nil:
        st.blocks.add ev.headers
        if ev.headersEndStream: st.inEnded = true
        st.notify()
      elif isServer and ev.streamId > c.lastDispatched and not c.server.stopping:
        let ns = AsyncH2Stream(conn: c, id: ev.streamId, headers: ev.headers,
                               blocks: @[ev.headers], inEnded: ev.headersEndStream)
        c.streams[ev.streamId] = ns
        c.activity = Moment.now()
        c.lastDispatched = ev.streamId
        ns.handler = c.runHandler(ns)
    of evData:
      if st != nil and not st.released:
        if st.inbuf.len == 0: st.inbuf = move ev.data     # no copy
        else: st.inbuf.appendBytes ev.data
        if ev.dataEndStream: st.inEnded = true
        st.notify()
      else:
        c.credit(0, ev.data.len)
    of evStreamClosed:
      if st != nil:
        st.closed = true
        st.errorCode = ev.errorCode
        st.notify()
        if ev.errorCode != 0: st.cancelHandler()
    of evGoAway:
      c.goawayReceived = true
    of evPingAck:
      c.pingOutstanding = false
    of evPing:
      if isServer and c.policy.minIntervalMs > 0:
        let now = Moment.now()
        let idle = c.streams.len == 0
        if (idle and not c.policy.permitWithoutCalls) or
           (c.lastPingRecv != Moment() and
            now - c.lastPingRecv < c.policy.minIntervalMs.milliseconds):
          inc c.pingStrikes
        c.lastPingRecv = now
        if c.pingStrikes > 2:
          c.sess.goAway(ENHANCE_YOUR_CALM, "too_many_pings")
          c.queueOutput(force = true)
          c.fail("client sent too many pings")
    if ev.kind in {evHeaders, evData}: c.pingStrikes = 0

proc pumpTlsIn(c: AsyncH2Conn) =
  ## Decrypts buffered records and feeds the plaintext to the session.
  var app: seq[byte]
  while true:
    let k = c.tls.pushRecords(c.tlsIn.toOpenArray(c.tlsInPos, c.tlsIn.high))
    if k > 0: c.tlsIn.consumed(c.tlsInPos, k)
    c.tls.pullApp(app)
    if k == 0:
      # The engine wants to send first (handshake), or is closed.
      let before = c.outQBytes
      c.queueOutput()
      if c.outQBytes == before or c.tlsIn.len == 0: break
    elif c.tlsIn.len == 0:
      break
  c.tls.checkPeer()
  if app.len > 0: c.sess.recv(app)
  if c.tls.isClosed: raise newException(TlsError, c.tls.errorMessage)

proc onBytes(c: AsyncH2Conn; data: openArray[byte]) =
  ## Bytes from the socket: through TLS into the session, then events out.
  c.lastRead = Moment.now()
  try:
    if c.tls == nil:
      c.sess.recv(data)
    else:
      c.tlsIn.appendBytes data
      c.pumpTlsIn()
    c.handleEvents()
    c.queueOutput()
    if not c.sess.wantRead() and not c.sess.wantWrite() and c.outQ.len == 0:
      c.fail("session finished")
  except CatchableError as e:
    # A connection error: nghttp2 has queued a GOAWAY; send it, then stop.
    try: c.queueOutput(force = true)
    except CatchableError: discard
    c.fail(e.msg)

proc readerLoop(c: AsyncH2Conn) {.async: (raises: []).} =
  ## Works on chronos' own read buffer (`readMessage`), so a connection costs
  ## no read buffer of ours.
  var eof = false
  proc take(data: openArray[byte]): tuple[consumed: int, done: bool] {.gcsafe, raises: [].} =
    if data.len == 0:
      eof = true
      return (0, true)
    if not c.closed: c.onBytes(data)
    (data.len, true)
  while not c.closed:
    try:
      await c.transp.readMessage(take)
    except CancelledError:
      c.fail("closed")
      break
    except CatchableError:
      c.fail("read error")
      break
    if eof:
      c.fail("connection closed by peer")
      break

proc writerLoop(c: AsyncH2Conn) {.async: (raises: []).} =
  while true:
    while c.outQ.len == 0 and not c.closed:
      try:
        await c.writeEv.wait()
      except CancelledError:
        c.fail("closed")
      c.writeEv.clear()
    if c.outQ.len == 0: break       # closed and drained
    let chunk = c.outQ.popFirst()
    var ok = true
    try:
      ok = (await c.transp.write(chunk)) == chunk.len
    except CatchableError:
      ok = false
    c.outQBytes -= chunk.len
    if ok:
      try:
        if c.tls != nil and c.tlsIn.len > 0:
          c.pumpTlsIn()
          c.handleEvents()
        c.queueOutput()
      except CatchableError as e: c.fail(e.msg)
      c.notifyRoom()
    else:
      c.fail("write error")
      c.outQ.clear()
      c.outQBytes = 0
  # Everything is out; closing the socket also ends the reader.
  await c.transp.closeWait()

proc pingDue(c: AsyncH2Conn): int =
  ## Sends a due PING or closes a connection whose PING went unanswered.
  ## Returns how long to wait (ms) before checking again, or -1 to stop.
  if c.ka.timeMs <= 0 or c.closed: return -1
  let now = Moment.now()
  let timeout = (if c.ka.timeoutMs > 0: c.ka.timeoutMs else: defaultPingTimeoutMs).milliseconds
  if c.pingOutstanding:
    let due = c.pingSent + timeout
    if now >= due:
      c.fail("keepalive: no response to PING within " & $timeout.milliseconds & " ms")
      return -1
    return int((due - now).milliseconds) + 1
  let due = c.lastRead + c.ka.timeMs.milliseconds
  if now < due: return int((due - now).milliseconds) + 1
  if c.streams.len > 0 or c.ka.withoutCalls or c.server != nil:
    try:
      c.sess.ping()
      c.pingOutstanding = true
      c.pingSent = now
      c.queueOutput()
    except CatchableError as e:
      c.fail(e.msg)
      return -1
    return int(timeout.milliseconds) + 1
  c.ka.timeMs                       # idle and not allowed to ping: look again later

proc pingerLoop(c: AsyncH2Conn) {.async: (raises: []).} =
  while true:
    let ms = c.pingDue()
    if ms < 0: break
    try:
      discard await withTimeout(c.closedEv.wait(), ms.milliseconds)
    except CancelledError:
      break

proc handshakeGuard(c: AsyncH2Conn) {.async: (raises: []).} =
  ## Server: closes a connection whose peer has not sent its first SETTINGS (the TLS handshake
  ## and the HTTP/2 preface are behind that) within `handshakeMs`.
  let limit = c.created + c.handshakeMs.milliseconds
  while not c.closed and not c.sess.gotPeerSettings:
    if Moment.now() >= limit:
      c.fail("handshake not completed in " & $c.handshakeMs & " ms")
      break
    try:
      await sleepAsync(100.milliseconds)
    except CancelledError:
      break

proc lifecycleLoop(c: AsyncH2Conn) {.async: (raises: []).} =
  ## Server: drains a connection that is too old or has had no call for too long: an advisory
  ## GOAWAY, the final one a moment later, then the calls in progress finish (for up to
  ## `graceMs`) and the connection closes.
  let ageNs = c.maxAgeMs.int64 * 1_000_000
  # +-10% so that the clients of a restarted server do not all return together
  let ageDue = if c.maxAgeMs > 0:
                 c.created + nanoseconds(ageNs + ageNs * ((c.created.epochNanoSeconds div 1000) mod 21 - 10) div 100)
               else: c.created
  var state = 0               # 0 serving, 1 advisory GOAWAY out, 2 final GOAWAY out
  var stateAt = c.created     # when state 1 began; the end of the grace in state 2
  var why = ""
  while not c.closed:
    let now = Moment.now()
    var wait = 1.hours
    case state
    of 0:
      if c.streams.len > 0: c.activity = now
      if c.maxAgeMs > 0:
        if now >= ageDue: why = "maximum connection age"
        else: wait = min(wait, ageDue - now)
      if c.maxIdleMs > 0:
        let idleDue = c.activity + c.maxIdleMs.milliseconds
        if now >= idleDue:
          if why.len == 0: why = "maximum connection idle time"
        else: wait = min(wait, min(idleDue - now, 1.seconds))
      if why.len > 0:
        try:
          c.sess.shutdownNotice()
          c.queueOutput()
        except CatchableError as e:
          c.fail(e.msg)
          return
        state = 1
        stateAt = now
        wait = 100.milliseconds
    of 1:
      if now >= stateAt + 100.milliseconds:
        try:
          c.sess.goAway()
          c.queueOutput()
        except CatchableError as e:
          c.fail(e.msg)
          return
        state = 2
        stateAt = now + c.graceMs.milliseconds
      wait = 100.milliseconds
    else:
      if c.streams.len == 0:
        c.fail("connection drained")
        return
      if c.graceMs > 0 and now >= stateAt:
        c.fail("grace of the connection over")
        return
      wait = 100.milliseconds
    try:
      discard await withTimeout(c.closedEv.wait(), max(wait, 1.milliseconds))
    except CancelledError:
      break

proc newConn(transp: StreamTransport; sess: H2Session; server: AsyncH2Server;
             ka: Keepalive): AsyncH2Conn =
  AsyncH2Conn(transp: transp, sess: sess, server: server, ka: ka,
              outQ: initDeque[seq[byte]](), writeEv: newAsyncEvent(),
              closedEv: newAsyncEvent(), lastRead: Moment.now(), created: Moment.now(), activity: Moment.now())

proc start(c: AsyncH2Conn) =
  c.queueOutput()             # client preface / SETTINGS
  c.readerF = c.readerLoop()
  c.writerF = c.writerLoop()
  if c.ka.timeMs > 0: c.pingerF = c.pingerLoop()
  if c.handshakeMs > 0: c.guardF = c.handshakeGuard()
  if c.maxAgeMs > 0 or c.maxIdleMs > 0: c.lifeF = c.lifecycleLoop()

proc shutdown(c: AsyncH2Conn) {.async: (raises: []).} =
  ## Sends GOAWAY (and TLS close_notify), closes the connection and waits
  ## until its tasks have ended.
  if not c.closed:
    try:
      c.sess.goAway()
      c.queueOutput(force = true)
      if c.tls != nil and not c.tls.isClosed:
        c.tls.close()
        c.queueOutput(force = true)
    except CatchableError: discard
    c.fail("closed")
  if c.writerF != nil: await noCancel c.writerF
  if c.readerF != nil: await noCancel c.readerF
  if c.pingerF != nil: await noCancel c.pingerF
  if c.guardF != nil: await noCancel c.guardF
  if c.lifeF != nil: await noCancel c.lifeF

# ------------------------------------------------------------ streams

proc closedError(st: AsyncH2Stream): ref H2StreamClosed =
  let c = st.conn
  let why = if st.errorCode != 0: "reset with error " & $st.errorCode
            elif c.failure.len > 0: c.failure
            else: "closed"
  newException(H2StreamClosed, "stream " & $st.id & ": " & why)

proc timeoutError(st: AsyncH2Stream): ref H2Timeout =
  newException(H2Timeout, "deadline exceeded on stream " & $st.id)

template checkGone(st: AsyncH2Stream) =
  if st.timedOut: raise st.timeoutError
  if st.closed or st.conn.closed: raise st.closedError

proc setTimeout*(st: AsyncH2Stream; ms: int) =
  ## Server: the stream is reset with CANCEL `ms` from now (the client's
  ## grpc-timeout); later calls raise H2Timeout and the handler is cancelled.
  st.armDeadline(ms)

proc isClosed*(st: AsyncH2Stream): bool =
  ## True once the stream is gone (cancelled, reset, timed out, connection closed).
  st.closed or st.conn.closed

proc deadlinePassed*(st: AsyncH2Stream): bool =
  st.timedOut or (st.hasDeadline and Moment.now() >= st.deadline)

proc remainingMs*(st: AsyncH2Stream): int =
  ## Milliseconds until the deadline (at least 0), or -1 without one.
  if not st.hasDeadline: return -1
  max(int((st.deadline - Moment.now()).milliseconds), 0)

proc errorCode*(st: AsyncH2Stream): uint32 = st.errorCode
  ## The RST_STREAM code the stream ended with, 0 if none.

proc peerEnded*(st: AsyncH2Stream): bool = st.inEnded
  ## True once the peer has ended its side (END_STREAM received).

proc waitClosed*(st: AsyncH2Stream; ms: int): Future[bool] {.async.} =
  ## Waits up to `ms` for the stream to close; true if it did.
  if st.isClosed: return true
  let until = Moment.now() + ms.milliseconds
  while not st.isClosed:
    let left = until - Moment.now()
    if left <= ZeroDuration: return false
    discard await withTimeout(st.changed(), left)
  true

type
  SendJob* = ref object
    ## A body that did not fit into the stream's buffer yet.
    head, data: seq[byte]
    off: int
    endStream: bool

proc pushSome(st: AsyncH2Stream; head, data: openArray[byte]; off: var int;
              endStream: bool): bool =
  ## Queues as much of `head` then `data` (from `off` on) as the stream's
  ## buffer has room for; true once everything is queued.
  let c = st.conn
  st.checkGone()
  if st.outEnded: raise newException(H2Error, "stream " & $st.id & ": body already ended")
  var room = maxStreamBuffer - c.sess.buffered(st.id)
  if c.maxBuffer > 0: room = min(room, c.maxBuffer - c.sess.queuedBytes)
  let total = head.len + data.len
  let remaining = total - off
  if room <= 0 and remaining > 0: return false
  let n = min(max(room, 0), remaining)
  let last = n == remaining
  if n > 0 or (last and endStream):
    let h0 = min(off, head.len)
    let h1 = min(off + n, head.len)
    let d0 = max(off - head.len, 0)
    let d1 = max(off + n - head.len, 0)
    c.sess.sendData(st.id, head.toOpenArray(h0, h1 - 1), data.toOpenArray(d0, d1 - 1),
                    endStream = last and endStream)
    off += n
    if last and endStream: st.outEnded = true
    c.queueOutput()
  last

proc push*(st: AsyncH2Stream; data: var seq[byte]; head: openArray[byte] = [];
           endStream = false): SendJob =
  ## Queues `head` then `data` without a copy of `data`. Returns nil when it
  ## all fitted; otherwise a job for `finish`, which now owns `data` (moved
  ## out of the argument). Raises H2Error if the stream is gone.
  var off = 0
  if st.pushSome(head, data, off, endStream): return nil
  SendJob(head: @head, data: move data, off: off, endStream: endStream)

proc finish*(st: AsyncH2Stream; job: SendJob) {.async.} =
  ## Waits for room and queues the rest of a body `push` left over.
  while true:
    await st.changed(room = true)
    if st.pushSome(job.head, job.data, job.off, job.endStream): return

proc completed*(): Future[void] =
  ## An already finished future, for a call that had nothing to wait for.
  result = newFuture[void]("h2.completed")
  result.complete()

proc send*(st: AsyncH2Stream; data: sink seq[byte]; endStream = false;
           head: openArray[byte] = []): Future[void] =
  ## Queues body bytes, waiting while the stream's unsent buffer is full.
  ## `head` goes in front of `data`. Pass a value you no longer need (or
  ## `move` it) and it is not copied.
  var d = data
  try:
    let job = st.push(d, head, endStream)
    result = if job == nil: completed() else: st.finish(job)
  except CatchableError as e:
    result = newFuture[void]("h2.send")
    result.fail(e)

proc recvData*(st: AsyncH2Stream): Future[seq[byte]] {.async.} =
  ## The next part of the body; empty at its end.
  while true:
    if st.inbuf.len > 0:
      result = move st.inbuf
      st.inbuf = @[]
      st.conn.credit(st.id, result.len)
      return
    if st.inEnded: return
    st.checkGone()
    await st.changed()

proc ended*(st: AsyncH2Stream): bool = st.inEnded and st.inbuf.len == 0
  ## The whole body has been taken.

proc sendHeaders*(st: AsyncH2Stream; headers: seq[Header]; endStream = false) =
  ## Server: the response HEADERS. With `endStream` nothing else follows.
  st.checkGone()
  if st.responded: raise newException(H2Error, "response HEADERS already sent")
  let c = st.conn
  c.sess.submitResponse(st.id, headers, endStream)
  st.responded = true
  if endStream: st.outEnded = true
  c.queueOutput()

proc sendTrailers*(st: AsyncH2Stream; trailers: seq[Header]) =
  ## Ends the body with a trailing HEADERS block.
  st.checkGone()
  if st.outEnded: raise newException(H2Error, "response already ended")
  st.conn.sess.sendTrailers(st.id, trailers)
  st.outEnded = true
  st.conn.queueOutput()

proc reset*(st: AsyncH2Stream; errorCode = CANCEL) =
  ## Resets the stream (RST_STREAM); it counts as closed from now on.
  let c = st.conn
  if not st.closed and not c.closed:
    try:
      c.sess.resetStream(st.id, errorCode)
      c.queueOutput()
    except CatchableError: discard
    st.closed = true
    st.errorCode = errorCode
    st.outEnded = true
    st.notify()

proc recvHeaders*(st: AsyncH2Stream): Future[seq[Header]] {.async.} =
  ## Client: the response HEADERS.
  while true:
    if st.blocks.len > 0: return st.blocks[0]
    st.checkGone()
    await st.changed()

proc recvTrailers*(st: AsyncH2Stream): Future[seq[Header]] {.async.} =
  ## Client: waits until the response has ended; the trailing HEADERS block,
  ## or empty for a trailers-only response.
  while true:
    if st.inEnded: return (if st.blocks.len > 1: st.blocks[^1] else: @[])
    st.checkGone()
    await st.changed()

proc cancel*(st: AsyncH2Stream) =
  ## Client: resets the stream with CANCEL.
  st.reset(CANCEL)

proc release*(st: AsyncH2Stream) =
  ## Client: forgets the stream; one still open is cancelled first.
  if st.released: return
  st.released = true
  let c = st.conn
  if not st.closed and not (st.inEnded and st.outEnded) and not c.closed:
    try:
      c.sess.resetStream(st.id, CANCEL)
      c.queueOutput()
    except CatchableError: discard
  st.closed = true
  st.notify()
  c.forget(st)

# ------------------------------------------------------------ client

proc connectEyeballs*(addrs: seq[TransportAddress]; timeoutMs: int;
                     staggerMs = eyeballDelayMs): Future[StreamTransport] {.async.} =
  ## Happy Eyeballs (RFC 8305): the first address is tried; if it has not answered within
  ## `staggerMs`, or has failed, the next is tried alongside it, and so on. The first to connect
  ## wins; the others are cancelled. Each attempt gets `timeoutMs` (negative: no limit beyond the
  ## system's). Raises the last error.
  var pending: seq[Future[StreamTransport]]
  var next = 0
  var winner: StreamTransport
  var lastErr: ref CatchableError
  try:
    while winner == nil and (next < addrs.len or pending.len > 0):
      var timer: Future[void]
      if next < addrs.len:
        let attempt = connect(addrs[next], flags = {SocketFlags.TcpNoDelay})
        pending.add(if timeoutMs >= 0: attempt.wait(timeoutMs.milliseconds) else: attempt)
        inc next
        if next < addrs.len: timer = sleepAsync(staggerMs.milliseconds)
      var watch: seq[FutureBase]
      for f in pending: watch.add FutureBase(f)
      if timer != nil: watch.add FutureBase(timer)
      discard await race(watch)
      if timer != nil and not timer.finished: await timer.cancelAndWait()
      var still: seq[Future[StreamTransport]]
      for f in pending:
        if not f.finished: still.add f
        elif f.completed:
          if winner == nil: winner = f.read
          else: await f.read.closeWait()       # two connected at once: keep one
        elif not f.cancelled: lastErr = f.error
      pending = still
  finally:
    for f in pending: await f.cancelAndWait()
  if winner == nil: raise lastErr
  return winner

const defaultConnectTimeoutMs* = 20_000
  ## How long `dial` waits for each address to accept the TCP connection.

proc dial*(host: string; port: Port; tls: TlsConfig = nil; serverName = "";
           keepalive = Keepalive(); connectTimeoutMs = defaultConnectTimeoutMs):
          Future[AsyncH2Conn] {.async.} =
  ## Without `tls`: HTTP/2 with prior knowledge (h2c). With it: TLS 1.2,
  ## ALPN h2, the server's certificate checked against `serverName` (default
  ## `host`). A failed handshake shows up as an error on the first stream.
  ## Each address gets `connectTimeoutMs` to accept the TCP connection (a
  ## negative value waits as long as the system does); past it the last
  ## address's `AsyncTimeoutError` is raised.
  let addrs = interleaveFamilies(resolveTAddress(stripBrackets(host), port),
                                 proc (a: TransportAddress): bool = a.family == AddressFamily.IPv6)
  if addrs.len == 0: raise newException(TransportError, "cannot resolve " & host)
  let transp = await connectEyeballs(addrs, connectTimeoutMs)
  setTcpKeepalive(cint(transp.fd), keepalive.tcpSecs)
  let c = newConn(transp, newClientSession(manualFlow = true), nil, keepalive)
  if tls != nil:
    c.tlsConf = tls
    try:
      c.tls = newClientTls(tls, if serverName.len > 0: serverName else: host)
    except TlsError as e:
      await transp.closeWait()
      raise e
  c.start()
  c

proc close*(c: AsyncH2Conn) {.async: (raises: []).} =
  ## Sends GOAWAY and closes the connection; open streams fail.
  await c.shutdown()

proc isClosed*(c: AsyncH2Conn): bool = c.closed

proc isUsable*(c: AsyncH2Conn): bool =
  ## Open, and the server has not sent GOAWAY: new streams may be started.
  not c.closed and not c.goawayReceived and c.sess.requestAllowed

proc activeStreams*(c: AsyncH2Conn): int = c.streams.len

proc failure*(c: AsyncH2Conn): string = c.failure

proc openStream*(c: AsyncH2Conn; headers: seq[Header]; timeoutMs = -1): AsyncH2Stream =
  ## Sends the request HEADERS; the body follows with `send`. With
  ## `timeoutMs >= 0` the stream is reset with CANCEL when the time is up.
  if c.closed:
    raise newException(H2StreamClosed, "connection closed: " & c.failure)
  if c.goawayReceived or not c.sess.requestAllowed:
    raise newException(H2StreamClosed, "connection is going away (GOAWAY)")
  let id = c.sess.submitRequest(headers)
  result = AsyncH2Stream(conn: c, id: id)
  c.streams[id] = result
  result.armDeadline(timeoutMs)
  c.queueOutput()

proc closeSend*(st: AsyncH2Stream): Future[void] =
  ## Ends the request body (half-close).
  st.send(@[], endStream = true)

# ------------------------------------------------------------ server

proc finishHandler(c: AsyncH2Conn; st: AsyncH2Stream) =
  c.activity = Moment.now()
  if not st.outEnded and not st.closed and not c.closed:
    try:
      c.sess.resetStream(st.id, INTERNAL_ERROR)
      c.queueOutput()
    except CatchableError: discard
  elif st.outEnded and not st.inEnded and not st.closed and not c.closed:
    # The response is complete but the client is still sending: tell it to
    # stop (as other gRPC servers do), or it waits for room that never comes.
    try:
      c.sess.resetStream(st.id, NO_ERROR)
      c.queueOutput()
    except CatchableError: discard
  st.closed = true
  st.notify()
  c.forget(st)
  if c.server != nil and c.server.stopping: c.closedEv.fire()   # wakes `stop`

proc runHandler(c: AsyncH2Conn; st: AsyncH2Stream) {.async: (raises: []).} =
  try:
    await c.server.handler(st, c.server.userData)
  except CancelledError:
    discard
  except CatchableError:
    discard
  c.finishHandler(st)

proc newAsyncStreamServer*(handler: AsyncStreamHandler; userData: pointer = nil;
                           port = Port(0); address = "127.0.0.1";
                           tls: TlsConfig = nil; keepalive = Keepalive();
                           pingPolicy = PingPolicy(); limits = Limits()): AsyncH2Server =
  ## Listens right away; connections are served by the running event loop.
  ## `limits` caps streams, connections and queued bytes (see `Limits`).
  let s = AsyncH2Server(handler: handler, userData: userData, tls: tls,
                        ka: keepalive, policy: pingPolicy, limits: limits)
  proc accept(server: StreamServer; transp: StreamTransport) {.async: (raises: []).} =
    if s.stopping:
      await transp.closeWait()
      return
    # Drop connections that are done.
    var keep: seq[AsyncH2Conn]
    for c in s.conns:
      if not (c.closed and c.streams.len == 0 and c.writerF.finished): keep.add c
    s.conns = keep
    if s.limits.maxConnections > 0 and s.conns.len >= s.limits.maxConnections:
      await transp.closeWait()         # over the limit: the peer sees a closed connection
      return
    var c: AsyncH2Conn
    try:
      c = newConn(transp, newServerSession(
        manualFlow = true, maxConcurrentStreams = s.limits.maxConcurrentStreams), s, s.ka)
      c.maxBuffer = s.limits.maxConnectionBuffer
      c.handshakeMs = s.limits.handshakeTimeoutMs
      c.maxAgeMs = s.limits.maxConnectionAgeMs
      c.maxIdleMs = s.limits.maxConnectionIdleMs
      c.graceMs = s.limits.maxConnectionAgeGraceMs
      c.policy = s.policy
      setTcpKeepalive(cint(transp.fd), s.ka.tcpSecs)
      if s.tls != nil: c.tls = newServerTls(s.tls)
    except CatchableError:
      await transp.closeWait()
      return
    s.conns.add c
    try: c.start()
    except CatchableError as e: c.fail(e.msg)
  s.srv = createStreamServer(initTAddress(address, port), accept,
                             {ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay})
  s.srv.start()
  s

proc port*(s: AsyncH2Server): Port = s.srv.localAddress().port

proc stop*(s: AsyncH2Server; graceMs = 0) {.async: (raises: []).} =
  ## Stops accepting and closes every connection. With `graceMs` > 0 clients
  ## get GOAWAY first and calls in progress may finish for up to that long;
  ## the handlers still running after that are cancelled. Stopping twice is
  ## harmless.
  if s.stopping: return
  s.stopping = true
  try: s.srv.stop()
  except CatchableError: discard
  await s.srv.closeWait()
  if graceMs > 0:
    var busy = false
    for c in s.conns:
      if not c.closed:
        try:
          c.sess.shutdownNotice()
          c.queueOutput()
        except CatchableError: discard
        busy = busy or c.streams.len > 0
    try:
      if busy: await sleepAsync(min(100, graceMs).milliseconds)
    except CancelledError: discard
    for c in s.conns:
      if not c.closed:
        try:
          c.sess.goAway()
          c.queueOutput()
        except CatchableError: discard
    let deadline = Moment.now() + graceMs.milliseconds
    for c in s.conns:
      while not c.closed and c.streams.len > 0 and Moment.now() < deadline:
        c.closedEv.clear()
        try: discard await withTimeout(c.closedEv.wait(), deadline - Moment.now())
        except CancelledError: break
  for c in s.conns:
    var running: seq[Task]
    for st in c.streams.values:
      if st.handler != nil and not st.handler.finished: running.add st.handler
    await c.shutdown()            # streams close; handlers get cancelled
    for f in running: await noCancel f
  s.conns = @[]
