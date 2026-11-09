## Transparent retry of a unary call the server refused (REFUSED_STREAM), blocking and chronos.

import std/[unittest, atomics]
import pkg/chronos
import nimgrpc
import nimgrpc/h2/blocking as h2
import nimgrpc/wire
import nimgrpc/asyncclient as ac
from nimgrpc/client as bc import nil

var seen, refuseFirst: Atomic[int]
var failWith: Atomic[int]        ## 0: answer, 1: INTERNAL status after the refusals

proc flaky(st: var ServerStream; ud: pointer) {.nimcall, gcsafe, raises: [].} =
  ## Refuses the first `refuseFirst` streams, then answers "ok" (or INTERNAL).
  try:
    let n = seen.fetchAdd(1) + 1
    discard st.readRequest()
    if n <= refuseFirst.load:
      st.reset(7)
      return
    let msg = @[byte('o'), byte('k')]
    if failWith.load == 1:
      st.respond(Reply(headers: @[(":status", "200"), ("content-type", "application/grpc")],
                       headersOnly: true))
      return
    st.respond(Reply(headers: @[(":status", "200"), ("content-type", "application/grpc")],
                     body: @(frameHeader(msg.len)) & msg,
                     trailers: @[("grpc-status", "0")]))
  except CatchableError: discard

proc start(refuse: int): Server =
  seen.store(0)
  refuseFirst.store(refuse)
  failWith.store(0)
  result = newStreamServer(flaky, nil)
  result.start()

suite "a refused call is sent again":
  test "blocking: refused twice, answered the third time":
    let s = start(2)
    let ch = bc.dial("127.0.0.1", s.port.int)
    let r = bc.unaryCall(ch, "/t.T/M", @[byte 1])
    check r.message == @[byte('o'), byte('k')]
    check seen.load == 3
    ch.close()
    s.stop()

  test "blocking: refused past the retries, the error says unprocessed":
    let s = start(100)
    let ch = bc.dial("127.0.0.1", s.port.int)
    var code = scOk
    var unprocessed = false
    try: discard bc.unaryCall(ch, "/t.T/M", @[byte 1])
    except GrpcError as e:
      code = e.code
      unprocessed = e.unprocessed
    check code == scUnavailable
    check unprocessed
    check seen.load == 1 + bc.refusedRetries
    ch.close()
    s.stop()

  test "blocking: the deadline bounds the retries":
    let s = start(100)
    let ch = bc.dial("127.0.0.1", s.port.int)
    var failed = false
    try: discard bc.unaryCall(ch, "/t.T/M", @[byte 1], timeoutMs = 30)
    except GrpcError: failed = true
    check failed
    check seen.load <= 1 + bc.refusedRetries
    ch.close()
    s.stop()

  test "blocking: a call that was not refused is not repeated":
    let s = start(0)
    failWith.store(1)             # trailers-only response without grpc-status: INTERNAL
    let ch = bc.dial("127.0.0.1", s.port.int)
    var code = scOk
    var unprocessed = true
    try: discard bc.unaryCall(ch, "/t.T/M", @[byte 1])
    except GrpcError as e:
      code = e.code
      unprocessed = e.unprocessed
    check code == scInternal
    check not unprocessed
    check seen.load == 1
    ch.close()
    s.stop()

  test "chronos: refused twice, answered the third time":
    let s = start(2)
    proc run(port: int): Future[seq[byte]] {.async.} =
      let ch = await ac.dialAsync("127.0.0.1", port)
      let r = await ac.unaryCall(ch, "/t.T/M", @[byte 1])
      await ch.close()
      return r.message
    let reply = waitFor run(s.port.int)
    check reply == @[byte('o'), byte('k')]
    check seen.load == 3
    s.stop()

  test "chronos: refused past the retries":
    let s = start(100)
    proc run(port: int): Future[bool] {.async.} =
      let ch = await ac.dialAsync("127.0.0.1", port)
      var unprocessed = false
      try: discard await ac.unaryCall(ch, "/t.T/M", @[byte 1])
      except GrpcError as e: unprocessed = e.unprocessed
      await ch.close()
      return unprocessed
    let unprocessed = waitFor run(s.port.int)
    check unprocessed
    check seen.load == 1 + ac.refusedRetries
    s.stop()
