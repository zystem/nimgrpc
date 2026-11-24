## Who the client is: what a server reads from the certificate of a client that authenticated
## with mutual TLS (`tlsServerConfig(..., clientCaPem = ...)`). The certificate has already been
## checked against the trusted CAs by the TLS engine; this module only reads names out of it.
##
## The identity comes from the certificate and from nothing else: not from metadata, not from
## what the client says in a call. A server that gives different clients of one CA different
## rights decides by `uris` (a SPIFFE ID, say), `dnsNames`, `emails`, `subject` or `fingerprint`
## and compares them exactly; the names are text from the certificate and mean nothing more.
##
## Names that are not text (a control character, bytes that are not UTF-8 where UTF-8 is
## required) are left out, so that a name cannot carry what looks like another name.

import std/[net, unicode]
import bearssl/abi/bearssl_hash

type
  PeerIdentity* = object
    authenticated*: bool       ## the client presented a certificate that chains to a trusted CA
                               ## (also on a resumed connection: the identity of the session
                               ## it resumes). False without mutual TLS: nothing else is set then.
    certDer*: seq[byte]        ## the client's own certificate, DER
    subject*: string           ## the subject's commonName ("" if it has none, or it is not text)
    dnsNames*: seq[string]     ## subjectAltName dNSName entries
    uris*: seq[string]         ## subjectAltName URI entries (a SPIFFE ID is one)
    emails*: seq[string]       ## subjectAltName rfc822Name entries
    ipAddresses*: seq[string]  ## subjectAltName iPAddress entries, as text
    fingerprint*: string       ## SHA-256 of `certDer`, 64 lowercase hex digits

const
  maxNames = 1000              ## names kept of each kind; a certificate holds no more than that

type Tlv = object
  tag: int
  start, len: int              ## the value: data[start ..< start + len]
  next: int                    ## where the next element begins

proc readTlv(d: openArray[byte]; pos, stop: int; t: var Tlv): bool =
  ## One DER element at `pos`, not reaching past `stop`. Tags of more than one byte are refused.
  if pos < 0 or pos + 2 > stop or stop > d.len: return false
  let tag = int(d[pos])
  if (tag and 0x1f) == 0x1f: return false
  var p = pos + 1
  var n = int(d[p])
  inc p
  if n >= 0x80:
    let k = n and 0x7f
    if k == 0 or k > 4 or p + k > stop: return false
    n = 0
    for i in 0 ..< k: n = (n shl 8) or int(d[p + i])
    p += k
  if n < 0 or p + n > stop: return false
  t = Tlv(tag: tag, start: p, len: n, next: p + n)
  true

proc bytesToString(d: openArray[byte]; start, len: int): string =
  result = newString(len)
  if len > 0: copyMem(result[0].addr, d[start].unsafeAddr, len)

proc noControl(d: openArray[byte]; t: Tlv): bool =
  ## No control character (NUL included) in the value. Checked on the bytes, before a string
  ## is made of them, so that a refused value allocates nothing.
  for i in 0 ..< t.len:
    let b = d[t.start + i]
    if b < 0x20 or b == 0x7f: return false
  true

proc allAscii(d: openArray[byte]; t: Tlv): bool =
  for i in 0 ..< t.len:
    if d[t.start + i] >= 0x80: return false
  true

proc textOf(d: openArray[byte]; t: Tlv): string =
  ## The characters of a string element, as UTF-8; "" for what is not usable text.
  if not noControl(d, t): return ""
  case t.tag
  of 0x13, 0x16, 0x14:           # PrintableString, IA5String, TeletexString: ASCII
    if allAscii(d, t): result = bytesToString(d, t.start, t.len)
  of 0x0c:                        # UTF8String
    let s = bytesToString(d, t.start, t.len)
    if validateUtf8(s) == -1: result = s
  of 0x1e:                        # BMPString: UTF-16, big-endian
    if t.len mod 2 != 0: return ""
    var s = ""
    var i = 0
    while i < t.len:
      let u = (int(d[t.start + i]) shl 8) or int(d[t.start + i + 1])
      i += 2
      if u >= 0xd800 and u <= 0xdfff: return ""     # a surrogate: not a BMP character
      if u < 0x20 or u == 0x7f: return ""
      s.add Rune(u).toUTF8
    result = s
  else: discard

proc asciiText(d: openArray[byte]; t: Tlv): string =
  ## A name of a subjectAltName entry (IA5String): printable ASCII only.
  for i in 0 ..< t.len:
    let b = d[t.start + i]
    if b < 0x20 or b >= 0x7f: return ""
  bytesToString(d, t.start, t.len)

proc ipText(d: openArray[byte]; t: Tlv): string =
  if t.len == 4:
    var ip = IpAddress(family: IpAddressFamily.IPv4)
    for i in 0 ..< 4: ip.address_v4[i] = d[t.start + i]
    $ip
  elif t.len == 16:
    var ip = IpAddress(family: IpAddressFamily.IPv6)
    for i in 0 ..< 16: ip.address_v6[i] = d[t.start + i]
    $ip
  else: ""

