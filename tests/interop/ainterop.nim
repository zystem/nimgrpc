## Interop peer on chronos, on the async stubs generated from
## grpc/testing/test.proto (tests/gen, option `async`): a TestService server
## and a client running the same cases as interop.nim.
##
##   ainterop server PORT [--tls|--mtls] [--certs=DIR] [--max-message=BYTES]
##   ainterop client HOST PORT [CASES] [--tls|--mtls] [--certs=DIR] [--server-name=NAME]
##                   [--lenient-compression] [--no-per-message-compression]

import std/[os, strutils]
import pkg/chronos
import nimgrpc/asynctyped
from nimgrpc/wire import defaultMaxMessage
import ../gen/grpc/testing/test_pb

const
  initialKey = "x-grpc-test-echo-initial"
  trailingKey = "x-grpc-test-echo-trailing-bin"

proc zeros(n: int): Payload = Payload(body: newSeq[byte](n))

# ---------------------------------------------------------------- server

proc echoMetadata(ctx: AsyncServerContext) =
  let a = ctx.metadata.get(initialKey)
  if a.len > 0: ctx.headers.add (initialKey, a)
  let b = ctx.metadata.get(trailingKey)
  if b.len > 0: ctx.trailers.add (trailingKey, b)

proc echoStatus(s: EchoStatus) =
  if s.code != 0: raise newGrpcError(toStatusCode(s.code), s.message)

proc checkCompressed(ctx: AsyncServerContext; expect: BoolValue) =
  if expect.value and not ctx.requestCompressed:
    raise newGrpcError(scInvalidArgument, "expected a compressed message")

proc emptyCall(ctx: AsyncServerContext; req: Empty): Future[Empty] {.async.} =
  return Empty()

proc unaryCall(ctx: AsyncServerContext; req: SimpleRequest): Future[SimpleResponse] {.async.} =
  ctx.echoMetadata()
  checkCompressed(ctx, req.expectCompressed)
  echoStatus(req.responseStatus)
  if req.responseCompressed.value: ctx.responseCompression = "gzip"
  return SimpleResponse(payload: zeros(req.responseSize))

proc streamingOutputCall(ctx: AsyncServerContext; req: StreamingOutputCallRequest;
                         output: AsyncServerWriter[StreamingOutputCallResponse]) {.async.} =
  for p in req.responseParameters:
    if p.compressed.value: ctx.responseCompression = "gzip"
  for p in req.responseParameters:
    if p.intervalUs > 0: await sleepAsync((p.intervalUs div 1000).milliseconds)
    await output.send(StreamingOutputCallResponse(payload: zeros(p.size)), p.compressed.value)

proc streamingInputCall(ctx: AsyncServerContext;
                        input: AsyncServerReader[StreamingInputCallRequest]):
                        Future[StreamingInputCallResponse] {.async.} =
  var total = 0
  while true:
    let req = await input.recv()
    if req.isNone: break
    checkCompressed(ctx, req.get.expectCompressed)
    total += req.get.payload.body.len
  return StreamingInputCallResponse(aggregatedPayloadSize: total.int32)

proc fullDuplexCall(ctx: AsyncServerContext;
                    call: AsyncServerBidi[StreamingOutputCallRequest,
                                          StreamingOutputCallResponse]) {.async.} =
  ctx.echoMetadata()
  while true:
    let req = await call.recv()
    if req.isNone: break
    echoStatus(req.get.responseStatus)
    for p in req.get.responseParameters:
      if p.compressed.value: ctx.responseCompression = "gzip"
      if p.intervalUs > 0: await sleepAsync((p.intervalUs div 1000).milliseconds)
      await call.send(StreamingOutputCallResponse(payload: zeros(p.size)), p.compressed.value)

proc newAsyncTestServer*(port = 0; tls: TlsConfig = nil; maxMessage = defaultMaxMessage): AsyncGrpcServer =
  result = newAsyncGrpcServer(port, tls = tls, maxMessage = maxMessage)
  result.registerTestService(TestServiceAsyncHandlers(
    emptyCall: emptyCall, unaryCall: unaryCall,
    streamingOutputCall: streamingOutputCall,
    streamingInputCall: streamingInputCall,
    fullDuplexCall: fullDuplexCall))

# ---------------------------------------------------------------- client

