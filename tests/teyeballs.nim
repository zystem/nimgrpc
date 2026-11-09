## Happy Eyeballs (RFC 8305): the order of addresses, and a dead address that does not hold up
## a live one, on the blocking and the chronos adapter.

import std/[unittest, net, nativesockets, monotimes, times]
import pkg/chronos
import nimgrpc/h2/[common, blocking, async]

proc isV6(s: string): bool = ':' in s

suite "the order of addresses":
  test "the resolver's first family goes first, then the families alternate":
    check interleaveFamilies(["::1", "::2", "::3", "1.1.1.1", "2.2.2.2"], isV6) ==
      @["::1", "1.1.1.1", "::2", "2.2.2.2", "::3"]
    check interleaveFamilies(["1.1.1.1", "::1", "2.2.2.2"], isV6) ==
      @["1.1.1.1", "::1", "2.2.2.2"]
    check interleaveFamilies(["1.1.1.1", "2.2.2.2"], isV6) == @["1.1.1.1", "2.2.2.2"]
    check interleaveFamilies(newSeq[string](), isV6).len == 0

type Blackhole = object
  listener: Socket
  fillers: seq[Socket]

proc newBlackhole(): Blackhole =
  ## A listener nobody accepts from, with its queue full: connecting to it neither succeeds nor
  ## fails, as to an address that drops packets.
  result.listener = newSocket(buffered = false)
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(Port(0), "127.0.0.1")
  result.listener.listen(1)
  for i in 0 ..< 6:
    let c = newSocket(buffered = false)
    try: c.connect("127.0.0.1", result.listener.getLocalAddr[1], 100)
    except CatchableError: discard
    result.fillers.add c

proc port(b: Blackhole): Port = b.listener.getLocalAddr[1]

proc close(b: Blackhole) =
  for c in b.fillers: c.close()
  b.listener.close()

proc liveListener(): Socket =
  result = newSocket(buffered = false)
  result.setSockOpt(OptReuseAddr, true)
  result.bindAddr(Port(0), "127.0.0.1")
  result.listen()

suite "the blocking connect":
  test "a live address after a dead one is reached after the stagger, not the timeout":
    let dead = newBlackhole()
    let live = liveListener()
    let targets = targetsOf("127.0.0.1", dead.port) & targetsOf("127.0.0.1", live.getLocalAddr[1])
    let t0 = getMonoTime()
    let s = connectTargets(targets, "test", timeoutMs = 5000, staggerMs = 100)
    let ms = (getMonoTime() - t0).inMilliseconds
    check s.getPeerAddr[1] == live.getLocalAddr[1]
    check ms >= 80
    check ms < 2000
    s.close()
    live.close()
    dead.close()

  test "a refused address passes to the next at once":
    let live = liveListener()
    let gone = liveListener()
    let gonePort = gone.getLocalAddr[1]
    gone.close()                     # nothing listens there any more
    let targets = targetsOf("127.0.0.1", gonePort) & targetsOf("127.0.0.1", live.getLocalAddr[1])
    let t0 = getMonoTime()
    let s = connectTargets(targets, "test", timeoutMs = 5000, staggerMs = 3000)
    check (getMonoTime() - t0).inMilliseconds < 1500
    check s.getPeerAddr[1] == live.getLocalAddr[1]
    s.close()
    live.close()

  test "only dead addresses: a timeout; only refused ones: an OS error":
    let dead = newBlackhole()
    var timedOut = false
    try: discard connectTargets(targetsOf("127.0.0.1", dead.port), "test", 300, 100)
    except TimeoutError: timedOut = true
    check timedOut
    dead.close()
    let gone = liveListener()
    let gonePort = gone.getLocalAddr[1]
    gone.close()
    var failed = false
    try: discard connectTargets(targetsOf("127.0.0.1", gonePort), "test", 300, 100)
    except OSError: failed = true
    check failed

suite "the chronos connect":
  test "a live address after a dead one is reached after the stagger":
    let dead = newBlackhole()
    let live = liveListener()
    let livePort = live.getLocalAddr[1]
    proc run(deadPort, livePort: int): Future[(int, int64)] {.async.} =
      let addrs = @[initTAddress("127.0.0.1", deadPort), initTAddress("127.0.0.1", livePort)]
      let t0 = Moment.now()
      let t = await connectEyeballs(addrs, 5000, staggerMs = 100)
      let ms = (Moment.now() - t0).milliseconds
      let peer = int(t.remoteAddress.port)
      await t.closeWait()
      return (peer, ms)
    let (peer, ms) = waitFor run(dead.port.int, livePort.int)
    check peer == livePort.int
    check ms >= 80
    check ms < 2000
    live.close()
    dead.close()

  test "all dead: the error of the last attempt, nothing left behind":
    let dead = newBlackhole()
    proc run(deadPort: int): Future[bool] {.async.} =
      try:
        discard await connectEyeballs(@[initTAddress("127.0.0.1", deadPort)], 300, 100)
        return false
      except CatchableError: return true
    check waitFor run(dead.port.int)
    dead.close()
