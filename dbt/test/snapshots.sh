#!/usr/bin/env bash
# Snapshot-validation harness wrapper.
#
# Drives test/snapshots.weir, which runs the PORT's plan against the real
# arquidevio/test-dbt fixture for every one of dbt's 121 golden snapshots and
# reports passed/121 (per profile + total). The weir script does all the work
# (glob the snapshots, extract profile/base/cur, run the port in Diff mode,
# canonical-JSON compare); this wrapper only locates the fixture and the
# script, then execs weir.
#
# Usage: test/snapshots.sh [FIXTURE_DIR]
#   FIXTURE_DIR defaults to /tmp/test-dbt (full-clone required — ranges need
#   history; a shallow clone will fail rev-parse). Clone it with:
#     git clone https://github.com/arquidevio/test-dbt.git /tmp/test-dbt
#
# Exit code: 0 iff all snapshots match; non-zero on any divergence.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="${1:-/tmp/test-dbt}"

if [ ! -d "$fixture/dbt-snapshots" ]; then
  echo "error: no dbt-snapshots/ under '$fixture' — is it the test-dbt fixture?" >&2
  echo "  git clone https://github.com/arquidevio/test-dbt.git /tmp/test-dbt" >&2
  exit 2
fi

exec weir "$here/snapshots.weir" "$fixture"
