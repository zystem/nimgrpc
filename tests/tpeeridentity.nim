## Who the client is, as a handler and an interceptor see it (`ctx.peer`): the certificate the
## client authenticated with under mutual TLS, read on the blocking and on the chronos server, kept
## across resumed sessions, and not open to what the client puts in its metadata.
##
## The server's own certificate is tests/certs/server.pem (CA ca.pem); the clients' certificates
## are tests/certs/ident/*.pem, made by their own CA (idca.pem), which the server trusts.

import std/[unittest, os, strutils]
import pkg/chronos
import nimgrpc
import nimgrpc/asyncserver
from nimgrpc/asyncclient as ac import nil
import nimgrpc/tls/[tls as rawtls, peerid]

const
  certs = currentSourcePath.parentDir / "certs"
  idents = certs / "ident"
proc pem(name: string): string = readFile(certs / name)
proc ident(name: string): string = readFile(idents / name)

proc describe(p: PeerIdentity): seq[byte] =
  ## What the handler tells the client it saw, as text.
  let s = [$p.authenticated, p.subject, p.dnsNames.join(","), p.uris.join(","),
           p.emails.join(","), p.ipAddresses.join(","), p.fingerprint].join("|")
  for c in s: result.add byte(c)

proc textOf(r: UnaryResult): seq[string] =
  var s = ""
  for b in r.message: s.add char(b)
  s.split('|')

proc who(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} = describe(ctx.peer)

proc serverConfig(mutual: bool): TlsConfig =
  tlsServerConfig(pem"server.pem", pem"server.key",
                  clientCaPem = (if mutual: ident"idca.pem" else: ""))

proc clientConfig(name: string): TlsConfig =
  tlsClientConfig(pem"ca.pem", ident(name & ".pem"), ident(name & ".key"))

const
  aliceFp = "b5ae2363117433dfbca74c2a2d19affb1ad4362aa982af757955d2a87f8ba810"
  bobFp = "0d9cd0590bccec957415888583d824752627d381676fc11aef94883f1afcf174"
  aliceUri = "spiffe://example.org/ns/prod/sa/alice"

proc ask(port: int; cfg: TlsConfig; metadata: Metadata = @[]): seq[string] =
  ## No `defer` for the channel: Nim can lose the exception on its way through one
  ## (docs/nim-compiler-notes.md), and the exception is what the callers look at.
  let ch = dial("127.0.0.1", port, cfg, "localhost")
  var failure: ref CatchableError
  try:
    result = ch.unaryCall("/t.T/Who", @[], metadata = metadata, timeoutMs = 5000).textOf
  except CatchableError as e:
    failure = e
  ch.close()
  if failure != nil: raise failure

suite "the identity of the client (blocking server)":
  test "alice's certificate gives her names, and the fingerprint":
    let srv = newGrpcServer(tls = serverConfig(true))
    srv.addUnary("/t.T/Who", who)
    srv.start()
    defer: srv.stop()
    let r = ask(srv.port, clientConfig("alice"))
    check r == @["true", "alice", "alice.example.com,alice-alt.example.com", aliceUri,
                 "alice@example.com", "10.1.2.3,2001:db8::1", aliceFp]

  test "other clients of the same CA are other identities":
    let srv = newGrpcServer(tls = serverConfig(true))
    srv.addUnary("/t.T/Who", who)
    srv.start()
    defer: srv.stop()
    check ask(srv.port, clientConfig("bob")) == @["true", "bob", "", "", "", "", bobFp]
    let carol = ask(srv.port, clientConfig("carol"))
    check carol[1] == "Zoë Müller"
    check carol[3] == "spiffe://example.org/ns/prod/sa/carol"

  test "without mutual TLS nobody is authenticated, even a client that sends a certificate":
    let srv = newGrpcServer(tls = serverConfig(false))
    srv.addUnary("/t.T/Who", who)
    srv.start()
    defer: srv.stop()
    check ask(srv.port, clientConfig("alice")) == @["false", "", "", "", "", "", ""]

  test "without TLS nobody is authenticated":
    let srv = newGrpcServer()
    srv.addUnary("/t.T/Who", who)
    srv.start()
    defer: srv.stop()
    let ch = dial("127.0.0.1", srv.port)
    defer: ch.close()
    check ch.unaryCall("/t.T/Who", @[], timeoutMs = 5000).textOf ==
          @["false", "", "", "", "", "", ""]

  test "what the client puts in its metadata is not an identity":
    let srv = newGrpcServer(tls = serverConfig(true))
    srv.addUnary("/t.T/Who", who)
    srv.start()
    defer: srv.stop()
    let r = ask(srv.port, clientConfig("bob"),
                @[("x-client-cn", "alice"), ("peer", aliceUri), ("authenticated", "admin")])
    check r[1] == "bob"
    check r[3] == ""

  test "a client certificate from a CA the server does not trust is refused":
    let srv = newGrpcServer(tls = serverConfig(true))
    srv.addUnary("/t.T/Who", who)
    srv.start()
    defer: srv.stop()
    let cfg = tlsClientConfig(pem"ca.pem", pem"rogue.pem", pem"rogue.key")
    let ch = dial("127.0.0.1", srv.port, cfg, "localhost")
    defer: ch.close()
    var refused = false
    try: discard ch.unaryCall("/t.T/Who", @[], timeoutMs = 5000)
    except CatchableError: refused = true
    check refused

  test "an interceptor can decide by the URI in the certificate":
    proc onlyAlice(ctx: var ServerContext; next: ServerNext; userData: pointer)
        {.nimcall, gcsafe, raises: [CatchableError].} =
      if aliceUri notin ctx.peer.uris:
        raise newGrpcError(scPermissionDenied, "only alice")
      next.proceed(ctx)
    let srv = newGrpcServer(tls = serverConfig(true))
    srv.addUnary("/t.T/Who", who)
    srv.addInterceptor(onlyAlice)
    srv.start()
    defer: srv.stop()
    check ask(srv.port, clientConfig("alice"))[0] == "true"
    var code = scOk
    try: discard ask(srv.port, clientConfig("bob"))
    except GrpcError as e: code = e.code
    check code == scPermissionDenied

  test "a resumed connection has the identity of the session it resumes":
    let srv = newGrpcServer(tls = serverConfig(true))
    srv.addUnary("/t.T/Who", who)
    srv.start()
    defer: srv.stop()
    let alice = clientConfig("alice")
    let bob = clientConfig("bob")
    for round in 0 ..< 3:                # the second and third of each use the saved session
      check ask(srv.port, alice)[6] == aliceFp
      check ask(srv.port, bob)[6] == bobFp

