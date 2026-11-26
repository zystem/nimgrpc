## TLS 1.2 with ALPN "h2" on BearSSL, I/O-free (see gtls.c).
##
## A `TlsConfig` is built once and shared read-only by every connection that
## uses it. It is built with the setters (`addTrustedCa`, `setIdentity`, ...) and then
## in use: the first connection made from it, `share`, or a server or channel that is
## given it ends the building, and a setter after that raises `TlsError`. A connection
## points into the arrays of the configuration, so changing them under it would leave
## it with freed memory. To change a configuration, build a new one. The configuration itself (trust anchors, identity, resumable
## sessions) is counted with atomic operations and a connection holds a count
## of its own, so it outlives them. The `TlsConfig` object that points at it is
## a Nim `ref`, and a Nim `ref` must not be copied between threads (ORC counts
## references without atomics): a thread that wants the configuration takes
## `share` of it and uses that object alone. A `TlsConn` is one session, driven
## by the connection that owns it under that connection's lock.

import std/os
import bearssl/abi/[bearssl_ssl, bearssl_x509, bearssl_pem, bearssl_ec,
                    bearssl_rsa, bearssl_hash, bearssl_rand]

{.compile: currentSourcePath.parentDir / "gtls.c".}

type
  GtlsConfP = distinct pointer   ## gtls_conf*, opaque
  GtlsConnP = distinct pointer   ## gtls_conn*, opaque

proc isNil(p: GtlsConfP): bool {.borrow.}
proc isNil(p: GtlsConnP): bool {.borrow.}

{.push importc, cdecl, raises: [], gcsafe.}
proc gtls_conf_new(): GtlsConfP
proc gtls_conf_error(c: GtlsConfP): cstring
proc gtls_conf_add_ca(c: GtlsConfP; pem: ptr byte; len: csize_t): clong
proc gtls_conf_set_identity(c: GtlsConfP; chain: ptr byte; chainLen: csize_t;
                            key: ptr byte; keyLen: csize_t): cint
proc gtls_conf_require_client_cert(c: GtlsConfP; on: cint): cint
proc gtls_conf_set_cipher_order(c: GtlsConfP; order: cint): cint
proc gtls_conf_set_lifetime(c: GtlsConfP; seconds: cint): cint
proc gtls_conf_freeze(c: GtlsConfP)
proc gtls_conf_frozen(c: GtlsConfP): cint
proc gtls_conf_retain(c: GtlsConfP)
proc gtls_conf_free(c: GtlsConfP)
proc gtls_client_new(c: GtlsConfP; serverName: cstring): GtlsConnP
proc gtls_server_new(c: GtlsConfP): GtlsConnP
proc gtls_free(t: GtlsConnP)
proc gtls_state(t: GtlsConnP): cuint
proc gtls_last_error(t: GtlsConnP): cint
proc gtls_push_records(t: GtlsConnP; data: ptr byte; len: csize_t): csize_t
proc gtls_pull_records(t: GtlsConnP; data: ptr byte; cap: csize_t): csize_t
proc gtls_push_app(t: GtlsConnP; data: ptr byte; len: csize_t): csize_t
proc gtls_flush(t: GtlsConnP)
proc gtls_pull_app(t: GtlsConnP; data: ptr byte; cap: csize_t): csize_t
proc gtls_close(t: GtlsConnP)
proc gtls_alpn(t: GtlsConnP): cstring
proc gtls_peer_ok(t: GtlsConnP): cint
proc gtls_peer_cert(t: GtlsConnP; len: ptr csize_t): ptr byte
proc gtls_resumed(t: GtlsConnP): cint
proc gtls_alpn_refused(t: GtlsConnP): cint
{.pop.}

const
  stClosed = 0x0001'u32
  stSendApp = 0x0008'u32

type
  TlsError* = object of CatchableError

  TlsConfigObj = object
    raw: GtlsConfP
  TlsConfig* = ref TlsConfigObj
    ## Trust anchors, our identity and policy. Immutable once in use (see the top of this module).

  PeerState = enum
    psPending     ## the handshake is not done: no application data moves yet
    psVerified    ## ALPN is h2 and the peer is authenticated as required
    psFailed      ## it is not: final, and the connection must be dropped

  TlsConnObj = object
    raw: GtlsConnP
    peer: PeerState
    why: string       ## psFailed: the reason
  TlsConn* = ref TlsConnObj