template expectCode(want: StatusCode; wantMsg: string; body: untyped) =
  ## Runs `body` (which may await); it must fail with `want`.
  block:
    var raised = false
    var code = scOk
    var msg = ""
    try:
      body
    except GrpcError as e:
      raised = true
      code = e.code
      msg = e.msg
    if not raised:
      raise newException(ValueError, "call succeeded, want " & $want)
    if code != want:
      raise newException(ValueError, "code " & $code & " (" & msg & "), want " & $want)
    if wantMsg.len > 0 and msg != wantMsg:
      raise newException(ValueError, "message " & msg.escape & ", want " & wantMsg.escape)

template expectCode(want: StatusCode; body: untyped) = expectCode(want, "", body)

proc check(cond: bool; what: string) =
  if not cond: raise newException(ValueError, what)

template closing(call: untyped; body: untyped) =
  ## Runs `body`, then closes `call` whether or not it failed.
  var failure: ref CatchableError
  try:
    body
  except CancelledError as e:
    call.close()
    raise e
  except CatchableError as e:
    failure = e
  call.close()
  if failure != nil: raise failure

proc outReq(respSizes: openArray[int32]; payload = 0;
            status = EchoStatus()): StreamingOutputCallRequest =
  result = StreamingOutputCallRequest(payload: zeros(payload), responseStatus: status)
  for n in respSizes: result.responseParameters.add ResponseParameters(size: n)

