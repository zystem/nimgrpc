## Blocking HTTP/2 over TCP, with streams.
##
## Per connection: a reader thread and a writer thread.
## * The reader reads the socket, feeds the session and files events under the
##   stream they belong to; a server starts a handler for every new request
##   stream as soon as its HEADERS arrive.
## * The writer sends what the session produced, in order. At most
##   `maxOutQueue` bytes wait for the socket; the rest stays in nghttp2, and a
##   sender waits while its stream has more than `maxStreamBuffer` unsent bytes.
##   A slow peer therefore slows the sender down instead of growing memory.
## * The connection lock is never held during socket I/O or while a handler
##   runs.
##
## Lock order: a connection lock may be held while taking the server's job
## lock, never the other way round.
##
## Threads get `ptr`, never `ref`; a `ref` stays with its single owner (the
## caller for a client, the server for accepted connections), so no reference
## count is touched from two threads.

import std/[locks, net, tables, deques, os, posix, atomics, options, nativesockets]
import ./session, ./common, ../tls/tls, ../cleanup, ../bytebuf

export session.Header, session.H2Error, net.Port, tls, common.H2Timeout,
       common.H2StreamClosed, common.Keepalive, common.PingPolicy, common.Limits

type
  StreamState = object
    blocks: seq[seq[Header]]   ## HEADERS blocks received
    inbuf: seq[byte]           ## body bytes received and not yet taken
    inEnded: bool              ## END_STREAM received
    outEnded: bool             ## we sent END_STREAM (or trailers)
    responded: bool            ## server: response HEADERS submitted
    closed: bool               ## the stream is closed
    errorCode: uint32          ## RST_STREAM / GOAWAY code, 0 on a clean close
    handled: bool              ## server: a handler owns the stream

  ConnObj = object
    sock: Socket
    sess: H2Session
    lock: Lock
    cond: Cond            ## every waiter on this connection, and the writer
    outQ: Deque[seq[byte]]
    wcond: Cond           ## the writer waits here, so a broadcast on `cond` does not wake it
    waiters: int          ## threads waiting on `cond`; nobody to wake means no broadcast
    outQBytes: int
    maxBuffer: int        ## `Limits.maxConnectionBuffer`; 0 for no limit
    streams: Table[int32, StreamState]
    server: ptr ServerObj ## nil for a client connection
    lastDispatched: int32 ## server: highest stream id handed to a handler
    pending: int          ## server: handlers still running for this connection
    closed: bool          ## no more reading or writing
    failure: string
    tls: TlsConn          ## nil for plaintext; used only under `lock`
    tlsConf: TlsConfig    ## client: keeps the config alive
    plainOut: seq[byte]   ## TLS: session output the engine has not taken yet
    plainPos: int         ## ... of which `plainOut[0 ..< plainPos]` is taken
    tlsIn: seq[byte]      ## TLS: records the engine has not taken yet
    tlsInPos: int         ## ... of which `tlsIn[0 ..< tlsInPos]` is taken
    ioRunning: int        ## reader/writer loops still running for this connection
    ka: Keepalive
    policy: PingPolicy
    lastReadNs: int64     ## monotonic time of the last bytes read
    pingOutstanding: bool
    pingSentNs: int64
    lastPingRecvNs: int64
    pingStrikes: int
    goawayReceived: bool  ## client: no new streams on this connection
  Conn* = ref ConnObj

  # ---- server side

  ServerStream* = object
    ## The handler's view of one request stream. Valid only inside the handler.
    conn: ptr ConnObj
    id*: int32
    headers*: seq[Header]   ## the request HEADERS
    deadline: Timespec
    hasDeadline: bool

  StreamHandler* = proc (st: var ServerStream; userData: pointer)
    {.nimcall, gcsafe, raises: [].}
    ## Runs on a worker thread from the moment the request HEADERS arrive.
    ## If it returns without ending the response, the stream is reset with
    ## INTERNAL_ERROR.

  Job = object
    conn: ptr ConnObj
    id: int32
    headers: seq[Header]

  WorkerThread = ref object
    th: Thread[ptr ServerObj]

  ServerObj = object
    listener: Socket
    handler: StreamHandler
    userData: pointer
    conns: seq[Conn]      ## owned by the accept thread until it is joined
    stopping: Atomic[bool]
    acceptor: Thread[ptr ServerObj]
    jobLock: Lock
    jobCond: Cond
    jobs: Deque[Job]
    idle: int             ## workers waiting for a job
    maxWorkers: int
    workersDone: bool
    workers: seq[WorkerThread]
    simple: RequestHandler   ## set when built from a whole-request handler
    simpleData: pointer
    tls: TlsConfig        ## nil for plaintext
    ka: Keepalive
    policy: PingPolicy
    limits: Limits
  Server* = ref ServerObj

  # ---- whole-request convenience API

  Request* = object
    headers*: seq[Header]
    body*: seq[byte]

  Reply* = object
    headers*: seq[Header]
    body*: seq[byte]
    trailers*: seq[Header]
    headersOnly*: bool      ## send `headers` with END_STREAM and nothing else

  RequestHandler* = proc (req: Request; userData: pointer): Reply
    {.nimcall, gcsafe, raises: [].}

  Response* = object
    headers*: seq[Header]   ## the first HEADERS block (:status ...)
    body*: seq[byte]
    trailers*: seq[Header]  ## the trailing HEADERS block; empty for trailers-only
    errorCode*: uint32      ## non-zero if the stream was reset by the peer

  # ---- client side

  ClientStream* = object
    ## One request stream opened by `openStream`. Use from one thread; the
    ## connection must outlive it. It holds a `ptr`, not a `ref`: streams live
    ## on many threads, and ORC reference counts are not atomic.
    conn: ptr ConnObj
    id*: int32
    deadline: Timespec
    hasDeadline: bool
    released: bool

