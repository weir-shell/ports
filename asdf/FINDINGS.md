# FINDINGS — porting asdf (bash) to weir, Stage 1

A language stress test. Scope: the read-only spine of asdf —
`.tool-versions` parsing, version resolution, install paths, plugin
callback invocation, shim resolution, and the four commands `where`,
`current`, `list`, `which`, plus a dispatcher. Every weir file
`weir check`s clean; the harness runs 11 cases, each **cross-checked
live against the real bash asdf** (the oracle runs in this container).

Verdict up front: **go**. The core read *dramatically* better in weir,
the plugin model is a natural fit, and the redesigns weir forced were
improvements, not workarounds. Friction concentrated in a handful of
missing `Str`/`Seq` members and one parser edge around statement-`if`.

---

## (a) What ported cleanly and read BETTER than the bash

### 1. `.tool-versions` as a TYPED value — the thesis, confirmed

Bash parses per-plugin, per-call, grep+sed (`parse_asdf_version_file`):

```bash
version=$(strip_tool_version_comments "$file_path" | grep "^${plugin_name} " | sed -e "s/^${plugin_name} //")
```

and `strip_tool_version_comments` is a 3-step sed nobody reads at a
glance: `sed '/^[[:blank:]]*#/d;s/#.*//;s/[[:blank:]]*$//'`.

In weir this is one pipeline over `seq<string>` yielding
`seq<ToolVersions>` — the whole file parsed once, all plugins, as data:

```weir
let parseToolVersions lines =
    lines
    |> stripComments
    |> Seq.choose (fun l ->
        match l |> Str.fields |> Seq.force with
        | [] -> None
        | name :: vers -> Some { plugin = name; versions = vers })
```

`stripComments` is the sed made legible (`Str.trySplitOnce "#"`,
`Str.trimEnd`, `Seq.where (<> "")`), marked `pure` — the checker *proves*
it touches nothing. Bash reparses per plugin queried; the weir value is
parsed once, asked many times. `Str.fields` (awk-default whitespace
split, no empty pieces) replaced the `IFS=' ' read -r -a` array dance.
Line count: two bash functions + per-plugin regrep ~20 lines returning a
string; the weir ~14 lines returning `seq<{ plugin; versions }>`.

### 2. `version|path` string -> a typed record

asdf joins two facts with a pipe because bash has one return channel:

```bash
printf "%s\n" "$asdf_version|$search_path/$file_name"   # callers: cut -d '|' -f 1 / -f 2
```

Every caller re-splits with `cut -d '|'`. In weir this is
`Resolved { versions; source; found }` — the `|`-join and every `cut`
undoing it vanish. Four ported call sites just read `.versions`/`.source`.

### 3. The `ref:`/`path:`/`system` dispatch -> a union

Bash does `IFS=':' read -r -a version_info` and indexes `[0]`/`[1]` in
FIVE functions, each re-splitting. weir has one `VersionSpec` union and
one `specOf` built on `Str.trySplitOnce ":"` (keeps the tail intact — a
`path:/a:b` value would break a naive split). Matching the union is
exhaustive-checked; bash silently falls through `else` on any surprise.

### 4. Plugins-as-programs — asdf's model IS weir's model

The headline architectural win. asdf runs callbacks (`list-all`,
`list-bin-paths`, …) as external programs with `ASDF_*` env set — EXCEPT
`exec-env`, which it *sources* (`. "${plugin_path}/bin/exec-env"`), a
plugin-injection surface. weir has no `source`: a callback is a child
with an env overlay. Porting `list_plugin_bin_paths`:

```weir
let env = Env.ofPairs [
    ("ASDF_INSTALL_TYPE", itype)
    ("ASDF_INSTALL_VERSION", iver)
    ("ASDF_INSTALL_PATH", ipath)
]
runCallback listBinPaths env [] |> Seq.collect Str.fields
```

Sets exactly those three, inherits the rest, parent untouched, callback
can't reach weir's state. The harness proves the callback genuinely runs:
moving an executable into the callback-declared `sub/bin` and re-running
`which` still finds it, matching the oracle.

### 5. Shim markers via the `Regex` pattern

`shim_plugin_versions` greps+seds `# asdf-plugin: X Y`. weir extracts them
typed in one `Seq.choose` arm:
`| Regex @"^# asdf-plugin: (\S+) (.+)$" (p, v) -> Some (p, v)` — yielding
`seq<string * string>`, not text to re-split.

