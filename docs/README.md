# Documents

Each page is one kind ([Diátaxis](https://diataxis.fr)): a **tutorial** is one path that works,
a **how-to** does one task, a **reference** is complete and dry, an **explanation** says why.

| Page | Kind | What it is for |
|---|---|---|
| [../README.md](../README.md) | overview | what the library is, when to use it, a first run, installing, the API in short |
| [../examples/README.md](../examples/README.md) | tutorial | a first service step by step, with what each command prints |
| [async.md](async.md) | how-to | using the chronos API |
| [building.md](building.md) | how-to | building, running the tests, how dependencies are chosen and tracked |
| [static-build.md](static-build.md) | how-to | a fully static client with musl |
| [interceptors.md](interceptors.md) | how-to | running code around every call: checking a token, logging, adding metadata |
| [production.md](production.md) | how-to | a checklist to go through before a server faces real clients |
| [upgrading.md](upgrading.md) | how-to | what to change when moving to each version |
| [releasing.md](releasing.md) | how-to | making a release (maintainers) |
| [troubleshooting.md](troubleshooting.md) | reference | every message of the library: what it means and what to do |
| [faq.md](faq.md) | reference | short answers to common questions |
| [supported-versions.md](supported-versions.md) | reference | which versions of the library, Nim and the dependencies, and which platforms |
| [interop.md](interop.md) | reference | the interop cases against grpc-go and how to run them |
| [h2spec.md](h2spec.md) | reference | the h2spec results and the known failures |
| [security-requirements.md](security-requirements.md) | reference | what a user can and cannot expect in security |
| [security-policies.md](security-policies.md) | reference | the rules the project holds itself to |
| [roadmap.md](roadmap.md) | reference | what is planned, considered and not intended |
| [../CHANGELOG.md](../CHANGELOG.md) | reference | what changed in each release |
| [architecture.md](architecture.md) | explanation | the parts, who acts and what each action does |
| [threat-model.md](threat-model.md) | explanation | who can attack what, and what stands in the way |
| [assurance-case.md](assurance-case.md) | explanation | why the security requirements are met |
| [nim-compiler-notes.md](nim-compiler-notes.md) | explanation | two compiler problems and how to write code around them |
| [nim-issue-finally.md](nim-issue-finally.md) | reference | the text of the compiler issue behind the notes above |

`tests/tdocs.nim` fails when a page of this directory is not in the table, when a message of the
library has no line in [troubleshooting.md](troubleshooting.md), or when
[supported-versions.md](supported-versions.md) disagrees with `nimgrpc.nimble` or the CI workflow;
`tests/texamples.nim` runs the commands the README and the tutorial show.
