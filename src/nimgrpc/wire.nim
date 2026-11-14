## The gRPC-over-HTTP/2 wire details (grpc/grpc doc/PROTOCOL-HTTP2.md):
## length-prefixed messages, grpc-timeout, grpc-message percent-encoding,
## binary metadata and the reserved header names.

import std/[base64, strutils]
import ./status, ./bytebuf

const
  defaultMaxMessage* = 4 * 1024 * 1024
  grpcContentType* = "application/grpc"

proc isGrpcContentType*(v: string): bool {.raises: [].} =
  ## "application/grpc", optionally followed by "+subtype" or ";parameters"
  ## (`application/grpc+proto`, `application/grpc;charset=utf-8`); a longer
  ## media type such as `application/grpcx` is not gRPC.
  v.startsWith(grpcContentType) and
    (v.len == grpcContentType.len or v[grpcContentType.len] in {'+', ';'})

# ---------------------------------------------------------------- messages

proc encodeMessage*(msg: openArray[byte]; compressed = false): seq[byte] =
  ## One message frame: flag byte (1 if `msg` is already compressed), 4-byte
  ## big-endian length, payload.
  result = newSeqUninit[byte](5 + msg.len)
  result[0] = byte(ord(compressed))
  let n = msg.len.uint32
  result[1] = byte(n shr 24)
  result[2] = byte(n shr 16)
  result[3] = byte(n shr 8)
  result[4] = byte(n)
  if msg.len > 0: copyMem(result[5].addr, msg[0].unsafeAddr, msg.len)

proc decodeMessages*(body: openArray[byte]; maxLen = defaultMaxMessage): seq[seq[byte]] =
  ## Splits a complete body into messages. Raises GrpcError on a truncated
  ## frame (INTERNAL), a compressed one (UNIMPLEMENTED: no codec is
  ## negotiated) or one above `maxLen` (RESOURCE_EXHAUSTED).
  var i = 0
  while i < body.len:
    if body.len - i < 5:
      raise newGrpcError(scInternal, "truncated message header")
    let flag = body[i]
    let n = (body[i+1].int shl 24) or (body[i+2].int shl 16) or
            (body[i+3].int shl 8) or body[i+4].int
    if flag != 0:
      raise newGrpcError(scUnimplemented, "compressed message without grpc-encoding")
    if n > maxLen:
      raise newGrpcError(scResourceExhausted,
        "message of " & $n & " bytes exceeds the limit of " & $maxLen)
    if body.len - i - 5 < n:
      raise newGrpcError(scInternal, "truncated message")
    result.add @(body.toOpenArray(i + 5, i + 4 + n))
    i += 5 + n

type
  MsgBuf* = object
    ## Reassembles message frames from the chunks of a body. A chunk is kept as
    ## it came (no copy) and its bytes go straight into the message being
    ## built, which grows only as data arrives, so a declared length alone
    ## reserves nothing.
    pending: seq[byte]          ## the last chunk fed ...
    ppos: int                   ## ... of which this much is used
    hdr: array[5, byte]
    hdrLen: int
    inBody: bool
    flag: byte
    need: int                   ## length of the message being built
    payload: seq[byte]

proc feed*(m: var MsgBuf; chunk: var seq[byte]) =
  ## Hands over the next received bytes; `chunk` is left empty. Take every
  ## complete message (`take` until false) before feeding more.
  if chunk.len == 0: return
  if m.ppos >= m.pending.len:
    m.pending = move chunk
    m.ppos = 0
  else:                          # not taken yet: keep order
    m.pending = m.pending[m.ppos .. ^1]
    m.ppos = 0
    m.pending.appendBytes chunk
  chunk = @[]

proc leftover*(m: MsgBuf): int =
  ## Bytes received that do not make a whole message yet.
  (m.pending.len - m.ppos) + (if m.inBody: 5 + m.payload.len else: m.hdrLen)

