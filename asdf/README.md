# asdf-weir — Stage 1 proof slice

A port of the pre-Go (bash) asdf version-manager to **weir**, a typed
F#-shaped shell language. Stage 1 covers the read-only spine.

## Layout
- `lib/core.weir` — the `utils.bash` equivalent: a declaration-only weir
  module. Typed `.tool-versions` parsing, version resolution (full asdf
  precedence), install paths, plugin-callback invocation, shim resolution.
- `lib/commands/{where,current,list,which}.weir` — the four read-only
  commands, each a weir script importing `core`.
- `bin/asdf.weir` — the dispatcher slice (routes the four; stubs the rest).
- `test/run.weir` — the harness: asserts stdout+exit per command against a
  fixture tree, cross-checked live against the real bash asdf (the oracle).
- `test/fixtures/` — a plugin with callbacks, installs, a nested
  `.tool-versions` tree, and shims.
- `FINDINGS.md` — the language payoff: what read better, what forced a
  redesign, and every missing/awkward Str/Seq/Path/Env member.

## Run
```
weir test/run.weir            # the test harness (11 cases)
weir bin/asdf.weir where dummy # the dispatcher
```
Set `ASDF_DATA_DIR`/`HOME` to point at a data dir; see `test/run.weir`.
