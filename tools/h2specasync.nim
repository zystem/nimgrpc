## A plain HTTP/2 (h2c) server for running h2spec against the chronos adapter.
##   nim c -d:release tools/h2specasync.nim && tools/h2specasync 8081 &
##   h2spec -h 127.0.0.1 -p 8081
## With a second argument the reply waits that many milliseconds after the request has ended:
##   tools/h2specasync 8081 100
## h2spec sends a stray frame right after a request and looks at the first frame that comes
## back; without the wait the reply can leave first and close the stream (docs/h2spec.md).

import std/[os, strutils]
import pkg/chronos
import nimgrpc/h2/async

var delayMs = 0

proc handler(st: AsyncH2Stream; ud: pointer): Future[void] {.async.} =
  while (await st.recvData()).len > 0: discard     # read the whole request
  if delayMs > 0: await sleepAsync(delayMs.milliseconds)
  st.sendHeaders(@[(":status", "200"), ("content-type", "text/plain")])
  await st.send(@[byte('o'), byte('k')], endStream = true)

let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8081
if paramCount() >= 2: delayMs = parseInt(paramStr(2))
let srv = newAsyncStreamServer(handler, port = Port(port))
echo "listening on ", port
runForever()
