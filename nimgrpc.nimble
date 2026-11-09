version       = "0.3.0"
author        = "zystem"
description   = "gRPC for Nim on top of nghttp2"
license       = "MIT"
srcDir        = "src"
bin           = @["protoc_gen_nim"]
installExt    = @["nim", "c"]

requires "nim >= 2.2.12", "bearssl >= 0.3.1", "chronos >= 4.0.4"

const tests = ["tests/th2session.nim", "tests/tblocking.nim", "tests/tgrpc.nim",
               "tests/ttls.nim", "tests/tcodec.nim", "tests/tkeepalive.nim",
               "tests/twkt.nim", "tests/tasynch2.nim", "tests/tasyncgrpc.nim",
               "tests/tlimits.nim", "tests/tasynclimits.nim", "tests/tchannelclose.nim", "tests/tipv6.nim",
               "tests/thandshake.nim", "tests/tconnage.nim", "tests/tconnageasync.nim",
               "tests/thealth.nim", "tests/thealthclient.nim", "tests/treflection.nim",
               "tests/tretry.nim", "tests/teyeballs.nim"]

proc runAll(flags, tag: string) =
  # A separate nimcache per flag set: Nim reuses C objects across --passC changes.
  for t in tests:
    exec "nim c -r --hints:off --nimcache:nimcache/" & tag & " " & flags & " " & t

task test, "Run the unit tests":
  runAll("", "plain")

task asan, "Run the tests under AddressSanitizer/LeakSanitizer":
  runAll("-d:useMalloc --debugger:native " &
         "--passC:-fsanitize=address --passL:-fsanitize=address", "asan")

task tsan, "Run the tests under ThreadSanitizer":
  runAll("-d:useMalloc --debugger:native " &
         "--passC:-fsanitize=thread --passL:-fsanitize=thread", "tsan")

task lint, "Style (NEP-1) and warnings: nothing may be reported":
  # `nim check` of the library, the plugin, the tests and the tools with the
  # style check as an error and warnings on; any "Warning:" fails the task.
  # NIMGRPC_FLAGS adds compiler flags (for example -d:nghttp2Prefix=...).
  var files = @["src/nimgrpc.nim", "src/nimgrpc/asyncclient.nim",
                "src/nimgrpc/asyncserver.nim", "src/nimgrpc/asynctyped.nim",
                "src/nimgrpc/typed.nim", "src/nimgrpc/wkt.nim",
                "src/protoc_gen_nim.nim"]
  for t in tests: files.add t
  for t in ["asyncbench", "asyncload", "fuzz", "h2specasync", "h2specserver",
            "hsbench", "tlsbench"]:
    files.add "tools/" & t & ".nim"
  var bad = 0
  for f in files:
    let (output, code) = gorgeEx("nim check --hints:off --warnings:on " &
      "--styleCheck:error -p:tests/gen " & getEnv("NIMGRPC_FLAGS") & " " & f)
    if code != 0 or "Warning:" in output:
      echo "FAILED: ", f, "\n", output
      inc bad
  if bad > 0: quit "lint: " & $bad & " file(s) fail"
  echo "lint: ", files.len, " files clean"

task coverage, "Statement coverage of src/nimgrpc (fails under 80%)":
  exec "tools/coverage.sh"
