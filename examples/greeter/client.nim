## A client of hello.Greeter through generated code: a unary call, a call the server answers
## with a stream, and an error.
##   nim c -r examples/greeter/client.nim [PORT [NAME]]      (50051 and "Nim" when left out)
import std/[os, strutils]
import nimgrpc
import ./hello_pb

let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 50051
let name = if paramCount() >= 2: paramStr(2) else: "Nim"

let ch = dial("127.0.0.1", port)
let greeter = newGreeterClient(ch)

echo greeter.sayHello(HelloRequest(name: name), timeoutMs = 2000).message

var replies = greeter.sayHelloStream(HelloRequest(name: name, count: 2), timeoutMs = 2000)
var reply: HelloReply
while replies.recv(reply):               # false at the end; raises GrpcError on a status that is not OK
  echo reply.message
replies.close()

try:
  discard greeter.sayHello(HelloRequest(), timeoutMs = 2000)
except GrpcError as e:
  echo e.code, ": ", e.msg
ch.close()
