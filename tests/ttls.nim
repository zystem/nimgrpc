## TLS and mutual TLS.

import std/[unittest, os, osproc, strutils, net, streams]
import nimgrpc
import nimgrpc/tls/tls as rawtls
import ./interop/interop

const certs = currentSourcePath.parentDir / "certs"
proc pem(name: string): string = readFile(certs / name)

proc expectFailure(f: proc () {.raises: [CatchableError].}): string =
  ## The message of the GrpcError `f` raises; fails the test if it succeeds.
  try:
    f()
  except GrpcError as e:
    return $e.code & ": " & e.msg
  checkpoint "the call succeeded"
  fail()

proc echoOnce(ch: GrpcChannel) =
  let r = ch.unaryCall("/grpc.testing.TestService/EmptyCall", @[], timeoutMs = 5000)
  doAssert r.message.len == 0

suite "TLS":
  test "unary and streaming calls over TLS (EC key)":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    for name in allCases: ch.runCase(name)
    ch.close()
    srv.stop()

  test "RSA server key":
    let srv = newTestServer(tls = tlsServerConfig(pem"rsaserver.pem", pem"rsaserver.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    ch.echoOnce()
    ch.close()
    srv.stop()

  test "a server certificate from an untrusted CA is rejected":
    let srv = newTestServer(tls = tlsServerConfig(pem"rogue.pem", pem"rogue.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    let msg = expectFailure(proc () = ch.echoOnce())
    check "scUnavailable" in msg
    check "trusted CA" in msg
    ch.close()
    srv.stop()

  test "a server name that is not in the certificate is rejected":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "example.com")
    let msg = expectFailure(proc () = ch.echoOnce())
    check "server name" in msg
    ch.close()
    srv.stop()

  test "a server dialled by its IP address is checked against the iPAddress entries":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"))   # no serverName: the IP
    ch.echoOnce()
    ch.close()
    let rsa = newTestServer(tls = tlsServerConfig(pem"rsaserver.pem", pem"rsaserver.key"))
    rsa.start()
    let ch2 = dial("127.0.0.1", rsa.port, tlsClientConfig(pem"ca.pem"), "127.0.0.1")
    ch2.echoOnce()
    ch2.close()
    rsa.stop()
    srv.stop()

  test "an IP address that is not in the certificate is rejected, and so is an untrusted CA":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "127.0.0.2")
    let msg = expectFailure(proc () = ch.echoOnce())
    check "server name" in msg
    ch.close()
    let ch6 = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "[::1]")
    check "server name" in expectFailure(proc () = ch6.echoOnce())
    ch6.close()
    srv.stop()
    let rogue = newTestServer(tls = tlsServerConfig(pem"rogue.pem", pem"rogue.key"))
    rogue.start()
    let ch3 = dial("127.0.0.1", rogue.port, tlsClientConfig(pem"ca.pem"))
    check "trusted CA" in expectFailure(proc () = ch3.echoOnce())
    ch3.close()
    rogue.stop()

  test "a name is still checked against DNS names, not IP entries":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    ch.echoOnce()
    ch.close()
    srv.stop()

  test "plaintext client against a TLS server fails":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    discard expectFailure(proc () = ch.echoOnce())
    ch.close()
    srv.stop()

  test "TLS client against a plaintext server fails":
    let srv = newTestServer()
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    discard expectFailure(proc () = ch.echoOnce())
    ch.close()
    srv.stop()

  test "a client that offers no ALPN protocol is refused in the handshake":
    if findExe("openssl").len == 0:
      checkpoint "openssl is not on PATH: skipped"
      skip()
    else:
      let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
      srv.start()
      # no -alpn: no ALPN extension at all, which BearSSL's own mismatch check lets through
      let (output, _) = execCmdEx("echo | openssl s_client -connect 127.0.0.1:" & $srv.port.int &
                                  " -tls1_2 2>&1")
      check "handshake failure" in output
      check "Cipher is (NONE)" in output
      # the same client with ALPN h2 is served, so the refusal is about the missing protocol
      let (ok, _) = execCmdEx("echo | openssl s_client -connect 127.0.0.1:" & $srv.port.int &
                              " -tls1_2 -alpn h2 2>&1")
      check "ALPN protocol: h2" in ok
      let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
      ch.echoOnce()
      ch.close()
      srv.stop()

  test "a server that selects no ALPN protocol is refused by the client":
    if findExe("openssl").len == 0:
      checkpoint "openssl is not on PATH: skipped"
      skip()
    else:
      var port: Port
      block:
        let probe = newSocket()
        probe.bindAddr(Port(0), "127.0.0.1")
        port = probe.getLocalAddr()[1]
        probe.close()
      # s_server without -alpn answers no protocol
      let p = startProcess(findExe("openssl"),
        args = ["s_server", "-accept", $port.int, "-cert", certs / "server.pem",
                "-key", certs / "server.key", "-tls1_2", "-quiet"],
        options = {poStdErrToStdOut})
      var up = false
      for _ in 0 ..< 100:
        let s = newSocket()
        try:
          s.connect("127.0.0.1", port)
          up = true
        except OSError:
          sleep(50)
        s.close()
        if up: break
      check up
      if up:
        let ch = dial("127.0.0.1", port.int, tlsClientConfig(pem"ca.pem"), "localhost")
        let msg = expectFailure(proc () = ch.echoOnce())
        check "ALPN" in msg
        ch.close()
        sleep(300)
      p.terminate()
      discard p.waitForExit()
      # s_server prints what it receives: the client must have sent it nothing (before, it sent
      # the HTTP/2 preface and SETTINGS, and only then found that ALPN had not been negotiated)
      let received = p.outputStream.readAll()
      check "PRI" notin received
      check "HTTP/2" notin received
      p.close()

  test "bad PEM is reported when the config is built":
    expect TlsError:
      discard tlsServerConfig("not a certificate", pem"server.key")
    expect TlsError:
      discard tlsServerConfig(pem"server.pem", "not a key")
    expect TlsError:
      discard tlsClientConfig("")

suite "cipher order":
  const orders = [coAuto, coAesGcmFirst, coChaChaFirst]

  test "every combination of client and server order connects":
    for serverOrder in orders:
      for clientOrder in orders:
        let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key",
                                                      cipherOrder = serverOrder))
        srv.start()
        let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem", cipherOrder = clientOrder),
                      "localhost")
        ch.echoOnce()
        ch.close()
        srv.stop()

  test "the server's order decides which cipher is used":
    if findExe("openssl").len == 0:
      skip()
    else:
      for (order, expected) in [(coAesGcmFirst, "AES128-GCM-SHA256"),
                                (coChaChaFirst, "CHACHA20-POLY1305")]:
        let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key",
                                                      cipherOrder = order))
        srv.start()
        # openssl offers both families; the server chooses between them
        let (output, _) = execCmdEx("echo | openssl s_client -connect 127.0.0.1:" & $srv.port.int &
                                    " -tls1_2 -alpn h2 2>&1")
        check ("Cipher is ECDHE-ECDSA-" & expected) in output or
              ("Cipher    : ECDHE-ECDSA-" & expected) in output
        srv.stop()

