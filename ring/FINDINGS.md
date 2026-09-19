# FINDINGS — porting ring (C#) to weir, Stage 1: the supervisor core

Scope: workspace config (yaml twin of ring.toml, import tree included),
the runnable model (`Proc` and `DockerCompose` for real; `Dotnet`/
`Kustomize` stub-with-teach), ring's exact lifecycle state machine,
process-alive health probes on a schedule, recovery/restart, escalation
to DEAD, and graceful shutdown. Plus `list` and `status` read commands.
Everything `weir check`s clean (zero warnings) under the freeze-aware
binary; the harness runs 56 asserts + a pty Ctrl+C test, all green,
including the no-orphans checks.

Verdict up front: **go**. The state machine, the two-phase teardown and
the whole config layer read dramatically better than the C#. The one
genuine architectural collision — a supervisor is a long-lived mutable
event loop, weir has no mutation and no unbounded loop — resolved into a
*file-backed* state design that turned out to be a feature (a second
process reads live supervisor state with no server). Friction
concentrated in signal delivery semantics (one real gap), cross-tick
state, and the known typed-scrutinee rule.

---

## (a) What ported cleanly and read BETTER than the C#

### 1. The Stateless FSM as a `match` — the headline

`Runnable.cs` configures its state machine through ~80 lines of
builder DSL, with entry actions, task-field mutation and message
sends interleaved:

```csharp
_fsm.Configure(State.Idle)
    .OnEntryFromAsync(Trigger.Init, () => InitCoreAsync(token))
    .OnEntryFromAsync(Trigger.Stop, () => _stopTask = StopCoreAsync(_context!, token))
    .Permit(Trigger.Start, State.Pending)
    .Permit(Trigger.InitFailure, State.Pending)
    .Permit(Trigger.Destroy, State.Zero)
    .Ignore(Trigger.HcUnhealthy) ...
```

The weir port is a 30-line pure function over two unions
(`src/lifecycle.weir`): `Goto` = Permit, `Stay` = Ignore, `Refused` =
Stateless' unhandled-trigger throw:

```weir
| (Idle, Start) -> Goto Pending
| (Idle, InitFailure) -> Goto Pending
| (Idle, Destroy) -> Goto Zero
| (Idle, Stop) -> Stay
```

Every (state, trigger) pair is adjudicated in one screen; the harness
unit-tests the table as *data* (`transition Dead Start == Refused`),
which the C# cannot do without instantiating a runnable + logger +
sender. Protocol events (`RUNNABLE_STARTED`…) are a second small
function `eventOf` instead of `Sender.EnqueueAsync` calls sprinkled
through five `*CoreAsync` methods. 7 states, 10 triggers, exact
transition parity with the C# (verified against `Runnable.cs:88-160`).

### 2. `within`/`always` IS `TerminateAsync` — teardown as structure

Ring's two-phase stop is manual task orchestration: `_stopTask` /
`_destroyTask` fields, `TaskCompletionSource`, `CancellationToken`
threading, and `TerminateAsync` = fire Stop, await, fire Destroy, await
— plus `WorkspaceLauncher.StopAsync`/`RemoveAsync`/`DisposeAsync`
(~40 more lines) to do it for the whole workspace on Ctrl+C.

In weir the same shape is *lexical*:

```weir
within                                      // per-runnable scope
    within proc child = sh -c $line         // one process generation
        within
            ...health loop...
        always
            Life.fire s.life id Life.Stop   // StopAsync (+ compose stop)
always
    Life.fire s.life id Life.Destroy        // DestroyAsync (+ compose down)
```

The inner `always` fires STOPPED per generation — which is exactly
ring's behaviour (recovery emits RUNNABLE_STOPPED too); the outer fires
DESTROYED once; and both run on the deadline path, on a raise, on
SIGTERM and on tty Ctrl+C, LIFO, with the process tree reaped by the
proc scope. The entire class of state the C# carries for this
(`_stopTask`, `_destroyTask`, `_runnableStarted`, event unsubscription,
`Interlocked` counters) does not exist in the port. This is the
strongest single mapping in the port.

