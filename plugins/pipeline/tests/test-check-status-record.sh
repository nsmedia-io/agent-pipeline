#!/usr/bin/env bash
# scripts/check-status-record.mjs: the WRITE-TIME honorer of status.json's verdict cap (#117).
#
# WHAT #117 IS. The cap was declared in status.schema.json and restated as prose in
# commands/pipeline.md, and nothing ran at write time. The only reader was
# test-status-schema-contract.sh's corpus walk, in CI, AFTER the violating record is in
# history. It fired twice in one run: seven labels up to 44 chars accumulated across phases
# unnoticed, and then a 33-char label was fixed in a worktree (6eefeb6) and silently
# reintroduced when a routine `cp` from a stale checkout overwrote the fixed copy (adce70c).
#
# THE SECOND OCCURRENCE IS WHY THIS SUITE ASSERTS OVER FILE CONTENT AND NEVER OVER A DIFF. A
# check keyed to "the value you just typed" catches a typo and misses a clobber. The cell named
# THE CLOBBER below is the regression test for that: the same fixed-then-overwritten sequence,
# run through the checker at each step.
#
# THE CAP IS NEVER COPIED INTO THIS FILE. Two sites hold the literal 32, both pinning the value
# ruled in #34, both asserted against the number READ OUT OF the schema by the script under
# test. Every behavioral cell derives its fixture length from that number, so raising the cap in
# the schema moves this suite through the script rather than through a pin. A test carrying its
# own 32 would stay green while the two drifted apart -- the class #74 filed over a different
# constant.
#
# SCOPE, and it is a refusal as much as a coverage statement: the verdict TOKEN fields only.
# #52 ruled that the instrument for events[].note, flags[].summary, veto_reason and error is
# CONTENT, not length, and that a cap would refuse correct work (a 600-char note recording a
# live reproduction). The FREE TEXT suite below is the ratchet on that: it feeds the checker a
# record whose free-text fields are enormous and requires exit 0.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
SCHEMA="$PLUGIN_DIR/schemas/status.schema.json"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"
CHECKER="$SCRIPTS_DIR/check-status-record.mjs"

# ---------------------------------------------------------------------------
# Fixture builders. A record is built by LENGTH, never by a hand-typed string, so a cap change
# moves the fixtures with it.
# ---------------------------------------------------------------------------

# verdict_of <n> -> an n-character token
verdict_of() { node -e 'process.stdout.write("V".repeat(Number(process.argv[1])))' "$1"; }

# status_body <events-verdict> <flags-verdict> -> a status.json body. An empty argument omits
# the verdict key entirely rather than writing "", a different (and schema-valid) case. NOT
# named `record`: harness.sh already owns that name for its counted-but-claimless reporting
# line, and shadowing it would silently turn every `record` call in a sourced helper into a
# fixture build.
status_body() {
  node -e '
    const ev = { phase: "4-review", at: "2026-01-01T00:00:00Z" };
    const fl = { phase: "4-review", agent: "qa", at: "2026-01-01T00:00:00Z" };
    if (process.argv[1] !== "") ev.verdict = process.argv[1];
    if (process.argv[2] !== "") fl.verdict = process.argv[2];
    process.stdout.write(JSON.stringify({
      current_phase: "4-review", started_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z", branch: "fix/117", events: [ev], flags: [fl],
    }));
  ' "$1" "$2"
}

# write_root <events-verdict> <flags-verdict> -> NEW_TMPDIR holding .pipeline/117/status.json
write_root() {
  new_tmpdir || return 90
  mkdir -p "$NEW_TMPDIR/.pipeline/117"
  status_body "$1" "$2" > "$NEW_TMPDIR/.pipeline/117/status.json"
}

