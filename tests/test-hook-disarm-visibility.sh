#!/usr/bin/env bash
# A pipeline check that cannot run SAYS SO (0.42.x, B2).
#
# Every hook still fails OPEN on tooling: exit 0, never a wedged session. What changed is that the
# fail-open is no longer silent. Each one now writes, through hooks/disarm.sh:
#   - one stderr line  "agent-pipeline <hook>: pipeline check <check> did not run: <reason>"
#   - the same sentence as the hook's JSON systemMessage on stdout (the user-visible channel)
#   - one line in the disarm log, which the next session-start warmup reports once and rotates.
#
# Each cell below is a path that used to exit 0 with nothing on stdout, so every "systemMessage"
# assertion is the control that fails without the change. The silent paths that must STAY silent (a
# project that never ran the pipeline) are pinned alongside.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
require_node

make_temp_project 1 || exit 90
GATE_SCRATCH="$TEMP_PROJECT"
gate_cache_declaration

# repo_with_pipeline -> NEW_TMPDIR: a git repo with a .pipeline dir and a commit
repo_with_pipeline() {
  new_tmpdir || return 90
  git -C "$NEW_TMPDIR" init -q
  git -C "$NEW_TMPDIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$NEW_TMPDIR/.pipeline"
}

# system_message <stdout> -> the systemMessage string, or <none>
system_message() {
  printf '%s' "$1" | node -e '
    let s = ""; process.stdin.on("data", (c) => (s += c)).on("end", () => {
      const line = s.split("\n").filter((l) => l.trim().startsWith("{")).pop();
      if (!line) { process.stdout.write("<none>"); return; }
      try { const o = JSON.parse(line); process.stdout.write(o.systemMessage || "<none>"); }
      catch { process.stdout.write("<unparseable>"); }
    });'
}

# ===============================================================================================
suite "PreToolUse: a CRASHED gate allows the call and says so"
# ===============================================================================================
# The fail-open tail in hooks.json used to be `|| { echo ... >&2; exit 0; }`: stderr only, which a
# PreToolUse hook's user never sees. A plugin root whose gate exits 3 stands in for a crash.
new_tmpdir || exit 90
CRASH_ROOT="$NEW_TMPDIR"
mkdir -p "$CRASH_ROOT/hooks"
printf 'exit 3\n' > "$CRASH_ROOT/hooks/pre-tool-use.sh"
chmod +x "$CRASH_ROOT/hooks/pre-tool-use.sh"
cp "$HOOKS_DIR/disarm.sh" "$CRASH_ROOT/hooks/disarm.sh"
CRASH_LOG="$CRASH_ROOT/disarm.log"
gate_reset_env "$TEMP_PROJECT"
GATE_PLUGIN_ROOT_OVERRIDE="$CRASH_ROOT"
GATE_EXTRA_ENV=("CLAUDE_PIPELINE_DISARM_LOG=$CRASH_LOG")
run_gate "$(gate_payload 'git add -A' agent_id=crash-1 agent_type=pipeline:qa)"
assert_eq "a crashed gate still exits 0 (fail open)" "$GATE_RC" "0"
assert_eq "  ...and denies nothing" "$GATE_DECISION" "none"
assert_contains "  ...but its systemMessage says the check did not run (stdout was empty before B2)" \
  "$(system_message "$GATE_OUT")" "pipeline check pretooluse-gate did not run: the gate exited 3 without a decision"
assert_contains "  ...and so does stderr" "$GATE_ERR" "agent-pipeline PreToolUse: pipeline check pretooluse-gate did not run"
assert_contains "  ...and the disarm log carries it for the next warmup" "$(cat "$CRASH_LOG" 2>/dev/null)" \
  "PreToolUse pipeline check pretooluse-gate did not run"

# CONTROL: with disarm.sh itself missing, the last-resort tail still allows the call.
rm -f "$CRASH_ROOT/hooks/disarm.sh"
gate_reset_env "$TEMP_PROJECT"
GATE_PLUGIN_ROOT_OVERRIDE="$CRASH_ROOT"
run_gate "$(gate_payload 'git add -A' agent_id=crash-2 agent_type=pipeline:qa)"
assert_eq "CONTROL: with disarm.sh missing too, the call is still allowed, exit 0" "$GATE_RC/$GATE_DECISION" "0/none"
assert_contains "CONTROL: via the last-resort stderr line" "$GATE_ERR" "gate unavailable"

