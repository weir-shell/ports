#!/bin/bash
# ring-weir Stage 1 gate: check every .weir, run the acceptance harness,
# then the pty Ctrl+C test. PATH gets the freeze weir binary and the
# docker-compose stub oracle.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/tmp/weir-freeze2/.local/bin:$PWD/test/stubs-path:$PATH"

echo "== weir check =="
for f in src/lifecycle.weir src/config.weir ring.weir test/run.weir; do
  weir check "$f"
  echo "ok - check $f"
done

echo "== acceptance =="
weir test/run.weir

echo "== pty ctrl-c =="
python3 test/pty-ctrl-c.py
