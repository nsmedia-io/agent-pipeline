#!/usr/bin/env bash
# #109: the SubagentStop sweep scopes itself by RUN OWNERSHIP, not by newest status.json mtime.
#
# THE DEFECT THIS SUITE PINS, measured on the shipped hook at 70e7d46 (origin/main, 2026-09-02)
# before the change. Fixture: one .pipeline root, two runs, BOTH in flight; the dba agent has
# just written a VALID review.dba.json under its own run 9001; sibling 9002 was freshly synced,
# so its status.json carries the newer mtime and its review.dba.json is invalid.
#
#   hooks/subagent-stop.sh emitted 856 bytes of {"decision":"block"} naming FIVE violations, all
#   of them in .pipeline/9002/review.dba.json, and stderr read
#     agent-pipeline SubagentStop: agent=dba verdict=checked issue=9002 violations=5
#
# subagent-stop.sh is fail-open for TOOLING gaps only; a non-empty validator payload is passed
# straight through to Claude Code, so that block REFUSED A CORRECT STOP for work the session
# never touched. The same wrong pick also MISSED the real defect in the other direction: with
# 9001's own artifact made invalid instead, the shipped hook validated 9002, reported
# `violations=0` and blocked nothing.
#
# The direction is refuses-correct-work, which is why it closes now rather than being filed.
#
# WHAT THE FIX MAY NOT COST, and every cell below is one half of that pair: an artifact this
# session genuinely owns and genuinely broke must still block. A scoping change that only ever
# narrows is indistinguishable from deleting the gate, so no cell here asserts a silence without
# a twin asserting the block it did not suppress.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

VALIDATOR="$SCRIPTS_DIR/validate-pipeline-artifact.mjs"

new_tmpdir || exit 90
WORK="$NEW_TMPDIR"

# ---- fixture builders --------------------------------------------------------------------
#
# `updated_at` is written as a CONTENT timestamp relative to now, and status.json mtimes are set
# with an explicit `touch -t`. Those are the two different clocks #106 measured apart and the
# distinction this whole change rests on: a `git clone` refreshes every mtime while leaving every
# `updated_at` exactly where it was, so a rule keyed on mtime reads a month-old finished run as
# the newest thing in the tree. Nothing here is allowed to depend on write ORDER, which is coarse
# enough on Linux that two writes microseconds apart land on the identical mtime (#27, green on
# APFS and red as a group on ubuntu-latest at a fixed commit).

# mkrun <root> <issue> <ago-ms|literal:...|none> [final_verdict]
mkrun() {
  local root="$1" issue="$2" when="$3" fv="${4:-}"
  mkdir -p "$root/.pipeline/$issue"
  node -e '
    const fs = require("fs");
    const [, file, issue, when, fv] = process.argv;
    const rec = {
      issue_number: /^\d+$/.test(issue) ? Number(issue) : null,
      current_phase: "4-review",
      started_at: "2026-09-01T00:00:00Z",
      branch: "b",
      risk_tier: "architectural",
      events: [],
    };
    if (when === "none") delete rec.updated_at;
    else if (when.startsWith("literal:")) rec.updated_at = when.slice(8);
    else rec.updated_at = new Date(Date.now() - Number(when)).toISOString();
    if (fv) rec.final_verdict = fv;
    fs.writeFileSync(file, JSON.stringify(rec, null, 1));
  ' "$root/.pipeline/$issue/status.json" "$issue" "$when" "$fv"
}

# A dba review shard that validates, and one that does not (bad verdict enum, wrong type on
# reviewed_at, a concern with no description). Five violations, counted in the record below.
mkvalid() {
  printf '%s' '{"verdict":"APPROVE","reviewed_at":"2026-09-02T00:00:00Z","concerns":[],"notes":"clean"}' \
    > "$1/review.dba.json"
}
mkinvalid() {
  printf '%s' '{"verdict":"LGTM","reviewed_at":7,"concerns":[{"severity":"spicy"}],"notes":"n"}' \
    > "$1/review.dba.json"
}

