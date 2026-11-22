## What a server reads out of a client certificate (src/nimgrpc/tls/peerid.nim): real
## certificates made by openssl (tests/certs/ident, expected values from `openssl x509`), the
## fingerprint, and what the reader does with damaged and hostile certificates.

import std/[unittest, os, base64, strutils]
import nimgrpc/tls/peerid

const certs = currentSourcePath.parentDir / "certs" / "ident"

proc derOf(name: string): seq[byte] =
  var body = ""
  for l in readFile(certs / name).splitLines:
    if l.len > 0 and not l.startsWith("-----"): body.add l
  for c in base64.decode(body): result.add byte(c)

suite "client certificates (made by openssl)":
  test "alice: common name and every kind of alternative name":
    let id = parsePeerCert(derOf("alice.pem"))
    check id.authenticated
    check id.subject == "alice"
    check id.dnsNames == @["alice.example.com", "alice-alt.example.com"]
    check id.uris == @["spiffe://example.org/ns/prod/sa/alice"]
    check id.emails == @["alice@example.com"]
    check id.ipAddresses == @["10.1.2.3", "2001:db8::1"]
    check id.fingerprint == "b5ae2363117433dfbca74c2a2d19affb1ad4362aa982af757955d2a87f8ba810"
    check id.certDer == derOf("alice.pem")

  test "bob: a name and nothing else":
    let id = parsePeerCert(derOf("bob.pem"))
    check id.subject == "bob"
    check id.dnsNames.len + id.uris.len + id.emails.len + id.ipAddresses.len == 0
    check id.fingerprint == "0d9cd0590bccec957415888583d824752627d381676fc11aef94883f1afcf174"

  test "carol: a UTF-8 name":
    let id = parsePeerCert(derOf("carol.pem"))
    check id.subject == "Zoë Müller"
    check id.uris == @["spiffe://example.org/ns/prod/sa/carol"]
    check id.fingerprint == "0bda79b2e38757377673e9ab72b9570afcc153b618b31e4f58b4de2e317bd8d5"

suite "damaged and hostile certificates":
  proc tlv(tag: int; content: seq[byte]): seq[byte] =
    result.add byte(tag)
    if content.len < 128: result.add byte(content.len)
    else:
      result.add 0x82'u8
      result.add byte(content.len shr 8)
      result.add byte(content.len and 255)
    result.add content

  proc bytes(s: string): seq[byte] =
    for c in s: result.add byte(c)

  proc cat(parts: varargs[seq[byte]]): seq[byte] =
    for p in parts: result.add p

  proc certWith(commonName: string; names: seq[byte]): seq[byte] =
    ## A certificate with just enough in it: a subject with a commonName, and the given
    ## subjectAltName entries.
    let oidCn = tlv(0x06, @[0x55'u8, 0x04, 0x03])
    let subject = tlv(0x30, tlv(0x31, tlv(0x30, cat(oidCn, tlv(0x0c, bytes(commonName))))))
    let oidSan = tlv(0x06, @[0x55'u8, 0x1d, 0x11])
    let ext = tlv(0x30, cat(oidSan, tlv(0x04, tlv(0x30, names))))
    let exts = tlv(0xa3, tlv(0x30, ext))
    let tbs = tlv(0x30, cat(tlv(0xa0, @[0x02'u8, 0x01, 0x02]), tlv(0x02, @[1'u8]),
                            tlv(0x30, @[]), tlv(0x30, @[]), tlv(0x30, @[]), subject,
                            tlv(0x30, @[]), exts))
    tlv(0x30, cat(tbs, tlv(0x30, @[]), tlv(0x03, @[0'u8])))

  test "the helper makes a certificate the reader understands":
    let id = parsePeerCert(certWith("x", cat(tlv(0x82, bytes("a.example.com")))))
    check id.subject == "x"
    check id.dnsNames == @["a.example.com"]

  test "a NUL or another control character in a name leaves the name out":
    let names = cat(tlv(0x82, bytes("a\x00b.example.com")),      # the old "a.example.com\0.evil.com"
                    tlv(0x82, bytes("ok.example.com")),
                    tlv(0x86, bytes("spiffe://x/a\nb")),
                    tlv(0x81, bytes("a@b\x7f.example.com")))
    let id = parsePeerCert(certWith("ok", names))
    check id.dnsNames == @["ok.example.com"]
    check id.uris.len == 0
    check id.emails.len == 0
    check parsePeerCert(certWith("x\x00y", @[])).subject == ""      # a commonName with a NUL

  test "a commonName that is not UTF-8 is not text":
    check parsePeerCert(certWith("\xc3\x28", @[])).subject == ""

  test "an address of the wrong length is left out":
    let id = parsePeerCert(certWith("x", cat(tlv(0x87, @[1'u8, 2, 3]), tlv(0x87, @[10'u8, 0, 0, 7]))))
    check id.ipAddresses == @["10.0.0.7"]

  test "no prefix of a certificate, and no changed byte, crashes the reader":
    let der = derOf("alice.pem")
    for n in 0 .. der.len:
      let id = parsePeerCert(der[0 ..< n])
      check id.certDer.len == n
      check id.fingerprint.len == 64
    var seed = 12345'u32
    for round in 0 ..< 3000:
      var d = der
      for k in 0 ..< 1 + round mod 4:
        seed = seed * 1664525'u32 + 1013904223'u32
        d[int(seed shr 8) mod d.len] = byte(seed shr 24)
      discard parsePeerCert(d)

  test "an element that claims more than there is":
    var d = derOf("alice.pem")
    d[1] = 0x84'u8                      # the length of the certificate takes four bytes ...
    d[2] = 0xff; d[3] = 0xff; d[4] = 0xff; d[5] = 0xff       # ... and says it is huge
    let id = parsePeerCert(d)
    check id.subject == ""
    check id.fingerprint.len == 64
