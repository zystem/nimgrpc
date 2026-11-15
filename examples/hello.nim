## The smallest program: a server and a client in one process, on raw message bytes, with no
## generated code and no .proto file.
##   nim c -r examples/hello.nim
import nimgrpc

proc bytes(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))
proc text(b: seq[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc sayHello(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  if req.len == 0: raise newGrpcError(scInvalidArgument, "empty name")
  bytes("Hello, " & text(req))

let srv = newGrpcServer(port = 0)                  # 0: any free port
srv.addUnary("/hello.Greeter/SayHello", sayHello)
srv.start()
echo "server started"

let ch = dial("127.0.0.1", srv.port)
echo "reply: ", text(ch.unaryCall("/hello.Greeter/SayHello", bytes("Nim"), timeoutMs = 1000).message)
try:
  discard ch.unaryCall("/hello.Greeter/SayHello", @[], timeoutMs = 1000)
except GrpcError as e:
  echo "error: ", e.code, ": ", e.msg
ch.close()
srv.stop()
echo "server stopped"
