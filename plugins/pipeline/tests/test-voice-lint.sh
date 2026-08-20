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
assert_contains "and it actually ran its cases (22)" "$SELFTEST_OUT" "22 passed"

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

set_phase "5-archived"
write_transcript "### Done

**Blast radius:** Contained
**Reversibility:** Undo button
**Confidence:** Solid"
lint
assert_eq "a completion report with no replication block exits 2" "$RC" "2"
assert_contains "and names the missing section" "$ERR" "See it yourself"

set_phase "5-archived"
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

# A well-formed but unlisted phase passes silently. That is the residual limit, and the drift
# suite below is what keeps it from mattering: a phase can only reach this state by existing in
# pipeline.md and being absent from BOTH tables, which the drift check fails on.
set_phase "3-invented-phase"
write_transcript "no block, em dashes — everywhere"
lint
assert_eq "RESIDUAL LIMIT: a well-formed unlisted phase is not linted" "$RC" "0"

# ---------------------------------------------------------------------------
suite "voice-lint: status.json current_phase shape (nothing else validates this file)"

# status.json is written by the ORCHESTRATOR, so SubagentStop never sees it; it is in no
# AGENT_RULES entry; and the schema walker does not implement `pattern`. Its one constraint has
# never been enforced anywhere. It matters here because a malformed phase matches no table entry
# and would make the voice check go SILENT instead of loud.
set_phase "Phase_Three"
write_transcript "anything at all"
lint
assert_eq "a malformed current_phase exits 2" "$RC" "2"
assert_contains "and quotes the offending value" "$ERR" "Phase_Three"
assert_contains "and names the schema it violates" "$ERR" "status.schema.json"
assert_contains "and says why silence would be the alternative" "$ERR" "silently disables"

# CONTROL: the shape check must accept every phase string the orchestrator legitimately writes,
# or it would block every run rather than the malformed ones. The message used here satisfies
# EVERY moment type at once (decision block, all three scales, replication block), so a non-zero
# result can only come from the phase shape and never from the voice rules. An earlier version
# of this loop compared $RC to $RC and could not fail; this one can.
ALL_SHAPES='### I need a decision

**What I am asking:** pick one.

### See it yourself

Open the page.

**Blast radius:** Contained
**Reversibility:** Undo button
**Confidence:** Solid'

for good in "3-impl" "2.5-design-owner-decision" "0.5-map" "halted-error" "5-archived" "4-review-complete"; do
  set_phase "$good"
  write_transcript "$ALL_SHAPES"
  lint
  assert_eq "CONTROL: '$good' passes the shape check" "$RC" "0"
done

# ---------------------------------------------------------------------------
suite "voice-lint: the table cannot drift from pipeline.md (config-derived)"

# The first VOICE_MOMENTS table was written from memory and invented FOUR phases no checkpoint
# writes, so those checks could never fire while the real completion report went uncovered.
# This derives the truth from pipeline.md rather than trusting the table, per evidence.md rule
# 19: build the expected set from CONFIGURATION, not from what has been observed.
PIPELINE_MD="$PLUGIN_ROOT/commands/pipeline.md"
LINT_SRC="$SCRIPTS_DIR/voice-lint.mjs"

UNACCOUNTED=""
while IFS= read -r phase; do
  [[ -z "$phase" || "$phase" == *"<"* ]] && continue   # skip the <phase>-error template
  grep -q "\"$phase\"" "$LINT_SRC" || UNACCOUNTED="$UNACCOUNTED $phase"
done < <(grep -o 'current_phase: *"[^"]*"' "$PIPELINE_MD" | sed 's/.*"\(.*\)"/\1/' | sort -u)

assert_eq "every phase pipeline.md writes is accounted for in voice-lint.mjs" \
  "${UNACCOUNTED# }" ""

# CONTROL: the derivation must actually find phases, or an empty result would "pass" vacuously
# (rule 19's own trap: a check over an empty set reports success).
PHASE_COUNT=$(grep -o 'current_phase: *"[^"]*"' "$PIPELINE_MD" | sed 's/.*"\(.*\)"/\1/' | sort -u | wc -l | tr -d ' ')
assert_eq "CONTROL: the phase derivation is non-empty (found $PHASE_COUNT)" \
  "$([ "$PHASE_COUNT" -ge 20 ] && echo many || echo "too few: $PHASE_COUNT")" "many"

