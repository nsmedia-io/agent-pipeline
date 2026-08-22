#!/usr/bin/env bash
# gate-phase-entry.mjs -- the decision function itself, driven through its CLI.
#
# WHAT THIS SUITE IS. Phase sequencing in commands/pipeline.md is prose addressed to the
# orchestrator, and the orchestrator is the component that decides what runs next. This guard
# is the first thing that REFUSES a turn whose recorded phase has no prerequisite behind it.
# Every case below drives the real process boundary stop.sh consumes -- `node
# gate-phase-entry.mjs --root <project>` -- and asserts on the decision and the reason string.
# Nothing here asserts a private helper, a call order, or the internal shape of the table.
#
# TWO THINGS THAT LOOK LIKE MISTAKES AND ARE NOT.
#   1. AC15(b) COMPUTES its `updated_at` at test time and AC15(c) uses a captured record
#      exactly as captured (2026-08-04, permanently stale). The same field is pinned in
#      opposite directions on purpose: hardcode (b) and the criterion rots into a staleness
#      test; refresh (c) and the staleness check silently stops testing anything.
#   2. AC12/AC13/AC14 assert on the DECISION STRING and never on an exit code. `granted` and
#      `not-applicable` both exit 0, so an exit-code assertion for those criteria would be
#      asserting something other than what it claims. The spec's own falsifiability pass names
#      this as the ONE mutation expected to survive.
#
# Fixture roots are new_tmpdir()s, registered and trap-removed by harness.sh. None is ever
# committed under .pipeline/, because AC19 and AC24 walk `git ls-files '.pipeline/*/status.json'`
# and a committed fixture would join their own population.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

GUARD="$SCRIPTS_DIR/gate-phase-entry.mjs"
REPO_ROOT="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel 2>/dev/null || printf '')"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# iso_hours_ago <hours> -> an ISO timestamp COMPUTED NOW. Never hardcode a date here.
iso_hours_ago() { node -e 'process.stdout.write(new Date(Date.now()-Number(process.argv[1])*3600e3).toISOString())' "$1"; }

FRESH_ISO="$(iso_hours_ago 1)"     # in flight
STALE_ISO="$(iso_hours_ago 25)"    # past the in-flight window; #63-P2 asserts that against
                                   # the value the guard exports, rather than restating it here

# ===========================================================================================
# #63 -- THE IN-FLIGHT CEILING, READ FROM THE GUARD INSTEAD OF RE-SPELLED HERE (preflight half)
#
# THE DEFECT. `IN_FLIGHT_MS` decides whether this guard evaluates a record AT ALL, and until now
# no cell in this suite pinned either side of its boundary. The measured green window was roughly
# (1.0h, 25.05h): the constant could fall to 1/23rd of its value with every assertion in the
# three gate suites still green. TWO FIXED FIXTURE AGES WOULD REPRODUCE THAT DEFECT AT NEW
# COORDINATES, so both ages below are COMPUTED from the value the module exports, and the only
# remaining bound on the VALUE is the pair of premise cells at the bottom of this block.
#
# THE PATH RULE, STATED ONCE AND NOT RESTATED AT EACH CELL. Three resolutions are in play and
# mixing them is the collision this section is most likely to be broken by.
#   - #63-A1/#63-A2 (the export and its value) and #63-D1/#63-D2/#63-D3 (the module-shape pins
#     the declared survivor rests on) read the CHECKOUT, `$REPO_ROOT/plugins/pipeline/scripts/
#     gate-phase-entry.mjs`. REPO_ROOT derives from PLUGIN_ROOT, which no SCRIPTS_DIR redirect
#     moves. Bind those to $GUARD instead and they go RED under the rewritten copy described
#     below WITH THE CHECKOUT UNTOUCHED -- a red cell about nothing, and one that falsifies the
#     expected-red declaration below for a reason unrelated to the constant.
#   - The two off-checkout copies (#63-C1..#63-C3, #63-V1..#63-V3) resolve $SCRIPTS_DIR, which
#     harness.sh:11 leaves overridable.
#   - probe43 expands $GUARD at CALL time, so `GUARD="<copy>" probe43 ...` drives a copy for
#     exactly that call. On /bin/bash 3.2.57 a prefix assignment before a FUNCTION call is scoped
#     to the call (`G=outer; G=inner f; echo $G` prints `outer`); no subshell, no global rebind.
#
# DRIFT IMMUNITY, AND WHAT A REWRITTEN RUN IS EXPECTED TO LOOK LIKE. harness.sh:11 is
# `SCRIPTS_DIR="${SCRIPTS_DIR:-...}"`, so
#     SCRIPTS_DIR=<tmpdir copy of the WHOLE scripts dir, constant rewritten> \
#       /bin/bash plugins/pipeline/tests/test-gate-phase-entry.sh
# drives a different ceiling with the checkout untouched. At 24h and at 2h THIS suite is fully
# green -- so the declaration below DISCRIMINATES rather than merely permits. At 48h EXACTLY TWO
# cells in THIS suite are expected red, and both fail for the same correct reason, that STALE_ISO
# is a 25h LITERAL and 25h is legitimately INSIDE a 48h window:
#     (i) the existing label `(a) 25h old, no final verdict -> not-applicable even at a guarded
#         phase`, and (ii) #63-P2 below.
# Leave those red or record them. Do NOT rebase STALE_ISO onto the constant (out of scope) and do
# NOT delete #63-P2. Neither red is evidence against the derivation.
#
# SCRIPTS_DIR IS NOT TRANSPARENT, AND THE NON-TRANSPARENCY IS NOT THIS CONSTANT'S DOING. Measured
# in three checkouts on ONE machine and ONE toolchain (bash 3.2.57(1)-release
# x86_64-apple-darwin25, node v24.19.0 -- three observations, not three environments): an
# UNMODIFIED whole-directory copy under SCRIPTS_DIR leaves THIS suite at 462/0 and takes
# test-gate-phase-entry-hook.sh from 59/0 to 57/2 at EVERY ceiling value (24h, 2h and 48h alike),
# because test-voice-lint.sh itself measures 44/4 under a redirected SCRIPTS_DIR. So a WHOLE-SET
# run at 48h shows THREE reds, not two: this suite's two, plus the hook suite's two-cell artefact
# of the REDIRECTION. Whoever re-derives this months from now reads this file, not a PR body.
#
# TWO MUTATIONS ARE EXPECTED TO SURVIVE THIS SECTION, each with a stated mechanism, because a
# battery in which everything reddens cannot tell coverage from a rubber stamp.
#   1. `inFlight`'s `now - updated <= IN_FLIGHT_MS` -> `<`. The two spellings differ only when the
#      age is exactly IN_FLIGHT_MS to the MILLISECOND, and the guard reads its own Date.now() in a
#      child process started AFTER the fixture was written, so no CLI-driven fixture lands there.
#      The residual is bounded to one millisecond and points toward ABSTENTION -- a silence, not a
#      falsehood. #63-D1/#63-D2/#63-D3 pin the CHEAP ways that premise stops holding (a re-spelled
#      clock, an override folded into the single read, an added `inFlight` export). THEY DO NOT
#      CLOSE THE CLASS: an override threaded into `inFlight`'s `now` ARGUMENT at its call site
#      leaves all three green and makes the guard's clock millisecond-exact from outside. That
#      remains a REVIEW OBLIGATION on any future edit to that argument, not a mechanized guarantee.
#   2. probe43's `age > CEIL` -> `>=`, the exact COMPLEMENT of (1), unreachable for the same
#      reason. #63-V5 makes that BRANCH live -- before it, deleting the staleness push entirely
#      left this suite at 462/0 -- which buys liveness, not falsifiability. The OPERATOR stays
#      unpinned and this section does not claim otherwise.
# If either ever reddens, something changed about the CLOCK, not about the boundary.
# ===========================================================================================

# MARGIN: how far each boundary fixture sits from the ceiling, on both sides. A LITERAL, pinned
# here rather than left to a caller, by a two-sided rule -- at least two orders of magnitude above
# the measured fixture-write-to-gate-return elapsed (237/227/239 ms over three runs, so ~1250x
# headroom, and #63-E1 ASSERTS that headroom rather than assuming it), and under 1% of the window
# (0.35% at 24h). Note the grain: that elapsed is fixture-write-to-gate-RETURN, which is not the
# 80-90 ms figure for a bare CLI invocation. The two measure different spans.
MARGIN=300000

# The #63 id ledger. Its own, not an extension of #43's or #61's: their Z2 cells grep `#43-...`
# and `#61-...` and a `#63-` id would not match either, so the three are independent by
# construction. Every `#63-` id is registered as its cell RUNS, and #63-Z2 at the bottom of this
# file compares that against every `#63-` id written in this file's SOURCE -- comments included.
# So do not write a `#63-<suffix>` in a comment unless a cell registers it.
AC63_IDS=""
reg63() { AC63_IDS="$AC63_IDS$1
"; }

# iso_ms_ago <ms> -> an ISO timestamp COMPUTED NOW, at MILLISECOND grain. `iso_hours_ago` above
# cannot express a margin small enough to sit inside the window without rounding it away.
iso_ms_ago() { node -e 'process.stdout.write(new Date(Date.now()-Number(process.argv[1])).toISOString())' "$1"; }

# ac63_age_vs_ceiling <iso> <ceiling-ms> -> `inside` | `outside` | `exactly-at-the-ceiling` | a
# diagnosis. Three-way on purpose: folding equality into either side would let a premise cell
# claim a strictness it never checked.
ac63_age_vs_ceiling() {
  node -e '
    const CEIL = Number(process.argv[2]);
    if (!Number.isFinite(CEIL) || CEIL <= 0) { process.stdout.write("the exported IN_FLIGHT_MS did not read as a finite positive number"); process.exit(0); }
    const parsed = Date.parse(process.argv[1]);
    if (!Number.isFinite(parsed)) { process.stdout.write("NOT DATABLE: " + JSON.stringify(process.argv[1])); process.exit(0); }
    const age = Date.now() - parsed;
    process.stdout.write(age < CEIL ? "inside" : age > CEIL ? "outside" : "exactly-at-the-ceiling");
  ' "$1" "$2"
}

# ac63_capture_staleness <status.json> <ceiling-ms> -> `stale` | `REFRESHED` | the validation
# sentence. EXTRACTED rather than left inline at its one call site, because #63-V4 has to drive
# THE SAME FUNCTION the capture tripwire calls; an exercise against a COPY of the tripwire would
# be testing a copy of the check rather than the check.
#
# THE GUARD IS NOT DEFENCE IN DEPTH HERE. A substituted read can arrive as `undefined` or as an
# empty shell argument where a literal could not, and `age > undefined` and `age > NaN` are both
# FALSE -- so an unvalidated site answers `REFRESHED` about a 437-hour-old capture and the
# tripwire silently retires. `Number("") === 0`, so an EMPTY argument is caught by the `CEIL <= 0`
# half and not by `isFinite`: both halves are required, and the argument must be QUOTED at every
# call site or an empty one vanishes and shifts argv.
ac63_capture_staleness() {
  node -e '
    const CEIL = Number(process.argv[2]);
    if (!Number.isFinite(CEIL) || CEIL <= 0) { process.stdout.write("the exported IN_FLIGHT_MS did not read as a finite positive number"); process.exit(0); }
    const s = require(process.argv[1]);
    process.stdout.write((Date.now() - new Date(s.updated_at).getTime()) > CEIL ? "stale" : "REFRESHED");
  ' "$1" "$2"
}

# ac63_read_state <read> <margin> -> `ok`, or a diagnosis that NAMES what came back.
ac63_read_state() {
  node -e '
    const raw = process.argv[1], margin = Number(process.argv[2]);
    if (raw === "") { process.stdout.write("the read produced NOTHING: the import failed, or the module threw before it could be read"); process.exit(0); }
    if (raw === "undefined") { process.stdout.write("the module exports no IN_FLIGHT_MS: the read came back as the string \"undefined\""); process.exit(0); }
    const n = Number(raw);
    if (!Number.isFinite(n)) { process.stdout.write("the read is not a finite number: " + JSON.stringify(raw)); process.exit(0); }
    if (!Number.isInteger(n)) { process.stdout.write("the read is not an integer: " + JSON.stringify(raw)); process.exit(0); }
    if (!(n > 2 * margin)) { process.stdout.write("the read is " + n + ", which is not strictly greater than 2*MARGIN (" + (2 * margin) + ")"); process.exit(0); }
    process.stdout.write("ok");
  ' "$1" "$2"
}

# THE READ: ONCE, here, through the dynamic-import path probe43 already uses. Everything #63
# derives is derived from this one value.
IN_FLIGHT_MS="$(node --input-type=module -e 'const m = await import(process.argv[1]); process.stdout.write(String(m.IN_FLIGHT_MS))' "$GUARD" 2>/dev/null)"

# ---------------------------------------------------------------------------
suite "#63 preflight: the ceiling is READ from the guard, and asserted before anything derives from it"
# ---------------------------------------------------------------------------
AC63_READ_STATE="$(ac63_read_state "$IN_FLIGHT_MS" "$MARGIN")"
reg63 "#63-R1"
assert_eq "#63-R1 the ceiling read out of the guard is a finite INTEGER strictly greater than 2*MARGIN -- \"a positive integer of plausible magnitude\" is one adjective short of the precondition the fixtures need: any value at or below MARGIN makes the INSIDE age IN_FLIGHT_MS - MARGIN zero or NEGATIVE, which dates that fixture in the FUTURE, and the guard has no floor, so a future-dated record is PERMANENTLY in flight" \
  "$AC63_READ_STATE" "ok"

# THE HALT, AND WHY IT IS NOT BELT-AND-BRACES. Measured against a real export-only build: with an
# EMPTY read -- the one spelling `set -u` does NOT catch, since $(( IN_FLIGHT_MS - MARGIN )) then
# yields -300000 with rc 0 and no diagnostic -- the INSIDE fixture is dated in the FUTURE and
# #63-B1 PASSES, the #63-C1..#63-C3 control's shift goes negative so every record falls out of
# flight and #63-C3 PASSES too, and ONLY #63-B2 reddens, with a message that says nothing about
# the read. Two of the three boundary cells go green VACUOUSLY. Halting here is the only thing
# that turns that one-cell red into a diagnosis.
#
# THE SPELLING IS LOAD-BEARING: `finish || exit 1`, never a bare `exit`. A bare exit skips
# finish(), so the run prints no passed=/failed= tally AND never runs the harness's
# uncounted-assertion guard. The assertion above fires FIRST so the failure is a COUNTED red cell
# in the ledger rather than a bare message.
if [[ "$AC63_READ_STATE" != "ok" ]]; then
  printf '\n#63 HALT: %s\n' "$AC63_READ_STATE" >&2
  printf '       Every age this suite derives from that value is meaningless, and two of the three\n' >&2
  printf '       boundary cells would go GREEN VACUOUSLY rather than red. Refusing to report on them.\n' >&2
  printf '       The guard must export IN_FLIGHT_MS (see #63-A1). If this is a partial revert that\n' >&2
  printf '       dropped the export while keeping this suite, restore the export or revert both.\n' >&2
  finish || exit 1
fi

# THE TWO PREMISES. These carry more weight than their own cells and are NOT a nicety a later
# author may tidy away. FRESH_ISO and STALE_ISO are load-bearing for 400-plus assertions in this
# file and their in/out status was, until now, assumed and never stated.
reg63 "#63-P1"
assert_eq "#63-P1 FRESH_ISO is INSIDE the ceiling. This is the only thing standing between the corpus walk's zero (\`no committed record is refused by the table\`) and a VACUOUS green: that walk rewrites every committed record's updated_at to FRESH_ISO precisely so staleness cannot mask the table, and its pass set is granted|not-applicable -- so if FRESH_ISO ever fell OUTSIDE, every corpus record would abstain and the zero would stay green over a wholly abstaining population. DIAGNOSIS, not sole detection: ~234 other cells redden in the same run" \
  "$(ac63_age_vs_ceiling "$FRESH_ISO" "$IN_FLIGHT_MS")" "inside"
reg63 "#63-P2"
assert_eq "#63-P2 STALE_ISO is OUTSIDE the ceiling. With #63-P1 this brackets the VALUE of IN_FLIGHT_MS to roughly (1.0h, 25.05h), which is the only bound the DERIVED cells contribute -- they read the value and are therefore value-independent. It is NOT the tightest bound in #63, and an earlier draft of this label said it was: #63-A2 pins the constant's exact SOURCE TEXT, is neither derived nor value-independent, and is strictly tighter -- MEASURED, a rewrite of the shipped constant to 2h leaves this cell GREEN and reddens #63-A2 as the sole red. So do not read this label as licence to delete #63-A2 as redundant. EXPECTED RED, and correctly so, under a rewrite of the constant to 48h: STALE_ISO is a 25h literal and 25h is legitimately inside a 48h window" \
  "$(ac63_age_vs_ceiling "$STALE_ISO" "$IN_FLIGHT_MS")" "outside"

# new_case <issue-dir-name> <status-json> -> CASE_ROOT, CASE_DIR
new_case() {
  new_tmpdir || exit 90
  CASE_ROOT="$NEW_TMPDIR"
  CASE_DIR="$CASE_ROOT/.pipeline/$1"
  mkdir -p "$CASE_DIR"
  printf '%s' "$2" > "$CASE_DIR/status.json"
}

# mk_status <phase> <tier> <events-json-array> [extra-top-level-json-with-leading-comma]
mk_status() {
  printf '{"issue_number":4242,"current_phase":"%s","risk_tier":%s,"updated_at":"%s","events":%s%s}' \
    "$1" "$2" "${MK_UPDATED:-$FRESH_ISO}" "$3" "${4:-}"
}

# capture <src-status.json> <dest> <patch-json>   (a null value in the patch DELETES the key)
capture() {
  node -e '
    const fs=require("fs");
    const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const p=JSON.parse(process.argv[3]);
    for (const k of Object.keys(p)) { if (p[k]===null) delete s[k]; else s[k]=p[k]; }
    fs.writeFileSync(process.argv[2], JSON.stringify(s,null,2));
  ' "$1" "$2" "$3"
}

# gate <root> -> GATE_RC, GATE_OUT, GATE_ERR, GATE_DEC, GATE_ISSUE
# The guard prints ONE JSON line on a decision. `decision` and `issue_dir` are bounded values,
# read with a bounded sed; `reason` is matched by substring so its wording stays Dev's.
gate() {
  local root="$1" errf="$1/.gate-stderr.txt"
  GATE_OUT="$( cd "$root" && node "$GUARD" --root "$root" 2>"$errf" )"
  GATE_RC=$?
  GATE_ERR="$(cat "$errf" 2>/dev/null)"
  GATE_DEC="$(printf '%s' "$GATE_OUT" | sed -n 's/.*"decision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$GATE_DEC" ]] || GATE_DEC="<no-decision-on-stdout>"
  GATE_ISSUE="$(printf '%s' "$GATE_OUT" | sed -n 's/.*"issue_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$GATE_ISSUE" ]] || GATE_ISSUE="<no-issue-dir-on-stdout>"
}

NO_EVENTS='[]'
SPEC_APPROVED='{"ba_approved_at":"2026-01-01T00:00:00Z"}'

# The 15 guarded rows: <phase>|<tier fixture uses>|<prerequisite filename>|<artifact body>
# `-` in the filename column is the ONE row with no prerequisite (0.5-map). See FINDING-2 in
# tasks.json: AC1 says all 15 refuse, the prerequisite table says this row always grants. The
# table wins, and the exception is asserted positively below rather than quietly dropped.
GUARDED_ROWS=(
  "0.5-map|architectural|-|-"
  "1-ba|architectural|map.json|{}"
  "2-constraints|standard|spec.json|$SPEC_APPROVED"
  "2-review|architectural|spec.json|$SPEC_APPROVED"
  "2.5-design|architectural|review.json|{}"
  "3-impl|architectural|design.json|{}"
  "4-review|architectural|impl-report.json|{}"
  "5-archive|architectural|peer-review.json|{}"
  "0.5-map-complete|architectural|map.json|{}"
  "1-ba-complete|architectural|spec.json|{}"
  "2-constraints-complete|standard|constraints.md|# constraints"
  "2-review-complete|architectural|review.json|{}"
  "2.5-design-complete|architectural|design.json|{}"
  "3-impl-complete|architectural|impl-report.json|{}"
  "4-review-complete|architectural|peer-review.json|{}"
)

# THE SECOND PREREQUISITE (#61 R9b), held in a COMPANION table rather than by widening the one
# above. GUARDED_ROWS is `<phase>|<tier>|<filename>|<body>` -- ONE filename -- and #61 gives the
# `2-review` row a SECOND required file. Widening the field would move all 15 entries, and three
# count assertions plus #43-S1 are pinned to them, so the second file lives here keyed by phase
# and every sweep that builds a SATISFIED fixture consults it.
#
# AN INDEXED ARRAY PLUS A LINEAR SCAN, NEVER `declare -A`. `/bin/bash` on macOS is 3.2.57, which
# has no associative arrays, and run.sh invokes each suite as `bash "$t"` -- PATH bash, not the
# shebang. ubuntu-latest ships bash 5, so a `declare -A` here would pass CI and fail every
# contributor running the documented local check, in the one direction nobody catches. Re-derive
# the interpreter with `/bin/bash --version`.
#
# <phase>|<filename>|<body>
EXTRA_PREREQS=(
  "2-review|map.json|{}"
)

# write_extra_prereqs <phase> <dir> -> writes every companion file for <phase> into <dir> and
# echoes the filenames it wrote, space-joined (empty for a row with no second prerequisite).
# Every caller asserts the echoed value against a LITERAL rather than against this table, so a
# typo'd phase key here fails loudly instead of quietly handing a cell a one-file fixture.
write_extra_prereqs() {
  local phase="$1" dir="$2" e rest file body wrote=""
  for e in "${EXTRA_PREREQS[@]}"; do
    case "$e" in
      "$phase|"*)
        rest="${e#"$phase|"}"
        file="${rest%%|*}"
        body="${rest#*|}"
        printf '%s' "$body" > "$dir/$file"
        wrote="$wrote $file"
        ;;
    esac
  done
  printf '%s' "${wrote# }"
}

# The literal each sweep expects, stated INDEPENDENTLY of EXTRA_PREREQS. Deriving it from the
# same table would make the probe a restatement of the table instead of an observation of it.
expected_extra_61() {  # <phase> -> the filenames that phase's fixture must also carry
  case "$1" in
    2-review) printf 'map.json' ;;
    *)        printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
suite "AC1: every guarded row refuses an empty fixture, and says what is missing"
# ---------------------------------------------------------------------------
assert_eq "the table under test has 15 guarded rows (8 entry + 7 exit)" "${#GUARDED_ROWS[@]}" "15"

AC1_REFUSING=0
for row in "${GUARDED_ROWS[@]}"; do
  IFS='|' read -r phase tier prereq _body <<< "$row"
  new_case 4242 "$(mk_status "$phase" "\"$tier\"" "$NO_EVENTS")"
  gate "$CASE_ROOT"
  if [[ "$prereq" == "-" ]]; then
    # The documented exception: the first guarded phase has no prerequisite to be absent.
    assert_eq "AC1 exception: $phase has no prerequisite and is granted" "$GATE_DEC" "granted"
    continue
  fi
  AC1_REFUSING=$((AC1_REFUSING + 1))
  assert_eq "$phase ($tier) with no artifact and no events is REFUSED" "$GATE_DEC" "refused"
  assert_eq "and the refusal exits 2" "$GATE_RC" "2"
  assert_contains "and the reason names the phase ($phase)" "$GATE_OUT" "$phase"
  assert_contains "and the reason names the missing prerequisite ($prereq)" "$GATE_OUT" "$prereq"
  assert_contains "and the reason names the issue dir (4242)" "$GATE_OUT" "4242"
done
assert_eq "14 rows can refuse; the 15th is the no-prerequisite exception" "$AC1_REFUSING" "14"

# ---------------------------------------------------------------------------
suite "AC2: every guarded row grants once ITS OWN prerequisite artifact is present"
# ---------------------------------------------------------------------------
AC2_ROWS=0
for row in "${GUARDED_ROWS[@]}"; do
  IFS='|' read -r phase tier prereq body <<< "$row"
  [[ "$prereq" == "-" ]] && continue
  AC2_ROWS=$((AC2_ROWS + 1))
  new_case 4242 "$(mk_status "$phase" "\"$tier\"" "$NO_EVENTS")"
  printf '%s' "$body" > "$CASE_DIR/$prereq"
  # #61 R9(b): a row may require a SECOND file. Written before the gate runs, and the fixture's
  # own shape asserted against a literal below, so a cell that silently stopped carrying its
  # second prerequisite cannot go on granting for the wrong reason.
  ac2_extra="$(write_extra_prereqs "$phase" "$CASE_DIR")"
  assert_eq "  fixture shape: $phase carries every SECOND prerequisite its row requires" \
    "$ac2_extra" "$(expected_extra_61 "$phase")"
  gate "$CASE_ROOT"
  assert_eq "$phase ($tier) with $prereq present is GRANTED" "$GATE_DEC" "granted"
  assert_eq "and it exits 0" "$GATE_RC" "0"
done
assert_eq "each row exercised its OWN filename, not one shared one" "$AC2_ROWS" "14"

