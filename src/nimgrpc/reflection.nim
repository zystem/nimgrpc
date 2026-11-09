## Server reflection (grpc.reflection.v1 and v1alpha) for both servers: `grpcurl` and `grpc_cli`
## can list the services of a server, and describe them when it holds their descriptors.
##
## ```nim
## import nimgrpc, nimgrpc/reflection
## import gen/echo_pb                       # generated with --nim_opt=blocking,descriptor
##
## let refl = newReflection()               # holds the well-known types too
## refl.addFileDescriptor(echo_pb.fileDescriptorProto)
## srv.register(refl)                       # GrpcServer or AsyncGrpcServer, after the services
## ```
##
## `list_services` needs nothing but the methods registered on the server. `file_by_filename`,
## `file_containing_symbol` (messages, enums, fields, services, methods) and
## `all_extension_numbers_of_type` need the descriptors, which `protoc-gen-nim` writes into a
## module when it runs with the option `descriptor` (`fileDescriptorProto`). A file answers
## together with the files it imports that the reflection holds. Extensions are not supported.

import std/[locks, tables, options]
import ./protobuf, ./status, ./server, ./asyncserver, ./wktdescriptors
import pkg/chronos

export status

type
  FileInfo = object
    name: string
    deps: seq[string]
    data: seq[byte]

  ReflectionObj = object
    lock: Lock
    files: Table[string, FileInfo]
    symbols: Table[string, string]       ## full name -> name of the file that declares it
    contexts: seq[pointer]               ## the `ReflContext`s of the blocking servers it was registered with

  Reflection* = object
    ## The descriptors a server can describe: a handle to memory shared by every thread, usable
    ## from any of them. `close` frees it, once no server that registered it is running.
    p: ptr ReflectionObj

  ReflContext = object                   ## what a blocking handler needs, kept for the server's life
    refl: ptr ReflectionObj
    registry: pointer

const
  reflectionPaths = ["/grpc.reflection.v1.ServerReflection/ServerReflectionInfo",
                     "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo"]
  notFoundCode = 5

# ---------------------------------------------------------------- indexing a descriptor

proc readString(r: var PbReader): string = r.getString()

proc indexMessage(r: var PbReader; scope: string; names: var seq[string]) =
  ## DescriptorProto: name (1), field (2), nested_type (3), enum_type (4), extension (6),
  ## oneof_decl (8). The name comes first in what protoc writes; the rest follows it.
  var name = ""
  var fields, nested, enums, oneofs: seq[seq[byte]]
  while not r.atEnd:
    var fieldNo: int
    var wt: WireType
    r.getTag(fieldNo, wt)
    case fieldNo
    of 1: name = r.readString()
    of 2: fields.add r.getBytes()
    of 3: nested.add r.getBytes()
    of 4: enums.add r.getBytes()
    of 8: oneofs.add r.getBytes()
    else: r.skipField(wt, fieldNo)
  let full = if scope.len > 0: scope & "." & name else: name
  names.add full
  for f in fields:
    var fr = initReader(f)
    while not fr.atEnd:
      var fieldNo: int
      var wt: WireType
      fr.getTag(fieldNo, wt)
      if fieldNo == 1: names.add full & "." & fr.readString()
      else: fr.skipField(wt, fieldNo)
  for o in oneofs:
    var orr = initReader(o)
    while not orr.atEnd:
      var fieldNo: int
      var wt: WireType
      orr.getTag(fieldNo, wt)
      if fieldNo == 1: names.add full & "." & orr.readString()
      else: orr.skipField(wt, fieldNo)
  for n in nested:
    var nr = initReader(n)
    indexMessage(nr, full, names)
  for e in enums:
    var er = initReader(e)
    # EnumDescriptorProto: name (1), value (2) { name (1) }; the values live in the enum's scope
    var ename = ""
    var values: seq[string]
    while not er.atEnd:
      var fieldNo: int
      var wt: WireType
      er.getTag(fieldNo, wt)
      case fieldNo
      of 1: ename = er.readString()
      of 2:
        var vr = initReader(er.getBytes())
        while not vr.atEnd:
          var f2: int
          var w2: WireType
          vr.getTag(f2, w2)
          if f2 == 1: values.add vr.readString()
          else: vr.skipField(w2, f2)
      else: er.skipField(wt, fieldNo)
    names.add full & "." & ename
    for v in values: names.add full & "." & v

