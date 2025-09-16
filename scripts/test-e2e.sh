#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN_DIR="$ROOT/target/debug"

if [[ ! -x "$BIN_DIR/envd" || ! -x "$BIN_DIR/envctl" ]]; then
  echo "Building envd/envctl binaries..." >&2
  cargo build --locked --bins
fi

ENVD_BIN="$BIN_DIR/envd"
ENVCTL_BIN="$BIN_DIR/envctl"

TMPDIR=$(mktemp -d -t cmux-e2e-XXXXXX)
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

"$ENVD_BIN" >/tmp/envd.log 2>&1 &
DAEMON_PID=$!

i=0
SOCK="$XDG_RUNTIME_DIR/cmux-envd/envd.sock"
until [[ -S "$SOCK" ]]; do
  ((i++))
  if (( i > 50 )); then
    echo "envd socket did not appear" >&2
    exit 1
  fi
  sleep 0.1
done

export PATH="$BIN_DIR:$PATH"

envctl ping | grep -q "pong"

envctl set E2E_FOO=bar
[[ $(envctl get E2E_FOO) == "bar" ]]

envctl unset E2E_FOO

HOME_DIR="$TMPDIR/home"
mkdir -p "$HOME_DIR"
RCFILE="$TMPDIR/envctl-test-rc"
cat >"$RCFILE" <<RC
export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
export ENVCTL_GEN=0
export PATH="$BIN_DIR:\$PATH"
RC
"$ENVCTL_BIN" hook bash >>"$RCFILE"

OUT1="$TMPDIR/out1"
OUT2="$TMPDIR/out2"

env HOME="$HOME_DIR" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    OUT_PATH="$OUT1" \
    bash --noprofile --rcfile "$RCFILE" <<'BASH'
set -eo pipefail
envctl set CROSS_E2E=from_shell1
printf '%s\n' "$CROSS_E2E" >"$OUT_PATH"
BASH

[[ $(cat "$OUT1") == "from_shell1" ]]

env HOME="$HOME_DIR" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    OUT_PATH="$OUT2" \
    bash --noprofile --rcfile "$RCFILE" <<'BASH'
set -eo pipefail
printf '%s\n' "$CROSS_E2E" >"$OUT_PATH"
BASH

[[ $(cat "$OUT2") == "from_shell1" ]]

envctl unset CROSS_E2E

echo "E2E bash script passed"
