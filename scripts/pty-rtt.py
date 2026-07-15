#!/usr/bin/env python3
# Isolate where the peer-relay echo latency lives, below the daemon:
#   kernel : pure kernel PTY per-char echo (ECHO on, ICANON off, sleep child)
#            -> measures the macOS/Linux kernel PTY round-trip alone.
#   cat    : process read+write round-trip (ECHO off, cat child, "x\n")
#            -> measures a child process echoing (proxy for a shell's line editor).
# No daemon, no tokio, no network. Run on macOS and Linux to compare.
import os, pty, time, select, termios, sys

def pct(v, q):
    v = sorted(v); n = len(v)
    return v[min(n - 1, int(round((n - 1) * q)))]

def run(mode, n=500):
    pid, fd = pty.fork()
    if pid == 0:
        if mode == "cat":
            os.execvp("cat", ["cat"])
        else:
            os.execvp("sleep", ["sleep", "3600"])
        os._exit(1)
    a = termios.tcgetattr(fd)
    if mode == "kernel":
        a[3] = (a[3] | termios.ECHO) & ~termios.ICANON   # per-char kernel echo
    else:  # cat
        a[3] = a[3] & ~termios.ECHO                        # only cat echoes
    a[6][termios.VMIN] = 1; a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    time.sleep(0.3)
    while select.select([fd], [], [], 0)[0]:
        os.read(fd, 65536)
    payload = b"x" if mode == "kernel" else b"x\n"
    samples = []
    for i in range(n + 10):
        t0 = time.perf_counter()
        os.write(fd, payload)
        deadline = time.perf_counter() + 1.0
        while time.perf_counter() < deadline:
            if select.select([fd], [], [], 0.2)[0]:
                data = os.read(fd, 65536)
                if b"x" in data:
                    if i >= 10:
                        samples.append((time.perf_counter() - t0) * 1000.0)
                    break
        while select.select([fd], [], [], 0)[0]:
            os.read(fd, 65536)
    os.kill(pid, 9); os.waitpid(pid, 0)
    return samples

if __name__ == "__main__":
    import platform
    print(f"platform: {platform.system()} {platform.release()}")
    for mode in ["kernel", "cat"]:
        s = run(mode)
        print(f"  {mode:8} n={len(s):<4} p50={pct(s,.5):7.3f} p95={pct(s,.95):7.3f} "
              f"p99={pct(s,.99):7.3f} max={max(s):8.3f}  (ms)")
