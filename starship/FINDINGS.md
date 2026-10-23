# FINDINGS — porting starship (Rust) to weir

Scope: the whole prompt — all 113 modules, the format-string language,
style/palette painting, `$all` ordering, custom and env_var modules, config
loading from `starship.toml` — as a weir REPL prompt function. Checked clean
(zero warnings) on weir v0.0.76.

Verdict: **go**. The port is byte-identical to starship 1.27.0 on every
oracle case: 12 format-language cases, 10 whole prompts and 193 module
renders, ANSI escapes included. About 5.1k lines of hand-written weir against
about 19.6k lines of non-test Rust (modules, formatter, configs, context,
print). The config types are generated, not written.

---

## (a) What ported well

1. **The config boundary was free.** `weir add schema` vendored starship's
   own `config-schema.json`, and `weir gen types` turned it into 114 record
   types (`lib/config.weir`). After that, `File.read p |> from toml Starship`
   reads a real user config. Every field is `Option`, so each module's
   defaults sit at the read site
   (`get (fun c -> c.symbol) "🦀 "`). `from toml` ignores unknown keys, which
   is the leniency starship has.
2. **Row-generic helpers replace starship's per-module boilerplate.** About
   60 language modules share one `lang` function. It accepts any
   `<Lang>Config` record carrying `format`/`symbol`/`detect_*` fields,
   because weir infers field access on a parameter row-generically. Each
   module is its defaults plus one version command.
3. **Concurrency.** starship's `par_iter` over modules is `Seq.pmap`.
   `exec_cmd`'s timeout is a `Seq.pfirst` race between the command and a
   sleep; the loser is tree-killed, so a hung `kubectl` can't stall the
   prompt. Total render time is 10–40 ms.
4. **Typed foreign formats.** `from json` (package.json, azureProfile,
   docker config), `from toml` (Cargo.toml, pyproject, jj output),
   `from xml` (pom.xml) and `from yaml` (kubeconfig, Pulumi.yaml) each take
   an anonymous shape inline.
5. **The oracle method.** Downloading the release binary and diffing bytes
   caught real divergences that reading the Rust alone would not have:
   - gix counts files inside untracked directories;
   - nu_ansi_term writes bg before fg and merges same-style runs;
   - an invalid style makes the segment inherit the enclosing group's style;
   - an empty `[]()` group paints, but one that only rendered to nothing
     does not.

## (b) What forced a redesign

1. **No recursion → the format parser is a fold.** starship parses with
   pest into a tree and renders recursively. Here a regex tokenizer feeds
   one `Seq.fold` over an explicit frame stack. Each frame (root, `[group]`,
   `(conditional)`) collects segments and a "has a non-empty variable"
   flag, and is resolved when its closer arrives. Meta variables (`$symbol`
   is itself a format) use two calls of the same non-recursive renderer
   instead of recursion.
2. **A prompt is one line.** `PromptStatus -> string` output has newlines
   turned into spaces, so starship's two-line default prints its upper
   lines from inside the prompt function. That works because the REPL
   calls the function once per entry and redraws only its own line, but a
   Ctrl+L loses them.
3. **No memoisation.** starship computes variables lazily and caches
   command output per prompt. Here a value two variables share is bound
   up front, and jj modules each spawn `jj show`.

## (c) Gaps in weir (by impact)

1. **`PromptStatus` has only `ok`/`exit`.** `cmd_duration` can't be built
   (the entry's duration is unknown), and there is no pipestatus. Adding
   `duration: Duration` would close the first.
2. **Same-named types in two imported modules collide** (`LangDefaults` in
   two mods files broke the root's check). Types are qualified at use
   (`F.Seg`), so the collision is surprising.
3. **Checker/assembly rough edges hit repeatedly:**
   - a multi-line list or record literal inside a lambda body that is
     followed by more lines gives "sits left of the lambda '('";
   - a trailing `&&` does not continue a line;
   - a `match` over a tuple of Options covering every case still demands
     `_`;
   - `$(rustc -Vv | complete)` (a literal head) checks alone but fails when
     checked through an importer;
   - `Option<Yaml> == …` is refused because Yaml can hold a float.
4. **`Path.home ()` ignores a `within env HOME=…` overlay**, while
   `Env.get "HOME"` sees it. A test harness with a fake HOME silently read
   the real one.
5. **YAML subset:** populated flow collections (`args: ["a"]`) refuse the
   *whole* document, even in keys the target type doesn't declare, so a
   kubeconfig with an exec plugin shows no context. `from yaml` also
   doesn't split a joined string (`Str.split "\n"` first), whereas
   json/toml do.
6. **`weir gen types` drafts the first `anyOf` variant.** Five fields that
   are string-or-array (`python_binary`, `custom.shell`, ...) would have
   refused valid configs. `gen/types.weir` regenerates and widens them to
   `Yaml`.
7. **Missing members** (each hand-rolled or shelled out):
   - display/grapheme width;
   - regex replace with `$1`/`$name` expansion (.NET also rejects
     `(?P<name>)`);
   - SHA-1 (`sha1sum` for aws SSO cache keys and pulumi);
   - an INI reader;
   - a PATH lookup (`which`);
   - bitwise operators (localip's route mask).
8. **Strings have no `\u`/`\e` escape**: ESC is
   `Bytes.fromHex "1b" |> Str.fromUtf8`.
9. **Vendoring:** `weir add module` vendors one file. A multi-file module
   like this one is copied or symlinked as a directory.
10. `def` is a reserved word with no meaning.

## Stage 2

- `cmd_duration` and pipestatus, once `PromptStatus` grows.
- A cached `jj show`/git status shared by a VCS family (a per-prompt record
  computed once in `Vcs`).
- `profiles` and top-level `[env_var]` (needs a `Yaml`-typed `env_var` and
  manual dispatch).
