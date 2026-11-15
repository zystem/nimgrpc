## A server of hello.Greeter (hello.proto) through generated code, with the health service and
## reflection beside it, until Ctrl-C.
##   nim c -r examples/greeter/server.nim [PORT]      (50051 when left out)
import std/[os, strutils]
import nimgrpc
import nimgrpc/[health, reflection]
import ./hello_pb

proc sayHello(ctx: var ServerContext; req: HelloRequest): HelloReply {.nimcall, gcsafe.} =
  if req.name.len == 0: raise newGrpcError(scInvalidArgument, "name is empty")
  HelloReply(message: "Hello, " & req.name)

proc sayHelloStream(ctx: var ServerContext; req: HelloRequest;
                    output: var ServerWriter[HelloReply]) {.nimcall, gcsafe.} =
  let count = if req.count > 0: int(req.count) else: 3
  for i in 1 .. count:
    ctx.checkCancelled()                 # the client left or its deadline passed: stop
    output.send HelloReply(message: "Hello, " & req.name & " (" & $i & " of " & $count & ")")

let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 50051
let srv = newGrpcServer(port = port)
srv.registerGreeter(GreeterHandlers(sayHello: sayHello, sayHelloStream: sayHelloStream))
let healthSvc = newHealth()              # grpc.health.v1.Health, what a Kubernetes probe calls
srv.register(healthSvc)
let refl = newReflection()               # lets grpcurl list and describe the services
refl.addFileDescriptor(hello_pb.fileDescriptorProto)
srv.register(refl)
srv.start()
echo "listening on 127.0.0.1:", srv.port

var stopping = false
setControlCHook(proc () {.noconv.} = stopping = true)
while not stopping: sleep(100)
healthSvc.shutdown()                    # NOT_SERVING first, then let running calls finish
srv.stop(graceMs = 2000)
echo "stopped"
