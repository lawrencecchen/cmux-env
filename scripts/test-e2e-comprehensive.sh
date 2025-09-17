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
CARGO_TARGET_DIR="$TMPDIR/target"
export CARGO_TARGET_DIR
BIN_DIR="$CARGO_TARGET_DIR/debug"
ENVD_BIN="$BIN_DIR/envd"
ENVCTL_BIN="$BIN_DIR/envctl"

echo "=== Building envd/envctl binaries ===" >&2
if command -v timeout >/dev/null 2>&1; then
  timeout --preserve-status 60 cargo build --locked --bins
else
  cargo build --locked --bins
fi
echo "Build completed successfully" >&2

cleanup() {
  # Kill any daemon we started
  if [[ -n "${DAEMON_PID:-}" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "Cleaning up daemon PID $DAEMON_PID" >&2
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi

  # Kill any background shells
  jobs -p | while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done

  rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

export XDG_RUNTIME_DIR="$TMPDIR/runtime"
mkdir -p "$XDG_RUNTIME_DIR/cmux-envd"

# Helper function to run envctl with timeout
run_envctl() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status 15 "$ENVCTL_BIN" "$@"
  else
    "$ENVCTL_BIN" "$@"
  fi
}

# Helper to create a bash RC file with hooks
create_rcfile() {
  local rcfile="$1"
  cat >"$rcfile" <<RC
export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
export ENVCTL_GEN=0
export PATH="$BIN_DIR:\$PATH"
RC
  "$ENVCTL_BIN" hook bash >>"$rcfile"
}

echo ""
echo "=== TEST 1: Basic envctl commands with pre-started daemon ===" >&2
echo "Starting envd daemon manually..." >&2
"$ENVD_BIN" >/tmp/envd.log 2>&1 &
DAEMON_PID=$!

# Wait for daemon socket
i=0
SOCK="$XDG_RUNTIME_DIR/cmux-envd/envd.sock"
MAX_WAIT=100  # 10 seconds
until [[ -S "$SOCK" ]]; do
  ((i++))
  if (( i > MAX_WAIT )); then
    echo "ERROR: envd socket did not appear" >&2
    cat /tmp/envd.log >&2 || true
    exit 1
  fi
  sleep 0.1
done
echo "Daemon ready after $((i-1)) attempts" >&2

# Test ping
echo "Testing ping..." >&2
PING_OUT=$(run_envctl ping)
if ! grep -q "pong" <<<"$PING_OUT"; then
  echo "ERROR: ping failed, got: $PING_OUT" >&2
  exit 1
fi

# Test set/get/unset
echo "Testing set/get/unset..." >&2
run_envctl set TEST_VAR1=value1
if [[ $(run_envctl get TEST_VAR1) != "value1" ]]; then
  echo "ERROR: get failed" >&2
  exit 1
fi
run_envctl unset TEST_VAR1
echo "✓ Test 1 passed: Basic commands work" >&2

echo ""
echo "=== TEST 2: Lazy daemon startup (daemon not running) ===" >&2
# Kill the daemon
if kill -0 "$DAEMON_PID" 2>/dev/null; then
  kill "$DAEMON_PID"
  wait "$DAEMON_PID" 2>/dev/null || true
fi
unset DAEMON_PID

# Remove socket
rm -f "$SOCK"

# Verify daemon is not running
if [[ -S "$SOCK" ]]; then
  echo "ERROR: Socket still exists" >&2
  exit 1
fi

echo "Daemon stopped, testing lazy startup via envctl..." >&2

# This should start the daemon lazily
run_envctl set LAZY_TEST=lazy_value

# Check if daemon started
if [[ ! -S "$SOCK" ]]; then
  echo "ERROR: Daemon did not start lazily" >&2
  exit 1
fi

# Verify the value was set
if [[ $(run_envctl get LAZY_TEST) != "lazy_value" ]]; then
  echo "ERROR: Lazy startup didn't preserve value" >&2
  exit 1
fi
run_envctl unset LAZY_TEST
echo "✓ Test 2 passed: Lazy daemon startup works" >&2

# Get the new daemon PID for cleanup
DAEMON_PID=$(pgrep -f "$ENVD_BIN" | head -1)

echo ""
echo "=== TEST 3: Cross-shell environment propagation (sequential) ===" >&2
HOME_DIR="$TMPDIR/home"
mkdir -p "$HOME_DIR"
RCFILE="$TMPDIR/envctl-test-rc"
create_rcfile "$RCFILE"

# Shell 1: Set a variable
echo "Shell 1: Setting CROSS_VAR=from_shell1..." >&2
OUT1="$TMPDIR/out1"
env HOME="$HOME_DIR" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    OUT_PATH="$OUT1" \
    /bin/bash --noprofile --rcfile "$RCFILE" <<'BASH'
set -eo pipefail
envctl set CROSS_VAR=from_shell1
# The DEBUG trap needs a command to trigger, so we use a no-op
:
echo "$CROSS_VAR" >"$OUT_PATH"
BASH

if [[ $(cat "$OUT1") != "from_shell1" ]]; then
  echo "ERROR: Shell 1 didn't see its own variable" >&2
  exit 1
fi

# Shell 2: Should see the variable
echo "Shell 2: Reading CROSS_VAR..." >&2
OUT2="$TMPDIR/out2"
env HOME="$HOME_DIR" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    OUT_PATH="$OUT2" \
    /bin/bash --noprofile --rcfile "$RCFILE" <<'BASH'
set -eo pipefail
# Trigger the DEBUG trap to load environment
:
echo "$CROSS_VAR" >"$OUT_PATH"
BASH

if [[ $(cat "$OUT2") != "from_shell1" ]]; then
  echo "ERROR: Shell 2 didn't see variable from Shell 1" >&2
  exit 1
fi
run_envctl unset CROSS_VAR
echo "✓ Test 3 passed: Sequential cross-shell propagation works" >&2

echo ""
echo "=== TEST 4: Concurrent shell sessions with live updates ===" >&2

# Create FIFOs for communication
SHELL1_READY="$TMPDIR/shell1_ready"
SHELL2_READY="$TMPDIR/shell2_ready"
SHELL1_OUT="$TMPDIR/shell1_out"
SHELL2_OUT="$TMPDIR/shell2_out"
mkfifo "$SHELL1_READY" "$SHELL2_READY"

echo "Starting two concurrent shell sessions..." >&2

# Start Shell 1 in background
(
  env HOME="$HOME_DIR" \
      XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
      PATH="$BIN_DIR:$PATH" \
      /bin/bash --noprofile --rcfile "$RCFILE" <<'BASH'
  set -eo pipefail

  # Signal ready
  echo "ready" >"'"$SHELL1_READY"'"

  # Wait for shell 2 to be ready
  read < "'"$SHELL2_READY"'"

  # Check initial state - should be empty
  : # Trigger DEBUG trap
  echo "initial:${CONCURRENT_VAR:-empty}" >>"'"$SHELL1_OUT"'"

  # Set a variable
  envctl set CONCURRENT_VAR=from_shell1
  : # Trigger DEBUG trap
  echo "set:$CONCURRENT_VAR" >>"'"$SHELL1_OUT"'"

  # Give shell 2 time to see the update
  sleep 1

  # Check if we see shell 2's variable
  envctl set DUMMY=trigger_update  # Trigger an update
  : # Trigger DEBUG trap
  echo "final:${OTHER_VAR:-notfound}" >>"'"$SHELL1_OUT"'"
BASH
) &
SHELL1_PID=$!

# Start Shell 2 in background
(
  env HOME="$HOME_DIR" \
      XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
      PATH="$BIN_DIR:$PATH" \
      /bin/bash --noprofile --rcfile "$RCFILE" <<'BASH'
  set -eo pipefail

  # Wait for shell 1 to be ready
  read < "'"$SHELL1_READY"'"

  # Signal ready
  echo "ready" >"'"$SHELL2_READY"'"

  # Check initial state - should be empty
  : # Trigger DEBUG trap
  echo "initial:${CONCURRENT_VAR:-empty}" >>"'"$SHELL2_OUT"'"

  # Wait a moment for shell 1 to set its variable
  sleep 0.5

  # Trigger update and check if we see shell 1's variable
  envctl set OTHER_VAR=from_shell2
  : # Trigger DEBUG trap
  echo "saw:${CONCURRENT_VAR:-notfound}" >>"'"$SHELL2_OUT"'"
  echo "set:$OTHER_VAR" >>"'"$SHELL2_OUT"'"
BASH
) &
SHELL2_PID=$!

# Wait for both shells with timeout
WAIT_COUNT=0
while [[ $WAIT_COUNT -lt 100 ]]; do
  if ! kill -0 "$SHELL1_PID" 2>/dev/null && ! kill -0 "$SHELL2_PID" 2>/dev/null; then
    break
  fi
  ((WAIT_COUNT++))
  sleep 0.1
done

# Check results
echo "Shell 1 output:" >&2
cat "$SHELL1_OUT" >&2 || true

echo "Shell 2 output:" >&2
cat "$SHELL2_OUT" >&2 || true

# Verify Shell 2 saw Shell 1's variable
if ! grep -q "saw:from_shell1" "$SHELL2_OUT"; then
  echo "ERROR: Shell 2 didn't see Shell 1's concurrent update" >&2
  exit 1
fi

# Verify Shell 1 saw Shell 2's variable
if ! grep -q "final:from_shell2" "$SHELL1_OUT"; then
  echo "ERROR: Shell 1 didn't see Shell 2's variable" >&2
  exit 1
fi

run_envctl unset CONCURRENT_VAR 2>/dev/null || true
run_envctl unset OTHER_VAR 2>/dev/null || true
run_envctl unset DUMMY 2>/dev/null || true
echo "✓ Test 4 passed: Concurrent shells can see each other's changes" >&2

echo ""
echo "=== TEST 5: Multiple envctl operations ===" >&2
echo "Testing bulk operations..." >&2

# Set multiple variables
run_envctl set VAR1=val1
run_envctl set VAR2=val2
run_envctl set VAR3=val3

# List all (we should see our variables)
LIST_OUT=$(run_envctl list 2>/dev/null || true)
if [[ -n "$LIST_OUT" ]]; then
  echo "List output: $LIST_OUT" >&2
fi

# Get all our variables
if [[ $(run_envctl get VAR1) != "val1" ]]; then
  echo "ERROR: VAR1 not found" >&2
  exit 1
fi
if [[ $(run_envctl get VAR2) != "val2" ]]; then
  echo "ERROR: VAR2 not found" >&2
  exit 1
fi
if [[ $(run_envctl get VAR3) != "val3" ]]; then
  echo "ERROR: VAR3 not found" >&2
  exit 1
fi

# Unset all
run_envctl unset VAR1
run_envctl unset VAR2
run_envctl unset VAR3
echo "✓ Test 5 passed: Multiple operations work" >&2

echo ""
echo "=== TEST 6: Shell hook integration ===" >&2
echo "Testing that shell hooks properly update environment..." >&2

HOOK_OUT="$TMPDIR/hook_out"
env HOME="$HOME_DIR" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    /bin/bash --noprofile --rcfile "$RCFILE" <<'BASH' >"$HOOK_OUT" 2>&1
set -eo pipefail

# Set a variable via envctl
envctl set HOOK_TEST=hook_value

# The hook should make it available immediately (after triggering DEBUG trap)
: # Trigger DEBUG trap
echo "immediate:${HOOK_TEST:-notfound}"

# Change it
envctl set HOOK_TEST=changed_value
: # Trigger DEBUG trap
echo "changed:${HOOK_TEST:-notfound}"

# Unset it
envctl unset HOOK_TEST
: # Trigger DEBUG trap
echo "unset:${HOOK_TEST:-notfound}"
BASH

if ! grep -q "immediate:hook_value" "$HOOK_OUT"; then
  echo "ERROR: Hook didn't provide immediate access to variable" >&2
  cat "$HOOK_OUT" >&2
  exit 1
fi

if ! grep -q "changed:changed_value" "$HOOK_OUT"; then
  echo "ERROR: Hook didn't update changed variable" >&2
  cat "$HOOK_OUT" >&2
  exit 1
fi

if ! grep -q "unset:notfound" "$HOOK_OUT"; then
  echo "ERROR: Hook didn't remove unset variable" >&2
  cat "$HOOK_OUT" >&2
  exit 1
fi
echo "✓ Test 6 passed: Shell hooks work correctly" >&2

echo ""
echo "==================================================================" >&2
echo "✅ ALL E2E TESTS PASSED SUCCESSFULLY!" >&2
echo "==================================================================" >&2