suite "mutual TLS":
  var srv: GrpcServer
  setup:
    srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key",
                                               clientCaPem = pem"ca.pem"))
    srv.start()
  teardown:
    srv.stop()

  test "a client with a certificate from the trusted CA gets through":
    let ch = dial("127.0.0.1", srv.port,
                  tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key"),
                  "localhost")
    ch.echoOnce()
    ch.runCase("ping_pong")
    ch.close()

  test "a client without a certificate is refused":
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    discard expectFailure(proc () = ch.echoOnce())
    ch.close()

  test "a client certificate from another CA is refused":
    let ch = dial("127.0.0.1", srv.port,
                  tlsClientConfig(pem"ca.pem", pem"rogue.pem", pem"rogue.key"),
                  "localhost")
    discard expectFailure(proc () = ch.echoOnce())
    ch.close()

  test "the server keeps serving after refusing clients":
    let ch = dial("127.0.0.1", srv.port,
                  tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key"),
                  "localhost")
    for i in 0 ..< 20: ch.echoOnce()
    ch.close()

# ---------------------------------------------------------------- resumption

proc feed(t: TlsConn; data: seq[byte]) =
  var rest = data
  while rest.len > 0:
    let n = t.pushRecords(rest)
    if n == 0: break
    rest = rest[n .. ^1]

proc handshake(c, s: TlsConn) =
  ## Runs a handshake between the two ends in memory.
  for _ in 0 ..< 100:
    c.feed(s.pullRecords())
    s.feed(c.pullRecords())
    if c.handshakeDone and s.handshakeDone: break

proc connect(cc, sc: TlsConfig; name = "localhost"): tuple[c, s: TlsConn] =
  let c = newClientTls(cc, name)
  let s = newServerTls(sc)
  handshake(c, s)
  (c, s)