# ===============================================================================================
suite "Stop: CLAUDE_HOOK_STOP_SKIP=1 leaves a record"
# ===============================================================================================
repo_with_pipeline || exit 90
SKIP_REPO="$NEW_TMPDIR"
OUT=$(CLAUDE_PROJECT_DIR="$SKIP_REPO" CLAUDE_HOOK_STOP_SKIP=1 bash "$HOOKS_DIR/stop.sh" </dev/null 2>"$SKIP_REPO/err.txt")
RC=$?
assert_eq "the skip still exits 0" "$RC" "0"
assert_contains "its systemMessage names the skip (nothing was said before B2)" "$(system_message "$OUT")" \
  "pipeline check voice-lint and project-check did not run: CLAUDE_HOOK_STOP_SKIP=1 is set"
assert_contains "the default disarm log lives in the git dir, never under .pipeline/" \
  "$(cat "$SKIP_REPO/.git/agent-pipeline-disarm.log" 2>/dev/null)" "CLAUDE_HOOK_STOP_SKIP=1 is set"
assert_eq "  ...so nothing new appears under .pipeline/" "$(ls -A "$SKIP_REPO/.pipeline" | grep -c .)" "0"

# CONTROL: the same repository and no skip, with nothing to check, says nothing.
repo_with_pipeline || exit 90
QUIET_REPO="$NEW_TMPDIR"
OUT=$(CLAUDE_PROJECT_DIR="$QUIET_REPO" bash "$HOOKS_DIR/stop.sh" </dev/null 2>/dev/null)
assert_eq "CONTROL: an ordinary stop with nothing to check prints no systemMessage" "$(system_message "$OUT")" "<none>"
assert_eq "CONTROL: and writes no disarm log" "$([[ -e "$QUIET_REPO/.git/agent-pipeline-disarm.log" ]] && echo written || echo absent)" "absent"

# ===============================================================================================
suite "Stop: the voice lint's did-not-run line reaches the user"
# ===============================================================================================
repo_with_pipeline || exit 90
VOICE_REPO="$NEW_TMPDIR"
write_run_record "$VOICE_REPO/.pipeline/5/status.json" "5-archived"
OUT=$(printf '{"cwd":"%s","transcript_path":"%s/missing.jsonl"}' "$VOICE_REPO" "$VOICE_REPO" \
  | CLAUDE_PROJECT_DIR="$VOICE_REPO" CLAUDE_PIPELINE_ACTIVE_ISSUE=5 bash "$HOOKS_DIR/stop.sh" 2>/dev/null)
assert_contains "an unreadable transcript at a voice moment is reported, not passed in silence" \
  "$(system_message "$OUT")" "pipeline check voice-lint did not run: phase 5-archived is a voice moment but no assistant message text could be read"

