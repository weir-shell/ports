# FINDINGS — porting dbt (F#) to weir, Stage 1: the read-only plan spine

Scope: dbt's Plan/Range/Profile/Selector/ProjectMetadata model
(types.fsx); git-diff change detection (diff between refs → changed dirs
`Map<dir, files>`; `allDirs`; commit-message change-key scraping via
`ParseCommitMessage`); the discovery pipeline (`findParentProjectPath`
ancestor walk-up + `findRequiredProjects` leaf-expand/exclude/ignore/
required filters + `ProjectMetadata` construction + sort); the `DbtEnv`
config (DBT_MODE Diff|All, DBT_PROFILE, base/current commit); and ONE
concrete selector — the dotnet `*.*sproj` generic. Stubbed-with-teach:
bicep/kustomize/node selectors, the dotnet dependency-graph leaf
expansion, CI last-success-sha, deploy-spec/output, and snapshot.
Replaced (not ported): the `plan {}`/`profile {}`/`selector {}`
computation-expression DSL.

Everything `weir check`s clean (zero warnings) on `weir
0.0.0-dev+27eba9d` (post-v0.0.47). The harness runs 14 filesystem/
exit-code asserts over a self-built fixture git repo in Diff, All, and
empty-diff modes, all green. **Oracle status: the REAL dbt RAN** — `fsy
run` restores paket in-process (sidestepping the read-only `~/.fsharp`
that blocks `fsy install-fsx-extensions`), so `test/oracle.sh` drives
the actual `Plan.evaluate` and the weir port over the SAME fixture and
diffs their reports: **byte-identical MATCH in both modes.**

Verdict up front: **go**. The model, the change-detection, the ancestor
walk-up, and the discovery pipeline all port cleanly and read at least as
well as the F#. The one real architectural collision — dbt's `plan`
value vs weir's `plan` keyword — is a naming problem, not a semantic
one, and disambiguates cleanly. The genuine loss is the CE-DSL sugar,
which becomes plain records (net: more honest, less terse). The concrete
gaps are small and named below (headline: no glob-exclude combinator; no
`[<Default>]` on `Env.load` enum fields).

---

## (a) What ported cleanly and read at least as WELL as the F#

### 1. The model is a straight record/union transcription

types.fsx's `Plan`/`Range`/`Profile`/`ProjectMetadata`/`Selector`/
`PlanOutput`/`ChangeSetRange`/`DiffResult` map 1:1 to weir records, and
the two behaviour-carrying unions (`BaseCommitStrategy`, `Mode`) to weir
unions. The F#'s `static member Default` values are gone — weir has no
static members, and the defaults live at the one construction site
(bin/dbt.weir) as an ordinary record literal, which is where a reader
looks anyway.

### 2. Records with FUNCTION FIELDS port verbatim — the pleasant surprise

`Selector` carries four function fields —
`isRequired: string -> bool`, `isIgnored: string -> bool`,
`projectId: ProjectMetadata -> string`,
`expandLeafs: LeafContext -> seq<string>` (types.fsx:60-63). weir's
function-type-in-a-field law ([D:function-types]) accepts every one, and
`Dotnet.generic` constructs them as plain lambdas
(`isIgnored = isTest`, `expandLeafs = fun ctx -> [ctx.projectPath]`). The
only consequence weir's laws impose: a function-bearing record cannot be
`show`n/`to json`'d/compared — so the port keeps **data** (`ProjectMetadata`,
serialisable, sortable) and **behaviour** (`Selector`) as separate types,
which dbt already does. No friction; the split was already right.

### 3. The ancestor walk-up IS `Graph.reach` (the third port to find this)