# run_checker <root> [args...] -> "<exit>|<stdout+stderr on one line>"
# The exit STATUS is the verdict this script exists to deliver, so it is captured in the same
# value as the output: a cell that asserted only on the text would pass on a checker that
# printed a refusal and exited 0, which is the shape that ships a control nobody can fail on.
run_checker() {
  local root="$1"; shift
  local out rc
  out="$( cd "$root" && node "$CHECKER" --root "$root" "$@" 2>&1 )"
  rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
suite "the instrument itself: the script exists and the cap comes out of the schema"
# ---------------------------------------------------------------------------
assert_eq "scripts/check-status-record.mjs is present" \
  "$([[ -f "$CHECKER" ]] && echo present || echo "ABSENT: $CHECKER")" "present"

# THE CAP, read the same way the script reads it. Every fixture length below is derived from
# these two numbers.
EV_CAP="$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(s.properties.events.items.properties.verdict.maxLength));
' "$SCHEMA" 2>/dev/null)"
FL_CAP="$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(s.properties.flags.items.properties.verdict.maxLength));
' "$SCHEMA" 2>/dev/null)"
assert_eq "VACUITY: a numeric events cap was read out of the schema (else every cell below measures nothing)" \
  "$([[ "$EV_CAP" =~ ^[0-9]+$ ]] && echo read || echo "NOT A NUMBER: $EV_CAP")" "read"
assert_eq "VACUITY: and a numeric flags cap too" \
  "$([[ "$FL_CAP" =~ ^[0-9]+$ ]] && echo read || echo "NOT A NUMBER: $FL_CAP")" "read"

# THE TWO SITES THAT HOLD THE LITERAL, one per capped field, pinning #34's ruled value. They are
# the only 32s in this file; everything else derives from the numbers above.
assert_eq "the events[] cap is still the ruled 32" "$EV_CAP" "32"
assert_eq "the flags[] cap is still the ruled 32" "$FL_CAP" "32"

# The script must never hold its own copy. Asserted on the SOURCE, because a copy that happens
# to agree with the schema today is invisible to every behavioral cell in this file.
assert_eq "the script holds no hardcoded cap: the digits '32' appear nowhere in its executable lines" \
  "$(grep -v '^[[:space:]]*\(\*\|/\*\|//\)' "$CHECKER" | grep -c '\b32\b' | tr -d ' ')" "0"
assert_contains "...because it reads maxLength out of the schema document instead" \
  "$(cat "$CHECKER")" "maxLength"

# ---------------------------------------------------------------------------
suite "THE BOUNDARY: maxLength is inclusive, so exactly-cap conforms and cap+1 does not"
# ---------------------------------------------------------------------------
# This is the `>` versus `>=` cell, and it is not academic: the live corpus this pipeline is
# committing right now sits at exactly 32 (SKIPPED_OWNER_DECISION_CONFIRMED, written during
# #106), so a `>=` here would refuse a record the schema permits and this repo has shipped.
AT_CAP="$(verdict_of "$EV_CAP")"
OVER_CAP="$(verdict_of $((EV_CAP + 1)))"
UNDER_CAP="$(verdict_of $((EV_CAP - 1)))"
assert_eq "CONTROL: the at-cap fixture really is exactly the cap long" "${#AT_CAP}" "$EV_CAP"
assert_eq "CONTROL: and the over-cap fixture is exactly one character longer" \
  "${#OVER_CAP}" "$((EV_CAP + 1))"

write_root "$AT_CAP" "$AT_CAP" || exit 90
AT_ROOT="$NEW_TMPDIR"
assert_eq "a verdict of EXACTLY the cap passes, silently, exit 0" "$(run_checker "$AT_ROOT")" "0|"

write_root "$UNDER_CAP" "$UNDER_CAP" || exit 90
assert_eq "one character under the cap passes too" "$(run_checker "$NEW_TMPDIR")" "0|"

write_root "$OVER_CAP" "" || exit 90
OVER_ROOT="$NEW_TMPDIR"
OVER_OUT="$(run_checker "$OVER_ROOT")"
assert_eq "NON-ZERO CONTROL: one character OVER the cap exits 1" "${OVER_OUT%%|*}" "1"
assert_contains "NON-ZERO CONTROL: ...and names the record" "$OVER_OUT" ".pipeline/117/status.json"
assert_contains "NON-ZERO CONTROL: ...names the json path, index included" "$OVER_OUT" "events[0].verdict"
assert_contains "NON-ZERO CONTROL: ...quotes the offending VALUE, so the writer can find it" \
  "$OVER_OUT" "\"$OVER_CAP\""
assert_contains "NON-ZERO CONTROL: ...and reports both lengths, so the reader need not count characters" \
  "$OVER_OUT" "len=$((EV_CAP + 1)) cap=$EV_CAP"

# ---------------------------------------------------------------------------
suite "the two fields are checked SEPARATELY, and neither rides on the other's cell"
# ---------------------------------------------------------------------------
# The hole #34 shipped in its own schema was exactly this: a check satisfied by the events[]
# copy never notices that flags[] is bare. So each direction gets its own fixture, and each
# fixture carries a CONFORMING value in the other field, so a silence is an observation rather
# than an unvisited branch.
write_root "$OVER_CAP" "$AT_CAP" || exit 90
EV_ONLY="$(run_checker "$NEW_TMPDIR")"
assert_eq "over-long in events[] only: exit 1" "${EV_ONLY%%|*}" "1"
assert_contains "...the events[] branch fires" "$EV_ONLY" "events[0].verdict"
assert_not_contains "...and the flags[] branch is SILENT on that same record" "$EV_ONLY" "flags[0].verdict"

write_root "$AT_CAP" "$OVER_CAP" || exit 90
FL_ONLY="$(run_checker "$NEW_TMPDIR")"
assert_eq "over-long in flags[] only: exit 1" "${FL_ONLY%%|*}" "1"
assert_contains "...the flags[] branch fires" "$FL_ONLY" "flags[0].verdict"
assert_not_contains "...and the events[] branch is SILENT on that same record" "$FL_ONLY" "events[0].verdict"

write_root "$OVER_CAP" "$OVER_CAP" || exit 90
BOTH="$(run_checker "$NEW_TMPDIR")"
assert_contains "both over-long: BOTH are reported, not just the first one found" "$BOTH" "events[0].verdict"
assert_contains "both over-long: ...including the flags[] one" "$BOTH" "flags[0].verdict"
assert_contains "both over-long: ...and the count says two" "$BOTH" "2 verdict value(s)"

# ---------------------------------------------------------------------------
suite "THE CLOBBER (#117 occurrence 2): a fix overwritten by a stale copy is caught the same way"
# ---------------------------------------------------------------------------
# The recorded sequence, replayed: a record carries an over-cap label; someone shortens it; a
# `cp` from a stale checkout puts the long one back. The checker reads FILE CONTENT and takes no
# argument naming what changed, so it cannot tell a keystroke from a `cp` -- which is the whole
# point. A diff-scoped check passes the third step.
new_tmpdir || exit 90
CLOBBER_ROOT="$NEW_TMPDIR"
mkdir -p "$CLOBBER_ROOT/.pipeline/117"
new_tmpdir || exit 90
STALE_COPY="$NEW_TMPDIR/stale-status.json"
LIVE_RECORD="$CLOBBER_ROOT/.pipeline/117/status.json"

status_body "$OVER_CAP" "" > "$LIVE_RECORD"
cp "$LIVE_RECORD" "$STALE_COPY"          # the orchestrator's own, still-unfixed copy
CLOBBER_1="$(run_checker "$CLOBBER_ROOT")"
assert_eq "step 1 -- the pre-existing over-cap label is refused" "${CLOBBER_1%%|*}" "1"
status_body "$AT_CAP" "" > "$LIVE_RECORD"     # Dev fixes it in the worktree
assert_eq "step 2 -- the fix is accepted, exit 0 and silent" "$(run_checker "$CLOBBER_ROOT")" "0|"
cp "$STALE_COPY" "$LIVE_RECORD"          # the routine sync puts the stale copy back
CLOBBERED="$(run_checker "$CLOBBER_ROOT")"
assert_eq "step 3 -- THE REGRESSION IS CAUGHT: the clobbered record is refused again" \
  "${CLOBBERED%%|*}" "1"
assert_contains "step 3 -- ...naming the same value the fix had removed" "$CLOBBERED" "\"$OVER_CAP\""

# ---------------------------------------------------------------------------
suite "the cap is READ, not compiled in: changing the schema moves the verdict"
# ---------------------------------------------------------------------------
# The direct falsification of "it holds its own 32". A scratch schema is not a mutation of the
# shipped one: the file under test is never edited, so an interrupted run leaves no planted
# defect in the tree (evidence.md's restore-from-git rule, avoided rather than obeyed).
mk_schema() {   # mk_schema <events-cap|omit> <flags-cap|omit> <dest>
  node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const set = (node, v) => { if (v === "omit") delete node.maxLength; else node.maxLength = Number(v); };
    set(s.properties.events.items.properties.verdict, process.argv[2]);
    set(s.properties.flags.items.properties.verdict, process.argv[3]);
    fs.writeFileSync(process.argv[4], JSON.stringify(s));
  ' "$SCHEMA" "$1" "$2" "$3"
}
new_tmpdir || exit 90
SCRATCH_SCHEMAS="$NEW_TMPDIR"
mk_schema $((EV_CAP + 8)) $((FL_CAP + 8)) "$SCRATCH_SCHEMAS/raised.json"
mk_schema $((EV_CAP - 8)) "$FL_CAP" "$SCRATCH_SCHEMAS/lowered-events.json"
mk_schema omit omit "$SCRATCH_SCHEMAS/uncapped.json"

assert_eq "raise the cap in a scratch schema and the SAME over-cap record passes" \
  "$(run_checker "$OVER_ROOT" --schema "$SCRATCH_SCHEMAS/raised.json")" "0|"
LOWERED="$(run_checker "$AT_ROOT" --schema "$SCRATCH_SCHEMAS/lowered-events.json")"
assert_eq "lower it and the SAME at-cap record is refused" "${LOWERED%%|*}" "1"
assert_contains "...against the lowered number, read out of that schema" "$LOWERED" "cap=$((EV_CAP - 8))"
assert_not_contains "...and only the field whose cap moved is refused (flags kept its own)" \
  "$LOWERED" "flags[0].verdict"

# A schema that stopped capping is a HARD ERROR, never a quiet pass. An unenforceable constraint
# has to announce itself: silently checking nothing is how the cap got into this state.
UNCAPPED="$(run_checker "$OVER_ROOT" --schema "$SCRATCH_SCHEMAS/uncapped.json")"
assert_eq "a schema with no maxLength at all exits 2 rather than passing the over-cap record" \
  "${UNCAPPED%%|*}" "2"
assert_contains "...and says why, rather than failing as an unexplained crash" \
  "$UNCAPPED" "no usable maxLength"

# ---------------------------------------------------------------------------
suite "--cap may only TIGHTEN: the checker has no argument that turns it off"
# ---------------------------------------------------------------------------
# test-status-schema-contract.sh drives this flag to reach a violation on the live corpus, so it
# exists; a flag that could RAISE the cap would be a documented way to silence a refusal, which
# is the one thing a write-time control must not ship with.
LOOSEN="$(run_checker "$AT_ROOT" --cap $((EV_CAP + 1)))"
assert_eq "a --cap above the schema's is REFUSED, exit 2" "${LOOSEN%%|*}" "2"
assert_contains "...and says which field it would have loosened" "$LOOSEN" "would LOOSEN events[].verdict"
TIGHTEN="$(run_checker "$AT_ROOT" --cap $((EV_CAP - 1)))"
assert_eq "a --cap below it is accepted and refuses MORE: the at-cap record now violates" \
  "${TIGHTEN%%|*}" "1"
assert_eq "a non-numeric --cap is a usage error, not a silently-ignored flag" \
  "$(run_checker "$AT_ROOT" --cap banana | cut -d'|' -f1)" "2"
assert_eq "an unknown flag is a usage error too, so a typo cannot no-op the run" \
  "$(run_checker "$AT_ROOT" --skip-verdicts | cut -d'|' -f1)" "2"

# ---------------------------------------------------------------------------
suite "nothing checked is never a pass"
# ---------------------------------------------------------------------------
# evidence.md: a check that reads what RAN cannot see what never ran. Every state below produces
# an empty violations list, and every one of them must exit non-zero, because an empty list is
# equally consistent with a clean corpus and with a walk that inspected nothing.
new_tmpdir || exit 90
EMPTY_ROOT="$NEW_TMPDIR"
mkdir -p "$EMPTY_ROOT/.pipeline"
EMPTY_OUT="$(run_checker "$EMPTY_ROOT")"
assert_eq "an empty .pipeline/ exits 2, not 0" "${EMPTY_OUT%%|*}" "2"
assert_contains "...and says out loud that nothing was checked" "$EMPTY_OUT" "not a pass"

new_tmpdir || exit 90
NO_PIPELINE_ROOT="$NEW_TMPDIR"
assert_eq "no .pipeline/ directory at all exits 2 as well" \
  "$(run_checker "$NO_PIPELINE_ROOT" | cut -d'|' -f1)" "2"

new_tmpdir || exit 90
TORN_ROOT="$NEW_TMPDIR"
mkdir -p "$TORN_ROOT/.pipeline/117"
printf '{"events":[{"phase":"4-review","at":"x","verdict":' > "$TORN_ROOT/.pipeline/117/status.json"
TORN="$(run_checker "$TORN_ROOT")"
assert_eq "a truncated record (an interrupted write) exits 2" "${TORN%%|*}" "2"
assert_contains "...and NAMES the file it could not read" "$TORN" ".pipeline/117/status.json"

new_tmpdir || exit 90
SHAPE_ROOT="$NEW_TMPDIR"
mkdir -p "$SHAPE_ROOT/.pipeline/117"
printf '{"events":{"phase":"4-review","verdict":"APPROVE"}}' > "$SHAPE_ROOT/.pipeline/117/status.json"
SHAPE="$(run_checker "$SHAPE_ROOT")"
assert_eq "events written as an OBJECT exits 2 rather than walking zero entries and passing" \
  "${SHAPE%%|*}" "2"
assert_contains "...naming the shape it found" "$SHAPE" "events is object"

assert_eq "an explicitly-named file that does not exist exits 2" \
  "$(run_checker "$AT_ROOT" .pipeline/9999/status.json | cut -d'|' -f1)" "2"

# ---------------------------------------------------------------------------
suite "the cap must not become a REQUIREMENT"
# ---------------------------------------------------------------------------
# An event or flag with no verdict key is schema-valid, and the live corpus contains such
# records (test-gate-phase-entry.sh pins one). A walk that treated absence as a violation would
# refuse correct work, which is the fail direction a write-time refusal can least afford.
write_root "" "" || exit 90
assert_eq "a record whose event and flag carry NO verdict key passes" "$(run_checker "$NEW_TMPDIR")" "0|"
REPORT_NOVERDICT="$(cd "$NEW_TMPDIR" && node "$CHECKER" --root "$NEW_TMPDIR" --report 2>/dev/null)"
assert_contains "...and the measurement says it inspected zero verdict strings, so the pass is legible" \
  "$REPORT_NOVERDICT" "verdicts=0"
assert_contains "...while still confirming it read the record" "$REPORT_NOVERDICT" "read=1"

# ---------------------------------------------------------------------------
suite "#52's ruling holds: this check has NO opinion about free text"
# ---------------------------------------------------------------------------
# The cheapest way to make a content problem look solved is to cap the field, and #52 ruled
# explicitly against it: events[].note, veto_reason and error carry no maxLength on purpose, and
# a 600-char note recording a live reproduction is correct work. This is the ratchet. If a
# future edit teaches this script a length opinion about free text, these cells go red.
new_tmpdir || exit 90
PROSE_ROOT="$NEW_TMPDIR"
mkdir -p "$PROSE_ROOT/.pipeline/117"
node -e '
  const long = "x".repeat(2000);
  process.stdout.write(JSON.stringify({
    current_phase: "4-review", started_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z", branch: "fix/117",
    ask_text: long, veto_reason: long, error: long,
    events: [{ phase: "4-review", at: "2026-01-01T00:00:00Z", verdict: process.argv[1], note: long }],
    flags: [{ phase: "4-review", agent: "qa", at: "2026-01-01T00:00:00Z", verdict: process.argv[1], summary: long }],
  }));
' "$AT_CAP" > "$PROSE_ROOT/.pipeline/117/status.json"
assert_eq "2000-char note, summary, veto_reason, error and ask_text all pass: exit 0, silent" \
  "$(run_checker "$PROSE_ROOT")" "0|"
# CONTROL on that pass: the record really did reach the verdict walk, so the exit 0 above is a
# result about a record that was read and not about one that was skipped for its size.
assert_contains "CONTROL: and the walk really inspected that record's two verdicts" \
  "$(cd "$PROSE_ROOT" && node "$CHECKER" --root "$PROSE_ROOT" --report 2>/dev/null)" "verdicts=2"
assert_eq "the script names no free-text field as something it measures" \
  "$(grep -c 'summary\.length\|note\.length\|veto_reason\.length\|error\.length' "$CHECKER" | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
suite "one command, no arguments to remember"
# ---------------------------------------------------------------------------
# #117's requirement in its own words. The bare invocation from the project root has to find
# every record and refuse a bad one; a check the orchestrator must remember flags for is the
# same class of thing as a rule it must remember to obey.
new_tmpdir || exit 90
MULTI_ROOT="$NEW_TMPDIR"
mkdir -p "$MULTI_ROOT/.pipeline/117" "$MULTI_ROOT/.pipeline/118" "$MULTI_ROOT/.pipeline/exp-a"
status_body "$AT_CAP" "" > "$MULTI_ROOT/.pipeline/117/status.json"
status_body "$AT_CAP" "" > "$MULTI_ROOT/.pipeline/118/status.json"
status_body "$AT_CAP" "" > "$MULTI_ROOT/.pipeline/exp-a/status.json"
BARE="$( cd "$MULTI_ROOT" && node "$CHECKER" --report 2>&1 )"
assert_contains "the bare invocation discovers every record under .pipeline/, numeric ids and named ones alike" \
  "$BARE" "files=3"
assert_contains "...and read all three" "$BARE" "read=3"
status_body "$OVER_CAP" "" > "$MULTI_ROOT/.pipeline/118/status.json"
BARE_BAD="$( cd "$MULTI_ROOT" && node "$CHECKER" 2>&1; printf '|%s' "$?" )"
assert_contains "one bad record among three is found by the bare invocation" "$BARE_BAD" ".pipeline/118/status.json"
assert_eq "...and the bare invocation exits 1" "${BARE_BAD##*|}" "1"
assert_not_contains "...without implicating its clean siblings" "$BARE_BAD" ".pipeline/117/status.json"

# CLAUDE_PROJECT_DIR is what the orchestrator has and cwd is not always the project root, so the
# bare invocation reads it. Pinned because the contract suite depends on the opposite: it passes
# --root explicitly, since run.sh executes during live pipeline runs where that variable points
# at a real project.
CPD_OUT="$( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$MULTI_ROOT" node "$CHECKER" 2>&1; printf '|%s' "$?" )"
assert_eq "run from an unrelated cwd, CLAUDE_PROJECT_DIR still locates the records" "${CPD_OUT##*|}" "1"
assert_contains "...and finds the same bad one" "$CPD_OUT" ".pipeline/118/status.json"

