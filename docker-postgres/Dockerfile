# A weir entrypoint on top of the official postgres image. weir replaces
# the shell entrypoint; `exec` inside it hands postgres pid 1 so SIGTERM
# reaches it directly (see FINDINGS.md).
FROM postgres:17

# Drop in a weir binary. Pin the release that ships `exec` (>= v0.0.50);
# the multi-arch install script picks the right build.
ARG WEIR_VERSION=v0.0.50
RUN set -eux; \
    apt-get update && apt-get install -y --no-install-recommends curl ca-certificates; \
    curl -fsSL "https://github.com/weir-shell/weir/releases/download/${WEIR_VERSION}/install.sh" | sh; \
    rm -rf /var/lib/apt/lists/*

COPY bin/entrypoint.weir /usr/local/bin/entrypoint.weir

# weir becomes the entrypoint; it execs `postgres` (the CMD) at the end,
# so the long-lived process is postgres itself, as pid 1.
ENTRYPOINT ["weir", "/usr/local/bin/entrypoint.weir"]
CMD ["postgres"]
