# SPDX-License-Identifier: GPL-2.0-or-later
"""Press Ctrl-C at a prompt, on a terminal, as a person would.

    ctrl-c.py PROMPT COMMAND [ARG...]

Runs COMMAND on a pseudo-terminal of its own, waits until it writes PROMPT,
sends Ctrl-C and waits five seconds for it to end. Prints "echo on" or
"echo off", the terminal's state then, and exits with COMMAND's status --
128 plus the signal when one killed it -- or 124 when it did not end, as
when the Ctrl-C was ignored; COMMAND is then killed.
"""
import os
import pty
import select
import signal
import sys
import termios
import time

prompt = sys.argv[1].encode()
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])


def read(until: float) -> bytes:
    """What COMMAND writes until then, or until it closes the terminal."""
    got = b""
    while time.time() < until:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                got += os.read(fd, 4096)
            except OSError:
                break
    return got


out = b""
deadline = time.time() + 30
while prompt not in out:
    if time.time() > deadline:
        os.kill(pid, signal.SIGKILL)
        sys.exit(f"no prompt {sys.argv[1]!r} within 30 seconds: {out!r}")
    out += read(time.time() + 0.2)
time.sleep(0.3)                          # the read is waiting by now
os.write(fd, b"\x03")

status = None
until = time.time() + 5
while time.time() < until:
    read(time.time() + 0.1)              # a full terminal would block it
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
        break
print("echo on" if termios.tcgetattr(fd)[3] & termios.ECHO else "echo off")
if status is None:
    os.kill(pid, signal.SIGKILL)
    sys.exit(124)
code = os.waitstatus_to_exitcode(status)        # -N when signal N killed it
sys.exit(code if code >= 0 else 128 - code)