proc `=destroy`(c: ConnObj) =
  `=destroy`(c.sock.addr[])
  deinitLock(c.lock.addr[])
  deinitCond(c.cond.addr[])
  deinitCond(c.wcond.addr[])
  `=destroy`(c.sess.addr[])
  `=destroy`(c.outQ.addr[])
  `=destroy`(c.streams.addr[])
  `=destroy`(c.failure.addr[])
  `=destroy`(c.tls.addr[])
  `=destroy`(c.tlsConf.addr[])
  `=destroy`(c.plainOut.addr[])
  `=destroy`(c.tlsIn.addr[])

proc `=copy`(dst: var ConnObj; src: ConnObj) {.error.}

proc `=destroy`(s: ServerObj) =
  `=destroy`(s.listener.addr[])
  `=destroy`(s.conns.addr[])
  deinitLock(s.jobLock.addr[])
  deinitCond(s.jobCond.addr[])
  `=destroy`(s.jobs.addr[])
  `=destroy`(s.workers.addr[])
  `=destroy`(s.tls.addr[])

proc `=copy`(dst: var ServerObj; src: ServerObj) {.error.}

converter toPtr(c: Conn): ptr ConnObj = c[].addr
  ## Internal procs take `ptr ConnObj`; the owner's `ref` converts.

# ------------------------------------------------------------ time

when defined(linux):
  const timedClock = CLOCK_MONOTONIC
    ## The clock of every deadline and timed wait: a step of the wall clock (NTP,
    ## a resumed virtual machine) must not shorten or stretch a timeout.
else:
  const timedClock = CLOCK_REALTIME    # no pthread_condattr_setclock here

proc initTimedCond(c: var Cond) =
  ## A condition variable whose timed waits count on `timedClock`.
  when defined(linux):
    var attr: Pthread_condattr
    discard pthread_condattr_init(attr.addr)
    discard pthread_condattr_setclock(attr.addr, timedClock)
    discard pthread_cond_init(cast[ptr Pthread_cond](c.addr), attr.addr)
    discard pthread_condattr_destroy(attr.addr)
  else:
    initCond(c)

proc deadlineIn*(ms: int): Timespec =
  ## An absolute deadline `ms` from now, on `timedClock`.
  discard clock_gettime(timedClock, result)
  let ns = result.tv_nsec.int + (ms mod 1000) * 1_000_000
  result.tv_sec = posix.Time(result.tv_sec.int + ms div 1000 + ns div 1_000_000_000)
  result.tv_nsec = ns mod 1_000_000_000

proc nowNs(): int64 =
  var t: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, t)
  t.tv_sec.int64 * 1_000_000_000 + t.tv_nsec.int64

proc waitUntil(c: var Cond; l: var Lock; deadline: Timespec): bool =
  ## False once the deadline has passed.
  pthread_cond_timedwait(cast[ptr Pthread_cond](c.addr),
                         cast[ptr Pthread_mutex](l.addr), deadline.unsafeAddr) != ETIMEDOUT

template threadBody(body: untyped) =
  ## Frees ORC's per-thread cycle-root buffer when the thread ends; without
  ## it every thread that ever dropped a cyclic object (an exception, say)
  ## leaks that buffer. Also drops the thread's current-exception slot, which
  ## a `raise` inside an `except` block can leave pointing at a dead exception.
  try:
    body
  finally:
    setCurrentException(nil)
    GC_fullCollect()

# ------------------------------------------------------------ connection internals
# Procs ending in `Locked` expect `c.lock` to be held.

proc wakeAll(c: ptr ConnObj) {.inline.} =
  if c.waiters > 0: broadcast(c.cond)

proc queueOutputLocked(c: ptr ConnObj) =
  ## Moves what the session produced (encrypted, with TLS) to the writer.
  if c.outQBytes >= maxOutQueue: return   # the writer pulls more as it drains
  if c.tls == nil:
    let o = c.sess.takeOutput()
    if o.len > 0:
      c.outQBytes += o.len
      c.outQ.addLast o
      signal(c.wcond)
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
        signal(c.wcond)
        progressed = true
      if not progressed or c.outQBytes >= maxOutQueue: break
  c.wakeAll()     # senders may now be under their buffer limit

proc failLocked(c: ptr ConnObj; why: string) =
  if not c.closed:
    c.closed = true
    if c.failure.len == 0: c.failure = why
    for st in c.streams.mvalues: st.closed = true
    signal(c.wcond)
    c.wakeAll()

proc waitLocked(c: ptr ConnObj; hasDeadline: bool; deadline: Timespec): bool =
  ## One wait on the connection condition; false if the deadline passed.
  inc c.waiters
  if hasDeadline: result = waitUntil(c.cond, c.lock, deadline)
  else:
    wait(c.cond, c.lock)
    result = true
  dec c.waiters

proc streamPtr(c: ptr ConnObj; id: int32): ptr StreamState =
  ## nil if the stream is unknown. Never raises.
  c.streams.withValue(id, v):
    return v
  nil

proc workerLoop(s: ptr ServerObj) {.thread.}

proc dispatchLocked(c: ptr ConnObj; id: int32; headers: seq[Header]) =
  let s = c.server
  c.streamPtr(id).handled = true
  c.lastDispatched = id
  inc c.pending
  acquire(s.jobLock)
  s.jobs.addLast Job(conn: c, id: id, headers: headers)
  if s.jobs.len > s.idle and s.workers.len < s.maxWorkers:
    let w = WorkerThread()
    s.workers.add w
    createThread(w.th, workerLoop, s)
  signal(s.jobCond)
  release(s.jobLock)

