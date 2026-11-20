# Security policies of the project

The rules the project holds itself to; the automatic parts are in [`.github/workflows/`](../.github/workflows/).

## Findings in dependencies and licenses (software composition analysis)

The library depends on `bearssl` and `chronos` (nimble, and their dependencies), and links nghttp2 and zlib (C). Tools: Dependabot for the GitHub Actions of the CI, Renovate (`renovate.json`) for the Nim version the CI uses (Dependabot cannot see it), Dependency Review on every pull request (it fails on a vulnerability of High or Critical severity and on a license outside an allowed list), and a review of the security announcements of nghttp2, BearSSL and zlib when a release is made (their advisories are public: nghttp2.org, bearssl.org, zlib.net). Nimble has no lock file here and no automatic scanner, so this part is manual and is a known gap.

Threshold for remediation of a finding about a vulnerability:

| Severity (CVSS) | A fix exists | No fix exists |
|---|---|---|
| Critical, High | fixed before the next release, and at once if the vulnerable code is reachable (nghttp2 is rebuilt at the fixed version and `NGHTTP2_VERSION` in CI and in [building.md](building.md) is raised) | the finding is recorded with the reason it is not exploitable; a mitigation is applied if it is reachable |
| Medium | within 30 days | recorded |
| Low | at the next routine update | none |

Licenses: dependencies must be under permissive licenses (MIT, BSD, Apache-2.0, ISC, MPL-2.0); Dependency Review accepts only an allowed list of such licenses and refuses the rest, in particular copyleft (GPL, AGPL).

**Before a release**: CI of the tagged commit must be green (all tests plainly and under AddressSanitizer), and the advisories of nghttp2, BearSSL and zlib are read. A release is not made while a Critical or High finding with a fix is open. A finding that is accepted instead of fixed is written into [CHANGELOG.md](../CHANGELOG.md) with the reason.

## Findings of dynamic analysis

Tools: AddressSanitizer and LeakSanitizer on every push and pull request (`nimble asan`), ThreadSanitizer by hand before a release (`nimble tsan`), the Nim compiler's own warnings. CodeQL does not support Nim, and the project knows of no static analyser for Nim beyond the compiler.

Fuzzing: `tools/fuzz.nim` feeds mutated valid inputs to the parsers that face the network (gRPC framing, gzip, Protobuf for three message types, the HTTP/2 session) under AddressSanitizer, weekly (`.github/workflows/fuzz.yml`); a crash or hang uploads the input and opens an issue, and is fixed with a regression test. A second fuzzer, `tools/libfuzz.nim` (libFuzzer, clang, AddressSanitizer and UBSan; `tools/libfuzz.sh TARGET [SECONDS]`), is coverage-guided over the same targets, the HTTP/2 client session among them, and runs in the same workflow, its corpus kept in the cache between runs. Its targets include the TLS records a client sends to a server and a server to a client (the handshake, with and without client certificates), through BearSSL. It instruments our code, BearSSL and, when `deps/nghttp2-fuzz` and `deps/zlib-fuzz` exist (the weekly run builds them: `FUZZ=1 tools/build-nghttp2.sh`, `tools/build-zlib-fuzz.sh`), nghttp2 and zlib, with the sanitizers on; the UBSan check `function` is off, because Nim names the types of the callbacks it gives nghttp2 differently from nghttp2's header. ThreadSanitizer runs the whole suite every night (`tsan.yml`).

Long-running checks: the weekly soak test (`.github/workflows/soak.yml`, `tools/soak.sh`) runs the chronos server under connection churn for 15 minutes, plain and TLS, and fails on growth of resident memory or open descriptors; an issue is opened on a breach. The weekly hostile-client run (`.github/workflows/hostile.yml`, `tools/hostile.sh`, `tools/conformance.sh`) sends both servers the floods, bombs and abandoned calls of the pentest of 2026-11-14 and runs h2spec and grpcurl; a failure opens an issue.

Threshold: a sanitizer report of any severity is fixed before the change is merged; a test that exposes it is added. CI fails on a report.

## Secrets and credentials

- No secret is in the repository (`.gitleaks.toml`, GitHub secret scanning and push protection). The keys under `tests/certs/` are throw-away keys for the TLS tests ([tests/certs/README.md](../tests/certs/README.md)).
- The library reads no secrets from the environment, files or the command line: the program passes TLS keys as arguments, and it is the program's job to store them.
- The CI uses no long-lived secret: it uses the short-lived `GITHUB_TOKEN` of the run only.
- A secret that leaked into the repository is treated as compromised: replaced first, then removed.

## Support of releases

See "What is supported" in [../SECURITY.md](../SECURITY.md).
