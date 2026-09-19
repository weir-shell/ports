import os, pty, signal, sys, time, subprocess, tempfile
d = tempfile.mkdtemp()
pid, fd = pty.fork()
if pid == 0:
    os.execv("/tmp/weir-freeze2/.local/bin/weir", ["weir", "/output/ring-weir/probes/p4.weir", d])
time.sleep(2)
# Ctrl+C via the pty (kernel delivers SIGINT to fg process group)
os.write(fd, b"\x03")
deadline = time.time() + 8
status = None
while time.time() < deadline:
    p, st = os.waitpid(pid, os.WNOHANG)
    if p == pid:
        status = st; break
    time.sleep(0.2)
if status is None:
    print("STILL-ALIVE"); os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
else:
    print("EXITED sig=%d code=%d" % (status & 0x7f, status >> 8))
try:
    print("--- log ---"); print(open(d + "/log").read())
except FileNotFoundError:
    print("no log")
r = subprocess.run(["pgrep", "-f", "sleep 301"], capture_output=True, text=True)
print("--- orphans ---"); print(r.stdout.strip() or "none")
