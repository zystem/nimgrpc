## Protobuf wire-format runtime for generated code (protoc-gen-nim).
##
## Generated messages call these procs; applications normally use only the
## generated `encode` / `decode`. Unknown fields are skipped on decode.


const
  maxNestingDepth* = 100
    ## How deep messages and groups may nest on decode (the limit protobuf-go and
    ## C++ protobuf use). The top-level message is at depth 0. Past it decoding
    ## raises ProtobufError.

type
  ProtobufError* = object of CatchableError
    ## Malformed input.

  WireType* = enum
    wtVarint = 0, wt64 = 1, wtLen = 2, wtStartGroup = 3, wtEndGroup = 4, wt32 = 5

  PbReader* = object
    data*: ptr UncheckedArray[byte]
    len*: int
    pos*: int
    depth*: int  ## nesting depth of this reader; `subReader` adds one

  PbWriter* = object
    buf*: seq[byte]

proc pbError(msg: string) {.noreturn, raises: [ProtobufError].} =
  raise newException(ProtobufError, msg)

# ---------------------------------------------------------------- writing

proc putVarint*(w: var PbWriter; v: uint64) =
  var x = v
  while x >= 0x80:
    w.buf.add byte(x and 0x7f or 0x80)
    x = x shr 7
  w.buf.add byte(x)

proc putTag*(w: var PbWriter; field: int; wt: WireType) =
  w.putVarint(uint64(field) shl 3 or uint64(ord(wt)))

proc putFixed32*(w: var PbWriter; v: uint32) =
  for i in 0 ..< 4: w.buf.add byte((v shr (8 * i)) and 0xff)

proc putFixed64*(w: var PbWriter; v: uint64) =
  for i in 0 ..< 8: w.buf.add byte((v shr (8 * i)) and 0xff)

proc putBytes*(w: var PbWriter; data: openArray[byte]) =
  w.putVarint(data.len.uint64)
  w.buf.add data

proc putString*(w: var PbWriter; s: string) =
  w.putVarint(s.len.uint64)
  if s.len > 0: w.buf.add s.toOpenArrayByte(0, s.high)

proc zigzag32*(v: int32): uint64 {.inline.} = uint64(cast[uint32]((v shl 1) xor (v shr 31)))
proc zigzag64*(v: int64): uint64 {.inline.} = cast[uint64]((v shl 1) xor (v shr 63))

proc beginLen*(w: var PbWriter): int =
  ## Starts a length-delimited value whose size is not known yet; pair with
  ## `endLen`. Reserves one byte for the length and moves the payload if the
  ## length needs more.
  w.buf.add 0
  w.buf.len

proc endLen*(w: var PbWriter; start: int) =
  let n = w.buf.len - start
  var lenBytes: array[10, byte]
  var k = 0
  var x = n.uint64
  while x >= 0x80:
    lenBytes[k] = byte(x and 0x7f or 0x80)
    x = x shr 7
    inc k
  lenBytes[k] = byte(x)
  inc k
  if k > 1:
    w.buf.setLen(w.buf.len + k - 1)
    moveMem(w.buf[start + k - 1].addr, w.buf[start].addr, n)
  for i in 0 ..< k: w.buf[start - 1 + i] = lenBytes[i]

# ---------------------------------------------------------------- reading

proc initReader*(data: openArray[byte]): PbReader =
  PbReader(data: if data.len > 0: cast[ptr UncheckedArray[byte]](data[0].unsafeAddr) else: nil,
           len: data.len)

proc atEnd*(r: PbReader): bool = r.pos >= r.len

proc getVarint*(r: var PbReader): uint64 =
  var shift = 0
  while true:
    if r.pos >= r.len: pbError("truncated varint")
    if shift > 63: pbError("varint too long")
    let b = r.data[r.pos]
    inc r.pos
    result = result or (uint64(b and 0x7f) shl shift)
    if b < 0x80: return
    shift += 7

