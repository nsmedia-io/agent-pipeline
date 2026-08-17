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

# The Stop payload arrives on stdin and carries transcript_path, which the voice lint needs.
# Read it ONCE here: stdin is not re-readable, and the check command below must not inherit it.
PAYLOAD=""
if [[ ! -t 0 ]]; then PAYLOAD=$(cat 2>/dev/null || true); fi

# Opt-out for one-off iterations.
[[ "${CLAUDE_HOOK_STOP_SKIP:-0}" == "1" ]] && exit 0

# Voice lint. Runs BEFORE the project check because it is the cheaper of the two and its
# failure is about the message the owner is about to read, not the code. It self-limits to
# pipeline phases that voice.md calls full-voice moments; every other stop is a silent no-op,
# which is what keeps it from being switched off. Fail-open on any tooling error.
VOICE_LINT="$(dirname "${BASH_SOURCE[0]}")/../scripts/voice-lint.mjs"
if [[ -n "$PAYLOAD" && -f "$VOICE_LINT" ]] && command -v node >/dev/null 2>&1; then
  VOICE_ERR=$(printf '%s' "$PAYLOAD" | node "$VOICE_LINT" 2>&1 >/dev/null)
  VOICE_RC=$?
  if [[ "$VOICE_RC" -eq 2 && -n "$VOICE_ERR" ]]; then
    printf '%s\n' "$VOICE_ERR" >&2
    exit 2
  fi
fi

# Shared config reader (see hooks/lib.sh). A missing lib means a broken install, so no-op
# rather than block a stop: this hook is fail-open by contract.
LIB="$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=./lib.sh
[[ -f "$LIB" ]] && . "$LIB" || exit 0

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
