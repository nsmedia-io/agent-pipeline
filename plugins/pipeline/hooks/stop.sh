#!/usr/bin/env bash
# Stop hook (agent-pipeline plugin). When the project defines a check command AND the working
# tree has uncommitted changes, run the check; block completion (exit 2 + stderr) if it fails,
# nudging the model to fix rather than declare the task done. No-op (exit 0) when no check is
# configured. Fail-open on any tooling error.
#
# Deliberately `set -u` only (NOT -e / pipefail): the check's exit code is handled explicitly,
# and an early abort would defeat the block-on-failure behavior.

set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# The app-inherited PATH can carry a stale nvm Node (v16) ahead of everything, breaking
# pnpm-based checks in repos that require modern Node. Prefer the NEWEST installed nvm
# Node explicitly; harmless no-op when nvm is absent.
if [[ -d "$HOME/.nvm/versions/node" ]]; then
  NEWEST_NODE=$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)
  [[ -n "$NEWEST_NODE" ]] && export PATH="$HOME/.nvm/versions/node/$NEWEST_NODE/bin:$PATH"
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Opt-out for one-off iterations.
[[ "${CLAUDE_HOOK_STOP_SKIP:-0}" == "1" ]] && exit 0

read_config() {
  local key="$1" default="${2:-}" file="$PROJECT_DIR/pipeline.config.json" val=""
  [[ -f "$file" ]] || { printf '%s' "$default"; return; }
  val=$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/')
  [[ -n "$val" ]] && printf '%s' "$val" || printf '%s' "$default"
}

# CUSTOMIZE: set "checkCommand" in pipeline.config.json to your verify command, e.g.
#   "npm run typecheck && npm test && npm run lint"
# Fallback: if unset but package.json declares a "typecheck" script, run `npm run typecheck`.
# If neither is available, this hook is a no-op.
CHECK="$(read_config checkCommand "")"
if [[ -z "$CHECK" ]]; then
  if [[ -f package.json ]] && grep -q '"typecheck"' package.json 2>/dev/null && command -v npm >/dev/null 2>&1; then
    CHECK="npm run typecheck"
  else
    exit 0
  fi
fi

# Only verify when there is something uncommitted to verify.
[[ -n "$(git status --porcelain 2>/dev/null)" ]] || exit 0

LOG=$(mktemp)
if bash -c "$CHECK" >"$LOG" 2>&1; then
  rm -f "$LOG"
  exit 0
fi

# Check failed: block completion and feed the model the tail of the output.
{
  echo "Stop hook blocked completion: project check failed."
  echo "Command: $CHECK"
  echo "Uncommitted changes require a passing check before stopping."
  echo ""
  echo "--- tail of check output ---"
  tail -30 "$LOG"
  echo "--- end ---"
  echo ""
  echo "To bypass for one-off iterations: CLAUDE_HOOK_STOP_SKIP=1"
} >&2
rm -f "$LOG"
exit 2
