#!/usr/bin/env python3
import os
import pty
import random
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import tty

SOCKET = "/run/sinty-matrix/socket"
KINDS = [0x01, 0x10, 0x10, 0x10, 0x11, 0x12, 0x13, 0x13, 0x81]


def crc8(data):
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def packet(kind, payload):
    body = bytes([kind, len(payload)]) + payload
    return b"\xa5\x5a" + body + bytes([crc8(body)])


def controller(fd, info, stats):
    buf = b""
    while True:
        try:
            data = os.read(fd, 4096)
        except OSError:
            return
        buf += data
        while True:
            start = buf.find(b"\xa5\x5a")
            if start < 0 or len(buf) < start + 4:
                buf = buf[start:] if start >= 0 else b""
                break
            n = buf[start + 3]
            if len(buf) < start + 5 + n:
                buf = buf[start:]
                break
            kind = buf[start + 2]
            buf = buf[start + 5 + n:]
            if kind == 0x01:
                os.write(fd, packet(0x81, info))
            elif kind == 0x10:
                stats["frames"] += 1


def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    s.settimeout(2)
    s.connect(SOCKET)
    return s


def hello():
    s = connect()
    s.send(b"\x01")
    reply = s.recv(64)
    s.close()
    return reply


def status(pid, field):
    with open("/proc/%d/status" % pid) as f:
        for line in f:
            if line.startswith(field + ":"):
                return int(line.split()[1])


def open_fds(pid):
    return len(os.listdir("/proc/%d/fd" % pid))


def payload_for(rng, kind, pixels):
    roll = rng.random()
    if kind == 0x10 and roll < 0.6:
        size = pixels
    elif roll < 0.8:
        size = rng.choice([0, 1, 2])
    else:
        size = rng.randrange(300)
    return rng.randbytes(size)


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: socket-fuzz.py <sinty-matrixd> <seconds> <seed> [WIDTHxHEIGHT]")
    daemon, seconds, seed = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
    width, height = (int(v) for v in (sys.argv[4] if len(sys.argv) > 4 else "13x8").split("x"))
    rng = random.Random(seed)
    info = struct.pack("<BBBBH", 1, width, height, 8, 1)

    master, slave = pty.openpty()
    tty.setraw(slave)
    stats = {"frames": 0}
    threading.Thread(target=controller, args=(master, info, stats), daemon=True).start()

    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as profile:
        profile.write("serial=%s\n" % os.ttyname(slave))
    proc = subprocess.Popen([daemon, profile.name])
    deadline = time.time() + 5
    while not os.path.exists(SOCKET) and time.time() < deadline:
        time.sleep(0.05)
    time.sleep(0.5)

    first = hello()
    rss, fds = status(proc.pid, "VmRSS"), open_fds(proc.pid)
    clients, sent, dropped = [], 0, 0
    end = time.time() + seconds
    while time.time() < end and proc.poll() is None:
        op = rng.random()
        if op < 0.05 or not clients:
            try:
                c = connect()
                c.setblocking(False)
                clients.append(c)
            except OSError:
                pass
            continue
        c = rng.choice(clients)
        if op < 0.08:
            clients.remove(c)
            c.close()
            continue
        kind = rng.choice(KINDS) if rng.random() < 0.9 else rng.randrange(256)
        data = b"" if rng.random() < 0.01 else bytes([kind]) + payload_for(rng, kind, width * height)
        try:
            c.send(data)
            sent += 1
        except OSError:
            pass
        try:
            while True:
                if not c.recv(64):
                    clients.remove(c)
                    c.close()
                    dropped += 1
                    break
        except OSError:
            pass
    for c in clients:
        c.close()
    time.sleep(1)
    os.unlink(profile.name)

    if proc.poll() is not None:
        print("sinty-matrixd exited with %d after %d packets" % (proc.returncode, sent))
        return 1
    last = hello()
    print("packets %d, clients dropped by the service %d, frames on the serial link %d"
          % (sent, dropped, stats["frames"]))
    print("rss %d -> %d kB, open fds %d -> %d, hello %s" % (
        rss, status(proc.pid, "VmRSS"), fds, open_fds(proc.pid), "unchanged" if last == first else "CHANGED"))
    proc.terminate()
    proc.wait()
    return 0 if last == first else 1


if __name__ == "__main__":
    sys.exit(main())
