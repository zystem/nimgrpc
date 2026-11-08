## Server reflection (v1 and v1alpha): services, files, symbols and imports, on both servers.

import std/[unittest, options, strutils]
import pkg/chronos
import nimgrpc
import nimgrpc/[protobuf, reflection]
import nimgrpc/[asyncclient, asyncserver]
from nimgrpc/client as bc import nil
import ./gen/echo_pb

const v1 = "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo"
const v1alpha = "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo"

proc request(field: int; arg: string; host = ""): seq[byte] =
  var w = PbWriter()
  if host.len > 0:
    w.putTag(1, wtLen)
    w.putString(host)
  w.putTag(field, wtLen)
  w.putString(arg)
  w.buf

type Answer = object
  host: string
  original: seq[byte]
  files: seq[seq[byte]]
  services: seq[string]
  extBase: string
  extNumbers: int
  errorCode: int
  errorMessage: string

proc readAnswer(data: seq[byte]): Answer =
  var r = initReader(data)
  while not r.atEnd:
    var f: int
    var wt: WireType
    r.getTag(f, wt)
    case f
    of 1: result.host = r.getString()
    of 2: result.original = r.getBytes()
    of 4:
      var m = initReader(r.getBytes())
      while not m.atEnd:
        var f2: int
        var w2: WireType
        m.getTag(f2, w2)
        if f2 == 1: result.files.add m.getBytes()
        else: m.skipField(w2, f2)
    of 5:
      var m = initReader(r.getBytes())
      while not m.atEnd:
        var f2: int
        var w2: WireType
        m.getTag(f2, w2)
        if f2 == 1: result.extBase = m.getString()
        elif f2 == 2: (discard m.getVarint(); inc result.extNumbers)
        else: m.skipField(w2, f2)
    of 6:
      var m = initReader(r.getBytes())
      while not m.atEnd:
        var f2: int
        var w2: WireType
        m.getTag(f2, w2)
        if f2 == 1:
          var s = initReader(m.getBytes())
          while not s.atEnd:
            var f3: int
            var w3: WireType
            s.getTag(f3, w3)
            if f3 == 1: result.services.add s.getString()
            else: s.skipField(w3, f3)
        else: m.skipField(w2, f2)
    of 7:
      var m = initReader(r.getBytes())
      while not m.atEnd:
        var f2: int
        var w2: WireType
        m.getTag(f2, w2)
        if f2 == 1: result.errorCode = int(m.getVarint())
        elif f2 == 2: result.errorMessage = m.getString()
        else: m.skipField(w2, f2)
    else: r.skipField(wt, f)

proc ask(ch: bc.GrpcChannel; path: string; req: seq[byte]): Answer =
  var call = bc.newCall(ch, path, timeoutMs = 5000)
  bc.send(call, req)
  var msg: seq[byte]
  doAssert bc.recv(call, msg)
  bc.closeSend(call)
  result = readAnswer(msg)
  bc.close(call)

proc sayUnary(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req

proc chat(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} = discard

let echoDescriptor = block:
  var b = newSeq[byte](fileDescriptorProto.len)
  for i, ch in fileDescriptorProto: b[i] = byte(ch)
  b

suite "reflection on the blocking server":
  let refl = newReflection()
  refl.addFileDescriptor(fileDescriptorProto)
  let srv = newGrpcServer()
  srv.addUnary("/reflect.test.Echo/Say", sayUnary)
  srv.addStreaming("/reflect.test.Echo/Chat", chat)
  srv.register(refl)
  srv.start()
  let ch = bc.dial("127.0.0.1", srv.port)

  test "list_services: the registered services, sorted, the reflection services among them":
    let a = ch.ask(v1, request(7, "*", host = "h.example"))
    check a.services == @["grpc.reflection.v1.ServerReflection",
                          "grpc.reflection.v1alpha.ServerReflection", "reflect.test.Echo"]
    check a.host == "h.example"                          # valid_host echoes the host
    check a.original == request(7, "*", host = "h.example")  # and the request comes back
    check ch.ask(v1alpha, request(7, "")).services.len == 3

  test "file_containing_symbol: the file, then what it imports":
    let a = ch.ask(v1, request(4, "reflect.test.Echo"))
    check a.errorCode == 0
    check a.files.len == 2
    check a.files[0] == echoDescriptor
    check a.files[1].len > 0                              # google/protobuf/timestamp.proto
    var r = initReader(a.files[1])
    var f: int
    var wt: WireType
    r.getTag(f, wt)
    check f == 1
    check r.getString() == "google/protobuf/timestamp.proto"

  test "every kind of symbol of the file is found":
    for sym in ["reflect.test.EchoRequest", "reflect.test.EchoReply",
                "reflect.test.EchoRequest.Mood", "reflect.test.EchoRequest.Tag",
                "reflect.test.EchoRequest.text", "reflect.test.EchoRequest.mood",
                "reflect.test.EchoRequest.LOUD", "reflect.test.Echo.Say",
                "reflect.test.Echo.Chat", "google.protobuf.Timestamp"]:
      let a = ch.ask(v1, request(4, sym))
      check a.errorCode == 0
      check a.files.len >= 1
    let miss = ch.ask(v1, request(4, "reflect.test.Nobody"))
    check miss.errorCode == 5                             # NOT_FOUND
    check "reflect.test.Nobody" in miss.errorMessage
    check miss.files.len == 0

  test "file_by_filename, with and without imports; an unknown file is NOT_FOUND":
    check ch.ask(v1, request(3, "echo.proto")).files.len == 2
    check ch.ask(v1, request(3, "google/protobuf/timestamp.proto")).files.len == 1
    check ch.ask(v1, request(3, "nope.proto")).errorCode == 5

  test "all_extension_numbers_of_type: none for a known type, NOT_FOUND for another":
    let a = ch.ask(v1, request(6, "reflect.test.EchoRequest"))
    check a.errorCode == 0
    check a.extBase == "reflect.test.EchoRequest"
    check a.extNumbers == 0
    check ch.ask(v1, request(6, "reflect.test.Nobody")).errorCode == 5

  test "a file that is not a descriptor is refused":
    expect ProtobufError:
      refl.addFileDescriptor(@[0xff'u8, 0xff, 0xff])

  ch.close()
  srv.stop()
  refl.close()

var asyncOut: seq[string]

proc asyncPart(port: int): Future[seq[string]] {.async.} =
  var res: seq[string]
  let ch = await dialAsync("127.0.0.1", port)
  let call = await ch.newCall(v1, timeoutMs = 5000)
  await call.send(request(7, ""))
  var m = await call.recv()
  res.add readAnswer(m.get).services.join(",")
  await call.send(request(4, "reflect.test.Echo"))
  m = await call.recv()
  let a = readAnswer(m.get)
  res.add $a.files.len
  await call.send(request(4, "reflect.test.Nobody"))
  m = await call.recv()
  res.add $readAnswer(m.get).errorCode
  await call.closeSend()
  call.close()
  await ch.close()
  return res

suite "reflection on the chronos server":
  test "list_services, a symbol with its import, and an error, on one stream":
    let refl = newReflection()
    refl.addFileDescriptor(fileDescriptorProto)
    proc say(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} = return req
    let srv = newAsyncGrpcServer()
    srv.addUnary("/reflect.test.Echo/Say", say)
    srv.register(refl)
    srv.start()
    let res = waitFor asyncPart(srv.port)
    check res == @["grpc.reflection.v1.ServerReflection,grpc.reflection.v1alpha.ServerReflection,reflect.test.Echo",
                   "2", "5"]
    waitFor srv.stop()
    refl.close()
