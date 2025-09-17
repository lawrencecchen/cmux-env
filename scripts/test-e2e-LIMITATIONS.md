# E2E Tests - Understanding and Usage

## How Shell Hooks Actually Work

After deep investigation, we've discovered how the shell hooks actually function:

### ✅ What Works
1. **Basic envctl operations**: set/get/unset work correctly
2. **Persistence**: Variables persist in the daemon across envctl calls
3. **Lazy daemon startup**: Daemon starts automatically when needed
4. **Concurrent operations**: Multiple envctl calls can run in parallel
5. **Shell hook mechanism**: The `envctl export` command DOES work correctly
6. **Cross-shell propagation**: Variables CAN be shared between shells with proper hook usage

### 🔍 Key Discovery: Interactive vs Non-Interactive Shells

The shell hooks use a **DEBUG trap** that only fires in **interactive shells**:
- In interactive shells (terminal sessions), the DEBUG trap fires before each command
- In non-interactive shells (scripts), the DEBUG trap does NOT fire
- For scripts, you must manually call `__envctl_apply` to load environment variables

### 📝 Correct Usage

#### For Interactive Shells (Terminal)
Add to your `.bashrc` or `.zshrc`:
```bash
export ENVCTL_GEN=0
eval "$(envctl hook bash)"  # or zsh/fish
```
Variables will automatically update before each command.

#### For Shell Scripts
```bash
#!/bin/bash
export ENVCTL_GEN=0
eval "$(envctl hook bash)"

# Manually apply to load current environment
__envctl_apply

# Now variables are available
echo "$MY_VAR"
```

### 🧪 Test Files
- `test-e2e-focused.sh`: Tests core functionality (set/get/unset, persistence, lazy startup)
- `test-e2e-shell-hooks-working.sh`: Tests shell hooks with proper manual apply for scripts

### 🎯 Implementation Details
1. `envctl export bash --since N` returns shell commands to export all variables changed since generation N
2. The hook's `__envctl_apply` function calls this and evaluates the result
3. In interactive shells, DEBUG trap calls `__envctl_apply` automatically
4. In scripts, you must call `__envctl_apply` manually

### ✅ Cross-Shell Propagation DOES Work!
Variables set in one shell ARE visible in other shells when hooks are used correctly:
1. Shell A: `envctl set FOO=bar`
2. Shell B (with hook): Variables are loaded on next command (interactive) or after `__envctl_apply` (script)

The system works as designed - the confusion was about DEBUG trap behavior in non-interactive shells.