const
  oidCommonName = [0x55'u8, 0x04, 0x03]
  oidSubjectAltName = [0x55'u8, 0x1d, 0x11]

proc oidIs(d: openArray[byte]; t: Tlv; oid: openArray[byte]): bool =
  if t.tag != 0x06 or t.len != oid.len: return false
  for i in 0 ..< oid.len:
    if d[t.start + i] != oid[i]: return false
  true

proc sha256Hex(der: openArray[byte]): string =
  var ctx: Sha256Context
  sha256Init(ctx)
  if der.len > 0: sha256Update(ctx, der[0].unsafeAddr, csize_t(der.len))
  var h: array[32, byte]
  sha256Out(ctx, h[0].addr)
  const digits = "0123456789abcdef"
  for b in h:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

proc parseSubject(d: openArray[byte]; subj: Tlv; id: var PeerIdentity) =
  # Name ::= SEQUENCE OF RelativeDistinguishedName (SET OF AttributeTypeAndValue)
  var rp = subj.start
  while rp < subj.next:
    var rdn: Tlv
    if not readTlv(d, rp, subj.next, rdn) or rdn.tag != 0x31: return
    var ap = rdn.start
    while ap < rdn.next:
      var atv: Tlv
      if not readTlv(d, ap, rdn.next, atv) or atv.tag != 0x30: return
      var oid, val: Tlv
      if readTlv(d, atv.start, atv.next, oid) and readTlv(d, oid.next, atv.next, val) and
         oidIs(d, oid, oidCommonName):
        id.subject = textOf(d, val)            # the last one is the most specific
      ap = atv.next
    rp = rdn.next

proc parseAltNames(d: openArray[byte]; oct: Tlv; id: var PeerIdentity) =
  # extnValue is an OCTET STRING that holds a SEQUENCE OF GeneralName
  if oct.tag != 0x04: return
  var seqT: Tlv
  if not readTlv(d, oct.start, oct.next, seqT) or seqT.tag != 0x30: return
  var p = seqT.start
  while p < seqT.next:
    var n: Tlv
    if not readTlv(d, p, seqT.next, n): return
    p = n.next
    case n.tag
    of 0x81:                                   # rfc822Name
      let s = asciiText(d, n)
      if s.len > 0 and id.emails.len < maxNames: id.emails.add s
    of 0x82:                                   # dNSName
      let s = asciiText(d, n)
      if s.len > 0 and id.dnsNames.len < maxNames: id.dnsNames.add s
    of 0x86:                                   # uniformResourceIdentifier
      let s = asciiText(d, n)
      if s.len > 0 and id.uris.len < maxNames: id.uris.add s
    of 0x87:                                   # iPAddress
      let s = ipText(d, n)
      if s.len > 0 and id.ipAddresses.len < maxNames: id.ipAddresses.add s
    else: discard

proc parsePeerCert*(der: openArray[byte]): PeerIdentity =
  ## The identity in a DER certificate. A certificate this reader cannot make sense of gives an
  ## identity with the fingerprint and `certDer` only: the fingerprint is always right.
  result.certDer = @der
  result.fingerprint = sha256Hex(der)
  result.authenticated = true
  # Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { ... }, ... }
  var cert, tbs: Tlv
  if not readTlv(der, 0, der.len, cert) or cert.tag != 0x30: return
  if not readTlv(der, cert.start, cert.next, tbs) or tbs.tag != 0x30: return
  var p = tbs.start
  var t: Tlv
  # [0] version (optional), serialNumber, signature, issuer, validity, subject, spki
  if not readTlv(der, p, tbs.next, t): return
  if t.tag == 0xa0:
    p = t.next
    if not readTlv(der, p, tbs.next, t): return
  p = t.next                                   # past the serial number
  for _ in 0 ..< 3:                            # signature, issuer, validity
    if not readTlv(der, p, tbs.next, t): return
    p = t.next
  var subj: Tlv
  if not readTlv(der, p, tbs.next, subj) or subj.tag != 0x30: return
  parseSubject(der, subj, result)
  p = subj.next
  if not readTlv(der, p, tbs.next, t): return  # subjectPublicKeyInfo
  p = t.next
  while p < tbs.next:                          # [1] [2] unique ids, [3] extensions
    if not readTlv(der, p, tbs.next, t): return
    p = t.next
    if t.tag != 0xa3: continue
    var exts: Tlv
    if not readTlv(der, t.start, t.next, exts) or exts.tag != 0x30: return
    var ep = exts.start
    while ep < exts.next:
      var ext: Tlv
      if not readTlv(der, ep, exts.next, ext) or ext.tag != 0x30: return
      ep = ext.next
      var oid, nxt: Tlv
      if not readTlv(der, ext.start, ext.next, oid) or not oidIs(der, oid, oidSubjectAltName):
        continue
      # [critical BOOLEAN DEFAULT FALSE] extnValue OCTET STRING
      if not readTlv(der, oid.next, ext.next, nxt): continue
      var valueAt = nxt
      if nxt.tag == 0x01:
        if not readTlv(der, nxt.next, ext.next, valueAt): continue
      parseAltNames(der, valueAt, result)
