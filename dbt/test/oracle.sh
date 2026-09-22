#!/usr/bin/env bash
# Oracle cross-check: run the REAL dbt (via fsy) and the weir port on the
# SAME fixture repo, in Diff and All modes, and diff their reports.
#
# Requires: fsy (dotnet global tool) with network access for paket
# restore, and a copy of dbt-src with an oracle driver (fsx/oracle.fsx).
# Falls back gracefully (exit 2) if the oracle toolchain is unavailable.
set -euo pipefail

DBT_SRC="${DBT_SRC:-/output/dbt-src}"
PORT_BIN="${PORT_BIN:-/output/dbt-weir/bin/dbt.weir}"
ORACLE="$DBT_SRC/fsx/oracle.fsx"

if ! command -v fsy >/dev/null 2>&1; then
  echo "SKIP: fsy not on PATH — oracle unavailable" >&2
  exit 2
fi
if [[ ! -f "$ORACLE" ]]; then
  echo "SKIP: oracle driver $ORACLE missing" >&2
  exit 2
fi

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/a" "$FIX/b" "$FIX/c/nested"
cd "$FIX"
git init -q; git config user.name t; git config user.email t@t
printf '<Project><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>\n' > a/x.csproj
printf '<Project><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>\n' > b/y.csproj
printf '<Project><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>\n' > c/nested/z.fsproj
echo hello > a/Program.cs; echo world > c/nested/Lib.fs; echo readme > README.md
git add -A; git commit -qm "init: [CHANGE-KEY-base] baseline"
BASE=$(git rev-parse HEAD)
echo changed >> a/Program.cs; echo touch >> c/nested/Lib.fs
git add -A; git commit -qm "feat: a and c [CHANGE-KEY-feat1] and [CHANGE-KEY-feat2]"
CUR=$(git rev-parse HEAD)

run_oracle() { DBT_LOG_LEVEL=warn fsy run "$ORACLE" 2>/dev/null | grep -E '^(PROJECT|KEY|DIR)'; }
run_port()   { weir "$PORT_BIN" 2>/dev/null | grep -E '^(PROJECT|KEY|DIR)'; }

fail=0
for MODE in diff all; do
  echo "== MODE=$MODE =="
  if [[ "$MODE" == diff ]]; then
    export DBT_MODE=diff DBT_BASE_COMMIT="$BASE" DBT_CURRENT_COMMIT="$CUR" DBT_PROFILE=default
  else
    export DBT_MODE=all DBT_PROFILE=default
    unset DBT_BASE_COMMIT DBT_CURRENT_COMMIT
  fi
  run_oracle | sort > "$FIX/oracle.txt"
  run_port   | sort > "$FIX/port.txt"
  if diff -u "$FIX/oracle.txt" "$FIX/port.txt"; then
    echo "MATCH ($MODE)"
  else
    echo "MISMATCH ($MODE)"; fail=1
  fi
done

if [[ $fail -eq 0 ]]; then echo "ORACLE CROSS-CHECK: ALL MATCH"; else echo "ORACLE CROSS-CHECK: FAILED"; exit 1; fi
