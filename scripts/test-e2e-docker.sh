#!/usr/bin/env bash
set -euo pipefail

# Global timeout for the entire script (5 minutes)
if command -v timeout >/dev/null 2>&1; then
  # Re-exec with timeout if not already under timeout
  if [[ "${E2E_UNDER_TIMEOUT:-}" != "1" ]]; then
    exec env E2E_UNDER_TIMEOUT=1 timeout --preserve-status 300 "$0" "$@"
  fi
fi

if [[ -f "$HOME/.cargo/env" ]]; then
  # Load cargo environment in minimal containers
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi

export PATH="/usr/local/cargo/bin:$PATH"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMPDIR=$(mktemp -d -t cmux-e2e-XXXXXX)

# When running in Docker, binaries are already built
if [[ "${IN_DOCKER:-}" == "1" ]]; then
  BIN_DIR="/app/target/debug"
else
  CARGO_TARGET_DIR="$TMPDIR/target"
  export CARGO_TARGET_DIR
  BIN_DIR="$CARGO_TARGET_DIR/debug"

  echo "Building envd/envctl binaries..." >&2
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status 60 cargo build --locked --bins
  else
    cargo build --locked --bins
  fi
  echo "Build completed successfully" >&2
fi

ENVD_BIN="$BIN_DIR/envd"
ENVCTL_BIN="$BIN_DIR/envctl"

cleanup() {
  if [[ -n "${DAEMON_PID:-}" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

export XDG_RUNTIME_DIR="$TMPDIR/runtime"
mkdir -p "$XDG_RUNTIME_DIR/cmux-envd"

echo "Starting envd daemon..." >&2
echo "XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR" >&2
echo "Socket path will be: $XDG_RUNTIME_DIR/cmux-envd/envd.sock" >&2
"$ENVD_BIN" >/tmp/envd.log 2>&1 &
DAEMON_PID=$!
echo "envd daemon started with PID $DAEMON_PID" >&2

# Give daemon a moment to start
sleep 0.5

# Check if daemon is still running
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
  echo "ERROR: envd daemon died immediately" >&2
  echo "envd log contents:" >&2
  cat /tmp/envd.log >&2 || echo "No log file found" >&2
  exit 1
fi

# Wait for daemon socket with timeout
i=0
SOCK="$XDG_RUNTIME_DIR/cmux-envd/envd.sock"
MAX_WAIT=100  # 10 seconds total (100 * 0.1s)
until [[ -S "$SOCK" ]]; do
  ((i++))
  if (( i > MAX_WAIT )); then
    echo "ERROR: envd socket did not appear after ${MAX_WAIT} attempts" >&2
    echo "envd log contents:" >&2
    cat /tmp/envd.log >&2 || true
    exit 1
  fi
  sleep 0.1
done
echo "envd socket ready after $((i-1)) attempts" >&2

export PATH="$BIN_DIR:$PATH"
# Always use timeout for envctl commands to prevent hanging
ENVCTL_CMD=("$ENVCTL_BIN")
if command -v timeout >/dev/null 2>&1; then
  ENVCTL_CMD=(timeout --preserve-status 15 "$ENVCTL_BIN")
else
  echo "WARNING: timeout command not available, tests may hang" >&2
fi

PING_OUT=$("${ENVCTL_CMD[@]}" ping)
grep -q "pong" <<<"$PING_OUT"

"${ENVCTL_CMD[@]}" set E2E_FOO=bar
[[ $("${ENVCTL_CMD[@]}" get E2E_FOO) == "bar" ]]

"${ENVCTL_CMD[@]}" unset E2E_FOO

HOME_DIR="$TMPDIR/home"
mkdir -p "$HOME_DIR"
RCFILE="$TMPDIR/envctl-test-rc"
cat >"$RCFILE" <<RC
export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
export ENVCTL_GEN=0
export PATH="$BIN_DIR:\$PATH"
RC
"$ENVCTL_BIN" hook bash >>"$RCFILE"

# Shell commands with timeout
SHELL_CMD=(/bin/bash --noprofile --rcfile "$RCFILE")
if command -v timeout >/dev/null 2>&1; then
  SHELL_CMD=(timeout --preserve-status 30 "${SHELL_CMD[@]}")
else
  echo "WARNING: timeout command not available for shell tests" >&2
fi

OUT1="$TMPDIR/out1"
OUT2="$TMPDIR/out2"

env HOME="$HOME_DIR" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    OUT_PATH="$OUT1" \
    "${SHELL_CMD[@]}" <<'BASH'
set -eo pipefail
envctl set CROSS_E2E=from_shell1
printf '%s\n' "$CROSS_E2E" >"$OUT_PATH"
BASH

[[ $(cat "$OUT1") == "from_shell1" ]]

env HOME="$HOME_DIR" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    OUT_PATH="$OUT2" \
    "${SHELL_CMD[@]}" <<'BASH'
set -eo pipefail
printf '%s\n' "$CROSS_E2E" >"$OUT_PATH"
BASH

[[ $(cat "$OUT2") == "from_shell1" ]]

"${ENVCTL_CMD[@]}" unset CROSS_E2E

echo "E2E bash script passed"