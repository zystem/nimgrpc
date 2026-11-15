## The same service on chronos: server and client on one thread, in one process.
##   nim c -r examples/greeter/async.nim
import std/options
import pkg/chronos
import nimgrpc/asynctyped
import ./hello_pb

proc sayHello(ctx: AsyncServerContext; req: HelloRequest): Future[HelloReply] {.async.} =
  return HelloReply(message: "Hello, " & req.name)

proc sayHelloStream(ctx: AsyncServerContext; req: HelloRequest;
                    output: AsyncServerWriter[HelloReply]) {.async.} =
  let count = if req.count > 0: int(req.count) else: 3
  for i in 1 .. count:
    await output.send(HelloReply(message: "Hello, " & req.name & " (" & $i & " of " & $count & ")"))

proc main() {.async.} =
  let srv = newAsyncGrpcServer(port = 0)             # 0: any free port
  srv.registerGreeter(GreeterAsyncHandlers(sayHello: sayHello, sayHelloStream: sayHelloStream))
  srv.start()

  let ch = await dialAsync("127.0.0.1", srv.port)
  let greeter = newGreeterAsyncClient(ch)
  echo (await greeter.sayHello(HelloRequest(name: "chronos"), timeoutMs = 2000)).message

  let replies = await greeter.sayHelloStream(HelloRequest(name: "chronos", count: 2), timeoutMs = 2000)
  while true:
    let reply = await replies.recv()
    if reply.isNone: break
    echo reply.get.message
  replies.close()

  await ch.close()
  await srv.stop()

waitFor main()
