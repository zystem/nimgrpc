# h2spec results

h2spec 2.6.0 against `tools/h2specserver` (blocking adapter, h2c, nghttp2 1.68.0),
2026-10-31, after the streaming rework: **146 tests, 135 passed, 2 skipped, 9 failed.**
(Before it: 134 passed. The test in 5.1 "half closed (remote): DATA" now passes,
because handlers start when HEADERS arrive and reply only after reading the body.)

```sh
nim c -d:release tools/h2specserver.nim && tools/h2specserver 18080 &
h2spec -h 127.0.0.1 -p 18080
```

h2spec 2.6.0 is written against RFC 7540. nghttp2 follows RFC 9113, which
replaced it. All nine failures come from that difference or from the test server
answering every request at once. None points to a bug in the adapter so far.
Each one still has to be confirmed separately.

| Section | Test | Got | Why |
|:---|:---|:---|:---|
| 5.1 | closed: DATA / HEADERS after RST_STREAM (8, 9) | timeout | nghttp2 silently ignores frames on recently closed streams, which RFC 9113 §5.1 allows. |
| 5.1 | closed: DATA / HEADERS (11, 12) | timeout | Same as above. |
| 5.1.1 | stream id smaller than previous | DATA, then GOAWAY | The reply to stream 5 is sent before the bad HEADERS arrives, and h2spec looks only at the first frame. |
| 5.3.1 | PRIORITY that depends on itself | timeout | RFC 9113 deprecates priorities, and nghttp2 ignores PRIORITY frames. |
| 5.4.1 | invalid PING: expects a bare close | GOAWAY, then close | The test wants the TCP connection closed with no frame before it. Sending GOAWAY first is what RFC 9113 §5.4.1 asks for. |
| 6.3 | PRIORITY on stream 0 | timeout | PRIORITY frames are ignored (see 5.3.1). |
| 6.9.1 | window above 2^31-1 on a stream | GOAWAY (FLOW_CONTROL_ERROR) | nghttp2 treats this as a connection error, not a stream error. The connection still gets FLOW_CONTROL_ERROR. |

## chronos adapter

The same run against `tools/h2specasync` (2026-11-01): **146 tests, 134
passed, 2 skipped, 10 failed.** The nine failures above, plus one timing
artefact:

| Section | Test | Got | Why |
|:---|:---|:---|:---|
| 5.1 | half closed (remote): HEADERS (6) | DATA | The test server replies as soon as the request ends, before the stray HEADERS arrives, and h2spec looks only at the first frame. The blocking server passes because its worker thread replies a moment later. |

Still to do: rerun with a server that delays its replies, so the timing
artefact in 5.1.1 drops out.

## In CI

`tools/conformance.sh` runs h2spec against both adapters in the workflow `Hostile client` (weekly, and when its files change) and fails on a failure that is not one of those above (`tools/h2spec_check.py`). It also asks both servers for their services with grpcurl, a client of server reflection that this project did not write.