### 6. The directory walk-up without a `while` loop

asdf hand-rolls `while [ "$search_path" != "/" ]; do … search_path=$(dirname …)`.
weir has no `while`; `Graph.reach` with a `parentOf` neighbor function
produces the ancestor chain breadth-first (parent after child), bounded
by construction. It reads as *what it is* — "the ancestor directories".
A pleasant surprise: a graph builtin cleanly solved a shell loop idiom.

---

## (b) What FORCED a redesign, and the weir answer

### 1. Dynamic command heads -> `sh -c` with a quoted path

The one forced fallback. asdf invokes a callback whose path is a runtime
value (`"${plugin_path}/bin/list-all"`). weir command heads must be
LITERAL, resolved at check time — `$(cb)` on a binding is a parse error
(`Expecting: '$@'`). So callbacks go through `sh -c`, path single-quoted:

```weir
let runCallback script env args =
    let quoted = args |> Seq.map (fun a -> $"'{a}'") |> Str.join " "
    $env(sh -c $"'{script}' {quoted}")
```

Correct and safe (values interpolated, no word-splitting), but the
byte-exact argv discipline weir gives literal commands is lost for the
one program whose identity is data. A **checked dynamic-exec primitive**
(`Proc.run pathExpr argv env` returning the `| complete` record) would
keep argv typed end-to-end. The single most impactful gap for this
domain. (Repeated in (c).)

### 2. The `list` star — faithfully porting a bash *bug*

`display_installed_versions` sets `current_version=$(cut -d '|' -f 1 …)` —
the WHOLE space-joined version string ("1.0.0 2.0.0"), then compares each
install against it. With two set versions it matches nothing, so nothing
stars; only a single-version preset ever stars. My first weir cut used
the *first* version (the sensible reading) and diverged from the oracle.
The typed port made the divergence obvious; I reproduced the accident
deliberately (`… |> _.versions |> Str.join " "`). Finding: the typed
rewrite surfaces latent bash bugs — you must *choose* to keep them.

### 3. `exit`-terminated branches -> early-return, not `if/else`

A statement `if c then <unit>` is a COMPLETE statement in weir, so a
following `elif`/`else` at column 0 is orphaned (parse error:
`'else' is a keyword`). asdf's commands are full of
`if …; then …; exit 0; elif …`. The weir idiom is guard-and-fall-through:
each terminal branch does its `exit`, the next case is the following
top-level statement. Reads *better* for dispatch (it's how the four
commands are structured), but a real reshape from the bash flow.

### 4. `find_versions` precedence, made explicit

The precedence (env var -> walk up -> `$HOME` -> default-filename
fallback) is spread across three bash functions with early `return 0`s.
weir's `findVersions` is one function: `match versionFromEnv`, then a
`Seq.tryPick` over candidate files (first hit wins — `tryPick` *is*
"first non-empty return"), then the fallback. `Seq.tryPick` replacing
loop-with-early-return was the cleanest single substitution in the port.

---

## (c) MISSING or AWKWARD — the concrete gap list

Each item is a place I reached for something absent, with the bash ported.

1. **`Str.padRight`/`padLeft` (or a width primitive).**
   `command-current.bash` uses `printf "%-15s %-15s %-10s\n"`. No width
   member, so I hand-rolled:
   ```weir
   let padRight w s =
       let n = w - Str.length s
       if n <= 0 then s else s + (Seq.replicate n " " |> Str.join "")
   ```
   Every tabular CLI port (asdf's `current`, `plugin list`,
   `latest --all`) needs this. `Str.padRight : int -> string -> string`
   would drop a helper from each.

2. **`Str.replicate n s` (string repeat).** Absent — went through
   `Seq.replicate n " " |> Str.join ""`. The building block for (1) and
   for any `printf`-padding or rule-of-dashes output.

3. **`seq` equality.** `seq<string> == seq<string>` is a check error
   (`'==' is not defined for seq<string>`). Comparing command output to
   expected is THE core test-harness op; I wrote
   `let seqEq a b = (a |> Str.join "\n") == (b |> Str.join "\n")`. A
   `Seq.equal` (elementwise, equatable elements) is the honest spelling —
   the join is lossy if elements contain the separator. Bit twice.

