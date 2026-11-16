# Before production: a checklist

One task: going through what a server of this library needs before it faces real clients.
Each line says what to set and why; the defaults are in the source of `Limits`, `Keepalive`
and `PingPolicy` ([../src/nimgrpc/h2/common.nim](../src/nimgrpc/h2/common.nim)). Settings are
read when the server is made: a change needs a new server (a restart). Nothing here was
measured in a large deployment ([security-requirements.md](security-requirements.md)).

## Version

- [ ] The latest release; the tag checked (`git tag -v`, [../SECURITY.md](../SECURITY.md)).
- [ ] nghttp2 at the version of [building.md](building.md) (1.71.0), zlib from an updated system.
- [ ] Nim from [supported-versions.md](supported-versions.md); read
      [nim-compiler-notes.md](nim-compiler-notes.md) if your handlers use `finally` or `defer`.
- [ ] A release build with the hardening flags of [building.md](building.md) ("Hardening"):
      the repository's own flags do not reach a program that links the library.

## Network

- [ ] `address`: the default is `127.0.0.1`. Listen on the interface the clients reach, not
      on every one.
- [ ] TLS on every network you do not own end to end. Plaintext HTTP/2 only on loopback or
      behind a proxy that ends TLS.
- [ ] A proxy or load balancer in front must speak HTTP/2 to the server and, with TLS, offer
      ALPN `h2`. Behind one, all clients share its address: leave `maxConnectionsPerIp` at 0.

## Keys and certificates

- [ ] The program reads the PEM files and gives their text to `tlsServerConfig`; the library
      reads no file. Keep the private key readable by the service's user only, out of the
      repository and out of the image; keep a backup of the CA key where the server is not.
- [ ] RSA keys of 2048 bits or more, or EC; SHA-256 signatures or better. Others fail the
      handshake.
- [ ] Renewal: there is no reload. A new certificate needs a new server, so plan a restart
      (`stop(graceMs)`) before the old one ends, and watch the end date from outside.
- [ ] Revocation is not checked (no CRL, no OCSP). To cut a client off, change the CA or
      refuse it in the handler by metadata. **Session resumption** keeps a peer that holds a
      session for ten minutes without a new certificate check: `setSessionLifetime(0)` turns
      it off.
- [ ] Mutual TLS (`clientCaPem`) admits a client whose certificate the CA signed. The handler
      is not told which client it is: authorization needs metadata as well.

## Who may call what

- [ ] The library has no authentication or authorization of calls. Check a token or a name
      from `ctx.metadata` in each handler and answer `scUnauthenticated` or
      `scPermissionDenied`, or do it once for every method in a server interceptor
      ([interceptors.md](interceptors.md)); it sees the metadata only, not the client's certificate.
- [ ] Reflection tells anyone who can connect the names and types of the services. Register
      it only where that is wanted.
- [ ] Handlers raise `GrpcError` with a text meant for the client. Other exceptions become
      `internal error`, which is right: do not send their text yourself.

## Limits (a server that untrusted clients reach)

**Dangerous when left at the default**: these are off (0, no limit) unless set.

- [ ] `Limits.maxConnections`: connections at once. No limit by default.
- [ ] `Limits.maxConnectionsPerIp`: where clients connect directly. No limit by default.
- [ ] `Limits.maxCallMs`: the longest a call may last. No limit by default; set it unless
      calls are meant to stay open.
- [ ] `Limits.maxConnectionIdleMs`, `maxConnectionAgeMs`: close idle and old connections. Off
      by default.

Set by default, check that they suit you:

- [ ] `maxMessage` (4 MiB), `Limits.maxConcurrentStreams` (100 per connection),
      `handshakeTimeoutMs` (20 s), `maxConnectionBuffer` (16 MiB).
- [ ] Blocking server: `maxWorkers` (256 calls at once). Memory under load is about the
      number of running handlers times twice the size of a response
      ([threat-model.md](threat-model.md), "slow or stalled peer").
- [ ] `newHealth(maxWatches = 64)`, `newReflection(maxStreams = 16)` on the blocking server.
- [ ] `pingPolicy`: off by default; set `minIntervalMs` to refuse clients that ping too often.
- [ ] No rate limit of calls exists. Put one in front or in the handlers if you need it.

## Seeing what happens

- [ ] `srv.setErrorHook(hook)` before `start`: without it an exception in a handler leaves no
      trace anywhere. Send what the hook gets to your log; it may hold paths and queries, so
      treat that log as sensitive.
- [ ] The library has no metrics and no access log. Count calls and time them in the handlers, or in
      a server interceptor, which sees every call, the health and reflection services too
      ([interceptors.md](interceptors.md)).
- [ ] The health service (`nimgrpc/health`) for the probes of the platform; `h.setStatus` when
      a dependency of a service is down.

## Stopping and upgrading

- [ ] On a stop signal: `h.shutdown()`, then `srv.stop(graceMs = ...)` with a grace longer
      than your longest ordinary call. Long handlers call `ctx.checkCancelled()`.
- [ ] Clients set `timeoutMs` on every call: a call without one waits for ever.
- [ ] Watch the releases of the repository; read [upgrading.md](upgrading.md) and
      [../CHANGELOG.md](../CHANGELOG.md) for each; regenerate the code of your `.proto` files.

## Drills

- [ ] Run your server under `tools/hostile.sh`-like load once: more connections than
      `maxConnections`, calls left open, a message over `maxMessage`; see that it answers an
      ordinary call afterwards and that its memory is what you expect.
- [ ] Let a test certificate expire and renew it by the procedure you wrote.
- [ ] Stop a server under load and see that no call is cut before the grace.
- [ ] Restore the keys from the backup on a clean machine.
