# Roadmap (November 2026 to November 2027)

What the project intends to do and not do in the next year. It is a plan of one maintainer, not a promise; items move when a user's need or a security problem asks for it. Done work is in [CHANGELOG.md](../CHANGELOG.md).

## Intends to do

1. **Coverage-guided fuzzing** (libFuzzer or ClusterFuzzLite) of the parsers that face the network. A mutation fuzzer (`tools/fuzz.nim`) over the Protobuf decoder, gRPC framing, gzip and the HTTP/2 session already runs weekly under AddressSanitizer.
2. **Memory per connection**: the heap profile (`tools/profile.sh`) shows 16 KiB of nghttp2 frame buffer and, with TLS, 40 KiB of BearSSL engine per connection; shrink them.
3. ~~**Limits**~~ (done in 0.2.0): a cap on concurrent streams, on connections and a buffer budget per connection, settable by the program (`Limits`). Still open: limits for a client, and a budget for decompressed messages.
4. **Interop breadth**: more cases against grpc-go and one more implementation (grpc-java or the C++ core); the remaining h2spec cases that can be met.
5. **Releases**: tag releases with notes, keep the changelog, publish to the nimble directory.
6. **Quality**: a regression test for every fixed bug; measure coverage if a tool for Nim becomes usable.
7. **A second maintainer and a second reviewer** (see [GOVERNANCE.md](../GOVERNANCE.md)).
8. **Badges**: the OpenSSF Best Practices badge at "passing", then as far as the project can honestly meet it.

## Considers (no date)

- Server reflection (the health checking service is done: `nimgrpc/health`).
- Per-call interceptors.
- HTTP/2 over a unix socket.

## Does not intend to do

- Being a gRPC-Web or HTTP/1.1 gateway.
- Authentication schemes beyond TLS, mTLS and metadata (the program decides).
- Pure-Nim replacements of nghttp2, BearSSL or zlib.
