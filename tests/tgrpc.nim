## gRPC wire helpers, and the unary interop cases run in-process.

import std/[unittest, atomics, locks]
import nimgrpc, nimgrpc/wire
import ./interop/interop
import ./gen/grpc/testing/test_pb

suite "wire":
  test "message framing round trip":
    let body = encodeMessage([1'u8, 2, 3]) & encodeMessage([]) & encodeMessage([9'u8])
    check decodeMessages(body) == @[@[1'u8, 2, 3], @[], @[9'u8]]

  test "framing errors map to status codes":
    template code(body: seq[byte]; maxLen = 100): StatusCode =
      var c = scOk
      try: discard decodeMessages(body, maxLen)
      except GrpcError as e: c = e.code
      c
    check code(@[0'u8, 0, 0]) == scInternal                        # short header
    check code(@[0'u8, 0, 0, 0, 5, 1]) == scInternal               # short payload
    check code(@[1'u8, 0, 0, 0, 0]) == scUnimplemented             # compressed
    check code(encodeMessage(newSeq[byte](101))) == scResourceExhausted

  test "grpc content types: application/grpc, optionally with +subtype or ;parameters":
    check isGrpcContentType("application/grpc")
    check isGrpcContentType("application/grpc+proto")
    check isGrpcContentType("application/grpc+json")
    check isGrpcContentType("application/grpc;charset=utf-8")
    check not isGrpcContentType("application/grpcx")
    check not isGrpcContentType("application/grpc-web")
    check not isGrpcContentType("application/grp")
    check not isGrpcContentType("application/json")
    check not isGrpcContentType("")

  test "grpc-timeout":
    check encodeTimeout(250) == "250m"
    check encodeTimeout(100_000_000) == "100000S"
    check parseTimeout("250m") == 250
    check parseTimeout("2S") == 2000
    check parseTimeout("1H") == 3_600_000
    check parseTimeout("1500u") == 2       # rounded up
    check parseTimeout("1n") == 1
    check parseTimeout("123456789m") == -1 # more than 8 digits
    check parseTimeout("12x") == -1
    check parseTimeout("m") == -1

  test "grpc-message percent-encoding":
    let msg = "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n 100%"
    let enc = encodeStatusMessage(msg)
    for ch in enc: check ch in {' ' .. '~'}
    check decodeStatusMessage(enc) == msg
    check decodeStatusMessage("bad %zz and %4") == "bad %zz and %4"

  test "binary metadata is base64 on the wire, reserved keys are dropped":
    let md: Metadata = @[("X-Bin", "\xab\x00\xff"), ("plain", "v"),
                         ("grpc-timeout", "1S"), ("content-type", "x"), (":path", "/")]
    let wire = md.toWire
    check wire == @[("x-bin", "qwD/"), ("plain", "v")]
    check fromWire(wire) == @[("x-bin", "\xab\x00\xff"), ("plain", "v")]

suite "unary interop, Nim client and Nim server":
  var srv: GrpcServer
  var ch: GrpcChannel
  setup:
    srv = newTestServer()
    srv.start()
    ch = dial("127.0.0.1", srv.port)
  teardown:
    ch.close()
    srv.stop()

  for name in allCases:
    test name:
      ch.runCase(name)

  test "an undecodable request is INTERNAL":
    var code = scOk
    try:
      discard ch.unaryCall("/grpc.testing.TestService/UnaryCall",
                           @[0xff'u8, 0xff, 0xff])
    except GrpcError as e:
      code = e.code
    check code == scInternal

  test "a request of 100 000 nested groups is INTERNAL and the server goes on":
    # 0xC3 0x3E is field 1000, start-group; it used to overflow the stack
    var bomb: seq[byte]
    for i in 0 ..< 100_000: bomb.add [0xC3'u8, 0x3E]
    var code = scOk
    try:
      discard ch.unaryCall("/grpc.testing.TestService/UnaryCall", bomb)
    except GrpcError as e:
      code = e.code
    check code == scInternal
    check ch.unaryCall("/grpc.testing.TestService/EmptyCall", newSeq[byte]()).message.len == 0
    let ok = ch.unaryCall("/grpc.testing.TestService/UnaryCall", SimpleRequest(responseSize: 3).encode)
    check SimpleResponse.decode(ok.message).payload.body.len == 3

proc abortingInput(ctx: var ServerContext;
                   input: var ServerReader[StreamingInputCallRequest]):
                   StreamingInputCallResponse {.nimcall, gcsafe, raises: [CatchableError].} =
  var req: StreamingInputCallRequest
  discard input.recv(req)
  raise newGrpcError(scAborted, "typed handler gave up")

proc failing(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  raise newException(ValueError, "not a gRPC error")

proc aborting(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  raise newGrpcError(scAborted, "the handler's own words")

# What the error hook saw, kept in fixed buffers so that no string crosses threads.
var hookLock: Lock
hookLock.initLock()
var hookCalls: Atomic[int]
var hookPath, hookMsg: array[64, char]

proc copyTo(dst: var array[64, char]; s: string) =
  for i in 0 ..< min(s.len, dst.len - 1): dst[i] = s[i]

proc recordError(path: string; e: ref CatchableError) {.nimcall, gcsafe, raises: [].} =
  withLock hookLock:
    {.cast(gcsafe).}:
      hookPath.copyTo path
      hookMsg.copyTo e.msg
  hookCalls.atomicInc

suite "handler errors":
  test "an unexpected exception becomes UNKNOWN and the server keeps going":
    let srv = newGrpcServer()
    srv.addUnary("/t.T/Fail", failing)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    for i in 0 ..< 50:      # many times on the same workers
      var code = scOk
      var msg = ""
      try:
        discard ch.unaryCall("/t.T/Fail", @[])
      except GrpcError as e:
        code = e.code
        msg = e.msg
      check code == scUnknown
      check msg == "internal error"       # the exception text stays on the server
    ch.close()
    srv.stop()

  test "the error hook gets the path and the exception; a GrpcError does not reach it":
    hookCalls.store 0
    withLock hookLock:
      {.cast(gcsafe).}:
        hookPath = default(array[64, char])
        hookMsg = default(array[64, char])
    let srv = newGrpcServer()
    srv.addUnary("/t.T/Fail", failing)
    srv.addUnary("/t.T/Abort", aborting)
    srv.setErrorHook(recordError)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    var code = scOk
    var msg = ""
    try:
      discard ch.unaryCall("/t.T/Abort", @[])
    except GrpcError as e:
      code = e.code
      msg = e.msg
    check code == scAborted
    check msg == "the handler's own words"
    check hookCalls.load == 0
    try:
      discard ch.unaryCall("/t.T/Fail", @[])
    except GrpcError as e:
      code = e.code
      msg = e.msg
    check code == scUnknown
    check msg == "internal error"
    check hookCalls.load == 1
    withLock hookLock:
      {.cast(gcsafe).}:
        check $cast[cstring](hookPath[0].addr) == "/t.T/Fail"
        check $cast[cstring](hookMsg[0].addr) == "not a gRPC error"
    ch.close()
    srv.stop()

  test "a typed streaming handler that raises, many times on the same workers":
    # Regression: the call through the generic handler type once lost its
    # error check, and the next raise on that worker died with OverflowDefect.
    let srv = newGrpcServer()
    srv.registerTestService(TestServiceHandlers(streamingInputCall: abortingInput))
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let svc = newTestServiceClient(ch)
    for i in 0 ..< 50:
      var call = svc.streamingInputCall(timeoutMs = 5000)
      call.send StreamingInputCallRequest()
      var code = scOk
      try:
        discard call.closeAndRecv()
      except GrpcError as e:
        code = e.code
      call.close()
      check code == scAborted
    ch.close()
    srv.stop()

import nimgrpc/compress/gzip
import nimgrpc/h2/blocking as h2b

suite "compression":
  test "gzip round trip":
    let data = newSeq[byte](100_000)
    let z = gzipCompress(data)
    check z.len < 1000
    check gzipDecompress(z, 100_000) == data

  test "decompression stops at the limit (zip bomb)":
    let bomb = gzipCompress(newSeq[byte](50_000_000))   # ~50 KB compressed
    check bomb.len < 100_000
    var code = scOk
    try: discard gzipDecompress(bomb, 4 * 1024 * 1024)
    except GrpcError as e: code = e.code
    check code == scResourceExhausted

  test "corrupt gzip is INTERNAL":
    var z = gzipCompress(@[1'u8, 2, 3, 4, 5, 6, 7, 8])
    z[z.len div 2] = z[z.len div 2] xor 0xff
    var code = scOk
    try: discard gzipDecompress(z, 1000)
    except GrpcError as e: code = e.code
    check code == scInternal

  proc rawCall(port: int; extra: seq[Header]; body: seq[byte]): h2b.Response =
    let c = h2b.dial("127.0.0.1", Port(port))
    var hs = @[(":method", "POST"), (":scheme", "http"), (":authority", "x"),
               (":path", "/grpc.testing.TestService/UnaryCall"),
               ("content-type", "application/grpc"), ("te", "trailers")]
    hs.add extra
    result = c.request(hs, body, timeoutMs = 5000)
    c.close()

  proc statusOf(r: h2b.Response): string =
    for blk in [r.trailers, r.headers]:
      for (k, v) in blk:
        if k == "grpc-status": return v

  var srv: GrpcServer
  setup:
    srv = newTestServer()
    srv.start()
  teardown:
    srv.stop()

  test "an unsupported grpc-encoding is UNIMPLEMENTED, with what is accepted":
    let r = rawCall(srv.port, @[("grpc-encoding", "snappy")],
                    encodeMessage(SimpleRequest().encode))
    check r.statusOf == $ord(scUnimplemented)
    var accept = ""
    for (k, v) in r.headers:
      if k == "grpc-accept-encoding": accept = v
    check accept == "gzip"

  test "a compressed message without grpc-encoding is INTERNAL":
    let msg = encodeMessage(gzipCompress(SimpleRequest().encode), compressed = true)
    check rawCall(srv.port, @[], msg).statusOf == $ord(scInternal)

  test "the size limit applies after decompression":
    let small = newGrpcServer(maxMessage = 1000)
    small.registerTestService(TestServiceHandlers(unaryCall: proc (ctx: var ServerContext;
        req: SimpleRequest): SimpleResponse {.nimcall, gcsafe.} = SimpleResponse()))
    small.start()
    let req = SimpleRequest(payload: Payload(body: newSeq[byte](100_000)))
    let msg = encodeMessage(gzipCompress(req.encode), compressed = true)
    check msg.len < 1000
    check rawCall(small.port, @[("grpc-encoding", "gzip")], msg).statusOf ==
          $ord(scResourceExhausted)
    small.stop()

  test "a compressed client call and a compressed reply":
    let ch = dial("127.0.0.1", srv.port)
    let svc = newTestServiceClient(ch)
    let r = svc.unaryCall(SimpleRequest(responseSize: 50_000, payload: Payload(body: newSeq[byte](50_000)),
                                        expectCompressed: BoolValue(value: true),
                                        responseCompressed: BoolValue(value: true)),
                          compression = "gzip", timeoutMs = 5000)
    check r.payload.body.len == 50_000
    ch.close()

suite "request validation":
  proc rawCall(port: int; contentType: string; extra: seq[Header]): h2b.Response =
    let c = h2b.dial("127.0.0.1", Port(port))
    var hs = @[(":method", "POST"), (":scheme", "http"), (":authority", "x"),
               (":path", "/grpc.testing.TestService/EmptyCall"),
               ("content-type", contentType), ("te", "trailers")]
    hs.add extra
    result = c.request(hs, encodeMessage([]), timeoutMs = 5000)
    c.close()

  proc statusOf(r: h2b.Response): string =
    for blk in [r.trailers, r.headers]:
      for (k, v) in blk:
        if k == "grpc-status": return v

  proc httpStatus(r: h2b.Response): string =
    for (k, v) in r.headers:
      if k == ":status": return v

  var srv: GrpcServer
  setup:
    srv = newTestServer()
    srv.start()
  teardown:
    srv.stop()

  test "a content-type that only starts like application/grpc gets 415":
    check rawCall(srv.port, "application/grpcx", @[]).httpStatus == "415"
    check rawCall(srv.port, "application/grpc-web", @[]).httpStatus == "415"
    check rawCall(srv.port, "text/plain", @[]).httpStatus == "415"
    for ok in ["application/grpc", "application/grpc+proto", "application/grpc;charset=utf-8"]:
      let r = rawCall(srv.port, ok, @[])
      check r.httpStatus == "200"
      check r.statusOf == "0"

  test "a malformed grpc-timeout is INTERNAL, a valid one or none works":
    for bad in ["-1S", "5x", "", "S", "123456789m", "5 S"]:
      let r = rawCall(srv.port, "application/grpc", @[("grpc-timeout", bad)])
      check r.statusOf == $ord(scInternal)
      var msg = ""
      for (k, v) in r.headers:
        if k == "grpc-message": msg = v
      check msg == "malformed grpc-timeout"
    check rawCall(srv.port, "application/grpc", @[("grpc-timeout", "5S")]).statusOf == "0"
    check rawCall(srv.port, "application/grpc", @[]).statusOf == "0"

when defined(linux):
  import std/[net, times]

  proc stuckListener(): tuple[lst: Socket, port: Port, fillers: seq[Socket]] =
    ## A listener that never accepts, with its queue full: the kernel then drops
    ## further SYNs, so a connect to it hangs.
    result.lst = newSocket()
    result.lst.setSockOpt(OptReuseAddr, true)
    result.lst.bindAddr(Port(0), "127.0.0.1")
    result.lst.listen(1)
    result.port = result.lst.getLocalAddr()[1]
    for _ in 0 ..< 8:
      let s = newSocket()
      try:
        s.connect("127.0.0.1", result.port, 200)
        result.fillers.add s
      except CatchableError:
        s.close()
        return                      # the queue is full

  proc closeAll(l: tuple[lst: Socket, port: Port, fillers: seq[Socket]]) =
    for s in l.fillers: s.close()
    l.lst.close()

  suite "connect timeout":
    test "dial gives up on a server that never accepts":
      let stuck = stuckListener()
      defer: closeAll(stuck)
      if stuck.fillers.len >= 8:
        skip()
      else:
        let started = epochTime()
        var code = scOk
        try:
          discard dial("127.0.0.1", stuck.port.int, connectTimeoutMs = 300)
        except GrpcError as e:
          code = e.code
        let took = epochTime() - started
        check code == scUnavailable
        check took >= 0.25 and took < 3.0