proc `=destroy`(c: TlsConfigObj) =
  if not c.raw.isNil: gtls_conf_free(c.raw)
proc `=copy`(dst: var TlsConfigObj; src: TlsConfigObj) {.error.}

proc `=destroy`(t: TlsConnObj) =
  if not t.raw.isNil: gtls_free(t.raw)
  `=destroy`(t.why.addr[])   # a type with its own `=destroy` must free its own fields
proc `=copy`(dst: var TlsConnObj; src: TlsConnObj) {.error.}

proc bytesOf(s: string): ptr byte =
  if s.len > 0: cast[ptr byte](s[0].unsafeAddr) else: nil

type
  CipherOrder* = enum
    ## Which cipher a connection prefers when both ends support several. All
    ## three orders offer the same suites (ECDHE with AES-128/256-GCM or
    ## ChaCha20-Poly1305); only the order differs.
    coAuto        ## AES-GCM first on a CPU with AES-NI and PCLMULQDQ, else ChaCha20
    coAesGcmFirst
    coChaChaFirst

proc newTlsConfig*(): TlsConfig =
  ## An empty configuration, to be filled by ONE thread with the setters below and then used. The
  ## freeze that ends the building is a checked flag, not a lock: a setter that runs while another
  ## thread makes a connection from the same config, or shares it, is a data race. Finish it
  ## before it is given to anybody. The PEM strings you pass stay in your memory (the library
  ## wipes the copies it makes, not yours): overwrite the key when the config is built.
  result = TlsConfig(raw: gtls_conf_new())
  if result.raw.isNil: raise newException(TlsError, "out of memory")

proc fail(c: TlsConfig; what: string) {.noreturn.} =
  raise newException(TlsError, what & ": " & $gtls_conf_error(c.raw))

proc checkBuilding(c: TlsConfig) =
  ## Raises TlsError once the configuration is in use.
  if gtls_conf_frozen(c.raw) != 0:
    raise newException(TlsError, "the TlsConfig is in use (a connection, share, a server or " &
                       "a channel has it) and cannot change: build a new one")

proc freeze*(c: TlsConfig) =
  ## Ends the building: the setters raise TlsError from now on. Servers and channels call this
  ## on the configuration they are given; a connection and `share` do it as well.
  if c != nil: gtls_conf_freeze(c.raw)

proc addTrustedCa*(c: TlsConfig; pem: string) =
  ## Certificates (PEM) that may sign the peer's chain. All of them are added, or, if one is
  ## not valid, none. Raises TlsError once the configuration is in use.
  c.checkBuilding()
  if gtls_conf_add_ca(c.raw, pem.bytesOf, pem.len.csize_t) < 0: c.fail("CA")

proc setIdentity*(c: TlsConfig; certChainPem, privateKeyPem: string) =
  ## Our certificate chain (leaf first) and its key (RSA or EC; PKCS#1, SEC1
  ## or PKCS#8, unencrypted). The chain and the key are checked together and replace the
  ## identity the configuration had (a second call does not add to the first); if either is not
  ## valid the configuration is unchanged. Raises TlsError once the configuration is in use.
  c.checkBuilding()
  if gtls_conf_set_identity(c.raw, certChainPem.bytesOf, certChainPem.len.csize_t,
                            privateKeyPem.bytesOf, privateKeyPem.len.csize_t) != 0:
    c.fail("identity")

proc setCipherOrder*(c: TlsConfig; order: CipherOrder) =
  ## The preferred cipher. On a server this order decides, whatever the client
  ## prefers; on a client it is the order offered. `coAuto` (the default)
  ## picks AES-GCM where the CPU does it in hardware, which is faster, and
  ## ChaCha20-Poly1305 elsewhere, where BearSSL's portable AES is slow.
  c.checkBuilding()
  if gtls_conf_set_cipher_order(c.raw, cint(ord(order))) != 0: c.checkBuilding()