proc take*(m: var MsgBuf; maxLen: int; payload: var seq[byte];
           compressed: var bool): bool =
  ## Takes the next complete message, if there is one. Raises GrpcError for a
  ## bad flag (INTERNAL) or a declared length above `maxLen`
  ## (RESOURCE_EXHAUSTED).
  while true:
    if not m.inBody:
      while m.hdrLen < 5 and m.ppos < m.pending.len:
        m.hdr[m.hdrLen] = m.pending[m.ppos]
        inc m.hdrLen
        inc m.ppos
      if m.hdrLen < 5:
        m.pending = @[]
        m.ppos = 0
        return false
      let flag = m.hdr[0]
      if flag > 1: raise newGrpcError(scInternal, "invalid message flag " & $flag)
      let n = (m.hdr[1].int shl 24) or (m.hdr[2].int shl 16) or
              (m.hdr[3].int shl 8) or m.hdr[4].int
      if n > maxLen:
        raise newGrpcError(scResourceExhausted,
          "message of " & $n & " bytes exceeds the limit of " & $maxLen)
      m.inBody = true
      m.flag = flag
      m.need = n
      m.payload = newSeqOfCap[byte](min(n, 65536))
    let k = min(m.need - m.payload.len, m.pending.len - m.ppos)
    if k > 0:
      m.payload.appendBytes(m.pending[m.ppos].addr, k)
      m.ppos += k
    if m.ppos >= m.pending.len:
      m.pending = @[]
      m.ppos = 0
    if m.payload.len == m.need:
      payload = move m.payload
      compressed = m.flag == 1
      m.payload = @[]
      m.inBody = false
      m.hdrLen = 0
      return true
    return false

proc frameHeader*(len: int; compressed = false): array[5, byte] =
  ## The 5 bytes in front of a message of `len` bytes.
  let n = len.uint32
  [byte(ord(compressed)), byte(n shr 24), byte(n shr 16), byte(n shr 8), byte(n)]

const supportedEncodings* = ["identity", "gzip"]
const acceptEncodingHeader* = ("grpc-accept-encoding", "gzip")

# ---------------------------------------------------------------- grpc-timeout

proc encodeTimeout*(ms: int): string =
  ## At most 8 digits, as the spec requires.
  if ms < 0: return "0m"
  if ms < 100_000_000: return $ms & "m"
  let s = (ms + 999) div 1000
  if s < 100_000_000: return $s & "S"
  $min((s + 59) div 60, 99_999_999) & "M"

proc parseTimeout*(v: string): int {.raises: [].} =
  ## Milliseconds, rounded up; -1 if the value is malformed.
  if v.len < 2 or v.len > 9: return -1
  let digits = v[0 ..< v.high]
  for ch in digits:
    if ch notin Digits: return -1
  let n = try: parseBiggestInt(digits) except ValueError: return -1
  case v[^1]
  of 'H': int(n * 3_600_000)
  of 'M': int(n * 60_000)
  of 'S': int(n * 1000)
  of 'm': int(n)
  of 'u': int((n + 999) div 1000)
  of 'n': int((n + 999_999) div 1_000_000)
  else: -1

# ---------------------------------------------------------------- grpc-message

proc encodeStatusMessage*(msg: string): string =
  ## Percent-encodes everything outside printable ASCII, and '%' itself.
  for ch in msg:
    if ch >= ' ' and ch <= '~' and ch != '%': result.add ch
    else: result.add '%' & toHex(ord(ch), 2)

proc decodeStatusMessage*(v: string): string =
  ## Lenient: a malformed escape is kept as is.
  var i = 0
  while i < v.len:
    if v[i] == '%' and i + 2 <= v.high and
       v[i+1] in HexDigits and v[i+2] in HexDigits:
      result.add chr(parseHexInt(v[i+1 .. i+2]))
      i += 3
    else:
      result.add v[i]
      inc i

# ---------------------------------------------------------------- metadata

proc isReserved*(key: string): bool =
  ## Headers the library owns; they never appear in user metadata.
  key.len == 0 or key[0] == ':' or key in ["content-type", "te"] or
    (key.startsWith("grpc-") and key != "grpc-status-details-bin")

proc toWire*(md: Metadata): seq[(string, string)] =
  for (k, v) in md:
    let key = k.toLowerAscii
    if key.isReserved: continue
    result.add (key, if key.endsWith("-bin"): encode(v).strip(leading = false, chars = {'='})
                     else: v)

proc fromWire*(headers: openArray[(string, string)]): Metadata =
  for (k, v) in headers:
    if k.isReserved: continue
    if k.endsWith("-bin"):
      var padded = v
      while padded.len mod 4 != 0: padded.add '='
      try: result.add (k, decode(padded))
      except ValueError: discard     # undecodable binary metadata is dropped
    else:
      result.add (k, v)

proc httpToStatus*(httpStatus: string): StatusCode =
  ## The mapping a client uses when a response carries no grpc-status.
  case httpStatus
  of "400": scInternal
  of "401": scUnauthenticated
  of "403": scPermissionDenied
  of "404": scUnimplemented
  of "429", "502", "503", "504": scUnavailable
  else: scUnknown