proc handleEventsLocked(c: ptr ConnObj) =
  let isServer = c.server != nil
  var events = c.sess.takeEvents()
  for ev in events.mitems:
    let known = ev.streamId in c.streams
    case ev.kind
    of evHeaders:
      if known:
        let st = c.streamPtr(ev.streamId)
        st.blocks.add ev.headers
        if ev.headersEndStream: st.inEnded = true
      elif isServer and ev.streamId > c.lastDispatched:
        c.streams[ev.streamId] = StreamState(blocks: @[ev.headers],
                                             inEnded: ev.headersEndStream)
        c.dispatchLocked(ev.streamId, ev.headers)
    of evData:
      if known:
        let st = c.streamPtr(ev.streamId)
        if st.inbuf.len == 0: st.inbuf = move ev.data     # no copy
        else: st.inbuf.appendBytes ev.data
        if ev.dataEndStream: st.inEnded = true
    of evStreamClosed:
      if known:
        let st = c.streamPtr(ev.streamId)
        st.closed = true
        st.errorCode = ev.errorCode
        if isServer and not st.handled: c.streams.del(ev.streamId)
    of evGoAway:
      c.goawayReceived = true
    of evPingAck:
      c.pingOutstanding = false
      signal(c.wcond)       # the writer schedules the next ping
    of evPing:
      if isServer and c.policy.minIntervalMs > 0:
        let now = nowNs()
        let idle = c.streams.len == 0
        if (idle and not c.policy.permitWithoutCalls) or
           (c.lastPingRecvNs != 0 and
            now - c.lastPingRecvNs < c.policy.minIntervalMs.int64 * 1_000_000):
          inc c.pingStrikes
        c.lastPingRecvNs = now
        if c.pingStrikes > 2:
          c.sess.goAway(11, "too_many_pings")   # ENHANCE_YOUR_CALM
          c.outQBytes = 0
          c.queueOutputLocked()
          c.failLocked("client sent too many pings")
    if ev.kind in {evHeaders, evData}: c.pingStrikes = 0
  c.wakeAll()

proc pumpTlsInLocked(c: ptr ConnObj) =
  ## Decrypts buffered records and feeds the plaintext to the session.
  var app: seq[byte]
  while true:
    let k = c.tls.pushRecords(c.tlsIn.toOpenArray(c.tlsInPos, c.tlsIn.high))
    if k > 0: c.tlsIn.consumed(c.tlsInPos, k)
    c.tls.pullApp(app)
    if k == 0:
      # The engine wants to send first (handshake), or is closed.
      let before = c.outQBytes
      c.queueOutputLocked()
      if c.outQBytes == before or c.tlsIn.len == 0: break
    elif c.tlsIn.len == 0:
      break
  c.tls.checkPeer()
  if app.len > 0: c.sess.recv(app)
  if c.tls.isClosed: raise newException(TlsError, c.tls.errorMessage)

proc ioDone(c: ptr ConnObj) =
  acquire(c.lock)
  dec c.ioRunning
  c.wakeAll()
  release(c.lock)

proc readerLoop(c: ptr ConnObj) =
  defer: c.ioDone()
  block:
    var buf = newSeq[byte](readChunk)
    while true:
      var n = 0
      try:
        n = c.sock.recv(buf[0].addr, buf.len)
      except CatchableError:
        n = -1
      acquire(c.lock)
      if n <= 0 or c.closed:
        c.failLocked(if n == 0: "connection closed by peer" else: "read error")
        release(c.lock)
        break
      c.lastReadNs = nowNs()
      try:
        if c.tls == nil:
          c.sess.recv(buf.toOpenArray(0, n - 1))
        else:
          c.tlsIn.appendBytes(buf[0].addr, n)
          c.pumpTlsInLocked()
        c.handleEventsLocked()
        c.queueOutputLocked()
        if not c.sess.wantRead() and not c.sess.wantWrite() and c.outQ.len == 0:
          c.failLocked("session finished")
      except CatchableError as e:
        # A connection error: nghttp2 has queued a GOAWAY; send it, then stop.
        try: c.queueOutputLocked()
        except CatchableError: discard
        c.failLocked(e.msg)
      let stop = c.closed
      release(c.lock)
      if stop: break

proc keepaliveLocked(c: ptr ConnObj): int =
  ## Sends a due PING or closes a connection whose PING went unanswered.
  ## Returns how long to wait (ms) before checking again, or -1 for no limit.
  if c.ka.timeMs <= 0 or c.closed: return -1
  let now = nowNs()
  let timeoutNs = (if c.ka.timeoutMs > 0: c.ka.timeoutMs else: 20_000).int64 * 1_000_000
  if c.pingOutstanding:
    let due = c.pingSentNs + timeoutNs
    if now >= due:
      c.failLocked("keepalive: no response to PING within " &
                   $(timeoutNs div 1_000_000) & " ms")
      return -1
    return int((due - now) div 1_000_000) + 1
  let due = c.lastReadNs + c.ka.timeMs.int64 * 1_000_000
  if now < due: return int((due - now) div 1_000_000) + 1
  let calls = c.streams.len > 0
  if calls or c.ka.withoutCalls or c.server != nil:
    try:
      c.sess.ping()
      c.pingOutstanding = true
      c.pingSentNs = now
      c.queueOutputLocked()
    except CatchableError as e:
      c.failLocked(e.msg)
      return -1
    return int(timeoutNs div 1_000_000) + 1
  c.ka.timeMs                       # idle and not allowed to ping: look again later

