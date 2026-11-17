## A plain HTTP/2 (h2c) server for running h2spec against the blocking adapter.
##   nim c -d:release tools/h2specserver.nim && tools/h2specserver 8080 &
##   h2spec -h 127.0.0.1 -p 8080
## With a second argument the reply waits that many milliseconds:
##   tools/h2specserver 8080 100
## h2spec sends a stray frame right after a request and looks at the first frame that comes
## back; without the wait the reply can leave first and close the stream (docs/h2spec.md).

import std/[os, strutils]
import nimgrpc/h2/blocking

var delayMs = 0     # set before the server starts, then only read

proc handler(req: Request; ud: pointer): Reply {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if delayMs > 0: sleep(delayMs)
  result.headers = @[(":status", "200"), ("content-type", "text/plain")]
  result.body = @[byte('o'), byte('k')]

let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8080
if paramCount() >= 2: delayMs = parseInt(paramStr(2))
let srv = newServer(handler, port = Port(port))
srv.start()
echo "listening on ", port
while true: sleep(1000)
