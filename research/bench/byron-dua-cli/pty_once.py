#!/usr/bin/env python3
"""Run `dua i --once=<keys> <path>` under a pty that answers cursor-position queries.

Usage: pty_once.py <keys> <path>   -> prints the final screen, rendered with pyte (pip install pyte).
Probe for dua 2.45.0 (Homebrew); fixture paths only.
"""
import fcntl, os, pty, select, struct, sys, termios, time

keys, path = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["LANG"] = "en_US.UTF-8"
    os.execvp("dua", ["dua", "-f", "bytes", "i", f"--once={keys}", path])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
out = b""
deadline = time.time() + 30
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        try:
            done, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if done:
            break
        continue
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if b"\x1b[6n" in chunk:
        os.write(fd, b"\x1b[30;1R")
import pyte
screen = pyte.Screen(120, 30)
stream = pyte.ByteStream(screen)
stream.feed(out)
print("\n".join(line.rstrip() for line in screen.display))
