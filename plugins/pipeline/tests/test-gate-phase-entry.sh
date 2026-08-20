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
STALE_ISO="$(iso_hours_ago 25)"    # past R6's 24h ceiling

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

r3_row() {  # r3_row <phase> <tier> <file> <failing-body> <satisfying-body> <event-json> <lack> <repair>
  local phase="$1" tier="$2" file="$3" bad="$4" good="$5" ev="$6" lack="$7" repair="$8" r1

  # 1. THE MISSING LEG: present-and-failing, WITH an event that would satisfy the row on its own.
  new_case 4242 "$(mk_status "$phase" "\"$tier\"" "$ev")"
  printf '%s' "$bad" > "$CASE_DIR/$file"
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
  gate "$CASE_ROOT"
  assert_eq "  CONTROL: the same fixture with a SATISFYING $file is granted" "$GATE_DEC" "granted"

  # 3. The event alone, artifact absent: path (b) is weaker on purpose, and this is the cell that
  #    proves the event is live. If this ever refuses, cell 1 stops being about priority at all.
  new_case 4242 "$(mk_status "$phase" "\"$tier\"" "$ev")"
  gate "$CASE_ROOT"
  assert_eq "  CONTROL: with no $file at all, that same event GRANTS (path (b) attests dispatch)" \
    "$GATE_DEC" "granted"

  # 4. Present-and-failing with NO events: the original cell, kept as a cell of the matrix.
  new_case 4242 "$(mk_status "$phase" "\"$tier\"" "$NO_EVENTS")"
  printf '%s' "$bad" > "$CASE_DIR/$file"
  gate "$CASE_ROOT"
  assert_eq "  and a failing $file with no events at all is refused too" "$GATE_DEC" "refused"
}

BA_EVENT='[{"phase":"1-ba","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'
P2_EVENT='[{"phase":"2-constraints","verdict":"complete","at":"2026-01-01T00:00:00Z"}]'

r3_row 2-review      architectural spec.json '{"issue_number":4242}' "$SPEC_APPROVED" "$BA_EVENT" \
  'carries no `ba_approved_at`' 'set `ba_approved_at` in .pipeline/4242/spec.json'
r3_row 2-constraints standard      spec.json '{"issue_number":4242}' "$SPEC_APPROVED" "$BA_EVENT" \
  'carries no `ba_approved_at`' 'set `ba_approved_at` in .pipeline/4242/spec.json'
r3_row 3-impl standard constraints.md '' '# real content' "$P2_EVENT" \
  'it is empty' 'into .pipeline/4242/constraints.md'

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
assert_contains "the refusal offers the abandoned-run route" "$GATE_ERR" "If this run is over"
assert_contains "  naming final_verdict" "$GATE_ERR" "final_verdict"
assert_contains "  and completed_at" "$GATE_ERR" "completed_at"
assert_contains "  and 5-archived" "$GATE_ERR" "5-archived"

# The stated consequence, asserted rather than left as prose: on a fresh checkout the SAME run
# is granted through path (b), because an event attests DISPATCH and not APPROVAL. This is the
# weakness R3 names and declines to defend against; a test that pins it is what stops it being
# quietly "fixed" into a rejecting-verdict blocklist over free text. A REJECTING verdict is used
# here on purpose: cell 3 above already covers the ordinary case.
new_case 4242 "$(mk_status "2-review" '"architectural"' \
  '[{"phase":"1-ba","verdict":"REWORK_REQUIRED","at":"2026-01-01T00:00:00Z"}]')"
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
# The live case, not a hypothetical: status.schema.json:13's own description blesses
# 3-scope-drift-adjudication, and pipeline.md never writes it. Under deny-by-default that
# record would refuse every stop in the project that holds it.
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
  "$(node -e 'const s=require(process.argv[1]);process.stdout.write((Date.now()-new Date(s.updated_at).getTime())>24*3600e3?"stale":"REFRESHED")' "$REC_STC")" \
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

two_dirs 202601010103 202601010103        # the measured tie: three records in this tree share one mtime
gate_nosignal "$CASE_ROOT"; FIRST_DEC="$GATE_DEC"; FIRST_DIR="$GATE_ISSUE"
gate_nosignal "$CASE_ROOT"
assert_eq "(c) an mtime tie is DETERMINISTIC across runs (decision)" "$GATE_DEC" "$FIRST_DEC"
assert_eq "  and deterministic in the dir it names" "$GATE_ISSUE" "$FIRST_DIR"
assert_eq "  and it names one of the two dirs rather than nothing" \
  "$([[ "$FIRST_DIR" == "5150" || "$FIRST_DIR" == "6160" ]] && echo named || echo "UNNAMED: $FIRST_DIR")" "named"

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
# Prose alone is provably insufficient: status.schema.json:13 blesses two phases pipeline.md
# never writes, which is live evidence that a vocabulary in this repo has ALREADY rotted in the
# one file a prose-derived test does not read.
CORPUS="$(git -C "$REPO_ROOT" ls-files '.pipeline/*/status.json' 2>/dev/null)"
CORPUS_N="$(printf '%s\n' "$CORPUS" | grep -c . | tr -d ' ')"
assert_eq "VACUITY CONTROL: the corpus walk found at least 4 committed records" \
  "$([[ "${CORPUS_N:-0}" -ge 4 ]] && echo enough || echo "ONLY $CORPUS_N")" "enough"

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
AC19_STRAYS="$(ac19_field strays)"
AC19_UNREAD="$(ac19_field unreadable)"
assert_eq "every committed record's current_phase is a member of one of the four sets" \
  "$AC19_STRAYS" ""
assert_eq "and the walk ACCOUNTS for every record rather than continuing past it" \
  "$AC19_UNREAD" ""

# ---------------------------------------------------------------------------
suite "AC24: no committed record is REFUSED (a zero, whose non-zero control is AC1's 14)"
# ---------------------------------------------------------------------------
# Each record is evaluated in its OWN temp project with its dir name preserved and updated_at
# rewritten to test time, so R6's staleness cannot mask the table. Artifacts are NOT copied:
# only status.json is tracked, so this is the fresh-checkout case the two-source rule exists for.
AC24_REFUSED=""
AC24_EVALUATED=0
while IFS= read -r rec; do
  [[ -n "$rec" ]] || continue
  name="$(basename "$(dirname "$rec")")"
  new_case "$name" '{}'
  if ! capture "$REPO_ROOT/$rec" "$CASE_DIR/status.json" "{\"updated_at\":\"$FRESH_ISO\"}" 2>/dev/null; then
    AC24_REFUSED="$AC24_REFUSED $name(UNREADABLE)"      # accounted for, never skipped
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
assert_eq "VACUITY CONTROL: at least 4 committed records were actually evaluated" \
  "$([[ "$AC24_EVALUATED" -ge 4 ]] && echo enough || echo "ONLY $AC24_EVALUATED")" "enough"
assert_eq "no committed record is refused by the table" "${AC24_REFUSED# }" ""

finish
