## Keeps the documents true: every message the library can raise has a line in
## docs/troubleshooting.md, the failures that page marks "(run)" give the text it shows,
## docs/supported-versions.md agrees with nimgrpc.nimble, the CI workflow and the source,
## and docs/README.md lists every page.

import std/[unittest, os, strutils, net, sequtils]
import nimgrpc

const
  root = currentSourcePath().parentDir.parentDir
  certs = root / "tests" / "certs"
  calls = ["newGrpcError(", ".fail(", "newException(", "finishCall(", "errorResponse(",
           "pbError("]

let page = readFile(root / "docs" / "troubleshooting.md")

proc pem(name: string): string = readFile(certs / name)

proc firstLiteral(s: string; open: int): string =
  ## The first string literal inside the parentheses that open at `open`, "" if none.
  var depth = 0
  var i = open
  while i < s.len:
    case s[i]
    of '(': inc depth
    of ')':
      dec depth
      if depth == 0: return ""
    of '"':
      var lit = ""
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and i + 1 < s.len: inc i
        lit.add s[i]
        inc i
      return lit
    else: discard
    inc i

proc messages(file: string): seq[string] =
  ## The text of every message `file` can raise: the first literal of each raising call, and
  ## in the TLS module the texts of `errorMessage`.
  let s = readFile(file)
  for call in calls:
    var at = s.find(call)
    while at >= 0:
      let lit = firstLiteral(s, at + call.len - 1).strip(chars = {' ', ':', '('})
      if lit.len >= 6: result.add lit
      at = s.find(call, at + 1)
  if file.endsWith("tls.nim"):
    for line in s.splitLines:
      let q = line.find('"')
      if q >= 0 and (line[q + 1 .. ^1].startsWith("TLS") or line[q + 1 .. ^1].startsWith("peer did")):
        result.add line[q + 1 ..< line.find('"', q + 1)].strip(chars = {' ', ':', '('})

proc nimFiles(): seq[string] =
  for f in walkDirRec(root / "src"):
    if f.endsWith(".nim") and "wkt" / "google" notin f: result.add f

template failure(body: untyped): string =
  ## The status and the text a client gets.
  var got = "no error"
  try:
    body
  except GrpcError as e:
    got = $e.code & ": " & e.msg
  except CatchableError as e:
    got = $e.name & ": " & e.msg
  got

proc shows(got, code, text: string) =
  checkpoint got
  check got.startsWith(code)
  check text in got
  check text in page