suite "session resumption":
  test "the second connection resumes, and checks the peer all the same":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    let cc = tlsClientConfig(pem"ca.pem")
    let a = connect(cc, sc)
    a.c.checkPeer(); a.s.checkPeer()
    check not a.c.resumed and not a.s.resumed
    let b = connect(cc, sc)
    b.c.checkPeer(); b.s.checkPeer()
    check b.c.resumed and b.s.resumed

  test "mutual TLS resumes too":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"ca.pem")
    let cc = tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key")
    let a = connect(cc, sc)
    a.c.checkPeer(); a.s.checkPeer()
    let b = connect(cc, sc)
    b.c.checkPeer(); b.s.checkPeer()
    check b.c.resumed and b.s.resumed

  test "a client without a certificate gets no session to resume":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"ca.pem")
    let cc = tlsClientConfig(pem"ca.pem")
    for _ in 0 ..< 3:
      let a = connect(cc, sc)
      check not a.s.resumed
      check a.s.isClosed or not a.s.handshakeDone     # refused during the handshake

  test "a session of one server config is not accepted by another":
    let cc = tlsClientConfig(pem"ca.pem")
    let a = connect(cc, tlsServerConfig(pem"server.pem", pem"server.key"))
    a.c.checkPeer()
    let b = connect(cc, tlsServerConfig(pem"server.pem", pem"server.key"))
    b.c.checkPeer(); b.s.checkPeer()
    check not b.c.resumed and not b.s.resumed

  test "lifetime 0 turns it off":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    let cc = tlsClientConfig(pem"ca.pem")
    sc.setSessionLifetime(0)
    cc.setSessionLifetime(0)
    let a = connect(cc, sc)
    a.c.checkPeer()
    let b = connect(cc, sc)
    check not b.c.resumed and not b.s.resumed

  test "a session older than the lifetime is not resumed":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    let cc = tlsClientConfig(pem"ca.pem")
    sc.setSessionLifetime(1)
    cc.setSessionLifetime(1)
    let a = connect(cc, sc)
    a.c.checkPeer(); a.s.checkPeer()
    check connect(cc, sc).c.resumed
    sleep(2200)
    let c = connect(cc, sc)
    c.c.checkPeer(); c.s.checkPeer()
    check not c.c.resumed and not c.s.resumed

  test "calls work over resumed connections":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let cfg = tlsClientConfig(pem"ca.pem")
    for _ in 0 ..< 3:
      let ch = dial("127.0.0.1", srv.port, cfg, "localhost")
      ch.echoOnce()
      ch.close()
    srv.stop()

suite "a configuration shared between threads":
  test "a shared object resumes the sessions of the one it was made from, and the original may go first":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    var cc = tlsClientConfig(pem"ca.pem")
    let sh = cc.share
    let a = connect(cc, sc)
    a.c.checkPeer(); a.s.checkPeer()
    check not a.c.resumed
    cc = nil                                  # the object that built it is gone, the shared one still holds the configuration
    GC_fullCollect()
    let b = connect(sh, sc)
    b.c.checkPeer(); b.s.checkPeer()
    check b.c.resumed and b.s.resumed          # the same sessions: a share is not a new configuration

  test "a connection keeps the configuration alive after every object that points at it is gone":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    var cc = tlsClientConfig(pem"ca.pem")
    let a = connect(cc, sc)
    cc = nil
    GC_fullCollect()
    a.c.checkPeer(); a.s.checkPeer()          # the trust anchors are still there for the check at the end of the handshake

  test "many threads, each with a share of one configuration, make connections for a while":
    var sc = tlsServerConfig(pem"server.pem", pem"server.key")
    var master = tlsClientConfig(pem"ca.pem")
    type Job = tuple[m: ptr TlsConfig, s: ptr TlsConfig, ok: ptr int]
    var oks: array[8, int]
    var jobs: array[8, Job]
    var th: array[8, Thread[ptr Job]]
    proc work(j: ptr Job) {.thread.} =
      {.cast(gcsafe).}:
        var n = 0
        for _ in 0 ..< 400:
          let mine = j.m[].share            # this thread's own object
          let c = newClientTls(mine, "localhost")
          let s = newServerTls(j.s[].share)
          handshake(c, s)
          if c.handshakeDone: inc n
        j.ok[] = n
    for i in 0 ..< 8:
      jobs[i] = (addr master, addr sc, addr oks[i])
      createThread(th[i], work, addr jobs[i])
    joinThreads(th)
    for i in 0 ..< 8: check oks[i] == 400

  test "channels dialled on several threads from one configuration are closed by a thread that did not dial them":
    # a connection holds no Nim reference to the configuration (the C side counts its owners atomically) and a channel holds an object of its own (`share`),
    # so the object that a thread passes to `dial` is touched by that thread only, whoever closes the channel
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    defer: srv.stop()
    var master = tlsClientConfig(pem"ca.pem")
    const threads = 6
    const each = 40
    type Job = tuple[m: ptr TlsConfig, port: int, chans: ptr array[each, GrpcChannel], ok: ptr int]
    var chans: array[threads, array[each, GrpcChannel]]
    var jobs: array[threads, Job]
    var oks: array[threads, int]
    var th: array[threads, Thread[ptr Job]]
    proc work(j: ptr Job) {.thread.} =
      {.cast(gcsafe).}:
        var n = 0
        for k in 0 ..< each:
          var mine = j.m[].share
          let ch = dial("127.0.0.1", j.port, mine, "localhost")
          mine = nil                               # the thread's object goes at once, the channel has its own
          try:
            ch.echoOnce()
            inc n
          except GrpcError: discard
          j.chans[][k] = ch
        j.ok[] = n
    for i in 0 ..< threads:
      jobs[i] = (addr master, srv.port, addr chans[i], addr oks[i])
      createThread(th[i], work, addr jobs[i])
    joinThreads(th)
    for i in 0 ..< threads:
      check oks[i] == each
      for ch in chans[i]: ch.close()                  # on this thread, not on the one that dialled