# CONTROL: a phase that exists in NEITHER table must be detectable by the same grep, or the
# check above proves only that grep runs.
grep -q '"9-does-not-exist"' "$LINT_SRC" \
  && assert_eq "CONTROL: the drift grep can report a miss" "found" "not found" \
  || assert_eq "CONTROL: the drift grep can report a miss" "not found" "not found"

# ---------------------------------------------------------------------------
suite "voice-lint: exp-<slug> runs are LINTED, not exempt"
# ---------------------------------------------------------------------------
# voice-lint.mjs used to declare its OWN issue-dir pattern, /^\d+$/, so resolveStatus could not
# see an experiment run at all: no active issue, no phase, no lint. The control went quiet on
# exactly the runs nobody is watching, and it did so silently -- the same defect shape, in a
# third copy of the same vocabulary, that widening the validator's pattern already fixed for
# artifact validation and that AC17 in test-gate-phase-entry.sh pins for the phase-entry guard
# ("exp-<slug> runs are GUARDED, not exempt"). The pattern is now IMPORTED from the validator,
# so these cases also stand as the behavioural witness that the import is wired up.
#
# This block deliberately runs LAST: it repoints TEMP_PROJECT/TEMP_ISSUE_DIR/TRANSCRIPT at a
# fresh root whose only issue dir is an exp- one, which would break the cases above if it ran
# before them.
EXP_SLUG="exp-two-owner-gates"
make_temp_project "$EXP_SLUG" || exit 90
TRANSCRIPT="$TEMP_PROJECT/transcript.jsonl"

# NO active-issue signal, because that is the shape production runs in: the Stop payload does
# not carry one, so the mtime scan is the branch that has to admit an exp- dir. Both signal
# names are unset around the CHILD, never around the assertion.
exp_lint_nosignal() {
  local errf="$TEMP_PROJECT/err.txt"
  printf '%s' "{\"cwd\":\"$TEMP_PROJECT\",\"transcript_path\":\"$TRANSCRIPT\"}" \
    | ( cd "$TEMP_PROJECT" && env -u CLAUDE_PIPELINE_ACTIVE_ISSUE -u PIPELINE_ACTIVE_ISSUE \
        CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$LINT" ) 2>"$errf" >/dev/null
  RC=$?
  ERR=$(cat "$errf")
}

# The OTHER branch: the explicit signal is regex-tested against the same vocabulary, so a
# numeric-only pattern rejected an exp- signal too. Widening one branch and not the other would
# pass every case above.
exp_lint_signal() {
  local errf="$TEMP_PROJECT/err.txt"
  printf '%s' "{\"cwd\":\"$TEMP_PROJECT\",\"transcript_path\":\"$TRANSCRIPT\"}" \
    | ( cd "$TEMP_PROJECT" && env CLAUDE_PIPELINE_ACTIVE_ISSUE="$EXP_SLUG" \
        CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$LINT" ) 2>"$errf" >/dev/null
  RC=$?
  ERR=$(cat "$errf")
}

set_phase "2.5-design-owner-decision"
write_transcript "I picked approach B because it is cleaner. Moving on to implementation."
exp_lint_nosignal
assert_eq "an exp- run at a decision moment is LINTED (mtime path) and exits 2" "$RC" "2"
assert_contains "and names the phase" "$ERR" "2.5-design-owner-decision"

exp_lint_signal
assert_eq "and the explicit-signal branch admits an exp- slug too" "$RC" "2"
assert_contains "and names the phase" "$ERR" "2.5-design-owner-decision"

# CONTROL, on the same exp- root: a compliant message is silent. Without it these cases would
# pass just as well against a lint that had started reddening everything, and "exp- is no
# longer exempt" would be indistinguishable from "exp- is now always refused".
write_transcript "$GOOD_DECISION"
exp_lint_nosignal
assert_eq "CONTROL: the same exp- moment WITH the decision block exits 0" "$RC" "0"
assert_eq "CONTROL: and says nothing" "$ERR" ""

# CONTROL: the exemption was phase-blind, so prove the lint still discriminates BY PHASE inside
# an exp- dir rather than simply biting on every exp- run it can now see.
set_phase "3-impl"
write_transcript "Refactored the parser — it now handles the nested case — and tests pass."
exp_lint_nosignal
assert_eq "CONTROL: a NON-voice phase in an exp- dir is still silent, em dashes and all" "$RC" "0"

finish