# ---------------------------------------------------------------------------
suite "the writer reads commands/pipeline.md, so the command is stated THERE"
# ---------------------------------------------------------------------------
# A rule with no runnable check beside it is what #117 is about; a runnable check named nowhere
# the writer looks is the same defect wearing the other hat.
VERDICT_RULE="$(sed -n '/^Rules for `verdict`/,/^$/p' "$PIPELINE_MD")"
assert_eq "VACUITY: the verdict rule block was extracted non-empty" \
  "$([[ -n "$VERDICT_RULE" ]] && echo present || echo "ABSENT from $PIPELINE_MD")" "present"
assert_contains "the verdict rule names the checker by path" "$VERDICT_RULE" "check-status-record.mjs"
CHECKPOINT_BLOCK="$(sed -n '/^### Durable checkpoint convention/,/^### /p' "$PIPELINE_MD")"
assert_eq "VACUITY: the checkpoint convention block was extracted non-empty" \
  "$([[ -n "$CHECKPOINT_BLOCK" ]] && echo present || echo ABSENT)" "present"
assert_contains "and the checkpoint commit recipe -- the place the writer actually acts -- runs it" \
  "$CHECKPOINT_BLOCK" "check-status-record.mjs"
assert_contains "...before the commit, not after it" \
  "$(printf '%s' "$CHECKPOINT_BLOCK" | grep -A2 'check-status-record.mjs' | head -3)" "git commit"
