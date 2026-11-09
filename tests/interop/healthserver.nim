## A server with the health service, for tests/interop/health_interop.sh: grpc-go's health client
## checks it. The statuses change on a timeline the Go client knows:
##   at once        "" SERVING, "a.B" NOT_SERVING
##   after 1 step   "later.C" becomes SERVING
##   after 2 steps  shutdown(): everything NOT_SERVING
##   after 3 steps  the server stops
## Usage: healthserver PORT [STEP_MS]

import std/[os, strutils]
import ../../src/nimgrpc
import ../../src/nimgrpc/health

let port = parseInt(paramStr(1))
let step = if paramCount() >= 2: parseInt(paramStr(2)) else: 1500
let hs = newHealth()
hs.setStatus("a.B", hsNotServing)
let srv = newGrpcServer(port = port)
srv.register(hs)
srv.start()
echo "listening ", srv.port
stdout.flushFile
sleep step
hs.setStatus("later.C", hsServing)
sleep step
hs.shutdown()
sleep step
srv.stop()
