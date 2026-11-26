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
- [ ] Build a `TlsConfig` on one thread and finish every setter (`addTrustedCa`, `setIdentity`,
      `setCipherOrder`, `setSessionLifetime`, `requireClientCert`) before its first use: a connection,
      `share`, a server or a channel. After that it cannot change and the setters raise `TlsError`.
      The freeze is a checked flag, not a lock: a setter that runs on one thread while another thread
      makes a connection from the same config, or shares it, is a data race. Hand the finished config
      out and do not touch it again.
- [ ] The PEM text you pass (the private key included) stays in your memory. The library wipes the
      copies it makes (the decoder's buffer, which is never grown with `realloc`, and the key it keeps),
      but it cannot wipe your string: read the key into a variable, build the config, then overwrite the
      variable (`zeroMem`), and keep keys out of logs, environment dumps and core files
      (`ulimit -c 0`).
- [ ] A client that must be refused within a known time (a revoked certificate): a resumed session
      skips the certificate check, so set `setSessionLifetime` to no more than that time, or to 0 for no
      resumption. Serve tenants that must not trust one another's clients from different servers or
      configs: a session never crosses configs, and every config has its own trust anchors.
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

## Limits (a client that dials servers you do not run)

Set by default; `ClientLimits` goes to `dial` and `dialAsync`.

- [ ] `ClientLimits.handshakeTimeoutMs` (20 s): a server that accepts and stays silent is dropped, and its calls fail with UNAVAILABLE. 0 means no limit: a call without a deadline would then wait for ever.
- [ ] `ClientLimits.maxHeaderListBytes` (64 KiB): the most one block of response headers or trailers may weigh; past it the call fails and the connection stays. 0 leaves only nghttp2's own limits.
- [ ] `maxMessage` (4 MiB) bounds a message after decompression; set a deadline (`timeoutMs`) on every call.

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
- [ ] Blocking server: `maxWorkers` (256 calls at once) and `Limits.maxQueuedCalls` (1024 calls
      waiting for a worker; one more is refused with REFUSED_STREAM, and a client of this
      library sees UNAVAILABLE and sends a unary call again). Memory under load is about the
      number of running handlers times twice the size of a response, plus what the waiting
      calls hold ([threat-model.md](threat-model.md), "slow or stalled peer").
- [ ] Blocking server: `Limits.maxQueuedBytes` (256 MiB) bounds, for the whole server, the bytes
      that calls without a worker hold (request headers and body that has arrived: calls that
      wait for a worker, and unary calls that wait for the rest of their message). Past it a
      call is refused or reset with REFUSED_STREAM (it was not started; a client of this library
      sees UNAVAILABLE and sends a unary call again). Set it to what the process can spare.
      `srv.queueStats()` gives the waiting calls and these bytes: watch it.
- [ ] Blocking server with long streaming calls: `Limits.maxStreamingCalls` (no quota by
      default) caps the streaming handlers that run at once, so that they cannot hold every
      worker (set it to about half of `maxWorkers`; the rest get RESOURCE_EXHAUSTED at once), and
      `Limits.maxStreamingCallMs` (0: `maxCallMs` applies) gives streaming calls their own
      time limit, longer or shorter than the one of the other calls, or none (-1).
- [ ] `newHealth(maxWatches = 64)`, `newReflection(maxStreams = 16)` on the blocking server.
- [ ] `pingPolicy`: off by default; set `minIntervalMs` to refuse clients that ping too often.
- [ ] No rate limit of calls exists. Put one in front or in the handlers if you need it.

## Availability under load (the blocking server)

A blocking server runs `maxWorkers` handlers at once; what arrives beyond that waits, and the limits below
say how much may wait and how long a call may hold a worker. Set them from a memory budget and the lifetime
of the streams you serve, not from the defaults.

- [ ] **Memory.** `Limits.maxQueuedBytes` (256 MiB) bounds the request bytes held for calls that have no
      worker; take it from what the process can spare. It does not count what the running handlers hold,
      the buffers of compression, or the buffers of TLS (about 42 KiB for each connection) or of the
      connections themselves: leave room for them.
- [ ] **Workers for unary calls.** Long streaming calls hold their workers. Set `Limits.maxStreamingCalls`
      to about half of `maxWorkers`, and the next streaming call is answered at once with
      RESOURCE_EXHAUSTED, so that short calls always find a worker. `tools/admission.nim` measures it (8
      workers, 24 threads that keep a streaming call open for 2 s, 4 threads that call a unary method; one
      run each, 2026-11-22, Linux x86-64, `-d:release`, client and server in one process):

      | `maxStreamingCalls` | unary calls in 10 s | unary p50 | unary p99 | streaming calls refused | resident size, peak |
      |---|---|---|---|---|---|
      | 0 (no quota) | 24 | 1998 ms | 1998 ms | 0 | 15 MiB |
      | 4 | 18,358 | 0.12 ms | 0.22 ms | 1,966,602 | 16 MiB |

      With a queue of 8 calls as well (`--queue 8 --bytes-mib 1`) the p99 of the unary calls was 20 ms and
      38,697 calls were refused by the queue limit: a queue that is too short refuses short calls too.
- [ ] **Watch it.** `srv.stats()` has the gauges (`queuedCalls`, `queuedBytes`, `runningStreaming`) and the
      counters (`refusedQueue`, `refusedBytes`, `shedBytes`, `refusedStreaming`) of these limits; the chronos
      server has `refusedStreaming` and `runningStreaming`. Alert on a refusal rate that stays above zero:
      a limit is too low, or clients come in faster than the server takes them. Acceptance for a service:
      a resident size under its ceiling and a unary p99 that holds under a sustained load of long streams,
      measured with `tools/admission.nim` or a load test of your own.
- [ ] `maxConnectionsPerIp` counts the address the connection comes from: behind a proxy that is the proxy's,
      and one cap then limits unrelated clients together. Set it only where clients connect directly.

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
