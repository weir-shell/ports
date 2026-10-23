# starship → weir

[starship](https://starship.rs)'s prompt, ported to weir, for the weir REPL.
All 113 starship modules, the format-string language, styles and palettes,
reading your existing `~/.config/starship.toml`.

## Use it in the REPL

`~/.config/weir/init.weir` (see [`examples/init.weir`](examples/init.weir)):

```weir
#init

import "./starship/starship.weir" as Ship

let starship st = Ship.prompt st

#session {
    prompt = starship
}
```

Put this directory beside the init file (copy, clone, or symlink — imports
resolve from the init file's real location), or symlink
`examples/init.weir` into place. The config is `$STARSHIP_CONFIG`, else
`~/.config/starship.toml`, re-read on every prompt; a broken file falls back
to the defaults with the error on stderr.

A render takes 10–40 ms in-process (modules run in parallel via `Seq.pmap`;
commands are bounded by `command_timeout`).

## From the command line

```sh
weir bin/starship.weir prompt [--path DIR] [--status N] [--config FILE] [--plain]
weir bin/starship.weir module --name git_status [--path DIR] ...
```

## Layout

| Path | What |
|------|------|
| `starship.weir` | the root: `$all`/PROMPT_ORDER, module dispatch, `prompt` |
| `lib/fmt.weir` | the format language (`[text](style)`, `(conditional)`, `$var`, `${scoped.var}`, escapes, meta `$symbol`) and the ANSI painter (styles, palettes, `prev_fg`/`prev_bg`, `$fill`, nu_ansi_term's escape minimisation) |
| `lib/ctx.weir` | per-prompt context: config load, directory scan, timeout-bounded `exec`, version formatting |
| `lib/config.weir` | config types, **generated** from starship's JSON schema (`gen/types.weir`) |
| `lib/mods/*.weir` | the modules: `lang_a`, `lang_b`, `vcs`, `cloud`, `sys` |
| `test/oracle*.weir` | byte-for-byte comparisons with a real starship binary |

Regenerate the config types after updating the vendored schema
(`.weir/schemas/starship.json`, locked in `.weir/lock.json`):

```sh
weir gen/types.weir
```

## Tests

Every test compares raw bytes, ANSI escapes included, against a reference
starship (1.27.0 in CI):

```sh
weir test/oracle_fmt.weir     --starship /path/to/starship   # 12 format-language cases
weir test/oracle.weir         --starship /path/to/starship   # 10 whole prompts
weir test/oracle_modules.weir --starship /path/to/starship   # 193 module renders
```

`oracle_modules` derives a fixture per language module from the schema's
`detect_*` defaults and runs it with `PATH` set to only `test/fakebin`
(scripts printing each toolchain's real version banner), so every
language module is compared with a version, whatever the machine has installed; plus git scenarios (dirty, stash, detached + tags,
ahead/behind, merge conflict, rebase, inside `.git`), directory truncation /
fish style / substitutions, status and character across exit codes, and
env/file-driven modules (aws, kubernetes, docker_context, conda, package,
custom, env_var, ...) under a fake HOME.

## Differences from starship

Forced by the weir REPL:

- **Multi-line prompts**: a weir prompt is one line, so `Ship.prompt` prints
  the lines above the input line itself and returns the last one. A screen
  redraw (Ctrl+L) repaints only the input line.
- **`right_format`**: there is no right prompt; it is right-aligned on the
  line above the input line (multi-line prompts only).
- **`continuation_prompt`**: weir draws its own.
- **`cmd_duration`** renders nothing: `PromptStatus` carries no duration.
- **`jobs`**: weir has no background jobs (always 0).
- **`character`**: no vi modes; always the insert symbol.
- **`status`**: no pipestatus; a weir error (no exit code) counts as status 1.
- **`claude_*`**: no Claude Code statusline input reaches a REPL prompt.

Not ported / approximated:

- `profiles`, and a top-level `[env_var]` with direct fields (the
  `[env_var.NAME]` tables work).
- `scan_timeout` (the directory listing always completes).
- Cell widths for `$fill` use unicode-width's rules approximately (emoji,
  East Asian wide, VS16, zero-width), not full grapheme segmentation.
- git: `GIT_DIR`/`GIT_WORK_TREE` overrides, repo trust and the WSL
  `windows_starship` path. jj modules each run `jj show` (starship caches one).
- `starship module X` still prints a module set `disabled = true`; here it is
  hidden (the full prompt behaves the same in both).
