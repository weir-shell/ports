# docker-postgres-entrypoint — Stage 1 proof slice

A port of the official
[docker-library/postgres](https://github.com/docker-library/postgres)
`docker-entrypoint.sh` to **weir** — the case that motivated the `exec`
reifier (process replacement). Stage 1 covers the entrypoint's spine: the
first-run bootstrap and the `exec` handoff.

> **Requires weir ≥ v0.0.50** (the `exec` reifier). This port lives on its
> own branch until [`TARGET_WEIR_RELEASE`](../TARGET_WEIR_RELEASE) bumps to
> v0.0.50 — on v0.0.46 `| exec` does not parse.

## The headline

A container entrypoint's whole job is to set the stage and then **become**
the real process, so the app is PID 1 and Docker's `SIGTERM` reaches *it*
for a graceful shutdown. The bash original does this with `exec "$@"` —
but only after a `gosu`/step-down dance and a signal-forwarding trap,
because a plain `bash` wrapper that *spawns* postgres would swallow the
signal and orphan it.

weir's `exec` is `execve`, not spawn: it **replaces** the weir image, so
postgres inherits weir's pid directly. The forwarding trap and the wrapper
process simply do not exist:

```weir
// the whole handoff — injection-safe dynamic head, argv forwarded verbatim
^$cmd $@cmdArgs | exec
```

This was the gap a Docker-entrypoint spike found: weir-as-PID-1 *spawned*
the app, dropped `SIGTERM`, and left it running after `docker stop`. `exec`
closes it.

## Layout

- `bin/entrypoint.weir` — the entrypoint: typed `POSTGRES_*` config, the
  first-run `initdb` + database bootstrap (against a throwaway local
  server, exactly the upstream sequence), then `^$cmd $@args | exec`.
- `Dockerfile` — `FROM postgres`, drops in a weir binary and the
  entrypoint, and sets `ENTRYPOINT ["weir", ".../entrypoint.weir"]`.
- `FINDINGS.md` — the language payoff and what `exec` closed.

## Run

```sh
weir check bin/entrypoint.weir          # typecheck (runs nothing)
docker build -t pg-weir .               # build the image
docker run --rm -e POSTGRES_PASSWORD=x pg-weir
# in another shell: `docker stop` — postgres logs a fast shutdown,
# because the SIGTERM reached postgres (pid 1), not a wrapper
```
