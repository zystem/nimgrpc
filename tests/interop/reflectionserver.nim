## A server with the reflection service, for tests/interop/reflection_interop.sh: grpc-go's
## reflection client lists its services and builds the descriptors it gets.
## Usage: reflectionserver PORT [SECONDS]

import std/[os, strutils]
import ../../src/nimgrpc
import ../../src/nimgrpc/reflection
import ../gen/echo_pb

proc say(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = req

proc chat(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} = discard

let refl = newReflection()
refl.addFileDescriptor(fileDescriptorProto)
let srv = newGrpcServer(port = parseInt(paramStr(1)))
srv.addUnary("/reflect.test.Echo/Say", say)
srv.addStreaming("/reflect.test.Echo/Chat", chat)
srv.register(refl)
srv.start()
echo "listening ", srv.port
stdout.flushFile
sleep (if paramCount() >= 2: parseInt(paramStr(2)) else: 5) * 1000
srv.stop()