# ===============================================================================================
suite "voice-lint.mjs: an unreadable schema is a did-not-run, not a pass"
# ===============================================================================================
new_tmpdir || exit 90
NOSCHEMA="$NEW_TMPDIR"
mkdir -p "$NOSCHEMA/scripts"
cp "$SCRIPTS_DIR"/*.mjs "$SCRIPTS_DIR"/*.json "$NOSCHEMA/scripts/" 2>/dev/null
repo_with_pipeline || exit 90
VL_REPO="$NEW_TMPDIR"
write_run_record "$VL_REPO/.pipeline/5/status.json" "4-review"
VL_ERR=$(printf '{"cwd":"%s"}' "$VL_REPO" | CLAUDE_PIPELINE_ACTIVE_ISSUE=5 node "$NOSCHEMA/scripts/voice-lint.mjs" 2>&1 >/dev/null)
VL_RC=$?
assert_eq "no schema to read -> still exit 0" "$VL_RC" "0"
assert_contains "  ...with one did-not-run line naming the schema (it returned null in silence before B2)" "$VL_ERR" \
  "agent-pipeline voice-lint did not run: schemas/status.schema.json could not be read"
VL_ERR=$(printf '{"cwd":"%s"}' "$VL_REPO" | CLAUDE_PIPELINE_ACTIVE_ISSUE=5 node "$SCRIPTS_DIR/voice-lint.mjs" 2>&1 >/dev/null)
assert_not_contains "CONTROL: the installed copy, which has its schema, says no such thing" "$VL_ERR" "could not be read"

# ===============================================================================================
suite "SubagentStop: each tooling gap says so in a project that runs the pipeline"
# ===============================================================================================
repo_with_pipeline || exit 90
SA_REPO="$NEW_TMPDIR"
OUT=$(printf '{}' | CLAUDE_PROJECT_DIR="$SA_REPO" CLAUDE_PLUGIN_ROOT="" bash "$HOOKS_DIR/subagent-stop.sh" 2>/dev/null)
assert_contains "no plugin root -> systemMessage" "$(system_message "$OUT")" \
  "pipeline check artifact-validator did not run: CLAUDE_PLUGIN_ROOT is not set"
new_tmpdir || exit 90
SA_EMPTY="$NEW_TMPDIR"
OUT=$(printf '{}' | CLAUDE_PROJECT_DIR="$SA_REPO" CLAUDE_PLUGIN_ROOT="$SA_EMPTY" bash "$HOOKS_DIR/subagent-stop.sh" 2>/dev/null)
assert_contains "absent validator -> systemMessage" "$(system_message "$OUT")" \
  "scripts/validate-pipeline-artifact.mjs is not installed"
new_tmpdir || exit 90
SA_CRASH="$NEW_TMPDIR"
mkdir -p "$SA_CRASH/scripts"
printf 'process.exit(1);\n' > "$SA_CRASH/scripts/validate-pipeline-artifact.mjs"
OUT=$(printf '{}' | CLAUDE_PROJECT_DIR="$SA_REPO" CLAUDE_PLUGIN_ROOT="$SA_CRASH" bash "$HOOKS_DIR/subagent-stop.sh" 2>/dev/null)
RC=$?
assert_eq "crashing validator -> still exit 0" "$RC" "0"
assert_contains "crashing validator -> systemMessage naming its exit code" "$(system_message "$OUT")" \
  "scripts/validate-pipeline-artifact.mjs exited 1"
# CONTROL: a project with no .pipeline stays silent on the same gap (the validator's own floor).
new_tmpdir || exit 90
SA_ADHOC="$NEW_TMPDIR"
OUT=$(printf '{}' | CLAUDE_PROJECT_DIR="$SA_ADHOC" CLAUDE_PLUGIN_ROOT="" bash "$HOOKS_DIR/subagent-stop.sh" 2>/dev/null)
assert_eq "CONTROL: no .pipeline -> the same gap stays silent" "$OUT" ""

# ===============================================================================================
suite "SessionStart: reports the disarm log once, and says when the warmup itself cannot run"
# ===============================================================================================
repo_with_pipeline || exit 90
SS_REPO="$NEW_TMPDIR"
printf '%s\n' "2026-09-16T00:00:00Z Stop pipeline check phase-entry-guard did not run: node is not on this hook's PATH" \
  > "$SS_REPO/.git/agent-pipeline-disarm.log"
OUT=$(CLAUDE_PROJECT_DIR="$SS_REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
assert_contains "the warmup reports checks that did not run since the last one" "$OUT" "CHECKS THAT DID NOT RUN since the last warmup (1"
assert_contains "  ...quoting the recorded line" "$OUT" "phase-entry-guard did not run: node is not on this hook's PATH"
assert_eq "  ...and rotates the log so it is reported once" \
  "$([[ -e "$SS_REPO/.git/agent-pipeline-disarm.log" ]] && echo still-there || echo rotated)/$([[ -s "$SS_REPO/.git/agent-pipeline-disarm.log.reported" ]] && echo kept || echo lost)" \
  "rotated/kept"
OUT=$(CLAUDE_PROJECT_DIR="$SS_REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
assert_not_contains "CONTROL: the next warmup does not repeat it" "$OUT" "CHECKS THAT DID NOT RUN"

# lib.sh missing used to exit 0 with NOTHING at all: indistinguishable from a project not using this.
new_tmpdir || exit 90
SS_COPY="$NEW_TMPDIR"
mkdir -p "$SS_COPY/hooks"
cp "$HOOKS_DIR/session-start.sh" "$HOOKS_DIR/disarm.sh" "$SS_COPY/hooks/"
OUT=$(CLAUDE_PROJECT_DIR="$SS_REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SS_COPY/hooks/session-start.sh" 2>/dev/null)
assert_contains "a missing lib.sh -> systemMessage saying the warmup did not run" "$(system_message "$OUT")" \
  "pipeline check warmup did not run: hooks/lib.sh is not installed"

# A non-git directory that carries pipeline state is reported; a bare one stays silent.
new_tmpdir || exit 90
SS_NOGIT="$NEW_TMPDIR"
printf '{}' > "$SS_NOGIT/pipeline.config.json"
OUT=$(CLAUDE_PROJECT_DIR="$SS_NOGIT" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
assert_contains "a non-git dir WITH pipeline.config.json -> systemMessage" "$(system_message "$OUT")" \
  "pipeline check warmup did not run"
new_tmpdir || exit 90
SS_BARE="$NEW_TMPDIR"
OUT=$(CLAUDE_PROJECT_DIR="$SS_BARE" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
assert_eq "CONTROL: a bare non-git dir stays silent" "$OUT" ""

finish