proc indexFile(data: openArray[byte]): (FileInfo, seq[string]) =
  ## The name, the imports and every symbol a FileDescriptorProto declares. Raises ProtobufError.
  var r = initReader(data)
  var pkg = ""
  var info = FileInfo(data: @data)
  var names: seq[string]
  var messages, enums, services: seq[seq[byte]]
  while not r.atEnd:
    var fieldNo: int
    var wt: WireType
    r.getTag(fieldNo, wt)
    case fieldNo
    of 1: info.name = r.readString()
    of 2: pkg = r.readString()
    of 3: info.deps.add r.readString()
    of 4: messages.add r.getBytes()
    of 5: enums.add r.getBytes()
    of 6: services.add r.getBytes()
    else: r.skipField(wt, fieldNo)
  if info.name.len == 0: raise newException(ProtobufError, "a FileDescriptorProto without a name")
  for m in messages:
    var mr = initReader(m)
    indexMessage(mr, pkg, names)
  for e in enums:
    var er = initReader(e)
    var ename = ""
    var values: seq[string]
    while not er.atEnd:
      var fieldNo: int
      var wt: WireType
      er.getTag(fieldNo, wt)
      case fieldNo
      of 1: ename = er.readString()
      of 2:
        var vr = initReader(er.getBytes())
        while not vr.atEnd:
          var f2: int
          var w2: WireType
          vr.getTag(f2, w2)
          if f2 == 1: values.add vr.readString()
          else: vr.skipField(w2, f2)
      else: er.skipField(wt, fieldNo)
    let scope = if pkg.len > 0: pkg & "." else: ""
    names.add scope & ename
    for v in values: names.add scope & v          # file-level enum values sit next to the enum
  for sv in services:
    var sr = initReader(sv)
    var sname = ""
    var methods: seq[string]
    while not sr.atEnd:
      var fieldNo: int
      var wt: WireType
      sr.getTag(fieldNo, wt)
      case fieldNo
      of 1: sname = sr.readString()
      of 2:
        var mr = initReader(sr.getBytes())
        while not mr.atEnd:
          var f2: int
          var w2: WireType
          mr.getTag(f2, w2)
          if f2 == 1: methods.add mr.readString()
          else: mr.skipField(w2, f2)
      else: sr.skipField(wt, fieldNo)
    let full = if pkg.len > 0: pkg & "." & sname else: sname
    names.add full
    for m in methods: names.add full & "." & m
  (info, names)

# ---------------------------------------------------------------- the registry

proc newReflection*(wellKnownTypes = true): Reflection =
  ## An empty reflection; with `wellKnownTypes` it holds google/protobuf/*.proto, which messages
  ## that use a Timestamp or an Any import.
  let p = createShared(ReflectionObj)
  initLock(p.lock)
  result = Reflection(p: p)
  if wellKnownTypes:
    for (name, data) in wellKnownDescriptors:
      var bytes = newSeq[byte](data.len)
      for i, ch in data: bytes[i] = byte(ch)
      let (info, symbols) = indexFile(bytes)
      p.files[info.name] = info
      for s in symbols: p.symbols[s] = info.name

proc addFileDescriptor*(r: Reflection; fileDescriptorProto: openArray[byte]) =
  ## Adds a serialized FileDescriptorProto (the constant `fileDescriptorProto` of a module
  ## generated with the `descriptor` option). Raises ProtobufError for something that is not one.
  let (info, symbols) = indexFile(fileDescriptorProto)
  acquire(r.p.lock)
  r.p.files[info.name] = info
  for s in symbols: r.p.symbols[s] = info.name
  release(r.p.lock)

proc addFileDescriptor*(r: Reflection; fileDescriptorProto: string) =
  ## The same for the string constant that `protoc-gen-nim` writes.
  var bytes = newSeq[byte](fileDescriptorProto.len)
  for i, ch in fileDescriptorProto: bytes[i] = byte(ch)
  r.addFileDescriptor(bytes)

proc close*(r: Reflection) =
  ## Frees the reflection. Only when no server that registered it is running.
  deinitLock(r.p.lock)
  for c in r.p.contexts: deallocShared(c)
  `=destroy`(r.p[])
  deallocShared(r.p)

proc filesWithDeps(r: ptr ReflectionObj; first: string): seq[seq[byte]] =
  ## The file, then the files it imports (transitively, each once) that the reflection holds.
  var seen: seq[string]
  var stack = @[first]
  acquire(r.lock)
  while stack.len > 0:
    let name = stack.pop()
    if name in seen or name notin r.files: continue
    seen.add name
    let info = r.files.getOrDefault(name)
    result.add info.data
    for i in countdown(info.deps.high, 0): stack.add info.deps[i]
  release(r.lock)

# ---------------------------------------------------------------- the messages

type
  RequestKind = enum rkNone, rkFile, rkSymbol, rkExtension, rkExtensionNumbers, rkServices

  Request = object
    host: string
    kind: RequestKind
    arg: string

proc parseRequest(data: seq[byte]): Request {.raises: [ProtobufError].} =
  ## ServerReflectionRequest: host (1), file_by_filename (3), file_containing_symbol (4),
  ## file_containing_extension (5), all_extension_numbers_of_type (6), list_services (7).
  var r = initReader(data)
  while not r.atEnd:
    var fieldNo: int
    var wt: WireType
    r.getTag(fieldNo, wt)
    case fieldNo
    of 1: result.host = r.getString()
    of 3: (result.kind = rkFile; result.arg = r.getString())
    of 4: (result.kind = rkSymbol; result.arg = r.getString())
    of 5: (result.kind = rkExtension; discard r.getBytes())
    of 6: (result.kind = rkExtensionNumbers; result.arg = r.getString())
    of 7: (result.kind = rkServices; result.arg = r.getString())
    else: r.skipField(wt, fieldNo)