proc getTag*(r: var PbReader; field: var int; wt: var WireType) =
  let t = r.getVarint()
  field = int(t shr 3)
  let w = int(t and 7)
  if field == 0 or w > 5: pbError("invalid tag")
  wt = WireType(w)

proc getFixed32*(r: var PbReader): uint32 =
  if r.len - r.pos < 4: pbError("truncated fixed32")
  for i in 0 ..< 4: result = result or (uint32(r.data[r.pos + i]) shl (8 * i))
  r.pos += 4

proc getFixed64*(r: var PbReader): uint64 =
  if r.len - r.pos < 8: pbError("truncated fixed64")
  for i in 0 ..< 8: result = result or (uint64(r.data[r.pos + i]) shl (8 * i))
  r.pos += 8

proc getLen*(r: var PbReader): int =
  let n = r.getVarint()
  if n > uint64(r.len - r.pos): pbError("length beyond the end of the message")
  int(n)

proc getBytes*(r: var PbReader): seq[byte] =
  let n = r.getLen()
  result = newSeq[byte](n)
  if n > 0: copyMem(result[0].addr, r.data[r.pos].addr, n)
  r.pos += n

proc getString*(r: var PbReader): string =
  ## Not checked for UTF-8.
  let n = r.getLen()
  result = newString(n)
  if n > 0: copyMem(result[0].addr, r.data[r.pos].addr, n)
  r.pos += n

proc subReader*(r: var PbReader): PbReader =
  ## A reader over the next length-delimited value; `r` moves past it.
  ## Raises ProtobufError when the nesting is deeper than `maxNestingDepth`.
  if r.depth >= maxNestingDepth: pbError("message nested too deeply")
  let n = r.getLen()
  result = PbReader(data: cast[ptr UncheckedArray[byte]](r.data[r.pos].addr), len: n,
                    depth: r.depth + 1)
  r.pos += n

proc childReader*(r: PbReader; data: openArray[byte]): PbReader =
  ## A reader over `data`, a message nested in what `r` reads, for code that
  ## copied the bytes out first. Checks the depth like `subReader`.
  if r.depth >= maxNestingDepth: pbError("message nested too deeply")
  result = initReader(data)
  result.depth = r.depth + 1

proc unzigzag32*(v: uint64): int32 {.inline.} =
  let u = uint32(v and 0xffff_ffff'u64)
  cast[int32]((u shr 1) xor (0'u32 - (u and 1)))

proc unzigzag64*(v: uint64): int64 {.inline.} =
  cast[int64]((v shr 1) xor (0'u64 - (v and 1)))

proc skipField*(r: var PbReader; wt: WireType; field: int) =
  ## Skips one field. Groups (proto2) are skipped whole, nested ones included;
  ## they count toward `maxNestingDepth` (no recursion, so a hostile message
  ## cannot overflow the stack).
  case wt
  of wtVarint: discard r.getVarint()
  of wt64: discard r.getFixed64()
  of wt32: discard r.getFixed32()
  of wtLen: r.pos += r.getLen()
  of wtStartGroup:
    if r.depth >= maxNestingDepth: pbError("message nested too deeply")
    var open: array[maxNestingDepth + 1, int]  # field numbers of the open groups
    var n = 1
    open[0] = field
    while true:
      var f: int
      var w: WireType
      r.getTag(f, w)
      case w
      of wtEndGroup:
        if f != open[n - 1]: pbError("mismatched end group")
        dec n
        if n == 0: return
      of wtStartGroup:
        if r.depth + n >= maxNestingDepth: pbError("message nested too deeply")
        open[n] = f
        inc n
      of wtVarint: discard r.getVarint()
      of wt64: discard r.getFixed64()
      of wt32: discard r.getFixed32()
      of wtLen: r.pos += r.getLen()
  of wtEndGroup: pbError("unexpected end group")