# ---------------------------------------------------------------------------
suite "AC3: the two-source rule -- a committed events[] grants what a gitignored artifact cannot"
# ---------------------------------------------------------------------------
# CAPTURED from the live record, not hand-written: every per-issue artifact except status.json
# is gitignored, so a resumed run in a fresh checkout has ONLY the committed events[]. The
# capture keeps issue 17's real suffixed labels (1-ba-rework, 2-review-r2, 3a-qa-tests, 3b-dev).
REC17="$REPO_ROOT/.pipeline/17/status.json"
assert_eq "the captured record exists (a missing capture must fail, not skip)" \
  "$([[ -f "$REC17" ]] && echo present || echo "MISSING: $REC17")" "present"
# Presence, not an occurrence count: the label appears in events[] AND in flags[], and a count
# assertion here would be red for a reason that has nothing to do with the criterion.
assert_eq "and it still carries the suffixed 3b-dev label this criterion rests on" \
  "$(node -e 'const s=require(process.argv[1]);process.stdout.write((s.events||[]).some(e=>e.phase==="3b-dev")?"present":"MISSING")' "$REC17")" \
  "present"

new_case 17 '{}'
# updated_at MUST be rewritten: the record is 2026-08-19T04:15Z and would fall outside R6's
# in-flight window, so a stale capture would pass this criterion while proving nothing.
capture "$REC17" "$CASE_DIR/status.json" "{\"updated_at\":\"$FRESH_ISO\"}"
gate "$CASE_ROOT"
assert_eq "issue 17 at 3-impl-complete, no impl-report.json on disk, is GRANTED by its 3b-dev event" \
  "$GATE_DEC" "granted"

# ---------------------------------------------------------------------------
suite "AC4: event labels resolve through the shared resolver and compare by SET MEMBERSHIP"
# ---------------------------------------------------------------------------
# DO NOT inline the events array as "[{\"phase\":...}]". Inside "$(...)" the escaped quotes
# collapse, the braces end up UNQUOTED, and bash brace-expands `{a,b,c}` into three words: the
# fixture that reaches disk is `"events":["phase":"3b-dev"]`, which is not valid JSON, so the
# guard reads it as a tooling failure and the case tests silence instead of set membership.
# Built in a variable, where no brace expansion happens, exactly like AC7's single-quoted form.
ac4() {  # ac4 <event-label> <expected-decision>
  local events='[{"phase":"'"$1"'","verdict":"complete","at":"'"$FRESH_ISO"'"}]'
  new_case 4242 "$(mk_status "4-review" '"architectural"' "$events")"
  gate "$CASE_ROOT"
  assert_eq "events[] label '$1' against the 4-review row {3,3b} -> $2" "$GATE_DEC" "$2"
}
ac4 "3b-dev" granted     # suffixed: a shape regex reads this as nothing (phaseKey's own docstring)
ac4 "3-impl" granted     # bare token
ac4 "9-nope" refused     # not in KNOWN_PHASES -> phaseKey returns null -> satisfies nothing

# ---------------------------------------------------------------------------
suite "AC5: NEGATIVE -- 2.5-design does not self-grant, and its SKIPPED note does not leak"
# ---------------------------------------------------------------------------
# Under a prefix implementation '2.5'.startsWith('2') is TRUE, so the record cited as the
# escape hatch's own precedent would self-grant the Phase 2 review gate it skipped. The
# 2.5-design row's satisfying set is {2}, so its own token is NOT a member. Two fixtures,
# because the plain-satisfaction half and the hatch half fail independently.
#
# WHY THE HATCH HALF IS NOT THE WHOLE ISSUE-17 RECORD, which is what the spec's AC5 text names.
# That record carries TWO events resolving to token 2 (2-review and 2-review-r2, both
# REQUEST_CHANGES), and {2} IS the 2.5-design row's satisfying set, so the whole record is
# granted through an entry that has nothing to do with the skip. AC9's second cell asserts
# exactly that pairing GRANTS ("a review that demanded changes still ran"), so demanding
# `refused` on a superset of AC9's own fixture asks the guard for two answers to one input.
# Measured, not reasoned: under the prefix mutation A4 the whole-record fixture is `granted`
# too, so it never discriminated the reading AC5 names -- it was red either way.
#
# The two cells below are the discriminating PAIR. They differ in exactly one thing: whether
# the other entries are present. (i) fixes the confound in place, so the narrowing is recorded
# in the suite rather than lost; (ii) is AC5's actual property, on the capture's REAL skip
# entry with its real note, and is the only cell in this suite that a hatch which self-clears
# the row it names can redden. Cell 3 below cannot: its entry is not SKIPPED.
assert_eq "the capture still carries the SKIPPED 2.5-design entry this criterion rests on" \
  "$(grep -c '"SKIPPED"' "$REC17" 2>/dev/null | tr -d ' ')" "1"
# The confound, named. If anyone strips these the pair below stops discriminating, and this
# fails loudly instead of the criterion quietly retiring.
assert_eq "and it carries a non-SKIPPED 2-review* entry, which is WHY the whole record grants" \
  "$(node -e 'const s=require(process.argv[1]);process.stdout.write(String((s.events||[]).filter(e=>/^2-review/.test(e.phase||"")&&e.verdict!=="SKIPPED").length))' "$REC17")" \
  "2"

# (i) THE CONFOUND, asserted positively rather than deleted: the whole record at 2.5-design is
#     granted, and the next cell shows what it is granted BY.
new_case 17 '{}'
capture "$REC17" "$CASE_DIR/status.json" "{\"current_phase\":\"2.5-design\",\"updated_at\":\"$FRESH_ISO\"}"
gate "$CASE_ROOT"
assert_eq "the WHOLE record at 2.5-design is granted -- by its 2-review entries, per AC9" "$GATE_DEC" "granted"

# (ii) the same capture, events narrowed to the REAL skip entry alone (derived from the record,
#      never hand-written). Nothing else can satisfy the row, so the decision is now a statement
#      about the hatch and about nothing else.
AC5_HATCH_PATCH="$(node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const e = (s.events || []).find((x) => x.phase === "2.5-design" && x.verdict === "SKIPPED");
  process.stdout.write(JSON.stringify({
    current_phase: "2.5-design", updated_at: process.argv[2], events: e ? [e] : [],
  }));
' "$REC17" "$FRESH_ISO")"
assert_eq "  the narrowed fixture really carries that entry, with its real non-empty note" \
  "$(printf '%s' "$AC5_HATCH_PATCH" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const e=(JSON.parse(b).events||[])[0];process.stdout.write(e&&e.verdict==="SKIPPED"&&String(e.note||"").trim()!==""?"skip-with-note":"MISSING")})')" \
  "skip-with-note"
new_case 17 '{}'
capture "$REC17" "$CASE_DIR/status.json" "$AC5_HATCH_PATCH"
gate "$CASE_ROOT"
assert_eq "the SKIPPED 2.5-design entry does NOT fire the hatch for the 2.5-design row" "$GATE_DEC" "refused"
assert_contains "and the refusal names the review.json it is still missing" "$GATE_OUT" "review.json"

AC5_EVENTS='[{"phase":"2.5-design","verdict":"complete","at":"'"$FRESH_ISO"'"}]'   # see the ac4 note
new_case 4242 "$(mk_status "2.5-design" '"architectural"' "$AC5_EVENTS")"
gate "$CASE_ROOT"
assert_eq "and a plain 2.5-design event does not satisfy the 2.5-design row either" "$GATE_DEC" "refused"

# ---------------------------------------------------------------------------
suite "AC6: NEGATIVE -- QA authored the contract, Dev never ran, so the run is not panel-ready"
# ---------------------------------------------------------------------------
# The generic repair for AC4 (map every 3x -> 3) opens this by construction. What must break
# is 'a run where Dev never ran is not panel-ready', not 'the string 3a is absent from a list'.
# TWO cells: 4-review and 3-impl-complete are separate rows that share the set {3,3b}, and
# asserting one leaves the other's set unmutated.
QA_ONLY='[{"phase":"3a-qa-tests","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'
for p in "4-review" "3-impl-complete"; do
  new_case 4242 "$(mk_status "$p" '"architectural"' "$QA_ONLY")"
  gate "$CASE_ROOT"
  assert_eq "3a-qa-tests alone does NOT satisfy the $p row (its set excludes 3a)" "$GATE_DEC" "refused"
  assert_contains "and the refusal names impl-report.json" "$GATE_OUT" "impl-report.json"
done

# ---------------------------------------------------------------------------
suite "AC7/AC8: the recorded-deviation hatch, and the written reason it costs"
# ---------------------------------------------------------------------------
new_case 4242 "$(mk_status "3-impl" '"architectural"' \
  '[{"phase":"2.5-design","verdict":"SKIPPED","at":"2026-01-01T00:00:00Z","note":"design space closed; owner informed"}]')"
gate "$CASE_ROOT"
assert_eq "AC7: a SKIPPED 2.5-design with a written reason clears entry to 3-impl" "$GATE_DEC" "granted"

# Three cells. A single 'note absent' fixture passes under a truthiness check that a
# whitespace-only string defeats, which is the whole point of the trim.
ac8() {  # ac8 <label> <note-json-fragment-or-empty>
  local events='[{"phase":"2.5-design","verdict":"SKIPPED","at":"2026-01-01T00:00:00Z"'"$2"'}]'  # see the ac4 note
  new_case 4242 "$(mk_status "3-impl" '"architectural"' "$events")"
  gate "$CASE_ROOT"
  assert_eq "AC8: a skip with $1 is REFUSED" "$GATE_DEC" "refused"
}
ac8 "no note at all"        ""
ac8 "an empty note"         ',"note":""'
ac8 "a whitespace-only note" ',"note":"   "'

# ---------------------------------------------------------------------------
suite "AC9: path (b) needs a token, never a verdict"
# ---------------------------------------------------------------------------
# events[].verdict is OPTIONAL in status.schema.json and a committed record carries six
# verdict-less events, so any verdict-keyed rule rejects a schema-valid record.
REC_STC="$REPO_ROOT/.pipeline/exp-script-test-coverage/status.json"
assert_eq "the verdict-less capture exists" \
  "$([[ -f "$REC_STC" ]] && echo present || echo "MISSING: $REC_STC")" "present"
assert_eq "and its 4-review event still carries no verdict key" \
  "$(node -e 'const s=require(process.argv[1]);const e=(s.events||[]).find(x=>x.phase==="4-review");process.stdout.write(e&&!("verdict" in e)?"verdictless":"CHANGED")' "$REC_STC")" \
  "verdictless"

new_case exp-script-test-coverage '{}'
capture "$REC_STC" "$CASE_DIR/status.json" "{\"updated_at\":\"$FRESH_ISO\",\"final_verdict\":null}"
gate "$CASE_ROOT"
assert_eq "a verdict-LESS 4-review event satisfies the 4-review-complete row" "$GATE_DEC" "granted"

# The other direction: a REJECTING verdict must also satisfy. The artifact a path-(b) event
# stands in for exists whatever the verdict says, and a review that demanded changes still ran.
new_case 4242 "$(mk_status "2.5-design" '"architectural"' \
  '[{"phase":"2-review","verdict":"REQUEST_CHANGES","at":"2026-01-01T00:00:00Z"}]')"
gate "$CASE_ROOT"
assert_eq "a REQUEST_CHANGES 2-review event still satisfies the 2.5-design row" "$GATE_DEC" "granted"

# ---------------------------------------------------------------------------
suite "AC10: 3-impl over the FULL tier x presence cross product (6 cells, own filename each)"
# ---------------------------------------------------------------------------
# A representative fixture is insufficient: this is a compound predicate, and every fixture
# sitting in one cell of the conjunction leaves the other branch unrun.
ac10() {  # ac10 <tier> <prereq-filename> <body> <present|absent> <expected>
  new_case 4242 "$(mk_status "3-impl" "\"$1\"" "$NO_EVENTS")"
  [[ "$4" == "present" ]] && printf '%s' "$3" > "$CASE_DIR/$2"
  gate "$CASE_ROOT"
  assert_eq "3-impl at $1 with $2 $4 -> $5" "$GATE_DEC" "$5"
  [[ "$5" == "refused" ]] && assert_contains "  and it names $2, not another tier's file" "$GATE_OUT" "$2"
  return 0
}
ac10 trivial       spec.json      '{}'             present granted
ac10 trivial       spec.json      '{}'             absent  refused
ac10 standard      constraints.md '# real content' present granted
ac10 standard      constraints.md '# real content' absent  refused
ac10 architectural design.json    '{}'             present granted
ac10 architectural design.json    '{}'             absent  refused

# ---------------------------------------------------------------------------
suite "R3 kind: content-conditioned rows test CONTENT on path (a), not mere presence"
# ---------------------------------------------------------------------------
# NOT AN AC OF ITS OWN, and named here because the spec's own criteria do not cover it: three
# rows are marked `kind: content-conditioned` and R3 states outright that path (a) tests file
# CONTENT while path (b) tests only that the phase was DISPATCHED. Without these, an
# existsSync-only implementation satisfies every criterion in the spec while the `kind` column
# means nothing, and the guard's strength silently depends on which machine it runs on.
#
# A FIXTURE MATRIX, NOT A REPRESENTATIVE FIXTURE, and that distinction is what this block was
# missing. `prerequisiteSatisfied` is a COMPOUND predicate -- the artifact decides the row BY
# ITSELF when it is present, and events[] are consulted only when it is absent -- and every cell
# here used to build the artifact-present half with NO_EVENTS. So every fixture sat in one cell
# of the conjunction, and the branch that makes the whole `content` column dead was never run:
# `if (existsSync(p)) return contentSatisfies(p,row)` could be rewritten to
# `if (existsSync(p) && contentSatisfies(p,row)) return true` -- falling through to the events
# path on a content FAILURE -- with zero failures across all three suites. That rewrite is the
# implementation's own docstring inverted: a dispatch event for the phase is always present by
# the time its artifact is, so an unapproved spec.json would be waved through by the very event
# that recorded the BA dispatch.
#
# The cross product is therefore {absent, present-and-failing, present-and-satisfying} x {no
# events, a SATISFYING event}. Cell (absent, no events) is AC1 and is not repeated. The
# artifact-absent-with-event cell is the non-zero control that makes the rest mean anything: it
# is what proves the event in cells 1 and 2 really does satisfy the row, so a refusal alongside
# it is the ARTIFACT overriding the event rather than an inert fixture.
# The `  1. ` line of the refusal, ALONE. Asserting the repair against the whole of stderr does
# not work and this was measured: the diagnosis line names the same field the repair does, so
# `assert_contains "$GATE_ERR" ba_approved_at` passes while route 1 says something else entirely.
# A mutation that replaced the ba-approved repair with "Re-run the phase and rewrite" SURVIVED on
# the whole-stderr form. The needle has to be searched where it is supposed to be.
route1() { printf '%s' "$GATE_ERR" | sed -n 's/^  1\. //p'; }

r3_row() {  # r3_row <phase> <tier> <file> <failing-body> <satisfying-body> <event-json> <lack> <repair> <expected-second-prereq>
  local phase="$1" tier="$2" file="$3" bad="$4" good="$5" ev="$6" lack="$7" repair="$8" r1
  local want_extra="${9:-}" extra
  # #61 R9(d): every cell of this matrix varies ONE thing -- the state of $file. A row that
  # requires a SECOND file gets it in EVERY cell, so the variable stays $file and the grant cells
  # below do not silently become tests of the other requirement. The event constant is left
  # untouched for the same reason: swapping it for one that also satisfies the second half would
  # vary two things at once.
  r3_extra() { extra="$(write_extra_prereqs "$phase" "$CASE_DIR")"; }

  # 1. THE MISSING LEG: present-and-failing, WITH an event that would satisfy the row on its own.
  new_case 4242 "$(mk_status "$phase" "\"$tier\"" "$ev")"
  printf '%s' "$bad" > "$CASE_DIR/$file"
  r3_extra
  assert_eq "  fixture shape: $phase's cells carry its SECOND prerequisite, so $file stays the only variable" \
    "$extra" "$want_extra"
  gate "$CASE_ROOT"
  assert_eq "$phase ($tier): a failing $file is NOT rescued by a satisfying events[] entry" \
    "$GATE_DEC" "refused"
  assert_eq "  and the refusal exits 2" "$GATE_RC" "2"
  # The operator-facing half of the same cell. The message a blocked turn reads used to say the
  # file was NOT PRESENT and send them to re-run the phase that produced it -- both false when
  # the file is sitting in front of them, and the wrong repair either way.
  assert_not_contains "  and the refusal does not claim the file is missing" \
    "$GATE_ERR" "\`$file\` is not present"
  assert_contains "  it says the file IS present" "$GATE_ERR" "\`$file\` IS present"
  assert_contains "  and diagnoses what the file lacks ($lack)" "$GATE_ERR" "$lack"
  r1="$(route1)"
  assert_eq "  CONTROL: a route 1 line was extracted at all, so the next assertion has a haystack" \
    "$([[ -n "$r1" ]] && echo found || echo "NO ROUTE 1 LINE")" "found"
  assert_contains "  and ROUTE 1 ITSELF names the repair this row needs" "$r1" "$repair"
  assert_not_contains "  and does not send them back to the phase that already produced it" \
    "$GATE_ERR" "Run the phase that produces"

  # 2. Same fixture, same event, CONTENT REPAIRED. The twin: without it, cell 1's refusal could
  #    be about the phase, the tier or the event rather than about the content.
  new_case 4242 "$(mk_status "$phase" "\"$tier\"" "$ev")"
  printf '%s' "$good" > "$CASE_DIR/$file"
  r3_extra
  gate "$CASE_ROOT"
  assert_eq "  CONTROL: the same fixture with a SATISFYING $file is granted" "$GATE_DEC" "granted"

  # 3. The event alone, artifact absent: path (b) is weaker on purpose, and this is the cell that
  #    proves the event is live. If this ever refuses, cell 1 stops being about priority at all.
  new_case 4242 "$(mk_status "$phase" "\"$tier\"" "$ev")"
  r3_extra
  gate "$CASE_ROOT"
  assert_eq "  CONTROL: with no $file at all, that same event GRANTS (path (b) attests dispatch)" \
    "$GATE_DEC" "granted"

  # 4. Present-and-failing with NO events: the original cell, kept as a cell of the matrix.
  new_case 4242 "$(mk_status "$phase" "\"$tier\"" "$NO_EVENTS")"
  printf '%s' "$bad" > "$CASE_DIR/$file"
  r3_extra
  gate "$CASE_ROOT"
  assert_eq "  and a failing $file with no events at all is refused too" "$GATE_DEC" "refused"
}

BA_EVENT='[{"phase":"1-ba","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'
P2_EVENT='[{"phase":"2-constraints","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'

r3_row 2-review      architectural spec.json '{"issue_number":4242}' "$SPEC_APPROVED" "$BA_EVENT" \
  'carries no `ba_approved_at`' 'set `ba_approved_at` in .pipeline/4242/spec.json' 'map.json'
r3_row 2-constraints standard      spec.json '{"issue_number":4242}' "$SPEC_APPROVED" "$BA_EVENT" \
  'carries no `ba_approved_at`' 'set `ba_approved_at` in .pipeline/4242/spec.json' ''
r3_row 3-impl standard constraints.md '' '# real content' "$P2_EVENT" \
  'it is empty' 'into .pipeline/4242/constraints.md' ''

# NON-ZERO CONTROL for the four message assertions above: the ABSENT case must still say the two
# things the present case must not. Without it, "does not claim the file is missing" is satisfied
# by a template that lost the absent-case wording entirely, and the operator blocked by a genuinely
# missing artifact is the one who pays.
new_case 4242 "$(mk_status "2-review" '"architectural"' "$NO_EVENTS")"
gate "$CASE_ROOT"
assert_contains "CONTROL: an ABSENT prerequisite still says it is not present" \
  "$GATE_ERR" "\`spec.json\` is not present"
assert_contains "CONTROL: and still sends the operator to the phase that produces it" \
  "$GATE_ERR" "Run the phase that produces"
assert_not_contains "CONTROL: and does not claim a file that is absent IS present" \
  "$GATE_ERR" "\`spec.json\` IS present"

# The route the in-flight predicate exists for, which the message never named. Concluding an
# abandoned run is the escape that works -- inFlight is false on a final_verdict, and isTerminal
# is true on completed_at and on 5-archived, each already asserted by AC12/AC15 -- so this route
# refuses nothing that was not already refused.
assert_contains "the refusal offers the abandoned-run route" "$GATE_ERR" "If this run is YOURS and is over"
assert_contains "  naming final_verdict" "$GATE_ERR" "final_verdict"
assert_contains "  and completed_at" "$GATE_ERR" "completed_at"
assert_contains "  and 5-archived" "$GATE_ERR" "5-archived"
# The ownership clause is the whole of what the TEXT can do about route 3 being the widest and
# cheapest disarm the guard has. It cannot withhold the capability -- that belongs to the
# in-flight predicate, and the spec discloses it in does_not_stop -- but an unqualified "if this
# run is over" reads to a blocked session as a licence over whatever run the guard happened to
# resolve, which on this hook is usually the newest status.json in the project rather than
# theirs. Pinned so a wording refresh cannot drop it back to the unqualified form.
assert_not_contains "  and does not offer it unqualified, over whatever run got resolved" \
  "$GATE_ERR" "If this run is over"

# The stated consequence, asserted rather than left as prose: on a fresh checkout the SAME run
# is granted through path (b), because an event attests DISPATCH and not APPROVAL. This is the
# weakness R3 names and declines to defend against; a test that pins it is what stops it being
# quietly "fixed" into a rejecting-verdict blocklist over free text. A REJECTING verdict is used
# here on purpose: cell 3 above already covers the ordinary case.
new_case 4242 "$(mk_status "2-review" '"architectural"' \
  '[{"phase":"1-ba","verdict":"REWORK_REQUIRED","at":"2026-01-01T00:00:00Z"}]')"
# #61 R9(d): re-sited by giving the fixture the row's SECOND prerequisite, so the variable this
# cell is about -- a REJECTING verdict on the 1-ba event -- stays the only one.
assert_eq "  fixture shape: and it carries the 2-review row's second prerequisite" \
  "$(write_extra_prereqs "2-review" "$CASE_DIR")" "map.json"
gate "$CASE_ROOT"
assert_eq "with no spec.json at all, a 1-ba event grants entry to 2-review (path (b) is weaker)" \
  "$GATE_DEC" "granted"

# ---------------------------------------------------------------------------
suite "AC11: an unusable risk_tier resolves to the STRICTEST row, never the loosest"
# ---------------------------------------------------------------------------
# The discriminating fixture: spec.json present (the trivial row's prerequisite), design.json
# absent (the architectural row's). A trivial default grants; the strictest default refuses.
ac11() {  # ac11 <label> <risk_tier-json-or-omit>
  local body
  if [[ "$2" == "omit" ]]; then
    body="$(printf '{"issue_number":4242,"current_phase":"3-impl","updated_at":"%s","events":[]}' "$FRESH_ISO")"
  else
    body="$(mk_status "3-impl" "$2" "$NO_EVENTS")"
  fi
  new_case 4242 "$body"
  printf '{}' > "$CASE_DIR/spec.json"
  gate "$CASE_ROOT"
  assert_eq "AC11: risk_tier $1 is evaluated at the architectural row" "$GATE_DEC" "refused"
  assert_contains "  and it names design.json, not spec.json" "$GATE_OUT" "design.json"
}
ac11 "absent"           omit
ac11 "null"             null
ac11 "an unknown string" '"deep"'

# ---------------------------------------------------------------------------
suite "AC12: terminal states decline to judge (asserted on the DECISION, never the exit code)"
# ---------------------------------------------------------------------------
for p in "5-archived" "halted-error" "3-impl-error"; do
  new_case 4242 "$(mk_status "$p" '"architectural"' "$NO_EVENTS")"
  gate "$CASE_ROOT"
  assert_eq "$p -> not-applicable" "$GATE_DEC" "not-applicable"
  assert_eq "  and stop.sh's side of it exits 0" "$GATE_RC" "0"
done
# A DIFFERENT predicate: a non-terminal phase that would otherwise refuse, carrying completed_at.
new_case 4242 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS" ',"completed_at":"2026-01-02T00:00:00Z"')"
gate "$CASE_ROOT"
assert_eq "a non-terminal phase carrying completed_at -> not-applicable" "$GATE_DEC" "not-applicable"

# ---------------------------------------------------------------------------
suite "AC13: each of the 9 UNGUARDED literals lets a halted run end its turn"
# ---------------------------------------------------------------------------
UNGUARDED_LITERALS=(
  "1-ba-open-questions" "1-ba-rework-required" "2.5-design-owner-decision"
  "3-impl-frontend-gate-failed" "3-impl-gate-failed" "3-impl-live-verify-unverified"
  "3-impl-tripwire" "3-impl-tripwire-indeterminate" "4-veto-rework-required"
)
assert_eq "the UNGUARDED set under test has 9 literals" "${#UNGUARDED_LITERALS[@]}" "9"
for p in "${UNGUARDED_LITERALS[@]}"; do
  new_case 4242 "$(mk_status "$p" '"architectural"' "$NO_EVENTS")"
  gate "$CASE_ROOT"
  assert_eq "$p -> not-applicable" "$GATE_DEC" "not-applicable"
done

