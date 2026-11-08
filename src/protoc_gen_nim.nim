## protoc-gen-nim: generates Nim code for Protobuf messages and gRPC services.
##
##   nim c -d:release src/protoc_gen_nim.nim
##   protoc --plugin=protoc-gen-nim=src/protoc_gen_nim --nim_out=OUT -I. a/b.proto
##
## For `a/b.proto` it writes `OUT/a/b_pb.nim`: one module per .proto file,
## importing the modules of the files it imports. Generate every file a
## generated module depends on, except google/protobuf/*.proto: those come
## with this package (`nimgrpc/wkt`). Code that reads `Option` or `Table` fields
## imports std/options and std/tables itself (the generated modules do not
## re-export them).
##
## Mapping:
## * message      -> object; nested `Outer.Inner` -> `Outer_Inner`
## * enum         -> `distinct int32` plus `Enum_VALUE` constants (proto3 enums
##                   are open: unknown values survive a round trip)
## * scalar       -> its Nim type; `optional` and proto2 fields -> `Option[T]`
##                   (written `options.Option` in generated code, so a proto
##                   message called `Option` does not clash)
## * message field-> the value plus `has<Field>`; a field whose type can contain
##                   the message itself -> `ref T` (nil when absent)
## * repeated     -> `seq[T]` (packed per the proto rules; both forms decoded)
## * map<K, V>    -> `Table[K, V]`
## * oneof        -> its members as presence-tracked fields; decoding one clears
##                   the others
## * service      -> `<Service>Client` with a proc per method, and
##                   `<Service>Handlers` + `register<Service>` for servers;
##                   with `--nim_opt=async` (or `blocking,async`) the chronos
##                   twins `<Service>AsyncClient` and `<Service>AsyncHandlers`
##
## Not supported: groups (skipped on decode), extensions, proto2 default
## values, preserving unknown fields.

import std/[strutils, tables, sets, os, options]
import nimgrpc/protobuf

# ================================================================ descriptors

type
  FieldType = enum
    ftNone = 0, ftDouble = 1, ftFloat, ftInt64, ftUint64, ftInt32, ftFixed64,
    ftFixed32, ftBool, ftString, ftGroup, ftMessage, ftBytes, ftUint32, ftEnum,
    ftSfixed32, ftSfixed64, ftSint32, ftSint64

  FieldDesc = object
    name: string
    number: int
    label: int                 # 1 optional, 2 required, 3 repeated
    typ: FieldType
    typeName: string           # ".pkg.Msg" for messages and enums
    oneofIndex: int            # -1 if none
    proto3Optional: bool
    packed: Option[bool]

  EnumDesc = object
    name: string
    values: seq[(string, int32)]

  MessageDesc = object
    name: string
    fields: seq[FieldDesc]
    nested: seq[MessageDesc]
    enums: seq[EnumDesc]
    oneofs: seq[string]
    mapEntry: bool

  MethodDesc = object
    name, input, output: string
    clientStreaming, serverStreaming: bool

  ServiceDesc = object
    name: string
    methods: seq[MethodDesc]

  FileDesc = object
    name, package, syntax: string
    deps: seq[string]
    messages: seq[MessageDesc]
    enums: seq[EnumDesc]
    services: seq[ServiceDesc]
    raw: seq[byte]       ## the FileDescriptorProto as protoc sent it

template readFields(r: var PbReader; body: untyped) =
  while not r.atEnd:
    var fieldNo {.inject.}: int
    var wt {.inject.}: WireType
    r.getTag(fieldNo, wt)
    body

