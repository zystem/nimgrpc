## TLS and mutual TLS.

import std/[unittest, os, osproc, strutils]
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