### 3. The class hierarchy as a union

`Runnable<TContext,TConfig>` + `ProcessRunnable<,>` + marker interfaces
(`ITrackProcessId`, `ITrackRetries`, `IUseWorkingDir`…) became one
config union (`Proc | DockerCompose | Dotnet | Kustomize`) and one
supervise function per ported arm. A telling C# detail with no weir
equivalent needed: on init failure ring conjures an *uninitialized*
context object —

```csharp
_context = (TContext)RuntimeHelpers.GetUninitializedObject(typeof(TContext));
```

— so the health loop has something to probe. The weir port has no
uninitialized values because contexts aren't objects: a generation's
"context" is the `within proc` handle plus files.

### 4. The health loop as `poll`

Ring's loop is a self-rescheduling dance: `QueueHealthCheckAsync` →
`Task.Delay(period)` → fire `HealthLoop` → entry action probes → fires
`HcOk/HcUnhealthy/HcDead` → `Healthy` entry re-queues. The weir loop is
`poll { timeout = budget; interval = period }` with a tick body that
fires `HealthLoop`, probes, fires the result trigger, and returns the
exit condition. Ring's escalation law
(`ConsecutiveFailures/TotalFailures >= max ⇒ Dead`,
`CheckHealthCoreAsync`) is three lines in the probe. One fidelity note:
ring's *Proc* context does not implement `ITrackRetries`, so a plain
proc in ring restarts forever and never escalates — the machinery
exists but only Dotnet/Kustomize use it. `--max-recoveries` generalizes
`MaxTotalFailuresUntilDead` to procs (default 10^6 ≈ ring's forever).

### 5. Config: 423 lines of C# + Tomlyn vs `from yaml` + `Graph.reach`

The whole Configuration project (WorkspaceConfig, RunnableConfigBase,
per-type classes, interfaces) is 423 lines plus a TOML library plus
`Configurator`/`ConfigSet` tree loading. The weir twin is declared
types + a loader (`src/config.weir`, 189 lines total), and the import
tree — ring's recursive config loader — is:

```weir
let files = Graph.reach (fun p -> p) importsOf root |> Seq.freeze
```

cycle- and diamond-safe by construction (the asdf port's walk-up
finding, repeated: a graph builtin keeps eating hand-rolled loaders).
Workspace-level `[env.<typeId>]` is a `Dictionary<string, Dictionary<..>>`
in C#; since the type-id set is closed, the weir spelling is a declared
record — arguably more honest than the stringly dictionary.

### 6. Small pleasures

- `Proc.tail` rides the death report for free (`flaky exited (code 1),
  last output: boom`) — ring builds output capture plumbing in
  `RunProcess.cs` for this.
- The child stdout spill law means a chatty runnable cannot pollute the
  supervisor's own stdout status stream — ring redirects and buffers
  manually.
- `--run-for 4s`, `--health-period 500ms`: typed `Duration` flags with
  `[<Default 5s>]` — CommandLineParser has nothing comparable.
- Line counts, with the honest caveat (no ws server, no tasks/flavours,
  two arms stubbed): supervisor-relevant C# ≈ 1069 lines
  (Runnable 378, WorkspaceLauncher 337, RunProcess 181, runnables ~170)
  + Configuration 423; weir ≈ 681 (lifecycle 189, config 189, ring 303).

---

## (b) What FORCED a redesign, and the weir answer

### 1. A supervisor is mutable; weir isn't — state became FILES

The C# supervisor is objects mutating in an event loop
(`ctx.ProcessId = info.Pid`, `t.ConsecutiveFailures++`). weir has no
mutation and no way to thread an accumulator across `poll` ticks or
`retry` attempts. The redesign: **the state dir is the mutable store** —
`state-<id>` (current RState), `recs-<id>` (ring's TotalFailures),
`verdict-<id>` (generation outcome), `events.log` (append-only, under
`within lock`). This is the port's biggest departure and its best
outcome:

- `ring status -s <dir>` reads a LIVE supervisor's state from a second
  process — ring needs its WebSocket server for that; here it fell out
  of the persistence design (demoed mid-run in the transcript).
- `events.log` is simultaneously the protocol event stream, the
  harness's assertion surface, and the SSE prototype (see (e)).
- Crash-forensics for free: the state dir outlives the process.

### 2. The event loop became structured concurrency

One `Seq.piter` arm per runnable; inside an arm, one `retry … until`
per process *generation* (spawn → supervise → verdict), recovery =
the next attempt re-entering `within proc`. Ring's
`RecoverAsync` = `fire Stop; fire Start` maps to: death tick fires
`HcUnhealthy` (→ Recovering), scope `always` fires `Stop` (→ Idle),
next generation fires `Start` (→ Pending) — byte-for-byte the same
event sequence ring pushes, from structure instead of method calls.

### 3. A scope cannot yield a value

`within proc` blocks are statements; the generation's outcome (recover
vs halt) cannot escape as a value, so it exits through `verdict-<id>`
and the generation re-reads it. Works, but it is the one place the
design feels like plumbing. (Same root as (c)#3.)

### 4. Optional backends vs the literal-head law

`weir check` only WARNS on a missing `docker-compose`, but *run*
refuses to start the whole file — so a proc-only workspace could not
run on a machine without docker-compose. For an orchestrator whose
backends are optional by nature, literal heads for optional tools are
wrong; they went through `sh -c` (quoted, teach-commented). This is
asdf's dynamic-exec gap wearing a new face: heads resolved at
file-load, not at first execution. A per-command lazy-resolve (error at
first *spawn*, like bash) or a checked dynamic-exec would both fix it.

### 5. Run budget as data — and a bug the transcript caught

Ring runs until told to stop; a weir script wants a bound, so `run`
takes `--run-for` and every poll gets `timeout = remaining + 60s` so
exhaustion (which raises) is unreachable. First transcript exposed an
off-by-one: a child dying in the same tick that hit the deadline took
one spurious restart *past* the deadline — the verdict now re-checks
the deadline. The typed port made the bug visible in one read of the
event log.

### 6. Console vs protocol stream

Ring pushes `RUNNABLE_HEALTH_CHECK` + `RUNNABLE_HEALTHY` every probe
(5s cadence, per runnable) because clients want it. On a terminal that
is noise, so: everything → `events.log`, state *changes* → console.
A deliberate divergence, worth calling out because it is really a
client-vs-terminal distinction the server story will reopen.

---

## (c) MISSING or AWKWARD — the concrete gap list

1. **Detached SIGINT is ignored — the one real gap for this domain.**
   Measured with the probe harness (`probes/p4-drive.sh`, `p5-pty.py`):
   - `kill -INT <pid>` (no tty): NO unwind — supervisor alive 10s
     later, children orphaned, SIGKILL required.
   - tty Ctrl+C (pty): full LIFO unwind (`inner-always`, `top-always`),
     tree reaped, re-raises SIGINT (dies with sig 2). Correct.
   - `kill -TERM`: full unwind, exit 143, no orphans. Correct.
   The SKILL's "SIGINT and SIGTERM all close every scope" holds only
   for *tty* SIGINT. A supervisor's stop paths in the wild are
   `kill -INT` from wrappers, systemd `KillSignal=SIGINT` setups, CI
   runners — all detached. The port's harness uses SIGTERM + a pty
   test; ring's own Ctrl+C story is covered, but please confirm whether
   ignoring non-tty SIGINT is deliberate; if not, it's a one-line
   register fix with an outsized payoff for long-running weir.

2. **Env sigils don't parse in `within proc` command position.**
   `within proc c = $ev(sh -c $line)` → `parse: Expecting '$@'` (and
   `!ev(...)` likewise), though the scoped-procs section says the
   command position takes "splices and env sigils like any command".
   The working spelling is nesting under `within env ev` — fine, and
   the assembly error for line-end `!ev` even teaches exactly that —
   but either the parser or the sentence should move.

3. **No cross-iteration state in `retry`/`poll`.** Porting
   `ITrackRetries` (`ConsecutiveFailures++`) had nowhere to live:
   bodies are re-evaluated with no accumulator, so counters became
   files (`recs-<id>`), with read/bump helpers. A state binder —
   `retry acc=x0 …` yielding `(acc, verdict)`, or a `Seq.foldUntil` —
   would erase five helpers and the verdict files ((b)#3) in one move.
   This is the supervisor-domain sibling of asdf's "no while".

4. **Typed-scrutinee rule taxes module-private helpers.** Matching a
   union param in a module forces a *signature* (= export) purely to
   type the param (`mergeEnvSection`, `sectionFor`, `ownEnv` in
   config.weir); in the script, `match p.workingDir with Some d`
   on a row-typed param is refused, pushing `Option.map`+`defaultValue`
   spellings (`shellLineFor`). All teachable errors, all with escapes —
   but a private type ascription (annotation or non-exporting sig)
   would keep intent local. (asdf hit the adjacent pattern-qualifier
   gap; this is the same law's module face.)

5. **Inference picked the wrong `+` overload on a row field.**
   `Instant.now () + a.runFor` (a: untyped param, runFor: Duration)
   errored "two points don't add" — the unresolved field unified with
   Instant instead of Duration. Fixed by computing the deadline at the
   typed call site. The message was good; the direction was surprising
   given the left operand was already `Instant` and `instant+duration`
   exists.

6. **`seq` equality still missing** (asdf gap #3, third sighting).
   Event-sequence asserts joined with `Str.join ","` again. `Seq.equal`
   keeps earning its place.

7. **`Str.padRight` still missing** (asdf gap #1, second sighting).
   `pad` re-hand-rolled for the status table and transition lines.

8. **First-probe delay is manual.** Ring's first health check fires
   after `HealthCheckPeriod`; `poll` runs its body immediately, so each
   generation starts with `Duration.sleep period`. A `poll` option
   (`initialDelay=`) would read better than a naked sleep.

9. **The discard dance in `always` blocks.** `let _stopR = sh -c
   $stopLine | complete` + a trailing `()` to keep the block unit-typed
   is a recurring three-token idiom when a cleanup command's failure is
   deliberately tolerated. The unused-binding law caught two REAL
   swallowed failures during development, so the law pays for itself —
   but a `| tolerate`-style reifier (stream, never raise, discard code)
   might be the honest spelling for cleanup paths.

Fidelity notes for the author (C# smells the typed port surfaced, not
weir gaps): (i) `DockerCompose.RunAsync` never passes the runnable's
`Env` config to the compose client — compose env config is silently
dead; (ii) the `Idle -InitFailure→ Pending` edge makes a failed init
fall into the health loop probing a `GetUninitializedObject` context —
ported into the table (and tested) but never fired by this supervisor;
it reads like an accident. (iii) `MaxConsecutiveFailures/MaxTotal`
never bite for Proc/DockerCompose (no `ITrackRetries` / probe returns
Dead directly) — the thresholds only govern Dotnet and Kustomize.

---

## (d) The `from toml` costing

**What ring's configs actually use** (all of `tests/resources/*.toml` +
docs): arrays of tables (`[[proc]]`, `[[dotnet]]`…); subtables binding
to the *most recent* array element (`[proc.env]` after a `[[proc]]`);
dotted headers (`[tasks.proc.greet]`, `[env.dotnet]`); string scalars,
string arrays (`args`, `tags`, `urls`, `imports`), booleans
(`bringDown`). No ints (ports are strings), no floats, no dates, no
inline tables, no multi-line strings in any test resource.

**Does the yaml-subset playbook transfer?** Mostly yes: it is a small,
regular subset — an owned parser with teaching rejections for dates,
inline tables, float exotica, exactly the yaml-subset move. Two TOML-
specific costs the yaml parser didn't have: (1) the *positional* rule
that `[proc.env]` attaches to the last `[[proc]]` — the document is not
a pure tree, the parser carries "current table" context; (2) TOML's
duplicate-definition laws want real diagnostics to be worth owning.
Call it a moderate, bounded job — bigger than `from xml`, far smaller
than yaml.

**Compat vs redesign.** Compat: every existing workspace is a
`ring.toml`; asdf/Cargo/pyproject make TOML a recurring boundary, so
`from toml` has customers beyond ring. Redesign: this port *proves* the
yaml twin is 1:1 — `[[proc]]` → a `proc:` sequence, `[proc.env]` → a
nested mapping, and the twins in `test/fixtures/` read at least as well
as the originals (the only loss: flow-style `["30"]` is outside weir's
yaml subset, so arg lists go block-style). A 20-line one-time converter
(any toml reader → yaml) covers migration without any weir change.

**Verdict:** don't build `from toml` for ring alone; build it when a
second toml-shaped port lands (asdf Stage-2 config files would be one).
When built, ring needs only the subset above — tables, arrays-of-
tables, dotted keys, strings/bools/string-arrays — and the playbook
transfers with the last-array-element rule as the one novel hazard.

---

## (e) THE PROTOCOL STUDY — ring's wire vs a weir server story

**Ground truth** (`Queil.Ring.Protocol`, `WebsocketsHandler.cs`,
server `WsClient.cs`, F# client `WsClient.fs`): binary frames, 1 type
byte + UTF-8 payload, 4096-byte cap; `M : byte` enum; `Ack : byte`
enum riding an ACK frame's first payload byte.

**Client → server (commands):** `LOAD`(path), `UNLOAD`, `START`,
`STOP`, `TERMINATE`, `RUNNABLE_INCLUDE`(id), `RUNNABLE_EXCLUDE`(id),
`RUNNABLE_EXECUTE_TASK`(json `{RunnableId, TaskId}`),
`WORKSPACE_APPLY_FLAVOUR`(name), `WORKSPACE_INFO_RQ`, `PING`.
(`INCLUDE_ALL` is declared but has no dispatcher.)

**Server → client (pushes):** `SERVER_IDLE/LOADED/RUNNING` (on connect
and on state change), `SERVER_SHUTDOWN`, `WORKSPACE_INFO_PUBLISH`
(JSON `WorkspaceInfo` snapshot: runnables × {id, type, state ∈ ZERO|
INITIATED|STARTED|HEALTH_CHECK|HEALTHY|DEAD|RECOVERING, tags, details,
tasks} + serverState + workspaceState ∈ NONE|IDLE|HEALTHY|DEGRADED +
flavours; deduped when unchanged, pushed on every transition), and the
eight per-runnable events `RUNNABLE_INITIATED/STARTED/HEALTH_CHECK/
HEALTHY/RECOVERING/UNRECOVERABLE/STOPPED/DESTROYED`.
(`WORKSPACE_DEGRADED/HEALTHY/STOPPED` are declared, never emitted —
the snapshot carries that.)

**Pairing:** every command gets an `ACK` (Ok/NotFound/ServerError/
TaskOk/TaskFailed/Alive…). NO correlation ids — long-running commands
queue their ACK to a background loop, so pairing is FIFO order only.
**No server-initiated message ever awaits a client reply.** Pushes are
fire-and-forget over an *unbounded* channel (no backpressure).

**The redesign sketch, evaluated.** `Http.serve` with sync handlers +
SSE-as-lazy-`seq<string>` + POST commands:

| ring wire | HTTP spelling |
|---|---|
| LOAD/UNLOAD/START/STOP/TERMINATE/INCLUDE/EXCLUDE/FLAVOUR | `POST /command` (or one route each); `Ack` = status + body |
| RUNNABLE_EXECUTE_TASK + deferred ACK.TaskOk | POST → 202, completion arrives as an event; or a handler that blocks until done (sync-over-async, weir's pmap doctrine) |
| WORKSPACE_INFO_RQ / WORKSPACE_INFO_PUBLISH | `GET /status` — this port's `doStatus` already computes exactly this shape from the state dir |
| RUNNABLE_* + SERVER_* pushes | `GET /events` SSE: the response body IS a lazy `seq<string>`, one event per element — this port's `events.log` is that stream *today* (`tail -f` is the prototype) |
| PING / ACK.Alive | `GET /healthz` |

**Verdict: ring's real protocol needs no WebSockets.** Duplex is an
implementation convenience, not a requirement: commands are strictly
request→response (HTTP does the correlation ring's FIFO ACKs only
approximate — a strict *upgrade*), pushes are strictly one-way (SSE),
and pull-based SSE adds the backpressure ring's unbounded channel
lacks. The 4KB frame cap disappears; the F# client's frame parser
becomes an HTTP client + line reader.

**Minimal weir surface required:**
1. `within serve srv = Http.serve { port = p } handler` — a *scoped*
   server (lifetime = scope, teardown closes the listener; consistent
   with `within proc`), handler `HttpRequest -> HttpResponse`, sync.
2. A streaming body case: `Stream of seq<string>` beside
   `Json/Text/NoBody` — lazy pull, one element per SSE line; an
   infinite seq is a legal body; client disconnect ends enumeration
   (needs a stated law: what does the producer see? the `Proc.stop`
   analogue).
3. A handler concurrency ceiling (`pmapWith`'s law transfers verbatim).

Nothing else: no correlation machinery, no new async surface, no ws.
And one Stage-1 receipt makes the server story *cheaper* than expected:
because supervisor state is file-backed, a `ring serve` could run as a
**separate process** reading the same state dir — `GET /status` =
`doStatus`, `GET /events` = tail `events.log`, commands = control files
(the include/exclude mechanism Stage 2 needs anyway). The server
becomes an optional adapter over data, not the supervisor's foundation
— that is a better architecture than ring's, and weir's constraints
forced it.

---

## (f) Stage-2 estimate

- **dotnet runnable** — git clone (`git` literal head), csproj →
  assembly path via **`from xml`** (weir reads csproj natively — a
  genuine differentiator), `dotnet build` under `retry attempts=3
  delay=10s` (ring's exact policy), then the existing proc arm with
  `ASPNETCORE_URLS`/urls env. ~1–1.5 days.
- **kustomize runnable** — build/apply via kubectl, pod polling with
  `kubectl get -o json |> from json` + `poll`; the 10s/5/10 threshold
  overrides are one record. ~1–1.5 days given a cluster.
- **tasks** (`[tasks.*]`, bringDown) + **include/exclude/flavours** —
  needs a control channel INTO a running arm: a `control-<id>` file the
  tick polls (the state-dir discipline extended). Excluded = fire Stop,
  park; included = next generation. ~2–3 days; this is where
  control-plane-by-files gets its real stress test.
- **`ring serve`** — with (e)'s three primitives, ~2–3 days as the
  separate-process adapter; without them, not portable (the one honest
  wall).
- **TOML** — per (d): a converter script now (~0.5 day), `from toml`
  when a second customer lands.
- **Startup spread / WaitUntilStarted ordering, config hot-reload
  (`OnConfigurationChanged`)** — reload is a supervisor restart in this
  design (state dir survives); dependency-ordered start would reuse
  `Graph.reach`. ~1–2 days.

Total Stage 2 without the server: **~5–8 dev-days**; the server story
is gated on the `Http.serve`+`Stream` surface, which (e) scopes to
three members. Highest-leverage weir changes for this domain, in
order: (1) detached-SIGINT unwind, (2) retry/poll state binder,
(3) the server surface.