proc writerLoop(c: ptr ConnObj) =
  defer: c.ioDone()
  block:
    while true:
      acquire(c.lock)
      while c.outQ.len == 0 and not c.closed:
        let waitMs = c.keepaliveLocked()
        if c.outQ.len > 0 or c.closed: break
        if waitMs < 0: wait(c.wcond, c.lock)
        else: discard waitUntil(c.wcond, c.lock, deadlineIn(waitMs))
      if c.outQ.len == 0:           # closed and drained
        release(c.lock)
        break
      var chunk = c.outQ.popFirst()
      while c.outQ.len > 0 and chunk.len < 65536 and c.outQ.peekFirst.len <= 65536:
        chunk.appendBytes c.outQ.popFirst()     # one send for what is ready
      release(c.lock)
      var off = 0
      var ok = true
      while off < chunk.len:
        let k = try: c.sock.send(chunk[off].unsafeAddr, chunk.len - off)
                except CatchableError: -1
        if k <= 0:
          ok = false
          break
        off += k
      acquire(c.lock)
      c.outQBytes -= chunk.len
      if ok:
        try:
          if c.tls != nil and c.tlsIn.len > 0:
            c.pumpTlsInLocked()
            c.handleEventsLocked()
          c.queueOutputLocked()
        except CatchableError as e: c.failLocked(e.msg)
      else:
        c.failLocked("write error")
        c.outQ.clear()
        c.outQBytes = 0
      release(c.lock)
      if not ok: break
    # Unblocks the reader if the peer never closes.
    discard posix.shutdown(c.sock.getFd, SHUT_RDWR)

proc newConn(sock: Socket; sess: H2Session; server: ptr ServerObj): Conn =
  result = Conn(sock: sock, sess: sess, server: server, lastReadNs: nowNs())
  initLock(result.lock)
  initTimedCond(result.cond)
  initTimedCond(result.wcond)
  result.outQ = initDeque[seq[byte]]()

# ------------------------------------------------------------ I/O thread pool
#
# Reader and writer loops run on long-lived threads shared by every
# connection in the process, client or server. A thread per connection would
# be simpler, but Nim's allocator does not reclaim the heap of a thread that
# exits while memory it allocated is still alive elsewhere, which is exactly
# what a connection's reader leaves behind: the server grew by ~86 KiB per
# connection. Pooled threads never exit, so their heaps are reused.

type
  IoJob = object
    conn: ptr ConnObj
    reader: bool
  IoPool = object
    lock: Lock
    cond: Cond
    jobs: Deque[IoJob]
    idle: int
    threads: int

var ioPool: ptr IoPool
var ioPoolOnce: Atomic[int]     # 0: none, 1: being made, 2: ready

proc ioThread(p: ptr IoPool) {.thread.} =
  while true:
    acquire(p.lock)
    inc p.idle
    while p.jobs.len == 0:
      wait(p.cond, p.lock)
    dec p.idle
    let job = p.jobs.popFirst()
    release(p.lock)
    if job.reader: readerLoop(job.conn) else: writerLoop(job.conn)
    setCurrentException(nil)    # drop any exception the loop left behind

proc getIoPool(): ptr IoPool =
  if ioPoolOnce.load(moAcquire) == 2: return ioPool
  var expected = 0
  if ioPoolOnce.compareExchange(expected, 1):
    let p = createShared(IoPool)
    initLock(p.lock)
    initCond(p.cond)
    p.jobs = initDeque[IoJob]()
    ioPool = p
    ioPoolOnce.store(2, moRelease)
  else:
    while ioPoolOnce.load(moAcquire) != 2: cpuRelax()
  ioPool

proc ioSubmit(c: ptr ConnObj; reader: bool) =
  let p = getIoPool()
  acquire(p.lock)
  p.jobs.addLast IoJob(conn: c, reader: reader)
  if p.jobs.len > p.idle:
    # Threads live for the rest of the process; the Thread object must not
    # move, so it lives in shared memory.
    let th = createShared(Thread[ptr IoPool])
    createThread(th[], ioThread, p)
    inc p.threads
  signal(p.cond)
  release(p.lock)

proc start(c: Conn) =
  acquire(c.lock)
  c.queueOutputLocked()     # client preface / SETTINGS
  c.ioRunning = 2
  release(c.lock)
  ioSubmit(c, reader = true)
  ioSubmit(c, reader = false)

proc stopThreads(c: Conn) =
  ## Closes the connection (GOAWAY, TLS close_notify) and waits until its
  ## reader and writer loops have returned.
  acquire(c.lock)
  if not c.closed:
    try:
      c.sess.goAway()
      c.outQBytes = 0                  # GOAWAY must get out
      c.queueOutputLocked()
      if c.tls != nil and not c.tls.isClosed:
        c.tls.close()                  # close_notify
        c.queueOutputLocked()
    except CatchableError: discard
    c.closed = true
    for st in c.streams.mvalues: st.closed = true
    signal(c.wcond)
    c.wakeAll()
  inc c.waiters
  while c.ioRunning > 0:
    wait(c.cond, c.lock)               # the writer drains, then shuts the socket down
  dec c.waiters
  release(c.lock)

# ------------------------------------------------------------ shared stream I/O


proc closedError(c: ptr ConnObj; st: ptr StreamState; id: int32): ref H2StreamClosed =
  let why = if st != nil and st.errorCode != 0: "reset with error " & $st.errorCode
            elif c.failure.len > 0: c.failure
            else: "closed"
  newException(H2StreamClosed, "stream " & $id & ": " & why)

proc timeoutLocked(c: ptr ConnObj; id: int32): ref H2Timeout =
  if not c.closed and id in c.streams and not c.streamPtr(id).closed:
    try:
      c.sess.resetStream(id, CANCEL)
      c.queueOutputLocked()
    except CatchableError: discard
    c.streamPtr(id).closed = true
    c.streamPtr(id).errorCode = CANCEL
  newException(H2Timeout, "deadline exceeded on stream " & $id)