proc parseEnum(r: var PbReader): EnumDesc =
  readFields(r):
    case fieldNo
    of 1: result.name = r.getString()
    of 2:
      var v = r.subReader()
      var name = ""
      var num = 0'i32
      readFields(v):
        case fieldNo
        of 1: name = v.getString()
        of 2: num = cast[int32](uint32(v.getVarint() and 0xffff_ffff'u64))
        else: v.skipField(wt, fieldNo)
      result.values.add (name, num)
    else: r.skipField(wt, fieldNo)

proc parseField(r: var PbReader): FieldDesc =
  result.oneofIndex = -1
  readFields(r):
    case fieldNo
    of 1: result.name = r.getString()
    of 3: result.number = int(r.getVarint())
    of 4: result.label = int(r.getVarint())
    of 5: result.typ = FieldType(int(r.getVarint()))
    of 6: result.typeName = r.getString()
    of 9: result.oneofIndex = int(r.getVarint())
    of 17: result.proto3Optional = r.getVarint() != 0
    of 8:
      var o = r.subReader()
      readFields(o):
        if fieldNo == 2 and wt == wtVarint: result.packed = some(o.getVarint() != 0)
        else: o.skipField(wt, fieldNo)
    else: r.skipField(wt, fieldNo)

proc parseMessage(r: var PbReader): MessageDesc =
  readFields(r):
    case fieldNo
    of 1: result.name = r.getString()
    of 2:
      var s = r.subReader()
      result.fields.add parseField(s)
    of 3:
      var s = r.subReader()
      result.nested.add parseMessage(s)
    of 4:
      var s = r.subReader()
      result.enums.add parseEnum(s)
    of 7:
      var o = r.subReader()
      readFields(o):
        if fieldNo == 7 and wt == wtVarint: result.mapEntry = o.getVarint() != 0
        else: o.skipField(wt, fieldNo)
    of 8:
      var o = r.subReader()
      readFields(o):
        if fieldNo == 1: result.oneofs.add o.getString()
        else: o.skipField(wt, fieldNo)
    else: r.skipField(wt, fieldNo)

proc parseService(r: var PbReader): ServiceDesc =
  readFields(r):
    case fieldNo
    of 1: result.name = r.getString()
    of 2:
      var m = r.subReader()
      var md: MethodDesc
      readFields(m):
        case fieldNo
        of 1: md.name = m.getString()
        of 2: md.input = m.getString()
        of 3: md.output = m.getString()
        of 5: md.clientStreaming = m.getVarint() != 0
        of 6: md.serverStreaming = m.getVarint() != 0
        else: m.skipField(wt, fieldNo)
      result.methods.add md
    else: r.skipField(wt, fieldNo)

proc withoutSourceInfo(raw: seq[byte]): seq[byte] =
  ## The FileDescriptorProto without `source_code_info` (field 9: the comments and positions that
  ## protoc adds for plugins), which a reflection client has no use for.
  var r = initReader(raw)
  while not r.atEnd:
    let start = r.pos
    var fieldNo: int
    var wt: WireType
    r.getTag(fieldNo, wt)
    r.skipField(wt, fieldNo)
    if fieldNo != 9: result.add raw.toOpenArray(start, r.pos - 1)

proc parseFile(r: var PbReader): FileDesc =
  readFields(r):
    case fieldNo
    of 1: result.name = r.getString()
    of 2: result.package = r.getString()
    of 3: result.deps.add r.getString()
    of 4:
      var s = r.subReader()
      result.messages.add parseMessage(s)
    of 5:
      var s = r.subReader()
      result.enums.add parseEnum(s)
    of 6:
      var s = r.subReader()
      result.services.add parseService(s)
    of 12: result.syntax = r.getString()
    else: r.skipField(wt, fieldNo)

# ================================================================ naming

const nimKeywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case",
  "cast", "concept", "const", "continue", "converter", "defer", "discard",
  "distinct", "div", "do", "elif", "else", "end", "enum", "except", "export",
  "finally", "for", "from", "func", "if", "import", "in", "include", "interface",
  "is", "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
  "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref", "return",
  "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var",
  "when", "while", "xor", "yield", "result"]

proc camel(s: string; upperFirst = false): string =
  ## snake_case -> camelCase; leading/trailing/doubled underscores dropped
  ## (Nim identifiers cannot have them).
  var up = upperFirst
  for ch in s:
    if ch == '_':
      up = result.len > 0
    elif up:
      result.add ch.toUpperAscii
      up = false
    else:
      result.add ch
  if result.len == 0: result = "x"
  if result[0] in Digits: result = "f" & result

proc ident(s: string): string =
  ## A Nim identifier for a proto field or method name: lowerCamelCase.
  result = camel(s)
  result[0] = result[0].toLowerAscii
  if result.normalize in nimKeywords: result = "`" & result & "`"

proc typeIdent(path: seq[string]): string =
  ## Type name for a (possibly nested) message or enum.
  for i, p in path:
    if i > 0: result.add "_"
    result.add camel(p, upperFirst = true).replace("_", "")
  if result.normalize in nimKeywords: result = "`" & result & "`"

proc constIdent(enumName, value: string): string =
  ## `PayloadType` + `COMPRESSABLE` -> `PayloadType_COMPRESSABLE`
  var v = ""
  for ch in value:
    if ch == '_':
      if v.len > 0 and v[^1] != '_': v.add '_'
    else: v.add ch
  v = v.strip(chars = {'_'})
  if v.len == 0: v = "X"
  enumName.strip(chars = {'`'}) & "_" & v

proc moduleOf(protoFile: string): string =
  ## "a/b.proto" -> "a/b_pb"
  protoFile.changeFileExt("") & "_pb"

# ================================================================ type registry

type
  TypeInfo = object
    nimName: string
    file: string
    isEnum: bool
    msg: ptr MessageDesc       # nil for enums

  Registry = object
    types: Table[string, TypeInfo]     # ".pkg.Outer.Inner" -> info

proc register(reg: var Registry; file: string; prefix: string; path: seq[string];
              m: var MessageDesc) =
  let full = prefix & "." & m.name
  let p = path & m.name
  reg.types[full] = TypeInfo(nimName: typeIdent(p), file: file, msg: m.addr)
  for e in m.enums:
    reg.types[full & "." & e.name] = TypeInfo(nimName: typeIdent(p & e.name),
                                              file: file, isEnum: true)
  for n in m.nested.mitems:
    reg.register(file, full, p, n)

proc buildRegistry(files: var seq[FileDesc]): Registry =
  for f in files.mitems:
    let prefix = if f.package.len > 0: "." & f.package else: ""
    for e in f.enums:
      result.types[prefix & "." & e.name] = TypeInfo(nimName: typeIdent(@[e.name]),
                                                      file: f.name, isEnum: true)
    for m in f.messages.mitems:
      result.register(f.name, prefix, @[], m)

proc canReach(reg: Registry; fromType, target: string; seen: var HashSet[string]): bool =
  ## True if a value of `fromType` can contain a `target` through singular
  ## message fields; such a field must be a `ref`.
  if fromType == target: return true
  if fromType in seen: return false
  seen.incl fromType
  let info = reg.types.getOrDefault(fromType)
  if info.msg == nil: return false
  for f in info.msg[].fields:
    if f.typ == ftMessage and f.label != 3:
      if reg.canReach(f.typeName, target, seen): return true
  false

# ================================================================ code generation

type
  Gen = object
    reg: Registry
    file: ptr FileDesc
    proto3: bool
    typesOut, procsOut, fwdOut: seq[string]

proc nimScalar(t: FieldType): string =
  case t
  of ftDouble: "float64"
  of ftFloat: "float32"
  of ftInt64, ftSint64, ftSfixed64: "int64"
  of ftUint64, ftFixed64: "uint64"
  of ftInt32, ftSint32, ftSfixed32: "int32"
  of ftUint32, ftFixed32: "uint32"
  of ftBool: "bool"
  of ftString: "string"
  of ftBytes: "seq[byte]"
  else: ""

proc wireOf(t: FieldType): string =
  case t
  of ftDouble, ftFixed64, ftSfixed64: "wt64"
  of ftFloat, ftFixed32, ftSfixed32: "wt32"
  of ftString, ftBytes, ftMessage: "wtLen"
  of ftGroup: "wtStartGroup"
  else: "wtVarint"

proc packable(t: FieldType): bool = t notin {ftString, ftBytes, ftMessage, ftGroup}

proc typeRef(g: Gen; protoName: string): string =
  ## A message or enum type as written in this module: qualified with its
  ## module when it comes from another file, so it cannot clash with names
  ## from std (google.protobuf.Option against options.Option, say).
  let info = g.reg.types[protoName]
  if info.file == g.file.name: info.nimName
  else: moduleOf(info.file).extractFilename & "." & info.nimName.strip(chars = {'`'})

proc nimType(g: Gen; f: FieldDesc): string =
  case f.typ
  of ftMessage, ftEnum: g.typeRef(f.typeName)
  else: nimScalar(f.typ)

proc writeValue(t: FieldType; v, w: string): string =
  ## Code writing value `v` (no tag) to writer `w`.
  case t
  of ftInt32: w & ".putVarint(cast[uint64](int64(" & v & ")))"
  of ftEnum: w & ".putVarint(cast[uint64](int64(int32(" & v & "))))"
  of ftInt64: w & ".putVarint(cast[uint64](" & v & "))"
  of ftUint32, ftUint64: w & ".putVarint(uint64(" & v & "))"
  of ftSint32: w & ".putVarint(zigzag32(" & v & "))"
  of ftSint64: w & ".putVarint(zigzag64(" & v & "))"
  of ftBool: w & ".putVarint(uint64(ord(" & v & ")))"
  of ftFixed32: w & ".putFixed32(" & v & ")"
  of ftSfixed32: w & ".putFixed32(cast[uint32](" & v & "))"
  of ftFloat: w & ".putFixed32(cast[uint32](" & v & "))"
  of ftFixed64: w & ".putFixed64(" & v & ")"
  of ftSfixed64: w & ".putFixed64(cast[uint64](" & v & "))"
  of ftDouble: w & ".putFixed64(cast[uint64](" & v & "))"
  of ftString: w & ".putString(" & v & ")"
  of ftBytes: w & ".putBytes(" & v & ")"
  of ftMessage:
    "(let ms = " & w & ".beginLen(); encodeInto(" & v & ", " & w & "); " & w & ".endLen(ms))"
  else: "discard"

proc readValue(g: Gen; f: FieldDesc; r: string): string =
  ## Expression reading one value of `f`'s type from reader `r`.
  case f.typ
  of ftInt32: "cast[int32](uint32(" & r & ".getVarint() and 0xffff_ffff'u64))"
  of ftEnum: g.nimType(f) & "(cast[int32](uint32(" & r & ".getVarint() and 0xffff_ffff'u64)))"
  of ftInt64: "cast[int64](" & r & ".getVarint())"
  of ftUint32: "uint32(" & r & ".getVarint() and 0xffff_ffff'u64)"
  of ftUint64: r & ".getVarint()"
  of ftSint32: "unzigzag32(" & r & ".getVarint())"
  of ftSint64: "unzigzag64(" & r & ".getVarint())"
  of ftBool: "(" & r & ".getVarint() != 0)"
  of ftFixed32: r & ".getFixed32()"
  of ftSfixed32: "cast[int32](" & r & ".getFixed32())"
  of ftFloat: "cast[float32](" & r & ".getFixed32())"
  of ftFixed64: r & ".getFixed64()"
  of ftSfixed64: "cast[int64](" & r & ".getFixed64())"
  of ftDouble: "cast[float64](" & r & ".getFixed64())"
  of ftString: r & ".getString()"
  of ftBytes: r & ".getBytes()"
  else: "default(" & g.nimType(f) & ")"

proc isZero(t: FieldType; v: string): string =
  case t
  of ftString, ftBytes: v & ".len == 0"
  of ftBool: "not " & v
  of ftEnum: "int32(" & v & ") == 0"
  of ftFloat, ftDouble:
    # -0.0 is not "zero" for presence: compare bits, as protoc does.
    "cast[uint64](float64(" & v & ")) == 0"
  else: v & " == 0"

type FieldShape = enum
  fsPlain       # implicit presence scalar
  fsOption      # Option[T]
  fsMessage     # T + has flag
  fsRefMessage  # ref T
  fsRepeated    # seq[T]
  fsMap         # Table[K, V]

proc mapEntry(g: Gen; f: FieldDesc): ptr MessageDesc =
  if f.typ == ftMessage and f.label == 3:
    let info = g.reg.types.getOrDefault(f.typeName)
    if info.msg != nil and info.msg[].mapEntry: return info.msg
  nil

proc shape(g: Gen; owner: string; f: FieldDesc): FieldShape =
  if g.mapEntry(f) != nil: return fsMap
  if f.label == 3: return fsRepeated
  if f.typ == ftMessage:
    var seen: HashSet[string]
    return if g.reg.canReach(f.typeName, owner, seen): fsRefMessage else: fsMessage
  if f.proto3Optional or f.oneofIndex >= 0 or not g.proto3: return fsOption
  fsPlain

proc hasName(f: FieldDesc): string = "has" & camel(f.name, upperFirst = true)

proc isPacked(g: Gen; f: FieldDesc): bool =
  f.typ.packable and (if f.packed.isSome: f.packed.get else: g.proto3)

proc genEnum(g: var Gen; path: seq[string]; e: EnumDesc) =
  let n = typeIdent(path)
  g.typesOut.add "  " & n & "* = distinct int32"
  var consts = @["const"]
  var seen: HashSet[int32]
  for (vn, vv) in e.values:
    consts.add "  " & constIdent(n, vn) & "* = " & n & "(" & $vv & ")"
  g.procsOut.add consts.join("\n")
  var names = @["func `$`*(v: " & n & "): string =", "  case int32(v)"]
  for (vn, vv) in e.values:
    if vv in seen: continue      # allow_alias: first name wins
    seen.incl vv
    names.add "  of " & $vv & ": \"" & vn & "\""
  names.add "  else: \"" & n & "(\" & $int32(v) & \")\""
  g.procsOut.add names.join("\n")
  g.procsOut.add "func `==`*(a, b: " & n & "): bool {.borrow.}"

proc genMessage(g: var Gen; prefix: string; path: seq[string]; m: MessageDesc) =
  let full = prefix & "." & m.name
  let p = path & m.name
  for e in m.enums: g.genEnum(p & e.name, e)
  for n in m.nested:
    if not n.mapEntry: g.genMessage(full, p, n)
  if m.mapEntry: return
  let n = typeIdent(p)

  # ---- type
  var t = @["  " & n & "* = object"]
  if m.fields.len == 0: t.add "    discard"
  for f in m.fields:
    let fname = ident(f.name)
    case g.shape(full, f)
    of fsPlain: t.add "    " & fname & "*: " & g.nimType(f)
    of fsOption: t.add "    " & fname & "*: options.Option[" & g.nimType(f) & "]"
    of fsMessage:
      t.add "    " & fname & "*: " & g.nimType(f)
      t.add "    " & f.hasName & "*: bool  ## set when decoded; see `encode`"
    of fsRefMessage: t.add "    " & fname & "*: ref " & g.nimType(f)
    of fsRepeated: t.add "    " & fname & "*: seq[" & g.nimType(f) & "]"
    of fsMap:
      let e = g.mapEntry(f)
      var kf, vf: FieldDesc
      for ef in e[].fields:
        if ef.number == 1: kf = ef
        elif ef.number == 2: vf = ef
      t.add "    " & fname & "*: tables.Table[" & g.nimType(kf) & ", " & g.nimType(vf) & "]"
  g.typesOut.add t.join("\n")

  g.fwdOut.add "func isEmpty*(m: " & n & "): bool {.raises: [].}"
  g.fwdOut.add "proc encodeInto*(m: " & n & "; w: var PbWriter) {.raises: [], gcsafe.}"
  g.fwdOut.add "proc decodeFrom*(m: var " & n & "; r: var PbReader) {.raises: [ProtobufError], gcsafe.}"

  # ---- isEmpty
  var ie = @["func isEmpty*(m: " & n & "): bool {.raises: [].} =",
             "  ## True if encoding `m` would write nothing."]
  var conds: seq[string]
  for f in m.fields:
    let fname = "m." & ident(f.name)
    case g.shape(full, f)
    of fsPlain: conds.add isZero(f.typ, fname)
    of fsOption: conds.add fname & ".isNone"
    of fsMessage: conds.add "not m." & f.hasName & " and isEmpty(" & fname & ")"
    of fsRefMessage: conds.add fname & " == nil"
    of fsRepeated, fsMap: conds.add fname & ".len == 0"
  if conds.len == 0: ie.add "  true"
  else: ie.add "  (" & conds.join(") and\n    (") & ")"
  g.procsOut.add ie.join("\n")

  # ---- encode
  var e = @["proc encodeInto*(m: " & n & "; w: var PbWriter) {.raises: [], gcsafe.} =",
            "  ## Writes the fields of `m` (no length prefix)."]
  if m.fields.len == 0: e.add "  discard"
  for f in m.fields:
    let fname = "m." & ident(f.name)
    let num = $f.number
    let tag = "w.putTag(" & num & ", " & wireOf(f.typ) & ")"
    case g.shape(full, f)
    of fsPlain:
      e.add "  if not (" & isZero(f.typ, fname) & "):"
      e.add "    " & tag & "; " & writeValue(f.typ, fname, "w")
    of fsOption:
      e.add "  if " & fname & ".isSome:"
      e.add "    " & tag & "; " & writeValue(f.typ, fname & ".get", "w")
    of fsMessage:
      e.add "  if m." & f.hasName & " or not isEmpty(" & fname & "):"
      e.add "    " & tag & "; " & writeValue(f.typ, fname, "w")
    of fsRefMessage:
      e.add "  if " & fname & " != nil:"
      e.add "    " & tag & "; " & writeValue(f.typ, fname & "[]", "w")
    of fsRepeated:
      if g.isPacked(f):
        e.add "  if " & fname & ".len > 0:"
        e.add "    w.putTag(" & num & ", wtLen)"
        e.add "    let s = w.beginLen()"
        e.add "    for v in " & fname & ": " & writeValue(f.typ, "v", "w")
        e.add "    w.endLen(s)"
      else:
        e.add "  for v in " & fname & ":"
        e.add "    " & tag & "; " & writeValue(f.typ, "v", "w")
    of fsMap:
      let me = g.mapEntry(f)
      var kf, vf: FieldDesc
      for ef in me[].fields:
        if ef.number == 1: kf = ef
        elif ef.number == 2: vf = ef
      e.add "  for k, v in " & fname & ":"
      e.add "    w.putTag(" & num & ", wtLen)"
      e.add "    let s = w.beginLen()"
      e.add "    w.putTag(1, " & wireOf(kf.typ) & "); " & writeValue(kf.typ, "k", "w")
      e.add "    w.putTag(2, " & wireOf(vf.typ) & "); " & writeValue(vf.typ, "v", "w")
      e.add "    w.endLen(s)"
  g.procsOut.add e.join("\n")

  # ---- decode
  var d = @["proc decodeFrom*(m: var " & n & "; r: var PbReader) {.raises: [ProtobufError], gcsafe.} =",
            "  ## Reads fields into `m`, merging as Protobuf specifies.",
            "  while not r.atEnd:",
            "    var field: int",
            "    var wt: WireType",
            "    r.getTag(field, wt)",
            "    case field"]
  # oneof siblings, to clear on set
  var oneofMembers: Table[int, seq[FieldDesc]]
  for f in m.fields:
    if f.oneofIndex >= 0 and not f.proto3Optional:
      oneofMembers.mgetOrPut(f.oneofIndex, @[]).add f
  proc clearOthers(g: Gen; f: FieldDesc): seq[string] =
    if f.oneofIndex < 0 or f.proto3Optional: return
    for o in oneofMembers.getOrDefault(f.oneofIndex):
      if o.number == f.number: continue
      case g.shape(full, o)
      of fsOption: result.add "m." & ident(o.name) & " = options.none(" & g.nimType(o) & ")"
      of fsMessage:
        result.add "m." & ident(o.name) & " = default(" & g.nimType(o) & ")"
        result.add "m." & o.hasName & " = false"
      of fsRefMessage: result.add "m." & ident(o.name) & " = nil"
      else: discard
  for f in m.fields:
    let fname = "m." & ident(f.name)
    let wire = wireOf(f.typ)
    d.add "    of " & $f.number & ":"
    for c in g.clearOthers(f): d.add "      " & c
    case g.shape(full, f)
    of fsPlain:
      d.add "      if wt == " & wire & ": " & fname & " = " & g.readValue(f, "r")
      d.add "      else: r.skipField(wt, field)"
    of fsOption:
      d.add "      if wt == " & wire & ": " & fname & " = options.some(" & g.readValue(f, "r") & ")"
      d.add "      else: r.skipField(wt, field)"
    of fsMessage:
      d.add "      if wt == wtLen:"
      d.add "        var sub = r.subReader()"
      d.add "        decodeFrom(" & fname & ", sub)"
      d.add "        m." & f.hasName & " = true"
      d.add "      else: r.skipField(wt, field)"
    of fsRefMessage:
      d.add "      if wt == wtLen:"
      d.add "        if " & fname & " == nil: " & fname & " = new(" & g.nimType(f) & ")"
      d.add "        var sub = r.subReader()"
      d.add "        decodeFrom(" & fname & "[], sub)"
      d.add "      else: r.skipField(wt, field)"
    of fsRepeated:
      if f.typ == ftMessage:
        d.add "      if wt == wtLen:"
        d.add "        var sub = r.subReader()"
        d.add "        var v: " & g.nimType(f)
        d.add "        decodeFrom(v, sub)"
        d.add "        " & fname & ".add v"
        d.add "      else: r.skipField(wt, field)"
      elif f.typ.packable:
        d.add "      if wt == wtLen:"
        d.add "        var sub = r.subReader()"
        d.add "        while not sub.atEnd: " & fname & ".add " & g.readValue(f, "sub")
        d.add "      elif wt == " & wire & ": " & fname & ".add " & g.readValue(f, "r")
        d.add "      else: r.skipField(wt, field)"
      else:
        d.add "      if wt == " & wire & ": " & fname & ".add " & g.readValue(f, "r")
        d.add "      else: r.skipField(wt, field)"
    of fsMap:
      let me = g.mapEntry(f)
      var kf, vf: FieldDesc
      for ef in me[].fields:
        if ef.number == 1: kf = ef
        elif ef.number == 2: vf = ef
      d.add "      if wt == wtLen:"
      d.add "        var sub = r.subReader()"
      d.add "        var k: " & g.nimType(kf)
      d.add "        var v: " & g.nimType(vf)
      d.add "        while not sub.atEnd:"
      d.add "          var ef: int"
      d.add "          var ewt: WireType"
      d.add "          sub.getTag(ef, ewt)"
      d.add "          if ef == 1 and ewt == " & wireOf(kf.typ) & ": k = " & g.readValue(kf, "sub")
      if vf.typ == ftMessage:
        d.add "          elif ef == 2 and ewt == wtLen:"
        d.add "            var vs = sub.subReader()"
        d.add "            decodeFrom(v, vs)"
      else:
        d.add "          elif ef == 2 and ewt == " & wireOf(vf.typ) & ": v = " & g.readValue(vf, "sub")
      d.add "          else: sub.skipField(ewt, ef)"
      d.add "        " & fname & "[k] = v"
      d.add "      else: r.skipField(wt, field)"
  d.add "    else: r.skipField(wt, field)"
  g.procsOut.add d.join("\n")

  g.procsOut.add "func protoName*(_: typedesc[" & n & "]): string = \"" &
    full[1 .. ^1] & "\"\n  ## The fully qualified Protobuf name (for google.protobuf.Any)."
  g.procsOut.add "proc encode*(m: " & n & "): seq[byte] {.raises: [], gcsafe.} =\n" &
    "  ## The wire form of `m`. A message-typed field is written when its\n" &
    "  ## `has` flag is set or its value differs from the default.\n" &
    "  var w: PbWriter\n  encodeInto(m, w)\n  move w.buf"
  g.procsOut.add "proc decode*(_: typedesc[" & n & "]; data: openArray[byte]): " & n &
    " {.raises: [ProtobufError], gcsafe.} =\n" &
    "  ## Raises ProtobufError on malformed input.\n" &
    "  var r = initReader(data)\n  decodeFrom(result, r)"

proc genService(g: var Gen; s: ServiceDesc): string =
  ## The blocking client and server API of `s`.
  let pkg = g.file.package
  let fullName = (if pkg.len > 0: pkg & "." else: "") & s.name
  let sn = camel(s.name, upperFirst = true)
  var o: seq[string]
  o.add "# ---------------------------------------------------------------- service " & fullName
  o.add ""
  o.add "type"
  o.add "  " & sn & "Client* = object"
  o.add "    ## Typed client for " & fullName & "."
  o.add "    ch*: GrpcChannel"
  o.add ""
  o.add "  " & sn & "Handlers* = object"
  o.add "    ## Server implementation of " & fullName & "; methods left nil answer"
  o.add "    ## UNIMPLEMENTED."
  for m in s.methods:
    let req = g.typeRef(m.input)
    let resp = g.typeRef(m.output)
    let kind =
      if m.clientStreaming and m.serverStreaming: "BidiFn"
      elif m.clientStreaming: "ClientStreamFn"
      elif m.serverStreaming: "ServerStreamFn"
      else: "UnaryFn"
    o.add "    " & ident(m.name) & "*: " & kind & "[" & req & ", " & resp & "]"
  o.add ""
  o.add "proc new" & sn & "Client*(ch: GrpcChannel): " & sn & "Client = " & sn & "Client(ch: ch)"
  o.add ""
  for m in s.methods:
    let req = g.typeRef(m.input)
    let resp = g.typeRef(m.output)
    let path = "/" & fullName & "/" & m.name
    let mn = ident(m.name)
    let mnPlain = mn.strip(chars = {'`'})
    if not m.clientStreaming and not m.serverStreaming:
      o.add "proc " & mn & "*(c: " & sn & "Client; req: " & req &
            "; metadata: Metadata = @[]; timeoutMs = -1; compression = \"\"): " & resp & " ="
      o.add "  unaryCallTyped[" & req & ", " & resp & "](c.ch, \"" & path &
            "\", req, metadata, timeoutMs, compression).message"
      o.add ""
      o.add "proc " & mnPlain & "WithMetadata*(c: " & sn & "Client; req: " & req &
            "; metadata: Metadata = @[]; timeoutMs = -1; compression = \"\"):"
      o.add "    tuple[message: " & resp & ", headers, trailers: Metadata] ="
      o.add "  unaryCallTyped[" & req & ", " & resp & "](c.ch, \"" & path &
            "\", req, metadata, timeoutMs, compression)"
    elif m.serverStreaming and not m.clientStreaming:
      o.add "proc " & mn & "*(c: " & sn & "Client; req: " & req &
            "; metadata: Metadata = @[]; timeoutMs = -1; compression = \"\"): ClientReader[" & resp & "] ="
      o.add "  openReader[" & req & ", " & resp & "](c.ch, \"" & path &
            "\", req, metadata, timeoutMs, compression)"
    elif m.clientStreaming and not m.serverStreaming:
      o.add "proc " & mn & "*(c: " & sn & "Client; metadata: Metadata = @[]; timeoutMs = -1;"
      o.add "    compression = \"\"): ClientWriter[" & req & ", " & resp & "] ="
      o.add "  openWriter[" & req & ", " & resp & "](c.ch, \"" & path & "\", metadata, timeoutMs, compression)"
    else:
      o.add "proc " & mn & "*(c: " & sn & "Client; metadata: Metadata = @[]; timeoutMs = -1;"
      o.add "    compression = \"\"): ClientBidi[" & req & ", " & resp & "] ="
      o.add "  openBidi[" & req & ", " & resp & "](c.ch, \"" & path & "\", metadata, timeoutMs, compression)"
    o.add ""
  o.add "proc register" & sn & "*(s: GrpcServer; h: " & sn & "Handlers) ="
  o.add "  ## Adds the methods of " & fullName & " that `h` implements."
  if s.methods.len == 0: o.add "  discard"
  for m in s.methods:
    let req = g.typeRef(m.input)
    let resp = g.typeRef(m.output)
    let path = "/" & fullName & "/" & m.name
    let adder =
      if m.clientStreaming and m.serverStreaming: "addTypedBidi"
      elif m.clientStreaming: "addTypedClientStream"
      elif m.serverStreaming: "addTypedServerStream"
      else: "addTypedUnary"
    o.add "  if h." & ident(m.name) & " != nil: " & adder & "[" & req & ", " & resp &
          "](s, \"" & path & "\", h." & ident(m.name) & ")"
  o.join("\n")

proc genAsyncService(g: var Gen; s: ServiceDesc): string =
  ## The chronos client and server API of `s` (plugin option `async`).
  let pkg = g.file.package
  let fullName = (if pkg.len > 0: pkg & "." else: "") & s.name
  let sn = camel(s.name, upperFirst = true)
  var o: seq[string]
  o.add "# ---------------------------------------------------------------- async service " & fullName
  o.add ""
  o.add "type"
  o.add "  " & sn & "AsyncClient* = object"
  o.add "    ## Typed chronos client for " & fullName & "."
  o.add "    ch*: AsyncChannel"
  o.add ""
  o.add "  " & sn & "AsyncHandlers* = object"
  o.add "    ## Async server implementation of " & fullName & "; methods left nil"
  o.add "    ## answer UNIMPLEMENTED."
  for m in s.methods:
    let req = g.typeRef(m.input)
    let resp = g.typeRef(m.output)
    let kind =
      if m.clientStreaming and m.serverStreaming: "AsyncBidiFn"
      elif m.clientStreaming: "AsyncClientStreamFn"
      elif m.serverStreaming: "AsyncServerStreamFn"
      else: "AsyncUnaryFn"
    o.add "    " & ident(m.name) & "*: " & kind & "[" & req & ", " & resp & "]"
  o.add ""
  o.add "proc new" & sn & "AsyncClient*(ch: AsyncChannel): " & sn & "AsyncClient = " &
        sn & "AsyncClient(ch: ch)"
  o.add ""
  for m in s.methods:
    let req = g.typeRef(m.input)
    let resp = g.typeRef(m.output)
    let path = "/" & fullName & "/" & m.name
    let mn = ident(m.name)
    let mnPlain = mn.strip(chars = {'`'})
    let cl = sn & "AsyncClient"
    if not m.clientStreaming and not m.serverStreaming:
      o.add "proc " & mn & "*(c: " & cl & "; req: " & req &
            "; metadata: Metadata = @[]; timeoutMs = -1; compression = \"\"): Future[" & resp & "] {.async.} ="
      o.add "  return (await unaryCallTyped[" & req & ", " & resp & "](c.ch, \"" & path &
            "\", req, metadata, timeoutMs, compression)).message"
      o.add ""
      o.add "proc " & mnPlain & "WithMetadata*(c: " & cl & "; req: " & req &
            "; metadata: Metadata = @[]; timeoutMs = -1; compression = \"\"):"
      o.add "    Future[tuple[message: " & resp & ", headers, trailers: Metadata]] ="
      o.add "  unaryCallTyped[" & req & ", " & resp & "](c.ch, \"" & path &
            "\", req, metadata, timeoutMs, compression)"
    elif m.serverStreaming and not m.clientStreaming:
      o.add "proc " & mn & "*(c: " & cl & "; req: " & req &
            "; metadata: Metadata = @[]; timeoutMs = -1; compression = \"\"): Future[AsyncClientReader[" & resp & "]] ="
      o.add "  openReader[" & req & ", " & resp & "](c.ch, \"" & path &
            "\", req, metadata, timeoutMs, compression)"
    elif m.clientStreaming and not m.serverStreaming:
      o.add "proc " & mn & "*(c: " & cl & "; metadata: Metadata = @[]; timeoutMs = -1;"
      o.add "    compression = \"\"): Future[AsyncClientWriter[" & req & ", " & resp & "]] ="
      o.add "  openWriter[" & req & ", " & resp & "](c.ch, \"" & path & "\", metadata, timeoutMs, compression)"
    else:
      o.add "proc " & mn & "*(c: " & cl & "; metadata: Metadata = @[]; timeoutMs = -1;"
      o.add "    compression = \"\"): Future[AsyncClientBidi[" & req & ", " & resp & "]] ="
      o.add "  openBidi[" & req & ", " & resp & "](c.ch, \"" & path & "\", metadata, timeoutMs, compression)"
    o.add ""
  o.add "proc register" & sn & "*(s: AsyncGrpcServer; h: " & sn & "AsyncHandlers) ="
  o.add "  ## Adds the methods of " & fullName & " that `h` implements."
  if s.methods.len == 0: o.add "  discard"
  for m in s.methods:
    let req = g.typeRef(m.input)
    let resp = g.typeRef(m.output)
    let path = "/" & fullName & "/" & m.name
    let adder =
      if m.clientStreaming and m.serverStreaming: "addTypedBidi"
      elif m.clientStreaming: "addTypedClientStream"
      elif m.serverStreaming: "addTypedServerStream"
      else: "addTypedUnary"
    o.add "  if h." & ident(m.name) & " != nil: " & adder & "[" & req & ", " & resp &
          "](s, \"" & path & "\", h." & ident(m.name) & ")"
  o.join("\n")

const wktPrefix = "google/protobuf/"

proc relImport(fromFile, toFile: string): string =
  ## Well-known types come from the copy in this package (nimgrpc/wkt), so user
  ## code need not generate them; everything else is imported relatively.
  if toFile.startsWith(wktPrefix):
    return "nimgrpc/wkt/" & moduleOf(toFile)
  let a = moduleOf(fromFile).parentDir
  let b = moduleOf(toFile)
  var rel = relativePath(b, if a.len > 0: a else: ".", '/')
  if not rel.startsWith("."): rel = "./" & rel
  "\"" & rel & "\""

type GenOptions = object
  descriptor: bool ## a constant with the serialized FileDescriptorProto (for nimgrpc/reflection)
  blocking: bool   ## blocking client and server API (nimgrpc/typed)
  async: bool      ## chronos client and server API (nimgrpc/asynctyped)

proc parseOptions(param: string): GenOptions =
  ## The plugin parameter (`--nim_opt=...`): a comma-separated list of
  ## `blocking`, `async` and `descriptor`; the default is `blocking`.
  if param.strip.len == 0: return GenOptions(blocking: true)
  for p in param.split(','):
    case p.strip
    of "blocking": result.blocking = true
    of "async": result.async = true
    of "descriptor": result.descriptor = true
    of "": discard
    else: raise newException(ValueError, "unknown option " & p.strip.escape &
                             " (expected blocking, async and/or descriptor)")

proc generate(reg: Registry; f: var FileDesc; opts: GenOptions): string =
  var g = Gen(reg: reg, file: f.addr, proto3: f.syntax == "proto3")
  let prefix = if f.package.len > 0: "." & f.package else: ""
  for e in f.enums: g.genEnum(@[e.name], e)
  for m in f.messages: g.genMessage(prefix, @[], m)

  var o: seq[string]
  o.add "# Generated by protoc-gen-nim from " & f.name & ". DO NOT EDIT."
  o.add "{.push styleChecks: off.}"    # proto names keep their spelling (NullValue_NULL_VALUE)
  o.add "{.push warning[UnusedImport]: off.}"
  o.add "import std/[options, tables]"
  o.add "import nimgrpc/protobuf"
  let services = f.services.len > 0
  if services and opts.blocking: o.add "import nimgrpc/typed"
  if services and opts.async: o.add "import pkg/chronos, nimgrpc/asynctyped"
  for dep in f.deps: o.add "import " & relImport(f.name, dep)
  # std/options and std/tables are not re-exported: a proto message named
  # `Option` (google.protobuf.Option) would then clash with them through
  # this module. Import them where Option/Table fields are used.
  o.add "export protobuf"
  for dep in f.deps:
    o.add "export " & moduleOf(dep).extractFilename
  if services and opts.blocking: o.add "export typed"
  if services and opts.async: o.add "export chronos, asynctyped"
  o.add "{.pop.}"
  o.add ""
  if g.typesOut.len > 0:
    o.add "type"
    o.add g.typesOut.join("\n\n")
    o.add ""
  if g.fwdOut.len > 0:
    o.add g.fwdOut.join("\n")
    o.add ""
  o.add g.procsOut.join("\n\n")
  o.add ""
  for s in f.services:
    if opts.blocking:
      o.add g.genService(s)
      o.add ""
    if opts.async:
      o.add g.genAsyncService(s)
      o.add ""
  if opts.descriptor:
    o.add "# The serialized FileDescriptorProto of " & f.name & ", for `nimgrpc/reflection`."
    o.add "const fileDescriptorProto* ="
    var i = 0
    while i < f.raw.len:
      var chunk = "  \""
      for b in f.raw[i ..< min(i + 24, f.raw.len)]:
        chunk.add "\\x" & toHex(int(b), 2).toLowerAscii
      chunk.add "\""
      i += 24
      o.add chunk & (if i < f.raw.len: " &" else: "")
    if f.raw.len == 0: o.add "  \"\""
    o.add ""
  while o[^1] == "": o.setLen(o.len - 1)
  o.add "{.pop.}"
  o.add ""
  o.join("\n")

# ================================================================ plugin I/O

proc main() =
  let input = stdin.readAll()
  var r = initReader(input.toOpenArrayByte(0, input.high))
  var toGenerate: seq[string]
  var files: seq[FileDesc]
  var param = ""
  readFields(r):
    case fieldNo
    of 1: toGenerate.add r.getString()
    of 2: param = r.getString()
    of 15:
      var s = r.subReader()
      let raw = @(s.data.toOpenArray(0, s.len - 1))
      var fd = parseFile(s)
      fd.raw = withoutSourceInfo(raw)
      files.add fd
    else: r.skipField(wt, fieldNo)

  var w: PbWriter
  w.putTag(2, wtVarint)          # supported_features: proto3 optional
  w.putVarint(1)
  try:
    let opts = parseOptions(param)
    let reg = buildRegistry(files)
    for f in files.mitems:
      if f.name notin toGenerate: continue
      let content = generate(reg, f, opts)
      w.putTag(15, wtLen)
      let s = w.beginLen()
      w.putTag(1, wtLen)
      w.putString(moduleOf(f.name) & ".nim")
      w.putTag(15, wtLen)
      w.putString(content)
      w.endLen(s)
  except CatchableError as e:
    w = PbWriter()
    w.putTag(1, wtLen)
    w.putString("protoc-gen-nim: " & e.msg)
  var outStr = newString(w.buf.len)
  if w.buf.len > 0: copyMem(outStr[0].addr, w.buf[0].addr, w.buf.len)
  stdout.write outStr
  stdout.flushFile()

when isMainModule:
  main()