const
  reqSizes = [27182, 8, 1828, 45904]
  respSizes = [31415'i32, 9, 2653, 58979]

var perMessageCompression* = true
  ## Off against grpc-java: it never compresses a single streamed message (see interop.nim).

var strictCompression* = true

proc runCase*(ch: AsyncChannel; name: string) {.async.} =
  ## Fails on failure.
  let svc = newTestServiceAsyncClient(ch)
  {.cast(gcsafe).}:
    let strict = strictCompression
  case name
  of "empty_unary":
    discard await svc.emptyCall(Empty(), timeoutMs = 10_000)
  of "large_unary":
    let r = await svc.unaryCall(SimpleRequest(responseSize: 314159, payload: zeros(271828)),
                                timeoutMs = 10_000)
    check r.payload.body.len == 314159, "payload " & $r.payload.body.len & " bytes"
  of "status_code_and_message", "special_status_message":
    let msg = if name == "status_code_and_message": "test status message"
              else: "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
    let st = EchoStatus(code: 2, message: msg)
    expectCode(scUnknown, msg):
      discard await svc.unaryCall(SimpleRequest(responseStatus: st))
    if name == "status_code_and_message":
      let call = await svc.fullDuplexCall(timeoutMs = 10_000)
      closing call:
        expectCode(scUnknown, msg):
          await call.send outReq([], status = st)
          await call.closeSend()
          while (await call.recv()).isSome: discard
  of "unimplemented_method":
    expectCode(scUnimplemented):
      discard await svc.unimplementedCall(Empty())
  of "unimplemented_service":
    let other = newUnimplementedServiceAsyncClient(ch)
    expectCode(scUnimplemented):
      discard await other.unimplementedCall(Empty())
  of "custom_metadata":
    let bin = "\xab\xab\xab"
    let md = @[(initialKey, "test_initial_metadata_value"), (trailingKey, bin)]
    let r = await svc.unaryCallWithMetadata(
      SimpleRequest(responseSize: 314159, payload: zeros(271828)), md, timeoutMs = 10_000)
    check r.message.payload.body.len == 314159, "unary payload size"
    check r.headers.get(initialKey) == "test_initial_metadata_value",
          "unary initial metadata " & $r.headers
    check r.trailers.get(trailingKey) == bin, "unary trailing metadata " & $r.trailers
    let call = await svc.fullDuplexCall(md, timeoutMs = 10_000)
    closing call:
      await call.send outReq([314159'i32], payload = 271828)
      await call.closeSend()
      let resp = await call.recv()
      check resp.isSome, "no duplex response"
      check resp.get.payload.body.len == 314159, "duplex payload size"
      check (await call.recv()).isNone, "extra duplex response"
      check call.headers.get(initialKey) == "test_initial_metadata_value",
            "duplex initial metadata " & $call.headers
      check call.trailers.get(trailingKey) == bin, "duplex trailing metadata"
  of "client_streaming":
    let call = await svc.streamingInputCall(timeoutMs = 10_000)
    closing call:
      for n in reqSizes: await call.send StreamingInputCallRequest(payload: zeros(n))
      let total = (await call.closeAndRecv()).aggregatedPayloadSize
      check total == 74922, "aggregated " & $total
  of "server_streaming":
    let call = await svc.streamingOutputCall(outReq(respSizes), timeoutMs = 10_000)
    closing call:
      for n in respSizes:
        let resp = await call.recv()
        check resp.isSome, "stream ended early"
        check resp.get.payload.body.len == n, "size " & $resp.get.payload.body.len & ", want " & $n
      check (await call.recv()).isNone, "extra response"
  of "ping_pong":
    let call = await svc.fullDuplexCall(timeoutMs = 10_000)
    closing call:
      for i in 0 ..< reqSizes.len:
        await call.send outReq([respSizes[i]], payload = reqSizes[i])
        let resp = await call.recv()
        check resp.isSome, "no response to request " & $i
        check resp.get.payload.body.len == respSizes[i], "size " & $resp.get.payload.body.len
      await call.closeSend()
      check (await call.recv()).isNone, "extra response"
  of "empty_stream":
    let call = await svc.fullDuplexCall(timeoutMs = 10_000)
    closing call:
      await call.closeSend()
      check (await call.recv()).isNone, "response on an empty stream"
  of "cancel_after_begin":
    let call = await svc.streamingInputCall(timeoutMs = 10_000)
    call.cancel()
    expectCode(scCancelled):
      discard await call.closeAndRecv()
  of "cancel_after_first_response":
    let call = await svc.fullDuplexCall(timeoutMs = 10_000)
    await call.send outReq([31415'i32], payload = 27182)
    check (await call.recv()).isSome, "no first response"
    call.cancel()
    expectCode(scCancelled):
      discard await call.recv()
  of "timeout_on_sleeping_server":
    let call = await svc.fullDuplexCall(timeoutMs = 1)
    closing call:
      expectCode(scDeadlineExceeded):
        await call.send outReq([], payload = 27182)
        while (await call.recv()).isSome: discard
  of "client_compressed_unary":
    let req = SimpleRequest(responseSize: 314159, payload: zeros(271828),
                            expectCompressed: BoolValue(value: true))
    if strict:
      expectCode(scInvalidArgument):
        discard await svc.unaryCall(req)
    let r = await svc.unaryCall(req, compression = "gzip", timeoutMs = 10_000)
    check r.payload.body.len == 314159, "compressed call: payload size"
    var plain = req
    plain.expectCompressed = BoolValue(value: false)
    check (await svc.unaryCall(plain, timeoutMs = 10_000)).payload.body.len == 314159,
          "uncompressed call: payload size"
  of "server_compressed_unary":
    for compressed in [true, false]:
      let call = await svc.ch.newCall("/grpc.testing.TestService/UnaryCall", timeoutMs = 10_000)
      closing call:
        await call.send SimpleRequest(responseSize: 314159,
                                      responseCompressed: BoolValue(value: compressed)).encode
        await call.closeSend()
        let raw = await call.recv()
        check raw.isSome, "no response"
        check SimpleResponse.decode(raw.get).payload.body.len == 314159, "payload size"
        if compressed or strict:
          check call.lastCompressed == compressed,
                "response compressed: " & $call.lastCompressed & ", want " & $compressed
        check (await call.recv()).isNone, "extra response"
  of "client_compressed_streaming":
    if strict:
      let probe = await svc.streamingInputCall(timeoutMs = 10_000)
      closing probe:
        expectCode(scInvalidArgument):
          await probe.send StreamingInputCallRequest(payload: zeros(27182),
                                                     expectCompressed: BoolValue(value: true))
          discard await probe.closeAndRecv()
    let call = await svc.streamingInputCall(timeoutMs = 10_000, compression = "gzip")
    closing call:
      await call.send(StreamingInputCallRequest(payload: zeros(27182),
                                                expectCompressed: BoolValue(value: true)), true)
      await call.send(StreamingInputCallRequest(payload: zeros(45904)), false)
      let total = (await call.closeAndRecv()).aggregatedPayloadSize
      check total == 73086, "aggregated " & $total
  of "server_compressed_streaming":
    var req = StreamingOutputCallRequest()
    req.responseParameters.add ResponseParameters(size: 31415, compressed: BoolValue(value: true))
    req.responseParameters.add ResponseParameters(size: 92653, compressed: BoolValue(value: false))
    let call = await svc.streamingOutputCall(req, timeoutMs = 10_000)
    closing call:
      var resp = await call.recv()
      check resp.isSome, "no first response"
      check resp.get.payload.body.len == 31415 and (call.lastCompressed or not perMessageCompression),
            "first: compressed 31415"
      resp = await call.recv()
      check resp.isSome, "no second response"
      check resp.get.payload.body.len == 92653, "second: size"
      if strict: check not call.lastCompressed, "second must not be compressed"
      check (await call.recv()).isNone, "extra response"
  of "keepalive_enforced":
    let fast = await dialAsync(ch.host, ch.port, ch.tls, ch.serverName,
                               Keepalive(timeMs: 50, timeoutMs: 2000))
    var failure: ref CatchableError
    try:
      let fsvc = newTestServiceAsyncClient(fast)
      let call = await fsvc.fullDuplexCall(timeoutMs = 10_000)
      expectCode(scUnavailable):
        discard await call.recv()
      call.close()
      discard await fsvc.emptyCall(Empty(), timeoutMs = 10_000)
    except CatchableError as e:
      failure = e
    await fast.close()
    if failure != nil: raise failure
  of "concurrent_load":
    # Not an official case: 2000 unary calls and 100 streams at once on one
    # channel, from one thread.
    var unaries: seq[Future[SimpleResponse]]
    for i in 0 ..< 2000:
      unaries.add svc.unaryCall(SimpleRequest(responseSize: int32(i mod 100),
                                              payload: zeros(i mod 50)), timeoutMs = 30_000)
    proc stream(): Future[int] {.async.} =
      let call = await svc.streamingOutputCall(outReq([10'i32, 20, 30]), timeoutMs = 30_000)
      var n = 0
      while true:
        let r = await call.recv()
        if r.isNone: break
        n += r.get.payload.body.len
      call.close()
      return n
    var streams: seq[Future[int]]
    for i in 0 ..< 100: streams.add stream()
    await allFutures(unaries)
    await allFutures(streams)
    for i, f in unaries:
      check f.completed, "unary " & $i & " failed: " & (if f.failed: f.error.msg else: "")
      check f.read.payload.body.len == i mod 100, "unary " & $i & " size"
    for f in streams:
      check f.completed and f.read == 60, "stream failed"
  else:
    raise newException(ValueError, "unknown case " & name)

const allCases* = ["empty_unary", "large_unary", "client_streaming",
                   "server_streaming", "ping_pong", "empty_stream",
                   "cancel_after_begin", "cancel_after_first_response",
                   "timeout_on_sleeping_server", "status_code_and_message",
                   "special_status_message", "unimplemented_method",
                   "unimplemented_service", "custom_metadata",
                   "client_compressed_unary", "server_compressed_unary",
                   "client_compressed_streaming", "server_compressed_streaming",
                   "concurrent_load"]

proc runClient*(host: string; port: int; only: seq[string] = @[];
                tls: TlsConfig = nil; serverName = ""): Future[int] {.async.} =
  ## The number of failed cases.
  let ch = await dialAsync(host, port, tls, serverName)
  var failed = 0
  for name in (if only.len > 0: only else: @allCases):
    try:
      await ch.runCase(name)
      echo "PASS ", name
    except CatchableError as e:
      echo "FAIL ", name, ": ", e.msg
      inc failed
  await ch.close()
  return failed

when isMainModule:
  var pos: seq[string]
  var mode = ""
  var serverNameOpt = "localhost"
  var maxMessageOpt = defaultMaxMessage
  var certs = currentSourcePath.parentDir.parentDir / "certs"
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a in ["--tls", "--mtls"]: mode = a[2 .. ^1]
    elif a == "--lenient-compression": strictCompression = false
    elif a == "--no-per-message-compression": perMessageCompression = false
    elif a.startsWith("--server-name="): serverNameOpt = a["--server-name=".len .. ^1]
    elif a.startsWith("--max-message="): maxMessageOpt = parseInt(a["--max-message=".len .. ^1])
    elif a.startsWith("--certs="): certs = a["--certs=".len .. ^1]
    else: pos.add a
  proc pem(name: string): string = readFile(certs / name)
  if pos.len > 0 and pos[0] == "server":
    let tls = case mode
      of "tls": tlsServerConfig(pem"server.pem", pem"server.key")
      of "mtls": tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"ca.pem")
      else: nil
    let s = newAsyncTestServer(if pos.len >= 2: parseInt(pos[1]) else: 10000, tls, maxMessageOpt)
    s.start()
    echo "listening on ", s.port, (if mode.len > 0: " (" & mode & ")" else: "")
    runForever()
  else:
    let host = if pos.len >= 2: pos[1] else: "127.0.0.1"
    let port = if pos.len >= 3: parseInt(pos[2]) else: 10000
    let only = if pos.len >= 4 and pos[3].len > 0: pos[3].split(',') else: @[]
    let tls = case mode
      of "tls": tlsClientConfig(pem"ca.pem")
      of "mtls": tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key")
      else: nil
    quit(waitFor runClient(host, port, only, tls, if tls != nil: serverNameOpt else: ""))