# The command in the doc is the command that runs. Extracted and EXECUTED rather than read:
# evidence.md's run-it-do-not-read-it rule, and this repo has shipped four non-running commands
# in one session.
DOC_CMD="$(printf '%s' "$CHECKPOINT_BLOCK" | grep 'check-status-record.mjs' | grep '^node ' | head -1)"
assert_eq "VACUITY: a runnable node invocation was extracted from the doc" \
  "$([[ -n "$DOC_CMD" ]] && echo extracted || echo "NO node line found in the recipe")" "extracted"
DOC_CMD_RESOLVED="${DOC_CMD/\"\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/check-status-record.mjs\"/$CHECKER}"
DOC_RUN="$( cd "$MULTI_ROOT" && eval "$DOC_CMD_RESOLVED" 2>&1; printf '|%s' "$?" )"
assert_eq "THE DOCUMENTED COMMAND ACTUALLY RUNS, and refuses the bad record" "${DOC_RUN##*|}" "1"
assert_contains "...naming it" "$DOC_RUN" ".pipeline/118/status.json"
status_body "$AT_CAP" "" > "$MULTI_ROOT/.pipeline/118/status.json"
DOC_RUN_CLEAN="$( cd "$MULTI_ROOT" && eval "$DOC_CMD_RESOLVED" 2>&1; printf '|%s' "$?" )"
assert_eq "GATE BITES, the other half: the same documented command exits 0 on the fixed record" \
  "$DOC_RUN_CLEAN" "|0"

