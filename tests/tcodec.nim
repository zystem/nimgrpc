## Generated Protobuf code against protoc.
##
## tests/proto/*.bin were encoded by protoc from the .txtpb fixtures. Each
## is decoded here, checked field by field, re-encoded and decoded again. When
## protoc is available (PROTOC, default `protoc` on PATH) the re-encoded bytes
## must also decode, in protoc, to the same text as the original.

import std/[unittest, os, osproc, options, tables, math, sequtils, strutils]
import nimgrpc/[protobuf, bytebuf, wire, status, health]
import ./gen/[codec_pb, legacy_pb]

const dir = currentSourcePath.parentDir / "proto"

proc load(name: string): seq[byte] =
  let s = readFile(dir / name)
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(result[0].addr, s[0].unsafeAddr, s.len)

proc protoc(): string =
  result = getEnv("PROTOC", findExe("protoc"))

proc protocDecode(typ, file: string; data: seq[byte]): string =
  ## protoc's text form of `data`; "" if protoc is missing.
  let p = protoc()
  if p.len == 0: return ""
  let tmp = getTempDir() / "tcodec.bin"
  var s = newString(data.len)
  if data.len > 0: copyMem(s[0].addr, data[0].unsafeAddr, data.len)
  writeFile(tmp, s)
  let (outp, code) = execCmdEx(p & " --decode=" & typ & " -I" & dir.quoteShell &
                               " " & file & " < " & tmp.quoteShell)
  doAssert code == 0, outp
  outp

proc groupBomb(n: int; field = 1000): seq[byte] =
  ## `n` start-groups, then `n` end-groups: unknown field `field`, nested.
  var w: PbWriter
  for i in 0 ..< n: w.putTag(field, wtStartGroup)
  for i in 0 ..< n: w.putTag(field, wtEndGroup)
  w.buf

proc startGroups(n: int): seq[byte] =
  ## Only the opening tags: 0xC3 0x3E, n times. What an attacker sends.
  for i in 0 ..< n:
    result.add 0xC3'u8
    result.add 0x3E'u8

proc nodeChain(n: int): seq[byte] =
  ## A Node with a child with a child ... `n` levels below the top one.
  var sz = newSeq[int](n + 1)   # sz[i]: size of the message at level i
  for i in countdown(n - 1, 0):
    var w: PbWriter
    w.putVarint(sz[i + 1].uint64)
    sz[i] = 1 + w.buf.len + sz[i + 1]
  var w: PbWriter
  for i in 0 ..< n:
    w.putTag(2, wtLen)
    w.putVarint(sz[i + 1].uint64)
  w.buf

