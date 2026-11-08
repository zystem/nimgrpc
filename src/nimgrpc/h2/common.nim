## Types shared by the blocking and the chronos HTTP/2 adapters.

import ./session

type
  H2Timeout* = object of H2Error
    ## The deadline passed; the stream has been reset with CANCEL.

  H2StreamClosed* = object of H2Error
    ## The stream is gone (reset by the peer, or the connection closed).

  Keepalive* = object
    ## Connection health checks with HTTP/2 PING (gRPC's keepalive).
    timeMs*: int
      ## Send a PING after this long without receiving anything; 0 turns
      ## keepalive off.
    timeoutMs*: int
      ## Close the connection if the PING is not acknowledged within this
      ## time (default 20 s when 0).
    withoutCalls*: bool
      ## Client: ping also while no call is in progress.
    tcpSecs*: int = 15
      ## The system's TCP keepalive on the socket: a probe after this many seconds of silence
      ## and every this many seconds after, the connection dropped after 9 unanswered. It
      ## finds a vanished peer without HTTP/2 PINGs and keeps a NAT or load balancer from
      ## forgetting a quiet connection. 0 leaves the system's default (off).

  PingPolicy* = object
    ## Server: what clients may do with PINGs (gRPC's enforcement policy).
    minIntervalMs*: int
      ## Pings closer together than this count as strikes; after more than
      ## two the connection gets GOAWAY ENHANCE_YOUR_CALM "too_many_pings".
      ## 0 turns enforcement off.
    permitWithoutCalls*: bool
      ## Pings while no call is in progress are allowed (else they are strikes).

  Limits* = object
    ## What a server accepts from its peers; the defaults suit most programs.
    maxConcurrentStreams*: int = 100
      ## Streams a client may have open at once on one connection (announced
      ## as SETTINGS_MAX_CONCURRENT_STREAMS; one more is refused with
      ## REFUSED_STREAM). 0 leaves nghttp2's default, which is no limit.
    maxConnections*: int = 0
      ## Connections served at once; a connection past the limit is closed
      ## at once. 0 means no limit.
    handshakeTimeoutMs*: int = 120_000
      ## A connection that has not completed the TLS handshake and sent the HTTP/2 preface and
      ## its first SETTINGS this long after it was accepted is closed. 0 means no limit.
    maxConnectionBuffer*: int = 16 * 1024 * 1024
      ## Body bytes that handlers have queued on all the streams of one
      ## connection and the socket has not taken; a sender waits above it.
      ## Together with `maxStreamBuffer` this bounds what a peer that does not
      ## read can make us hold. 0 means no limit beyond `maxStreamBuffer`.

const
  readChunk* = 16 * 1024
  maxOutQueue* = 256 * 1024        ## bytes framed and waiting for the socket
  maxStreamBuffer* = 256 * 1024    ## unsent body bytes per stream before send waits
  NO_ERROR* = 0'u32
  INTERNAL_ERROR* = 2'u32
  CANCEL* = 8'u32
  ENHANCE_YOUR_CALM* = 11'u32
  defaultPingTimeoutMs* = 20_000

proc consumed*(s: var seq[byte]; pos: var int; n: int) =
  ## Marks `n` more bytes at the front of `s` as used. The buffer is only
  ## emptied once all of it is used (or, for a long one, half of it is), so
  ## taking it a record at a time does not shift the rest each time.
  pos += n
  if pos >= s.len:
    s.setLen(0)
    pos = 0
  elif pos >= 65536 and pos * 2 >= s.len:
    let rest = s.len - pos
    moveMem(s[0].addr, s[pos].addr, rest)
    s.setLen(rest)
    pos = 0

proc dropPrefix*(s: var seq[byte]; n: int) =
  let rest = s.len - n
  if rest > 0: moveMem(s[0].addr, s[n].addr, rest)
  s.setLen(rest)

proc isIpv6Literal*(host: string): bool =
  ## "::1", "::", "fe80::1", "[::1]": an address with a colon is IPv6.
  ':' in host

proc stripBrackets*(host: string): string =
  ## "[::1]" -> "::1"; anything else unchanged.
  if host.len > 2 and host[0] == '[' and host[^1] == ']': host[1 ..< host.high] else: host

proc hostPort*(host: string; port: int): string =
  ## "host:port" as an :authority; an IPv6 literal gets its brackets ("[::1]:50051").
  let h = stripBrackets(host)
  (if isIpv6Literal(h): "[" & h & "]" else: h) & ":" & $port
