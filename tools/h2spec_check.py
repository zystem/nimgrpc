#!/usr/bin/env python3
"""Reads the JUnit report of h2spec and compares the failed tests with the ones that are known.

    tools/h2spec_check.py REPORT.xml blocking|async

docs/h2spec.md explains each known failure (h2spec 2.6.0 follows RFC 7540, nghttp2 RFC 9113).
Exit status 1 when a test fails that is not in the list, so a new failure is noticed; a known
failure that now passes is only reported.
"""
import sys
import xml.etree.ElementTree as ET

# "section: test name" as h2spec writes them. RFC: differences between RFC 7540, which h2spec
# 2.6.0 tests, and RFC 9113, which nghttp2 follows. RACES: the blocking test server answers as
# soon as its worker runs, the answer can leave before the stray frame of the test arrives, and
# h2spec looks only at the first frame it gets. The chronos test server is run with a delay
# before its answer (tools/conformance.sh), so these races are not allowed for it: without the
# delay they failed in 14 runs of 30, with it in none (docs/h2spec.md, 2026-11-16).
RFC = {
    "http2/5.1: closed: Sends a DATA frame after sending RST_STREAM frame",
    "http2/5.1: closed: Sends a HEADERS frame after sending RST_STREAM frame",
    "http2/5.1: closed: Sends a DATA frame",
    "http2/5.1: closed: Sends a HEADERS frame",
    "http2/5.1.1: Sends stream identifier that is numerically smaller than previous",
    "http2/5.3.1: Sends PRIORITY frame that depend on itself",
    "http2/5.4.1: Sends an invalid PING frame for connection close",
    "http2/6.3: Sends a PRIORITY frame with 0x0 stream identifier",
    "http2/6.9.1: Sends multiple WINDOW_UPDATE frames increasing the flow control window to above 2^31-1 on a stream",
}
RACES = {
    "http2/5.1: half closed (remote): Sends a HEADERS frame",
    'http2/6.1: Sends a DATA frame on the stream that is not in "open" or "half-closed (local)" state',
}
KNOWN = {"blocking": RFC | RACES, "async": RFC}

def main():
    if len(sys.argv) != 3 or sys.argv[2] not in KNOWN: sys.exit(__doc__)
    report, adapter = sys.argv[1], sys.argv[2]
    total = 0; failed = []
    for suite in ET.parse(report).getroot().iter("testsuite"):
        for case in suite.iter("testcase"):
            total += 1
            if case.find("failure") is not None or case.find("error") is not None:
                failed.append("%s: %s" % (case.get("package") or suite.get("name"), case.get("classname") or case.get("name")))
    print("%s adapter: %d tests, %d failed" % (adapter, total, len(failed)))
    for f in failed: print("  failed:", f)
    if total == 0: sys.exit("the report has no tests")
    known = KNOWN[adapter]
    new = [f for f in failed if f not in known]
    for f in sorted(known - set(failed)): print("  known failure that passed this time:", f)
    if new: sys.exit("%d failure(s) not in the known list" % len(new))

if __name__ == "__main__":
    main()
