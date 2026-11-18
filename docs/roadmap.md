# Roadmap (November 2026 to November 2027)

What the project intends to do and not do in the next year. It is a plan of one maintainer, not a promise; items move when a user's need or a security problem asks for it. Done work is in [CHANGELOG.md](../CHANGELOG.md).

## Intends to do

1. ~~**Coverage-guided fuzzing**~~ (done in the next release): `tools/libfuzz.nim` (libFuzzer, clang) over the Protobuf decoder (three message types), gRPC framing, gzip and the HTTP/2 session, weekly in `.github/workflows/fuzz.yml` with the corpus kept between runs, next to the mutation fuzzer `tools/fuzz.nim`. Still open: ClusterFuzzLite on pull requests, a target for the HTTP/2 client session and for TLS records, and instrumenting nghttp2 and zlib (the harness instruments our own code; the libraries are linked as built).
2. **Memory per connection**: the heap profile (`tools/profile.sh`) shows 16 KiB of nghttp2 frame buffer and, with TLS, 40 KiB of BearSSL engine per connection; shrink them. Both sizes are fixed from outside (nghttp2's frame buffer is a compile-time constant, BearSSL's full-duplex buffers are its minimum), so the work went to our own tables: 10 KiB less per connection on 2026-11-18, see [async.md](async.md).
3. ~~**Limits**~~ (done in 0.2.0): a cap on concurrent streams, on connections and a buffer budget per connection, settable by the program (`Limits`). Limits for a client (`ClientLimits`: handshake timeout, size of response headers) are in the next release; a budget for decompressed messages per connection is not planned, as no other gRPC library has one (see [threat-model.md](threat-model.md)).
4. **Interop breadth**: more cases against grpc-go and one more implementation (grpc-java or the C++ core); the remaining h2spec cases that can be met.
5. **Releases**: tag releases with notes, keep the changelog, publish to the nimble directory.
6. **Quality**: a regression test for every fixed bug; measure coverage if a tool for Nim becomes usable.
7. **A second maintainer and a second reviewer** (see [GOVERNANCE.md](../GOVERNANCE.md)).
8. **Badges**: the OpenSSF Best Practices badge at "passing", then as far as the project can honestly meet it.

## Considers (no date)

- Reflection of extensions (the reflection service and the health checking service are done: `nimgrpc/reflection`, `nimgrpc/health`).
- HTTP/2 over a unix socket.

## Does not intend to do

- Being a gRPC-Web or HTTP/1.1 gateway.
- Authentication schemes beyond TLS, mTLS and metadata (the program decides).
- Pure-Nim replacements of nghttp2, BearSSL or zlib.
- The blocking server on `epoll` (no reader and writer thread per connection). Measured on 2026-11-17 ([async.md](async.md)): it would save two threads and about 100 KiB per idle connection but not the limit of about 256 open streaming calls; the chronos server covers both. Reconsidered if a user needs thousands of idle connections on the blocking server.
