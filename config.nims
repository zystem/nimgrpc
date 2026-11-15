import std/strutils
switch("path", thisDir() & "/src")
switch("mm", "orc")
switch("panics", "on")
# nghttp2: the library looks in /opt/nghttp2 unless -d:nghttp2Prefix says otherwise. Inside this
# repository NGHTTP2_PREFIX, or a build made by tools/build-nghttp2.sh (deps/nghttp2), is used
# when the command line names none.
if existsEnv("NGHTTP2_PREFIX"):
  switch("define", "nghttp2Prefix=" & getEnv("NGHTTP2_PREFIX"))
elif dirExists(thisDir() & "/deps/nghttp2"):
  switch("define", "nghttp2Prefix=" & thisDir() & "/deps/nghttp2")
# Dependencies outside nimble's reach (e.g. a sandbox): point at checkouts.
if existsEnv("NIM_BEARSSL"): switch("path", getEnv("NIM_BEARSSL"))
# Extra checkouts (chronos and its deps), separated by ':'.
if existsEnv("NIM_PATHS"):
  for p in getEnv("NIM_PATHS").split(':'):
    if p.len > 0: switch("path", p)
# Hardening of what this repository builds (the C parts and the generated C of
# a release build); a program that links the library passes the same flags.
when defined(release) or defined(danger):
  switch("passC", "-fstack-protector-strong -D_FORTIFY_SOURCE=2")
# The standard variables of a build are honoured and only added to: a packager's
# CC, CFLAGS and LDFLAGS reach the C compiler and the linker (Nim itself reads
# them only with --cc:env).
if existsEnv("CC"):
  switch("gcc.exe", getEnv("CC"))
  switch("gcc.linkerexe", getEnv("CC"))
if existsEnv("CFLAGS"): switch("passC", getEnv("CFLAGS"))
if existsEnv("LDFLAGS"): switch("passL", getEnv("LDFLAGS"))