# ---------------------------------------------------------------------------
suite "the default scan is scoped to LIVE records (0.41.0)"
# ---------------------------------------------------------------------------
# WHY THE SCOPE CHANGED. `.pipeline/` accumulates one record per run forever, and records
# written before #34 capped the verdict field carry pre-cap values nobody may edit: they are the
# archive. The bare invocation walked all of them, so a checkpoint commit printed the same
# violations about the same finished runs on every run of every issue, none of them actionable
# by the writer. A refusal that fires identically whatever you just wrote is one people learn to
# scroll past, and a control nobody reads is indistinguishable from one that was never wired up.
#
# LIVE is a DISJUNCTION and each half is pinned separately below: recent, OR not at a terminal
# phase. The second half is what keeps an abandoned run in scope -- a pipeline halted three
# months ago at 3-impl-gate-failed is exactly the record a --resume will read next.

# aged_record <file> <phase> <iso-updated_at> <events-verdict>
aged_record() {
  mkdir -p "$(dirname "$1")"
  node -e '
    const fs = require("fs");
    const [, file, phase, updated, verdict] = process.argv;
    const ev = { phase, at: updated };
    if (verdict !== "") ev.verdict = verdict;
    fs.writeFileSync(file, JSON.stringify({
      current_phase: phase, started_at: "2020-01-01T00:00:00Z", updated_at: updated,
      branch: "b", events: [ev], flags: [],
    }));' "$1" "$2" "$3" "$4"
}