# stop <root> [marker] -> RC, OUT (the decision channel), ERR (the attribution line)
stop() {
  local root="$1" marker="${2:-}" payload
  payload=$(node -e '
    const [, root, marker] = process.argv;
    const p = { hook_event_name: "SubagentStop", session_id: "i109", agent_type: "pipeline:dba", cwd: root };
    if (marker) p.active_issue = marker;
    process.stdout.write(JSON.stringify(p));
  ' "$root" "$marker")
  printf '%s' "$payload" \
    | ( cd "$root" && CLAUDE_PROJECT_DIR="$root" node "$VALIDATOR" ) \
      >"$WORK/out.txt" 2>"$WORK/err.txt"
  RC=$?
  OUT=$(cat "$WORK/out.txt")
  ERR=$(cat "$WORK/err.txt")
}

# blocked -> "yes"/"no"; scoped -> the issue name the attribution line reports
blocked() { [[ -n "$OUT" ]] && printf 'yes' || printf 'no'; }
scoped()  { printf '%s' "$ERR" | sed -n 's/.*issue=\([^ ;]*\).*/\1/p'; }

# root <name> -> a fresh project root under $WORK
root() { local d="$WORK/$1"; mkdir -p "$d/.pipeline"; printf '%s' "$d"; }

# =============================================================================================
suite "#109 A: a wrong pick no longer refuses a correct stop, and a right pick still blocks"
# =============================================================================================

# A1 THE REPRODUCTION. Two runs in flight; this session's own artifact under 9001 is VALID and
# the foreign sibling 9002 is invalid AND carries the newest mtime. Measured pre-fix: blocked,
# scoped to 9002, five violations.
A=$(root a); mkrun "$A" 9001 60000; mkvalid "$A/.pipeline/9001"
mkrun "$A" 9002 60000; mkinvalid "$A/.pipeline/9002"
touch -t 202601010000 "$A/.pipeline/9001/status.json"
touch -t 202701010000 "$A/.pipeline/9002/status.json"   # the sibling is unambiguously NEWEST
stop "$A"
assert_eq "A1: two runs in flight and a valid own artifact does NOT block" "$(blocked)" "no"
assert_contains "A1: and the abstention names WHICH ambiguity it was" "$ERR" "ambiguous-owner"
assert_not_contains "A1: the foreign sibling is never named as the checked issue" "$ERR" "issue=9002"

# A2 NON-ZERO CONTROL, block direction. One run in flight, and it is this session's own, with a
# genuinely broken artifact. Without this cell A1 is satisfied by a validator that blocks nothing.
B=$(root b); mkrun "$B" 9001 60000; mkinvalid "$B/.pipeline/9001"
mkrun "$B" 9002 60000 APPROVE_WITH_NOTES; mkvalid "$B/.pipeline/9002"
touch -t 202701010000 "$B/.pipeline/9002/status.json"   # concluded AND newest by mtime
stop "$B"
assert_eq "A2 CONTROL: the session's own broken artifact still blocks" "$(blocked)" "yes"
assert_eq "A2 CONTROL: and the block is scoped to the run that owns it" "$(scoped)" "9001"
assert_contains "A2 CONTROL: the block names the artifact" "$OUT" "review.dba.json"

# A3 THE CLONE SHAPE, which is the production reachability #106 measured: every tracked
# status.json is re-stamped by the checkout, so the newest-mtime dir is a run that CONCLUDED.
# Its stale artifact must not author a refusal.
C=$(root c); mkrun "$C" 9001 60000; mkvalid "$C/.pipeline/9001"
mkrun "$C" 9002 "literal:2026-08-01T00:00:00Z" REQUEST_CHANGES; mkinvalid "$C/.pipeline/9002"
touch -t 202701010000 "$C/.pipeline/9002/status.json"
stop "$C"
assert_eq "A3: a CONCLUDED run's broken artifact does not block, however new its mtime" "$(blocked)" "no"
assert_eq "A3: the in-flight run is the one in scope" "$(scoped)" "9001"

# A4 A3's DISCRIMINATING TWIN. Same shape, but the in-flight run's own artifact is the broken
# one. If A3 passed because the validator stopped looking at anything, this reddens.
D=$(root d); mkrun "$D" 9001 60000; mkinvalid "$D/.pipeline/9001"
mkrun "$D" 9002 "literal:2026-08-01T00:00:00Z" REQUEST_CHANGES; mkvalid "$D/.pipeline/9002"
touch -t 202701010000 "$D/.pipeline/9002/status.json"
stop "$D"
assert_eq "A4 CONTROL: the in-flight run's own broken artifact blocks" "$(blocked)" "yes"
assert_eq "A4 CONTROL: scoped to it and not to the newer concluded sibling" "$(scoped)" "9001"

assert_eq "A: every case exited 0 -- the validator is still fail-open on its own process contract" "$RC" "0"

# =============================================================================================
suite "#109 B: the marker can turn an abstention into a deny, and can NEVER suppress one"
# =============================================================================================
#
# This is the shipped precedent at gate-phase-entry.mjs's candidateDirs: ask ONE resolver two
# questions -- who does the signal name, and who resolves with no signal at all -- and act on the
# UNION. The union is what makes "widen-only" structural rather than argued.
#
# #106's round-4 spec first ruled the opposite ("the marker may only ever REDUCE refusals") and
# that ruling is RETIRED, per #109's correction note: reduce-only makes the marker functionally
# identical to an operator disarm on a control whose entire job is to refuse, and it forecloses
# the remedy for the abstention A1 now produces.

# B1 ABSTENTION -> DENY. A1's fixture exactly, plus the marker.
stop "$A" 9002
assert_eq "B1: the marker resolves an otherwise-ambiguous stop and the deny lands" "$(blocked)" "yes"
assert_eq "B1: scoped to the record the marker named" "$(scoped)" "9002"

# B2 and the same marker pointed at the OTHER in-flight run, whose artifact is clean: no block.
# Two cells with one fixture and opposite outcomes is what makes B1 a discrimination rather than
# an unconditional refusal whenever a marker is present.
stop "$A" 9001
assert_eq "B2 CONTROL: a marker naming the clean in-flight run blocks nothing" "$(blocked)" "no"
assert_eq "B2 CONTROL: and it IS the record that was checked" "$(scoped)" "9001"

# B3 CANNOT SUPPRESS, shape 1: the marker names a run the in-flight narrowing EXCLUDES. Measured
# on the shipped hook pre-fix: this did NOT block -- the marker was honoured unconditionally, so
# the sole in-flight run's broken artifact went unchecked and the marker was a working off-switch.
E=$(root e); mkrun "$E" 9001 60000; mkinvalid "$E/.pipeline/9001"
mkrun "$E" 9002 60000 APPROVE; mkvalid "$E/.pipeline/9002"
stop "$E" 9002
assert_eq "B3: a marker naming a CONCLUDED run cannot suppress the deny the sole candidate earns" "$(blocked)" "yes"
assert_eq "B3: which is the in-flight run, not the named one" "$(scoped)" "9001"

# B4 CANNOT SUPPRESS, shape 2: the marker names a directory that does not exist.
F=$(root f); mkrun "$F" 9001 60000; mkinvalid "$F/.pipeline/9001"
stop "$F" 9999
assert_eq "B4: a marker naming an absent dir cannot suppress it either" "$(blocked)" "yes"
assert_eq "B4: still scoped to the sole in-flight run" "$(scoped)" "9001"

# B5 WIDEN-ONLY, asserted as a SET RELATION over the cross product rather than on one fixture.
# For every root built above and every marker value, the set of issues the marker run checks must
# CONTAIN the set the bare run checks. A per-fixture spot check would sit in one cell of that
# product; the loop walks all of it.
WIDEN_VIOLATIONS=""
for r in "$A" "$B" "$C" "$D" "$E" "$F"; do
  stop "$r"; BARE="$(scoped)"
  for m in 9001 9002 9999 ""; do
    stop "$r" "$m"; WITH="$(scoped)"
    # containment for a set that is 0 or 1 element: bare empty is always contained; otherwise the
    # marker run must have checked the same record.
    if [[ -n "$BARE" && "$WITH" != "$BARE" ]]; then
      WIDEN_VIOLATIONS="${WIDEN_VIOLATIONS}[$(basename "$r") marker=${m:-<none>} bare=$BARE with=$WITH]"
    fi
  done
done
assert_eq "B5: over 6 roots x 4 marker values, a marker NEVER removes a record from the checked set" \
  "${WIDEN_VIOLATIONS:-none}" "none"

# B5's PREMISE, because a containment check over an empty product passes vacuously: at least one
# row in that loop must have had a non-empty bare answer to contain.
stop "$B"
assert_eq "B5 PREMISE: the loop had a non-empty bare answer to contain (else B5 is vacuous)" \
  "$(scoped)" "9001"

# =============================================================================================
suite "#109 C: an undatable record prevents narrowing and is never the resolved owner"
# =============================================================================================
#
# Carried over from #106 rather than re-derived. The two halves pull in opposite directions and
# both are asserted: it COUNTS as a candidate (so it can never shrink a set to one), and it can
# never BE the owner (so an arbitrarily old abandoned run cannot author a refusal).

# C1 sole candidate, undatable, broken artifact -> no deny.
G=$(root g); mkrun "$G" 9001 "literal:not-a-date"; mkinvalid "$G/.pipeline/9001"
stop "$G"
assert_eq "C1: an undatable sole candidate does not own the stop, so nothing blocks" "$(blocked)" "no"
assert_contains "C1: and the abstention says which rule it was" "$ERR" "undatable-sole-candidate"

# C2 NON-ZERO CONTROL for C1: make the SAME record datable and recent, change nothing else.
mkrun "$G" 9001 60000
stop "$G"
assert_eq "C2 CONTROL: datable and recent, the identical artifact blocks" "$(blocked)" "yes"

# C3 an undatable record PREVENTS NARROWING: one in-flight broken run plus one undatable sibling
# is two candidates, so the owner is undecidable.
H=$(root h); mkrun "$H" 9001 60000; mkinvalid "$H/.pipeline/9001"
mkrun "$H" 9002 "literal:"; mkvalid "$H/.pipeline/9002"
stop "$H"
assert_eq "C3: an undatable sibling keeps the set at two, so the stop abstains" "$(blocked)" "no"
assert_contains "C3: named as ambiguity, not as a missing run" "$ERR" "ambiguous-owner"

# C3 CONTROL: give the undatable sibling a final_verdict and it leaves the candidate set, because
# `concluded` is evaluated FIRST and needs no dating. The set narrows to one and the deny returns.
mkrun "$H" 9002 "literal:" APPROVE
stop "$H"
assert_eq "C3 CONTROL: concluding the undatable sibling narrows the set and the deny returns" "$(blocked)" "yes"
assert_eq "C3 CONTROL: scoped to the run that owns the artifact" "$(scoped)" "9001"

# =============================================================================================
suite "#109 D: the in-flight grain is updated_at, and mtime cannot stand in for it"
# =============================================================================================
#
# The single measurement that decided this, re-taken here as a two-directional assertion: a clone
# refreshes every mtime and touches no `updated_at`, so the two clocks disagree by construction
# on exactly the tree an adopting project checks out. Both cells hold mtime CONSTANT and move
# only `updated_at`, so mtime cannot be the term that decided either outcome.
I=$(root i); mkrun "$I" 9001 $(( 48 * 60 * 60 * 1000 )); mkinvalid "$I/.pipeline/9001"
touch "$I/.pipeline/9001/status.json"                 # mtime = NOW, updated_at = 48h ago
stop "$I"
assert_eq "D1: a record 48h stale by updated_at is not in flight, whatever its mtime says" "$(blocked)" "no"
assert_contains "D1: reported as no run in flight" "$ERR" "no-in-flight-run"

mkrun "$I" 9001 60000
touch -t 202601010000 "$I/.pipeline/9001/status.json" # mtime = 8 months ago, updated_at = 1 min
stop "$I"
assert_eq "D2 CONTROL: recent by updated_at IS in flight, with an mtime 8 months old" "$(blocked)" "yes"
assert_eq "D2 CONTROL: and it is the record in scope" "$(scoped)" "9001"

# =============================================================================================
suite "#109 E: #115's unnamable-run recovery survives, now bounded by the same predicate"
# =============================================================================================
#
# #115 taught this sweep to check a run whose directory ISSUE_DIR_RE cannot name. #109 does not
# retire that; it applies the ownership rule to it, so the recovery reaches an unnamable run that
# is IN FLIGHT and not one abandoned in a tree months ago.
J=$(root j)
mkdir -p "$J/.pipeline/tracker-unreachable-20260902"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    current_phase: "2-review", started_at: "2026-09-01T00:00:00Z",
    updated_at: new Date(Date.now() - 60000).toISOString(), branch: "b", events: [],
  }));' "$J/.pipeline/tracker-unreachable-20260902/status.json"
