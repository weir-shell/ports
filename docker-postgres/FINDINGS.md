# Findings — docker-postgres-entrypoint

The engineering account: what `exec` closed, what read better, and the
friction met porting `docker-entrypoint.sh`.

## What this port drove: `exec` (process replacement)

This port is the *reason* `exec` exists. The entrypoint pattern is
universal — set the stage, then `exec "$@"` so the real process is PID 1 —
and weir could not express the second half. Before `exec`, the only handoff
was a spawn (`^$cmd $@args` as a command statement), which:

- **left weir as PID 1**, so Docker's `SIGTERM` on `docker stop` hit weir,
  not postgres — no graceful shutdown, a 10s SIGKILL timeout, and a real
  risk of an unclean data dir;
- would have needed a **hand-written signal-forwarding trap** and a reaping
  loop to even approximate what the kernel gives you for free with execve.

`cmd | exec` replaces the image: postgres *becomes* the process, keeps
weir's pid, and Docker signals it directly. The bash original's `gosu` +
`trap` + `exec` sequence collapses to one line, and it is the injection-safe
dynamic-head spelling (`^$cmd $@cmdArgs | exec`), not a `sh -c` string.

The diverging type falls out correctly: `exec` never returns, so `print
"unreached"` after it is dead code the checker knows is unreachable, and a
bare `cmd | exec` statement is legal (no "computes a value and discards it"
— the discard gate exempts it like `fail`/`exit`).

## What read better than the bash

- **Typed config, one place.** The `POSTGRES_*` contract is three
  `Env.get … |> Option.defaultValue` bindings with the upstream defaults,
  versus the bash's scattered `: "${POSTGRES_USER:=postgres}"` parameter
  expansions. `POSTGRES_DB` defaulting to `POSTGRES_USER` is one line that
  reads as what it is.
- **The bootstrap is a named function**, called once behind `if firstRun`,
  instead of a 40-line `if [ -z "$DATABASE_ALREADY_EXISTS" ]` block. The
  throwaway-server sequence (`pg_ctl start` → `createdb` → `pg_ctl -m fast
  stop`) is the same three steps, but each `| orFail "…"` names its own
  failure instead of relying on `set -e`.
- **No `set -e` footguns.** Every command is a reifier: `| orFail`
  raises with a message on nonzero, so a failed `initdb` stops the
  entrypoint loudly rather than silently continuing to a broken `exec`.

## What this port also fixed: top-level `if/else`

The first cut of the entrypoint hit a real parser gap: a statement-position
`if … then <block> else <block>` at the *top level* did not parse
(`'else' is a keyword`, backtrack) — it worked only inside a
function/expression body. The root was the assembler: a col-0 `if` is its
own logical statement, and the dedented `else` was treated as a new
statement, so the parser hit a stray keyword. A col-0 `else`/`elif` now
continues its `if` (the same col-0 continuation as a dedented
`|`/`until`/`always`), so the natural entrypoint shape

```weir
if firstRun then
    ...bootstrap...
else
    print "already initialized"
```

reads exactly as it should. (Fixed in v0.0.50, alongside `exec`.)

## Stage 2

- The `gosu` step-down (run initdb/bootstrap as the `postgres` user when
  started as root) — weir needs a `setuid`/`su-exec` story, or the image
  runs as the postgres user throughout.
- `docker-entrypoint-initdb.d/` script execution (`*.sh`/`*.sql`/`*.sql.gz`
  on first run) — a `Path.glob` + per-extension dispatch.
- The `--` argument handling and the `_is_sourced` re-exec guard.