RECENT_ISO="$(node -e 'process.stdout.write(new Date(Date.now() - 3600e3).toISOString())')"
OLD_ISO="$(node -e 'process.stdout.write(new Date(Date.now() - 400*24*3600e3).toISOString())')"

new_tmpdir || exit 90
SCOPE_ROOT="$NEW_TMPDIR"
# 1: OLD and ARCHIVED, carrying an over-cap verdict. The historical record nobody may fix.
aged_record "$SCOPE_ROOT/.pipeline/1/status.json" "5-archived" "$OLD_ISO" "$OVER_CAP"
# 2: OLD but NOT terminal. Abandoned mid-run, and still the record a resume would read.
aged_record "$SCOPE_ROOT/.pipeline/2/status.json" "3-impl" "$OLD_ISO" "$AT_CAP"
# 3: RECENT and archived. Terminal, but inside the window, so still in scope.
aged_record "$SCOPE_ROOT/.pipeline/3/status.json" "5-archived" "$RECENT_ISO" "$AT_CAP"

SCOPED="$(cd "$SCOPE_ROOT" && node "$CHECKER" --root "$SCOPE_ROOT" --report 2>&1)"
assert_contains "the default scan reads two of the three records" "$SCOPED" "files=2"
assert_eq "and it exits 0: the old archived violation is out of scope" \
  "$(run_checker "$SCOPE_ROOT" | cut -d'|' -f1)" "0"