dbt's `findParentProjectPath` (plan.fsx:31-55) is a hand-written
`let rec findParentProj` climbing `Directory.GetParent` until a dir
holds a matching project file or it hits `rootDir`. In weir the parent
chain is `Graph.reach (fun d -> d) parentOf startDir` (a linear chain,
breadth-first = nearest-first), then `Seq.tryPick` the first ancestor
with matches (discover.weir `ancestors`/`findParentProjects`). No
recursion, cycle-safe by construction — the same "a graph builtin keeps
eating hand-rolled walkers" the asdf and ring ports reported. The
harness's deep-change case (a file under `a/deep/sub` with no project of
its own resolving to `a/x.csproj`) exercises exactly this and matches the
oracle.

### 4. The discovery pipeline is one Seq pipeline

`findRequiredProjects` (plan.fsx:57-140) — a 6-stage F# pipeline
(walk-up → distinct → expand leafs → exclude filter → ignore filter →
warn-and-drop not-required → metadata map → sort) — is a single weir
`|>` chain (discover.weir:findRequiredProjects). `Seq.collect`,
`Seq.distinct`, `Seq.where`, `Seq.map`, `Seq.sortBy` line up with dbt's
`Seq.collect`/`Seq.distinct`/`Seq.filter`/`Seq.map`/`Seq.sortBy`
one-for-one. The warn-on-not-required side effect (plan.fsx:108-116) is a
`Seq.iter` over the complement, unchanged in intent.

### 5. `from xml` beats XPath for the dotnet selector

dbt's `DotnetProject.hasProperty` (project.fsx:11-16) builds an
`XPathDocument` and runs `/Project/PropertyGroup[*]/{prop}[text()='true']`.
The weir port declares `type Project = { [<Elem "PropertyGroup">] groups:
seq<PropertyGroup> }` and reads `File.read p |> from xml Project`, then
`Seq.exists (fun g -> g.IsTestProject == Some "true")`. Verified against
the fixture's real `b/y.csproj` — `isTest` returns true, `a/x.csproj`
false. The csproj IS the typed boundary; no XPath string, no navigator.

### 6. `Env.load` for `DbtEnv`

dbt's `DbtEnv` (plan.fsx:146-155) is a `readEnv<DbtEnv>` record with
`[<Env.Default>]` attributes. weir's `Env.load DbtEnv` fills the same
record; `[<Default "default">]` on `DBT_PROFILE` and Option fields
reading absent-as-None both work. (The enum-default wrinkle is (c)#2.)

### 7. Honest line count

Ported surface — dbt F#: types.fsx 119 + plan.fsx 277 + git-diff.fsx 103
+ dotnet/project.fsx 59 = 558 lines of MODEL+PIPELINE, **plus** the
411-line CE-DSL builder that the port does not reproduce at all. weir
port: types 105 + gitdiff 112 + discover 124 + dotnet 73 + plan 124 =
538 lines, with NO builder equivalent needed. So the port is ~40% of the
F# by dropping the DSL machinery outright — the config is just a value.

---

## (b) What FORCED a redesign, and the weir answer

### 1. The `plan` NAME COLLISION — dbt's value vs weir's keyword

dbt's headline is a `Plan` *value* evaluated by `Plan.evaluate`:

```fsharp
plan { range { ... }; profile { selector { pattern "*.fsx" } } }
    |> Plan.evaluate
```

weir has a `plan` *keyword* — the dry-run mutation-capture head
([D:plan-apply]): `plan` + a block yields a `Plan` value whose FS/HTTP
mutations were captured instead of performed. **These are unrelated
concepts sharing a name.** They disambiguate cleanly because they never
occupy the same slot: weir's `plan` is a statement head (lowercase
keyword), dbt's is a data type. The port names the config value
`BuildPlan` (types.weir) and keeps the evaluator as `Plan.evaluate` —
but `Plan` there is a MODULE name (lib/plan.weir), not weir's keyword,
so the two never clash at the source level. One real consequence: a
script importing the module cannot alias it `as Plan` (weir refuses —
"the name 'Plan' is already a module in scope"; the module self-declares
`Plan`), so bin/dbt.weir imports it `as Dbt`. That is the whole cost.