proc sendLocked(c: ptr ConnObj; id: int32; head, data: openArray[byte]; endStream: bool;
                hasDeadline: bool; deadline: Timespec) =
  ## Queues body bytes (`head` then `data`), waiting while the stream's unsent
  ## buffer is full.
  var off = 0
  let total = head.len + data.len
  while true:
    let s = c.streamPtr(id)          # re-read: the table may grow while we wait
    if s == nil or s.closed or c.closed: raise c.closedError(s, id)
    if s.outEnded: raise newException(H2Error, "stream " & $id & ": body already ended")
    var room = maxStreamBuffer - c.sess.buffered(id)
    if c.maxBuffer > 0: room = min(room, c.maxBuffer - c.sess.queuedBytes)
    let remaining = total - off
    if room > 0 or remaining == 0:
      let n = min(max(room, 0), remaining)
      let last = n == remaining
      if n > 0 or (last and endStream):
        let h0 = min(off, head.len)
        let h1 = min(off + n, head.len)
        let d0 = max(off - head.len, 0)
        let d1 = max(off + n - head.len, 0)
        c.sess.sendData(id, head.toOpenArray(h0, h1 - 1), data.toOpenArray(d0, d1 - 1),
                        endStream = last and endStream)
        off += n
        if last and endStream: s.outEnded = true
        c.queueOutputLocked()
      if last: return
    if not c.waitLocked(hasDeadline, deadline):
      raise c.timeoutLocked(id)

proc recvLocked(c: ptr ConnObj; id: int32; buf: var seq[byte];
                hasDeadline: bool; deadline: Timespec): bool =
  ## Moves received body bytes into `buf` (replacing its contents). False when
  ## the body has ended and everything has been taken.
  while true:
    if id notin c.streams:
      raise c.closedError(nil, id)
    let st = c.streamPtr(id)
    if st.inbuf.len > 0:
      buf = move st.inbuf
      st.inbuf = @[]
      return true
    if st.inEnded: return false
    if st.closed: raise c.closedError(st, id)
    if not c.waitLocked(hasDeadline, deadline):
      raise c.timeoutLocked(id)

# ------------------------------------------------------------ server streams

proc setTimeout*(st: var ServerStream; ms: int) =
  ## Bounds every later blocking call on this stream.
  if ms >= 0:
    st.deadline = deadlineIn(ms)
    st.hasDeadline = true

proc recvData*(st: var ServerStream; buf: var seq[byte]): bool =
  ## Blocks for the next part of the request body; false at its end.
  let c = st.conn
  acquire(c.lock)
  try:
    result = c.recvLocked(st.id, buf, st.hasDeadline, st.deadline)
  finally:
    release(c.lock)

proc isClosed*(st: ServerStream): bool =
  ## True once the stream is gone (for example the client cancelled).
  let c = st.conn
  acquire(c.lock)
  result = c.closed or st.id notin c.streams or c.streamPtr(st.id).closed
  release(c.lock)

proc deadlinePassed*(st: ServerStream): bool =
  ## True if the stream has a deadline and it is now past.
  if not st.hasDeadline: return false
  var now: Timespec
  discard clock_gettime(timedClock, now)
  now.tv_sec.int > st.deadline.tv_sec.int or
    (now.tv_sec.int == st.deadline.tv_sec.int and now.tv_nsec >= st.deadline.tv_nsec)

proc remainingMs*(st: ServerStream): int =
  ## Milliseconds until the deadline (at least 0), or -1 without one.
  if not st.hasDeadline: return -1
  var now: Timespec
  discard clock_gettime(timedClock, now)
  let ms = (st.deadline.tv_sec.int - now.tv_sec.int) * 1000 +
           (st.deadline.tv_nsec.int - now.tv_nsec.int) div 1_000_000
  max(ms, 0)

proc waitClosed*(st: ServerStream; ms: int): bool =
  ## Waits up to `ms` (or until the deadline, if sooner) for the stream to
  ## close. True if it closed (cancelled by the client, connection gone,
  ## server stopping); false if the time ran out first. Wakes up as soon as
  ## the stream closes rather than at the end of `ms`.
  let c = st.conn
  var limit = ms
  let left = st.remainingMs
  if left >= 0 and left < limit: limit = left
  let until = deadlineIn(max(limit, 0))
  acquire(c.lock)
  while true:
    if c.closed or st.id notin c.streams or c.streamPtr(st.id).closed:
      result = true
      break
    inc c.waiters
    let woke = waitUntil(c.cond, c.lock, until)
    dec c.waiters
    if not woke:
      result = c.closed or st.id notin c.streams or c.streamPtr(st.id).closed
      break
  release(c.lock)

proc sendHeaders*(st: var ServerStream; headers: openArray[Header]; endStream = false) =
  ## The response HEADERS. With `endStream` nothing else follows
  ## (a gRPC trailers-only response).
  let c = st.conn
  acquire(c.lock)
  try:
    if st.id notin c.streams or c.streamPtr(st.id).closed or c.closed:
      raise c.closedError(c.streamPtr(st.id), st.id)
    let s = c.streamPtr(st.id)
    if s.responded: raise newException(H2Error, "response HEADERS already sent")
    c.sess.submitResponse(st.id, headers, endStream)
    s.responded = true
    if endStream: s.outEnded = true
    c.queueOutputLocked()
  finally:
    release(c.lock)

proc sendData*(st: var ServerStream; data: openArray[byte]; endStream = false;
               head: openArray[byte] = []) =
  ## Queues `head` then `data` as body bytes.
  let c = st.conn
  acquire(c.lock)
  try:
    c.sendLocked(st.id, head, data, endStream, st.hasDeadline, st.deadline)
  finally:
    release(c.lock)

