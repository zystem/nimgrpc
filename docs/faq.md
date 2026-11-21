# Questions

Short answers; the links say more. For an error message see [troubleshooting.md](troubleshooting.md).

## Choosing

**Blocking or chronos?** Blocking for a program that already uses threads, or a client with a
few calls. Chronos for many connections or calls on one thread, and for a server whose clients
hold calls open (`Health/Watch`, long streams): there a waiting call costs no thread
([async.md](async.md)). Both speak the same protocol and can be mixed in one program.

**Does it work with grpc-go, grpcurl, Envoy, Kubernetes probes?** grpc-go: yes, 18 interop cases
in both directions ([interop.md](interop.md)). grpcurl: yes, with reflection
(`tools/conformance.sh`). The health service is the standard `grpc.health.v1.Health` that
Kubernetes' `grpc` probe and Envoy call; a run against a real Kubernetes or Envoy: not run.

**TLS 1.3?** No. BearSSL has TLS 1.2 only. A peer that allows only TLS 1.3 cannot connect.

**gRPC-Web, HTTP/1.1, JSON transcoding?** No, and not planned ([roadmap.md](roadmap.md)). Put
a proxy that does it in front.

**Windows, macOS?** Not run. CI and the maintainer's runs are on Linux x86-64
([supported-versions.md](supported-versions.md)).

**Is it ready for production?** It is young: tested against grpc-go and h2spec, under
sanitizers, fuzzed and attacked by its own hostile client, but not run in large production
([security-requirements.md](security-requirements.md)). Read [production.md](production.md)
before exposing a server.

## Building

**Why must I build nghttp2?** The library links it statically, at a version it was tested
with, so a program does not depend on what the system has. It takes about ten seconds
(`tools/build-nghttp2.sh` in a clone, [building.md](building.md) otherwise).

**Can I use the system's nghttp2?** Only its static library: the build links
`PREFIX/lib/libnghttp2.a` and needs 1.61.0 or later. `-d:nghttp2Prefix=/usr` works where the
distribution ships `libnghttp2.a` there; not run.

**Do I need `protoc`?** Only to generate code from `.proto` files. The untyped API
(`addUnary`, `unaryCall` on bytes) needs none.

**Must I regenerate code after an upgrade?** Yes, as a rule: generated code and the library
are versioned together ([upgrading.md](upgrading.md) says when it does not matter).

## Using

**My server is not reachable from another host.** It listens on `127.0.0.1` by default. Pass
`address = "0.0.0.0"`, or `"::"` for IPv6 and IPv4.

**How do I know who the client is?** From metadata (`ctx.metadata`), which the program
checks. With mutual TLS the server admits only clients whose certificate the given CA signed,
but a handler is not told which certificate it was. A server interceptor can check the
metadata once for every call ([interceptors.md](interceptors.md)); it does not see the certificate either.

**How do I send an error with a code?** `raise newGrpcError(scNotFound, "no such user")` in
the handler. Anything else reaches the client as UNKNOWN `internal error`.

**Where are the logs?** There are none: the library prints nothing. `srv.setErrorHook(hook)`
gives the program each exception a handler did not turn into a `GrpcError`. To log or time
every call, use a server interceptor ([interceptors.md](interceptors.md)).

**Can I run code around every call (authentication, logging, metrics)?** Yes: add an interceptor
with `srv.addInterceptor` (or `ch.addInterceptor` on a client). It runs around every call, can
refuse it, and sees the metadata and the status but no messages. See
[interceptors.md](interceptors.md).

**Are calls retried?** `unaryCall` sends a call again, twice at most and within its deadline,
only when the server refused it before starting (`e.unprocessed`). Streaming calls and calls
that failed any other way are not retried.

**Does a channel reconnect?** Yes, at the next call after its connection closed or the server
sent GOAWAY. There is no connection pool and no load balancing: one channel is one connection.

**How large can a message be?** 4 MiB by default (`maxMessage`, per server and per call),
before and after decompression. For more, stream.

**How do I stop a server without cutting calls?** `h.shutdown()` if it has the health
service, then `srv.stop(graceMs = 5000)`: GOAWAY first, running calls get the grace.

**Can I change a server's certificate without a restart?** No call for it exists. Make a new
server with the new `TlsConfig` and stop the old one. A `TlsConfig` cannot change once a
connection, `share`, a server or a channel has it: its setters raise `TlsError`.

**Is a channel or a server safe to use from several threads?** A blocking channel: yes, calls
from several threads share its connection. A chronos channel and server belong to the thread
that runs their event loop. A `TlsConfig` given to several threads: `share(config)` for each.

## Project

**Which version gets fixes?** The latest release and `main` ([../SECURITY.md](../SECURITY.md)).

**How do I report a vulnerability?** Privately, through the repository's Security tab
([../SECURITY.md](../SECURITY.md)); not in an issue.

**How do I check a release?** `git tag -v` against `docs/allowed_signers`
([../SECURITY.md](../SECURITY.md), "Verifying a release").