**Could weir's own `plan` MODEL dbt's evaluate?** No, and the reason is
instructive. weir's `plan` captures *weir-native mutations* of a block
into an inspectable, diffable, applyable value — it is dry-run-a-write.
dbt's `evaluate` READS git and the filesystem and RETURNS a report
(required projects, change keys); it performs no mutation to capture. If
anything, dbt's evaluate is closer to a `readonly` block (ambient reads,
no external mutation) than to `plan`. So the collision is purely lexical:
same four letters, opposite verbs (capture-a-write vs compute-from-reads).
This is the most interesting finding in the port and it cost nothing to
resolve — but a reader coming from weir's `plan` keyword will absolutely
be surprised, which is worth the paragraph.

### 2. The CE-DSL → plain records — the biggest STRUCTURAL redesign

dbt's `plan {}`/`profile {}`/`selector {}` builders (plan.builder.fsx,
411 lines) are F# computation expressions with `[<CustomOperation>]`
members (`pattern`, `exclude`, `required_when`, `extend`, …), facet
lists, reverse-order accumulation, and an `extend`/merge protocol
(`flattenSelector`, `makeSelector`, `makeProfile`). **weir has NO
computation expressions**, so none of this ports. The same config is a
plain nested record literal:

```weir
let profile = T.Profile {
    id = "default"
    includeRootDir = false
    changeKeyRegex = Some @"(CHANGE-KEY-[a-z0-9]+)"
    selector = Dotnet.generic
}
let buildPlan = T.BuildPlan { profiles = Map.ofPairs [("default", profile)]; range = None }
```

**What was lost:** (i) the `extend`/merge sugar — a selector inheriting a
base and appending patterns/excludes (test-plan.fsx's
`extend baseSelector` + extra `pattern`). In weir that is ordinary
record copy-and-update: `{ Dotnet.generic with patterns = Seq.append
Dotnet.generic.patterns ["*.toml"] }` — MORE explicit, and the
"excludes merge in reverse order" quirk (a CE accumulation artifact, per
test-plan.fsx) simply doesn't arise. (ii) The `from_ref`/`to_ref`
overloads taking string-or-Option — collapsed to one `Range { fromRef =
Some "..."; toRef = None }`. (iii) The multi-`pattern` repetition — now
one `patterns = ["*.a"; "*.b"]` list.

**Reads better or worse?** Better for a reader, slightly worse for the
author of a large config. The CE hid the fact that a plan is *just a
value*; the record makes it obvious, composes with `{ with }`, and needs
no builder to learn. The 411-line builder becoming zero lines is the
headline. The one genuine ergonomic loss is `extend`'s implicit
id-inheritance and list-append — in weir you spell the append yourself.
For a Stage-2 with many selectors, a small `Selector.extend base
overrides` helper function (plain, not a CE) would restore the terseness
with none of the facet-list machinery.

### 3. `Env.load` enum fields reject `[<Default>]`