# ---------------------------------------------------------------------------
suite "AC14: fail-OPEN on vocabulary, fail-CLOSED on sequence"
# ---------------------------------------------------------------------------
# Not a hypothetical: until #42, status.schema.json:13's own description named
# 3-scope-drift-adjudication as an example phase, and pipeline.md never wrote it. Under
# deny-by-default a record holding it would refuse every stop in the project. The schema no
# longer names it, but the INPUT below stays exactly as it is -- pipeline.md still writes it
# nowhere, so it remains a phase this guard can genuinely meet and must not refuse.
for p in "3-scope-drift-adjudication" "3-something-nobody-writes"; do
  new_case 4242 "$(mk_status "$p" '"architectural"' "$NO_EVENTS")"
  gate "$CASE_ROOT"
  assert_eq "unrecognised phase $p -> not-applicable, NOT refused" "$GATE_DEC" "not-applicable"
done

# ---------------------------------------------------------------------------
suite "AC15: the in-flight predicate (the Stop hook is project-scoped, not run-scoped)"
# ---------------------------------------------------------------------------
# Without this, the guard binds to whatever status.json has the newest mtime and evaluates it
# at EVERY turn end in the whole project, so an abandoned run at a guarded phase blocks every
# turn permanently, escapable only by hand-editing a committed record.

MK_UPDATED="$STALE_ISO"
new_case 4242 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"
MK_UPDATED=""
gate "$CASE_ROOT"
assert_eq "(a) 25h old, no final verdict -> not-applicable even at a guarded phase" "$GATE_DEC" "not-applicable"

new_case 4242 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"   # FRESH_ISO, computed above
gate "$CASE_ROOT"
assert_eq "(b) 1h old (COMPUTED at test time) at the same phase -> refused" "$GATE_DEC" "refused"

# (c) the capture AS CAPTURED. This assertion is the tripwire on the capture itself: if anyone
# refreshes exp-script-test-coverage's updated_at, this fails loudly instead of the staleness
# check silently retiring.
assert_eq "the capture is still permanently stale (>24h), which is what (c) tests" \
  "$(ac63_capture_staleness "$REC_STC" "$IN_FLIGHT_MS")" \
  "stale"
new_case exp-script-test-coverage '{}'
capture "$REC_STC" "$CASE_DIR/status.json" '{}'
gate "$CASE_ROOT"
assert_eq "(c) the capture as captured -> not-applicable" "$GATE_DEC" "not-applicable"

# (c') isolates the ceiling. As captured the record is not-applicable for TWO reasons at once
# (stale AND final_verdict), so (c) alone cannot tell which mechanism fired. Same capture,
# final_verdict deleted, updated_at untouched.
new_case exp-script-test-coverage '{}'
capture "$REC_STC" "$CASE_DIR/status.json" '{"final_verdict":null}'
gate "$CASE_ROOT"
assert_eq "(c') stale ALONE, with no final verdict, is still not-applicable" "$GATE_DEC" "not-applicable"

# (d) a final verdict, at a phase that would otherwise refuse, regardless of age.
new_case 4242 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS" ',"final_verdict":"APPROVE"')"
gate "$CASE_ROOT"
assert_eq "(d) a fresh record carrying a final verdict -> not-applicable" "$GATE_DEC" "not-applicable"

# ---------------------------------------------------------------------------
suite "AC16: the active-issue SIGNAL must not NARROW the guard's subject"
# ---------------------------------------------------------------------------
# Q3 rejected a config knob and an env var, and R6 reintroduced one by inheritance: pointing
# CLAUDE_PIPELINE_ACTIVE_ISSUE at a satisfied dir yields exit 0 for every turn with no trace
# in the archived record. Resolve BOTH dirs; refuse if EITHER refuses.

# two_dirs <refusing-mtime> <granting-mtime> -> CASE_ROOT with 5150 (refuses) and 6160 (grants)
two_dirs() {
  new_tmpdir || exit 90
  CASE_ROOT="$NEW_TMPDIR"
  mkdir -p "$CASE_ROOT/.pipeline/5150" "$CASE_ROOT/.pipeline/6160"
  printf '%s' "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")" > "$CASE_ROOT/.pipeline/5150/status.json"
  printf '%s' "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")" > "$CASE_ROOT/.pipeline/6160/status.json"
  printf '{}' > "$CASE_ROOT/.pipeline/6160/design.json"
  touch -t "$1" "$CASE_ROOT/.pipeline/5150/status.json"
  touch -t "$2" "$CASE_ROOT/.pipeline/6160/status.json"
}

# gate_signal <root> <env-arg ...> -> GATE_OUT, GATE_RC, GATE_DEC, GATE_ISSUE
# The env has to be set for the child, so this cannot reuse gate() as written.
gate_signal() {
  local root="$1"; shift
  GATE_OUT="$( cd "$root" && env "$@" node "$GUARD" --root "$root" 2>/dev/null )"
  GATE_RC=$?
  GATE_DEC="$(printf '%s' "$GATE_OUT" | sed -n 's/.*"decision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$GATE_DEC" ]] || GATE_DEC="<no-decision-on-stdout>"
  GATE_ISSUE="$(printf '%s' "$GATE_OUT" | sed -n 's/.*"issue_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$GATE_ISSUE" ]] || GATE_ISSUE="<no-issue-dir-on-stdout>"
}

# gate_nosignal <root> -> the same outputs, with BOTH signal names removed from the CHILD's
# environment.
#
# `env -u` rather than the `( unset ...; assert ... )` this used to be, and the difference is the
# whole reason the cells below count. harness.sh tracks TESTS_PASSED/TESTS_FAILED in shell
# variables and assert_* returns 0 on both branches, so an assertion evaluated inside a `( ... )`
# printed its FAIL line and incremented nothing that survived the subshell: seven assertions in
# this file -- including the two (b') CONTROLs, whose entire job is to be falsifiable -- could not
# fail the build. Scope the environment around the CHILD process, never around the assertion.
gate_nosignal() { gate_signal "$1" -u CLAUDE_PIPELINE_ACTIVE_ISSUE -u PIPELINE_ACTIVE_ISSUE; }

two_dirs 202601010101 202601010102        # granting dir is newest
gate_nosignal "$CASE_ROOT"
assert_eq "(a) signal unset: the mtime-derived (granting) dir is the one evaluated" "$GATE_DEC" "granted"
assert_contains "  and the decision names that dir" "$GATE_ISSUE" "6160"

two_dirs 202601010102 202601010101        # refusing dir is newest; signal points at the granting one
gate_signal "$CASE_ROOT" CLAUDE_PIPELINE_ACTIVE_ISSUE=6160
assert_eq "(b) setting the signal to a satisfied dir does NOT disarm the guard" "$GATE_DEC" "refused"
assert_contains "  and the refusal names WHICH dir refused" "$GATE_OUT" "5150"

# (b') THE OTHER DIRECTION, and the only cell in this suite that requires the signal to be READ
#      at all. In (a), (b) and (c) the refusing record is always the mtime-newest one, so a
#      guard that ignores the signal entirely -- resolving only by mtime -- passes every one of
#      them. Here the signal names the REFUSING dir while the mtime-newest dir GRANTS, so
#      ignoring the signal answers `granted` and this cell is the thing that says so.
#      BOTH env names are doors into the same resolver and only one of them was ever opened; a
#      fix applied to one and not the other passes a suite that tests only the first.
for signal_var in CLAUDE_PIPELINE_ACTIVE_ISSUE PIPELINE_ACTIVE_ISSUE; do
  two_dirs 202601010101 202601010102      # granting dir (6160) is newest; 5150 refuses
  # NON-ZERO CONTROL, on this exact fixture: with no signal the answer is `granted`, so the
  # refusal below is attributable to the signal and to nothing else about the tree.
  gate_nosignal "$CASE_ROOT"
  assert_eq "  CONTROL ($signal_var): with no signal this same tree GRANTS (mtime picks 6160)" "$GATE_DEC" "granted"
  gate_signal "$CASE_ROOT" "$signal_var=5150"
  assert_eq "(b') $signal_var naming the REFUSING dir is honoured, not discarded for mtime" "$GATE_DEC" "refused"
  assert_eq "  and the decision names the signal-named dir" "$GATE_ISSUE" "5150"
  assert_eq "  and it exits 2" "$GATE_RC" "2"
done

# (c) THE MTIME TIE. This cell used to assert the opposite -- that a tie still "names one of the
#     two dirs rather than nothing" -- because activeIssueDir resolved a tie by readdirSync
#     order, which is stable on one machine and therefore looked deterministic when measured
#     here. It is not stable ACROSS machines: hash order on ext4, roughly insertion order on
#     APFS, so the dir this guard judged on a tie was a property of the filesystem (#27).
#
#     A tie now resolves to NO subject, and this guard falls silent. That is a DISARM VECTOR and
#     it is recorded as one, here and in the module header, rather than left for a reader to
#     discover: a fresh `git clone` writes every tracked status.json inside one coarse-clock
#     tick on Linux, which is exactly the tie, so the guard can be silenced without anyone
#     choosing to silence it. It is accepted as the price of never judging a run this session
#     does not own, and it routes through the fail-open tooling condition R11 already declares
#     ("no resolvable active issue"), not through a new one.
two_dirs 202601010103 202601010103        # the measured tie: both records share one mtime
gate_nosignal "$CASE_ROOT"; FIRST_DEC="$GATE_DEC"; FIRST_DIR="$GATE_ISSUE"
gate_nosignal "$CASE_ROOT"
assert_eq "(c) an mtime tie is DETERMINISTIC across runs (decision)" "$GATE_DEC" "$FIRST_DEC"
assert_eq "  and deterministic in the dir it names" "$GATE_ISSUE" "$FIRST_DIR"
assert_eq "  and a tie resolves to NO subject: silent, not an arbitrary pick" \
  "$FIRST_DEC" "<no-decision-on-stdout>"
assert_eq "  and the silence is fail-OPEN (exit 0), never a refusal" "$GATE_RC" "0"
# CONTROL, on this same tree: break the tie by one minute and a decision comes back. Without it
# the three assertions above would pass just as well against a guard that had stopped working
# altogether, which is the failure mode this suite exists to catch.
two_dirs 202601010103 202601010104        # 6160 (granting) now strictly newest
gate_nosignal "$CASE_ROOT"
assert_eq "  CONTROL: breaking the tie by one minute restores a decision" "$GATE_DEC" "granted"
assert_contains "  and that decision names the strictly-newest dir" "$GATE_ISSUE" "6160"

# ---------------------------------------------------------------------------
suite "AC17: exp-<slug> runs are GUARDED, not exempt"
# ---------------------------------------------------------------------------
# The recorded failure this mirrors: an experiment run had NO artifact validation at all
# because the dir pattern did not match, so both halves of a gate went inert on exactly the
# runs nobody watches.
new_case exp-guardtest "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"
gate "$CASE_ROOT"
assert_eq "an in-flight exp- run at a guarded phase with no prerequisite is REFUSED" "$GATE_DEC" "refused"
assert_contains "and the refusal names the exp- dir" "$GATE_OUT" "exp-guardtest"

# ---------------------------------------------------------------------------
suite "AC20: prerequisites are evaluated for the phase NAMED by current_phase"
# ---------------------------------------------------------------------------
# pipeline.md:71 wins over :22. Under the successor reading, a run interrupted mid-Phase-3
# resumes at Phase 4 having never finished Phase 3 -- the exact failure this issue exists to
# stop. Here: at 1-ba with map.json present, entry semantics grants; successor semantics would
# look for Phase 2's prerequisite and refuse.
new_case 4242 "$(mk_status "1-ba" '"architectural"' "$NO_EVENTS")"
printf '{}' > "$CASE_DIR/map.json"
gate "$CASE_ROOT"
assert_eq "1-ba with map.json present is granted (entry semantics, not successor)" "$GATE_DEC" "granted"

# ---------------------------------------------------------------------------
suite "AC29: a /phase re-run that did real work can clear the guard"
# ---------------------------------------------------------------------------
# phaseKey('phase-rerun') is null today, so the bare label can never clear the guard. A
# token-prefixed label resolves through the shared resolver with no new vocabulary.
new_case 4242 "$(mk_status "2-review" '"architectural"' \
  '[{"phase":"1-ba-rerun","verdict":"complete","at":"2026-01-01T00:00:00Z"}]')"
# #61 R9(d): re-sited by giving the fixture the row's second prerequisite. The variable this cell
# is about is the LABEL SHAPE (`1-ba-rerun` vs the bare `phase-rerun` twin below), not the map.
assert_eq "  fixture shape: and it carries the 2-review row's second prerequisite" \
  "$(write_extra_prereqs "2-review" "$CASE_DIR")" "map.json"
gate "$CASE_ROOT"
assert_eq "a 1-ba-rerun event resolves to token 1 and satisfies the 2-review row" "$GATE_DEC" "granted"

new_case 4242 "$(mk_status "2-review" '"architectural"' \
  '[{"phase":"phase-rerun","verdict":"complete","at":"2026-01-01T00:00:00Z"}]')"
gate "$CASE_ROOT"
assert_eq "the bare 'phase-rerun' label still resolves to nothing and satisfies nothing" "$GATE_DEC" "refused"

# ---------------------------------------------------------------------------
suite "AC30: the checkpoint-first window, where the guard is CORRECT and the convention is the fix"
# ---------------------------------------------------------------------------
# 'Checkpoint first, then append the exit event' is compliant with pipeline.md as written and
# leaves a window in which the record says 'entering 3-impl' with neither design.json (absent
# in a fresh checkout) nor a closing 2.5 event. The guard's answer in that window is right:
# the record genuinely does not show the phase closed. R14's one-write convention is the fix.
new_case 4242 "$(mk_status "3-impl" '"architectural"' \
  '[{"phase":"2-review","verdict":"complete","at":"2026-01-01T00:00:00Z"}]')"
gate "$CASE_ROOT"
assert_eq "checkpointed into 3-impl with no design.json and no 2.5 event -> refused" "$GATE_DEC" "refused"
assert_contains "and the reason names design.json" "$GATE_OUT" "design.json"

# ---------------------------------------------------------------------------
suite "AC25: no resolvable active issue dir is SILENT, not a refusal"
# ---------------------------------------------------------------------------
new_tmpdir || exit 90
gate "$NEW_TMPDIR"
assert_eq "no .pipeline/ at all -> exit 0" "$GATE_RC" "0"
assert_eq "  and no stdout" "$GATE_OUT" ""
assert_eq "  and no stderr" "$GATE_ERR" ""

new_tmpdir || exit 90
mkdir -p "$NEW_TMPDIR/.pipeline/schemas" "$NEW_TMPDIR/.pipeline/_archived"
printf '%s' "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")" > "$NEW_TMPDIR/.pipeline/schemas/status.json"
gate "$NEW_TMPDIR"
assert_eq "only non-issue-shaped siblings -> exit 0" "$GATE_RC" "0"
assert_eq "  and no stdout" "$GATE_OUT" ""
assert_eq "  and no stderr" "$GATE_ERR" ""

# ---------------------------------------------------------------------------
suite "AC19: a SECOND ground truth, derived from the committed RECORDS rather than from prose"
# ---------------------------------------------------------------------------
# Prose alone is provably insufficient, and it was measured rather than argued: until #42,
# status.schema.json:13 named two phases pipeline.md never wrote and omitted six it did. A
# vocabulary in this repo HAD rotted, in the one file no prose-derived test read. The list is
# corrected and now has its own set-equality test, so that is history -- but a second ground
# truth derived from the committed RECORDS is still the point of this suite.
CORPUS="$(git -C "$REPO_ROOT" ls-files '.pipeline/*/status.json' 2>/dev/null)"
CORPUS_N="$(printf '%s\n' "$CORPUS" | grep -c . | tr -d ' ')"
# RETAINED DELIBERATELY (#43 AC12(b)/(c)). Do NOT finish this floor off after reading the
# general argument against floors at AC24's exact accounting below: this floor is that
# accounting's OWN anti-vacuity companion. `EVALUATED + UNREADABLE == CORPUS_N` is trivially
# true at 0 == 0 + 0, and AC24's "no committed record is refused" zero is trivially true over
# an empty population too, so a broken glob, a wrong cwd or a rename of `.pipeline/` satisfies
# both without this. Nothing in the repo STATES what the corpus should contain and inferring it
# from history is forbidden, so a floor is the only shape available here.
# The CONSTANT is 1, not 4: the corpus BOTH GROWS AND IS ARCHIVED (pipeline.md's Phase 5
# sanctions moving a record to `.pipeline/_archived/<n>/`, two levels deep and outside this
# glob), so 4 is a measurement of a population a documented operation shrinks. 0 is the only
# value that makes the equality trivially true, so >= 1 keeps the whole property with no
# false-failure mode -- and a false failure in THIS suite is the disarm pressure #43 exists to
# reduce.
assert_eq "VACUITY CONTROL: the corpus walk found at least 1 committed record" \
  "$([[ "${CORPUS_N:-0}" -ge 1 ]] && echo enough || echo "ONLY $CORPUS_N")" "enough"

AC19_REPORT="$(cd "$REPO_ROOT" && node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const mod = await import(process.argv[1]);
  const known = new Set([...mod.ENTRY, ...mod.EXIT, ...mod.UNGUARDED, ...mod.TERMINAL]);
  const files = process.argv.slice(2);
  let read = 0; const unreadable = []; const strays = [];
  for (const f of files) {
    let s;
    try { s = JSON.parse(readFileSync(f, "utf8")); }
    catch (e) { unreadable.push(f + " (" + e.message.slice(0, 40) + ")"); continue; }
    read++;
    const p = s.current_phase;
    if (typeof p !== "string") { unreadable.push(f + " (no current_phase)"); continue; }
    if (!known.has(p)) strays.push(f + " -> " + p);
  }
  // ACCOUNTED FOR, not skipped: a walk that continues past what it could not read reports a
  // zero it did not earn.
  process.stdout.write(JSON.stringify({ total: files.length, read, unreadable, strays }));
' "$GUARD" $CORPUS 2>/dev/null)"
# The <no-report> sentinel belongs on the REPORT, never on the extracted value, which is the
# shape the sibling drift suite's field() already uses. Applying `${VALUE:-<no-report>}` to the
# value makes both assertions below unsatisfiable in the direction they assert: an EMPTY strays
# list -- the passing state -- is exactly what `:-` replaces with the sentinel.
# BOTH of field()'s branches, not just the first. An empty REPORT is one way to measure
# nothing; a report that is present but does not carry the key is the other, and sed prints
# nothing for it, which is byte-identical to "the list was empty" -- the passing state. An
# absence assertion that cannot tell `nothing wrong` from `nothing measured` is not an
# assertion, and that is the whole reason the sentinel exists.
ac19_field() {  # ac19_field <json-key>
  [[ -n "$AC19_REPORT" ]] || { printf '<no-report>'; return; }
  case "$AC19_REPORT" in *"\"$1\":"*) ;; *) printf '<no-field:%s>' "$1"; return ;; esac
  printf '%s' "$AC19_REPORT" | sed -n "s/.*\"$1\":\\[\\([^]]*\\)\\].*/\\1/p"
}
# Witnessed, on this exact function: a non-empty report that lost the key must NOT read as an
# empty list. Without this the hardening above is a claim rather than a control.
assert_eq "  CONTROL: a report missing the key reads as <no-field:strays>, never as empty" \
  "$(AC19_REPORT='{"total":9,"read":9}' ac19_field strays)" "<no-field:strays>"
assert_eq "  CONTROL: and an absent report still reads as <no-report>" \
  "$(AC19_REPORT='' ac19_field strays)" "<no-report>"
ac19_scalar() {  # ac19_scalar <json-key> -> the number, or a sentinel
  [[ -n "$AC19_REPORT" ]] || { printf '<no-report>'; return; }
  case "$AC19_REPORT" in *"\"$1\":"*) ;; *) printf '<no-field:%s>' "$1"; return ;; esac
  printf '%s' "$AC19_REPORT" | sed -n "s/.*\"$1\":\\([0-9]*\\).*/\\1/p"
}
AC19_STRAYS="$(ac19_field strays)"
AC19_UNREAD="$(ac19_field unreadable)"
assert_eq "every committed record's current_phase is a member of one of the four sets" \
  "$AC19_STRAYS" ""
assert_eq "and the walk ACCOUNTS for every record rather than continuing past it" \
  "$AC19_UNREAD" ""
# The `unreadable` zero above is EARNED here rather than assumed. Both `total` and `read` were
# already computed and already carried in the report, and neither was asserted -- so an empty
# `unreadable` list was equally consistent with a walk that read every record and with one that
# read none. A POSITIVE assertion over the same population, against the count the shell derived
# independently, turns that zero into a derived result. No temp tree, no planted record.
assert_eq "the walk READ every record the corpus listed (which is what makes the zero above a result)" \
  "$(ac19_scalar read)" "$CORPUS_N"
assert_eq "and it was handed the whole corpus in the first place" \
  "$(ac19_scalar total)" "$CORPUS_N"

# ---------------------------------------------------------------------------
suite "AC24: no committed record is REFUSED (a zero, whose non-zero control is AC1's 14)"
# ---------------------------------------------------------------------------
# Each record is evaluated in its OWN temp project with its dir name preserved and updated_at
# rewritten to test time, so R6's staleness cannot mask the table. Artifacts are NOT copied:
# only status.json is tracked, so this is the fresh-checkout case the two-source rule exists for.
AC24_REFUSED=""
AC24_EVALUATED=0
AC24_UNREADABLE=0
while IFS= read -r rec; do
  [[ -n "$rec" ]] || continue
  name="$(basename "$(dirname "$rec")")"
  new_case "$name" '{}'
  if ! capture "$REPO_ROOT/$rec" "$CASE_DIR/status.json" "{\"updated_at\":\"$FRESH_ISO\"}" 2>/dev/null; then
    AC24_REFUSED="$AC24_REFUSED $name(UNREADABLE)"      # accounted for, never skipped
    AC24_UNREADABLE=$((AC24_UNREADABLE + 1))
    continue
  fi
  AC24_EVALUATED=$((AC24_EVALUATED + 1))
  gate "$CASE_ROOT"
  # A zero must be earned. `refused` is the failure this criterion names, but ANYTHING that is
  # not one of the two acceptable decisions is also recorded: without this, a guard that emits
  # no decision at all (because it does not exist yet, or threw) would satisfy "no record was
  # refused" while having evaluated nothing. That is the vacuous form of this exact assertion.
  case "$GATE_DEC" in
    granted|not-applicable) ;;
    refused)                AC24_REFUSED="$AC24_REFUSED $name(refused)" ;;
    *)                      AC24_REFUSED="$AC24_REFUSED $name(NO-DECISION:$GATE_DEC)" ;;
  esac
done <<< "$CORPUS"
# REPLACES the `AC24_EVALUATED >= 4` floor that stood here (#43 AC12(a)). An EXACT accounting,
# not a floor: the loop's only non-evaluating exit records the record BY NAME and increments
# AC24_UNREADABLE, so nothing can leave the walk silently, and a `continue` inserted anywhere
# else reddens this by exactly the number of records it skipped. A floor could not see that
# over a 6-record corpus. Its anti-vacuity companion is the retained `CORPUS_N >= 1` control in
# the AC19 walk above -- read the two as a pair, because this equality is trivially true at 0.
assert_eq "#43-C1 the walk ACCOUNTS for every committed record: evaluated + unreadable == the corpus" \
  "$((AC24_EVALUATED + AC24_UNREADABLE))" "$CORPUS_N"
assert_eq "no committed record is refused by the table" "${AC24_REFUSED# }" ""

# ===========================================================================================
# #43 / #45 -- the two branches no fixture in this suite could reach through its own builders.
#
# WHY EVERY LABEL BELOW CARRIES A `#43-` PREFIX. This suite already owns `suite "AC11: ..."`
# and `suite "AC12: ..."`, which are DIFFERENT criteria wearing the numbers #43's spec gave
# its own. A mutation battery discharges itself by naming an assertion label a reader can grep
# for, so a colliding label makes that grep return two unrelated sites and the discharge stops
# discriminating. Continuing this suite's own numbering (AC31+) does not work either: two other
# open issues name this file in their bodies, so two branches both appending AC31 re-create the
# collision at merge time. An issue number is unique by construction and tells the next reader
# which issue introduced the cell. Measured before relying on it: `git grep -c -- '#43-'` over
# the whole tree at merge-base 2ec6dd7 returns ZERO files, while `AC31` already returns two.
#
# WHAT IS RED HERE AND WHAT IS NOT, stated because a reader who expects a Phase-3a contract to
# be uniformly red will otherwise mistrust the parts that are green:
#   - RED at the merge-base: the three undetermined-tier cells (#43-T4/T5/T6) and the
#     content-agreement checks (#43-K1/K2/K3). Those are the behaviour change.
#   - GREEN at the merge-base BY DESIGN: everything else. #43/#45 is a test-gap issue -- the
#     undatable branch and the resolved-tier column already BEHAVE correctly, they were merely
#     unexercised, which is why MUT-A and MUT-C survived all 345 assertions. A gap-closing pin
#     cannot be red before the gap is closed. Its bite is proved by mutation, never by colour.
# ===========================================================================================

# ONE variable, used in THREE places: the fixture body, the fixture-shape probe, and the
# negative assertion. That is what stops "the output does not contain GARBAGE" going vacuous
# the day somebody rewords the fixture. It is deliberately not a real word, and specifically
# not `deep` -- which this suite's own ac11 helper already passes as its unknown-string
# spelling, so a negative assertion on it would be a false failure waiting for a reword.
GARBAGE_TIER="ZZQ-NOT-A-TIER-43"