# Each half of the disjunction, named, so a rule that kept only one would redden here rather
# than pass on the aggregate count.
assert_not_contains "the OLD ARCHIVED record is the one dropped" "$SCOPED" ".pipeline/1/status.json"
ALL_OUT="$(run_checker "$SCOPE_ROOT" --all)"
assert_eq "--all restores the historical walk and finds it" "${ALL_OUT%%|*}" "1"
assert_contains "...naming the record the default scan skipped" "$ALL_OUT" ".pipeline/1/status.json"

# NON-ZERO CONTROL ON THE SCOPING ITSELF. The two cells above are consistent with a scan that
# reads nothing at all, so each surviving record is made to speak: put an over-cap verdict in
# the OLD NON-TERMINAL record and in the RECENT ARCHIVED one, one at a time, and require the
# default scan to refuse each.
aged_record "$SCOPE_ROOT/.pipeline/2/status.json" "3-impl" "$OLD_ISO" "$OVER_CAP"
OLD_LIVE="$(run_checker "$SCOPE_ROOT")"
assert_eq "an OLD but non-terminal record is IN scope: the default scan refuses it" "${OLD_LIVE%%|*}" "1"
assert_contains "...naming it" "$OLD_LIVE" ".pipeline/2/status.json"
aged_record "$SCOPE_ROOT/.pipeline/2/status.json" "3-impl" "$OLD_ISO" "$AT_CAP"