proc sendTrailers*(st: var ServerStream; trailers: openArray[Header]) =
  ## Ends the response with a trailing HEADERS block.
  let c = st.conn
  acquire(c.lock)
  try:
    if st.id notin c.streams or c.streamPtr(st.id).closed or c.closed:
      raise c.closedError(c.streamPtr(st.id), st.id)
    let s = c.streamPtr(st.id)
    if s.outEnded: raise newException(H2Error, "response already ended")
    c.sess.sendTrailers(st.id, trailers)
    s.outEnded = true
    c.queueOutputLocked()
  finally:
    release(c.lock)

proc reset*(st: var ServerStream; errorCode = CANCEL) =
  let c = st.conn
  acquire(c.lock)
  if st.id in c.streams and not c.streamPtr(st.id).closed and not c.closed:
    try:
      c.sess.resetStream(st.id, errorCode)
      c.queueOutputLocked()
    except CatchableError: discard
    c.streamPtr(st.id).outEnded = true
  release(c.lock)

proc finishHandlerLocked(c: ptr ConnObj; id: int32) =
  ## The handler for `id` has returned.
  if id in c.streams:
    let s = c.streamPtr(id)
    if not s.outEnded and not s.closed and not c.closed:
      try:
        c.sess.resetStream(id, INTERNAL_ERROR)
        c.queueOutputLocked()
      except CatchableError: discard
    c.streams.del(id)      # a late close event finds nothing and is ignored
  dec c.pending
  c.wakeAll()

proc workerLoop(s: ptr ServerObj) {.thread.} =
  threadBody:
    while true:
      acquire(s.jobLock)
      inc s.idle
      while s.jobs.len == 0 and not s.workersDone:
        wait(s.jobCond, s.jobLock)
      dec s.idle
      if s.jobs.len == 0:
        release(s.jobLock)
        break
      var job = s.jobs.popFirst()
      release(s.jobLock)
      var st = ServerStream(conn: job.conn, id: job.id, headers: move job.headers)
      s.handler(st, s.userData)
      let c = job.conn
      acquire(c.lock)
      c.finishHandlerLocked(job.id)
      release(c.lock)

# ------------------------------------------------------------ whole-request server API

proc readRequest*(st: var ServerStream): Request =
  ## Reads the whole request body.
  result.headers = st.headers
  var chunk: seq[byte]
  while st.recvData(chunk): result.body.appendBytes chunk

proc respond*(st: var ServerStream; rep: Reply) =
  if rep.headersOnly:
    st.sendHeaders(rep.headers, endStream = true)
  else:
    st.sendHeaders(rep.headers)
    st.sendData(rep.body, endStream = rep.trailers.len == 0)
    if rep.trailers.len > 0: st.sendTrailers(rep.trailers)

proc simpleTrampoline(st: var ServerStream; userData: pointer)
    {.nimcall, gcsafe, raises: [].} =
  let s = cast[ptr ServerObj](userData)
  try:
    let req = st.readRequest()
    st.respond(s.simple(req, s.simpleData))
  except CatchableError:
    discard          # the stream is gone; the worker resets it if needed

# ------------------------------------------------------------ server

proc connectAny(host: string; port: Port; timeoutMs: int): Socket =
  ## The first address of `host` (IPv4 or IPv6, in the order the resolver gives) that accepts
  ## the connection, each given `timeoutMs`. Raises the last error.
  let ais = getAddrInfo(stripBrackets(host), port, Domain.AF_UNSPEC, SockType.SOCK_STREAM,
                        Protocol.IPPROTO_TCP)
  var lastErr: ref CatchableError
  var ai = ais
  try:
    while ai != nil:
      let dom = toKnownDomain(ai.ai_family)
      if dom.isSome:
        let sock = newSocket(dom.get, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP,
                             buffered = false)
        try:
          sock.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
          let numeric = getAddrString(ai.ai_addr)
          if timeoutMs >= 0: sock.connect(numeric, port, timeoutMs)
          else: sock.connect(numeric, port)
          return sock
        except CatchableError as e:
          sock.close()      # a socket that never connected must not keep its descriptor
          lastErr = e
      ai = ai.ai_next
  finally:
    freeAddrInfo(ais)
  if lastErr != nil: raise lastErr
  raise newException(OSError, "no usable address for " & host)

proc newStreamServer*(handler: StreamHandler; userData: pointer = nil;
                      port = Port(0); address = "127.0.0.1";
                      maxWorkers = 256; tls: TlsConfig = nil;
                      keepalive = Keepalive(); pingPolicy = PingPolicy();
                      limits = Limits()): Server =
  ## Every request stream gets a worker thread for as long as its handler
  ## runs; the pool grows on demand up to `maxWorkers` threads. With `tls`
  ## connections must speak TLS 1.2 with ALPN h2. `limits` caps streams,
  ## connections and queued bytes (see `Limits`).
  result = Server(handler: handler, userData: userData, maxWorkers: maxWorkers,
                  tls: tls, ka: keepalive, policy: pingPolicy, limits: limits)
  initLock(result.jobLock)
  initCond(result.jobCond)
  result.jobs = initDeque[Job]()
  let bindHost = stripBrackets(address)
  if isIpv6Literal(bindHost):
    result.listener = newSocket(Domain.AF_INET6, SockType.SOCK_STREAM,
                                Protocol.IPPROTO_TCP, buffered = false)
    # "::" takes IPv4 clients too (dual-stack), whatever the system's default is
    var v6only: cint = 0
    discard setsockopt(result.listener.getFd, IPPROTO_IPV6.cint, IPV6_V6ONLY.cint,
                       v6only.addr, sizeof(cint).SockLen)
  else:
    result.listener = newSocket(buffered = false)
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(port, bindHost)
  result.listener.listen()