mkinvalid "$J/.pipeline/tracker-unreachable-20260902"
stop "$J"
assert_eq "E1: an IN-FLIGHT unnamable run's broken artifact still blocks (#115 intact)" "$(blocked)" "yes"
assert_contains "E1: and the naming gap is still reported" "$ERR" "verdict=unnamed-run"

# E2 the new bound, and it is the half that changed: the same directory 48h stale.
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    current_phase: "2-review", started_at: "2026-01-01T00:00:00Z",
    updated_at: new Date(Date.now() - 48 * 3600 * 1000).toISOString(), branch: "b", events: [],
  }));' "$J/.pipeline/tracker-unreachable-20260902/status.json"
stop "$J"
assert_eq "E2: a 48h-stale unnamable run is not this stop's owner, so it blocks nothing" "$(blocked)" "no"

# E3 the SOLE unnamable run, undatable. Counted as a candidate (E4 needs that) and never the
# owner, which is the same two-sided ruling section C asserts for a named run.
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    current_phase: "2-review", started_at: "2026-01-01T00:00:00Z",
    updated_at: "not-a-date", branch: "b", events: [],
  }));' "$J/.pipeline/tracker-unreachable-20260902/status.json"
stop "$J"
assert_eq "E3: an UNDATABLE unnamable run is never the resolved owner either" "$(blocked)" "no"

