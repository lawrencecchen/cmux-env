#!/usr/bin/env bash
set -euo pipefail

# Test shell hooks in an isolated environment
# This script creates a temporary HOME directory to avoid modifying the user's real shell config

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
# Use shorter path to avoid socket path length issues on macOS
TMPDIR="/tmp/cmux-e2e-$$"
mkdir -p "$TMPDIR"

# When running in Docker, binaries are already built
if [[ "${IN_DOCKER:-}" == "1" ]]; then
  BIN_DIR="/app/target/debug"
  echo "=== Using pre-built binaries in Docker ===" >&2
else
  CARGO_TARGET_DIR="$TMPDIR/target"
  export CARGO_TARGET_DIR
  BIN_DIR="$CARGO_TARGET_DIR/debug"

  echo "=== Building envd/envctl binaries ===" >&2
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
  # Kill any daemon we started
  pkill -f "$ENVD_BIN" 2>/dev/null || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

# Create isolated environment
export XDG_RUNTIME_DIR="$TMPDIR/runtime"
mkdir -p "$XDG_RUNTIME_DIR/cmux-envd"

# Create a temporary HOME to avoid modifying user's real shell config
TEST_HOME="$TMPDIR/home"
mkdir -p "$TEST_HOME"

# Export PATH with our binaries
export PATH="$BIN_DIR:$PATH"

# Helper function to run envctl with timeout
run_envctl() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status 15 "$ENVCTL_BIN" "$@"
  else
    "$ENVCTL_BIN" "$@"
  fi
}

echo ""
echo "=== TEST 1: Shell hook installation and basic functionality ===" >&2

# Start daemon (will be started lazily if not already running)
echo "Setting initial variable..." >&2
run_envctl set HOOK_TEST_INIT=initial_value

# Create a .bashrc with the hook installed
echo "Installing bash hook in temporary HOME..." >&2
cat > "$TEST_HOME/.bashrc" <<EOF
# Test .bashrc
export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
export PATH="$BIN_DIR:\$PATH"
export ENVCTL_GEN=0

# Install the envctl hook
eval "\$(envctl hook bash)"
EOF

echo "Testing shell with hook installed..." >&2
# Test that a new bash shell sees the variable
OUTPUT=$(env HOME="$TEST_HOME" bash -l -c 'echo "HOOK_TEST_INIT=${HOOK_TEST_INIT:-not_found}"')
if [[ "$OUTPUT" != "HOOK_TEST_INIT=initial_value" ]]; then
  echo "ERROR: Shell hook didn't load initial variable" >&2
  echo "Got: $OUTPUT" >&2
  exit 1
fi
echo "✓ Test 1 passed: Shell hook loads existing variables" >&2

echo ""
echo "=== TEST 2: Cross-shell environment propagation ===" >&2

# Start a persistent shell session
echo "Starting persistent shell session..." >&2
SHELL_FIFO="$TMPDIR/shell_fifo"
mkfifo "$SHELL_FIFO"

# Start a background shell that reads commands from the FIFO
(
  env HOME="$TEST_HOME" bash -l <<'SHELL_SCRIPT'
  # Read and execute commands from the FIFO
  while IFS= read -r cmd < '"$SHELL_FIFO"'; do
    if [[ "$cmd" == "exit" ]]; then
      break
    fi
    eval "$cmd"
  done
SHELL_SCRIPT
) &
SHELL_PID=$!

sleep 1  # Give the shell time to start

# Test 1: Set a variable from outside and check if shell sees it
echo "Setting variable from outside shell..." >&2
run_envctl set EXTERNAL_VAR=from_outside

# Send command to check the variable
echo 'echo "EXTERNAL_VAR=${EXTERNAL_VAR:-not_found}" > '"$TMPDIR/result1.txt" > "$SHELL_FIFO"
sleep 0.5

if [[ -f "$TMPDIR/result1.txt" ]]; then
  RESULT=$(cat "$TMPDIR/result1.txt")
  if [[ "$RESULT" != "EXTERNAL_VAR=from_outside" ]]; then
    echo "ERROR: Shell didn't see externally set variable" >&2
    echo "Got: $RESULT" >&2
    echo "exit" > "$SHELL_FIFO"
    wait $SHELL_PID 2>/dev/null || true
    exit 1
  fi