proc verifies(cc, sc: TlsConfig): bool =
  ## True if a handshake between the two completes and checks out on both ends (`checkPeer`
  ## does nothing before the handshake is done, so a refused one must be told apart first).
  try:
    let a = connect(cc, sc)
    if not (a.c.handshakeDone and a.s.handshakeDone): return false
    a.c.checkPeer()
    a.s.checkPeer()
    result = true
  except TlsError:
    result = false

proc raisesTlsError(f: proc () {.raises: [CatchableError].}): bool =
  try: f()
  except TlsError: return true
  false

suite "a TlsConfig is built, then in use":
  test "a second setIdentity replaces the identity, it does not add to it":
    let sc = newTlsConfig()
    sc.setIdentity(pem"rogue.pem", pem"rogue.key")         # a CA the client does not trust
    sc.setIdentity(pem"server.pem", pem"server.key")
    check verifies(tlsClientConfig(pem"ca.pem"), sc)       # the chain starts with the new leaf

  test "trust anchors added in several calls all count":
    let cc = newTlsConfig()
    cc.addTrustedCa(pem"ca.pem")
    cc.addTrustedCa(pem"otherca.pem")
    check verifies(cc, tlsServerConfig(pem"server.pem", pem"server.key"))
    check verifies(cc, tlsServerConfig(pem"rogue.pem", pem"rogue.key"))

  test "a setIdentity that fails leaves nothing behind":
    let sc = newTlsConfig()
    check raisesTlsError(proc () = sc.setIdentity(pem"server.pem", "not a key"))
    # the chain was not kept: the configuration still has no identity
    check raisesTlsError(proc () = discard newServerTls(sc))

  test "a setIdentity that fails keeps the identity that was there":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    check raisesTlsError(proc () = sc.setIdentity(pem"rogue.pem", "not a key"))
    check verifies(tlsClientConfig(pem"ca.pem"), sc)

  test "an addTrustedCa with one bad certificate adds none":
    let cc = newTlsConfig()
    check raisesTlsError(proc () = cc.addTrustedCa(
      pem"ca.pem" & "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"))
    check raisesTlsError(proc () = discard newClientTls(cc, "localhost"))   # still no anchor

  test "once a connection is made from it the setters refuse, and the connection goes on":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    let cc = tlsClientConfig(pem"ca.pem")
    let a = connect(cc, sc)
    check raisesTlsError(proc () = sc.addTrustedCa(pem"otherca.pem"))
    check raisesTlsError(proc () = sc.setIdentity(pem"rsaserver.pem", pem"rsaserver.key"))
    check raisesTlsError(proc () = sc.setCipherOrder(coChaChaFirst))
    check raisesTlsError(proc () = sc.setSessionLifetime(0))
    check raisesTlsError(proc () = sc.requireClientCert())
    check raisesTlsError(proc () = cc.addTrustedCa(pem"otherca.pem"))
    a.c.checkPeer(); a.s.checkPeer()                       # the connection is not harmed
    check verifies(cc, sc)                                 # and the configuration is as it was

  test "share ends the building too, for both objects":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    let other = sc.share
    check raisesTlsError(proc () = sc.setSessionLifetime(0))
    check raisesTlsError(proc () = other.setSessionLifetime(0))

  test "a server and a dial take the configuration: it is in use from then on":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    let srv = newTestServer(tls = sc)
    srv.start()
    check raisesTlsError(proc () = sc.setSessionLifetime(0))
    srv.stop()
    let cc = tlsClientConfig(pem"ca.pem")
    let srv2 = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv2.start()
    let ch = dial("127.0.0.1", srv2.port, cc, "localhost")
    check raisesTlsError(proc () = cc.setSessionLifetime(0))
    ch.close()
    srv2.stop()
