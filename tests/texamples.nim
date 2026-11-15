## The examples do what the documents say. Every `nim c -r examples/...` in a console block of
## README.md and examples/README.md is built and run here, and what it prints is compared with
## the lines that follow the command in that block. A changed example or a changed document
## fails until both agree.

import std/[unittest, os, osproc, strutils, streams, net, posix, sets]
import nimgrpc/h2/nghttp2

const
  root = currentSourcePath.parentDir.parentDir
  docs = ["README.md", "examples/README.md"]
  binDir = root / "nimcache" / "examples" / "bin"

type Step = object
  doc: string           ## the document the block is in
  file: string          ## examples/....nim
  output: seq[string]   ## what the document says it prints

var afterCtrlC: seq[string]   ## what the server prints once Ctrl-C is pressed ("^C..." blocks)

proc stepsOf(doc: string): seq[Step] =
  var inBlock, hasStep = false
  for line in lines(root / doc):
    if line.startsWith("```"):
      inBlock = line.strip == "```console"
      hasStep = false
    elif not inBlock: discard
    elif line.startsWith("$ "):
      let words = line.splitWhitespace()
      hasStep = words.len >= 5 and words[1 .. 3] == ["nim", "c", "-r"] and words[4].startsWith("examples/")
      if hasStep: result.add Step(doc: doc, file: words[4])
    elif line.startsWith("^C"): afterCtrlC.add line[2 .. ^1]
    elif hasStep: result[^1].output.add line

proc build(file: string; flags = ""): string =
  ## Builds an example the way the documents do, against the nghttp2 this test was built with.
  result = binDir / file.splitFile.name
  let cmd = "nim c --nimcache:" & quoteShell(root / "nimcache" / "examples" / file.splitFile.name) &
    " -d:nghttp2Prefix=" & quoteShell(nghttp2Prefix) & " " & flags & " " & getEnv("NIMGRPC_FLAGS") &
    " -o:" & quoteShell(result) & " " & quoteShell(file)
  let (output, code) = execCmdEx(cmd, workingDir = root)
  if code != 0: raise newException(IOError, cmd & " failed:\n" & output)
  # the documents say a build that succeeds prints nothing
  if output.strip.len > 0: raise newException(IOError, cmd & " printed:\n" & output)

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = s.getLocalAddr()[1].int
  s.close()

proc printed(bin: string; args: openArray[string] = []): seq[string] =
  let p = startProcess(bin, workingDir = root, args = args, options = {poStdErrToStdOut})
  let text = p.outputStream.readAll()
  doAssert p.waitForExit() == 0, bin & " failed:\n" & text
  p.close()
  text.strip(leading = false).splitLines()

var all: seq[Step]
for d in docs: all.add stepsOf(d)

suite "the examples print what the documents show":
  test "the documents show every example":
    var shown: HashSet[string]
    for s in all: shown.incl s.doc & ": " & s.file
    check "README.md: examples/hello.nim" in shown
    for f in ["hello", "greeter/server", "greeter/client", "greeter/async"]:
      check "examples/README.md: examples/" & f & ".nim" in shown
    check afterCtrlC == @["stopped"]

  test "the programs that run by themselves":
    var ran = 0
    for s in all:
      if s.file.endsWith("server.nim") or s.file.endsWith("client.nim"): continue
      checkpoint s.doc & ": " & s.file
      check printed(build(s.file)) == s.output
      inc ran
    check ran >= 3

  test "the server and the client, in two processes":
    var serverOut, clientOut: seq[string]
    for s in all:
      if s.file.endsWith("server.nim"): serverOut = s.output
      if s.file.endsWith("client.nim"): clientOut = s.output
    check serverOut == @["listening on 127.0.0.1:50051"]   # the port it takes when given none
    let server = build("examples/greeter/server.nim")
    let client = build("examples/greeter/client.nim")
    let port = freePort()
    let p = startProcess(server, workingDir = root, args = [$port], options = {poStdErrToStdOut})
    check p.outputStream.readLine() == "listening on 127.0.0.1:" & $port
    check printed(client, [$port]) == clientOut
    check posix.kill(Pid(p.processID), SIGINT) == 0          # Ctrl-C
    check p.outputStream.readAll().strip.splitLines() == afterCtrlC
    check p.waitForExit() == 0
    p.close()

  test "hello_pb.nim is what protoc-gen-nim makes from hello.proto":
    if findExe("protoc").len == 0:
      skip()
    else:
      let plugin = build("src/protoc_gen_nim.nim", "--hints:off")   # as step 5 of the tutorial
      let outDir = root / "nimcache" / "examples" / "gen"
      createDir outDir
      let (output, code) = execCmdEx("protoc --plugin=protoc-gen-nim=" & quoteShell(plugin) &
        " --nim_out=" & quoteShell(outDir) & " --nim_opt=blocking,async,descriptor" &
        " -Iexamples/greeter hello.proto", workingDir = root)
      check code == 0 and output.strip.len == 0
      check readFile(outDir / "hello_pb.nim") == readFile(root / "examples" / "greeter" / "hello_pb.nim")