proc share*(c: TlsConfig): TlsConfig =
  ## Another object for the same configuration, with the same resumable
  ## sessions: for a thread (or a connection) that must not touch the reference
  ## count of `c`, which another thread may be changing. The configuration is
  ## freed when the last object made from it and the last connection using it
  ## are gone. `c` is only read, so any number of threads may call `share` on it
  ## at once as long as none of them copies the reference. `share` ends the building of `c`: the
  ## setters raise from then on, and they must not run on another thread at the same moment.
  if c.isNil: return nil
  gtls_conf_retain(c.raw)
  TlsConfig(raw: c.raw)

const defaultSessionLifetime* = 600

proc setSessionLifetime*(c: TlsConfig; seconds: int) =
  ## How long a TLS session may be resumed, which skips the public-key work of
  ## a handshake (a new connection costs about half as much). A server keeps
  ## the sessions of authenticated peers for at most this long and a client
  ## offers the last one for the same server name for as long; 0 turns
  ## resumption off. A resumed session is not checked against the certificate
  ## again, so this is also how long a revoked or expired certificate still
  ## works for a client that already has a session. Default ten minutes.
  c.checkBuilding()
  if gtls_conf_set_lifetime(c.raw, cint(seconds)) != 0: c.checkBuilding()

proc requireClientCert*(c: TlsConfig; on = true) =
  ## Server: refuse clients without a certificate that chains to a trusted CA.
  c.checkBuilding()
  if gtls_conf_require_client_cert(c.raw, cint(on)) != 0: c.checkBuilding()

proc tlsClientConfig*(caPem: string; certChainPem = ""; privateKeyPem = "";
                      cipherOrder = coAuto): TlsConfig =
  ## A client trusting `caPem`; with a chain and key it also authenticates itself. The config comes
  ## back finished (build further on one thread only, before its first use: see `newTlsConfig`).
  result = newTlsConfig()
  result.setCipherOrder(cipherOrder)
  result.addTrustedCa(caPem)
  if certChainPem.len > 0: result.setIdentity(certChainPem, privateKeyPem)

proc tlsServerConfig*(certChainPem, privateKeyPem: string; clientCaPem = "";
                      cipherOrder = coAuto): TlsConfig =
  ## A server; with `clientCaPem` clients must present a certificate it signed. The config comes
  ## back finished (build further on one thread only, before its first use: see `newTlsConfig`).
  result = newTlsConfig()
  result.setCipherOrder(cipherOrder)
  result.setIdentity(certChainPem, privateKeyPem)
  if clientCaPem.len > 0:
    result.addTrustedCa(clientCaPem)
    result.requireClientCert()

proc newClientTls*(c: TlsConfig; serverName: string): TlsConn =
  ## `serverName` must match a DNS name (dNSName entry or CN) in the server's certificate, or, if it
  ## is an IP address, an iPAddress entry; no SNI is sent for an IP address.
  let raw = gtls_client_new(c.raw, serverName.cstring)
  if raw.isNil: c.fail("client session")
  TlsConn(raw: raw)

proc newServerTls*(c: TlsConfig): TlsConn =
  let raw = gtls_server_new(c.raw)
  if raw.isNil: c.fail("server session")
  TlsConn(raw: raw)

# ---------------------------------------------------------------- pump

proc isClosed*(t: TlsConn): bool = (gtls_state(t.raw) and stClosed) != 0

proc errorMessage*(t: TlsConn): string =
  ## Why the session failed, from BearSSL's error code.
  let e = gtls_last_error(t.raw).int
  if gtls_alpn_refused(t.raw) != 0: return "peer did not negotiate ALPN h2"
  case e
  of 0: "TLS session closed"
  of 3, 4: "TLS: unsupported protocol version (TLS 1.2 is required)"
  of 29: "TLS: the client presented no certificate"
  of 35: "TLS: the peer presented no certificate"
  of 54: "TLS: certificate expired or not yet valid"
  of 56: "TLS: server name does not match the certificate"
  of 50: "TLS: certificate exceeds a limit (a client certificate of more than 128 KiB)"
  of 62: "TLS: certificate not signed by a trusted CA"
  else:
    if e >= 512: "TLS: sent fatal alert " & $(e - 512)
    elif e >= 256: "TLS: peer sent fatal alert " & $(e - 256)
    else: "TLS error " & $e

