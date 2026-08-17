#!/usr/bin/env bash
# voice-lint.mjs — the first thing in this plugin that actually READS voice.md's rules.
#
# Two layers, same split as the validator's suite:
#   (1) The script's own --self-test, WIRED IN rather than re-implemented. It covers the pure
#       lint over text + moment.
#   (2) The PROCESS contract the self-test cannot reach: the stdin payload, the transcript
#       walk, the phase-derived trigger, and the fail-open guarantees.
#
# The property that matters most here is the one that decides whether this control survives
# contact with real use: it must be SILENT on every stop that is not a pipeline voice moment.
# voice.md bans em dashes "anywhere, ever"; a lint enforcing that on ordinary conversation gets
# disabled within a day, and a disabled control is a no-op with extra steps. Several cases
# below exist only to prove the silence.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

LINT="$SCRIPTS_DIR/voice-lint.mjs"
ISSUE=4244

make_temp_project "$ISSUE" || exit 90

TRANSCRIPT="$TEMP_PROJECT/transcript.jsonl"

# write_transcript <text> — one assistant turn carrying <text>
write_transcript() {
  node -e '
    const fs=require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      type:"assistant", message:{content:[{type:"text", text:process.argv[2]}]}
    })+"\n");
  ' "$TRANSCRIPT" "$1"
}

set_phase() { printf '{"current_phase":"%s"}' "$1" > "$TEMP_ISSUE_DIR/status.json"; }

# lint [extra-payload-json] -> RC, ERR
lint() {
  local extra="${1:-}"
  local payload="{\"cwd\":\"$TEMP_PROJECT\",\"transcript_path\":\"$TRANSCRIPT\"$extra}"
  local errf="$TEMP_PROJECT/err.txt"
  printf '%s' "$payload" \
    | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" \
        CLAUDE_PIPELINE_ACTIVE_ISSUE="$ISSUE" node "$LINT" ) 2>"$errf" >/dev/null
  RC=$?
  ERR=$(cat "$errf")
}

GOOD_DECISION='Here is the situation in plain language.

### I need a decision

**What I am asking:** pick one.'

# ---------------------------------------------------------------------------
suite "voice-lint: the pure lint (script self-test, wired in not copied)"

SELFTEST_OUT=$(node "$LINT" --self-test 2>&1)
SELFTEST_RC=$?
assert_eq "the bundled --self-test passes" "$SELFTEST_RC" "0"
assert_contains "and it actually ran its cases (>= 16)" "$SELFTEST_OUT" "16 passed"

# ---------------------------------------------------------------------------
suite "voice-lint: silent everywhere it is not a voice moment"

# THE CASE THIS CONTROL LIVES OR DIES ON. An ordinary turn, mid-implementation, full of em
# dashes. If this ever blocks, the lint is unusable and will be turned off.
set_phase "3-impl"
write_transcript "Refactored the parser — it now handles the nested case — and tests pass."
lint
assert_eq "a NON-voice phase exits 0 even with em dashes" "$RC" "0"
assert_eq "a NON-voice phase says nothing" "$ERR" ""

set_phase "2-review"
write_transcript "Dispatched three reviewers."
lint
assert_eq "another non-voice phase is silent too" "$RC" "0"

rm -f "$TEMP_ISSUE_DIR/status.json"
write_transcript "No pipeline running here — just chatting."
lint
assert_eq "no status.json at all exits 0" "$RC" "0"
assert_eq "no status.json says nothing" "$ERR" ""

# ---------------------------------------------------------------------------
suite "voice-lint: it bites at a real voice moment"

set_phase "2.5-design-owner-decision"
write_transcript "I picked approach B because it is cleaner. Moving on to implementation."
lint
assert_eq "a decision moment with no decision block exits 2" "$RC" "2"
assert_contains "and names the phase" "$ERR" "2.5-design-owner-decision"
assert_contains "and names the missing block" "$ERR" "I need a decision"
assert_contains "and points at voice.md" "$ERR" "voice.md"
assert_contains "and offers the documented bypass" "$ERR" "CLAUDE_HOOK_STOP_SKIP=1"

# CONTROL: the same phase, with the block present, must pass. Without this the case above
# proves only that the lint blocks at this phase, not that it discriminates.
write_transcript "$GOOD_DECISION"
lint
assert_eq "CONTROL: the same moment WITH the block exits 0" "$RC" "0"
assert_eq "CONTROL: and says nothing" "$ERR" ""

write_transcript "$GOOD_DECISION — with an em dash"
lint
assert_eq "an em dash at a voice moment exits 2" "$RC" "2"
assert_contains "and quotes the rule" "$ERR" "em dash"

write_transcript "$GOOD_DECISION

As discussed, this is the same shape as before."
lint
assert_eq "a banned phrase at a voice moment exits 2" "$RC" "2"
assert_contains "and explains why it is banned" "$ERR" "assumes the owner was in the thread"

set_phase "1-ba-open-questions"
write_transcript "BA raised a question about scope. I went with the recommendation."
lint
assert_eq "the open-questions gate is a voice moment too" "$RC" "2"

set_phase "5-complete"
write_transcript "### Done

**Blast radius:** Contained
**Reversibility:** Undo button
**Confidence:** Solid"
lint
assert_eq "a completion report with no replication block exits 2" "$RC" "2"
assert_contains "and names the missing section" "$ERR" "See it yourself"

set_phase "5-complete"
write_transcript "### Done

### See it yourself

Open the page.

**Blast radius:** Contained
**Reversibility:** Undo button
**Confidence:** Solid"
lint
assert_eq "CONTROL: a complete report with scales + replication exits 0" "$RC" "0"

# ---------------------------------------------------------------------------
suite "voice-lint: fail-OPEN guarantees (a voice lint must never wedge a stop)"

set_phase "2.5-design-owner-decision"
write_transcript "no block here"

lint ',"stop_hook_active":true'
assert_eq "stop_hook_active short-circuits (no double-block loop)" "$RC" "0"

printf '%s' 'not json at all' \
  | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$LINT" ) 2>/dev/null >/dev/null
assert_eq "a garbled payload exits 0" "$?" "0"

printf '%s' '{}' \
  | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$LINT" ) 2>/dev/null >/dev/null
assert_eq "an empty payload exits 0" "$?" "0"

printf '{"cwd":"%s","transcript_path":"/nope/missing.jsonl"}' "$TEMP_PROJECT" \
  | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" \
      CLAUDE_PIPELINE_ACTIVE_ISSUE="$ISSUE" node "$LINT" ) 2>/dev/null >/dev/null
assert_eq "an unreadable transcript exits 0" "$?" "0"

printf 'garbage not jsonl\n{"type":"assistant"}\n' > "$TRANSCRIPT"
lint
assert_eq "an unparseable transcript exits 0" "$RC" "0"

# An unrecognised phase passes silently. This is the script's stated KNOWN LIMIT, asserted here
# so it stays a documented choice rather than becoming a surprise: if a phase is renamed and
# VOICE_MOMENTS is not updated, the lint goes quiet rather than loud.
set_phase "9-invented-phase"
write_transcript "no block, em dashes — everywhere"
lint
assert_eq "KNOWN LIMIT: an unrecognised phase is not linted" "$RC" "0"

finish