# The id ledger. Every `#43-` id is registered as its cell RUNS, and the two checks at the
# bottom compare what ran against every id that appears in this file's own source.
AC43_IDS=""
reg43() { AC43_IDS="$AC43_IDS$1
"; }

# probe43 <status.json> <fresh|undatable> <absent|null|exact:VALUE> -> "ok" or the diagnosis.
#
# ONE line per cell, at the only moment it is free. `decideForDir` reaches `not-applicable` by
# FOUR routes before the tier check is evaluated -- a truthy `completed_at` (never parsed, so
# "TBD" counts), an UNGUARDED phase, an unrecognised phase, and !inFlight (a truthy
# `final_verdict`, including a value outside the schema's closed enum, OR undatable OR stale)
# -- and the last emits ONE reason string for three different causes. So a decision assertion
# alone cannot say WHICH route fired, and a fixture that quietly took another one would pass
# while testing nothing. The probe asserts the fixture qualifies for exactly the route its own
# cell names.
#
# It also parses the record, which covers the FIFTH pre-tier exit: `decideForDir` returns null
# on an unreadable or non-object record and the caller renders that as SILENCE -- rc 0, empty
# stdout, indistinguishable from `not-applicable` to an rc-only assertion. That binds hardest
# on the hand-written-body cells below, where a typo'd fixture IS unparseable JSON.
probe43() {
  node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const mod = await import(process.argv[1]);
    const guarded = new Set([...mod.ENTRY, ...mod.EXIT]);
    // #63: the ceiling this probe judges against is the guard'"'"'s OWN exported value, not a second
    // copy of the number spelled here -- and it is VALIDATED before it is compared against. A
    // substituted read can arrive as `undefined` where a literal could not, and `age > undefined`
    // and `age > NaN` are both FALSE, so an unvalidated read answers `ok` about a fixture it never
    // judged, silently, for the ~345 assertions this probe qualifies.
    const CEIL = Number(mod.IN_FLIGHT_MS);
    let s;
    try { s = JSON.parse(readFileSync(process.argv[2], "utf8")); }
    catch (e) { process.stdout.write("UNPARSEABLE FIXTURE: " + e.message.slice(0, 60)); process.exit(0); }
    if (!s || typeof s !== "object" || Array.isArray(s)) { process.stdout.write("NON-OBJECT FIXTURE"); process.exit(0); }
    const bad = [];
    if (!Number.isFinite(CEIL) || CEIL <= 0) bad.push("the exported IN_FLIGHT_MS did not read as a finite positive number");
    if (s.completed_at) bad.push("completed_at is truthy: this fixture exits by the isTerminal route");
    if (s.final_verdict) bad.push("final_verdict is truthy: this fixture exits by the concluded route");
    if (typeof s.current_phase !== "string" || !guarded.has(s.current_phase)) {
      bad.push("current_phase " + JSON.stringify(s.current_phase) + " is not a GUARDED row");
    }
    const parsed = Date.parse(s.updated_at);
    if (process.argv[3] === "fresh") {
      if (!Number.isFinite(parsed)) bad.push("updated_at is NOT datable, but this cell is the datable control");
      else if (Number.isFinite(CEIL) && CEIL > 0 && Date.now() - parsed > CEIL) bad.push("updated_at is past the in-flight ceiling this suite reads from the guard: this cell would test staleness");
    } else if (process.argv[3] === "undatable") {
      if (Number.isFinite(parsed)) bad.push("updated_at IS datable, so this cell tests staleness, not undatability");
    } else bad.push("the cell asked for an unknown datability: " + process.argv[3]);
    const want = process.argv[4];
    const has = Object.prototype.hasOwnProperty.call(s, "risk_tier");
    if (want === "absent") { if (has) bad.push("the risk_tier KEY is present, but this cell tests the absent spelling"); }
    else if (want === "null") { if (!has || s.risk_tier !== null) bad.push("risk_tier is " + JSON.stringify(s.risk_tier) + ", not JSON null"); }
    else if (want.startsWith("exact:")) {
      const v = want.slice(6);
      if (s.risk_tier !== v) bad.push("risk_tier is " + JSON.stringify(s.risk_tier) + ", not the exact literal " + JSON.stringify(v));
    } else bad.push("the cell asked for an unknown tier shape: " + want);
    process.stdout.write(bad.length ? bad.join("; ") : "ok");
  ' "$GUARD" "$1" "$2" "$3" 2>&1
}

# ---------------------------------------------------------------------------
suite "#43 the 1-ba row x tier: a tiers-restricted row and an UNDETERMINED tier (#45)"
# ---------------------------------------------------------------------------
# The live defect, reproduced at merge-base 2ec6dd7 before this family was written:
#   trivial -> not-applicable rc 0   standard -> not-applicable rc 0   architectural -> refused rc 2
#   ABSENT  -> refused rc 2          null     -> refused rc 2          garbage -> refused rc 2
# The tier is BA's OUTPUT and `1-ba` is checkpointed BEFORE BA runs, so at that phase the tier
# is NECESSARILY absent -- and the bottom row is therefore what every non-architectural run
# actually meets at its first turn boundary. `normalizeTier` resolves the absence to the
# strictest row, which switches on a map.json requirement that standard-tier runs fold into
# Phase 1 and trivial-tier runs may skip entirely.
#
# THE ARCHITECTURAL CELL IS A CONTROL, not decoration. Two different failures make every other
# cell in this family pass: a row whose `tiers` column was deleted, and a call site left at the
# old argument count (the tiers column then reads as disabled at EVERY tier). Both turn the
# architectural cell from refused into not-applicable, and nothing else in these 345 assertions
# notices either.
#
# id | label | risk_tier as written into the fixture (OMIT = no key at all) | probe shape | decision | rc | kind
AC43_T_ROWS=(
  '#43-T1|trivial|"trivial"|exact:trivial|not-applicable|0|off'
  '#43-T2|standard|"standard"|exact:standard|not-applicable|0|off'
  '#43-T3|architectural|"architectural"|exact:architectural|refused|2|applies'
  '#43-T4|absent|OMIT|absent|not-applicable|0|undetermined'
  '#43-T5|null|null|null|not-applicable|0|undetermined'
  "#43-T6|an unknown string|\"$GARBAGE_TIER\"|exact:$GARBAGE_TIER|not-applicable|0|undetermined"
)
AC43_T_COVERED=""      # what the table ACTUALLY drove, accumulated as each cell runs
AC43_UNDETERMINED=""   # the undetermined tail of it, which the byTier family below re-uses
for row in "${AC43_T_ROWS[@]}"; do
  IFS='|' read -r id label tierjson probetier expdec exprc kind <<< "$row"
  case "$probetier" in
    "exact:$GARBAGE_TIER") covers="unknown-string" ;;
    exact:*)               covers="${probetier#exact:}" ;;
    *)                     covers="$probetier" ;;
  esac
  AC43_T_COVERED="$AC43_T_COVERED $covers"
  [[ "$kind" == "undetermined" ]] && AC43_UNDETERMINED="$AC43_UNDETERMINED $covers"
  if [[ "$tierjson" == "OMIT" ]]; then
    # ROUTE: hand-written body. mk_status() always interpolates a risk_tier key, so the ABSENT
    # spelling is unconstructible through the builder; this is the same route the ac11 helper
    # above already uses for exactly this problem. The probe is load-bearing here precisely
    # because a hand-written body carries no builder guarantee about the other four fields.
    body="$(printf '{"issue_number":4242,"current_phase":"1-ba","updated_at":"%s","events":[]}' "$FRESH_ISO")"
  else
    body="$(mk_status "1-ba" "$tierjson" "$NO_EVENTS")"   # ROUTE: the builder, unmodified
  fi
  new_case 4243 "$body"
  reg43 "$id"
  assert_eq "$id probe: the fixture qualifies for the tier route ONLY ($label)" \
    "$(probe43 "$CASE_DIR/status.json" fresh "$probetier")" "ok"
  gate "$CASE_ROOT"
  assert_eq "$id: 1-ba with no map.json at risk_tier $label -> $expdec" "$GATE_DEC" "$expdec"
  assert_eq "$id: and it exits $exprc" "$GATE_RC" "$exprc"
  # THE POSITIVE HALF OF EVERY NEGATIVE BELOW. A decision line that is EMPTY -- the guard threw
  # and the fail-open branch swallowed it -- satisfies any assert_not_contains vacuously. These
  # two say the output exists AND came from this fixture, so a silent build cannot look like a
  # prohibition being honoured.
  assert_contains "$id: and the decision names THIS fixture's issue dir" "$GATE_OUT" "4243"
  assert_contains "$id: and names the phase under test" "$GATE_OUT" "1-ba"
  case "$kind" in
    applies)
      assert_contains "$id: and the surviving refusal still names map.json" "$GATE_OUT" "map.json"
      ;;
    undetermined)
      # R3's distinct wording, asserted so that reusing the resolved-tier string reddens here
      # and nowhere else. The wording itself stays Dev's: this matches the NEGATED POLARITY the
      # criterion uses ("undetermined" / "no determined risk_tier"), case-folded, not a fixed
      # sentence.
      #
      # THE POLARITY IS THE POINT, and the obvious spelling of this assertion does not carry it:
      # a bare `contains "determined"` passed 329/0 against a reason string stating the exact
      # INVERSE of what the guard did ("has a determined risk_tier, so the tier-restricted row
      # APPLIES and the turn is refused"), because `determined` is a substring of `undetermined`
      # and the three negatives below are all absent from that inverse too. Non-zero control for
      # that zero: a reason of bare `determined` reddens three cells here, so the harness can see
      # reason-string changes at exactly these assertions. Hence a set of NEGATED spellings, wide
      # enough to leave the wording Dev's and narrow enough that the inverse cannot satisfy it.
      # `undetermined` alone is NOT the needle: the shipped sentence says "no determined".
      folded43="$(printf '%s' "$GATE_OUT" | tr 'A-Z' 'a-z')"
      polarity43="NOT-NEGATED"
      case "$folded43" in
        *undetermined*|*"no determined"*|*"not determined"*|*"never determined"*) polarity43="negated" ;;
      esac
      assert_eq "$id: and the reason says the tier is NOT determined, in a negated polarity (an inverted reason must not satisfy this)" \
        "$polarity43" "negated"
      assert_not_contains "$id: and NOT the resolved-tier wording, which names a tier the record does not carry" \
        "$GATE_OUT" "is not a guarded phase at the"
      # The normalized value must never reach stdout on this branch: `architectural` is what
      # normalizeTier INVENTS for an unusable tier, and printing it tells an operator the
      # record says something it does not say.
      assert_not_contains "$id: and the invented strictest tier never reaches stdout" \
        "$GATE_OUT" "architectural"
      ;;
  esac
  if [[ "$probetier" == "exact:$GARBAGE_TIER" ]]; then
    # THE PROHIBITION, made falsifiable. This is the first branch in the guard where the field
    # is known NOT to be a known tier and has not been normalized away, which is exactly where
    # an implementer reaches for "${status.risk_tier}". The value is agent-written free text in
    # a file that is committed and archived verbatim, and nothing enforces the schema's enum at
    # runtime. The needle and the fixture body are the SAME shell variable.
    assert_not_contains "$id: and the record's own risk_tier text is NOT interpolated into the reason" \
      "$GATE_OUT" "$GARBAGE_TIER"
  fi
done
# WHAT THIS IS NOT, because the obvious form of it is vacuous and I measured that it is: an
# `executed == ${#TABLE[@]}` counter cannot see a DELETED row, since both sides shrink together.
# Mutated -- one row deleted, loop untouched -- such a counter stayed green at failed=0 and the
# family silently covered five tiers instead of six. The coverage has to be compared against
# something the table cannot shrink, so the resolved half is derived from the guard's OWN tier
# vocabulary (dispatch-model.mjs's KNOWN_TIERS, which gate-phase-entry.mjs imports) and the
# undetermined half is the three spellings a writer can put in the field: ABSENT, which the
# schema allows (risk_tier is not in `required`), plus null and an unknown string, which it does
# not and which nothing validates this record against anyway. A fourth tier added to KNOWN_TIERS
# reddens this until the table covers it.
reg43 "#43-T0"
assert_eq "#43-T0 the family drove every KNOWN_TIER plus every undetermined spelling, in order" \
  "${AC43_T_COVERED# }" \
  "$(MOD43="$SCRIPTS_DIR/dispatch-model.mjs" node --input-type=module \
      -e 'const m = await import(process.env.MOD43); process.stdout.write(m.KNOWN_TIERS.join(" "))' 2>&1) absent null unknown-string"
# The module path travels in the ENVIRONMENT, not in argv: dispatch-model.mjs is a CLI as well
# as a module, and `node -e '...' <path>` makes that path argv[1], which is what its own
# isMain() seam reads -- so the import runs its main() and the "tier vocabulary" this assertion
# derives comes back as a dispatch-site error message. Measured, once, in this assertion.

# ---------------------------------------------------------------------------
suite "#43 the byTier rows are UNCHANGED at an undetermined tier"
# ---------------------------------------------------------------------------
# The other branch of the same conjunction. Three cells prove the new distinction FIRES on
# every undetermined spelling; these three prove it does not LEAK into the byTier path, where
# the strictest-row default is correct and stays correct -- `3-impl` is only reached after
# Phase 1 copied the tier, so an undetermined tier there means a corrupted or hand-edited
# record, not the mandated ordering.
#
# The discriminating fixture is spec.json PRESENT and design.json ABSENT: the one presence
# combination where the trivial row and the architectural row disagree. Any other combination
# passes under both, which is what makes this family a discrimination rather than a restatement.
#
# NOTE FOR THE BATTERY: MUT-D (normalizeTier's default -> trivial) reddens the suite's own
# `AC11:` trio AND these three cells, so its expected count is no longer the 6 measured at the
# merge-base. Derive it; do not restate it.
#
# id | label | risk_tier as written (OMIT = no key) | probe shape
AC43_B_ROWS=(
  '#43-B1|absent|OMIT|absent'
  '#43-B2|null|null|null'
  "#43-B3|an unknown string|\"$GARBAGE_TIER\"|exact:$GARBAGE_TIER"
)
AC43_B_COVERED=""
for row in "${AC43_B_ROWS[@]}"; do
  IFS='|' read -r id label tierjson probetier <<< "$row"
  case "$probetier" in
    "exact:$GARBAGE_TIER") AC43_B_COVERED="$AC43_B_COVERED unknown-string" ;;
    *)                     AC43_B_COVERED="$AC43_B_COVERED $probetier" ;;
  esac
  if [[ "$tierjson" == "OMIT" ]]; then
    body="$(printf '{"issue_number":4242,"current_phase":"3-impl","updated_at":"%s","events":[]}' "$FRESH_ISO")"
  else
    body="$(mk_status "3-impl" "$tierjson" "$NO_EVENTS")"
  fi
  new_case 4243 "$body"
  printf '{}' > "$CASE_DIR/spec.json"          # the trivial row's prerequisite, present
  reg43 "$id"
  assert_eq "$id probe: the fixture qualifies for the tier route ONLY ($label)" \
    "$(probe43 "$CASE_DIR/status.json" fresh "$probetier")" "ok"
  gate "$CASE_ROOT"
  assert_eq "$id: 3-impl at risk_tier $label is still evaluated at the STRICTEST row -> refused" \
    "$GATE_DEC" "refused"
  assert_contains "$id: and it still names design.json, not spec.json" "$GATE_OUT" "design.json"
done
# Cross-derived against the family above rather than against its own length: the two families
# are the two branches of ONE conjunction, so they must cover the SAME undetermined spellings.
# A row deleted from either table reddens this; a counter over the table's own length cannot.
reg43 "#43-B0"
assert_eq "#43-B0 the byTier family drove exactly the undetermined spellings the tiers family did" \
  "${AC43_B_COVERED# }" "${AC43_UNDETERMINED# }"

# ---------------------------------------------------------------------------
suite "#43 the in-flight predicate's UNDATABLE branch, which mk_status() cannot construct"
# ---------------------------------------------------------------------------
# `mk_status()` always interpolates a well-formed `updated_at`, so the branch that stops an
# UNDATABLE record from holding a project's turns open forever has never been exercised:
# mutating `if (!Number.isFinite(updated)) return false;` to `return true;` passes all 345
# assertions at the merge-base. Every cell here is paired with a fresh-updated_at CONTROL at
# the SAME phase and the SAME issue dir (#43-D1), so each undatable cell discriminates instead
# of passing over an empty population -- and the probe separates it from the STALENESS branch,
# whose reason string is byte-identical.
#
# id | label | fixture route | probe datability | decision | rc | the shape it covers
AC43_D_ROWS=(
  '#43-D1|fresh (the non-zero CONTROL)|builder|fresh|refused|2|datable-control'
  '#43-D2|the key DELETED|capture-null|undatable|not-applicable|0|key-absent'
  '#43-D3|an unparseable string|mk-updated|undatable|not-applicable|0|unparseable-string'
  '#43-D4|JSON null|hand-written|undatable|not-applicable|0|json-null'
)
AC43_D_COVERED=""
for row in "${AC43_D_ROWS[@]}"; do
  IFS='|' read -r id label route probeage expdec exprc covers <<< "$row"
  AC43_D_COVERED="$AC43_D_COVERED $covers"
  case "$route" in
    builder)
      new_case 4243 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"
      ;;
    capture-null)
      # ROUTE: capture()'s documented null-deletes-the-key patch. mk_status() cannot emit a
      # record with no updated_at key, and mk_status() is not modified.
      new_case 4243 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"
      capture "$CASE_DIR/status.json" "$CASE_DIR/status.json" '{"updated_at":null}'
      ;;
    mk-updated)
      # ROUTE: the MK_UPDATED env seam the builder already reads.
      MK_UPDATED="not-a-date"
      new_case 4243 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"
      MK_UPDATED=""
      ;;
    hand-written)
      # ROUTE: a hand-written body. capture()'s patch cannot SET null -- null is its delete
      # sentinel -- and a writer can put the field present and null IN VIOLATION of
      # status.schema.json, which requires updated_at and types it as a date-time string but is
      # enforced against this record by nothing at runtime. Kept as a writer-shape witness, not
      # a schema-permitted one (re-derive with
      # `grep -n -A4 '"updated_at"' plugins/pipeline/schemas/status.schema.json`, and note the
      # nullable spelling this same file uses for issue_number a few lines above, which is what
      # updated_at would look like if the shape WERE permitted): no mutation of the
      # guard distinguishes JSON null from an absent key (`Date.parse(null)` is NaN exactly as
      # `Date.parse(undefined)` is), so every mutation that reddens this cell has already
      # reddened #43-D2. If a future reviewer finds one that reddens this and NOT #43-D2, that
      # is a real asymmetry in the guard and this note should be retired, not defended.
      new_case 4243 "$(printf '{"issue_number":4242,"current_phase":"3-impl","risk_tier":"architectural","updated_at":null,"events":[]}')"
      ;;
  esac
  reg43 "$id"
  assert_eq "$id probe: the fixture is $probeage, and takes no other pre-tier route ($label)" \
    "$(probe43 "$CASE_DIR/status.json" "$probeage" exact:architectural)" "ok"
  gate "$CASE_ROOT"
  assert_eq "$id: 3-impl with no design.json and updated_at $label -> $expdec" "$GATE_DEC" "$expdec"
  assert_eq "$id: and it exits $exprc" "$GATE_RC" "$exprc"
  assert_contains "$id: and the decision came from THIS fixture (names the issue dir)" "$GATE_OUT" "4243"
done
# A COVERAGE CONTRACT, not a count: these are the three undatable CLASSES a WRITER can produce in
# violation of status.schema.json -- which requires updated_at as a date-time string and so
# permits none of them, and which nothing validates this record against -- plus the datable
# control that makes them results. CLASSES and not shapes: `true`, `[]` and `{}` are further
# undatable SHAPES, and each collapses into the unparseable class already driven here, so the
# set is complete at this grain and would not be at the literal one. The authority is the writer,
# not the schema. No code-side
# vocabulary enumerates them (which is itself why this branch went unexercised), so the set is
# written out -- and because it is written out, deleting a row reddens this instead of shrinking
# the family in silence, which is what an `executed == table length` counter does.
reg43 "#43-D0"
assert_eq "#43-D0 the family drove the datable control and every undatable shape a record can carry" \
  "${AC43_D_COVERED# }" "datable-control key-absent unparseable-string json-null"

# ---------------------------------------------------------------------------
suite "#43 the tier distinction must not LEAK into the exported satisfyingTokens"
# ---------------------------------------------------------------------------
# satisfyingTokens is the guard's exported surface. It has ONE consumer outside this file
# (test-gate-phase-entry-drift.sh). Re-derive with `git grep -rn satisfyingTokens .`, which
# returns the export, that one consumer, and this file's own uses. An earlier version of this
# note added "four consumers of the guard MODULE" -- dropped, not re-guessed: it carried no
# membership rule and no command of its own, and reviewers reading it got 4, 5 or 6 depending on
# whether a file that only greps the module as TEXT, or one that DELETES it to exercise the
# disarm, counts as a consumer. An uncommanded count beside a commanded one is the defect this
# note exists to prevent.
# The new distinction belongs to the tiers-restricted ROW, not to the token sets, so every
# undetermined spelling must still resolve through the strictest-row default and return exactly
# what the architectural tier returns.
#
# THE COMPARISON CARRIES ITS OWN CONTROL (#43-S3), and it is not decoration: a walk of this
# shape reported "IDENTICAL" three times while comparing empty files, and the only thing that
# exposed it was a mutant that MUST have differed and did not. A "no difference" result is
# worth nothing until the comparison has been shown able to see one.
AC43_TOKENS="$(node --input-type=module -e '
  const mod = await import(process.argv[1]);
  const rows = [...mod.ENTRY, ...mod.EXIT];
  const tiers = [["trivial", "trivial"], ["standard", "standard"], ["architectural", "architectural"],
                 ["garbage", process.argv[2]], ["null", null], ["absent", undefined]];
  const col = {};
  for (const [name, t] of tiers) col[name] = rows.map((r) => JSON.stringify(mod.satisfyingTokens(r, t))).join("|");
  process.stdout.write(JSON.stringify({
    rows: rows.length,
    cells: rows.length * tiers.length,
    undetermined_matches_architectural:
      ["garbage", "null", "absent"].every((n) => col[n] === col.architectural) ? "yes" : "NO",
    trivial_differs_from_architectural: col.trivial !== col.architectural ? "yes" : "NO",
  }));
' "$GUARD" "$GARBAGE_TIER" 2>&1)"
ac43_field() {  # ac43_field <key> -> the value, or a sentinel that cannot be mistaken for one
  [[ -n "$AC43_TOKENS" ]] || { printf '<no-report>'; return; }
  case "$AC43_TOKENS" in *"\"$1\":"*) ;; *) printf '<no-field:%s>' "$1"; return ;; esac
  printf '%s' "$AC43_TOKENS" | sed -n "s/.*\"$1\":\"\\{0,1\\}\\([^\",}]*\\).*/\\1/p"
}
reg43 "#43-S1"
assert_eq "#43-S1 the walk covered every guarded row at every tier spelling (15 rows x 6 spellings)" \
  "$(ac43_field cells)" "$(( ${#GUARDED_ROWS[@]} * 6 ))"
reg43 "#43-S2"
assert_eq "#43-S2 every undetermined spelling returns the architectural token sets, byte for byte" \
  "$(ac43_field undetermined_matches_architectural)" "yes"
reg43 "#43-S3"
assert_eq "#43-S3 CONTROL: the same comparison CAN see a difference (trivial != architectural)" \
  "$(ac43_field trivial_differs_from_architectural)" "yes"

# ---------------------------------------------------------------------------
suite "#43 the guard and pipeline.md must AGREE, in writing, about the 1-ba ordering"
# ---------------------------------------------------------------------------
# A content check, and the round-1 form of this criterion was satisfiable by a ZERO-LINE DIFF:
# `1-ba` and `risk_tier` already co-occur in both files (5/5 and 2/13 occurrences at 2ec6dd7),
# so a conjunction of common tokens passed before anything was written. Hence ONE CONTIGUOUS
# DISTINCTIVE STRING, the SAME one in both files -- two independently chosen per-file strings
# cannot witness the word "agree" -- matched with whitespace normalized so a comment reflow is
# not a false failure.
#
# THIS STRING IS THE CONTRACT. Reword it here and in BOTH files, or not at all.
ANCHOR_43='the 1-ba checkpoint is written before BA runs, so the risk_tier at 1-ba is whatever an EARLIER write left there, never the output of the BA dispatch this checkpoint precedes'
PIPELINE_MD="$PLUGIN_ROOT/commands/pipeline.md"

# block43 <file> <marker> -> the ONE comment block containing <marker>, comment leaders
# stripped and whitespace squeezed; `<no-block>` when no block holds it. Co-location, not a
# fixed address: a whole-file grep passes with the sentence pasted anywhere, and the criterion
# is that the new prose sits in the SAME block as the existing strictest-default sentence. If
# Dev moves both to the file prologue together, this still holds.
block43() {
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const blocks = src.match(/\/\*[\s\S]*?\*\//g) || [];
    const lines = src.split("\n");
    let run = [];
    for (const ln of lines) {          // maximal runs of consecutive // comment lines count too
      if (/^\s*\/\//.test(ln)) run.push(ln);
      else { if (run.length) blocks.push(run.join("\n")); run = []; }
    }
    if (run.length) blocks.push(run.join("\n"));
    const hit = blocks.find((b) => b.includes(process.argv[2]));
    process.stdout.write(hit ? hit.replace(/^\s*(\*|\/\/)\s?/gm, "").replace(/\s+/g, " ").trim() : "<no-block>");
  ' "$1" "$2" 2>&1
}
norm43() { sed 's/^[[:space:]]*\*[[:space:]]\{0,1\}//' "$1" | tr '\n' ' ' | tr -s '[:space:]' ' '; }
# present/ABSENT rather than assert_contains, for the pipeline.md half ONLY: that haystack is
# the whole normalized file, and a failing assert_contains would print it as one 60KB line,
# burying the one thing the reader needs. The needle is in the assertion NAME instead.
contains43() { case "$1" in *"$2"*) printf 'present' ;; *) printf 'ABSENT' ;; esac; }