proc newServer*(handler: RequestHandler; userData: pointer = nil; port = Port(0);
                address = "127.0.0.1"; maxWorkers = 256; tls: TlsConfig = nil): Server =
  ## A server whose handler sees the whole request and returns the whole reply.
  result = newStreamServer(simpleTrampoline, nil, port, address, maxWorkers, tls)
  result.userData = result[].addr
  result.simple = handler
  result.simpleData = userData

proc port*(s: Server): Port = s.listener.getLocalAddr()[1]

proc reap(s: ptr ServerObj) =
  ## Drops connections that are closed and have no handler running.
  var keep: seq[Conn]
  for c in s.conns:
    acquire(c.lock)
    let done = c.closed and c.pending == 0 and c.ioRunning == 0
    release(c.lock)
    if done:
      c.stopThreads()
      c.sock.close()
    else:
      keep.add c
  s.conns = keep

proc acceptLoop(s: ptr ServerObj) {.thread.} =
  threadBody:
    while true:
      var client: Socket
      try:
        s.listener.accept(client)
      except CatchableError:
        if s.stopping.load: break
        sleep(10)
        continue
      if s.stopping.load:
        client.close()
        break
      client.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
      s.reap()
      if s.limits.maxConnections > 0 and s.conns.len >= s.limits.maxConnections:
        client.close()                 # over the limit: the peer sees a closed connection
        continue
      let c = newConn(client, newServerSession(
        maxConcurrentStreams = s.limits.maxConcurrentStreams), s)
      c.maxBuffer = s.limits.maxConnectionBuffer
      c.ka = s.ka
      c.policy = s.policy
      if s.tls != nil:
        try:
          c.tls = newServerTls(s.tls)
        except TlsError:
          client.close()
          continue
      c.start()
      s.conns.add c

proc start*(s: Server) =
  ## Accepts connections on a background thread.
  createThread(s.acceptor, acceptLoop, s[].addr)

proc stop*(s: Server; graceMs = 0) =
  ## Stops accepting connections and closes the open ones. With `graceMs`
  ## > 0 the shutdown is graceful: clients get GOAWAY (first a notice, then
  ## the final one), calls already started may finish for up to `graceMs`,
  ## and only then are connections closed and the remaining calls cancelled.
  s.stopping.store(true)
  discard posix.shutdown(s.listener.getFd, SHUT_RDWR)
  joinThread(s.acceptor)
  s.listener.close()
  if graceMs > 0 and s.conns.len > 0:
    var busy = false
    for c in s.conns:
      acquire(c.lock)
      if not c.closed:
        try:
          c.sess.shutdownNotice()
          c.queueOutputLocked()
        except CatchableError: discard
        busy = busy or c.streams.len > 0
      release(c.lock)
    # The notice reaches clients that may be opening streams right now; the
    # final GOAWAY, about a round trip later, fixes the last stream served.
    if busy: sleep(min(100, graceMs))
    for c in s.conns:
      acquire(c.lock)
      if not c.closed:
        try:
          c.sess.goAway()
          c.queueOutputLocked()
        except CatchableError: discard
      release(c.lock)
    let deadline = nowNs() + graceMs.int64 * 1_000_000
    for c in s.conns:
      acquire(c.lock)
      while not c.closed and (c.pending > 0 or c.streams.len > 0) and nowNs() < deadline:
        inc c.waiters
        discard waitUntil(c.cond, c.lock, deadlineIn(
          max(1, int((deadline - nowNs()) div 1_000_000))))
        dec c.waiters
      release(c.lock)
  for c in s.conns: c.stopThreads()   # streams close; handlers see it and return
  acquire(s.jobLock)
  s.workersDone = true                # workers drain the queue, then exit
  broadcast(s.jobCond)
  release(s.jobLock)
  for w in s.workers: joinThread(w.th)
  for c in s.conns: c.sock.close()    # no worker can reach a connection now
  s.conns = @[]

# ------------------------------------------------------------ client

proc close*(c: Conn) =
  ## Sends GOAWAY, stops both threads and closes the socket.
  c.stopThreads()
  c.sock.close()

proc isClosed*(c: Conn): bool =
  acquire(c.lock)
  result = c.closed
  release(c.lock)

proc isUsable*(c: Conn): bool =
  ## Open, and the server has not sent GOAWAY: new streams may be started.
  acquire(c.lock)
  result = not c.closed and not c.goawayReceived and c.sess.requestAllowed
  release(c.lock)

proc activeStreams*(c: Conn): int =
  acquire(c.lock)
  result = c.streams.len
  release(c.lock)

const defaultConnectTimeoutMs* = 20_000
  ## How long `dial` waits for each address to accept the TCP connection.

proc dial*(host: string; port: Port; tls: TlsConfig = nil; serverName = "";
           keepalive = Keepalive(); connectTimeoutMs = defaultConnectTimeoutMs): Conn =
  ## Without `tls`: HTTP/2 with prior knowledge (h2c). With it: TLS 1.2,
  ## ALPN h2, the server's certificate checked against `serverName` (default:
  ## `host`; DNS names only). A failed handshake shows up as an error on the
  ## first stream. Each address the name resolves to gets `connectTimeoutMs`
  ## to accept the TCP connection (a negative value waits as long as the
  ## system does); past it `TimeoutError` is raised. Resolving the name is not
  ## covered: it blocks for as long as the resolver takes.
  let sock = connectAny(host, port, connectTimeoutMs)
  result = newConn(sock, newClientSession(), nil)
  result.ka = keepalive
  if tls != nil:
    result.tlsConf = tls
    result.tls = newClientTls(tls, if serverName.len > 0: serverName else: host)
  result.start()

