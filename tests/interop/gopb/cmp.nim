## The varints and tags of tests/interop/gopb/cases.txt (hex, one per line) read by this decoder,
## in the format of main.go, which prints what protobuf-go's `protowire` makes of the same bytes:
##
##   nim c -p:src -o:/tmp/pbcmp tests/interop/gopb/cmp.nim && /tmp/pbcmp tests/interop/gopb/cases.txt
##   (cd tests/interop/gopb && cp go.mod.example go.mod && go run . < cases.txt)
##
## Compare the two lists. The differences that are meant are the wire types 6 and 7 and the
## field numbers 2^29 .. 2^31 - 1 (docs/interop.md).
import std/[strutils, os]
import nimgrpc/protobuf
proc hexBytes(s: string): seq[byte] =
  let t = s.replace(" ", "")
  for i in countup(0, t.len - 2, 2): result.add byte(parseHexInt(t[i .. i + 1]))
for line in lines(paramStr(1)):
  let l = line.strip
  if l.len == 0 or l.startsWith("#"): continue
  let b = hexBytes(l)
  var vout, tout: string
  try:
    var r = initReader(b)
    vout = "ok " & $r.getVarint()
  except ProtobufError: vout = "err"
  try:
    var r = initReader(b)
    var f: int
    var w: WireType
    r.getTag(f, w)
    tout = "ok field=" & $f & " wt=" & $ord(w)
  except ProtobufError: tout = "err"
  echo alignLeft(l, 44), " varint: ", alignLeft(vout, 22), " tag: ", tout
