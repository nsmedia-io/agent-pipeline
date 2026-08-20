#!/usr/bin/env bash
# Stop hook (agent-pipeline plugin). Two blocking steps, in this order: the phase-entry guard
# (a pipeline run may not END a turn at a phase whose prerequisite was never produced), then
# the project check (when a check command is configured AND the tree has uncommitted changes,
# run it and block completion with exit 2 + stderr if it fails, nudging the model to fix rather
# than declare the task done). No-op (exit 0) when neither applies.
#
# FAIL DIRECTION, which is no longer one rule. The project check and the voice lint are
# fail-open throughout: any tooling error is a no-op. The phase-entry guard splits the two
# apart, because they are events in different environments: its DECISION is fail-CLOSED (a
# recognised phase with an absent prerequisite refuses, and that is discretion exercised inside
# the agent session), while its TOOLING stays fail-OPEN (no node, no script, no readable
# record -> exit 0 in silence, because that is the operator's machine and not a decision at
# all). A tooling fail-open is invisible by construction, so hooks/session-start.sh reports a
# disarmed guard once per session.
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

# Phase-entry guard. Placement is a WINDOW, not a floor. It sits BELOW the PAYLOAD read because
# stdin is not re-readable: above it, this step would consume the payload, PAYLOAD would come
# back empty, and the voice lint would be skipped by its own emptiness test with no error
# anywhere. It sits ABOVE every early exit below it, all five of which are states in which a
# turn very commonly ends -- a checkpoint commit leaves the tree CLEAN, and an adopting project
# with no checkCommand and no package.json typecheck script exits before the clean-tree check
# is ever reached, so a guard placed lower would be inert exactly when it matters most.
#
# Only exit code 2 blocks. Its stderr is a fixed template built from the phase table, never
# from status.json's free text, and nothing else this step could print is repeated here.
GATE="$(dirname "${BASH_SOURCE[0]}")/../scripts/gate-phase-entry.mjs"
if [[ -f "$GATE" ]] && command -v node >/dev/null 2>&1; then
  GATE_ERR=$(node "$GATE" --root "$PROJECT_DIR" 2>&1 >/dev/null </dev/null)
  GATE_RC=$?
  if [[ "$GATE_RC" -eq 2 && -n "$GATE_ERR" ]]; then
    printf '%s\n' "$GATE_ERR" >&2
    exit 2
  fi
fi

# CLAUDE_HOOK_STOP_SKIP bypasses the voice lint and the project check for one-off iterations,
# but NOT the phase-entry guard, which sits above this line and can still exit 2: an
# environment variable that disarms a halting control leaves no trace in the archived run
# record, and this repo has already refused that shape twice.
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