proc messageOf(f: proc () {.raises: [CatchableError].}): string =
  ## The message of the TlsError `f` raises, "" if it does not.
  try: f()
  except TlsError as e: return e.msg
  ""

suite "the peer is verified before data moves":
  test "a client that does not trust the server's CA: checkPeer raises, and keeps raising":
    let a = connect(tlsClientConfig(pem"otherca.pem"),
                    tlsServerConfig(pem"server.pem", pem"server.key"))
    check not a.c.handshakeDone
    check "certificate not signed by a trusted CA" in messageOf(proc () = a.c.checkPeer())
    # a second ask used to pass: the flag was set before the checks were made
    check "certificate not signed by a trusted CA" in messageOf(proc () = a.c.checkPeer())
    check "certificate not signed by a trusted CA" in messageOf(proc () =
      var got: seq[byte]
      a.c.pullApp(got))

  test "nothing is sent to a peer that failed":
    let a = connect(tlsClientConfig(pem"otherca.pem"),
                    tlsServerConfig(pem"server.pem", pem"server.key"))
    check a.c.pushApp(@[1'u8, 2, 3]) == 0
    a.c.flush()
    check a.c.pushApp(@[1'u8, 2, 3]) == 0

  test "a server that requires a certificate: a client without one fails the check on the server":
    let a = connect(tlsClientConfig(pem"ca.pem"),
                    tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"ca.pem"))
    check "the client presented no certificate" in messageOf(proc () = a.s.checkPeer())
    check "the client presented no certificate" in messageOf(proc () = a.s.checkPeer())
    check a.s.pushApp(@[1'u8]) == 0

  test "a failed peer whose reason is a computed text: the text goes with the connection":
    # "TLS: peer sent fatal alert N" is built at run time. `TlsConnObj` has its own `=destroy`,
    # which did not free that text: the weekly fuzz run found it (issues 75, 76, 77, 40 MB in the
    # mutation fuzzer). It shows as a leak at exit, so it is checked by the run of this file
    # under LeakSanitizer (`nimble asan`); here, that the reason is the right one.
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    let alert = @[0x15'u8, 0x03, 0x03, 0x00, 0x02, 0x02, 0x28]   # a fatal alert, handshake_failure
    for i in 0 ..< 200:
      let s = newServerTls(sc)
      s.feed(alert)
      check "peer sent fatal alert 40" in messageOf(proc () = s.checkPeer())

  test "a verified peer stays verified, and data moves without a call of checkPeer first":
    let a = connect(tlsClientConfig(pem"ca.pem"),
                    tlsServerConfig(pem"server.pem", pem"server.key"))
    check a.c.pushApp(@[1'u8, 2, 3]) == 3         # settles the peer itself
    a.c.flush()
    a.s.feed(a.c.pullRecords())
    var got: seq[byte]
    a.s.pullApp(got)
    check got == @[1'u8, 2, 3]
    a.c.checkPeer(); a.c.checkPeer(); a.s.checkPeer()

suite "after a change of policy":
  test "a client that was let in is refused by the server with another set of trusted CAs":
    # Whoever resumed a session under the old policy has to show its certificate again under the
    # new one: a session lives in the cache of one config, and a new config (new trust anchors)
    # has none. The test is the denial after the change, and that the first session did not help.
    let before = tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"ca.pem")
    let cc = tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key")
    let first = connect(cc, before)
    first.c.checkPeer(); first.s.checkPeer()
    let again = connect(cc, before)
    again.c.checkPeer(); again.s.checkPeer()
    check again.s.resumed                        # under the old policy the session is resumed ...
    let after = tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"otherca.pem")
    let refusedNow = connect(cc, after)          # ... and under the new one the client is not let in
    check not (refusedNow.s.handshakeDone and
               (try: (refusedNow.s.checkPeer(); true) except TlsError: false))
    check not refusedNow.s.resumed

  test "a server that needs no resumption does not keep a session: lifetime 0":
    let sc = tlsServerConfig(pem"server.pem", pem"server.key", clientCaPem = pem"ca.pem")
    sc.setSessionLifetime(0)
    let cc = tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key")
    cc.setSessionLifetime(0)
    let a = connect(cc, sc)
    a.c.checkPeer(); a.s.checkPeer()
    let b = connect(cc, sc)
    b.c.checkPeer(); b.s.checkPeer()
    check not b.s.resumed                        # every connection shows its certificate