proc resumed*(t: TlsConn): bool =
  ## After the handshake: the session was resumed, not made afresh.
  gtls_resumed(t.raw) != 0

proc handshakeDone*(t: TlsConn): bool = (gtls_state(t.raw) and stSendApp) != 0

proc settle(t: TlsConn) =
  ## Moves a pending peer to verified or failed as soon as the handshake is done (ALPN must be
  ## h2, the peer authenticated as required), or has failed with an error. Never raises, and
  ## never goes back: a failed peer stays failed, however often it is asked.
  if t.peer != psPending: return
  if t.handshakeDone:
    let p = gtls_alpn(t.raw)
    if p == nil or p != "h2":
      t.peer = psFailed
      t.why = "peer did not negotiate ALPN h2"
    elif gtls_peer_ok(t.raw) == 0:
      t.peer = psFailed
      t.why = "peer did not present a trusted certificate"
    else:
      t.peer = psVerified
  elif t.isClosed and gtls_last_error(t.raw) != 0:
    t.peer = psFailed                 # the handshake ended in an error: the engine says which
    t.why = t.errorMessage

proc checkPeer*(t: TlsConn) =
  ## Raises TlsError if the peer failed: ALPN is not h2, the peer did not authenticate as
  ## required, or the handshake ended in an error. Does nothing while the handshake is still
  ## going on, and once the peer is verified. A failure is final: asking again raises again, and
  ## `pullApp` and `pushApp` move no data for a peer that is not verified, so a caller that
  ## ignored the exception (or calls this too late) still sends and receives nothing.
  t.settle()
  if t.peer == psFailed: raise newException(TlsError, t.why)

proc peerCert*(t: TlsConn): seq[byte] =
  ## A server that asks for client certificates: the DER of the certificate of the client, once
  ## the peer is verified (also on a resumed session: it is the certificate of the connection
  ## the session was made on). Empty without mutual TLS, and before the handshake is done.
  t.settle()
  if t.peer != psVerified: return
  var n: csize_t
  let p = gtls_peer_cert(t.raw, n.addr)
  if p != nil and n > 0:
    result = newSeq[byte](int(n))
    copyMem(result[0].addr, p, int(n))

proc pushRecords*(t: TlsConn; data: openArray[byte]): int =
  ## Feeds bytes from the network; returns how many were taken.
  var off = 0
  while off < data.len:
    let n = gtls_push_records(t.raw, data[off].unsafeAddr, csize_t(data.len - off)).int
    if n == 0: break
    off += n
  off

proc pullApp*(t: TlsConn; dst: var seq[byte]) =
  ## Appends the plaintext received so far to `dst`: nothing until the peer is verified, and
  ## TlsError for a peer that failed (see `checkPeer`).
  t.checkPeer()
  if t.peer != psVerified: return
  while true:
    let start = dst.len
    dst.setLenUninit(start + 16384)
    let n = gtls_pull_app(t.raw, dst[start].addr, 16384).int
    dst.setLen(start + n)
    if n == 0: break

proc pushApp*(t: TlsConn; data: openArray[byte]): int =
  ## Queues plaintext to send; returns how many bytes were taken (0 during the
  ## handshake, and for a peer that is not verified, or failed: nothing goes to a peer that did
  ## not pass `checkPeer`). Call `flush`, then `pullRecords`.
  t.settle()
  if t.peer != psVerified: return 0
  var off = 0
  while off < data.len:
    let n = gtls_push_app(t.raw, data[off].unsafeAddr, csize_t(data.len - off)).int
    if n == 0: break
    off += n
  off

proc flush*(t: TlsConn) = gtls_flush(t.raw)

proc pullRecords*(t: TlsConn): seq[byte] =
  ## Records ready for the network.
  while true:
    let start = result.len
    result.setLenUninit(start + 16384)
    let n = gtls_pull_records(t.raw, result[start].addr, 16384).int
    result.setLen(start + n)
    if n == 0: break

proc close*(t: TlsConn) = gtls_close(t.raw)
