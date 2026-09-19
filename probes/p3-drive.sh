#!/bin/bash
set -u
d=$1
setsid /tmp/weir-freeze2/.local/bin/weir /output/ring-weir/probes/p3.weir "$d" > "$d/out" 2> "$d/err" &
sup=$!
sleep 2
kill -INT $sup
for i in $(seq 1 50); do kill -0 $sup 2>/dev/null || break; sleep 0.2; done
if kill -0 $sup 2>/dev/null; then echo "STILL-ALIVE"; kill -9 $sup; else echo "EXITED"; fi
wait $sup 2>/dev/null; echo "code=$?"
echo "--- log ---"; cat "$d/log" 2>/dev/null || echo no-log
echo "--- err ---"; cat "$d/err"
echo "--- orphans ---"; pgrep -f "sleep 300" || echo none
