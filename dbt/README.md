# dbt-weir

Stage-1 port of [arquidevio/dbt](https://gitlab.com/arquidevio) — an F#
monorepo-build toolkit — to **weir**. Ports the read-only plan spine:
the Plan/Range/Profile/Selector/ProjectMetadata model, git-diff change
detection, the `findParentProjectPath` ancestor walk-up +
`findRequiredProjects` discovery pipeline, the `DbtEnv` config, and the
dotnet `*.*sproj` selector. See `FINDINGS.md` for the full report.

## Layout

- `lib/types.weir`    — the model (BuildPlan, Range, Profile, Selector, …)
- `lib/gitdiff.weir`  — change detection (allDirs, dirsFromDiff, change keys)
- `lib/discover.weir` — the walk-up + discovery pipeline
- `lib/dotnet.weir`   — the dotnet selector (`from xml` csproj probing)
- `lib/plan.weir`     — DbtEnv + `Plan.evaluate`
- `lib/stubs.weir`    — stub-with-teach for the un-ported surface
- `bin/dbt.weir`      — CLI entry (the default dotnet plan, evaluated)
- `test/harness.weir` — self-contained fixture + asserts
- `test/oracle.sh`    — cross-check vs the REAL dbt (via `fsy run`)

## Run

```
cd <a monorepo git repo>
DBT_MODE=diff DBT_BASE_COMMIT=<sha> DBT_CURRENT_COMMIT=<sha> weir /path/to/bin/dbt.weir
DBT_MODE=all weir /path/to/bin/dbt.weir
```

## Test

```
weir test/harness.weir      # 14 asserts, self-contained
DBT_SRC=/output/dbt-src test/oracle.sh   # cross-check vs real dbt
```
