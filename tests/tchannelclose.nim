## Closing a channel while a call of another thread waits on it: the call fails, `close` returns, and nothing the call still uses is freed under it. The failing call used to touch the
## freed connection (a use after free that AddressSanitizer reports: `nimble asan`; a plain run ends in a hang or a crash now and then).

import std/[unittest, atomics, os]
import nimgrpc

proc blockForever(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var msg: seq[byte]
  while call.recv(msg): discard         # it never sends: the client's `recv` waits for the headers of the reply

type WaitArgs = tuple[call: ptr ClientCall, code: ptr Atomic[int], started: ptr Atomic[bool]]

proc waiter(a: WaitArgs) {.thread.} =
  {.cast(gcsafe).}:
    var msg: seq[byte]
    a.started[].store(true)
    try:
      try:
        discard a.call[].recv(msg)
        a.code[].store(0)
      except GrpcError as e:
        a.code[].store(int(e.code))
      except CatchableError:
        a.code[].store(-1)
    finally:
      # what the threads of the library do (docs/nim-issue-finally.md): a thread that caught an exception and ends leaves its cycle roots
      setCurrentException(nil)
      GC_fullCollect()

proc startServer(): GrpcServer =
  result = newGrpcServer()
  result.addStreaming("/t.T/Block", blockForever)
  result.start()

proc waitOn(ch: GrpcChannel; call: var ClientCall; code: var Atomic[int]; started: var Atomic[bool]; th: var Thread[WaitArgs]) =
  code.store(-2)
  started.store(false)
  createThread(th, waiter, (addr call, addr code, addr started))
  while not started.load: sleep 1
  sleep 20                              # the waiter is inside `recv` now (it has nothing to receive)

suite "closing a channel while a call waits on it":
  test "the waiting call fails and close returns, many times":
    let srv = startServer()
    for i in 0 ..< 40:
      let ch = dial("127.0.0.1", srv.port)
      var call = ch.newCall("/t.T/Block", timeoutMs = 20000)
      call.send([1'u8])
      var code: Atomic[int]
      var started: Atomic[bool]
      var th: Thread[WaitArgs]
      ch.waitOn(call, code, started, th)
      ch.close()
      joinThread(th)
      check code.load notin [-2, 0]     # it ended with an error, and it ended
    srv.stop()

  test "shutdown wakes the waiting call and frees nothing: the thread is joined, then the channel closed (also twice)":
    let srv = startServer()
    for i in 0 ..< 40:
      let ch = dial("127.0.0.1", srv.port)
      var call = ch.newCall("/t.T/Block", timeoutMs = 20000)
      call.send([1'u8])
      var code: Atomic[int]
      var started: Atomic[bool]
      var th: Thread[WaitArgs]
      ch.waitOn(call, code, started, th)
      ch.shutdown()
      joinThread(th)
      check code.load notin [-2, 0]
      ch.shutdown()                      # again: nothing happens
      var refused = false
      try: discard ch.newCall("/t.T/Block")
      except GrpcError: refused = true   # a closed channel takes no new calls
      check refused
      call.close()                       # the stream of the call, while the channel is still there
      ch.close()
    srv.stop()