proc errorResponse(code: int; message: string): seq[byte] =
  var e = PbWriter()
  e.putTag(1, wtVarint)
  e.putVarint(uint64(code))
  e.putTag(2, wtLen)
  e.putString(message)
  var w = PbWriter()
  w.putTag(7, wtLen)
  w.putBytes(e.buf)
  w.buf

proc filesResponse(files: seq[seq[byte]]): seq[byte] =
  var m = PbWriter()
  for f in files:
    m.putTag(1, wtLen)
    m.putBytes(f)
  var w = PbWriter()
  w.putTag(4, wtLen)
  w.putBytes(m.buf)
  w.buf

proc servicesResponse(names: seq[string]): seq[byte] =
  var m = PbWriter()
  for n in names:
    var s = PbWriter()
    s.putTag(1, wtLen)
    s.putString(n)
    m.putTag(1, wtLen)
    m.putBytes(s.buf)
  var w = PbWriter()
  w.putTag(6, wtLen)
  w.putBytes(m.buf)
  w.buf

proc extensionNumbersResponse(baseType: string): seq[byte] =
  var m = PbWriter()
  m.putTag(1, wtLen)
  m.putString(baseType)
  var w = PbWriter()
  w.putTag(5, wtLen)
  w.putBytes(m.buf)
  w.buf

proc answer(refl: ptr ReflectionObj; services: seq[string]; raw: seq[byte]): seq[byte] =
  ## ServerReflectionResponse for one request: valid_host (1), original_request (2), and one of
  ## file_descriptor_response (4), all_extension_numbers_response (5), list_services_response (6),
  ## error_response (7).
  var req: Request
  var body: seq[byte]
  try:
    req = parseRequest(raw)
  except ProtobufError as e:
    body = errorResponse(3, "bad request: " & e.msg)       # INVALID_ARGUMENT
  if body.len == 0:
    case req.kind
    of rkServices: body = servicesResponse(services)
    of rkFile:
      let files = filesWithDeps(refl, req.arg)
      body = if files.len > 0: filesResponse(files)
             else: errorResponse(notFoundCode, "file not found: " & req.arg)
    of rkSymbol:
      acquire(refl.lock)
      let file = refl.symbols.getOrDefault(req.arg)
      release(refl.lock)
      let files = if file.len > 0: filesWithDeps(refl, file) else: @[]
      body = if files.len > 0: filesResponse(files)
             else: errorResponse(notFoundCode, "symbol not found: " & req.arg)
    of rkExtensionNumbers:
      acquire(refl.lock)
      let known = req.arg in refl.symbols
      release(refl.lock)
      body = if known: extensionNumbersResponse(req.arg)   # no extension is declared
             else: errorResponse(notFoundCode, "type not found: " & req.arg)
    of rkExtension: body = errorResponse(notFoundCode, "extensions are not supported")
    of rkNone: body = errorResponse(12, "the request names no method")   # UNIMPLEMENTED
  var w = PbWriter()
  if req.host.len > 0:
    w.putTag(1, wtLen)
    w.putString(req.host)
  w.putTag(2, wtLen)
  w.putBytes(raw)
  w.buf.add body
  w.buf

# ---------------------------------------------------------------- the blocking server

proc rawInfo(ctx: var ServerContext; call: var ServerCall; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  let c = cast[ptr ReflContext](userData)
  var msg: seq[byte]
  while call.recv(msg):
    call.send(answer(c.refl, servicesIn(c.registry), msg))

proc register*(srv: GrpcServer; r: Reflection) =
  ## Adds the reflection service (v1 and v1alpha) to a blocking server. Register it after the
  ## services, or they are missing from `list_services` of a server that is already running;
  ## the reflection service lists itself, as grpc-go's does.
  let c = createShared(ReflContext)
  c.refl = r.p
  c.registry = srv.registryHandle()
  acquire(r.p.lock)
  r.p.contexts.add c
  release(r.p.lock)
  for path in reflectionPaths: srv.addStreamingRaw(path, rawInfo, cast[pointer](c))

# ---------------------------------------------------------------- the chronos server

proc register*(srv: AsyncGrpcServer; r: Reflection) =
  ## Adds the reflection service (v1 and v1alpha) to a chronos server.
  let refl = r.p
  proc info(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
    while true:
      let m = await call.recv()
      if m.isNone: break
      await call.send(answer(refl, srv.serviceNames(), m.get))
  for path in reflectionPaths: srv.addStreaming(path, info)