proc openStream*(c: Conn; headers: openArray[Header]; timeoutMs = -1): ClientStream =
  ## Sends the request HEADERS; the body follows with `send`. With
  ## `timeoutMs >= 0` every blocking call on the stream shares that deadline.
  result = ClientStream(conn: c[].addr)
  if timeoutMs >= 0:
    result.deadline = deadlineIn(timeoutMs)
    result.hasDeadline = true
  acquire(c.lock)
  try:
    if c.closed:
      raise newException(H2StreamClosed, "connection closed: " & c.failure)
    if c.goawayReceived or not c.sess.requestAllowed:
      raise newException(H2StreamClosed, "connection is going away (GOAWAY)")
    result.id = c.sess.submitRequest(headers)
    c.streams[result.id] = StreamState()
    c.queueOutputLocked()
  finally:
    release(c.lock)

proc send*(st: var ClientStream; data: openArray[byte]; endStream = false;
           head: openArray[byte] = []) =
  ## Queues `head` then `data` as body bytes.
  let c = st.conn
  acquire(c.lock)
  try:
    c.sendLocked(st.id, head, data, endStream, st.hasDeadline, st.deadline)
  finally:
    release(c.lock)

proc closeSend*(st: var ClientStream) =
  ## Ends the request body (half-close).
  st.send([], endStream = true)

proc recvHeaders*(st: var ClientStream): seq[Header] =
  ## Blocks for the response HEADERS.
  let c = st.conn
  acquire(c.lock)
  try:
    while true:
      if st.id notin c.streams: raise c.closedError(nil, st.id)
      let s = c.streamPtr(st.id)
      if s.blocks.len > 0: return s.blocks[0]
      if s.closed: raise c.closedError(s, st.id)
      if not c.waitLocked(st.hasDeadline, st.deadline):
        raise c.timeoutLocked(st.id)
  finally:
    release(c.lock)

proc recvData*(st: var ClientStream; buf: var seq[byte]): bool =
  ## Blocks for the next part of the response body; false at its end.
  let c = st.conn
  acquire(c.lock)
  try:
    result = c.recvLocked(st.id, buf, st.hasDeadline, st.deadline)
  finally:
    release(c.lock)

proc recvTrailers*(st: var ClientStream): seq[Header] =
  ## Blocks until the response has ended; the trailing HEADERS block, or empty
  ## for a trailers-only response. Raises H2StreamClosed if the stream was
  ## reset first.
  let c = st.conn
  acquire(c.lock)
  try:
    while true:
      let s = c.streamPtr(st.id)
      if s == nil: raise c.closedError(nil, st.id)
      if s.inEnded: return (if s.blocks.len > 1: s.blocks[^1] else: @[])
      if s.closed: raise c.closedError(s, st.id)
      if not c.waitLocked(st.hasDeadline, st.deadline):
        raise c.timeoutLocked(st.id)
  finally:
    release(c.lock)

proc errorCode*(st: ClientStream): uint32 =
  ## The RST_STREAM / GOAWAY code the stream ended with, 0 if none.
  let c = st.conn
  acquire(c.lock)
  let s = c.streamPtr(st.id)
  result = if s != nil: s.errorCode else: 0
  release(c.lock)

proc deadlinePassed*(st: ClientStream): bool =
  ## True if the stream has a deadline and it is now past.
  if not st.hasDeadline: return false
  var now: Timespec
  discard clock_gettime(timedClock, now)
  now.tv_sec.int > st.deadline.tv_sec.int or
    (now.tv_sec.int == st.deadline.tv_sec.int and now.tv_nsec >= st.deadline.tv_nsec)

proc peerEnded*(st: ClientStream): bool =
  ## True once the server has ended its side (END_STREAM received).
  let c = st.conn
  acquire(c.lock)
  let s = c.streamPtr(st.id)
  result = s != nil and s.inEnded
  release(c.lock)

proc cancel*(st: var ClientStream) =
  ## Resets the stream with CANCEL.
  let c = st.conn
  acquire(c.lock)
  if st.id in c.streams and not c.streamPtr(st.id).closed and not c.closed:
    try:
      c.sess.resetStream(st.id, CANCEL)
      c.queueOutputLocked()
    except CatchableError: discard
    c.streamPtr(st.id).closed = true
    c.streamPtr(st.id).errorCode = CANCEL
  release(c.lock)

proc release*(st: var ClientStream) =
  ## Forgets the stream. A stream still open is cancelled first.
  if st.released: return
  st.released = true
  let c = st.conn
  acquire(c.lock)
  if st.id in c.streams:
    let s = c.streamPtr(st.id)
    if not s.closed and not (s.inEnded and s.outEnded) and not c.closed:
      try:
        c.sess.resetStream(st.id, CANCEL)
        c.queueOutputLocked()
      except CatchableError: discard
    c.streams.del(st.id)
  release(c.lock)

proc request*(c: Conn; headers: openArray[Header]; body: openArray[byte] = [];
              timeoutMs = -1): Response =
  ## Sends a whole request and blocks for the whole response. A stream reset
  ## by the peer is returned with `errorCode` set; a closed connection raises
  ## H2StreamClosed, a passed deadline H2Timeout.
  var st = c.openStream(headers, timeoutMs)
  var failure: ref H2StreamClosed
  var res: Response
  withCleanup:
    try:
      st.send(body, endStream = true)
      res.headers = st.recvHeaders()
      var chunk: seq[byte]
      while st.recvData(chunk): res.body.appendBytes chunk
      res.trailers = st.recvTrailers()
    except H2StreamClosed as e:
      acquire(c.lock)
      let s = c.streamPtr(st.id)
      let resetByPeer = s != nil and s.errorCode != 0 and not c.closed
      if resetByPeer:
        res.errorCode = s.errorCode
        if res.headers.len == 0 and s.blocks.len > 0: res.headers = s.blocks[0]
      release(c.lock)
      if not resetByPeer: failure = e
  do:
    st.release()
  if failure != nil: raise failure
  res