proc echoBack(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req
proc slow(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ctx.sleep(2000)
  req
proc broken(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  raise newException(ValueError, "a secret path")
proc large(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  newSeq[byte](5 * 1024 * 1024)

proc server(tls: TlsConfig = nil; limits = Limits()): GrpcServer =
  result = newGrpcServer(port = 0, tls = tls, limits = limits)
  result.addUnary("/t.T/Echo", echoBack)
  result.addUnary("/t.T/Slow", slow)
  result.addUnary("/t.T/Broken", broken)
  result.addUnary("/t.T/Large", large)
  result.start()

proc call(port: int; path = "/t.T/Echo"; tls: TlsConfig = nil; name = "";
          req = @[1'u8]; timeoutMs = 5000; compression = ""): string =
  ## No `defer` for the channel here: Nim 2.2.12 and 2.2.14 can lose the exception on its way
  ## through one (docs/nim-compiler-notes.md), and the exception is what this returns.
  var ch: GrpcChannel
  var dialed = false
  result = failure:
    ch = dial("127.0.0.1", port, tls, name)
    dialed = true
    discard ch.unaryCall(path, req, timeoutMs = timeoutMs, compression = compression)
  if dialed: ch.close()

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = s.getLocalAddr()[1].int
  s.close()

suite "troubleshooting page":
  test "every message of the library has a line":
    var missing: seq[string]
    var seen = 0
    for f in nimFiles():
      for m in messages(f):
        inc seen
        if m notin page: missing.add m & "  (" & f.relativePath(root) & ")"
    checkpoint missing.deduplicate.join("\n")
    check seen > 100
    check missing.len == 0

  test "the failures marked (run) give the text of the page":
    let plain = server()
    let tlsOnly = server(tlsServerConfig(pem"server.pem", pem"server.key"))
    let mutual = server(tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"ca.pem"))
    let single = server(limits = Limits(maxConnections: 1))
    defer:
      for s in [plain, tlsOnly, mutual, single]: s.stop()
    let ca = tlsClientConfig(pem"ca.pem")

    shows(call(freePort()), "scUnavailable", "Connection refused")
    let unresolved = failure:
      discard dial("no-such-host.invalid", 50051)
    shows(unresolved, "scUnavailable", "Name or service not known")
    shows(call(plain.port, "/t.T/Nope"), "scUnimplemented", "unknown method /")
    shows(call(plain.port, "/t.T/Slow", timeoutMs = 200), "scDeadlineExceeded", "deadline exceeded")
    let hidden = call(plain.port, "/t.T/Broken")
    shows(hidden, "scUnknown", "internal error")
    check "secret" notin hidden
    shows(call(plain.port, req = newSeq[byte](5 * 1024 * 1024)), "scResourceExhausted", "exceeds the limit of")
    shows(call(plain.port, "/t.T/Large"), "scResourceExhausted", "exceeds the limit of")
    shows(call(plain.port, compression = "br"), "scInvalidArgument", "unsupported compression \"")
    shows(call(tlsOnly.port), "scUnavailable", "connection closed by peer")
    shows(call(plain.port, tls = ca, name = "localhost"), "scUnavailable",
          "TLS: unsupported protocol version (TLS 1.2 is required)")
    shows(call(tlsOnly.port, tls = tlsClientConfig(pem"otherca.pem"), name = "localhost"),
          "scUnavailable", "TLS: certificate not signed by a trusted CA")
    shows(call(tlsOnly.port, tls = ca, name = "example.com"), "scUnavailable",
          "TLS: server name does not match the certificate")
    shows(call(mutual.port, tls = ca, name = "localhost"), "scUnavailable", "connection closed by peer")

    let first = dial("127.0.0.1", single.port)
    discard first.unaryCall("/t.T/Echo", @[1'u8], timeoutMs = 5000)
    shows(call(single.port), "scUnavailable", "connection closed by peer")
    first.close()
    let afterClose = failure:
      discard first.unaryCall("/t.T/Echo", @[1'u8])
    shows(afterClose, "scUnavailable", "channel closed")

    let badIdentity = failure:
      discard tlsServerConfig("not a certificate", "nor a key")
    shows(badIdentity, "TlsError", "identity: no certificate in chain")
    let badCa = failure:
      discard tlsClientConfig("not a certificate")
    shows(badCa, "TlsError", "CA: no certificate in CA bundle")

suite "supported-versions page":
  let versions = readFile(root / "docs" / "supported-versions.md")
  let nimble = readFile(root / "nimgrpc.nimble")
  let ci = readFile(root / ".github" / "workflows" / "ci.yml")

  proc after(s, mark: string; stop: set[char]): string =
    let at = s.find(mark)
    doAssert at >= 0, mark
    var i = at + mark.len
    while i < s.len and s[i] notin stop:
      result.add s[i]
      inc i

  test "the release, and the lowest Nim, bearssl and chronos, are those of nimgrpc.nimble":
    check ("| " & nimble.after("version       = \"", {'"'}) & " ✔") in versions
    check ("| Nim | " & nimble.after("\"nim >= ", {'"'}) & " ✔") in versions
    check ("| bearssl (nimble) | " & nimble.after("\"bearssl >= ", {'"'}) & " ✔") in versions
    check ("| chronos (nimble) | " & nimble.after("\"chronos >= ", {'"'}) & " ✔") in versions

  test "the Nim versions and nghttp2 are those of the CI workflow":
    let nims = ci.after("nim: [", {']'}).split(',').mapIt(it.strip(chars = {' ', '\'', '"'}))
    check nims.len >= 2
    check ("| " & nims.join(", ") & " ✔ in CI") in versions
    check ("| " & ci.after("NGHTTP2_VERSION: ", {'\n'}).strip & " ✔ in CI") in versions

  test "the lowest nghttp2 is the one the source refuses to build below":
    let header = readFile(root / "src" / "nimgrpc" / "h2" / "nghttp2.nim")
    let lowest = header.after("nimgrpc needs nghttp2 ", {' '})
    check ("| nghttp2 | " & lowest & " ✔") in versions
    check ("needs nghttp2 " & lowest) in page

suite "index of the documents":
  test "docs/README.md lists every page of docs/":
    let index = readFile(root / "docs" / "README.md")
    for f in walkFiles(root / "docs" / "*.md"):
      let name = f.extractFilename
      if name != "README.md":
        checkpoint name
        check ("](" & name & ")") in index
