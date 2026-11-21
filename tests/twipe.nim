## What the TLS layer leaves in memory it frees. gtls.c wipes the private key, the record keys and
## buffers (they hold plaintext), the session cache and the temporary copies of the key before it
## frees them; but a plain `memset` just before `free` is a dead store, and an optimizing compiler
## removes it (the audit of 2026-11-21 saw it missing in a release binary). So this test is built
## with -O2 and `free` wrapped (-Wl,--wrap=free): while armed, every block that gtls.c frees is
## searched for a private key's scalar and for a plaintext that went through a connection, and a
## block that still has one is a hit. It runs on Linux without -d:useMalloc (the sanitizer runs
## of `nimble asan` and `nimble tsan` use it, and put their own `free` in the way).

import std/[unittest, os, base64, strutils]
import nimgrpc/tls/tls as rawtls

when defined(linux) and not defined(useMalloc):
  {.passc: "-O2".}
  {.passl: "-Wl,--wrap=free".}
  {.emit: """
#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <malloc.h>
extern void __real_free(void *);
static const unsigned char *wipe_needle[4];
static size_t wipe_len[4];
static int wipe_n;
static int wipe_hits[4];
static volatile int wipe_armed;
void __wrap_free(void *p) {
    if (wipe_armed && p) {
        size_t sz = malloc_usable_size(p);
        for (int i = 0; i < wipe_n; i++)
            if (sz >= wipe_len[i] && memmem(p, sz, wipe_needle[i], wipe_len[i])) wipe_hits[i]++;
    }
    __real_free(p);
}
void wipe_set(int i, const unsigned char *n, size_t l) { wipe_needle[i] = n; wipe_len[i] = l; if (i >= wipe_n) wipe_n = i + 1; wipe_hits[i] = 0; }
void wipe_arm(int on) { wipe_armed = on; }
int wipe_hit(int i) { return wipe_hits[i]; }
""".}
  proc wipeSet(i: cint; n: ptr byte; l: csize_t) {.importc: "wipe_set", nodecl.}
  proc wipeArm(on: cint) {.importc: "wipe_arm", nodecl.}
  proc wipeHit(i: cint): cint {.importc: "wipe_hit", nodecl.}

  const certs = currentSourcePath.parentDir / "certs"
  proc pem(name: string): string = readFile(certs / name)

  proc feed(t: TlsConn; data: seq[byte]) =
    var rest = data
    while rest.len > 0:
      let n = t.pushRecords(rest)
      if n == 0: break
      rest = rest[n .. ^1]

  proc ecScalar(keyPem: string): string =
    ## The 32 bytes of the private scalar of an EC P-256 key in PKCS#8: after 02 01 01 04 20.
    var body = ""
    for l in keyPem.splitLines:
      if l.len > 0 and not l.startsWith("-----"): body.add l
    let der = base64.decode(body)
    let at = der.find("\x02\x01\x01\x04\x20")
    doAssert at >= 0
    der[at + 5 ..< at + 5 + 32]

  let plain = "gtls-wipe-test: plaintext that went through a connection 0123456789"

  proc exercise() =
    ## Builds configurations and connections, sends the plaintext, lets all of it go.
    let sc = tlsServerConfig(pem"server.pem", pem"server.key")
    let cc = tlsClientConfig(pem"ca.pem")
    for round in 0 ..< 2:                  # the second one resumes: the session cache is used
      let c = newClientTls(cc, "localhost")
      let s = newServerTls(sc)
      for _ in 0 ..< 100:
        c.feed(s.pullRecords())
        s.feed(c.pullRecords())
        if c.handshakeDone and s.handshakeDone: break
      c.checkPeer(); s.checkPeer()
      var data = newSeq[byte](plain.len)
      copyMem(data[0].addr, plain[0].unsafeAddr, plain.len)
      doAssert c.pushApp(data) == data.len
      c.flush()
      s.feed(c.pullRecords())
      var got: seq[byte]
      s.pullApp(got)
      doAssert got.len == data.len
    # a rebuilt identity: the old key is replaced (and wiped), and the new one loaded
    let sc2 = newTlsConfig()
    sc2.setIdentity(pem"rsaserver.pem", pem"rsaserver.key")
    sc2.setIdentity(pem"server.pem", pem"server.key")

  suite "memory that the TLS layer frees":
    test "no private key and no plaintext is left in a block gtls.c frees":
      let scalar = ecScalar(pem"server.key")
      doAssert scalar.len == 32
      wipeSet(0, cast[ptr byte](scalar[0].unsafeAddr), csize_t(scalar.len))
      wipeSet(1, cast[ptr byte](plain[0].unsafeAddr), csize_t(plain.len))
      wipeArm(1)
      exercise()
      wipeArm(0)
      checkpoint "private key scalar found in freed blocks: " & $wipeHit(0)
      checkpoint "plaintext found in freed blocks: " & $wipeHit(1)
      check wipeHit(0) == 0
      check wipeHit(1) == 0
else:
  suite "memory that the TLS layer frees":
    test "skipped (needs Linux and no -d:useMalloc)":
      skip()
