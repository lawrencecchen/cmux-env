#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for the Docker demo image. Starts envd, prints docs, and
# launches an interactive shell (bash/zsh/fish) with envctl hooks installed.

TARGET_DIR="/usr/local/bin"
ENVD_BIN="$TARGET_DIR/envd"
ENVCTL_BIN="$TARGET_DIR/envctl"

if [[ ! -x "$ENVD_BIN" || ! -x "$ENVCTL_BIN" ]]; then
  echo "envd/envctl not found in $TARGET_DIR" >&2
  exit 1
fi

RUNTIME_DIR="/tmp/cmux-demo-$$"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR/cmux-envd"

"$ENVD_BIN" >/dev/null 2>&1 &
DAEMON_PID=$!

cleanup() {
  if kill -0 "$DAEMON_PID" >/dev/null 2>&1; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$RUNTIME_DIR"
}
trap cleanup EXIT INT TERM

export PATH="$TARGET_DIR:$PATH"
export ENVCTL_GEN=0

cat <<'DOC'
=== cmux-env demo (Docker) ===

You are in a container with:
  - envd running per-user on a private runtime dir
  - envctl on PATH
  - shell hook installed to apply diffs on each prompt

Try these:
  envctl ping
  envctl status
  envctl set FOO=bar
  envctl export bash --since "${ENVCTL_GEN:-0}" --pwd "$PWD"
  envctl unset FOO

Directory-scoped overlay:
  mkdir -p demo/proj/sub && cd demo
  envctl set VAR=global
  envctl set VAR=local --dir "$PWD/proj"
  cd proj/sub   # prompt hook should export VAR=local
  cd ../..      # prompt hook should export VAR=global

Bulk load from stdin:
  printf "%s\n" "A=1" "B=2" | envctl load -
  envctl list

Note: Use literal keys. For example, 'envctl get FOO' not 'envctl get $FOO'.
Exit this shell to stop the daemon and container.
DOC

SHELL_KIND="${DEMO_SHELL:-bash}"
case "$SHELL_KIND" in
  bash)
    # Persist hook in ~/.bashrc so new shells/tmux windows inherit it
    if ! grep -q "^# >>> envctl hook >>>" "$HOME/.bashrc" 2>/dev/null; then
      {
        echo "# >>> envctl hook >>>"
        echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""
        echo 'export ENVCTL_GEN=${ENVCTL_GEN:-0}'
        "$ENVCTL_BIN" hook bash
        echo "# <<< envctl hook <<<"
      } >> "$HOME/.bashrc"
    fi
    # Ensure PATH contains /usr/local/bin
    if ! grep -q "/usr/local/bin" "$HOME/.bashrc"; then
      echo 'export PATH="/usr/local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    # Also force-load a custom rcfile for the current shell so hook is active immediately
    RCFILE="/tmp/envctl-bashrc.$$"
    {
      echo "# envctl demo rc"
      echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""
      echo 'export ENVCTL_GEN=${ENVCTL_GEN:-0}'
      echo 'export PATH="/usr/local/bin:$PATH"'
      echo 'source "$HOME/.bashrc" >/dev/null 2>&1 || true'
      "$ENVCTL_BIN" hook bash
    } > "$RCFILE"
    exec bash --noprofile --rcfile "$RCFILE" -i
    ;;
  zsh)
    # Persist hook in ~/.zshrc
    if ! grep -q "^# >>> envctl hook >>>" "$HOME/.zshrc" 2>/dev/null; then
      {
        echo "# >>> envctl hook >>>"
        echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""
        echo 'export ENVCTL_GEN=${ENVCTL_GEN:-0}'
        "$ENVCTL_BIN" hook zsh
        echo "# <<< envctl hook <<<"
      } >> "$HOME/.zshrc"
    fi
    # Ensure PATH contains /usr/local/bin
    if ! grep -q "/usr/local/bin" "$HOME/.zshrc"; then
      echo 'export PATH="/usr/local/bin:$PATH"' >> "$HOME/.zshrc"
    fi
    exec zsh -i
    ;;
  fish)
    # Persist hook in fish config
    mkdir -p "$HOME/.config/fish"
    if ! grep -q "^# >>> envctl hook >>>" "$HOME/.config/fish/config.fish" 2>/dev/null; then
      {
        echo "# >>> envctl hook >>>"
        echo 'set -gx XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR"'
        echo 'set -gx ENVCTL_GEN 0'
        "$ENVCTL_BIN" hook fish
        echo "# <<< envctl hook <<<"
      } >> "$HOME/.config/fish/config.fish"
    fi
    # Ensure PATH contains /usr/local/bin
    if ! grep -q "/usr/local/bin" "$HOME/.config/fish/config.fish"; then
      echo 'set -gx PATH "/usr/local/bin" $PATH' >> "$HOME/.config/fish/config.fish"
    fi
    export XDG_CONFIG_HOME="$HOME/.config"
    exec fish -i
    ;;
  *)
    echo "Unknown DEMO_SHELL '$SHELL_KIND', falling back to bash." >&2
    if ! grep -q "^# >>> envctl hook >>>" "$HOME/.bashrc" 2>/dev/null; then
      {
        echo "# >>> envctl hook >>>"
        echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""
        echo 'export ENVCTL_GEN=${ENVCTL_GEN:-0}'
        "$ENVCTL_BIN" hook bash
        echo "# <<< envctl hook <<<"
      } >> "$HOME/.bashrc"
    fi
    exec bash -i
    ;;
esac