4. **Capturing under an env overlay with `| complete`.** The `$e(cmd)`
   capture sigil does NOT compose with a reifier: `$e(weir …) | complete`
   is a parse error (`'complete' must directly follow a single external
   command segment`). Workaround: `within env e` + `let r = cmd |
   complete` inside — two lines for the natural one-liner (output AND exit
   code under an overlay). A reifier accepting the sigil form, or
   `Env.run e cmd`, would close it.

5. **Dynamic executable resolution (`command -v` / PATH search).**
   `with_shim_executable` sets `PATH=$exec_paths:$PATH` then
   `command -v $shim`. No PATH-search primitive and no dynamic head, so I
   re-implemented `command -v`: join the shim name onto each exec dir,
   `File.exists` + `File.mode |> contains "x"`. Faithful for asdf, but a
   `Proc.which name (paths: seq<string>)` would be the direct port.

6. **`File.mode` exec test is stringly.** To check executability:
   `File.mode p |> Option.map (Str.contains "x")`. A `File.isExecutable p
   : bool` would be clearer and platform-correct; substring-matching
   `"rwxr-xr-x"` is a smell, and `None` on Windows forced a default.

7. **Qualified union cases in patterns — a teaching gap.** `| Core.System
   ->` is a parse error; the fix is bare `| System ->` (scrutinee type
   resolves the imported case). Documented and correct, but the error
   didn't point at "drop the qualifier". Worth a targeted message —
   imported unions are common in a multi-module port.

8. **`let`-ending-in-`exit` infers a generic return.** The dispatcher's
   `runCmd` ending in `exit code` inferred a polymorphic `'a` return, so
   using it in a match arm was a *discard* error. Reshaped to return the
   `int` code, `exit` at the call site (`exit (runCmd "where")`).
   Reasonable once understood; surprising on a function that "obviously
   never returns".

None blocked the port. 1–4 are small stdlib additions; 5–6 domain-shaped
convenience; 7–8 diagnostics polish.

---

## (d) Stage 2+ scope estimate

**Cheap (reuse the Stage-1 core almost as-is):**
- `latest` / `list-all` — `Core.listAll` already runs the callback;
  `latest` is filter+sort over it. ~0.5 day incl. `latest-stable`.
- `plugin list` / `plugin list-all` — read-only dir + git-remote reads;
  `--urls/--refs` needs `git --git-dir …` (literal head, no fallback).
  ~0.5 day.
- `env` / `info` / `version` — thin. ~0.5 day total.

**Moderate (mutation, weir-native `File`/`Dir`/`plan`):**
- `global` / `local` / `shell` — rewrite `.tool-versions`. Bash is
  `sed -e "s|^plugin .*$|plugin versions|"` + temp-file dance; weir is
  parse -> update typed rows -> text -> `File.write`, and `plan`/`apply`
  gives a real dry-run for free. The typed core pays off hardest here.
  ~1–1.5 days.
- `uninstall` / `reshim` — `Dir.deleteAll` + shim regeneration. ~1.5 days.

**Expensive (machinery; where the dynamic-exec gap bites):**
- `install` — download/install callbacks, concurrency (`Seq.pmap` fits
  asdf's `&`+`wait`), env transforms, and `exec-env` SOURCING (weir's
  no-source stance forces a redesign: run `exec-env` as a child that
  prints its env delta, then overlay — cleaner but a real rethink).
  ~3–4 days.
- `exec` / shim execution — the dynamic-head problem at its worst: `exec`
  an arbitrary resolved binary with a computed argv+env. Without a
  checked dynamic-exec primitive it's all `sh -c` string-building. Gap
  #1/#5 gates this. ~3 days, or ~1.5 with a `Proc.exec` primitive.
- `plugin add` / `plugin update` — git clone/fetch + `post-plugin-*`
  hooks + short-name repo sync. The `asdf_run_hook` `eval` becomes a
  child `sh -c`. ~2 days.

**Legacy version files** (`.ruby-version` via `parse_legacy_version_file`
/ `list-legacy-filenames`) — stubbed in Stage 1; a per-dir legacy branch
in `findVersions` (another callback + a config read). ~0.5 day.

**Total remaining ~24 commands, ~14–18 dev-days**, front-loaded on
`install`/`exec`. The highest-leverage language change for the rest is a
**checked dynamic-exec primitive** (gaps #1/#5): it converts
`install`/`exec` from string-built `sh -c` back into weir's typed-argv
discipline and roughly halves those estimates.
