# weir-ports

Real-world programs ported to [weir](https://weir.sh) — a typed, shell-shaped
scripting language. Each port is a **language stress test**: the working code
proves weir can carry the program, and the `FINDINGS.md` alongside it is the
honest engineering account of what read *better* than the original, what forced
a redesign, and what weir was missing (that list has driven real language
features — `Str.fields`, `Bytes.hmacSha256`, dynamic command heads, and more).

Every port is checked and tested against the weir release pinned in
[`TARGET_WEIR_RELEASE`](./TARGET_WEIR_RELEASE); CI installs exactly that release
and runs it, so a red build is the migration-work signal for the next release
(the same currency pattern `tree-sitter-weir` uses).

## The ports

| Port | From | Surface it exercises | Headline |
|------|------|----------------------|----------|
| [`asdf/`](./asdf) | asdf (bash version manager, pre-Go) | files · process · PATH · plugins-as-programs | core commands at **~half the bash line count** (1265 → 657); `.tool-versions` parses **once** into a typed value |
| [`acme/`](./acme) | acme.sh (ACME/Let's Encrypt client) | HTTP · JSON · Bytes/base64url · crypto | HTTP layer **230 → 33 lines**; JWS envelope **openssl-oracle-verified**; RFC-7638 thumbprints byte-match |
| [`ring/`](./ring) | ring (.NET process orchestrator) | supervision · concurrency · lifecycle · signals | a process supervisor on `Proc.spawn`/`poll`; the FSM as a **30-line `match`**; state file-backed → `status` from a second process, no server |
| [`dbt/`](./dbt) | dbt (arquidevio monorepo build tool, F#) | monorepo discovery · git-diff change detection · CE-DSL → records · `from xml` | the `plan{}` computation-expression DSL → **plain records** (~40% fewer lines, "a plan is just a value"); **real-dbt oracle byte-identical**; `Graph.reach` eats the 4th hand-rolled walk-up; the `plan`-keyword collision (dbt's build-`Plan` vs weir's dry-run `plan`) |

Each is a **Stage 1** slice — a coherent, runnable proof, not a complete port —
with a Stage-2 estimate in its FINDINGS.

## What the ports taught the language

The findings are the point. A sample of gaps these ports surfaced, most now
closed:

- **Dynamic command heads** (`^$path arg`) — asdf's plugin callbacks are runtime
  paths; the literal-head rule forced `sh -c`, the injection vector weir exists
  to abolish. Now a first-class, injection-safe form.
- **`Str.fields`/`Str.rsplit`**, **`Bytes.fromHex`/`toHex`/`hmacSha256`**,
  **`Seq.equal`**, **`Str.padLeft`/`padRight`** — each hand-rolled in a port
  before it was a member.
- **Non-tty SIGINT** (ring) — scopes unwind on Ctrl+C at a tty but a piped
  process ignored the signal; a supervisor-critical fix.
- **A server surface** (ring) — the protocol study proved `Http.serve` +
  SSE-as-a-lazy-`seq` covers a real orchestrator's protocol without WebSockets.

Each port also caught **bugs in the original** — the typed rewrite makes latent
logic errors obvious (asdf's version-starring, ring's unpassed compose env).

## Running a port

```sh
curl -fsSL https://weir.sh/install.sh | sh   # installs the latest weir
cd asdf && weir check bin/asdf.weir     # typecheck (runs nothing)
weir test/run.weir                      # the port's own harness
```

The pinned release is the contract: `weir --version` should be at least
`TARGET_WEIR_RELEASE`.
