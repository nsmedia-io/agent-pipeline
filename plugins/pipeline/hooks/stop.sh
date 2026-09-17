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
# the agent session), while its TOOLING stays fail-OPEN (no node, no script, a crashed guard ->
# exit 0, because that is the operator's machine and not a decision at all). A tooling fail-open
# is no longer silent: each one records "pipeline check X did not run: reason" through
# hooks/disarm.sh (stderr, the user-visible systemMessage, and the disarm log that
# hooks/session-start.sh reports at the next warmup), and session-start.sh still reports a
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

# A CHECK THAT CANNOT RUN SAYS SO (0.42.x, B2). Every tooling fail-open below still exits 0, but it
# now records one "pipeline check X did not run: reason" line: on stderr, in the disarm log the
# next warmup reports, and as this hook's JSON systemMessage, printed ONCE on a 0 exit by the trap.
# A missing disarm.sh is itself a broken install, so the fallback keeps the stderr line alone.
DISARM_LIB="$(dirname "${BASH_SOURCE[0]}")/disarm.sh"
if [[ -f "$DISARM_LIB" ]]; then
  DISARM_SOURCED=1
  # shellcheck source=./disarm.sh
  . "$DISARM_LIB"
else
  disarm_record() { printf 'agent-pipeline %s: pipeline check %s did not run: %s\n' "$1" "$2" "$3" >&2; }
  disarm_flush() { :; }
fi
_stop_exit() {
  local rc=$?
  [[ "$rc" -eq 0 ]] && disarm_flush
  return 0
}
trap _stop_exit EXIT

cd "$PROJECT_DIR" 2>/dev/null || {
  disarm_record Stop "stop-hook" "the project directory $PROJECT_DIR could not be entered"
  exit 0
}
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
# Only a project that runs the pipeline has a guard or a voice check worth announcing the loss of.
PIPELINE_PRESENT=0
[[ -d "$PROJECT_DIR/.pipeline" ]] && PIPELINE_PRESENT=1

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
  # A guard that exited with neither a decision (0) nor a refusal (2) crashed. Its own text is NOT
  # republished: stderr from this step is read as a refusal, and a stack trace is not one.
  if [[ "$GATE_RC" -ne 0 && "$PIPELINE_PRESENT" -eq 1 ]]; then
    disarm_record Stop "phase-entry-guard" "scripts/gate-phase-entry.mjs exited $GATE_RC without a decision"
  fi
elif [[ "$PIPELINE_PRESENT" -eq 1 ]]; then
  if [[ ! -f "$GATE" ]]; then
    disarm_record Stop "phase-entry-guard" "scripts/gate-phase-entry.mjs is not installed"
  else
    disarm_record Stop "phase-entry-guard" "node is not on this hook's PATH"
  fi
fi

# CLAUDE_HOOK_STOP_SKIP bypasses the voice lint and the project check for one-off iterations,
# but NOT the phase-entry guard, which sits above this line and can still exit 2: an
# environment variable that disarms a halting control leaves no trace in the archived run
# record, and this repo has already refused that shape twice. The skip itself now leaves a trace:
# it is recorded in the disarm log, which the next session-start warmup reports.
#
# ONCE PER SESSION. The skip is an environment variable, so it is set for every Stop of the session;
# recording each one would repeat the same line after every turn and train the reader to skip it.
# The session_id from the Stop payload is remembered beside the disarm log, and a Stop in a session
# already recorded exits 0 in silence. A payload with no readable session_id records every time,
# which is the loud direction.
if [[ "${CLAUDE_HOOK_STOP_SKIP:-0}" == "1" ]]; then
  SKIP_SESSION=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  SKIP_LOG=$(disarm_log_path 2>/dev/null || true)
  SKIP_MARK=""
  [[ -n "$SKIP_LOG" ]] && SKIP_MARK="$(dirname "$SKIP_LOG")/agent-pipeline-stop-skip.session"
  if [[ -n "$SKIP_SESSION" && -n "$SKIP_MARK" && "$(cat "$SKIP_MARK" 2>/dev/null)" == "$SKIP_SESSION" ]]; then
    exit 0
  fi
  disarm_record Stop "voice-lint and project-check" "CLAUDE_HOOK_STOP_SKIP=1 is set"
  if [[ -n "$SKIP_SESSION" && -n "$SKIP_MARK" ]]; then
    printf '%s' "$SKIP_SESSION" > "$SKIP_MARK" 2>/dev/null || true
  fi
  exit 0
fi

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
  # voice-lint.mjs reports its own did-not-run cases as one prefixed stderr line at exit 0; any
  # other non-zero exit is a crash of the lint itself.
  VOICE_SKIP_PREFIX="agent-pipeline voice-lint did not run: "
  if [[ "$VOICE_RC" -eq 0 && "$PIPELINE_PRESENT" -eq 1 && "$VOICE_ERR" == "$VOICE_SKIP_PREFIX"* ]]; then
    VOICE_REASON="${VOICE_ERR#"$VOICE_SKIP_PREFIX"}"
    disarm_record Stop "voice-lint" "${VOICE_REASON%%$'\n'*}"
  elif [[ "$VOICE_RC" -ne 0 && "$VOICE_RC" -ne 2 && "$PIPELINE_PRESENT" -eq 1 ]]; then
    disarm_record Stop "voice-lint" "scripts/voice-lint.mjs exited $VOICE_RC without a verdict"
  fi
elif [[ -n "$PAYLOAD" && "$PIPELINE_PRESENT" -eq 1 ]]; then
  if [[ ! -f "$VOICE_LINT" ]]; then
    disarm_record Stop "voice-lint" "scripts/voice-lint.mjs is not installed"
  else
    disarm_record Stop "voice-lint" "node is not on this hook's PATH"
  fi
fi

# Shared config reader (see hooks/lib.sh). A missing lib means a broken install, so no-op
# rather than block a stop: this hook is fail-open by contract, and it says so.
LIB="$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [[ -f "$LIB" ]]; then
  # shellcheck source=./lib.sh
  . "$LIB"
else
  disarm_record Stop "project-check" "hooks/lib.sh is not installed"
  exit 0
fi

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
