#!/usr/bin/env python3
"""Reads the JUnit report of h2spec and compares the failed tests with the ones that are known.

    tools/h2spec_check.py REPORT.xml blocking|async

docs/h2spec.md explains each known failure (h2spec 2.6.0 follows RFC 7540, nghttp2 RFC 9113).
Exit status 1 when a test fails that is not in the list, so a new failure is noticed; a known
failure that now passes is only reported.
"""
import sys
import xml.etree.ElementTree as ET

# "section: test name" as h2spec writes them (package, then the name of the test case)
KNOWN = {
    "blocking": set(),
    "async": set(),
}
# Until the lists above are filled from a first run in CI: how many may fail (docs/h2spec.md).
KNOWN_COUNT = {"blocking": 9, "async": 10}

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
    if known:
        new = [f for f in failed if f not in known]
        for f in sorted(known - set(failed)): print("  known failure that passes now:", f)
        if new: sys.exit("%d failure(s) not in the known list" % len(new))
    elif len(failed) > KNOWN_COUNT[adapter]:
        sys.exit("more failures than the %d that are known" % KNOWN_COUNT[adapter])

if __name__ == "__main__":
    main()