GUARD_BLOCK_43="$(block43 "$GUARD" "STRICTEST row")"
reg43 "#43-K4"
assert_contains "#43-K4 CONTROL: the block extractor found the block holding the strictest-default sentence" \
  "$GUARD_BLOCK_43" "An unusable risk_tier resolves to the STRICTEST row, never the loosest."
reg43 "#43-K5"
assert_not_contains "#43-K5 CONTROL: and it reports absence for a string that is not in that block" \
  "$GUARD_BLOCK_43" "ZZQ-NOT-IN-THIS-BLOCK-43"
reg43 "#43-K6"
assert_eq "#43-K6 CONTROL: commands/pipeline.md was read, and still mandates the 1-ba checkpoint" \
  "$(contains43 "$(norm43 "$PIPELINE_MD")" 'current_phase: "1-ba"')" "present"

reg43 "#43-K1"
assert_eq "#43-K1 commands/pipeline.md carries the shared anchor clause: \"$ANCHOR_43\"" \
  "$(contains43 "$(norm43 "$PIPELINE_MD")" "$ANCHOR_43")" "present"
reg43 "#43-K2"
assert_contains "#43-K2 and the guard states THE SAME clause, in the comment block that holds the strictest-default sentence" \
  "$GUARD_BLOCK_43" "$ANCHOR_43"
# THE THREE PROSE LITERALS #61 ADDS TO THIS CONTRACT, stated together where an implementer will
# read them, because they are the parts of this change no measurement can derive.
#
# NEEDLE SELECTION IS THE TRAP HERE, and it was measured before these were chosen: the block this
# family extracts contains the bare string `1-ba` TEN times, one of them inside ANCHOR_43, which
# is pinned byte-identical. So the paired NEGATIVE cannot be the bare token -- it would be
# unsatisfiable by construction and this file would contradict itself. It is a full distinct
# CLAUSE instead, and the POSITIVE does not contain the negative as a substring, so neither
# control can blind the other.
SITING_61='the map.json requirement now lives on the 2-review row'
STALE_SITING_61='first-visit enforcement lives on the 1-ba row'
RETIRED_61='RETIRED AT EVERY TIER'

# #43-K3 RE-ANCHORED, not deleted, which is what its own previous label instructed. It used to
# assert the block cites `#61` as where the requirement WOULD be re-sited; #61 has now landed, so
# the citation of a future issue is replaced by a statement of the shipped siting.
reg43 "#43-K3"
assert_contains "#43-K3 and the guard states where the map requirement now lives: \"$SITING_61\" -- IF THIS FAILS the siting moved again or the sentence was reworded: re-anchor this assertion AND its paired negative #61-P1 to the new siting, do NOT delete either" \
  "$GUARD_BLOCK_43" "$SITING_61"

# ---------------------------------------------------------------------------
suite "#43 the label namespace itself: unique, and every id that exists actually RAN"
# ---------------------------------------------------------------------------
# A mutation battery discharges itself by naming an assertion label a reader can grep for, so
# the label has to be unique or the grep returns two sites and proves nothing. And an id that
# appears in this file but never ran is the shrinking-cell failure one size up: the per-family
# counters above catch a row that stops executing, this catches a whole family that does.
reg43 "#43-C1"   # lives in the AC24 walk above, registered here where the ledger is defined
reg43 "#43-Z1"
reg43 "#43-Z2"
AC43_UNIQ="$(printf '%s' "$AC43_IDS" | grep . | sort -u)"
assert_eq "#43-Z1 no #43 assertion id is used twice (a colliding label makes the battery's grep return two unrelated sites)" \
  "$(printf '%s\n' "$AC43_IDS" | grep -c . | tr -d ' ')" "$(printf '%s\n' "$AC43_UNIQ" | grep -c . | tr -d ' ')"
assert_eq "#43-Z2 every #43 id written in this file was REGISTERED by a cell that ran" \
  "$(printf '%s\n' "$AC43_UNIQ" | grep -c . | tr -d ' ')" \
  "$(grep -o '#43-[A-Za-z0-9][A-Za-z0-9]*' "${BASH_SOURCE[0]}" | sort -u | grep -c . | tr -d ' ')"

# ===========================================================================================
# #61 -- the map.json requirement, RE-SITED from the `1-ba` row to `2-review`.
#
# THE DEFECT, reproduced at the merge-base before this family was written: an architectural run
# that never ran Phase 0.5 -- no map.json on disk, no `0.5` token in events[] -- and is parked at
# `2-review` is GRANTED, rc 0. The requirement that exists to catch that skip sits on the `1-ba`
# row behind `tiers: ["architectural"]`, and `1-ba` is checkpointed BEFORE BA returns the tier,
# so since #43 the row abstains on the mandated path at every tier. The row looks live and is
# dead. The siting is what is wrong, not the abstention.
#
# WHY THE `#61-` PREFIX. This suite already owns `suite "AC1: ..."` through `suite "AC30: ..."`,
# which are DIFFERENT criteria wearing the numbers #61's spec gave its own. A mutation battery
# discharges itself by naming a label a reader can grep for, and a colliding label makes that
# grep return two unrelated sites and prove nothing. Same reason the `#43-` family exists.
#
# WHAT IS RED HERE BEFORE THE IMPLEMENTATION EXISTS, AND WHAT IS NOT -- stated because a reader
# who expects a Phase-3a contract to be uniformly red will otherwise mistrust the green half.
#   RED at the merge-base, and these ARE the behaviour change:
#     #61-C1..C6   the six tier spellings with map.json absent: granted today, must refuse.
#     #61-F1..F5   the five non-architectural delta sets: {0.5-map-complete} today, and exactly
#                  `2-review` -- that row and no other -- must join them.
#     #61-T1       the exported satisfying set does not cover what actually satisfies the row.
#     #43-K3 / #61-P1 / #61-P2   the guard's own prose still says the requirement is retired.
#   GREEN at the merge-base BY DESIGN, and these are what the change must NOT break:
#     #61-A1..A3  routing evidence        #61-B1..B6  the grant column
#     #61-D1..D5  the events path and its deviation hatch, on the SECOND requirement
#     #61-E1..E8  the ba-approved gate, which a swap would have deleted from the whole route
#     #61-G1/G2   the command pipeline.md publishes    #61-H1..H3  3-impl is not disarmed
#     #61-N1/N2   the undetermined-tier abstention set
#     #61-Q1..Q7  the determination pair, presence-not-content, and replay
#     #61-T2..T5  the token-visibility probe's own controls
#
#   A BARE FAMILY PREFIX IS NOT WRITEABLE HERE, and the first draft of THIS VERY PARAGRAPH proved
#   it twice: the id prefix followed by a wildcard IS an id to the ledger's own grep, and it is
#   one no cell registers, so the checks at the bottom of this family reported nine phantom ids --
#   and then a tenth, from the sentence warning about the other nine. Write the ENDPOINTS.
#   A preservation pin cannot be red before the thing it preserves is broken. Its bite is proved
#   by mutation, never by colour -- which is what #61-M1 is for.
# ===========================================================================================

