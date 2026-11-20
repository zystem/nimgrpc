## Interop peer in Nim, on code generated from grpc/testing/test.proto
## (tests/gen): a grpc.testing.TestService server and a client running the
## interop cases from nimgrpc/grpc doc/interop-test-descriptions.md.
##
##   interop server PORT [--tls|--mtls] [--certs=DIR] [--max-message=BYTES]
##   interop client HOST PORT [CASES] [--tls|--mtls] [--certs=DIR] [--server-name=NAME]
##                  [--lenient-compression] [--no-per-message-compression]

import std/strutils
import nimgrpc, nimgrpc/cleanup
from nimgrpc/wire import defaultMaxMessage
import ../gen/grpc/testing/test_pb

const
  initialKey = "x-grpc-test-echo-initial"
  trailingKey = "x-grpc-test-echo-trailing-bin"

proc zeros(n: int): Payload = Payload(body: newSeq[byte](n))

# ---------------------------------------------------------------- server

proc echoMetadata(ctx: var ServerContext) =
  let a = ctx.metadata.get(initialKey)
  if a.len > 0: ctx.headers.add (initialKey, a)
  let b = ctx.metadata.get(trailingKey)
  if b.len > 0: ctx.trailers.add (trailingKey, b)

proc echoStatus(s: EchoStatus) =
  if s.code != 0: raise newGrpcError(toStatusCode(s.code), s.message)

proc emptyCall(ctx: var ServerContext; req: Empty): Empty
    {.nimcall, gcsafe, raises: [CatchableError].} =
  Empty()

proc checkCompressed(ctx: ServerContext; expect: BoolValue) =
  ## The compression interop cases: a message that says it was sent
  ## compressed must have been.
  if expect.value and not ctx.requestCompressed:
    raise newGrpcError(scInvalidArgument, "expected a compressed message")

proc unaryCall(ctx: var ServerContext; req: SimpleRequest): SimpleResponse
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ctx.echoMetadata()
  checkCompressed(ctx, req.expectCompressed)
  echoStatus(req.responseStatus)
  if req.responseCompressed.value: ctx.responseCompression = "gzip"
  SimpleResponse(payload: zeros(req.responseSize))

proc streamingOutputCall(ctx: var ServerContext; req: StreamingOutputCallRequest;
                         output: var ServerWriter[StreamingOutputCallResponse])
    {.nimcall, gcsafe, raises: [CatchableError].} =
  for p in req.responseParameters:
    if p.compressed.value: ctx.responseCompression = "gzip"
  for p in req.responseParameters:
    if p.intervalUs > 0: ctx.sleep(p.intervalUs div 1000)
    output.send(StreamingOutputCallResponse(payload: zeros(p.size)), p.compressed.value)

proc streamingInputCall(ctx: var ServerContext;
                        input: var ServerReader[StreamingInputCallRequest]):
                        StreamingInputCallResponse
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var req: StreamingInputCallRequest
  var total = 0
  while input.recv(req):
    checkCompressed(ctx, req.expectCompressed)
    total += req.payload.body.len
  StreamingInputCallResponse(aggregatedPayloadSize: total.int32)

proc fullDuplexCall(ctx: var ServerContext;
                    call: var ServerBidi[StreamingOutputCallRequest,
                                         StreamingOutputCallResponse])
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ctx.echoMetadata()
  var req: StreamingOutputCallRequest
  while call.recv(req):
    echoStatus(req.responseStatus)
    for p in req.responseParameters:
      if p.compressed.value: ctx.responseCompression = "gzip"
      if p.intervalUs > 0: ctx.sleep(p.intervalUs div 1000)
      call.send(StreamingOutputCallResponse(payload: zeros(p.size)), p.compressed.value)

