## A coverage-guided fuzzer (libFuzzer) over the parsers that face the network: gRPC framing,
## gzip, Protobuf decoding and the HTTP/2 session. One binary per target; build and run it with
## tools/libfuzz.sh. The targets and their seeds are those of tools/fuzz.nim (tools/fuzztargets.nim).
##
## The errors a parser may raise on bad input (ProtobufError, GrpcError, H2Error) are fine;
## anything else is a finding, and so are a crash, a sanitizer report and a hang.

import ./fuzztargets

const fuzzTarget {.strdefine.} = "frames"

proc nimMain() {.importc: "NimMain", cdecl.}
proc cAbort() {.importc: "abort", header: "<stdlib.h>", noreturn.}

proc LLVMFuzzerInitialize(argc: ptr cint; argv: ptr pointer): cint {.exportc, cdecl.} =
  nimMain()     # --noMain: libFuzzer has the main function
  0

proc LLVMFuzzerTestOneInput(data: ptr UncheckedArray[byte]; size: csize_t): cint
    {.exportc, cdecl.} =
  var d = newSeq[byte](size.int)
  if size > 0: copyMem(d[0].addr, data, size.int)
  try:
    when fuzzTarget == "frames": tFrames(d)
    elif fuzzTarget == "gzip": tGzip(d)
    elif fuzzTarget == "everything": tEverything(d)
    elif fuzzTarget == "legacy": tLegacy(d)
    elif fuzzTarget == "wkt": tWkt(d)
    elif fuzzTarget == "h2server" or fuzzTarget == "h2client":
      # the first two bytes say where the input is cut into two reads
      if d.len >= 2:
        splitAt = d[0].int shl 8 or d[1].int
        when fuzzTarget == "h2server": tH2Server(d[2 .. ^1])
        else: tH2Client(d[2 .. ^1])
    elif fuzzTarget == "tlsserver" or fuzzTarget == "tlsclient":
      # two bytes for the cut, then the byte that picks the configuration
      if d.len >= 3:
        splitAt = d[0].int shl 8 or d[1].int
        when fuzzTarget == "tlsserver": tTlsServer(d[2 .. ^1])
        else: tTlsClient(d[2 .. ^1])
    else: {.error: "unknown -d:fuzzTarget".}
  except Exception:
    cAbort()    # an error the parser should not raise: libFuzzer keeps the input
  0
