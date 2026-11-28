# Security reviews

Reference: the reviews of the library and what became of their findings.

| Review | Revision | Note |
|---|---|---|
| [21 November 2026](SECURITY-REVIEW-2026-11-21.en.md): audit and choice of TLS 1.3 | `3f257a1` | translated from Russian |
| [22 November 2026](SECURITY-REVIEW-2026-11-22.en.md): reassessment | `6625671` | |

Each report speaks of its own revision and is not updated: what it says is missing may exist now.
The links to files lead to the current code, not to the reviewed revision. The tables below say
what was done up to 28 November 2026; [../../CHANGELOG.md](../../CHANGELOG.md) has the details,
with what was and was not run.

## 21 November

| Finding | State | Where |
|---|---|---|
| 1. No limit of waiting work in the blocking server | fixed; the limit of waiting calls and of their bytes is on by default, the streaming quota is not | pull requests 69, 74 |
| 2. A TlsConfig could be changed while in use | fixed: it freezes on first use; no reload of certificates | pull request 70 |
| 3. A failed peer check could pass when asked again | fixed | pull request 72 |
| 4. The wiping of a connection was optimized away | fixed | pull request 73 |
| 5. Failed allocations in the PEM loader | fixed | pull request 73 |
| 6. Protobuf bounds of varints and tags | fixed | pull request 71 |
| The handler did not learn who the client is | done: `ctx.peer` | pull request 78 |
| Choice of a TLS 1.3 backend | open, put off on 28 November 2026: the library speaks TLS 1.2; the sizes were not compared | |

## 22 November

| Finding | State | Where |
|---|---|---|
| The byte budget was checked and taken in two steps; trailers were not charged | fixed | pull request 81 |
| `realloc` could leave a private key in memory | fixed; the PEM string the program passes stays its own to wipe | pull request 81 |
| Limits off by default, availability under load | documented, with counters and a load test (`tools/admission.nim`); `maxConnections` (4096) and `maxConnectionIdleMs` (15 minutes) are on by default since 0.9.0; the limits that would cut long streams stay off | pull request 81, release 0.9.0 |
| Client identity and revocation | identity: `ctx.peer`. Revocation: a deny list by fingerprint (`denyCertificate`); **no CRL, no OCSP** | pull requests 78, 81, release 0.9.0 |
| Precondition of building a config on one thread; the C comment on threads; the allocation test | fixed | pull request 81 |
| The TLS pump takes 16 KiB before it knows what is ready | fixed: profiling showed that a peer that does not read could make a connection take hundreds of MiB | release 0.8.0, [GHSA-6p4v-6g7c-g9hv](https://github.com/zystem/nimgrpc/security/advisories/GHSA-6p4v-6g7c-g9hv) |
| TLS 1.3 | open, put off on 28 November 2026 | |
| Constant time of the cryptographic backend | partly: the implementations chosen are pinned by `tests/tcryptoimpl.nim`; no timing measurement | CHANGELOG |
| ARM | the tests run on arm64 in CI; the static size was not measured there | [../supported-versions.md](../supported-versions.md) |
| Long soak | the chronos server, 8 hours, plain and TLS: memory and descriptors held steady; the blocking server: not run | CHANGELOG |
| Replacing certificates without a restart | not done, by decision: start a new server | [../production.md](../production.md) |

What to set on a server that faces clients is in [../production.md](../production.md).