# E4 and it still COUNTS: an undatable unnamable run beside an in-flight one is two candidates,
# so neither is adopted. Without the counting half, the in-flight one would be adopted as the
# sole orphan and a stop would be blocked on a guess.
mkdir -p "$J/.pipeline/tracker-unreachable-20260901"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    current_phase: "2-review", started_at: "2026-09-01T00:00:00Z",
    updated_at: new Date(Date.now() - 60000).toISOString(), branch: "b", events: [],
  }));' "$J/.pipeline/tracker-unreachable-20260901/status.json"
mkinvalid "$J/.pipeline/tracker-unreachable-20260901"
stop "$J"
assert_eq "E4: an undatable unnamable run still COUNTS, so two of them abstain" "$(blocked)" "no"
assert_contains "E4: and the abstention names both" "$ERR" "unnamed-run-ambiguous"

# E4 CONTROL: remove the undatable one from the candidate set by CONCLUDING it, and the in-flight
# orphan is the sole candidate again -- so E4's silence is the counting rule and not a dead path.
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    current_phase: "2-review", started_at: "2026-01-01T00:00:00Z",
    updated_at: "not-a-date", branch: "b", events: [], final_verdict: "APPROVE",
  }));' "$J/.pipeline/tracker-unreachable-20260902/status.json"