dbt writes `[<Env.Default("diff")>] DBT_MODE: Mode` (plan.fsx:147-148).
weir refuses `[<Default>]` on an enum-typed `Env.load` field ("attribute
literals are string/int/bool") — the enum resting point spells
`Option<Mode>` + `Option.defaultValue`. So `DbtEnv.DBT_MODE` is
`Option<Mode>` and a one-line `modeOf env = env.DBT_MODE |>
Option.defaultValue T.Diff` supplies the "diff" default. Minor, teachable,
one helper — but a real divergence from dbt's attribute (and see (c)#2).

---

## (c) MISSING or AWKWARD — the concrete gap list

1. **No glob-EXCLUDE combinator.** dbt uses
   `Microsoft.Extensions.FileSystemGlobbing.Matcher` with
   `AddInclude`/`AddExcludePatterns` and a `**/*.*` + excludes matcher
   (plan.fsx:70-73, 104). weir has `Path.glob` (include-only:
   within-segment `*`, cross-segment `**`, `?`, `[abc]`) but **no exclude
   side and no matcher object that combines include+exclude**. Hand-rolled
   in discover.weir as `isExcluded excludes path = excludes |> Seq.exists
   (fun e -> path |> Str.contains e)` — a substring containment, which
   matches dbt's relative-path-fragment excludes in practice but is NOT
   glob-accurate (a `*.g.cs` exclude pattern would not work). Wanted:
   `Path.glob` with an exclude arg, or a `Glob.match`/`Glob.matcher`
   primitive taking include+exclude pattern sets. This is the headline
   gap for this domain — dbt's whole selection story is glob include/
   exclude.

2. **`[<Default>]` refused on `Env.load` enum fields** (see (b)#3).
   dbt's `[<Env.Default("diff")>] DBT_MODE: Mode` (plan.fsx:147) has no
   weir spelling; the field must be `Option<Mode>` + a code default.

3. **Imported union CONSTRUCTORS need the `T.` qualifier; PATTERNS
   don't.** In lib/plan.weir, constructing `T.MergeBase`/`T.Override`/
   `T.Parent`/`T.Diff` needs the import qualifier (a bare `Diff` errors
   "'Diff' is module-qualified; use 'T.Diff'"), but MATCHING them
   (`match mode with | Diff -> …`) resolves bare against the scrutinee
   type. Correct per [D:ambiguous-ctor]/the pattern rules, but the
   asymmetry is a small papercut when a union straddles a module
   boundary — you write `T.Diff` to build and `Diff` to match, in
   adjacent lines.

4. **Signatures and record-field types name imported types BARE, not
   qualified.** `let resolveBaseRefs : string -> BaseStrategy -> …` and
   `DBT_MODE: Mode` — writing `T.BaseStrategy`/`T.Mode` in a signature or
   field-type position is a parse error ("a signature names types bare").
   Fine once learned, but it sits oddly beside (c)#3: the SAME imported
   name is bare in a type position and qualified in a value position.
   (This is the module-signature face of asdf/ring's typed-scrutinee
   law.)

5. **No `Path.GetRelativePath`.** dbt computes `relativePath`/
   `relativeDir` via `Path.GetRelativePath(cwd, ...)` (plan.fsx:121-130).
   The port sidesteps it: git already yields repo-root-relative paths and
   the evaluator runs at repo root, so `relativePath == path` and every
   field derives lexically from `Path.dir`/`Path.fileName`/`Path.stem`.
   Worked here, but a discovery root ≠ cwd (dbt's `discoveryRoot`
   selector option) would need real relative-path arithmetic weir does
   not offer. Wanted: `Path.relativeTo base path`.

6. **`Str`-split on a CHAR SET is `Str.rsplit` + a regex class.** dbt's
   projectId default does `relativeDir.Split(['.';'_'])` (plan.fsx:136).
   weir has no `Str.split`-on-many-chars; the port uses `Str.rsplit
   @"[._]"` + `Str.join "-"`, which is fine (and arguably clearer) — noting
   it only because the F# `.Split(charArray)` is a one-liner with no
   direct weir twin.

7. **`==` still undefined for `Option<seq<_>>`** (the recurring seq-eq
   gap, now inside Option). Asserting `changeKeys == None` failed
   ("'==' is not defined for Option<seq<string>>"); the harness matches
   `| None -> true | Some _ -> false` instead. `Seq.equal` covers the
   Some case; there is no `Option.equalBy`. Fourth sighting of the
   seq-equality family across these ports.

Fidelity notes for the dbt author (F# behaviours the typed port
surfaced, not weir gaps): (i) the change-key scrape yields only the
FIRST regex match PER LINE — `ParseCommitMessage` (git.fsx:130-136) maps
`ParseRegex` over `--pretty=%B` lines and `ParseRegex` returns one
match's groups, so a commit body `[CHANGE-KEY-feat1] and
[CHANGE-KEY-feat2]` on one line contributes only `feat1` (confirmed
against the real dbt: the oracle emitted exactly `CHANGE-KEY-feat1`).
That is easy to read as "all keys in the message" and is not. (ii) The
base commit is EXCLUSIVE in the `base..current` log range, so a key in
the base commit itself is never scraped — also confirmed against the
oracle.

---

## (d) Stage-2 estimate

- **Glob include/exclude** — the (c)#1 gap is the real Stage-2 gate for
  the other selectors: bicep/node are pure glob (`*.bicep`,
  `package.json`) and would work TODAY with `Path.glob`, but any selector
  needing excludes (dbt's `exclude "subdir"`) wants the real matcher.
  Either land a weir `Glob` primitive or accept substring-exclude with a
  stated non-claim. ~0.5 day to port bicep+node selectors on the current
  `Path.glob`; the exclude-accuracy gap is a weir change, not a port one.

- **dotnet dependency-graph leaf expansion** (solution.fsx,
  `makeDependencyTree`/`findLeafDependants`/`findAllLeafDependants`) —
  the `expandLeafs` Stage-1 stub is identity. Real expansion needs
  `.sln`/`.slnx` parsing (dbt uses Ionide.ProjInfo) + a `ProjectReference`
  graph walk. weir has NO sln parser (`.slnx` is XML — `from xml`
  reaches it; classic `.sln` is a bespoke text format — an owned parser,
  the yaml-subset playbook). The graph walk itself is `Graph.reach` over
  ProjectReferences (csproj via `from xml`, already proven). ~1.5–2 days,
  most of it the `.sln` parser; `.slnx`-only would be ~1 day.

- **CI last-success-sha** (github/tekton) — resolves a base commit from a
  provider API. `Http.fetch`/`Http.send` + `from json` is the exact
  shape; the Tekton path shells `kubectl`/CRD reads. ~1 day each given
  credentials.

- **snapshot write/validate** (snapshot.fsx) — PlanOutput is already
  `to json`-able (function-free by design), so write is `out |> to json
  |> File.write`, validate is read+`Seq.equal`/record compare. The one
  wrinkle is the seq-eq gap (c)#7 for the compare. ~0.5 day.

- **The `extend`/merge DSL ergonomics** — if a Stage-2 config grows many
  selectors, a plain `Selector.extend` helper (not a CE) restores dbt's
  terseness. ~0.25 day.

Total Stage 2: **~4–6 dev-days**, gated on the glob-exclude decision and
the `.sln` parser. Highest-leverage weir changes for this domain, in
order: (1) glob include/exclude (or a `Glob` matcher), (2) `[<Default>]`
on `Env.load` enum fields, (3) `Path.relativeTo`.

---

## Oracle status (stated plainly)

**The real dbt ran.** `fsy install-fsx-extensions` is blocked
(`~/.fsharp` is read-only in this container), but `fsy run <script.fsx>`
restores paket IN-PROCESS and executes — so the actual `Plan.evaluate`
runs. `fsx/oracle.fsx` (a driver dropped in the writable dbt-src tree)
evaluates the same dotnet plan the port ships; `test/oracle.sh` builds
one fixture repo, runs BOTH the real dbt and the weir port over it in
Diff and All modes, and `diff`s the reports. Result: **byte-identical in
both modes** (required projects `a` + `c/nested`, key `CHANGE-KEY-feat1`,
dirs `a` + `c/nested` in Diff; same projects and no keys/dirs in All;
test project `b` excluded in both). This is a true cross-check against
the F# implementation, not source-reasoning.

## Harness

`test/harness.weir` — a self-contained weir test: it builds a temp git
repo (`a/x.csproj`, `b/y.csproj` (test project), `c/nested/z.fsproj`, a
deep `a/deep/sub/n.cs` change with no project of its own), commits a
baseline and a feature change, then runs `Plan.evaluate` in Diff, All,
and empty-diff modes and asserts (14 asserts, `fail` → exit 1):
required-project ids, kinds, test-project exclusion, the walk-up
(deep change → project `a`), change keys (first-match-per-line),
changed dirs, the change-set range, and the None-shaped All/empty
outputs. All green.
