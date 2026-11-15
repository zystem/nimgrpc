# Examples: a first service, step by step

A tutorial: one path, and after each command what it prints. It starts where
[Try it](../README.md#try-it) of the README ends: the repository is cloned, `nimble install -y
--depsOnly` has run and `tools/build-nghttp2.sh` has built nghttp2 into `deps/nghttp2`. Run every
command from the root of the repository. The compiler prints nothing here when it succeeds
(`examples/config.nims` turns its hints off), and a build takes a few seconds.

Each step is checked by `tests/texamples.nim`: it runs the programs and compares what they print
with the blocks below.

## 1. A call without generated code

[hello.nim](hello.nim) starts a server on a free port, registers one handler that works on the
raw bytes of a message, calls it twice from a client in the same process (the second call sends
an empty name and gets an error) and stops the server.

```console
$ nim c -r examples/hello.nim
server started
reply: Hello, Nim
error: scInvalidArgument: empty name
server stopped
```

## 2. A service from a .proto file: the server

[greeter/hello.proto](greeter/hello.proto) describes a service `hello.Greeter` with a unary
method `SayHello` and a method `SayHelloStream` that answers with a stream.
[greeter/hello_pb.nim](greeter/hello_pb.nim) is the code `protoc-gen-nim` made from it (step 5
makes it again). [greeter/server.nim](greeter/server.nim) fills in the two handlers and adds the
health service and reflection. Start it and leave it running:

```console
$ nim c -r examples/greeter/server.nim
listening on 127.0.0.1:50051
```

## 3. The client

In a second terminal, [greeter/client.nim](greeter/client.nim) makes a unary call, reads a
stream of two replies and makes a call that the server refuses:

```console
$ nim c -r examples/greeter/client.nim
Hello, Nim
Hello, Nim (1 of 2)
Hello, Nim (2 of 2)
scInvalidArgument: name is empty
```

Back in the first terminal, press Ctrl-C. The server reports NOT_SERVING to health checks, lets
running calls finish and stops:

```console
^Cstopped
```

## 4. The same on chronos

[greeter/async.nim](greeter/async.nim) runs the same service and a client on one thread. The
handlers and the calls return futures; the generated file is the same (it was made with
`--nim_opt=blocking,async`).

```console
$ nim c -r examples/greeter/async.nim
Hello, chronos
Hello, chronos (1 of 2)
Hello, chronos (2 of 2)
```

## 5. Generating the code again

This step needs `protoc` (the package `protobuf-compiler` on Debian and Ubuntu). Build the
plugin, run it on the `.proto` file and see that it gives the file that is already there:

```console
$ nim c -d:release --hints:off -o:tools/protoc-gen-nim src/protoc_gen_nim.nim
$ protoc --plugin=protoc-gen-nim=tools/protoc-gen-nim --nim_out=examples/greeter --nim_opt=blocking,async,descriptor -Iexamples/greeter hello.proto
$ git status --short examples/greeter
```

None of the three prints anything: the generated file did not change. Now add a field or a
method to `hello.proto`, run the second command again, and the compiler will tell you which
handlers and calls to write.

## 6. Code around every call

[interceptors.nim](interceptors.nim) is the program of step 1 with two interceptors on the server and
one on the client. A server interceptor runs around every call to a method. Here the first
one logs the path and the status of each call, and the second refuses a call whose
`authorization` metadata is not the token. The client interceptor adds the token. The program
makes three calls: one that succeeds, one on a second channel that has no client interceptor
(so it sends no token), and one where the handler fails. Each `log:` line is printed by the
server, each `reply:` or `error:` line by the client. [docs/interceptors.md](../docs/interceptors.md)
says what an interceptor can and cannot do.

```console
$ nim c -r examples/interceptors.nim
log: /hello.Greeter/SayHello scOk
reply: Hello, Nim
log: /hello.Greeter/SayHello scUnauthenticated
error: scUnauthenticated: missing or wrong token
log: /hello.Greeter/SayHello scNotFound
error: scNotFound: no such person
```

## Next

- What every call, option and limit is: [Using the library](../README.md#using-the-library) in
  the README, and [docs/async.md](../docs/async.md) for chronos.
- TLS and mutual TLS: the TLS paragraph of the README; a whole client is
  [static_client.nim](static_client.nim), built in [docs/static-build.md](../docs/static-build.md).
- A server that faces clients you do not trust: the "slow or stalled peer" row of
  [docs/threat-model.md](../docs/threat-model.md).

What was run: steps 1 to 5 on 2026-11-15, on Linux Mint 22.3 (x86-64) with Nim 2.4.0, nghttp2 1.68.1 and protoc
3.21.12, in a fresh clone; step 6 on 2026-11-16 on Linux x86-64 with Nim 2.4.0 and nghttp2 1.68.0, in the working tree.