stop "$J"
assert_eq "E4 CONTROL: concluding it narrows the set to one and the deny returns" "$(blocked)" "yes"
assert_eq "E4 CONTROL: scoped to the in-flight unnamable run" "$(scoped)" "tracker-unreachable-20260901"

# =============================================================================================
suite "#109 F: the sentinel that asks the resolver 'with no marker' is declared ONCE"
# =============================================================================================
#
# A second copy of a shared vocabulary is the drift this repo has paid for twice already
# (voice-lint's private /^\d+$/ hiding exp- runs; the IN_FLIGHT_MS pair that needed a suite of
# its own to stay honest). gate-phase-entry.mjs already imports from the validator, so this one
# is a single declaration rather than a pinned pair.
DECLS=$(grep -c '^export const MTIME_ONLY' "$SCRIPTS_DIR/validate-pipeline-artifact.mjs")
assert_eq "F: the validator declares the sentinel exactly once" "$DECLS" "1"
assert_eq "F: gate-phase-entry.mjs declares no second copy" \
  "$(grep -c 'const MTIME_ONLY *=' "$SCRIPTS_DIR/gate-phase-entry.mjs")" "0"
assert_contains "F: it imports the shared one instead" \
  "$(grep -n 'MTIME_ONLY' "$SCRIPTS_DIR/gate-phase-entry.mjs")" "import"
# And the sentinel still does its job: a value ISSUE_DIR_RE rejects, so the marker branch fails
# over. Asserted against the shipped regex rather than by eyeballing the literal.
assert_eq "F: the sentinel is a name the issue-dir shape REJECTS (else it would resolve a dir)" \
  "$(node --input-type=module -e "
     const m = await import('file://$SCRIPTS_DIR/validate-pipeline-artifact.mjs');
     process.stdout.write(m.ISSUE_DIR_RE.test(m.MTIME_ONLY) ? 'accepted' : 'rejected');")" \
  "rejected"

finish
