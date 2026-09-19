#!/bin/bash
set -u
d=$1
sig=${2:-INT}
setsid /tmp/weir-freeze2/.local/bin/weir /output/ring-weir/probes/p4.weir "$d" > "$d/out" 2> "$d/err" &
sup=$!
sleep 2
kill -$sig $sup
for i in $(seq 1 50); do kill -0 $sup 2>/dev/null || break; sleep 0.2; done
if kill -0 $sup 2>/dev/null; then echo "STILL-ALIVE"; kill -9 $sup; else echo "EXITED"; fi
wait $sup 2>/dev/null; echo "code=$?"
echo "--- log ---"; cat "$d/log" 2>/dev/null
echo "--- err ---"; cat "$d/err" 2>/dev/null
echo "--- orphans ---"; pgrep -f "sleep 301" || echo none
