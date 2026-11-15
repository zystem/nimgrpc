# Security policy

nimgrpc parses bytes from the network (HTTP/2, TLS, gRPC framing, Protobuf), so a report of a weakness is welcome and is read first.

## Reporting

- Use GitHub's private vulnerability reporting for this repository (Security → Report a vulnerability), or write to the maintainer at the address on the commits (a noreply address is used there; ask for a private channel in a first message that holds no details).
- Do not put details of an unfixed problem into a public issue.
- Say what you saw, on which commit, and how to see it again; a failing test is the best report.

## Coordinated disclosure, and the timeframe

- **Acknowledgement** within 7 days of a report; an assessment (confirmed, not reproducible, not a vulnerability) within 14 days.
- **Fix**: a confirmed problem is fixed and tested first; for High and Critical severity the target is a release within 30 days, for the rest the next release. The reporter is told when the fix is ready.
- **Disclosure**: after the fix is released, or after 90 days from the report if no fix is possible, whichever is first (earlier by agreement). The problem is then described in [CHANGELOG.md](CHANGELOG.md) and in a GitHub security advisory, with the people who reported it named if they wish.
- **Contact**: the private vulnerability reporting of this repository is the security contact; there is no other channel to a person, to keep reports out of public places.

## What is supported

- **Scope**: the latest release (all fixes of security problems are made there) and the head of `main`. An earlier release does not get a fix: update to the latest.
- **Duration**: a release is supported until the next release is made. The project is young (version 0.x) and has no long-term-support line ([docs/supported-versions.md](docs/supported-versions.md)).
- **End of support**: it is said in the release notes of the release that replaces it.

The threat model is in [docs/threat-model.md](docs/threat-model.md), the policies for dependencies and analysis in [docs/security-policies.md](docs/security-policies.md), how the project is run in [GOVERNANCE.md](GOVERNANCE.md).

## Verifying a release

Release tags are signed with the maintainer's SSH key (`git tag -s`), from the first release made after 0.2.0; the tags `v0.0.1` to `v0.2.0` are not signed. The library is distributed as source: a tag is the release, and there is no binary to sign. The public key is in [docs/allowed_signers](docs/allowed_signers) (key type ed25519, fingerprint `SHA256:lW4afK66UsIcTD4xXiwz2vutEsLvEYqYk+pTx+MuPHo`) and in the maintainer's GitHub account (Settings → SSH and GPG keys, as a signing key), so GitHub shows "Verified" on the tag. To check one yourself:

```
git clone https://github.com/zystem/nimgrpc && cd nimgrpc
git -c gpg.ssh.allowedSignersFile=docs/allowed_signers tag -v vX.Y.Z
```

The output must say `Good "git" signature` and show the fingerprint above; compare the fingerprint with the one on the maintainer's GitHub profile, since the file in the repository is only as trustworthy as the repository. A change of the key is announced in the release notes and made in a commit that the previous key signed.

## What helps a reviewer

- [docs/threat-model.md](docs/threat-model.md), [docs/architecture.md](docs/architecture.md), [docs/assurance-case.md](docs/assurance-case.md).
- Tests are the specification: `nimble test`; the same under AddressSanitizer and ThreadSanitizer (`nimble asan`, `nimble tsan`); interop against grpc-go ([docs/interop.md](docs/interop.md)) and h2spec ([docs/h2spec.md](docs/h2spec.md)).