TESTS61_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The id ledger, same shape as the #43 family's: every id registers as its cell RUNS, and the two
# checks at the bottom compare what ran against every id this file's own source mentions.
AC61_IDS=""
reg61() { AC61_IDS="$AC61_IDS$1
"; }

# mk61 <phase> <tier-json-or-OMIT> <events> -- mk_status always writes the risk_tier key, and the
# ABSENT spelling is one of the six this family asserts invariance over.
mk61() {
  if [[ "$2" == "OMIT" ]]; then
    printf '{"issue_number":4242,"current_phase":"%s","updated_at":"%s","events":%s}' \
      "$1" "$FRESH_ISO" "$3"
  else
    mk_status "$1" "$2" "$3"
  fi
}

# Built in variables, never inline inside a "$(...)": inside a command substitution the escaped
# quotes collapse, the braces end up unquoted and bash brace-expands them, so what reaches disk is
# not valid JSON and the case tests SILENCE instead of the behaviour it names. See AC4's note.
EV_1='[{"phase":"1-ba","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'
EV_05='[{"phase":"0.5-map","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'
EV_1_05='[{"phase":"1-ba","verdict":"complete","at":"2026-01-01T00:00:00Z"},{"phase":"0.5-map","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'
EV_05_SKIPPED_NOTED='[{"phase":"0.5-map","verdict":"SKIPPED","note":"trivial surface, no blast radius to map","at":"2026-01-01T00:00:00Z"}]'
EV_05_SKIPPED_BARE='[{"phase":"0.5-map","verdict":"SKIPPED","at":"2026-01-01T00:00:00Z"}]'
EV_05_RERUN='[{"phase":"0.5-map-rerun","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'
EV_FULL='[{"phase":"1-ba","verdict":"complete","at":"2026-01-01T00:00:00Z"},{"phase":"2-review","verdict":"complete","at":"2026-01-01T00:00:00Z"},{"phase":"2.5-design","verdict":"complete","at":"2026-01-01T00:00:00Z"},{"phase":"3-impl","verdict":"complete","at":"2026-01-01T00:00:00Z"},{"phase":"4-review","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'

SPEC_UNAPPROVED='{"issue_number":4242}'
MISCASED_TIER="Standard"     # unrecognised by KNOWN_TIERS: a real record's mis-cased spelling

# ---------------------------------------------------------------------------
suite "#61 AC1 (routing half): the siting is a CHECKPOINTED entry phase, not a pass-through literal"
# ---------------------------------------------------------------------------
# `grep -o | wc -l`, never `grep -c`, which counts LINES and would silently lower a count if two
# occurrences shared one. This is the ONE property of the siting that ships to an adopting project
# with no `.pipeline` history: the OCCUPANCY half of R1 is a census over committed records and is
# deliberately not asserted anywhere, because it would fail in every downstream clone.
# LIMIT, stated rather than rewritten (#53 R1's sixth strict-form site). The terms passed here
# spell the phase assignment in the UNQUOTED-KEY form `current_phase: "x"`, and pipeline.md
# ALSO writes one assignment in JSON form, `"current_phase": "0-setup"`. Both live terms below
# name phases written the unquoted way, so this helper is CORRECT today and is deliberately not
# widened. A term aimed at a JSON-form assignment would silently return 0 here, which reads as
# "pipeline.md does not say that" rather than as "this pattern cannot see it" -- the exact
# confusion that let a 26-literal file be policed by a 25-literal population. Any new term
# added here must first be checked against BOTH quoting forms.
md61() { grep -o "$1" "$PIPELINE_MD" | wc -l | tr -d ' '; }

reg61 "#61-A1"
assert_eq "#61-A1 pipeline.md mandates a checkpoint INTO \`2-review\`, exactly once -- EXPIRY: if this stops being 1, the routing evidence for this siting has moved and R1's routing half must be re-derived before the row is trusted again" \
  "$(md61 'Checkpoint first.*current_phase: "2-review"')" "1"
reg61 "#61-A2"
assert_eq "#61-A2 PAIRED NEGATIVE: and it mandates no checkpoint into a \`-complete\` literal, which is what makes A1's term DISCRIMINATE -- EXPIRY: if this returns non-zero, pipeline.md has begun checkpointing a pass-through literal, this term has stopped discriminating, and the partition must be re-measured before either half is trusted" \
  "$(md61 'Checkpoint first.*current_phase: "1-ba-complete"')" "0"
reg61 "#61-A3"
assert_eq "#61-A3 DOCUMENTED NON-ZERO CONTROL: the NAIVE term gives the identical answer for the chosen row and for the row rejected for never being occupied, which is why the refined term above is the one doing the work" \
  "$(md61 'current_phase: "2-review"')/$(md61 'current_phase: "1-ba-complete"')" "1/1"

# ---------------------------------------------------------------------------
suite "#61 AC1/AC2/AC3: the decision at 2-review is INVARIANT across all six tier spellings"
# ---------------------------------------------------------------------------
# THE FIXTURE IS PINNED ON EVERY AXIS BUT ONE. spec.json present WITH `ba_approved_at`, events[]
# carrying a `1` token and NO `0.5` token; map.json is the only thing that varies. Measured why
# that matters: with map.json present but no spec.json and events[] empty, all six spellings are
# REFUSED naming spec.json, so the unpinned form of this criterion would have been false of the
# very build it governs -- green for a reason that has nothing to do with the map.
#
# ASSERTED OVER THE SIX, NOT A REPRESENTATIVE. An invariance claim is meaningless from one cell,
# and the map-PRESENT column is what stops the whole family passing on a row that refuses
# everything. The re-sited row carries no `tiers` key and no `byTier` key, so the phase NAME is
# the tier evidence: pipeline.md routes standard runs to `2-constraints` and trivial runs straight
# to `3-impl`, and a run that is AT `2-review` is on the architectural route whatever its
# risk_tier field says. That is a strictly better signal than the field, which is optional in
# status.schema.json and which no script writes.
#
# grant-id | refuse-id | label | risk_tier as written (OMIT = no key at all) | short key
AC61_TIER_ROWS=(
  '#61-B1|#61-C1|architectural|"architectural"|architectural'
  '#61-B2|#61-C2|standard|"standard"|standard'
  '#61-B3|#61-C3|trivial|"trivial"|trivial'
  '#61-B4|#61-C4|absent|OMIT|absent'
  '#61-B5|#61-C5|null|null|null'
  "#61-B6|#61-C6|an unrecognised string|\"$GARBAGE_TIER\"|unrecognised"
)
AC61_SPELLINGS=""
for row in "${AC61_TIER_ROWS[@]}"; do
  IFS='|' read -r gid rid tlabel tierjson tkey <<< "$row"
  AC61_SPELLINGS="$AC61_SPELLINGS $tkey"

  # (a) map.json PRESENT -> GRANTED. Also AC3's first control half.
  new_case 4242 "$(mk61 "2-review" "$tierjson" "$EV_1")"
  printf '%s' "$SPEC_APPROVED" > "$CASE_DIR/spec.json"
  printf '{}' > "$CASE_DIR/map.json"
  gate "$CASE_ROOT"
  reg61 "$gid"
  assert_eq "$gid 2-review at risk_tier $tlabel, spec approved and map.json PRESENT -> granted" \
    "$GATE_DEC" "granted"
  assert_eq "  and it exits 0" "$GATE_RC" "0"

  # (b) map.json ABSENT, and no `0.5` token to stand in for it -> REFUSED, naming map.json.
  new_case 4242 "$(mk61 "2-review" "$tierjson" "$EV_1")"
  printf '%s' "$SPEC_APPROVED" > "$CASE_DIR/spec.json"
  gate "$CASE_ROOT"
  reg61 "$rid"
  assert_eq "$rid 2-review at risk_tier $tlabel, spec approved and NO map.json and no 0.5 token -> refused" \
    "$GATE_DEC" "refused"
  assert_eq "  and it exits 2" "$GATE_RC" "2"
  assert_contains "  and the reason names the missing map.json" "$GATE_OUT" "map.json"
  # The near-miss half: naming spec.json here would send the operator after the file that is
  # sitting in front of them, satisfied. A refusal that names the wrong file is a refusal that
  # teaches its reader to reach for this guard's widest disarm.
  assert_not_contains "  and does NOT name spec.json, which this fixture satisfies" \
    "$GATE_OUT" "spec.json"
done
reg61 "#61-B0"
assert_eq "#61-B0 the family drove every KNOWN_TIER plus every undetermined spelling, in order" \
  "${AC61_SPELLINGS# }" "architectural standard trivial absent null unrecognised"

# THE OPERATOR-FACING HALF of the AC2 cell. `  1. ` alone, never the whole of stderr: measured on
# this file's own earlier form, the diagnosis line names the same file the repair does, so a
# whole-stderr assertion passed while route 1 said something else entirely and a wrong-repair
# mutation SURVIVED. The needle has to be searched where it is supposed to be.
new_case 4242 "$(mk61 "2-review" '"architectural"' "$EV_1")"
printf '%s' "$SPEC_APPROVED" > "$CASE_DIR/spec.json"
gate "$CASE_ROOT"
AC61_R1="$(route1)"
reg61 "#61-C7"
assert_eq "#61-C7 CONTROL: a route 1 line was extracted at all, so the next assertion has a haystack" \
  "$([[ -n "$AC61_R1" ]] && echo found || echo "NO ROUTE 1 LINE")" "found"
reg61 "#61-C8"
assert_contains "#61-C8 and ROUTE 1 ITSELF sends the operator to the phase that produces map.json" \
  "$AC61_R1" "Run the phase that produces \`map.json\`"
reg61 "#61-C9"
assert_contains "#61-C9 and stderr says map.json is NOT PRESENT, which is the true diagnosis here" \
  "$GATE_ERR" "\`map.json\` is not present"

# ---------------------------------------------------------------------------
suite "#61 AC3: the NON-ZERO CONTROL has two halves, so it cannot pass by always granting"
# ---------------------------------------------------------------------------
# Half one is #61-B1 above (the same record with map.json on disk). Half two is the events path:
# the second requirement must be satisfiable by a recorded `0.5` the same way every other row's
# is, or the fresh-checkout route this guard's own header exists for is closed for `2-review` --
# and R11(b)'s adopting-project population is exactly the one that meets it.
ac61_2review() {  # ac61_2review <events> -> a case at 2-review, spec approved, map.json ABSENT
  new_case 4242 "$(mk61 "2-review" '"architectural"' "$1")"
  printf '%s' "$SPEC_APPROVED" > "$CASE_DIR/spec.json"
  gate "$CASE_ROOT"
}
ac61_2review "$EV_05"
reg61 "#61-D1"
assert_eq "#61-D1 no map.json on disk, but a 0.5-map entry in events[] -> granted (path (b), the fresh-checkout route)" \
  "$GATE_DEC" "granted"
assert_eq "  and it exits 0" "$GATE_RC" "0"

# THE DEVIATION HATCH, on the NEW requirement. A recorded SKIP is the only thing that clears a
# row without doing the work, and it costs a written reason -- without the note the hatch is free,
# and a free hatch is not a hatch. Both halves, because the noteless twin is what makes the first
# a discrimination rather than a restatement of #61-D1.
ac61_2review "$EV_05_SKIPPED_NOTED"
reg61 "#61-D2"
assert_eq "#61-D2 a 0.5-map SKIPPED entry WITH a written note clears the map requirement" \
  "$GATE_DEC" "granted"
ac61_2review "$EV_05_SKIPPED_BARE"
reg61 "#61-D3"
assert_eq "#61-D3 and the same entry with NO note does not: the hatch costs a reason" \
  "$GATE_DEC" "refused"
assert_contains "  and that refusal still names map.json" "$GATE_OUT" "map.json"
ac61_2review "$EV_05_RERUN"
reg61 "#61-D4"
assert_eq "#61-D4 a 0.5-map-rerun label resolves through the shared resolver to token 0.5 and clears it" \
  "$GATE_DEC" "granted"
ac61_2review "$EV_1"
reg61 "#61-D5"
assert_eq "#61-D5 NEGATIVE: a 1-ba entry satisfies the spec half and does NOT stand in for the map half" \
  "$GATE_DEC" "refused"

# ---------------------------------------------------------------------------
suite "#61 AC4: the ba-approved gate SURVIVES at the same row -- this is the criterion that forbids a swap"
# ---------------------------------------------------------------------------
# `2-review` is the ONLY row on the architectural route that both is occupied and carries the
# ba-approved content check: `2-constraints` carries it but is standard-only by routing, and
# `1-ba-complete` carries a weaker presence check and has never been a persisted current_phase.
# Swapping map.json IN FOR spec.json here therefore deletes that gate from the entire
# architectural route. Measured under a swap prototype: this cell goes rc 2 -> rc 0.
new_case 4242 "$(mk61 "2-review" '"architectural"' "$EV_1_05")"
printf '%s' "$SPEC_UNAPPROVED" > "$CASE_DIR/spec.json"
printf '{}' > "$CASE_DIR/map.json"
gate "$CASE_ROOT"
reg61 "#61-E1"
assert_eq "#61-E1 map.json present, spec.json present but carrying no ba_approved_at -> still refused" \
  "$GATE_DEC" "refused"
assert_eq "  and it exits 2" "$GATE_RC" "2"
reg61 "#61-E2"
assert_contains "#61-E2 and the refusal names spec.json, not the requirement this issue added" \
  "$GATE_OUT" "spec.json"
reg61 "#61-E3"
assert_not_contains "#61-E3 and does NOT name map.json, which this fixture satisfies" "$GATE_OUT" "map.json"
reg61 "#61-E4"
assert_contains "#61-E4 and stderr says the file IS present rather than sending them after a missing one" \
  "$GATE_ERR" "\`spec.json\` IS present"
reg61 "#61-E5"
assert_contains "#61-E5 and diagnoses what it lacks" "$GATE_ERR" 'carries no `ba_approved_at`'
reg61 "#61-E6"
assert_contains "#61-E6 and route 1 is the CONTENT repair, not a re-run of the phase that produced it" \
  "$(route1)" 'set `ba_approved_at` in .pipeline/4242/spec.json'

# BOTH obligations failing at once. The refusal names ONE file, which keeps the single-route `1. `
# address that route1() depends on -- an address bought by a wrong-repair mutation that SURVIVED a
# whole-stderr assertion. EXPIRY: if this fails, the row's two halves are no longer evaluated
# primary-first, and the panel must re-check that route1()'s needle still has one address before
# accepting the change.
new_case 4242 "$(mk61 "2-review" '"architectural"' "$NO_EVENTS")"
printf '%s' "$SPEC_UNAPPROVED" > "$CASE_DIR/spec.json"
gate "$CASE_ROOT"
reg61 "#61-E7"
assert_eq "#61-E7 with BOTH obligations failing the turn is refused" "$GATE_DEC" "refused"
reg61 "#61-E8"
assert_eq "#61-E8 and the refusal names exactly ONE prerequisite file, so the single-route message shape holds" \
  "$(route1 | grep -o 'spec\.json\|map\.json' | sort -u | tr '\n' ' ' | sed 's/ $//')" "spec.json"

# ---------------------------------------------------------------------------
suite "#61 AC5: DELTA PRESERVATION -- exactly one row joins the refusing set, at every non-architectural spelling"
# ---------------------------------------------------------------------------
# THE FIXTURE, stated in full because silence on this axis makes the criterion false of today's
# guard: with NOTHING present and events[] empty the same tiers refuse at 13 of 15 rows, so an
# unpinned fixture measures the wrong thing. Here: spec.json WITH ba_approved_at, constraints.md
# non-empty, review.json / design.json / impl-report.json / peer-review.json present, map.json
# ABSENT, events[] = [1, 2, 2.5, 3, 4], updated_at 1h ago.
#
# SETS, NEVER COUNTS. Comparing counts would let a lost refusal and a gained refusal cancel.
# Measured baseline at the merge-base, for all five spellings: exactly {0.5-map-complete}. The
# expected value below is that baseline plus `2-review` -- that row and NO OTHER. The clause is
# NAMED rather than described: a description like "a row pipeline.md routes only at the
# architectural tier" also admits `2.5-design` and two `-complete` literals, so a belt-and-braces
# SECOND siting would satisfy the descriptive form while the spec's own out_of_scope forbids one.
AC61_SWEEP=""
ac61_sweep_refusing() {  # <tier-json-or-OMIT> -> AC61_SWEEP, the phases returning rc 2, in walk order
  local tierjson="$1" row phase out=""
  for row in "${GUARDED_ROWS[@]}"; do
    IFS='|' read -r phase _t _p _b <<< "$row"
    new_case 4242 "$(mk61 "$phase" "$tierjson" "$EV_FULL")"
    printf '%s' "$SPEC_APPROVED"  > "$CASE_DIR/spec.json"
    printf '{}'                   > "$CASE_DIR/review.json"
    printf '{}'                   > "$CASE_DIR/design.json"
    printf '{}'                   > "$CASE_DIR/impl-report.json"
    printf '{}'                   > "$CASE_DIR/peer-review.json"
    printf '# constraints'        > "$CASE_DIR/constraints.md"
    gate "$CASE_ROOT"
    if [[ "$GATE_RC" == "2" ]]; then out="$out $phase"; fi
  done
  AC61_SWEEP="${out# }"
}

# id | label | risk_tier as written (OMIT = no key at all)
AC61_DELTA_ROWS=(
  '#61-F1|standard|"standard"'
  '#61-F2|trivial|"trivial"'
  '#61-F3|absent|OMIT'
  '#61-F4|null|null'
  "#61-F5|the mis-cased spelling \"$MISCASED_TIER\"|\"$MISCASED_TIER\""
)
for row in "${AC61_DELTA_ROWS[@]}"; do
  IFS='|' read -r id dlabel tierjson <<< "$row"
  ac61_sweep_refusing "$tierjson"
  reg61 "$id"
  assert_eq "$id at risk_tier $dlabel the never-mapped run is refused at the baseline row and at 2-review, and at NO other row" \
    "$AC61_SWEEP" "2-review 0.5-map-complete"
done

# ---------------------------------------------------------------------------
suite "#61 AC6: the undetermined-tier ABSTENTION SET is unchanged, asserted on the OUTCOME"
# ---------------------------------------------------------------------------
# On the outcome rather than on a keyword, and that is the whole point: PREREQUISITES is `const`
# and not exported, so a source regex over the spelling `tiers:` is the only table-shaped
# assertion available and it is a blocklist over a spelling. Verified to discriminate: a second
# restriction spelled `onlyTiers` on `2-review` keeps the published `tiers: \[` grep at exactly 1
# -- so #61-G1 below still passes -- and turns this set into {1-ba, 2-review}.
AC61_NA=""
for row in "${GUARDED_ROWS[@]}"; do
  IFS='|' read -r phase _t _p _b <<< "$row"
  new_case 4242 "$(mk61 "$phase" "OMIT" "$NO_EVENTS")"
  gate "$CASE_ROOT"
  if [[ "$GATE_DEC" == "not-applicable" ]]; then AC61_NA="$AC61_NA $phase"; fi
done
reg61 "#61-N1"
assert_eq "#61-N1 with an undetermined tier and no artifacts at all, exactly ONE guarded row abstains, and it is still the 1-ba row" \
  "${AC61_NA# }" "1-ba"
reg61 "#61-N2"
assert_eq "#61-N2 VACUITY CONTROL: that walk really visited all 15 guarded rows" \
  "${#GUARDED_ROWS[@]}" "15"

# ---------------------------------------------------------------------------
suite "#61 AC7: the re-derivation command commands/pipeline.md publishes stays TRUE"
# ---------------------------------------------------------------------------
# A two-file agreement with prose this lane may not edit: pipeline.md publishes this command and
# asserts it returns exactly one hit, on the `1-ba` row. An exact equality pinned to an identity,
# not a decaying floor. The second-key evasion a grep cannot catch is #61-N1's job, deliberately.
reg61 "#61-G1"
# A SPELLING PIN, NOT A COVERAGE GUARD, and this round measured the difference: at the previous
# head, planting `tiers: ["architectural"]` on a byTier CELL reddened this cell, while the same
# plant spelled `tiers:["architectural"]` -- one space fewer -- survived the whole suite at
# 451/0. The two-file agreement with pipeline.md is what this pins; the coverage it looked like
# it was providing is #61-S1's job, which grades the POSITION and catches both spellings.
assert_eq "#61-G1 \`tiers: [\` appears exactly once in the guard -- a SPELLING pin held jointly with commands/pipeline.md, not a coverage guard: \`tiers:[\` evades it and #61-S1 is what catches that" \
  "$(grep -o 'tiers: \[' "$GUARD" | wc -l | tr -d ' ')" "1"
reg61 "#61-G2"
assert_contains "#61-G2 and the one hit is on the 1-ba row" "$(grep 'tiers: \[' "$GUARD")" '"1-ba"'

# ---------------------------------------------------------------------------
suite "#61 AC8: 3-impl is NOT disarmed at any undetermined spelling"
# ---------------------------------------------------------------------------
# This suite exists because the obvious discharge of the previous draft's blocker -- gating every
# byTier row on `tierDetermined` -- silently flips these three from rc 2 to rc 0 while satisfying
# every other criterion in #61's list. The fixture is the one measured for that flip: spec.json
# approved, map.json present, constraints.md non-empty, design.json ABSENT, events[] empty.
AC61_H_ROWS=(
  '#61-H1|absent|OMIT'
  '#61-H2|null|null'
  "#61-H3|an unrecognised string|\"$GARBAGE_TIER\""
)
for row in "${AC61_H_ROWS[@]}"; do
  IFS='|' read -r id hlabel tierjson <<< "$row"
  new_case 4242 "$(mk61 "3-impl" "$tierjson" "$NO_EVENTS")"
  printf '%s' "$SPEC_APPROVED" > "$CASE_DIR/spec.json"
  printf '{}'                  > "$CASE_DIR/map.json"
  printf '# constraints'       > "$CASE_DIR/constraints.md"
  gate "$CASE_ROOT"
  reg61 "$id"
  assert_eq "$id 3-impl at risk_tier $hlabel with no design.json and no 2.5 token -> still refused" \
    "$GATE_DEC" "refused"
  assert_eq "  and it exits 2" "$GATE_RC" "2"
  assert_contains "  and the reason still names design.json" "$GATE_OUT" "design.json"
done

# ---------------------------------------------------------------------------
suite "#61 AC9/AC10: the guard's own prose, POSITIVE and NEGATIVE, in the block that holds the strictest-default sentence"
# ---------------------------------------------------------------------------
# Co-location, not a fixed address -- block43() finds the ONE comment block holding the marker, so
# a whole-file grep passing with the sentence pasted anywhere is not enough. The extractor's own
# two controls (#43-K4 finds a known-present string, #43-K5 reports absence for a known-absent
# one) run above and must both stay, or an extractor returning `<no-block>` makes every negative
# below pass VACUOUSLY. The positive half is #43-K3, re-anchored above.
reg61 "#61-P1"
assert_not_contains "#61-P1 PAIRED NEGATIVE: and the block does not also claim \"$STALE_SITING_61\" -- both halves are exercised, so a block naming BOTH rows as current fails instead of passing on the positive alone. EXPIRY: if this fails, the prose has re-acquired the stale siting and #43-K3 alone can no longer tell a correct block from a contradictory one" \
  "$GUARD_BLOCK_43" "$STALE_SITING_61"
reg61 "#61-P2"
assert_not_contains "#61-P2 and no surviving sentence says the map requirement is $RETIRED_61 -- that sentence was TRUE of the 1-ba siting and is false of this one" \
  "$GUARD_BLOCK_43" "$RETIRED_61"
reg61 "#61-P3"
assert_contains "#61-P3 CONTROL: the ANCHOR_43 clause is still in that same block, byte-identical, so the rewrite edited the block rather than replacing it" \
  "$GUARD_BLOCK_43" "$ANCHOR_43"
reg61 "#61-P4"
assert_eq "#61-P4 CONTROL: and the extractor returned a real block, not the <no-block> sentinel that would make P1 and P2 vacuous" \
  "$([[ "$GUARD_BLOCK_43" == "<no-block>" || -z "$GUARD_BLOCK_43" ]] && echo "NO BLOCK EXTRACTED" || echo extracted)" \
  "extracted"

# ---------------------------------------------------------------------------
suite "#61 AC11: the deletion battery's named label, and the harness that lets it discharge itself"
# ---------------------------------------------------------------------------
# AC11 IS a mutation, so what ships is the harness half: the label the battery names must be
# UNIQUE across tests/, or the grep a reader runs to check the discharge returns two unrelated
# sites and proves nothing. ASSEMBLED FROM TWO PIECES so this assertion is not itself an
# occurrence -- the self-counting trap, which this repo has hit twice.
AC61_BATTERY_LABEL="#61-""C1"
# CODE lines only. A prose mention of the id in a comment is not an assertion SITE, and refusing
# them would make the rule un-followable in the one place the id most needs explaining -- the same
# discrimination the moving-ref ratchet draws between describing a construct and using it. What
# must be unique is the site a reader lands on when the battery says "this label went red".
ac61_label_sites() {  # <needle> -> occurrences on non-comment lines across tests/
  grep -h -- "$1" "$TESTS61_DIR"/*.sh 2>/dev/null | grep -v '^[[:space:]]*#' | grep -c . | tr -d ' '
}
reg61 "#61-M1"
assert_eq "#61-M1 the label the map.json-deletion battery discharges itself by naming has EXACTLY ONE assertion site across tests/" \
  "$(ac61_label_sites "$AC61_BATTERY_LABEL")" "1"
reg61 "#61-M2"
assert_eq "#61-M2 CONTROL: the same counter CAN return more than one, so the 1 above is a measurement and not a search that finds nothing" \
  "$(ac61_label_sites "reg61" | awk '{print ($1 > 1 ? "can-see-more" : "SEES-ONLY-ONE")}')" \
  "can-see-more"
# ASSEMBLED for the same reason as the battery label above: written whole, the absent needle would
# be PRESENT on this very line and the zero control would report 1.
AC61_ABSENT_LABEL="ZZQ-NO-SUCH""-LABEL-61"
reg61 "#61-M3"
assert_eq "#61-M3 CONTROL: and it returns ZERO for a label that is nowhere, so #61-M1 is not counting a pattern that matches everything" \
  "$(ac61_label_sites "$AC61_ABSENT_LABEL")" "0"

# ---------------------------------------------------------------------------
suite "#61 AC12: the tier-determination PAIR, which is stated in two places and stays in sync on only one axis"
# ---------------------------------------------------------------------------
# `normalizeTier` and the raw-field determination check at the call site both read KNOWN_TIERS, so
# adding a TIER stays in sync automatically. A change to the MATCHING RULE -- a `.trim()`, a
# `.toLowerCase()` -- diverges silently, and nothing pinned it.
#
# THE DISCRIMINATING SPELLING IS ` trivial`, NOT ` architectural`, and this was measured rather
# than reasoned: under a `.trim()` added to normalizeTier alone, ` architectural` still resolves
# to the architectural row (it already did, via the strictest-row default) and tierDetermined is
# still false, so EVERY assertion about it is unchanged and the mutation is a no-op there. Only a
# spelling whose trimmed form is a DIFFERENT tier than the strictest default can see the change.
new_case 4242 "$(mk_status "1-ba" '" architectural"' "$NO_EVENTS")"
gate "$CASE_ROOT"
reg61 "#61-Q1"
assert_eq "#61-Q1 a leading-space risk_tier is UNDETERMINED at the call site, so a tiers-restricted row does not apply" \
  "$GATE_DEC" "not-applicable"
reg61 "#61-Q2"
assert_contains "#61-Q2 and the guard says so in its own words rather than claiming a tier it does not have" \
  "$GATE_OUT" "carries no determined risk_tier"

# The leg that BITES. spec.json present (the trivial row's prerequisite) and design.json absent
# (the architectural row's) is the one presence combination where the two byTier cells disagree.
new_case 4242 "$(mk_status "3-impl" '" trivial"' "$NO_EVENTS")"
printf '{}' > "$CASE_DIR/spec.json"
gate "$CASE_ROOT"
reg61 "#61-Q3"
assert_eq "#61-Q3 and a leading-space \` trivial\` still resolves to the STRICTEST row -- this is the leg that reddens if normalizeTier alone gains a normalising transform the determination check does not" \
  "$GATE_DEC" "refused"
reg61 "#61-Q4"
assert_contains "#61-Q4 and it names design.json, the architectural cell's prerequisite, not spec.json" \
  "$GATE_OUT" "design.json"

# ---------------------------------------------------------------------------
suite "#61 AC13: every token that can satisfy the re-sited row is visible on the EXPORTED surface"
# ---------------------------------------------------------------------------
# THE PROPERTY, asserted as an OUTCOME and not as a mechanism, because it CONSTRAINS the
# mechanism: the drift suite's registry-conformance walk enumerates tokens ONLY through
# `satisfyingTokens` over ENTRY+EXIT, so a token the guard will ACCEPT for a row but which that
# function does not return is invisible to the one check that exists to catch strays. Measured
# under a prototype that held the second requirement's tokens outside the returned set: a stray
# planted there left the drift suite 37 passed / 0 failed -- BLIND -- while the identical stray in
# the primary tokens went 36/1.
#
# So this does not read the table. It DERIVES the accepted set by driving the real CLI once per
# token in the imported registry, on each half of the row in turn, and compares that observation
# against what the module reports. Equality in both directions: a token that satisfies and is not
# reported is the blindness; a token reported but not honoured is a set that has stopped
# describing the row.
# The registry is passed as argv[2], NEVER argv[1]: dispatch-model.mjs self-runs as a CLI when
# its own path is argv[1], and it then prints its unknown-role diagnostic and exits 2. Read as a
# token list that would be a fixture of English words, silently, which is how the first spelling
# of this probe reported a 29-token registry. The drift suite passes it in the same position for
# the same reason.
KNOWN_PHASES_61="$(node --input-type=module -e '
  const { KNOWN_PHASES } = await import(process.argv[2]);
  process.stdout.write(KNOWN_PHASES.join(" "));
' "$GUARD" "$SCRIPTS_DIR/dispatch-model.mjs" 2>/dev/null)"

AC61_GRANTING=""
ac61_granting_tokens() {  # <phase> [<file>=<body>]... -> AC61_GRANTING, sorted and space-joined
  local phase="$1"; shift
  local t f events out=""
  for t in $KNOWN_PHASES_61; do
    events='[{"phase":"'"$t"'","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'
    new_case 4242 "$(mk_status "$phase" '"architectural"' "$events")"
    if [[ "$#" -gt 0 ]]; then
      for f in "$@"; do printf '%s' "${f#*=}" > "$CASE_DIR/${f%%=*}"; done
    fi
    gate "$CASE_ROOT"
    if [[ "$GATE_DEC" == "granted" ]]; then out="$out
$t"; fi
  done
  AC61_GRANTING="$(printf '%s' "$out" | grep . | sort -u | tr '\n' ' ' | sed 's/ $//')"
}

ac61_reported() {  # <phase> [<tier>|ABSENT] -> the exported satisfying set, sorted, space-joined
  node --input-type=module -e '
    const m = await import(process.argv[1]);
    const t = process.argv[3] === "ABSENT" ? undefined : process.argv[3];
    process.stdout.write([...m.satisfyingTokens(process.argv[2], t)].sort().join(" "));
  ' "$GUARD" "$1" "${2:-architectural}" 2>&1
}

# HALF ONE: map.json on disk, spec.json ABSENT -- only events[] can satisfy the ba-approved half.
ac61_granting_tokens 2-review "map.json={}"
AC61_TOK_PRIMARY="$AC61_GRANTING"
# HALF TWO: spec.json present AND approved, map.json ABSENT -- only events[] can satisfy the map
# half. At the merge-base this half grants for EVERY token, because there is no second
# requirement to satisfy: that is the shape of the defect, seen from the token side.
ac61_granting_tokens 2-review "spec.json=$SPEC_APPROVED"
AC61_TOK_SECONDARY="$AC61_GRANTING"

reg61 "#61-T1"
assert_eq "#61-T1 every token the 2-review row ACCEPTS -- on either half -- is reachable from the exported satisfyingTokens, which is what makes the drift suite's registry walk total over this row" \
  "$(printf '%s\n%s\n' "$AC61_TOK_PRIMARY" "$AC61_TOK_SECONDARY" | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ' | sed 's/ $//')" \
  "$(ac61_reported 2-review architectural)"

# THE NON-ZERO CONTROL, in the same run: the identical probe over a row this change does not
# touch. Without it, agreement above is indistinguishable from a probe that grants nothing and a
# report that returns nothing.
ac61_granting_tokens 4-review
reg61 "#61-T2"
assert_eq "#61-T2 NON-ZERO CONTROL: the same probe over an UNCHANGED row reproduces that row's exported set exactly" \
  "$AC61_GRANTING" "$(ac61_reported 4-review architectural)"
reg61 "#61-T3"
assert_eq "#61-T3 and that control set is NON-EMPTY, so #61-T2 is an observation rather than two absences agreeing" \
  "$([[ -n "$AC61_GRANTING" ]] && echo "$AC61_GRANTING" || echo "EMPTY: the probe granted for no token at all")" \
  "3 3b"
reg61 "#61-T4"
assert_eq "#61-T4 VACUITY CONTROL: the probe drove the whole imported phase registry, not a subset it happened to remember" \
  "$(printf '%s' "$KNOWN_PHASES_61" | tr ' ' '\n' | grep -c . | tr -d ' ')" "10"

# THE TIER AXIS. The row carries no `tiers` and no `byTier` key, so its exported set must be
# byte-identical at every spelling -- the same invariance #61-B1..B6 and #61-C1..C6 assert on the
# decision, asserted here on the surface the drift walk actually reads.
reg61 "#61-T5"
assert_eq "#61-T5 and the exported set for 2-review is identical at all six tier spellings" \
  "$(ac61_reported 2-review trivial)/$(ac61_reported 2-review standard)/$(ac61_reported 2-review architectural)/$(ac61_reported 2-review "$GARBAGE_TIER")/$(ac61_reported 2-review ABSENT)" \
  "$(ac61_reported 2-review architectural)/$(ac61_reported 2-review architectural)/$(ac61_reported 2-review architectural)/$(ac61_reported 2-review architectural)/$(ac61_reported 2-review architectural)"

# ---------------------------------------------------------------------------
suite "#61 the rule table's ROW SHAPE, which is what makes the arity ceiling LOUD instead of silent"
# ---------------------------------------------------------------------------
# WHY THIS EXISTS. `also` expresses exactly TWO requirements. A third, written as a nested
# `also.also`, is measured to be BOTH invisible to `satisfyingTokens` (the drift walk stays 37/0
# with a stray planted there) AND inert on the decision path (rc 0 with its file absent) -- a
# written requirement silently not enforced, which is the guard claiming more than it knows. The
# union in `satisfyingTokens` is total for the shape someone remembered, not total by
# construction. This converts that permissive silence into a failure.
#
# AN OUTCOME PROPERTY OVER EVERY POSITION THE WALK REACHES, not a blocklist over a spelling: the
# module walks its own live table, reports every key set it holds TAGGED BY POSITION, and the
# permitted set for each position is stated HERE, so the table is not graded against its own
# opinion. A key nobody taught the walk to read fails whatever it is called.
#
# WHY POSITION AND NOT JUST NAME, measured rather than reasoned about. The first spelling of this
# check was total over key NAMES and read two structurally distinct positions as one "row", and
# two written-but-never-read keys passed it with both suites fully green:
#   - `tiers` on a `byTier` CELL. `appliesAtTier` reads the RAW top-level row, so the cell's copy
#     is inert; the row went on firing at the tier the cell said to exclude.
#   - `file`/`tokens` on a `byTier` DISPATCHER row. `rowFor` returns the cell, so the dispatcher's
#     copy is inert -- and the guard GRANTED rc 0 with the named file absent, which is a written
#     requirement never enforced, the same claim-more direction as the nested `also.also`.
# Hence four permitted sets, one per position, each naming exactly the keys a reader reaches
# there. The dispatcher's `tiers` is in its set because it IS read: driven through the CLI, a
# `tiers: ["architectural"]` written on the `3-impl` dispatcher turned a standard-tier refusal
# into `not-applicable`, so excluding it would refuse a key the guard honours.
#
# WHAT THIS STILL DOES NOT GRADE, so nobody reads it as more than it is.
#   - The walk descends into `byTier` and `also` and nowhere else: a key holding a nested object
#     under any OTHER name is reported as a stray at its parent, which is the right failure, but
#     its interior is never visited.
#   - A NEW position whose keys are all permitted is invisible to the SUBSET check by
#     construction; #61-S4's count and #61-S7's census are the legs that see one, which is why
#     both carry their own expiry.
#   - A MISSING key is never a stray, because a subset check has nothing to compare against.
#     Two live consequences, both measured, both left to the behavioural suite this round:
#     a `byTier` cell key that no `KNOWN_TIERS` spelling selects (`archtiectural`) makes `rowFor`
#     return undefined and the guard fall SILENT for every record at that phase and tier (400/59
#     when planted, all behavioural); and a cell carrying no `file` at all demands nothing, which
#     the guard grants. #61-S8/S9 below close the sub-case that speaks -- a live `tokens` or
#     `content` with no `file` to hang on, and an `also` whose `file` is missing or empty -- and
#     they close it by VALUE, which is the one thing a key set cannot see.
AC61_ROW_KEYS="file tokens content tiers also"
AC61_CELL_KEYS="file tokens content also"
AC61_DISPATCH_KEYS="byTier tiers"
AC61_ALSO_KEYS="file tokens content"
# <row keys> <byTier cell keys> <byTier dispatcher keys> <also sub-row keys> -> "<path>:<key>" ...
# An unrecognised kind is deliberately NOT defaulted: allow[kind] comes back undefined, the walk
# throws, 2>&1 puts the stack where the expected value should be, and the cell reddens. A default
# would silently grade a fifth position against somebody else's list.
ac61_shape_strays() {
  node --input-type=module -e '
    const m = await import(process.argv[1]);
    const allow = {
      row: new Set(process.argv[2].split(" ")),
      cell: new Set(process.argv[3].split(" ")),
      dispatcher: new Set(process.argv[4].split(" ")),
      also: new Set(process.argv[5].split(" ")),
    };
    const strays = [];
    for (const s of m.rowShapes()) {
      for (const k of s.keys) if (!allow[s.kind].has(k)) strays.push(s.path + ":" + k);
    }
    process.stdout.write(strays.sort().join(" "));
  ' "$GUARD" "$1" "$2" "$3" "$4" 2>&1
}

reg61 "#61-S1"
assert_eq "#61-S1 every position's key set is a subset of the keys a reader actually reaches THERE -- row {$AC61_ROW_KEYS}, byTier cell {$AC61_CELL_KEYS}, byTier dispatcher {$AC61_DISPATCH_KEYS}, also sub-row {$AC61_ALSO_KEYS} -- EXPIRY: if this fails the table grew a key at a position nothing reads, so either teach that position's reader (satisfyingTokens, rowFor, appliesAtTier or the decision path) IN THE SAME COMMIT or normalize the table to a requires[] list; do NOT widen the permitted set to make it green" \
  "$(ac61_shape_strays "$AC61_ROW_KEYS" "$AC61_CELL_KEYS" "$AC61_DISPATCH_KEYS" "$AC61_ALSO_KEYS")" ""
# NON-ZERO CONTROL that DISCRIMINATES rather than merely fires: drop `also` from the permitted
# row keys and exactly ONE stray comes back, naming the row that carries it. That pins three
# things at once -- the checker can go red, the `also` key is really on the table, and it is on
# ONE row (the spec forbids a belt-and-braces second siting).
#
# READ THE RED SETS OF S2/S3/S5/S6 AS TABLE-GLOBAL, NOT AS POSITION-LOCAL. Each withholds a
# different key and asserts one exact stray string, but `ac61_shape_strays` returns the WHOLE
# sorted stray list, so a stray planted ANYWHERE reddens all four together -- measured: one stray
# on the unrelated `2-constraints` row reddens S1, S2, S3, S5 and S6 at once. What each control
# discriminates is the PAIR it was built around (a cell mis-tagged as a row reddens exactly S6
# and S7 and nothing else). The red set is evidence that something moved, never evidence of WHERE.
reg61 "#61-S2"
assert_eq "#61-S2 NON-ZERO CONTROL: with \`also\` removed from the permitted set the check reddens, on exactly one row, and it is the re-sited one" \
  "$(ac61_shape_strays "file tokens content tiers" "file tokens content" "$AC61_DISPATCH_KEYS" "$AC61_ALSO_KEYS")" "2-review:also"
# AND THE SUB-ROW IS GRADED AGAINST THE NARROWER SET, which is the half that defends the ceiling:
# withhold `tokens` from the ALSO permitted keys only. `tokens` is still permitted on a ROW, so a
# sub-row graded by the wrong list would come back clean and this control would pass on two
# absences agreeing. Exactly one stray, and it is the sub-row's.
reg61 "#61-S3"
assert_eq "#61-S3 SECOND CONTROL: the also sub-row is graded against the ALSO list, not the wider row list -- which is what makes a nested third requirement fail rather than pass as a row" \
  "$(ac61_shape_strays "$AC61_ROW_KEYS" "$AC61_CELL_KEYS" "$AC61_DISPATCH_KEYS" "file content")" "2-review.also:tokens"
# EACH POSITION IS GRADED AGAINST ITS OWN LIST, and both halves of that need a control that
# DISCRIMINATES rather than merely fires. Withhold `byTier` from the DISPATCHER list while
# leaving it permitted on a plain row: exactly one stray comes back, and only because `3-impl` is
# tagged `dispatcher`. Were it tagged `row` the key would be permitted and this would return
# nothing, so the cell cannot pass on two absences agreeing.
reg61 "#61-S5"
assert_eq "#61-S5 THIRD CONTROL: the byTier DISPATCHER row is graded against the dispatcher list, which is what makes a primary requirement written where rowFor never looks fail instead of pass as a row" \
  "$(ac61_shape_strays "file tokens content tiers byTier also" "$AC61_CELL_KEYS" "tiers" "$AC61_ALSO_KEYS")" "3-impl:byTier"
# The same shape for the CELL half: withhold `content` from the cell list only. `content` stays
# permitted on a row, so a cell graded by the wrong list comes back clean and this control fails.
reg61 "#61-S6"
assert_eq "#61-S6 FOURTH CONTROL: a byTier CELL is graded against the cell list, which is what makes a \`tiers\` written on a cell -- inert, because appliesAtTier reads the raw top-level row -- fail instead of pass as a row" \
  "$(ac61_shape_strays "$AC61_ROW_KEYS" "file tokens also" "$AC61_DISPATCH_KEYS" "$AC61_ALSO_KEYS")" "3-impl.byTier.standard:content"
# AND THE KINDS THEMSELVES ARE PINNED. Every control above is a statement about a kind, so a walk
# that re-tagged one position as another would move which list grades what while every subset
# check stayed green. EXPIRY: this moves when the TABLE's shape moves, never to make a suite
# green -- a kind count that changed without a table change means the walk started tagging by
# contents instead of by position.
reg61 "#61-S7"
assert_eq "#61-S7 the walk tags 14 plain rows, 1 byTier dispatcher, 3 byTier cells and 1 also sub-row -- the census the four permitted sets are grading" \
  "$(node --input-type=module -e '
     const m = await import(process.argv[1]);
     const n = {};
     for (const s of m.rowShapes()) n[s.kind] = (n[s.kind] || 0) + 1;
     process.stdout.write(Object.keys(n).sort().map((k) => k + ":" + n[k]).join(" "));
   ' "$GUARD" 2>&1)" \
  "also:1 cell:3 dispatcher:1 row:14"
# 19 = 15 rows + 3 byTier cells + 1 also sub-row.
reg61 "#61-S4"
assert_eq "#61-S4 VACUITY CONTROL: the shape walk visited one entry per guarded row, plus the sub-structures, rather than a subset it happened to remember -- EXPIRY: a new row or a new sub-structure is EXPECTED to redden this, and that failure is the point. #61-S1 grades KEYS and is blind BY CONSTRUCTION to a new POSITION whose keys are all permitted; this count and #61-S7's census are the only legs that see one -- and they cannot move apart, because this total is the sum of that census's per-kind counts. Read the new entry, decide whether satisfyingTokens AND the decision path both reach it, and move the number in that same commit -- never alone to make the suite green" \
  "$(node --input-type=module -e '
     const m = await import(process.argv[1]);
     const s = m.rowShapes();
     // A phase name CONTAINS a dot (`0.5-map`, `2.5-design`), so "top level" is the absence of a
     // sub-structure SEGMENT, never the absence of a dot. The first spelling of this counted 13.
     const sub = (p) => p.includes(".byTier.") || p.endsWith(".also");
     process.stdout.write(s.filter((r) => !sub(r.path)).length + "/" + s.length);
   ' "$GUARD" 2>&1)" \
  "${#GUARDED_ROWS[@]}/19"

# A KEY IS ONLY LIVE WHEN THE SIBLING IT HANGS ON IS, and the checks above cannot see that. They
# grade key NAMES per position, independently of each other, so a shape whose every key is
# permitted at its position can still be silently inert: `tokens` and `content` are read only
# inside `checkOne`, which a vacuous primary skips, so on a `file: null` row they are consulted by
# nothing on the decision path while `satisfyingTokens` reports the tokens anyway. `{ file: null,
# tokens: [] }` and `{ file: null, tokens: ["0.5"] }` are the SAME key set, so no subset check can
# separate them -- which is why `rowShapes()` publishes each position's raw object and the rule
# lives here. Both directions were driven through the real CLI before these cells were written:
#   - CLAIM-MORE. `"0.5-map": { file: null, tokens: ["0.5"] }` -> `satisfyingTokens` REPORTS
#     ["0.5"] while the CLI GRANTS rc 0 on an empty events[] with no map.json anywhere. A written
#     requirement, published on the reporting surface, enforced by nobody -- byte for byte the
#     class the suite below closes for `also`, one key over.
#   - FAIL-OPEN SILENCE. An `also` with no usable `file` makes `path.join(dir, undefined)` throw,
#     and the guard's fail-OPEN catch swallows it: no stdout, no stderr, rc 0. That is not merely
#     a lost grant. With two resolvable issue dirs it swallows the OTHER dir's genuine rc 2 --
#     measured: signal names a record that refuses, mtime names a record parked at the malformed
#     row, previous head rc 2 with the refusal intact, patched head rc 0 and stdout EMPTY.
#     Through hooks/stop.sh, which branches only on rc 2 and discards stdout, that reads as a pass.
#
# `also` IS EXEMPT FROM THE FIRST RULE, DELIBERATELY, and this is the half a key-name reading of
# it would get wrong: an `also` on a `file: null` row is LIVE -- #61-V3 below drives exactly that
# shape and the guard REFUSES. Refusing it here would build-fail a shape the guard honours, which
# is the same error pointed the other way.
ac61_sibling_inert() {  # -> "<path>:<field>" per live field with no truthy `file` beside it
  node --input-type=module -e '
    const m = await import(process.argv[1]);
    const bad = [];
    for (const s of m.rowShapes()) {
      if (s.node.file) continue;
      if (Array.isArray(s.node.tokens) && s.node.tokens.length) bad.push(s.path + ":tokens");
      if (s.node.content) bad.push(s.path + ":content");
    }
    process.stdout.write(bad.sort().join(" "));
  ' "$GUARD" 2>&1
}
reg61 "#61-S8"
assert_eq "#61-S8 no position states a requirement that nothing can read: a \`tokens\` or \`content\` whose sibling \`file\` is falsy is skipped with the vacuous primary and still REPORTED by satisfyingTokens -- EXPIRY: if this fails, either give that requirement a \`file\` or delete it; making \`checkOne\` run on a vacuous primary would path.join on null and silence the guard, and widening this rule to accept it would publish a requirement the decision path never consults" \
  "$(ac61_sibling_inert)" ""
# The SECOND rule, and it is about SILENCE rather than about a wrongful grant: every `also`
# sub-row's `file` must be a usable string. Missing -> path.join throws; empty -> path.join
# returns the ISSUE DIR, which exists, so the second requirement passes on the directory's own
# existence and grants. Neither is visible to #61-S1: `file` is a permitted `also` key, and the
# subset check sees a permitted key whether it is absent or holds junk.
ac61_also_files() {  # -> "<path>:<file-as-JSON>" for every `also` whose file is not a usable string
  node --input-type=module -e '
    const m = await import(process.argv[1]);
    const bad = [];
    for (const s of m.rowShapes()) {
      if (s.kind !== "also") continue;
      if (typeof s.node.file !== "string" || s.node.file.trim() === "") {
        bad.push(s.path + ":" + JSON.stringify(s.node.file === undefined ? "<absent>" : s.node.file));
      }
    }
    process.stdout.write(bad.sort().join(" "));
  ' "$GUARD" 2>&1
}
reg61 "#61-S9"
assert_eq "#61-S9 every \`also\` sub-row names a real file: an absent or empty \`file\` there is not a wrong answer but NO answer -- the guard throws inside its own fail-OPEN catch and exits rc 0 with both streams empty, swallowing any OTHER issue dir's refusal in the same run -- EXPIRY: if this fails, give the \`also\` a filename; an events-only second requirement is not expressible in this table and adding one means teaching checkOne, in the same commit" \
  "$(ac61_also_files)" ""
# NON-ZERO CONTROL FOR BOTH, and it discriminates VALUES from KEYS, which is the whole point of
# the two cells above: `0.5-map` HAS a `file` key and its value is null, so a walk that graded
# key names would place it in neither list and both rules would be vacuously true forever. This
# census is read off the same `node` objects, so it is also what fails loudly if `rowShapes()`
# ever stops publishing them. EXPIRY: it moves when the TABLE moves -- a row that stops demanding
# a file, or a second `also` -- and never to make the suite green.
reg61 "#61-S10"
assert_eq "#61-S10 NON-ZERO CONTROL: the vacuous positions and the \`also\` filename, read off the VALUES the two rules above are about -- \`0.5-map\` carries a \`file\` KEY whose VALUE is null, so a key-name walk would report neither and both rules would be vacuously green" \
  "$(node --input-type=module -e '
     const m = await import(process.argv[1]);
     const vac = [], als = [];
     for (const s of m.rowShapes()) {
       if (!s.node.file) vac.push(s.path);
       if (s.kind === "also") als.push(s.path + "=" + s.node.file);
     }
     process.stdout.write("falsy-file: " + vac.sort().join(" ") + " | also-file: " + als.sort().join(" "));
   ' "$GUARD" 2>&1)" \
  "falsy-file: 0.5-map 3-impl | also-file: 2-review.also=map.json"

# ---------------------------------------------------------------------------
suite "#61 a row with no primary \`file\` still owes its \`also\` -- on the DECISION path, not only in the report"
# ---------------------------------------------------------------------------
# WHY THIS EXISTS. \`prerequisiteSatisfied\` used to answer a vacuous primary with an early return,
# which skipped \`row.also\` entirely: an \`also\` written on a \`file: null\` row was REPORTED by
# \`satisfyingTokens\` and never enforced, and the guard granted rc 0 with the named file absent.
# That is the guard claiming more than it knows -- the same direction as the nested \`also.also\`
# the shape walk above exists to make loud, in a shape the shape walk cannot see, because \`also\`
# is a permitted key on any row and the combination is what was wrong.
#
# WHY IT NEEDS A PATCHED TABLE. No shipped row is a \`file: null\` row carrying an \`also\`, so the
# behaviour cannot be driven through the live table -- and asserting it only when some future row
# happens to need it is how a latent footgun stays latent. \`0.5-map\` is the ONLY \`file: null\` row
# and, this issue's subject being whether the map obligation is enforced at all, the likeliest
# home for a second requirement. So these cells run the REAL CLI against a COPY of the scripts
# dir carrying exactly one literal substitution, and they assert the substitution COUNT: an edit
# that no longer matches reddens here instead of silently testing the unpatched module.
ac61_patch_literal() {  # <file> <literal find> <literal replace> -> prints the substitution count
  node -e '
    const fs = require("node:fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const parts = src.split(process.argv[2]);
    fs.writeFileSync(process.argv[1], parts.join(process.argv[3]));
    process.stdout.write(String(parts.length - 1));
  ' "$1" "$2" "$3"
}
# gate() against a PATCHED COPY of the module, restoring \$GUARD so no later cell inherits it.
gate_using() {
  local saved="$GUARD"
  GUARD="$1"
  gate "$2"
  GUARD="$saved"
}

new_tmpdir || exit 90
AC61_VDIR="$NEW_TMPDIR"
cp -R "$SCRIPTS_DIR" "$AC61_VDIR/scripts"
AC61_VGUARD="$AC61_VDIR/scripts/gate-phase-entry.mjs"
AC61_VPATCHED="$(ac61_patch_literal "$AC61_VGUARD" \
  '"0.5-map": { file: null, tokens: [] },' \
  '"0.5-map": { file: null, tokens: [], also: { file: "map.json", tokens: ["0.5"] } },')"
reg61 "#61-V1"
assert_eq "#61-V1 the one-line table patch these cells rest on applied EXACTLY once -- 0 means the row was reformatted and the cells below are silently driving the SHIPPED table" \
  "$AC61_VPATCHED" "1"

# The fixture: parked at the one \`file: null\` row, nothing in events[], no map.json on disk.
new_case 4242 "$(mk61 "0.5-map" '"architectural"' '[]')"
gate "$CASE_ROOT"
reg61 "#61-V2"
assert_eq "#61-V2 CONTROL: the SHIPPED table grants this record, because its row demands nothing -- so the refusal below is the second requirement's doing and not the fixture's" \
  "$GATE_DEC/$GATE_RC" "granted/0"

gate_using "$AC61_VGUARD" "$CASE_ROOT"
reg61 "#61-V3"
assert_eq "#61-V3 with an \`also\` on that same row and its file absent, the guard REFUSES: a vacuous primary answers only for the primary half" \
  "$GATE_DEC/$GATE_RC" "refused/2"
reg61 "#61-V4"
assert_contains "#61-V4 and the refusal names the second requirement's file, which is the only file that row demands" \
  "$GATE_OUT" "map.json"

# NON-ZERO CONTROL in the other direction: the patched table is not simply refusing everything.
printf '{}' > "$CASE_DIR/map.json"
gate_using "$AC61_VGUARD" "$CASE_ROOT"
reg61 "#61-V5"
assert_eq "#61-V5 NON-ZERO CONTROL: satisfy that second requirement and the same patched table grants, so #61-V3 discriminates rather than refusing on sight" \
  "$GATE_DEC/$GATE_RC" "granted/0"

# ---------------------------------------------------------------------------
suite "#61 edge cases: the map half is a PRESENCE check, and the decision is replayable"
# ---------------------------------------------------------------------------
# PRESENCE, NOT CONTENT. Every other map.json obligation in the table is plain presence, and
# giving this one a content condition would be a second behavioural change smuggled in beside the
# re-siting. These two cells pass at the merge-base for a reason that has nothing to do with the
# map -- today the row does not read it at all -- so they are only a discrimination alongside
# #61-C1, which is what proves the file is consulted.
new_case 4242 "$(mk61 "2-review" '"architectural"' "$EV_1")"
printf '%s' "$SPEC_APPROVED" > "$CASE_DIR/spec.json"
: > "$CASE_DIR/map.json"                       # zero bytes
gate "$CASE_ROOT"
reg61 "#61-Q5"
assert_eq "#61-Q5 an EMPTY map.json still satisfies the row: presence, not content" "$GATE_DEC" "granted"

new_case 4242 "$(mk61 "2-review" '"architectural"' "$EV_1")"
printf '%s' "$SPEC_APPROVED" > "$CASE_DIR/spec.json"
printf 'not json at all {[' > "$CASE_DIR/map.json"
gate "$CASE_ROOT"
reg61 "#61-Q6"
assert_eq "#61-Q6 and so does an unparseable one -- a parse here would be a second behaviour change" \
  "$GATE_DEC" "granted"

# REPLAY. The Stop hook fires at every turn boundary, so the same record is judged over and over;
# a decision that changed on the second look would mean the guard writes state it does not declare.
new_case 4242 "$(mk61 "2-review" '"architectural"' "$EV_1")"
printf '%s' "$SPEC_APPROVED" > "$CASE_DIR/spec.json"
gate "$CASE_ROOT"; AC61_FIRST="$GATE_DEC/$GATE_RC"
gate "$CASE_ROOT"; AC61_SECOND="$GATE_DEC/$GATE_RC"
reg61 "#61-Q7"
assert_eq "#61-Q7 judging the identical record twice returns the identical decision and exit code" \
  "$AC61_SECOND" "$AC61_FIRST"
reg61 "#61-Q8"
assert_eq "#61-Q8 and that repeated decision is the refusal, so the replay cell is not two grants agreeing" \
  "$AC61_FIRST" "refused/2"

# ---------------------------------------------------------------------------
suite "#61 the label namespace: unique, and every id that exists actually RAN"
# ---------------------------------------------------------------------------
reg61 "#61-Z1"
reg61 "#61-Z2"
AC61_UNIQ="$(printf '%s' "$AC61_IDS" | grep . | sort -u)"
assert_eq "#61-Z1 no #61 assertion id is used twice (a colliding label makes the battery's grep return two unrelated sites)" \
  "$(printf '%s\n' "$AC61_IDS" | grep -c . | tr -d ' ')" "$(printf '%s\n' "$AC61_UNIQ" | grep -c . | tr -d ' ')"
assert_eq "#61-Z2 every #61 id written in this file was REGISTERED by a cell that ran" \
  "$(printf '%s\n' "$AC61_UNIQ" | grep -c . | tr -d ' ')" \
  "$(grep -o '#61-[A-Za-z0-9][A-Za-z0-9]*' "${BASH_SOURCE[0]}" | sort -u | grep -c . | tr -d ' ')"


# ===========================================================================================
# #63 -- THE BOUNDARY PAIR, ITS CONTROL, AND THE PINS UNDER THE DECLARED SURVIVOR.
#
# The preflight half of this section is at the top of the file, beside the fixture helpers,
# because the capture tripwire at the AC15 suite calls one of its functions. The PATH RULE, the
# expected-red declaration under a rewritten ceiling, the SCRIPTS_DIR non-transparency
# measurement and the two expected survivors are all stated there, once, and are not restated
# here.
#
# ONE COPY HELPER, TWO CONSUMERS. `ac63_guard_copy` below is the only way this section builds an
# off-checkout guard, and it copies the WHOLE scripts directory every time. harness.sh's
# `copy_script_with_deps` (the script plus lib.mjs) is NOT usable here and the near-miss is the
# most likely wrong turn in this section: gate-phase-entry.mjs imports ./lib.mjs,
# ./dispatch-model.mjs, ./pipeline-telemetry.mjs and ./validate-pipeline-artifact.mjs by relative
# path, and a partial copy throws ERR_MODULE_NOT_FOUND straight into the guard's own
# fail-open-on-tooling-error catch. MEASURED: that produces `<no-decision-on-stdout>` with rc 1 --
# which an rc-only assertion reads as a pass -- and, worse, probe43 folds stderr into stdout, so
# against a partial copy the VALIDATED and the UNVALIDATED probe emit BYTE-IDENTICAL stack traces
# and an `output != "ok"` exercise passes identically for both. That is why every cell below
# asserts the DECISION STRING or the EXACT SENTENCE, and never an exit code and never an
# inequality against "ok".
# ===========================================================================================

# ac63_guard_copy <label> <replacement-line> -> AC63_COPY_GUARD, AC63_COPY_MATCHES.
# The match count is REPORTED, never swallowed, because every call site asserts it is exactly 1:
# a 0 means the declaration was reformatted and the cells below are silently driving the SHIPPED
# ceiling while claiming to drive a rewritten one.
#
# IT SETS GLOBALS AND DOES NOT ECHO, for the reason new_tmpdir gives one line up in harness.sh: a
# `$(...)` capture runs in a SUBSHELL, so both the guard path AND the temp-dir REGISTRATION would
# be discarded there and the trap would never own the directory it handed out. MEASURED, on the
# first draft of this section: `X="$(ac63_guard_copy ...)"` died at the next line with
# `AC63_COPY_GUARD: unbound variable`.
ac63_guard_copy() {
  local label="$1" repl="$2"
  new_tmpdir || exit 90
  cp -R "$SCRIPTS_DIR" "$NEW_TMPDIR/scripts" || exit 90
  AC63_COPY_GUARD="$NEW_TMPDIR/scripts/gate-phase-entry.mjs"
  AC63_COPY_MATCHES="$(node -e '
    const fs = require("node:fs");
    const p = process.argv[1], repl = process.argv[2];
    const re = /^export const IN_FLIGHT_MS = .*;$/;
    let n = 0;
    const out = fs.readFileSync(p, "utf8").split("\n").map((l) => { if (re.test(l)) { n++; return repl; } return l; });
    fs.writeFileSync(p, out.join("\n"));
    if (n !== 1) process.stderr.write("ac63_guard_copy(" + process.argv[3] + "): matched " + n + " declaration line(s), expected 1\n");
    process.stdout.write(String(n));
  ' "$AC63_COPY_GUARD" "$repl" "$label")"
}

# ---------------------------------------------------------------------------
suite "#63 the boundary PAIR: both ages COMPUTED from the exported ceiling, neither spelled"
# ---------------------------------------------------------------------------
# Both cells are `3-impl` at the architectural tier with the prerequisite ABSENT and no events --
# the same shape the AC15(a)/(b) cells use -- so the only thing that differs between them is
# which side of the ceiling the record sits on.

AC63_IN_AGE=$(( IN_FLIGHT_MS - MARGIN ))
AC63_OUT_AGE=$(( IN_FLIGHT_MS + MARGIN ))

AC63_T0="$(node -e 'process.stdout.write(String(Date.now()))')"
MK_UPDATED="$(iso_ms_ago "$AC63_IN_AGE")"
new_case 4242 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"
MK_UPDATED=""
AC63_IN_ROOT="$CASE_ROOT"
gate "$CASE_ROOT"
AC63_ELAPSED=$(( $(node -e 'process.stdout.write(String(Date.now()))') - AC63_T0 ))
reg63 "#63-B1"
assert_eq "#63-B1 INSIDE the ceiling by MARGIN (updated_at = now - (IN_FLIGHT_MS - MARGIN), COMPUTED from the exported value and spelled nowhere): the guard EVALUATES the record and refuses" \
  "$GATE_DEC/$GATE_RC" "refused/2"
reg63 "#63-E1"
assert_eq "#63-E1 the wall clock from writing the INSIDE fixture to the gate returning is strictly under MARGIN. ASSERTED, not printed: that cell's EFFECTIVE age is IN_FLIGHT_MS - MARGIN + elapsed, so an unasserted margin turns a slow runner into a FLAKE instead of a failure. Measured elapsed here: ${AC63_ELAPSED}ms against a MARGIN of ${MARGIN}ms" \
  "$(if [[ "$AC63_ELAPSED" -lt "$MARGIN" ]]; then printf 'under'; else printf 'OVER'; fi)" "under"

MK_UPDATED="$(iso_ms_ago "$AC63_OUT_AGE")"
new_case 4242 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"
MK_UPDATED=""
AC63_OUT_ROOT="$CASE_ROOT"
gate "$CASE_ROOT"
reg63 "#63-B2"
assert_eq "#63-B2 OUTSIDE the ceiling by MARGIN (the IDENTICAL record body, updated_at = now - (IN_FLIGHT_MS + MARGIN)): the guard ABSTAINS -- and with #63-B1 that is the first pin either side of a boundary whose green window was measured at roughly (1.0h, 25.05h)" \
  "$GATE_DEC/$GATE_RC" "not-applicable/0"
reg63 "#63-B3"
assert_contains "#63-B3 and the abstention names the IN-FLIGHT route specifically: decideForDir reaches not-applicable by four routes before this one, and a decision-only assertion cannot say which fired" \
  "$GATE_OUT" "is not in flight"

# ---------------------------------------------------------------------------
suite "#63 the NON-ZERO CONTROL: the pair reads the ceiling rather than merely equalling itself"
# ---------------------------------------------------------------------------
# THE SHIFT IS COMPUTED, NEVER SPELLED. floor((IN_FLIGHT_MS - MARGIN) / 2) is strictly below the
# INSIDE fixture's age at EVERY base value, because floor(X/2) < X for X = IN_FLIGHT_MS - MARGIN
# > MARGIN -- which is exactly what #63-R1 asserts. So the flip below is guaranteed, not lucky.
# A control that rewrote the LITERAL instead would find ZERO occurrences of it in a rewritten
# build and would manufacture a third red cell there, falsifying the expected-red declaration in
# the preflight block for a reason that has nothing to do with the constant.

AC63_PORCELAIN_BEFORE="$(git -C "$PLUGIN_ROOT" status --porcelain 2>/dev/null)"
AC63_GUARD_SUM_BEFORE="$(cksum < "$SCRIPTS_DIR/gate-phase-entry.mjs")"

AC63_SHIFT=$(( (IN_FLIGHT_MS - MARGIN) / 2 ))
ac63_guard_copy "shifted-boundary control" "export const IN_FLIGHT_MS = $AC63_SHIFT;"
AC63_SHIFT_GUARD="$AC63_COPY_GUARD"
reg63 "#63-C1"
assert_eq "#63-C1 the shifted-boundary rewrite located EXACTLY ONE declaration line -- 0 means the declaration was reformatted and #63-C2/#63-C3 are silently driving the SHIPPED ceiling while reporting a control" \
  "$AC63_COPY_MATCHES" "1"

gate_using "$AC63_SHIFT_GUARD" "$AC63_IN_ROOT"
reg63 "#63-C2"
assert_eq "#63-C2 against a whole-scripts-dir copy whose ceiling is HALVED, the IDENTICAL INSIDE fixture FLIPS to not-applicable. Asserted on the DECISION STRING and never on rc: a partial copy fails open to <no-decision-on-stdout> with rc 1, which an rc-only assertion reads as a pass and cannot tell from a real abstention" \
  "$GATE_DEC" "not-applicable"
gate_using "$AC63_SHIFT_GUARD" "$AC63_OUT_ROOT"
reg63 "#63-C3"
assert_eq "#63-C3 and the OUTSIDE fixture HOLDS at not-applicable against that same copy, so #63-C2 is a DISCRIMINATION and not a copy that abstains on sight" \
  "$GATE_DEC" "not-applicable"

# THE CHECKOUT IS NEVER WRITTEN. Both halves are asserted, and #63-C5 is the load-bearing one.
# MEASURED, by pointing the rewrite at $SCRIPTS_DIR/gate-phase-entry.mjs in a tree where that
# file was ALREADY modified: #63-C4 SURVIVED that mutation and only #63-C5 caught it, because
# `git status --porcelain` prints the same ` M <path>` line before and after -- a file already
# recorded as modified cannot be recorded as modified twice. So the porcelain half is the coarse
# one and is blind in a dirty tree, which is the tree Dev works in; the checksum half compares
# two NON-EMPTY operands and fires either way. Do not delete #63-C5 as a duplicate of #63-C4.
#
# DELIBERATE DEVIATION, FLAGGED FOR REVIEW: the criterion says `git status --porcelain` is EMPTY.
# Asserted as written, this cell reddens for anyone with unrelated uncommitted work in the tree --
# including whoever is mid-edit on this very file -- which is a red cell about the operator's
# working tree rather than about the control. INVARIANCE is the property the criterion exists for
# ("an interrupted run cannot leave a shifted constant in the checkout") and it reddens under the
# criterion's own named mutation (point the rewrite at $SCRIPTS_DIR/gate-phase-entry.mjs).
AC63_PORCELAIN_AFTER="$(git -C "$PLUGIN_ROOT" status --porcelain 2>/dev/null)"
reg63 "#63-C4"
assert_eq "#63-C4 the controls left the checkout EXACTLY as they found it: git status --porcelain inside the plugin tree is unchanged across them, so an interrupted run cannot leave a shifted constant behind. THE COARSE HALF: it is blind when the guard is already modified, since porcelain prints the same line before and after -- #63-C5 is what bites there" \
  "$AC63_PORCELAIN_AFTER" "$AC63_PORCELAIN_BEFORE"
reg63 "#63-C5"
assert_eq "#63-C5 and the SHIPPED guard is byte-identical after those cells ran (checksum, two non-empty operands, so this is not a zero-versus-zero comparison)" \
  "$(cksum < "$SCRIPTS_DIR/gate-phase-entry.mjs")" "$AC63_GUARD_SUM_BEFORE"

# ---------------------------------------------------------------------------
suite "#63 the export itself, and the module shape the declared survivor rests on"
# ---------------------------------------------------------------------------
AC63_CHECKOUT_GUARD="$REPO_ROOT/plugins/pipeline/scripts/gate-phase-entry.mjs"
reg63 "#63-A0"
assert_eq "#63-A0 REPO_ROOT resolves and the checkout copy of the guard is readable. This cell FAILS rather than skipping: the five cells below are the only ones in #63 that read the CHECKOUT rather than whatever \$SCRIPTS_DIR points at, and a skip would retire all five in silence" \
  "$(if [[ -n "$REPO_ROOT" && -f "$AC63_CHECKOUT_GUARD" ]]; then printf 'resolved'; else printf 'UNRESOLVED: REPO_ROOT=%s' "${REPO_ROOT:-<empty>}"; fi)" "resolved"
reg63 "#63-A1"
assert_eq "#63-A1 the guard EXPORTS the ceiling exactly once, so this suite can read the number instead of re-spelling it. Read from the CHECKOUT, never \$GUARD" \
  "$(grep -c '^export const IN_FLIGHT_MS' "$AC63_CHECKOUT_GUARD" 2>/dev/null | tr -d ' ')" "1"
reg63 "#63-A2"
assert_eq "#63-A2 and the exported VALUE is unchanged by the export -- both halves are needed, since a cell asserting only the grep count would pass with the value silently moved. THIS IS THE PERMANENT VALUE PIN, not a one-shot check on the export refactor: it is the TIGHTEST bound on IN_FLIGHT_MS in this file, strictly tighter than the #63-P1/#63-P2 interval and the SOLE red when the shipped constant is rewritten to 2h, so do not delete it as redundant with #63-P2. It pins EXACT SOURCE TEXT, so this cell's failure direction is toward FALSE ALARM -- a behaviour-preserving reformat to 86_400_000 reddens it for a non-defect reason, so read the diff" \
  "$(sed -n 's/^export const IN_FLIGHT_MS = \(.*\);$/\1/p' "$AC63_CHECKOUT_GUARD" 2>/dev/null)" "24 * 60 * 60 * 1000"

# The three pins under the FIRST declared survivor. They catch the CHEAP ways its premise stops
# holding. They do NOT close the class -- see the preflight block.
reg63 "#63-D1"
assert_eq "#63-D1 Date.now() occurs exactly ONCE in the module. IF THIS FAILS: the count moved, which means EITHER a clock seam now exists OR the token was written in a comment or a string with no seam at all -- this cell's failure direction is toward FALSE ALARM, so read the diff. If it is a seam, the <=/< survivor is no longer justified and must be re-opened" \
  "$(grep -o 'Date\.now()' "$AC63_CHECKOUT_GUARD" 2>/dev/null | grep -c . | tr -d ' ')" "1"
reg63 "#63-D2"
assert_eq "#63-D2 the initializer that feeds inFlight is spelled exactly \`  const now = Date.now();\`. This is NOT redundant with #63-D1: folding an override into that single read (\`Number(process.env.GATE_NOW) || Date.now()\`) leaves the whole-file count at exactly 1 and #63-D1 GREEN, and that divergence is the entire reason this cell exists. IF THIS FAILS the survivor's justification must be re-opened" \
  "$(grep -c '^  const now = Date\.now();$' "$AC63_CHECKOUT_GUARD" 2>/dev/null | tr -d ' ')" "1"
reg63 "#63-D3"
assert_eq "#63-D3 the module exports no inFlight, asserted by DYNAMIC IMPORT and deliberately not by grep: appending \`export { inFlight };\` leaves \`grep -c '^export function inFlight'\` at 0 while the import reads \`function\`. Exporting the predicate would create a second parallel path to the same answer, which is what the survivor's justification rests on NOT existing" \
  "$(node --input-type=module -e 'const m = await import(process.argv[1]); process.stdout.write(typeof m.inFlight === "undefined" ? "absent" : "EXPORTED as " + typeof m.inFlight)' "$AC63_CHECKOUT_GUARD" 2>/dev/null)" "absent"

# ---------------------------------------------------------------------------
suite "#63 the guard's own prose: the shared-definition claim is corrected AND sited"
# ---------------------------------------------------------------------------
# (i) and (ii) are both satisfied by DELETION, which would leave no drift-risk sentence anywhere
# near the predicate and nothing citing the follow-up issue in the file. (iii) is the cell that
# closes that: it is POSITIVE and SITED, and it is RED before the change (neither token occurs
# anywhere under scripts/ or tests/ today), so it can go green only by putting the citation where
# the predicate is. The BAND IS RELATIVE to `function inFlight(`, never an absolute line range:
# an absolute range decays the first time anything above it moves.
ac63_scripts_hits() { grep -r -c -- "$1" "$REPO_ROOT/plugins/pipeline/scripts/" 2>/dev/null | awk -F: '{ s += $NF } END { print s + 0 }'; }
reg63 "#63-H1"
assert_eq "#63-H1 the guard no longer claims it is \"reusing\" pipeline-status.mjs's window: there is no shared symbol and both modules hold their own literal, so the header claim was flatly false (non-zero control: exactly 1 hit before the change)" \
  "$(ac63_scripts_hits 'reusing pipeline-status')" "0"
reg63 "#63-H2"
assert_eq "#63-H2 and inFlight's own doc comment no longer claims the predicate is the one pipeline-status.mjs \"already uses\" -- TRUE today and silently FALSE the moment either literal moves, which is the exact drift risk being named (non-zero control: exactly 1 hit before the change)" \
  "$(ac63_scripts_hits 'already uses to call a run')" "0"
reg63 "#63-H3"
assert_eq "#63-H3 a #74 citation is SITED in the 20 lines above \`function inFlight(\`, where the duplication actually is. Without this, deleting the false clause outright passes #63-H1 and #63-H2 while leaving the drift risk unstated and unciteable anywhere in the file. A citation in the FILE HEADER alone does NOT satisfy this" \
  "$(node -e '
    const fs = require("node:fs");
    const src = fs.readFileSync(process.argv[1], "utf8").split("\n");
    const i = src.findIndex((l) => /^function inFlight\(/.test(l));
    if (i < 0) { process.stdout.write("NO `function inFlight(` LINE FOUND: re-anchor this cell, do not delete it"); process.exit(0); }
    const band = src.slice(Math.max(0, i - 20), i);
    process.stdout.write(band.some((l) => l.indexOf("#74") !== -1) ? "sited" : "NOT SITED: no #74 in lines " + Math.max(1, i - 19) + "-" + i);
  ' "$AC63_CHECKOUT_GUARD" 2>/dev/null)" "sited"

# ---------------------------------------------------------------------------
suite "#63 this suite stops re-deriving the ceiling, in code AND in the prose beside it"
# ---------------------------------------------------------------------------
# THE PATTERNS ARE ASSEMBLED SO THEY CANNOT MATCH THEIR OWN CELL. This file is inside the
# population these two greps walk, and a self-matching detector is un-passable for a reason that
# has nothing to do with the subject -- the trap this repo has hit twice. The character class in
# the first pattern and the split literal in the second are what keep these lines out of their
# own results; verify with the mutations below rather than by eye.
AC63_VALUE_PHRASE="24h ""ceiling"
reg63 "#63-G1"
assert_eq "#63-G1 no cell in this suite re-derives the ceiling as its own hardcoded arithmetic: both former sites (the capture tripwire and probe43's staleness diagnosis) now READ the exported constant. MUTATE THE TWO SITES SEPARATELY -- restoring one and restoring both are indistinguishable to a zero-hit grep, and that hides a dead site" \
  "$(grep -c '24 *[*] *3600e3' "${BASH_SOURCE[0]}" | tr -d ' ')" "0"
reg63 "#63-G2"
assert_eq "#63-G2 and no prose in this suite still spells that ceiling's VALUE (\"$AC63_VALUE_PHRASE\"): a message asserting 24h while comparing against a constant that may not be 24h is the same false claim in prose that this issue corrects in the guard's header. SCOPED TO THE PHRASE, not to the bare number, deliberately: a zero-hit rule over \"24h\" alone would collide with the frozen assertion label at the capture tripwire" \
  "$(grep -c "$AC63_VALUE_PHRASE" "${BASH_SOURCE[0]}" | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
suite "#63 the substituted reads are VALIDATED, the validation is EXERCISED, the branch is LIVE"
# ---------------------------------------------------------------------------
# ~345 assertions in this file rest on probe43's qualification and its failure mode is SILENCE, so
# a read that arrives as `undefined` must be named rather than compared against: `age > undefined`
# is FALSE, and the probe would answer `ok` about a fixture it never judged.

ac63_guard_copy "no-export driver" "const IN_FLIGHT_MS = $IN_FLIGHT_MS;"
AC63_NOEXP_GUARD="$AC63_COPY_GUARD"
reg63 "#63-V1"
assert_eq "#63-V1 the no-export rewrite located EXACTLY ONE declaration line. The replacement is the SAME declaration with the \`export\` keyword stripped and the value carried across from the read, so ENTRY/EXIT still export and the module still imports cleanly -- only the ceiling becomes unreadable" \
  "$AC63_COPY_MATCHES" "1"

new_case 4242 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"
AC63_PROBE_FIXTURE="$CASE_DIR/status.json"
reg63 "#63-V2"
assert_eq "#63-V2 CONTROL: against the SHIPPED guard this same fixture qualifies cleanly, so #63-V3 is the VALIDATION firing and not the fixture being wrong" \
  "$(probe43 "$AC63_PROBE_FIXTURE" fresh exact:architectural)" "ok"
reg63 "#63-V3"
assert_eq "#63-V3 driven against a WHOLE-scripts-dir copy with the export stripped, probe43 NAMES the unreadable ceiling instead of answering ok. Asserted as an EXACT SENTENCE and never as \`!= ok\`: probe43 folds stderr into stdout, so against a partial copy a module-resolution stack trace satisfies \`!= ok\` IDENTICALLY for the probe that validates and the probe that does not -- the rubber stamp reappearing inside the cell written to abolish one" \
  "$(GUARD="$AC63_NOEXP_GUARD" probe43 "$AC63_PROBE_FIXTURE" fresh exact:architectural)" \
  "the exported IN_FLIGHT_MS did not read as a finite positive number"

reg63 "#63-V4"
assert_eq "#63-V4 the capture tripwire's OWN validation, exercised in ITS environment -- a shell variable, not a module read -- by driving THE SAME function that tripwire calls with the ceiling argument EMPTY. Number(\"\") === 0, so an empty argument is caught by the \`CEIL <= 0\` half and NOT by isFinite: both halves are required, and the argument must be QUOTED or an empty one vanishes and shifts argv" \
  "$(ac63_capture_staleness "$REC_STC" "")" \
  "the exported IN_FLIGHT_MS did not read as a finite positive number"

MK_UPDATED="$(iso_ms_ago "$AC63_OUT_AGE")"
new_case 4242 "$(mk_status "3-impl" '"architectural"' "$NO_EVENTS")"
MK_UPDATED=""
reg63 "#63-V5"
assert_eq "#63-V5 probe43's staleness branch is LIVE: a fixture past the ceiling by MARGIN produces exactly that diagnosis. Before this cell the branch was DEAD -- every fixture in this file sat INSIDE the ceiling, all three call sites assert == ok, and both flipping the comparison and DELETING the whole staleness push left the suite at 462/0. This buys LIVENESS, not falsifiability: the > versus >= distinction is the second declared survivor and stays unpinned" \
  "$(probe43 "$CASE_DIR/status.json" fresh exact:architectural)" \
  "updated_at is past the in-flight ceiling this suite reads from the guard: this cell would test staleness"

# THE LAST WRITE-CAPABLE COPY CALL IS ABOVE (#63-V1's no-export driver). #63-C4 and #63-C5 sit
# after the FIRST copy call only, so neither can see a write performed after they ran, and the
# LAST call is the one whose residue an interrupted run actually leaves behind: under the copy
# helper's own named mutation (repoint AC63_COPY_GUARD at $SCRIPTS_DIR) the run ends with the
# shipped guard reading `const IN_FLIGHT_MS = 86400000;` -- this PR's only executable change,
# reverted AND the literal respelled, sitting in the checkout waiting for a `git commit -a`.
# Do not delete this as a duplicate of #63-C5; a checksum taken earlier proves nothing about a
# later write. Failure direction is toward a REAL defect, not false alarm: if this reddens, the
# checkout has been written by this file and the diff must be inspected before anything is
# committed.
reg63 "#63-C6"
assert_eq "#63-C6 the SHIPPED guard is STILL byte-identical after the LAST copy-driven cell in this file (checksum, two non-empty operands, so this is not a zero-versus-zero comparison). #63-C5 covers only the copies above it" \
  "$(cksum < "$SCRIPTS_DIR/gate-phase-entry.mjs")" "$AC63_GUARD_SUM_BEFORE"

# ---------------------------------------------------------------------------
suite "#63 the label namespace: unique, and every id that exists actually RAN"
# ---------------------------------------------------------------------------
reg63 "#63-Z1"
reg63 "#63-Z2"
AC63_UNIQ="$(printf '%s' "$AC63_IDS" | grep . | sort -u)"
assert_eq "#63-Z1 no #63 assertion id is used twice (a colliding label makes the battery's grep return two unrelated sites)" \
  "$(printf '%s\n' "$AC63_IDS" | grep -c . | tr -d ' ')" "$(printf '%s\n' "$AC63_UNIQ" | grep -c . | tr -d ' ')"
assert_eq "#63-Z2 every #63 id written in this file was REGISTERED by a cell that ran" \
  "$(printf '%s\n' "$AC63_UNIQ" | grep -c . | tr -d ' ')" \
  "$(grep -o '#63-[A-Za-z0-9][A-Za-z0-9]*' "${BASH_SOURCE[0]}" | sort -u | grep -c . | tr -d ' ')"

# ===========================================================================================
# #53 -- THE JUDGEMENT CLAUSE FOR `0-setup` MUST DISCRIMINATE FROM AN UNRECOGNISED PHASE
#
# THE DEFECT. `0-setup` is the run's first recorded phase and a real occupied one, but it sits
# in no cell of this guard's partition, so it falls through to the fail-open branch for a phase
# the table does not know. Its decision reason therefore carries a judgement clause BYTE-
# IDENTICAL to the one produced for an invented phase: the run's setup step is judged as if it
# were a typo.
#
# THE CLAUSE, NOT THE REASON STRING, AND THAT DISTINCTION IS WHAT MAKES THIS FALSIFIABLE. The
# guard interpolates the record's OWN directory and phase into a leading
# `.pipeline/<dir> at `<phase>`` span, so the two FULL reason strings ALREADY differ at HEAD and
# an assertion over them is green with the defect live. Everything below strips that
# record-derived span first and compares what remains.
#
# THE STRIP IS AN ANCHORED PATTERN, NEVER A FIXED-LENGTH CUT. Measured at HEAD: the two records'
# interpolated spans have DIFFERENT byte lengths, so a `cut -c N-` makes the two clauses differ
# trivially, ships green with the defect live, and reproduces the original defect at new
# coordinates. #53-A7 asserts that length difference rather than leaving it as a claim.
#
# EXPECTED STATE OF THIS SECTION BEFORE THE FIX: #53-A4 is the RED one, and it is red because
# both clauses are the same 31 bytes. Every other cell here is green at HEAD, by design -- they
# are the premises and the controls that make #53-A4's red mean what it says.
# ===========================================================================================

AC53_IDS=""
reg53() { AC53_IDS="$AC53_IDS$1
"; }

# ac53_probe <phase> [updated_at-iso] [extra-top-level-json-with-leading-comma]
#   -> "<rc>|<decision>|<clause>|<clause-bytes>|<prefix-bytes>"
# The clause and BOTH byte counts are taken off the guard's LIVE stdout, never off this file's
# own prose: a spec's text is not the running guard, and the only number worth asserting is the
# one the process produced.
ac53_probe() {
  new_tmpdir || exit 90
  local root="$NEW_TMPDIR" out rc
  mkdir -p "$root/.pipeline/999"
  printf '{"issue_number":999,"current_phase":"%s","updated_at":"%s","events":[]%s}' \
    "$1" "${2:-$FRESH_ISO}" "${3:-}" > "$root/.pipeline/999/status.json"
  out="$(node "$GUARD" --root "$root" 2>/dev/null)"; rc=$?
  printf '%s' "$out" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let j;
      try { j = JSON.parse(s); } catch { process.stdout.write(process.argv[1] + "|<unparseable-stdout>|<none>|-1|-1"); return; }
      const reason = String(j.reason == null ? "" : j.reason);
      const m = /^\.pipeline\/[^ ]+ at `[^`]*`/.exec(reason);
      const clause = m ? reason.slice(m[0].length) : "<NO-RECORD-DERIVED-PREFIX>";
      process.stdout.write([
        process.argv[1], String(j.decision), clause,
        String(Buffer.byteLength(clause, "utf8")),
        String(m ? Buffer.byteLength(m[0], "utf8") : -1),
      ].join("|"));
    });
  ' "$rc"
}
ac53_f() { printf '%s' "$1" | cut -d'|' -f"$2"; }

AC53_SETUP="$(ac53_probe "0-setup")"
AC53_GHOST="$(ac53_probe "9-invented")"
AC53_HALT="$(ac53_probe "1-ba-open-questions")"
AC53_TERM="$(ac53_probe "5-archived")"

# ---------------------------------------------------------------------------
suite "#53 AC7 premises: the record-derived span is real, and the strip removes exactly it"
# ---------------------------------------------------------------------------
reg53 "#53-A1"
assert_eq "#53-A1 the reason for a record at \`0-setup\` carries the record-derived \`.pipeline/<dir> at \\\`<phase>\\\`\` span, and the anchored strip matches it. Without this premise a failed strip would return the WHOLE reason and #53-A4 would compare two strings that trivially differ" \
  "$([[ "$(ac53_f "$AC53_SETUP" 5)" -gt 0 ]] && echo stripped || echo "NO PREFIX MATCHED: $(ac53_f "$AC53_SETUP" 3)")" "stripped"
reg53 "#53-A2"
assert_eq "#53-A2 and so does the reason for a record at \`9-invented\`" \
  "$([[ "$(ac53_f "$AC53_GHOST" 5)" -gt 0 ]] && echo stripped || echo "NO PREFIX MATCHED: $(ac53_f "$AC53_GHOST" 3)")" "stripped"
reg53 "#53-A7"
assert_eq "#53-A7 THE STRIP CANNOT BE A FIXED-LENGTH CUT: the two records' interpolated spans have DIFFERENT byte lengths, so any \`cut -c N-\` makes the two clauses differ at HEAD and ships GREEN with the defect live. This cell is why the strip is an anchored pattern" \
  "$([[ "$(ac53_f "$AC53_SETUP" 5)" != "$(ac53_f "$AC53_GHOST" 5)" ]] && echo differ || echo "EQUAL LENGTHS: a fixed cut would be indistinguishable here")" "differ"

# ---------------------------------------------------------------------------
suite "#53 AC7: the clause for \`0-setup\` DIFFERS from the clause for an invented phase"
# ---------------------------------------------------------------------------
reg53 "#53-A3"
assert_eq "#53-A3 PAIRED NEGATIVE, an EXACT equality taken off LIVE stdout: an unrecognised phase's remaining clause is still exactly the fail-open sentence, 31 bytes. This is what makes #53-A4 a discrimination rather than a claim that something changed" \
  "$(ac53_f "$AC53_GHOST" 3)/$(ac53_f "$AC53_GHOST" 4)" ", which is not a guarded phase./31"
reg53 "#53-A4"
assert_eq "#53-A4 THE CRITERION: with the record-derived span stripped, the judgement clause for \`0-setup\` is NOT the clause for an invented phase. RED before the fix, where both are the identical 31-byte fail-open sentence and the run's own setup step is judged as if it were a typo" \
  "$([[ "$(ac53_f "$AC53_SETUP" 3)" != "$(ac53_f "$AC53_GHOST" 3)" ]] && echo discriminates || echo "IDENTICAL CLAUSES ($(ac53_f "$AC53_SETUP" 4) bytes each): $(ac53_f "$AC53_SETUP" 3)")" \
  "discriminates"
reg53 "#53-A5"
assert_eq "#53-A5 and this change is BEHAVIOUR-NEUTRAL at runtime: both records still decide \`not-applicable\` and still exit 0. Only the declaration and the clause move" \
  "$(ac53_f "$AC53_SETUP" 1)/$(ac53_f "$AC53_SETUP" 2)/$(ac53_f "$AC53_GHOST" 1)/$(ac53_f "$AC53_GHOST" 2)" \
  "0/not-applicable/0/not-applicable"
reg53 "#53-A6"
assert_eq "#53-A6 LIVE POSITIVE CONTROLS that a clause CAN differ under this instrument, so #53-A4's red is about the subject and not about the strip: an UNGUARDED phase's clause is 51 bytes and a TERMINAL one's is 13, both taken off live stdout and both distinct from the 31" \
  "$(ac53_f "$AC53_HALT" 4)/$(ac53_f "$AC53_TERM" 4)" "51/13"

# ---------------------------------------------------------------------------
suite "#53 R4(b): the new cell's branch sits AFTER the terminal check"
# ---------------------------------------------------------------------------
# A PRESERVATION PIN. Green at HEAD and green after a correct fix; its bite is proved by
# mutation, not by colour. MEASURED both ways: with the new branch placed AFTER the terminal
# check a `0-setup` record carrying `completed_at` still renders ` is finished.`; with the same
# branch moved BEFORE it, the identical record renders the setup-step clause -- a terminal
# record judged non-terminal. That is the concrete regression this cell exists to refuse.
AC53_TERM_SETUP="$(ac53_probe "0-setup" "$FRESH_ISO" ",\"completed_at\":\"$FRESH_ISO\"")"
reg53 "#53-P1"
assert_eq "#53-P1 a record at \`0-setup\` carrying \`completed_at\` is judged FINISHED, not judged as a setup step: the terminal check runs first, and a new partition branch placed before it would silently un-finish every concluded run that ended at this phase" \
  "$(ac53_f "$AC53_TERM_SETUP" 3)" " is finished."

# ---------------------------------------------------------------------------
suite "#53 AC7's non-zero control: dated from the ceiling the guard exports, not from a literal"
# ---------------------------------------------------------------------------
# A LITERAL ISO TIMESTAMP STOPS BEING A CONTROL, SILENTLY, ON A 24-HOUR TIMER. Measured against
# this guard: the same `3-impl` architectural record with no design.json gives rc 2 `refused` at
# now-23h and rc 0 `not-applicable` at now-25h and at any fixed past date. And `Date.parse`
# splits on MAGNITUDE rather than on numeric-ness -- `"12345"` parses to the YEAR 12345, finite
# and FUTURE-dated, so such a fixture reads as permanently in flight and fires the control for
# the wrong reason, surviving any staleness mutation aimed at it. The date below is therefore
# derived AT RUN TIME from the ceiling the guard itself exports, and the age is asserted INSIDE
# that ceiling BEFORE the rc-2 outcome is read as evidence.
AC53_CTRL_ISO="$(iso_ms_ago $(( IN_FLIGHT_MS / 2 )))"
reg53 "#53-N1"
assert_eq "#53-N1 PREMISE, asserted before the outcome is read as evidence: the control fixture's age is INSIDE the ceiling read out of the guard. An out-of-window fixture fails by name here instead of abstaining with rc 0 and looking like a pass" \
  "$(ac63_age_vs_ceiling "$AC53_CTRL_ISO" "$IN_FLIGHT_MS")" "inside"
AC53_CTRL="$(ac53_probe "3-impl" "$AC53_CTRL_ISO" ",\"risk_tier\":\"architectural\"")"
reg53 "#53-N2"
assert_eq "#53-N2 NON-ZERO CONTROL: the same probe over a record whose prerequisite is genuinely missing exits 2 and decides \`refused\`, so every \`not-applicable\`/exit-0 cell above is the guard abstaining on purpose and not the probe failing to reach it" \
  "$(ac53_f "$AC53_CTRL" 1)/$(ac53_f "$AC53_CTRL" 2)" "2/refused"

# ---------------------------------------------------------------------------
suite "#53 the label namespace: unique, and every id that exists actually RAN"
# ---------------------------------------------------------------------------
reg53 "#53-Z1"
reg53 "#53-Z2"
AC53_UNIQ="$(printf '%s' "$AC53_IDS" | grep . | sort -u)"
assert_eq "#53-Z1 no #53 assertion id is used twice (a colliding label makes a mutation battery's grep return two unrelated sites)" \
  "$(printf '%s\n' "$AC53_IDS" | grep -c . | tr -d ' ')" "$(printf '%s\n' "$AC53_UNIQ" | grep -c . | tr -d ' ')"
assert_eq "#53-Z2 every #53 id written in this file was REGISTERED by a cell that ran" \
  "$(printf '%s\n' "$AC53_UNIQ" | grep -c . | tr -d ' ')" \
  "$(grep -o '#53-[A-Za-z0-9][A-Za-z0-9]*' "${BASH_SOURCE[0]}" | sort -u | grep -c . | tr -d ' ')"

finish