suite "the identity of the client (chronos server)":
  proc whoAsync(ctx: AsyncServerContext; req: seq[byte]): Future[seq[byte]] {.async.} =
    return describe(ctx.peer)

  proc askAsync(port: int; cfg: TlsConfig): Future[seq[string]] {.async.} =
    let ch = await ac.dialAsync("127.0.0.1", port, cfg, "localhost")
    var s = ""
    try:
      let r = await ac.unaryCall(ch, "/t.T/Who", @[], timeoutMs = 5000)
      for b in r.message: s.add char(b)
    finally:
      await ac.close(ch)
    return s.split('|')

  test "alice, bob, and alice again over a resumed session":
    let srv = newAsyncGrpcServer(tls = serverConfig(true))
    srv.addUnary("/t.T/Who", whoAsync)
    srv.start()
    defer: waitFor srv.stop()
    let alice = clientConfig("alice")
    let bob = clientConfig("bob")
    check waitFor(askAsync(srv.port, alice)) ==
          @["true", "alice", "alice.example.com,alice-alt.example.com", aliceUri,
            "alice@example.com", "10.1.2.3,2001:db8::1", aliceFp]
    check waitFor(askAsync(srv.port, bob))[6] == bobFp
    check waitFor(askAsync(srv.port, alice))[6] == aliceFp
    check waitFor(askAsync(srv.port, bob))[1] == "bob"

  test "without mutual TLS nobody is authenticated":
    let srv = newAsyncGrpcServer(tls = serverConfig(false))
    srv.addUnary("/t.T/Who", whoAsync)
    srv.start()
    defer: waitFor srv.stop()
    check waitFor(askAsync(srv.port, clientConfig("alice")))[0] == "false"

# ---------------------------------------------------------------- the TLS engine

proc feed(t: TlsConn; data: seq[byte]) =
  var rest = data
  while rest.len > 0:
    let n = t.pushRecords(rest)
    if n == 0: break
    rest = rest[n .. ^1]

proc connect(cc, sc: TlsConfig): tuple[c, s: TlsConn] =
  let c = newClientTls(cc, "localhost")
  let s = newServerTls(sc)
  for _ in 0 ..< 100:
    c.feed(s.pullRecords())
    s.feed(c.pullRecords())
    if c.handshakeDone and s.handshakeDone: break
  (c, s)

suite "the client's certificate in the TLS engine":
  test "a resumed session gives the server the certificate of the session, and a new one its own":
    let sc = serverConfig(true)
    let alice = clientConfig("alice")
    let bob = clientConfig("bob")
    let a1 = connect(alice, sc)
    a1.c.checkPeer(); a1.s.checkPeer()       # the client's check is what saves the session
    check not a1.s.resumed
    let aliceDer = a1.s.peerCert()
    check aliceDer.len > 100
    check parsePeerCert(aliceDer).subject == "alice"
    let b1 = connect(bob, sc)
    b1.c.checkPeer(); b1.s.checkPeer()
    check parsePeerCert(b1.s.peerCert()).subject == "bob"
    let a2 = connect(alice, sc)
    a2.c.checkPeer(); a2.s.checkPeer()
    check a2.s.resumed                       # a resumed session presents no certificate ...
    check a2.s.peerCert() == aliceDer        # ... and the server still knows whose it is
    let b2 = connect(bob, sc)
    b2.c.checkPeer(); b2.s.checkPeer()
    check b2.s.resumed
    check parsePeerCert(b2.s.peerCert()).subject == "bob"

  test "no certificate before the handshake is done, and none without mutual TLS":
    let sc = serverConfig(true)
    let early = newServerTls(sc)
    check early.peerCert().len == 0
    let plain = connect(clientConfig("alice"), serverConfig(false))
    plain.s.checkPeer()
    check plain.s.peerCert().len == 0

  test "a session whose identity is no longer kept is not resumed: a full handshake instead":
    # The table of identities (512) is smaller than the session cache; when alice's entry has
    # been overwritten, resuming her session would give the server a client it cannot name.
    let sc = serverConfig(true)
    let alice = clientConfig("alice")
    let a1 = connect(alice, sc)
    a1.c.checkPeer(); a1.s.checkPeer()
    let aliceDer = a1.s.peerCert()
    for i in 0 ..< 600:                        # each with a configuration of its own: a new session
      let other = connect(clientConfig("bob"), sc)
      other.c.checkPeer(); other.s.checkPeer()
    let a2 = connect(alice, sc)
    a2.c.checkPeer(); a2.s.checkPeer()
    check not a2.s.resumed
    check a2.s.peerCert() == aliceDer          # a full handshake presents the certificate again
