## Options of the TCP socket that both adapters set.

import std/posix
import std/nativesockets except IPPROTO_TCP

when defined(linux):
  let TCP_KEEPIDLE {.importc, header: "<netinet/tcp.h>".}: cint
  let TCP_KEEPINTVL {.importc, header: "<netinet/tcp.h>".}: cint
  let TCP_KEEPCNT {.importc, header: "<netinet/tcp.h>".}: cint

const keepProbes = 9      ## unanswered probes before the system drops the connection (Go's default)

proc setTcpKeepalive*(fd: SocketHandle; secs: int) =
  ## Turns on the system's TCP keepalive: after `secs` of silence a probe is sent, then one every
  ## `secs`, and after 9 unanswered ones the connection is dropped. It finds a peer that has
  ## vanished (a cut cable, a crashed machine) and keeps a NAT or a load balancer from forgetting
  ## a quiet connection. 0 or less leaves the system's default (off). Errors are ignored: a
  ## system without the option is no worse off.
  if secs <= 0: return
  var on: cint = 1
  discard setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, on.addr, sizeof(cint).SockLen)
  when defined(linux):
    var v: cint = secs.cint
    discard setsockopt(fd, posix.IPPROTO_TCP, TCP_KEEPIDLE, v.addr, sizeof(cint).SockLen)
    discard setsockopt(fd, posix.IPPROTO_TCP, TCP_KEEPINTVL, v.addr, sizeof(cint).SockLen)
    var probes: cint = keepProbes
    discard setsockopt(fd, posix.IPPROTO_TCP, TCP_KEEPCNT, probes.addr, sizeof(cint).SockLen)

proc tcpKeepaliveOn*(fd: SocketHandle): bool =
  ## Whether SO_KEEPALIVE is set on the socket (for tests).
  var on: cint
  var len = sizeof(cint).SockLen
  getsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, on.addr, len.addr) == 0 and on != 0

proc setTcpKeepalive*(fd: cint; secs: int) =
  ## The same for a plain descriptor (the chronos adapter has no `SocketHandle`).
  setTcpKeepalive(SocketHandle(fd), secs)

proc tcpKeepaliveOn*(fd: cint): bool = tcpKeepaliveOn(SocketHandle(fd))