suite "proto3 codec":
  let original = load("everything.bin")
  let m = Everything.decode(original)

  test "scalars, including extremes":
    let s = m.scalars
    check m.hasScalars
    check s.fDouble == -1.5e300
    check s.fFloat == 3.25'f32
    check s.fInt32 == -42
    check s.fInt64 == -9007199254740993'i64
    check s.fUint32 == 4294967295'u32
    check s.fUint64 == 18446744073709551615'u64
    check s.fSint32 == low(int32)
    check s.fSint64 == low(int64)
    check s.fFixed32 == 4000000000'u32
    check s.fFixed64 == 18000000000000000000'u64
    check s.fSfixed32 == -7
    check s.fSfixed64 == -8
    check s.fBool
    check s.fString == "héllo ☺ \x00 end"
    check s.fBytes == @[0'u8, 0xff, 0x10]
    check s.fColor == Color_BLUE
    check int32(s.fColor) == -3

  test "repeated, packed and not":
    check m.packedInts == @[1'i32, -1, 300, 0, 2147483647]
    check m.unpackedInts == @[5'i32, -5]
    check m.packedSints == @[-1'i64, 1, low(int64)]
    check m.packedDoubles.len == 3 and m.packedDoubles[0] == 0.5
    check m.packedDoubles[1] == 0.0 and copySign(1.0, m.packedDoubles[1]) < 0
    check m.strings == @["a", "", "ccc"]
    check m.inners.len == 2 and m.inners[0].x == 1 and
          m.inners[0].mood == Everything_Inner_Mood_HAPPY
    check m.inners[1] == Everything_Inner()

  test "open enums keep unknown values":
    check m.colors == @[Color_RED, Color_BLUE, Color(7)]
    check $Color(7) == "Color(7)"
    check $Color_RED == "RED"

  test "maps":
    check m.strToInt == {"one": 1'i32, "minus": -1'i32}.toTable
    check m.intToInner.len == 1 and m.intToInner[-5].x == 9
    check m.boolToStr == {true: "yes"}.toTable

  test "oneof, optional and keyword fields":
    check m.hasChoiceInner and m.choiceInner.x == 77
    check m.choiceStr.isNone and m.choiceInt.isNone
    check m.maybeInt == some(0'i32)     # explicit presence keeps a set zero
    check m.maybeStr.isNone
    check m.hasInner and m.inner.mood == Everything_Inner_Mood_HAPPY
    check m.`type` == 3
    check m.fieldWithLargeNumber == 1

  test "recursive messages":
    check m.hasTree and m.tree.name == "root"
    check m.tree.child != nil and m.tree.child.name == "c"
    check m.tree.child.child != nil and m.tree.child.child.name == "cc"
    check m.tree.child.child.child == nil
    check m.tree.children.len == 2 and m.tree.children[1].children[0].name == "k2a"

  test "round trip in Nim":
    let again = Everything.decode(m.encode)
    check again.encode == m.encode
    check again.scalars == m.scalars
    check again.strToInt == m.strToInt
    check again.tree.child.child.name == "cc"

  test "protoc decodes our encoding to the same message":
    let a = protocDecode("codec.test.Everything", "codec.proto", original)
    if a.len == 0:
      skip()
    else:
      check protocDecode("codec.test.Everything", "codec.proto", m.encode) == a

  test "a later oneof member clears the earlier one":
    var w: PbWriter
    w.putTag(12, wtLen); w.putString("first")
    w.putTag(14, wtVarint); w.putVarint(9)
    let d = Everything.decode(w.buf)
    check d.choiceStr.isNone and d.choiceInt == some(9'i64)

  test "malformed input raises ProtobufError":
    for bad in [@[0x08'u8], @[0x0a'u8, 0x05, 1], @[0x0a'u8, 0xff, 0xff, 0xff, 0xff, 0x0f],
                @[0x00'u8], @[0x0f'u8]]:
      expect ProtobufError:
        discard Everything.decode(bad)

  test "unknown fields are skipped":
    var w: PbWriter
    w.putTag(1000, wtLen); w.putString("ignored")
    w.putTag(1001, wt32); w.putFixed32(1)
    w.putTag(19, wtVarint); w.putVarint(5)
    check Everything.decode(w.buf).`type` == 5

proc fromHex(s: string): seq[byte] =
  let t = s.replace(" ", "")
  for i in countup(0, t.len - 2, 2): result.add byte(parseHexInt(t[i .. i + 1]))

proc varintOf(hex: string): Option[uint64] =
  var r = initReader(fromHex(hex))
  try: result = some(r.getVarint())
  except ProtobufError: discard

proc tagOf(hex: string): Option[(int, int)] =
  var r = initReader(fromHex(hex))
  var f: int
  var w: WireType
  try:
    r.getTag(f, w)
    result = some((f, ord(w)))
  except ProtobufError: discard

suite "varint and tag bounds":
  ## The expected results of the varints are those of protobuf-go v1.36.12 (`protowire.ConsumeVarint`),
  ## run on 2026-11-21 with tests/interop/gopb; the tags differ from it in two ways, in the tests
  ## below that say so.
  test "a varint is at most ten bytes, and the tenth is 0 or 1":
    let nines = "ff ff ff ff ff ff ff ff ff"
    check varintOf("00") == some(0'u64)
    check varintOf("7f") == some(127'u64)
    check varintOf("80 01") == some(128'u64)
    check varintOf(nines & " 01") == some(high(uint64))
    check varintOf("80 80 80 80 80 80 80 80 80 01") == some(1'u64 shl 63)
    check varintOf("80 00") == some(0'u64)                                # padded, as protobuf-go
    check varintOf("80 80 80 80 80 80 80 80 80 00") == some(0'u64)
    check varintOf(nines & " 02").isNone          # it was cut to its low bit: 9223372036854775807
    check varintOf(nines & " 7f").isNone          # it was 18446744073709551615
    check varintOf("80 80 80 80 80 80 80 80 80 02").isNone    # it was 0
    check varintOf(nines & " 81 00").isNone                   # eleven bytes
    check varintOf("80 80 80 80 80 80 80 80 80 80 00").isNone
    check varintOf("80").isNone                               # truncated

  test "the largest values round-trip":
    for v in [0'u64, 1, 127, 128, (1'u64 shl 32) - 1, 1'u64 shl 32, (1'u64 shl 63) - 1,
              1'u64 shl 63, high(uint64)]:
      var w: PbWriter
      w.putVarint(v)
      var r = initReader(w.buf)
      check r.getVarint() == v
      check r.atEnd

  test "field numbers 1 to 2^29 - 1 are tags":
    check tagOf("08") == some((1, 0))
    check tagOf("f8 ff ff ff 0f") == some((maxFieldNumber, 0))
    check maxFieldNumber == 536870911

  test "field 0, a field number past 2^29 - 1 and wire types 6 and 7 are not tags":
    check tagOf("00").isNone
    check tagOf("07").isNone
    check tagOf("0e").isNone            # protobuf-go leaves the wire type to its caller
    check tagOf("0f").isNone
    check tagOf("80 80 80 80 10").isNone     # field 2^29: protobuf-go reads it, as an unknown field
    check tagOf("f8 ff ff ff ff 03").isNone  # past 2^31 - 1: protobuf-go refuses it too
    check tagOf("f8 ff ff ff ff ff ff ff ff 01").isNone   # it was field 2^61 - 1

  test "a message with such a value raises ProtobufError":
    # field 19 (a varint) with an overflowing varint, and an unknown field 2^29
    for bad in ["98 01 ff ff ff ff ff ff ff ff ff 02", "80 80 80 80 10 01"]:
      expect ProtobufError:
        discard Everything.decode(fromHex(bad))

suite "large values":
  # A large bytes or string field is copied once into a buffer that is as long as the message
  # (it used to be reallocated twice, and one 4 MiB field cost 10 MiB).
  test "a large bytes field in a sub-message: one buffer of the size of the message":
    var m = Everything(scalars: Scalars(fBytes: newSeq[byte](1 shl 20)), hasScalars: true)
    m.scalars.fBytes[^1] = 7
    let enc = encode(m)
    check enc.len > 1 shl 20 and enc.len < (1 shl 20) + 32
    check enc.capacity <= enc.len + 80
    let back = Everything.decode(enc)
    check back.scalars.fBytes.len == 1 shl 20 and back.scalars.fBytes[^1] == 7

  test "a large string three messages deep":
    var deep = new Node
    deep.name = strutils.repeat('x', 300_000)
    var mid = new Node
    mid.name = "c"
    mid.child = deep
    let m = Everything(tree: Node(name: "root", child: mid), hasTree: true)
    let enc = encode(m)
    check enc.capacity <= enc.len + 80
    check Everything.decode(enc).tree.child.child.name.len == 300_000

  test "two large fields and small ones around them round-trip":
    var m = Everything(scalars: Scalars(fString: strutils.repeat('a', 70_000), fBytes: newSeq[byte](70_000), fInt32: 5),
                       hasScalars: true, strings: @["s", strutils.repeat('b', 100_000), "t"])
    let back = Everything.decode(encode(m))
    check back.scalars.fString.len == 70_000 and back.scalars.fBytes.len == 70_000
    check back.scalars.fInt32 == 5 and back.strings.len == 3 and back.strings[1].len == 100_000

suite "nesting limit":
  test "the limit is 100":
    check maxNestingDepth == 100

  test "groups nested exactly at the limit are skipped":
    discard Node.decode(groupBomb(maxNestingDepth))
    discard Node.decode(groupBomb(1))

  test "groups one deeper raise ProtobufError":
    expect ProtobufError:
      discard Node.decode(groupBomb(maxNestingDepth + 1))

  test "a huge group bomb raises ProtobufError, no crash":
    # 2 000 000 start-groups: 4 MB, just under the default message limit
    let bomb = startGroups(2_000_000)
    check bomb.len == 4_000_000
    expect ProtobufError:
      discard Node.decode(bomb)
    expect ProtobufError:
      discard Everything.decode(bomb)

  test "groups count from the depth of the message they are in":
    # Node.child (depth 1) holding 100 nested groups is 101 deep; 99 is fine
    proc wrap(inner: seq[byte]): seq[byte] =
      var w: PbWriter
      w.putTag(2, wtLen)
      w.putBytes(inner)
      w.buf
    discard Node.decode(wrap(groupBomb(maxNestingDepth - 1)))
    expect ProtobufError:
      discard Node.decode(wrap(groupBomb(maxNestingDepth)))

  test "a mismatched or stray end group is still an error":
    var w: PbWriter
    w.putTag(1000, wtStartGroup); w.putTag(1001, wtEndGroup)
    expect ProtobufError:
      discard Node.decode(w.buf)
    var e: PbWriter
    e.putTag(1000, wtEndGroup)
    expect ProtobufError:
      discard Node.decode(e.buf)

  test "nested messages exactly at the limit decode":
    var m = Node.decode(nodeChain(maxNestingDepth))
    var depth = 0
    var cur = m.addr
    while cur.child != nil:
      cur = cur.child[].addr
      inc depth
    check depth == maxNestingDepth

  test "nested messages one deeper raise ProtobufError":
    expect ProtobufError:
      discard Node.decode(nodeChain(maxNestingDepth + 1))

  test "a huge chain of nested messages raises ProtobufError, no crash":
    let bomb = nodeChain(700_000)
    check bomb.len < 4 * 1024 * 1024
    expect ProtobufError:
      discard Node.decode(bomb)

  test "decodeHealthRequest raises ProtobufError on the group bomb":
    expect ProtobufError:
      discard decodeHealthRequest(startGroups(300_000))
    expect ProtobufError:
      discard decodeHealthRequest(groupBomb(maxNestingDepth + 1))
    check decodeHealthRequest(groupBomb(maxNestingDepth)) == ""

suite "proto2 codec":
  let original = load("legacy.bin")
  let m = Legacy.decode(original)

  test "explicit presence and recursion":
    check m.a == some(0'i32)
    check m.b == some("")
    check m.next != nil and m.next.b == some("inner")
    check m.next.next != nil and m.next.next.b == some("deeper")
    check m.next.next.a.isNone

  test "repeated scalars: unpacked by default, packed on request":
    check m.unpacked == @[1'i32, 2]
    check m.packed == @[3'i32, 4]
    let enc = m.encode
    # field 3 unpacked: tag 0x18 per element; field 4 packed: one tag 0x22
    var tags3, tags4 = 0
    for i, b in enc:
      if b == 0x18: inc tags3
      if b == 0x22: inc tags4
    check tags3 >= 2 and tags4 >= 1

  test "protoc decodes our encoding to the same message":
    let a = protocDecode("codec.legacy.Legacy", "legacy.proto", original)
    if a.len == 0:
      skip()
    else:
      check protocDecode("codec.legacy.Legacy", "legacy.proto", m.encode) == a

suite "byte buffers":
  test "appendBytes keeps what is there and adds the rest":
    var b = @[1'u8, 2]
    b.appendBytes [3'u8, 4, 5]
    b.appendBytes newSeq[byte]()
    check b == @[1'u8, 2, 3, 4, 5]
    var raw = [9'u8, 8]
    b.appendBytes(raw[0].addr, 2)
    b.appendBytes(nil, 0)
    check b == @[1'u8, 2, 3, 4, 5, 9, 8]

  test "frames split across chunks are reassembled":
    let frames = encodeMessage([10'u8, 20, 30]) & encodeMessage([40'u8])
    var m: MsgBuf
    var got: seq[seq[byte]]
    for i in 0 ..< frames.len:                  # one byte at a time
      var chunk = @[frames[i]]
      m.feed(chunk)
      var payload: seq[byte]
      var compressed: bool
      while m.take(1024, payload, compressed):
        got.add payload
    check got == @[@[10'u8, 20, 30], @[40'u8]]
    check m.leftover == 0

  test "several frames in one chunk, an empty one and a partial tail":
    let f = encodeMessage([1'u8, 2]) & encodeMessage([]) & encodeMessage([7'u8, 8, 9])
    var m: MsgBuf
    var chunk = f[0 ..< f.len - 2]
    m.feed(chunk)
    var payload: seq[byte]
    var compressed: bool
    check m.take(1024, payload, compressed) and payload == @[1'u8, 2]
    check m.take(1024, payload, compressed) and payload.len == 0
    check not m.take(1024, payload, compressed)
    check m.leftover == 5 + 1
    chunk = f[f.len - 2 .. ^1]
    m.feed(chunk)
    check m.take(1024, payload, compressed) and payload == @[7'u8, 8, 9]
    check m.leftover == 0

  test "a compressed flag is reported":
    var m: MsgBuf
    var chunk = encodeMessage([5'u8], compressed = true)
    m.feed(chunk)
    var payload: seq[byte]
    var compressed: bool
    check m.take(1024, payload, compressed) and compressed

  test "a bad flag and an oversize length are refused, and reserve nothing":
    var payload: seq[byte]
    var compressed: bool
    var m: MsgBuf
    var chunk = @[2'u8, 0, 0, 0, 1, 0]
    m.feed(chunk)
    expect GrpcError: discard m.take(1024, payload, compressed)
    var m2: MsgBuf
    chunk = frameHeader(1_000_000).toSeq
    m2.feed(chunk)
    expect GrpcError: discard m2.take(1024, payload, compressed)
    # within the limit, the length alone allocates only a little
    var m3: MsgBuf
    chunk = frameHeader(1_000_000).toSeq
    m3.feed(chunk)
    check not m3.take(4_000_000, payload, compressed)
    check m3.leftover == 5

  test "frameHeader agrees with encodeMessage":
    check @(frameHeader(300, true)) == encodeMessage(newSeq[byte](300), compressed = true)[0 ..< 5]
