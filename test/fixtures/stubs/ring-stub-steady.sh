#!/bin/bash
if [ -n "${RING_ENV_OUT:-}" ]; then
  echo "${WS_LEVEL_VAR:-unset}:${STEADY_VAR:-unset}" > "$RING_ENV_OUT"
fi
exec sleep "${1:-600}"
