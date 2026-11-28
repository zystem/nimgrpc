## Which BearSSL implementations a connection uses for secret data. Each one allowed here is one
## BearSSL writes to run in constant time (https://www.bearssl.org/constanttime.html); the table
## based AES and the i32 RSA are not. A new version of BearSSL or of the compiler, or another
## CPU, that picks something else fails here. This looks at the choice only, not at what the
## compiler made of that code, and measures no time.
##
## nim.cfg of this file defines gtlsProbe, and the C file is built with -DGTLS_PROBE.

import std/[unittest, os]

# Before the import: Nim notes the C flags of gtls.c when it meets its {.compile.}, so a flag
# given later would let it reuse an object built without it.
{.passc: "-DGTLS_PROBE".}
import nimgrpc/tls/tls

const certs = currentSourcePath.parentDir / "certs"
proc pem(name: string): string = readFile(certs / name)

const allowed = {
  "aes": @["br_aes_x86ni_ctr_vtable", "br_aes_ct64_ctr_vtable", "br_aes_ct_ctr_vtable"],
  "ghash": @["br_ghash_pclmul", "br_ghash_ctmul64", "br_ghash_ctmul32", "br_ghash_ctmul"],
  "chacha20": @["br_chacha20_sse2", "br_chacha20_ct_run"],
  "poly1305": @["br_poly1305_ctmulq", "br_poly1305_ctmul32_run", "br_poly1305_ctmul_run"],
  "ec": @["ec_fast"],                       # gtls.c's router: P-256 below, the rest br_ec_all_m31
  "p256": @["br_ec_p256_m64", "br_ec_all_m31"],
  "rsa-private": @["br_rsa_i62_private", "br_rsa_i31_private", "br_rsa_i15_private"],
  "ecdsa-sign": @["br_ecdsa_i31_sign_asn1", "br_ecdsa_i15_sign_asn1"]}

suite "the implementations that handle secrets":
  test "a client and a server use constant-time ones only":
    for (cert, key) in [("server.pem", "server.key"), ("rsaserver.pem", "rsaserver.key")]:
      let c = newClientTls(tlsClientConfig(pem"ca.pem"), "localhost")
      let s = newServerTls(tlsServerConfig(pem(cert), pem(key)))
      for (what, names) in allowed:
        for t in [c, s]:
          let got = t.implementationOf(what)
          checkpoint what & ": " & got
          check got in names
      if cert == "server.pem":
        var line = "implementations:"
        for (what, _) in allowed: line.add " " & what & "=" & s.implementationOf(what)
        echo line