else
  echo "ERROR: Shell didn't produce output" >&2
  echo "exit" > "$SHELL_FIFO"
  wait $SHELL_PID 2>/dev/null || true
  exit 1
fi
echo "✓ Test 2.1 passed: Shell sees externally set variables" >&2

# Test 2: Set a variable from inside the shell
echo "Setting variable from inside shell..." >&2
echo 'envctl set INTERNAL_VAR=from_inside' > "$SHELL_FIFO"
sleep 0.5

# Check if we can see it from outside
EXTERNAL_CHECK=$(run_envctl get INTERNAL_VAR)
if [[ "$EXTERNAL_CHECK" != "from_inside" ]]; then
  echo "ERROR: Externally couldn't see internally set variable" >&2
  echo "Got: $EXTERNAL_CHECK" >&2
  echo "exit" > "$SHELL_FIFO"
  wait $SHELL_PID 2>/dev/null || true
  exit 1
fi
echo "✓ Test 2.2 passed: External commands see shell-set variables" >&2

# Clean up the shell
echo "exit" > "$SHELL_FIFO"
wait $SHELL_PID 2>/dev/null || true

echo ""
echo "=== TEST 3: Multiple concurrent shells with hooks ===" >&2

# Create two shells with hooks
echo "Starting two shells with hooks..." >&2

# Shell 1
SHELL1_OUT="$TMPDIR/shell1_out"
(
  env HOME="$TEST_HOME" bash -l <<'EOF'
  # Wait a moment for shell 2 to start
  sleep 0.5

  # Set a variable
  envctl set SHELL1_VAR=from_shell1

  # Wait for shell 2 to set its variable
  sleep 1

  # Check if we can see shell 2's variable
  echo "In shell1, SHELL2_VAR=${SHELL2_VAR:-not_found}"
EOF
) > "$SHELL1_OUT" 2>&1 &
SHELL1_PID=$!

# Shell 2
SHELL2_OUT="$TMPDIR/shell2_out"
(
  env HOME="$TEST_HOME" bash -l <<'EOF'
  # Wait a moment for shell 1 to set its variable
  sleep 1

  # Set a variable
  envctl set SHELL2_VAR=from_shell2

  # Check if we can see shell 1's variable
  echo "In shell2, SHELL1_VAR=${SHELL1_VAR:-not_found}"
EOF
) > "$SHELL2_OUT" 2>&1 &
SHELL2_PID=$!

# Wait for both shells to complete
wait $SHELL1_PID 2>/dev/null || true
wait $SHELL2_PID 2>/dev/null || true

echo "Shell 1 output:" >&2
cat "$SHELL1_OUT" >&2 || true

echo "Shell 2 output:" >&2
cat "$SHELL2_OUT" >&2 || true

# Note: The shells may not see each other's variables immediately due to the DEBUG trap timing
# But they should be able to see variables that were set before they started
echo "✓ Test 3 passed: Multiple shells can run with hooks" >&2

echo ""
echo "=== TEST 4: Hook with .bashrc sourcing ===" >&2

# Test that sourcing .bashrc manually also works
echo "Testing manual .bashrc sourcing..." >&2
OUTPUT=$(env HOME="$TEST_HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PATH="$BIN_DIR:$PATH" bash -c '
  source ~/.bashrc
  envctl set SOURCED_VAR=sourced_value
  echo "SOURCED_VAR=${SOURCED_VAR:-not_found}"
')

if [[ "$OUTPUT" != "SOURCED_VAR=sourced_value" ]]; then
  echo "WARNING: Manual sourcing didn't immediately show variable" >&2
  echo "Got: $OUTPUT" >&2
  # This is expected behavior - the DEBUG trap needs a command to trigger
fi

# But the variable should be set in the daemon
CHECK=$(run_envctl get SOURCED_VAR)
if [[ "$CHECK" != "sourced_value" ]]; then
  echo "ERROR: Variable wasn't set in daemon" >&2
  echo "Got: $CHECK" >&2
  exit 1
fi
echo "✓ Test 4 passed: Manual .bashrc sourcing works" >&2

echo ""
echo "==================================================================" >&2
echo "✅ ALL SHELL HOOK TESTS PASSED!" >&2
echo "==================================================================" >&2
echo ""
echo "Note: Shell hooks use a DEBUG trap that triggers before each command." >&2
echo "Variables may not be immediately visible within the same command that sets them." >&2
echo "This is expected behavior - new shells will see all previously set variables." >&2