proc newTestServer*(port = 0; tls: TlsConfig = nil; maxMessage = defaultMaxMessage): GrpcServer =
  result = newGrpcServer(port, tls = tls, maxMessage = maxMessage)
  result.registerTestService(TestServiceHandlers(
    emptyCall: emptyCall, unaryCall: unaryCall,
    streamingOutputCall: streamingOutputCall,
    streamingInputCall: streamingInputCall,
    fullDuplexCall: fullDuplexCall))

# ---------------------------------------------------------------- client

proc expectCode(f: proc () {.raises: [CatchableError].}; want: StatusCode;
                wantMsg = "") =
  var raised = false
  var code = scOk
  var msg = ""
  try:
    f()
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

proc check(cond: bool; what: string) =
  if not cond: raise newException(ValueError, what)

proc outReq(respSizes: openArray[int32]; payload = 0;
            status = EchoStatus()): StreamingOutputCallRequest =
  result = StreamingOutputCallRequest(payload: zeros(payload), responseStatus: status)
  for n in respSizes: result.responseParameters.add ResponseParameters(size: n)

const
  reqSizes = [27182, 8, 1828, 45904]
  respSizes = [31415'i32, 9, 2653, 58979]

var perMessageCompression* = true
  ## Off against servers that do not choose compression per message at all (grpc-java sets it
  ## for a whole unary call and never for a stream): the check that the first streamed message
  ## is compressed when the request asks for it is skipped.

var strictCompression* = true
  ## Off against servers that cannot report whether a request was compressed
  ## or choose compression per message (grpc-go): the probes and the
  ## "this one must not be compressed" checks are skipped.

proc runCase*(ch: GrpcChannel; name: string) =
  ## Raises on failure.
  let svc = newTestServiceClient(ch)
  var resp: StreamingOutputCallResponse
  case name
  of "empty_unary":
    discard svc.emptyCall(Empty(), timeoutMs = 10_000)
  of "large_unary":
    let r = svc.unaryCall(SimpleRequest(responseSize: 314159, payload: zeros(271828)),
                          timeoutMs = 10_000)
    check r.payload.body.len == 314159, "payload " & $r.payload.body.len & " bytes"
  of "status_code_and_message", "special_status_message":
    let msg = if name == "status_code_and_message": "test status message"
              else: "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
    let st = EchoStatus(code: 2, message: msg)
    expectCode(proc () = discard svc.unaryCall(SimpleRequest(responseStatus: st)),
               scUnknown, msg)
    if name == "status_code_and_message":
      var call = svc.fullDuplexCall(timeoutMs = 10_000)
      withCleanup:
        expectCode(proc () =
          call.send outReq([], status = st)
          call.closeSend()
          var m: StreamingOutputCallResponse
          while call.recv(m): discard, scUnknown, msg)
      do:
        call.close()
  of "unimplemented_method":
    expectCode(proc () = discard svc.unimplementedCall(Empty()), scUnimplemented)
  of "unimplemented_service":
    let other = newUnimplementedServiceClient(ch)
    expectCode(proc () = discard other.unimplementedCall(Empty()), scUnimplemented)
  of "custom_metadata":
    let bin = "\xab\xab\xab"
    let md = @[(initialKey, "test_initial_metadata_value"), (trailingKey, bin)]
    let r = svc.unaryCallWithMetadata(
      SimpleRequest(responseSize: 314159, payload: zeros(271828)), md, timeoutMs = 10_000)
    check r.message.payload.body.len == 314159, "unary payload size"
    check r.headers.get(initialKey) == "test_initial_metadata_value",
          "unary initial metadata " & $r.headers
    check r.trailers.get(trailingKey) == bin, "unary trailing metadata " & $r.trailers
    var call = svc.fullDuplexCall(md, timeoutMs = 10_000)
    withCleanup:
      call.send outReq([314159'i32], payload = 271828)
      call.closeSend()
      check call.recv(resp), "no duplex response"
      check resp.payload.body.len == 314159, "duplex payload size"
      check not call.recv(resp), "extra duplex response"
      check call.headers.get(initialKey) == "test_initial_metadata_value",
            "duplex initial metadata " & $call.headers
      check call.trailers.get(trailingKey) == bin, "duplex trailing metadata"
    do:
      call.close()
  of "client_streaming":
    var call = svc.streamingInputCall(timeoutMs = 10_000)
    withCleanup:
      for n in reqSizes: call.send StreamingInputCallRequest(payload: zeros(n))
      let total = call.closeAndRecv().aggregatedPayloadSize
      check total == 74922, "aggregated " & $total
    do:
      call.close()
  of "server_streaming":
    var call = svc.streamingOutputCall(outReq(respSizes), timeoutMs = 10_000)
    withCleanup:
      for n in respSizes:
        check call.recv(resp), "stream ended early"
        check resp.payload.body.len == n, "size " & $resp.payload.body.len & ", want " & $n
      check not call.recv(resp), "extra response"
    do:
      call.close()
  of "ping_pong":
    var call = svc.fullDuplexCall(timeoutMs = 10_000)
    withCleanup:
      for i in 0 ..< reqSizes.len:
        call.send outReq([respSizes[i]], payload = reqSizes[i])
        check call.recv(resp), "no response to request " & $i
        check resp.payload.body.len == respSizes[i], "size " & $resp.payload.body.len
      call.closeSend()
      check not call.recv(resp), "extra response"
    do:
      call.close()
  of "empty_stream":
    var call = svc.fullDuplexCall(timeoutMs = 10_000)
    withCleanup:
      call.closeSend()
      check not call.recv(resp), "response on an empty stream"
    do:
      call.close()
  of "cancel_after_begin":
    var call = svc.streamingInputCall(timeoutMs = 10_000)
    call.cancel()
    expectCode(proc () = discard call.closeAndRecv(), scCancelled)
  of "cancel_after_first_response":
    var call = svc.fullDuplexCall(timeoutMs = 10_000)
    call.send outReq([31415'i32], payload = 27182)
    check call.recv(resp), "no first response"
    call.cancel()
    expectCode(proc () = discard call.recv(resp), scCancelled)
  of "timeout_on_sleeping_server":
    var call = svc.fullDuplexCall(timeoutMs = 1)
    withCleanup:
      expectCode(proc () =
        call.send outReq([], payload = 27182)
        while call.recv(resp): discard, scDeadlineExceeded)
    do:
      call.close()
  of "client_compressed_unary":
    let req = SimpleRequest(responseSize: 314159, payload: zeros(271828),
                            expectCompressed: BoolValue(value: true))
    if strictCompression:   # probe: the server must notice an uncompressed one
      expectCode(proc () = discard svc.unaryCall(req), scInvalidArgument)
    let r = svc.unaryCall(req, compression = "gzip", timeoutMs = 10_000)
    check r.payload.body.len == 314159, "compressed call: payload size"
    var plain = req
    plain.expectCompressed = BoolValue(value: false)
    check svc.unaryCall(plain, timeoutMs = 10_000).payload.body.len == 314159,
          "uncompressed call: payload size"
  of "server_compressed_unary":
    for compressed in [true, false]:
      var call = svc.ch.newCall("/grpc.testing.TestService/UnaryCall", timeoutMs = 10_000)
      withCleanup:
        call.send SimpleRequest(responseSize: 314159,
                                responseCompressed: BoolValue(value: compressed)).encode
        call.closeSend()
        var raw: seq[byte]
        check call.recv(raw), "no response"
        check SimpleResponse.decode(raw).payload.body.len == 314159, "payload size"
        if compressed or strictCompression:
          check call.lastCompressed == compressed,
                "response compressed: " & $call.lastCompressed & ", want " & $compressed
        check not call.recv(raw), "extra response"
      do:
        call.close()
  of "client_compressed_streaming":
    if strictCompression:
      var probe = svc.streamingInputCall(timeoutMs = 10_000)
      withCleanup:
        expectCode(proc () =
          probe.send StreamingInputCallRequest(payload: zeros(27182),
                                               expectCompressed: BoolValue(value: true))
          discard probe.closeAndRecv(), scInvalidArgument)
      do:
        probe.close()
    var call = svc.streamingInputCall(timeoutMs = 10_000, compression = "gzip")
    withCleanup:
      call.send(StreamingInputCallRequest(payload: zeros(27182),
                                          expectCompressed: BoolValue(value: true)), true)
      call.send(StreamingInputCallRequest(payload: zeros(45904)), false)
      let total = call.closeAndRecv().aggregatedPayloadSize
      check total == 73086, "aggregated " & $total
    do:
      call.close()
  of "server_compressed_streaming":
    var req = StreamingOutputCallRequest()
    req.responseParameters.add ResponseParameters(size: 31415, compressed: BoolValue(value: true))
    req.responseParameters.add ResponseParameters(size: 92653, compressed: BoolValue(value: false))
    var call = svc.streamingOutputCall(req, timeoutMs = 10_000)
    withCleanup:
      check call.recv(resp), "no first response"
      check resp.payload.body.len == 31415 and (call.lastCompressed or not perMessageCompression),
            "first: compressed 31415"
      check call.recv(resp), "no second response"
      check resp.payload.body.len == 92653, "second: size"
      if strictCompression: check not call.lastCompressed, "second must not be compressed"
      check not call.recv(resp), "extra response"
    do:
      call.close()
  of "keepalive_enforced":
    # Not an official case: a channel pinging every 50 ms during a quiet call.
    # A server enforcing gRPC's default policy (one ping per 5 min) answers
    # with GOAWAY too_many_pings; the call fails UNAVAILABLE and the next call
    # works over a new connection.
    let fast = dial(ch.p.host, ch.p.port, ch.p.tls, ch.p.serverName,
                    Keepalive(timeMs: 50, timeoutMs: 2000))
    withCleanup:
      let fsvc = newTestServiceClient(fast)
      var call = fsvc.fullDuplexCall(timeoutMs = 10_000)
      expectCode(proc () = discard call.recv(resp), scUnavailable)
      call.close()
      discard fsvc.emptyCall(Empty(), timeoutMs = 10_000)
    do:
      fast.close()
  else:
    raise newException(ValueError, "unknown case " & name)

const allCases* = ["empty_unary", "large_unary", "client_streaming",
                   "server_streaming", "ping_pong", "empty_stream",
                   "cancel_after_begin", "cancel_after_first_response",
                   "timeout_on_sleeping_server", "status_code_and_message",
                   "special_status_message", "unimplemented_method",
                   "unimplemented_service", "custom_metadata",
                   "client_compressed_unary", "server_compressed_unary",
                   "client_compressed_streaming", "server_compressed_streaming"]

proc runClient*(host: string; port: int; only: seq[string] = @[];
                tls: TlsConfig = nil; serverName = ""): int =
  ## Returns the number of failed cases.
  let ch = dial(host, port, tls, serverName)
  for name in (if only.len > 0: only else: @allCases):
    try:
      ch.runCase(name)
      echo "PASS ", name
    except CatchableError as e:
      echo "FAIL ", name, ": ", e.msg
      inc result
  ch.close()

when isMainModule:
  import std/os
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
    let s = newTestServer(if pos.len >= 2: parseInt(pos[1]) else: 10000, tls, maxMessageOpt)
    s.start()
    echo "listening on ", s.port, (if mode.len > 0: " (" & mode & ")" else: "")
    while true: sleep(1000)
  else:
    let host = if pos.len >= 2: pos[1] else: "127.0.0.1"
    let port = if pos.len >= 3: parseInt(pos[2]) else: 10000
    let only = if pos.len >= 4 and pos[3].len > 0: pos[3].split(',') else: @[]
    let tls = case mode
      of "tls": tlsClientConfig(pem"ca.pem")
      of "mtls": tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key")
      else: nil
    quit(runClient(host, port, only, tls, if tls != nil: serverNameOpt else: ""))
