## Code around every call: a server that checks a token and logs each call, and a client that adds
## the token, in one process.
##   nim c -r examples/interceptors.nim
import nimgrpc

proc bytes(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))
proc text(b: seq[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc sayHello(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  if text(req) == "nobody": raise newGrpcError(scNotFound, "no such person")
  bytes("Hello, " & text(req))

proc logCalls(ctx: var ServerContext; next: ServerNext; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ## Added first, so it is the outermost: it also sees the calls the next one refuses.
  var failure: ref CatchableError
  try:
    next.proceed(ctx)
  except CatchableError as e:        # no `finally`: see docs/nim-compiler-notes.md
    failure = e
  let code = if failure == nil: scOk
             elif failure of GrpcError: (ref GrpcError)(failure).code
             else: scUnknown
  echo "log: ", ctx.path, " ", code
  if failure != nil: raise failure   # raised outside the `except` block

proc checkToken(ctx: var ServerContext; next: ServerNext; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  let token = cast[ptr string](userData)[]      # `userData` is read only: thread-safe
  if ctx.metadata.get("authorization") != "Bearer " & token:
    raise newGrpcError(scUnauthenticated, "missing or wrong token")
  next.proceed(ctx)

proc addToken(info: var ClientCallInfo; next: ClientNext; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  info.metadata.add ("authorization", "Bearer " & cast[ptr string](userData)[])
  next.proceed(info)

var token = "s3cret"                               # must outlive the server and the channel

let srv = newGrpcServer(port = 0)
srv.addUnary("/hello.Greeter/SayHello", sayHello)
srv.addInterceptor(logCalls)
srv.addInterceptor(checkToken, token.addr)
srv.start()

proc call(ch: GrpcChannel; name: string) =
  try:
    echo "reply: ", text(ch.unaryCall("/hello.Greeter/SayHello", bytes(name), timeoutMs = 1000).message)
  except GrpcError as e:
    echo "error: ", e.code, ": ", e.msg

let withToken = dial("127.0.0.1", srv.port)
withToken.addInterceptor(addToken, token.addr)
let noToken = dial("127.0.0.1", srv.port)          # a second channel: no interceptor

withToken.call("Nim")        # succeeds
noToken.call("Nim")          # refused by checkToken
withToken.call("nobody")     # the handler fails
withToken.close()
noToken.close()
srv.stop()
