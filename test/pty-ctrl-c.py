#!/usr/bin/env python3
"""Ctrl+C at a real pty: the supervisor must tear children down (STOPPED,
DESTROYED per runnable), report final states, and die by SIGINT.
(kill -INT from outside a tty is a no-op for weir - measured; SIGTERM and
tty Ctrl+C are the unwind paths. See FINDINGS.)"""
import os, pty, signal, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEIR = "/tmp/weir-freeze2/.local/bin/weir"
sd = tempfile.mkdtemp()

pid, fd = pty.fork()
if pid == 0:
    os.chdir(ROOT)
    os.execv(WEIR, [WEIR, "ring.weir", "run", "-w", "test/fixtures/demo.yaml",
                    "--run-for", "120s", "--health-period", "500ms",
                    "--state-dir", sd])

def events():
    try:
        return open(os.path.join(sd, "events.log")).read()
    except FileNotFoundError:
        return ""

deadline = time.time() + 20
while time.time() < deadline:
    e = events()
    if e.count("RUNNABLE_HEALTHY") >= 2:
        break
    time.sleep(0.2)
else:
    sys.exit("FAIL: runnables never got healthy")

os.write(fd, b"\x03")  # Ctrl+C

status = None
deadline = time.time() + 15
while time.time() < deadline:
    p, st = os.waitpid(pid, os.WNOHANG)
    if p == pid:
        status = st
        break
    time.sleep(0.2)
if status is None:
    os.kill(pid, signal.SIGKILL)
    sys.exit("FAIL: supervisor ignored Ctrl+C")

if not (os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGINT):
    sys.exit(f"FAIL: expected death by SIGINT, got status {status}")
print("ok - supervisor died by SIGINT after teardown")

e = events()
for ident in ("steady", "flaky"):
    for ev in ("RUNNABLE_STOPPED", "RUNNABLE_DESTROYED"):
        if f"{ident} {ev}" not in e:
            sys.exit(f"FAIL: missing {ident} {ev} after Ctrl+C")
print("ok - both runnables stopped and destroyed")

for ident in ("steady", "flaky"):
    st = open(os.path.join(sd, f"state-{ident}")).read().strip()
    if st != "Zero":
        sys.exit(f"FAIL: {ident} final state {st}, expected Zero")
print("ok - final states Zero")

time.sleep(0.5)
r = subprocess.run(["pgrep", "-f", "ring" + "-stub"], capture_output=True)
if r.returncode != 1:
    sys.exit(f"FAIL: orphans remain: {r.stdout}")
print("ok - no orphans")
print("PTY CTRL+C GREEN")