aged_record "$SCOPE_ROOT/.pipeline/3/status.json" "5-archived" "$RECENT_ISO" "$OVER_CAP"
RECENT_ARCH="$(run_checker "$SCOPE_ROOT")"
assert_eq "a RECENT archived record is IN scope too" "${RECENT_ARCH%%|*}" "1"
assert_contains "...naming it" "$RECENT_ARCH" ".pipeline/3/status.json"
aged_record "$SCOPE_ROOT/.pipeline/3/status.json" "5-archived" "$RECENT_ISO" "$AT_CAP"

# --issue reaches ONE record whatever its age or phase, which is the flag a writer uses when the
# thing they just edited is the archived one.
ISSUE_OUT="$(run_checker "$SCOPE_ROOT" --issue 1)"
assert_eq "--issue reads the out-of-scope record and refuses it" "${ISSUE_OUT%%|*}" "1"
assert_contains "...and reads ONLY that one" "$ISSUE_OUT" ".pipeline/1/status.json"
assert_not_contains "...without walking its siblings" "$ISSUE_OUT" ".pipeline/2/status.json"
assert_eq "--issue on a clean record exits 0" "$(run_checker "$SCOPE_ROOT" --issue 3 | cut -d'|' -f1)" "0"
assert_eq "--issue on a run that does not exist exits 2, never 0" \
  "$(run_checker "$SCOPE_ROOT" --issue 4242 | cut -d'|' -f1)" "2"
assert_eq "--issue with no value is a usage error" \
  "$(run_checker "$SCOPE_ROOT" --issue | cut -d'|' -f1)" "2"

# A record the scan CANNOT date stays in scope. An undatable record is one the checker must
# still be given the chance to refuse; filtering it here would turn a torn write into a silent
# pass, which is the one thing "nothing checked is never a pass" forbids.
new_tmpdir || exit 90
UNDATABLE_ROOT="$NEW_TMPDIR"
mkdir -p "$UNDATABLE_ROOT/.pipeline/7"
printf '{"current_phase":"5-archived","events":[{"phase":"5-archived","at":"x","verdict":' \
  > "$UNDATABLE_ROOT/.pipeline/7/status.json"
TORN_SCOPE="$(run_checker "$UNDATABLE_ROOT")"
assert_eq "a torn record at a terminal phase is still read, and exits 2" "${TORN_SCOPE%%|*}" "2"
assert_contains "...naming the file it could not read" "$TORN_SCOPE" ".pipeline/7/status.json"

# A tree whose every record is archived-and-old reports NOTHING CHECKED rather than a pass, and
# the message names the scope so the reader knows --all is the next move. This is the state the
# scoping newly creates, so it gets its own cell rather than riding on the pre-existing
# empty-directory one.
new_tmpdir || exit 90
ALL_ARCHIVED="$NEW_TMPDIR"
aged_record "$ALL_ARCHIVED/.pipeline/9/status.json" "5-archived" "$OLD_ISO" "$AT_CAP"
ARCHIVED_ONLY="$(run_checker "$ALL_ARCHIVED")"
assert_eq "a tree with only old archived records exits 2, not 0" "${ARCHIVED_ONLY%%|*}" "2"
assert_contains "...saying nothing was checked" "$ARCHIVED_ONLY" "not a pass"
assert_contains "...naming the scope, so the reader knows why" "$ARCHIVED_ONLY" "LIVE"
assert_contains "...and naming the flag that widens it" "$ARCHIVED_ONLY" "--all"
assert_eq "CONTROL: --all on the same tree finds the record and passes it" \
  "$(run_checker "$ALL_ARCHIVED" --all)" "0|"

# The selection flags do not combine with explicitly named files: a flag silently ignored beside
# an argument is how a writer comes to believe they checked something they did not.
assert_eq "--all beside a named file is a usage error" \
  "$(run_checker "$SCOPE_ROOT" --all .pipeline/1/status.json | cut -d'|' -f1)" "2"


finish
