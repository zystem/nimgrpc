## The C side of TLS (gtls.c) when an allocation fails. gtls.c is built here with
## -DGTLS_FAIL_INJECT: every malloc, calloc, realloc and strdup of that file goes through a hook
## that makes the allocation with a chosen number fail, once. For each number from 0 up, one
## operation is run: a call that fails must say so (TlsError, "out of memory" or the like), must
## leave the configuration as it was (so the one that worked keeps working), and must not crash;
## the loop ends when an operation succeeds with the failure still pending (it has fewer
## allocations than the number). Under `nimble asan` LeakSanitizer sees what a failed path leaks.

import std/[unittest, os]
import nimgrpc/tls/tls as rawtls

{.passc: "-DGTLS_FAIL_INJECT".}
{.emit: "extern long gtls_fail_after;".}
var failAfter {.importc: "gtls_fail_after", nodecl.}: clong

const certs = currentSourcePath.parentDir / "certs"
proc pem(name: string): string = readFile(certs / name)

proc feed(t: TlsConn; data: seq[byte]) =
  var rest = data
  while rest.len > 0:
    let n = t.pushRecords(rest)
    if n == 0: break
    rest = rest[n .. ^1]

proc verifies(cc, sc: TlsConfig): bool =
  ## True if a handshake between the two completes and checks out.
  try:
    let c = newClientTls(cc, "localhost")
    let s = newServerTls(sc)
    for _ in 0 ..< 100:
      c.feed(s.pullRecords())
      s.feed(c.pullRecords())
      if c.handshakeDone and s.handshakeDone: break
    if not (c.handshakeDone and s.handshakeDone): return false
    c.checkPeer()
    s.checkPeer()
    true
  except TlsError:
    false

proc injected(op: proc (): bool {.raises: [CatchableError].}): tuple[failed: bool, pending: bool] =
  ## Runs `op` (true if it raised TlsError) with the allocation `failAfter` failing; whether the
  ## failure was still pending afterwards means `op` had fewer allocations.
  var raised = false
  try:
    raised = op()
  except TlsError:
    raised = true
  let pending = failAfter >= 0
  failAfter = -1
  (raised, pending)

const maxAllocs = 400        # far more than any operation here makes

suite "allocation failures in the TLS layer":
  test "addTrustedCa: a failure adds nothing, and says so":
    var failures = 0
    for k in 0 ..< maxAllocs:
      let cc = tlsClientConfig(pem"ca.pem")
      failAfter = clong(k)
      let (raised, pending) = injected(proc (): bool =
        try: cc.addTrustedCa(pem"otherca.pem")
        except TlsError: return true
        false)
      if pending: break                              # the operation has fewer allocations
      let rogueTrusted = verifies(cc, tlsServerConfig(pem"rogue.pem", pem"rogue.key"))
      check raised != rogueTrusted                   # failed: not added, done: added
      check verifies(cc, tlsServerConfig(pem"server.pem", pem"server.key"))   # the old anchor stays
      if raised: inc failures
    check failures > 0

  test "setIdentity: a failure keeps the identity that was there":
    var failures = 0
    for k in 0 ..< maxAllocs:
      let sc = tlsServerConfig(pem"server.pem", pem"server.key")   # trusted by the client
      failAfter = clong(k)
      let (raised, pending) = injected(proc (): bool =
        try: sc.setIdentity(pem"rogue.pem", pem"rogue.key")
        except TlsError: return true
        false)
      if pending: break
      # failed: still the trusted identity; done: the rogue one, which the client refuses
      check raised == verifies(tlsClientConfig(pem"ca.pem"), sc)
      if raised: inc failures
    check failures > 0

  test "setIdentity with an RSA key and a chain: the same":
    var failures = 0
    for k in 0 ..< maxAllocs:
      let sc = tlsServerConfig(pem"server.pem", pem"server.key")
      failAfter = clong(k)
      let (raised, pending) = injected(proc (): bool =
        try: sc.setIdentity(pem"rsaserver.pem", pem"rsaserver.key")
        except TlsError: return true
        false)
      if pending: break
      check verifies(tlsClientConfig(pem"ca.pem"), sc)    # either identity is trusted
      if raised: inc failures
    check failures > 0

  test "setIdentity with an RSA-4096 key (a buffer that grows twice): a failure changes nothing":
    var failures = 0
    for k in 0 ..< maxAllocs:
      let sc = tlsServerConfig(pem"server.pem", pem"server.key")   # trusted by the client
      failAfter = clong(k)
      let (raised, pending) = injected(proc (): bool =
        try: sc.setIdentity(pem"rsaserver.pem", pem"rsa4096.key")
        except TlsError: return true
        false)
      if pending: break
      # failed: still the trusted identity; done: a chain with a key that is not its own, which
      # no client accepts
      check raised == verifies(tlsClientConfig(pem"ca.pem"), sc)
      if raised: inc failures
    check failures > 0

  test "a connection that cannot be made says so, and the next one can":
    var failures = 0
    for k in 0 ..< maxAllocs:
      let sc = tlsServerConfig(pem"server.pem", pem"server.key")
      let cc = tlsClientConfig(pem"ca.pem")
      failAfter = clong(k)
      let (raised, pending) = injected(proc (): bool =
        try:
          discard newServerTls(sc)
          discard newClientTls(cc, "localhost")
        except TlsError: return true
        false)
      if pending: break
      check verifies(cc, sc)                         # the failure was once; the configs are fine
      if raised: inc failures
    check failures > 0

  test "the configuration builders: every failed allocation is a TlsError":
    # Nothing a builder allocates is optional: it makes the trust anchors, the chain, the key and
    # the configuration itself, and a configuration that lacked any of them would trust or
    # present something other than what was asked. So each failure of the numbers below must come
    # out as a TlsError (an allocation that was allowed to fail quietly would show here as a
    # config that came back), and the first number that does not fail ends the loop.
    for k in 0 ..< maxAllocs:
      failAfter = clong(k)
      var built: TlsConfig
      let (raised, pending) = injected(proc (): bool =
        try:
          built = tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"ca.pem")
        except TlsError: return true
        false)
      if pending:
        check not raised and built != nil        # fewer allocations than k: a whole config
        break
      check raised                                # one that failed: no config, and an error
      check built == nil
    for k in 0 ..< maxAllocs:                     # the client builder with its identity, too
      failAfter = clong(k)
      var built: TlsConfig
      let (raised, pending) = injected(proc (): bool =
        try:
          built = tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key")
        except TlsError: return true
        false)
      if pending:
        check not raised and built != nil
        break
      check raised
      check built == nil
    # a build that did not fail has the trust and the identity that were asked for
    check verifies(tlsClientConfig(pem"ca.pem"), tlsServerConfig(pem"server.pem", pem"server.key"))
    check verifies(tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key"),
                   tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"ca.pem"))
    check not verifies(tlsClientConfig(pem"otherca.pem"),
                       tlsServerConfig(pem"server.pem", pem"server.key"))
