#!/usr/bin/env bash
# status.schema.json's own contract: the verdict cap (#34) and the current_phase example
# list (#42).
#
# WHY THIS FILE EXISTS. status.schema.json has exactly ONE runtime reader -- voice-lint.mjs:247 (the
# readFileSync in phaseShapeFailure), which reads properties.current_phase.pattern at :249 and
# nothing else. The file appears in no
# AGENT_RULES entry in validate-pipeline-artifact.mjs, and that walker does not implement
# maxLength at all, so a maxLength written into this schema refuses nothing by itself. Both
# defects this suite pins are the same condition: a constraint nobody reads can be absent
# (#34's unbounded verdict) or wrong (#42's rotted phase list) indefinitely with nothing going
# red. So the reader is HERE. The population is the committed corpus, because that is the
# population #34 cares about -- status.json is committed AND archived verbatim into the
# knowledge store, so whatever lands in it lands in a public tree at full length.
#
# THE CAP IS READ FROM THE SCHEMA, NEVER COPIED. TWO sites below hold the literal 32 -- one pin
# per capped field, because AC1 requires each field pinned SEPARATELY -- and both pin the value
# the spec ruled (q2). Every assertion OVER THE CORPUS uses the value read out of the schema, so
# changing the schema alone moves this suite's verdict. A test carrying its own copy of 32 would
# stay green while the schema drifted away underneath it.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
SCHEMA="$PLUGIN_DIR/schemas/status.schema.json"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"
GUARD="$SCRIPTS_DIR/gate-phase-entry.mjs"
VALIDATOR="$SCRIPTS_DIR/validate-pipeline-artifact.mjs"
VOICE_LINT="$SCRIPTS_DIR/voice-lint.mjs"
TESTS_DIR="$PLUGIN_DIR/tests"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"

# The corpus build is NOT reimplemented here. test-pipeline-telemetry.sh owns the one
# marker-delimited helper (#30 D1) and test-corpus-union.sh drives it; a second build would be a
# second population that can silently disagree with the first. The UNION matters for the same
# reason it mattered there: a tracked-only walk cannot see an untracked in-flight record, and
# the union can only ever WIDEN the population, never narrow it.
BEGIN_MARK='# --- BEGIN corpus helper (issue #30 D1) ---'
END_MARK='# --- END corpus helper ---'
HELPER_SRC="$TEMP_PROJECT/corpus-helper.sh"
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0,b){inblk=1;next} index($0,e){inblk=0} inblk{print}' \
  "$TESTS_DIR/test-pipeline-telemetry.sh" > "$HELPER_SRC"
if [[ -s "$HELPER_SRC" ]]; then
  # shellcheck disable=SC1090
  . "$HELPER_SRC"
fi

# ---------------------------------------------------------------------------
# The walker. Parameterised by CAP and by the file list, so the same code runs against the live
# corpus and against crafted temp trees -- the cells are the only way to watch each conjunct
# fail, and a conjunct nobody has watched fail is a claim.
# ---------------------------------------------------------------------------
WALKER="$TEMP_PROJECT/verdict-walk.cjs"
cat > "$WALKER" <<'NODE'
const fs = require("fs");
const cap = Number(process.argv[2]);
const files = process.argv.slice(3);
if (!Number.isInteger(cap) || cap <= 0) {
  process.stdout.write("caperror=" + JSON.stringify(process.argv[2]) + "\n");
  process.exit(3);
}
const out = {
  files: files.length, read: 0, verdicts: 0, longest: 0, longestvalue: "",
  unreadable: [], badevents: [], badflags: [], violations: [],
};
for (const f of files) {
  let s;
  try { s = JSON.parse(fs.readFileSync(f, "utf8")); }
  catch (e) {
    // ACCOUNTED FOR, not skipped: `read` is asserted against the shell's own count, so a walk
    // that continued past what it could not read cannot report a zero it did not earn.
    out.unreadable.push(f + " (" + String(e.message).slice(0, 40) + ")");
    continue;
  }
  out.read++;
  if (!Array.isArray(s.events)) {
    out.badevents.push(f + " (events is " + (s.events === undefined ? "absent" : typeof s.events) + ")");
  }
  if (s.flags !== undefined && !Array.isArray(s.flags)) {
    out.badflags.push(f + " (flags is " + typeof s.flags + ")");
  }
  for (const field of ["events", "flags"]) {
    const arr = s[field];
    if (!Array.isArray(arr)) continue;
    arr.forEach((entry, i) => {
      const v = entry && entry.verdict;
      // An ABSENT verdict is schema-valid and stays valid: the cap must not become a
      // requirement. test-gate-phase-entry.sh:287 pins one live record whose event carries no
      // verdict key at all, and a walk that counted absence as a violation would refuse it.
      if (typeof v !== "string") return;
      out.verdicts++;
      if (v.length > out.longest) { out.longest = v.length; out.longestvalue = v; }
      if (v.length > cap) {
        out.violations.push(f + " " + field + "[" + i + "].verdict=" + JSON.stringify(v) +
          " len=" + v.length + " cap=" + cap);
      }
    });
  }
}
const flat = (v) => (Array.isArray(v) ? v.join(" ;; ") : String(v)).replace(/[\r\n]+/g, " ");
let text = "";
for (const k of ["files", "read", "verdicts", "longest", "longestvalue",
                 "unreadable", "badevents", "badflags", "violations"]) {
  text += k + "=" + flat(out[k]) + "\n";
}
process.stdout.write(text);
NODE

# verdict_report <root> <cap> -> KEY=VALUE lines
verdict_report() {
  local root="$1" cap="$2" files
  files="$(corpus_files "$root" '.pipeline/*/status.json')"
  # Word splitting on $files is deliberate: it is a newline-separated path list.
  # shellcheck disable=SC2086
  ( cd "$root" 2>/dev/null && node "$WALKER" "$cap" $files ) 2>/dev/null
}

# rfield <report> <key> -> the value, or a SENTINEL.
# The sentinel goes on the REPORT and on the missing KEY, never on the value: every list this
# suite asserts is asserted EMPTY, and empty is the passing state, so a `${x:-fallback}` on the
# value would make those assertions unsatisfiable in the direction they assert. This is the
# ac19_field discipline from test-gate-phase-entry.sh, and it is controlled below on this
# function rather than assumed.
rfield() {
  local rep="$1" key="$2"
  [[ -n "$rep" ]] || { printf '<no-report>'; return; }
  printf '%s\n' "$rep" | grep -q "^$key=" || { printf '<no-field:%s>' "$key"; return; }
  printf '%s\n' "$rep" | sed -n "s/^$key=//p"
}

# ---------------------------------------------------------------------------
suite "the walker's own reporting (controls on the instrument, before any measurement)"
# ---------------------------------------------------------------------------
assert_eq "the corpus helper was extracted and is callable" \
  "$(declare -f corpus_files >/dev/null 2>&1 && echo yes || echo no)" "yes"
assert_eq "CONTROL: an absent report reads as <no-report>, never as an empty list" \
  "$(rfield '' violations)" "<no-report>"
assert_eq "CONTROL: a present report missing the key reads as <no-field:violations>" \
  "$(rfield 'files=6
read=6' violations)" "<no-field:violations>"
assert_eq "CONTROL: and a present key with an empty list still reads as empty" \
  "$(rfield 'violations=
read=6' violations)" ""

# ---------------------------------------------------------------------------
suite "AC1: both verdict fields carry the cap, and each is pinned SEPARATELY"
# ---------------------------------------------------------------------------
# Separately, because "the schema contains maxLength" is satisfied by the events[] copy alone
# and never notices that flags[] is bare -- which is the exact hole #34 shipped, since #34 names
# only events[] while flags[] eight lines below carries the LONGER value.
SCHEMA_FACTS="$(node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const p = (x) => (x === undefined ? "<absent>" : String(x));
  const ev = ((s.properties.events.items || {}).properties || {}).verdict || {};
  const fl = ((s.properties.flags.items || {}).properties || {}).verdict || {};
  const sum = ((s.properties.flags.items || {}).properties || {}).summary || {};
  const desc = s.properties.current_phase.description || "";
  const m = /^Examples:\s*([^]*?)\.\s/.exec(desc);
  const list = m ? m[1].split(/\s*,\s*/).map((t) => t.trim()).filter(Boolean) : [];
  process.stdout.write(
    "events_cap=" + p(ev.maxLength) + "\n" +
    "events_type=" + p(ev.type) + "\n" +
    "events_desc=" + p(ev.description).replace(/[\r\n]+/g, " ") + "\n" +
    "flags_cap=" + p(fl.maxLength) + "\n" +
    "flags_type=" + p(fl.type) + "\n" +
    "flags_desc=" + p(fl.description).replace(/[\r\n]+/g, " ") + "\n" +
    "summary_cap=" + p(sum.maxLength) + "\n" +
    "pattern=" + p(s.properties.current_phase.pattern) + "\n" +
    "phaselist=" + list.join(" ") + "\n" +
    "phasecount=" + list.length + "\n",
  );
' "$SCHEMA" 2>/dev/null)"
assert_eq "status.schema.json parses as JSON at all" \
  "$([[ -n "$SCHEMA_FACTS" ]] && echo parsed || echo "UNPARSEABLE or unreadable: $SCHEMA")" "parsed"

# THE TWO SITES THAT HOLD THE LITERAL, one pin per capped field. Two, not one, because AC1's
# whole point is that "the schema contains maxLength" is satisfied by the events[] copy while
# flags[] sits bare; a single shared pin cannot tell those apart. Both pin the ruled value (spec
# q2: 32 = the 18-char longest DECLARED verdict plus headroom for a longer token, below the
# length of the prose sentence the bound refuses). Every corpus assertion below reads the schema
# instead, so a cap change moves this suite's verdict through the corpus, not through the pins.
assert_eq "AC1: events[].verdict is capped at the ruled 32" "$(rfield "$SCHEMA_FACTS" events_cap)" "32"
assert_eq "AC1: flags[].verdict is capped at the ruled 32 (folded in by R2; #34 names only events[])" \
  "$(rfield "$SCHEMA_FACTS" flags_cap)" "32"
assert_eq "AC1: events[].verdict is still typed string" "$(rfield "$SCHEMA_FACTS" events_type)" "string"
assert_eq "AC1: flags[].verdict is still typed string" "$(rfield "$SCHEMA_FACTS" flags_type)" "string"
assert_eq "AC1: the two caps agree with each other" \
  "$(rfield "$SCHEMA_FACTS" events_cap)" "$(rfield "$SCHEMA_FACTS" flags_cap)"

# R6. The sentence is prose and no mutation tells an accurate sentence from an inaccurate one,
# so what is asserted is that it is PRESENT on both capped fields -- and the machine-checkable
# half of the claim is asserted separately, as an expiry, further down.
assert_contains "R6: events[].verdict says plainly that nothing validates this file" \
  "$(rfield "$SCHEMA_FACTS" events_desc)" "NOTHING VALIDATES status.json AGAINST THIS SCHEMA"
assert_contains "R6: flags[].verdict says the same" \
  "$(rfield "$SCHEMA_FACTS" flags_desc)" "nothing validates status.json against this schema"
assert_eq "flags[].summary's pre-existing 140 cap is untouched" \
  "$(rfield "$SCHEMA_FACTS" summary_cap)" "140"

# THE WRITER RULE THE DESCRIPTIONS NAME. Both verdict descriptions say the cap "is honored by the
# writer", and commands/pipeline.md is the only document the writer reads. A rule nobody reads is
# a comment, so the claim is asserted rather than trusted -- and asserted against the number read
# out of the SCHEMA, not a literal repeated here, so raising the cap in the schema alone reddens
# this until the writer's copy follows.
PIPELINE_VERDICT_RULE="$(sed -n '/^Rules for `verdict`/,/^$/p' "$PIPELINE_MD")"
assert_contains "R6: commands/pipeline.md restates the verdict cap to the WRITER, beside the 140 summary rule" \
  "$PIPELINE_VERDICT_RULE" "$(rfield "$SCHEMA_FACTS" events_cap)-char cap"
assert_contains "R6: ...and says what the field is for, so the cap is not read as a truncation budget" \
  "$PIPELINE_VERDICT_RULE" "TOKEN, not prose"
assert_eq "CONTROL: the extraction is SCOPED -- the range stops at the blank line and does not run on into the next section" \
  "$(printf '%s' "$PIPELINE_VERDICT_RULE" | grep -c 'When dispatching Phase 4' | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
suite "AC2: VACUITY CONTROL over the corpus, asserted BEFORE any property of it"
# ---------------------------------------------------------------------------
# The floor is DERIVED, never pinned to a number. A pinned 6 measures the branch this suite runs
# on and not the repo: origin/main holds 5 committed records and this branch holds 6, because a
# run commits its OWN status.json as it goes. The population is enumerated twice by independent
# means -- git's index and the filesystem -- and the union of the two is the floor, so the floor
# tracks whatever the tree actually holds and can only grow as runs land. What it refuses is the
# case this project keeps re-breaking: a walk that found NOTHING and reported no problems.
CORPUS_TRACKED_N="$(cd "$REPO_ROOT" && git ls-files '.pipeline/*/status.json' 2>/dev/null | grep -c . | tr -d ' ')"
CORPUS_ONDISK_N="$(cd "$REPO_ROOT" && ls -1 .pipeline/*/status.json 2>/dev/null | grep -c . | tr -d ' ')"
CORPUS_N="$(corpus_files "$REPO_ROOT" '.pipeline/*/status.json' | grep -c . | tr -d ' ')"
CORPUS_FLOOR=$(( CORPUS_TRACKED_N > CORPUS_ONDISK_N ? CORPUS_TRACKED_N : CORPUS_ONDISK_N ))

assert_eq "VACUITY CONTROL: git's index enumerates at least one committed status record" \
  "$([[ "${CORPUS_TRACKED_N:-0}" -ge 1 ]] && echo enough || echo "ZERO tracked records: the walk has nothing to be right about")" "enough"
assert_eq "VACUITY CONTROL: and the filesystem enumerates at least one too" \
  "$([[ "${CORPUS_ONDISK_N:-0}" -ge 1 ]] && echo enough || echo "ZERO on-disk records")" "enough"
assert_eq "VACUITY CONTROL: the union walk is at least as large as both enumerations (it may only WIDEN)" \
  "$([[ "${CORPUS_N:-0}" -ge "$CORPUS_FLOOR" && "$CORPUS_FLOOR" -ge 1 ]] && echo enough || echo "union=$CORPUS_N floor=$CORPUS_FLOOR")" "enough"

LIVE_CAP="$(rfield "$SCHEMA_FACTS" events_cap)"
LIVE="$(verdict_report "$REPO_ROOT" "$LIVE_CAP")"
assert_eq "the walk produced a report at all" \
  "$([[ -n "$LIVE" ]] && echo reported || echo "NO REPORT: the walker did not run")" "reported"
assert_eq "AC2: the walk READ every record the corpus listed (which is what makes the zeros below results)" \
  "$(rfield "$LIVE" read)" "$CORPUS_N"
assert_eq "AC2: every committed record parses" "$(rfield "$LIVE" unreadable)" ""
assert_eq "AC2: and every one has events as an ARRAY (the shape conjunct, asserted apart from the count)" \
  "$(rfield "$LIVE" badevents)" ""
assert_eq "AC2: and flags, where present, is an array too" "$(rfield "$LIVE" badflags)" ""

# The three cells of AC2's matrix, driven against crafted trees. The count conjunct and the two
# shape conjuncts are mutated SEPARATELY: a fixture satisfying both hides whichever is broken.
new_tmpdir || exit 90
EMPTY_ROOT="$NEW_TMPDIR"
mkdir -p "$EMPTY_ROOT/.pipeline"
EMPTY_REPORT="$(verdict_report "$EMPTY_ROOT" "$LIVE_CAP")"
assert_eq "CELL(zero records): the walk reports files=0 rather than passing green" \
  "$(rfield "$EMPTY_REPORT" files)" "0"
assert_eq "CELL(zero records): and the vacuity predicate this suite uses REFUSES that count" \
  "$([[ "$(rfield "$EMPTY_REPORT" files)" -ge 1 ]] && echo enough || echo refused)" "refused"

new_tmpdir || exit 90
BAD_ROOT="$NEW_TMPDIR"
mkdir -p "$BAD_ROOT/.pipeline/a" "$BAD_ROOT/.pipeline/b" "$BAD_ROOT/.pipeline/c"
printf '{"current_phase":"3-impl","events":[]}' > "$BAD_ROOT/.pipeline/a/status.json"
printf '{"current_phase":"3-impl","events":[' > "$BAD_ROOT/.pipeline/b/status.json"
printf '{"current_phase":"3-impl","events":{"phase":"3-impl"}}' > "$BAD_ROOT/.pipeline/c/status.json"
BAD_REPORT="$(verdict_report "$BAD_ROOT" "$LIVE_CAP")"
assert_contains "CELL(unparseable record): the walk NAMES it instead of skipping past it" \
  "$(rfield "$BAD_REPORT" unreadable)" ".pipeline/b/status.json"
assert_eq "CELL(unparseable record): and read < files, so the shortfall is visible" \
  "$([[ "$(rfield "$BAD_REPORT" read)" -lt "$(rfield "$BAD_REPORT" files)" ]] && echo short || echo "read=$(rfield "$BAD_REPORT" read) files=$(rfield "$BAD_REPORT" files)")" "short"
assert_contains "CELL(events is an object, not an array): reported on the shape conjunct" \
  "$(rfield "$BAD_REPORT" badevents)" ".pipeline/c/status.json"
assert_eq "CELL: and the well-formed sibling is NOT reported (the control on the control)" \
  "$(printf '%s' "$(rfield "$BAD_REPORT" badevents)" | grep -c 'pipeline/a/' | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
suite "AC3/AC4: every committed verdict conforms to the cap READ FROM the schema"
# ---------------------------------------------------------------------------
assert_eq "AC4: the cap used below came out of the schema, not out of this file" \
  "$([[ "$LIVE_CAP" =~ ^[0-9]+$ ]] && echo "read" || echo "NOT A NUMBER: $LIVE_CAP")" "read"
assert_eq "AC3: no committed events[].verdict or flags[].verdict exceeds the cap" \
  "$(rfield "$LIVE" violations)" ""
# The zero above is EARNED here: an empty violations list is equally consistent with a walk that
# inspected 26 verdicts and with one that inspected none.
assert_eq "AC3: and the walk actually inspected verdict strings (which is what makes that zero a result)" \
  "$([[ "$(rfield "$LIVE" verdicts)" -ge 1 ]] && echo inspected || echo "inspected NOTHING: verdicts=$(rfield "$LIVE" verdicts)")" "inspected"

# THE NON-ZERO CONTROL, permanent and in-suite rather than a one-off an author ran once. At a cap
# of 17 exactly one committed record violates, and the check must NAME it -- a check that reddens
# without identifying the violator cannot be told apart from one that reddens because the walk
# broke.
#
# EXPIRY, and it is a real one: this control is anchored to a LIVE record, and the correct fate of
# a live record is that somebody edits or deletes it. If this assertion fails, check FIRST whether
# .pipeline/17/status.json still carries APPROVE_WITH_NOTES; if it does not, this control has lost
# its subject and needs re-anchoring to whatever the corpus maximum then is, NOT deleting.
C17="$(verdict_report "$REPO_ROOT" 17)"
assert_contains "AC3 NON-ZERO CONTROL: at cap 17 the check goes red and NAMES the file" \
  "$(rfield "$C17" violations)" ".pipeline/17/status.json"
assert_contains "AC3 NON-ZERO CONTROL: ...names the FLAGS entry that carries the 18-char value" \
  "$(rfield "$C17" violations)" "flags["
assert_contains "AC3 NON-ZERO CONTROL: ...and quotes the offending value" \
  "$(rfield "$C17" violations)" "APPROVE_WITH_NOTES"
assert_eq "AC3 NON-ZERO CONTROL: the corpus maximum is still the 18-char value this control rests on" \
  "$(rfield "$LIVE" longestvalue)/$(rfield "$LIVE" longest)" "APPROVE_WITH_NOTES/18"

# BOTH FIELDS, mutated independently: a control drawn from one cap over the live corpus can leave
# a whole branch unexercised, so "the check fired" would not say WHICH branch fired.
#
# DIRECTION decides what may rest on the live corpus. This FIRES cell may: the corpus only ever
# grows by a run committing its own record, and an added record cannot remove a long verdict, so
# no correct future run can silence it. Its old partner asserted the opposite direction -- that
# the events[] branch was SILENT at cap 17 -- and a silence over a growing population is broken by
# any record that adds a long value. One did, correctly: pipeline.md makes each events[] entry the
# EXIT marker of the phase it closes, so a panel returning APPROVE_WITH_NOTES writes those 18
# characters into events[], and #34's own completed record did exactly that. That cell is now
# re-founded on the crafted pair below, where the population is fixed by this file.
C14="$(verdict_report "$REPO_ROOT" 14)"
assert_contains "AC3 FIXTURE MATRIX: at cap 14 the events[] branch fires on the LIVE corpus" \
  "$(rfield "$C14" violations)" "events["

# THE DISCRIMINATION, on trees this file builds. Each holds one crafted violator in ONE field and
# one record shaped like a real completed run -- events[] AND flags[] both carrying the 18-char
# APPROVE_WITH_NOTES that broke the old cell -- so the population already contains the case that
# comes for it. One branch fires, the other is silent, in both directions: neither can be the
# other's output mislabelled, and neither can mask the other.
LONG_VERDICT="$(node -e 'process.stdout.write("A".repeat(Number(process.argv[1])+1))' "$LIVE_CAP")"
assert_eq "CONTROL: the crafted violator is one character OVER the cap read from the schema (the fixture is the fixture it claims to be)" \
  "${#LONG_VERDICT}" "$(( LIVE_CAP + 1 ))"
new_tmpdir || exit 90
SPLIT_EV="$NEW_TMPDIR"
new_tmpdir || exit 90
SPLIT_FL="$NEW_TMPDIR"
COMPLETED_RUN='{"current_phase":"4-review-complete","events":[{"phase":"4-review","at":"x","verdict":"APPROVE_WITH_NOTES"}],"flags":[{"phase":"4-review","agent":"qa","at":"x","verdict":"APPROVE_WITH_NOTES"}]}'
for split_root in "$SPLIT_EV" "$SPLIT_FL"; do
  mkdir -p "$split_root/.pipeline/run"
  printf '%s' "$COMPLETED_RUN" > "$split_root/.pipeline/run/status.json"
done
mkdir -p "$SPLIT_EV/.pipeline/ev" "$SPLIT_FL/.pipeline/fl"
printf '{"current_phase":"3-impl","events":[{"phase":"3-impl","at":"x","verdict":"%s"}],"flags":[{"phase":"3-impl","agent":"dev","at":"x","verdict":"APPROVE"}]}' \
  "$LONG_VERDICT" > "$SPLIT_EV/.pipeline/ev/status.json"
printf '{"current_phase":"3-impl","events":[{"phase":"3-impl","at":"x","verdict":"APPROVE"}],"flags":[{"phase":"3-impl","agent":"dev","at":"x","verdict":"%s"}]}' \
  "$LONG_VERDICT" > "$SPLIT_FL/.pipeline/fl/status.json"
EV_ONLY="$(verdict_report "$SPLIT_EV" "$LIVE_CAP")"
FL_ONLY="$(verdict_report "$SPLIT_FL" "$LIVE_CAP")"

assert_contains "AC3 FIXTURE MATRIX: with the over-long value in events[], the events[] branch fires and NAMES it" \
  "$(rfield "$EV_ONLY" violations)" ".pipeline/ev/status.json events[0]"
assert_eq "AC3 FIXTURE MATRIX: ...and the flags[] branch is silent on that same tree" \
  "$(printf '%s' "$(rfield "$EV_ONLY" violations)" | grep -c 'flags\[' | tr -d ' ')" "0"
assert_contains "AC3 FIXTURE MATRIX: with the over-long value in flags[], the flags[] branch fires and NAMES it" \
  "$(rfield "$FL_ONLY" violations)" ".pipeline/fl/status.json flags[0]"
assert_eq "AC3 FIXTURE MATRIX: ...and the events[] branch is silent on that same tree (the two cells differ)" \
  "$(printf '%s' "$(rfield "$FL_ONLY" violations)" | grep -c 'events\[' | tr -d ' ')" "0"
# Each silence above is EARNED, not unvisited: four verdict strings per tree were read, and the
# 18-char pair among them is the value a completed APPROVE_WITH_NOTES run writes. A walk that
# stopped inspecting a branch would report the same silence and a smaller count -- which is the
# one mutation the silence cells cannot see by themselves. The literal 4 is safe BECAUSE this
# file owns the population outright: no pipeline run can add a record to these trees, so unlike
# the corpus-anchored cell this replaced, only an edit HERE can move it.
assert_eq "AC3 FIXTURE MATRIX: both branches were INSPECTED in the events[] tree (4 verdicts read)" \
  "$(rfield "$EV_ONLY" verdicts)" "4"
assert_eq "AC3 FIXTURE MATRIX: and in the flags[] tree too" \
  "$(rfield "$FL_ONLY" verdicts)" "4"
assert_eq "AC3 FIXTURE MATRIX: the completed-run record conforms in BOTH fields, so a real APPROVE_WITH_NOTES run cannot break these cells" \
  "$(printf '%s' "$(rfield "$EV_ONLY" violations)$(rfield "$FL_ONLY" violations)" | grep -c 'pipeline/run/' | tr -d ' ')" "0"

# The same two branches against CRAFTED records at the REAL cap, so the matrix does not depend on
# lowering the cap to reach a cell.
new_tmpdir || exit 90
OVER_ROOT="$NEW_TMPDIR"
mkdir -p "$OVER_ROOT/.pipeline/ev" "$OVER_ROOT/.pipeline/fl" "$OVER_ROOT/.pipeline/ok"
printf '{"current_phase":"3-impl","events":[{"phase":"3-impl","at":"x","verdict":"%s"}]}' "$LONG_VERDICT" \
  > "$OVER_ROOT/.pipeline/ev/status.json"
printf '{"current_phase":"3-impl","events":[],"flags":[{"phase":"3-impl","agent":"dev","at":"x","verdict":"%s"}]}' "$LONG_VERDICT" \
  > "$OVER_ROOT/.pipeline/fl/status.json"
printf '{"current_phase":"3-impl","events":[{"phase":"3-impl","at":"x","verdict":"APPROVE_WITH_NOTES"}],"flags":[{"phase":"3-impl","agent":"dev","at":"x"}]}' \
  > "$OVER_ROOT/.pipeline/ok/status.json"
OVER="$(verdict_report "$OVER_ROOT" "$LIVE_CAP")"
assert_contains "AC3 FIXTURE MATRIX: an over-long events[].verdict violates at the real cap" \
  "$(rfield "$OVER" violations)" ".pipeline/ev/status.json events[0]"
assert_contains "AC3 FIXTURE MATRIX: an over-long flags[].verdict violates at the real cap" \
  "$(rfield "$OVER" violations)" ".pipeline/fl/status.json flags[0]"
assert_eq "AC3 FIXTURE MATRIX: a conforming record and a verdict-LESS flag are not violations" \
  "$(printf '%s' "$(rfield "$OVER" violations)" | grep -c 'pipeline/ok/' | tr -d ' ')" "0"
assert_eq "the cap must not become a requirement: the verdict-less flag was simply not counted" \
  "$(rfield "$OVER" verdicts)" "3"

# ---------------------------------------------------------------------------
suite "R6's machine-checkable half: the sentence's EXPIRY"
# ---------------------------------------------------------------------------
# The schema now says in prose that nothing validates status.json against it. Prose cannot be
# mutated into falsity, but the fact underneath it can: the day someone registers status.json in
# AGENT_RULES is the day that sentence becomes a lie, and this is the assertion that notices.
AGENT_RULES_HITS="$(grep -c 'status\.schema\.json' "$VALIDATOR" | tr -d ' ')"
assert_eq "EXPIRY: status.schema.json is still named nowhere in validate-pipeline-artifact.mjs. If this fails, status.json is now validated and the 'nothing validates this file' sentences in the schema must be DELETED, not this assertion." \
  "$AGENT_RULES_HITS" "0"
assert_eq "CONTROL: that grep can find the string when it is there (voice-lint.mjs does read the schema)" \
  "$([[ "$(grep -c 'status\.schema\.json' "$VOICE_LINT" | tr -d ' ')" -ge 1 ]] && echo finds || echo "the grep finds NOTHING anywhere: it is measuring itself")" "finds"

# ---------------------------------------------------------------------------
suite "AC5: the current_phase example list, as SET EQUALITY against pipeline.md"
# ---------------------------------------------------------------------------
# Set equality in BOTH directions, not a substring grep. voice-lint.mjs's first phase table is the
# recorded precedent: its drift test was `grep -q "\"$phase\"" src`, which a phase named in a
# COMMENT satisfies, and the table invented four phases nothing writes and missed two real ones.
#
# Direction: the schema FOLLOWS pipeline.md, never the reverse. pipeline.md's current_phase writes
# are the ground truth; the description is a hand-maintained second copy, which is the whole of
# #42. `<phase>-error` is dropped because it is a TEMPLATE, not a literal, and is named in the
# description as a shape instead. halted-error is ADDED because two other authorities bless it by
# name while pipeline.md writes it nowhere -- see AC6.
PIPELINE_PHASES="$(grep -o '"\?current_phase"\?: *"[^"]*"' "$PIPELINE_MD" \
  | sed 's/.*: *"\(.*\)"/\1/' | grep -vx '<phase>-error' | LC_ALL=C sort -u)"
EXPECTED_PHASES="$(printf '%s\nhalted-error\n' "$PIPELINE_PHASES" | grep -v '^$' | LC_ALL=C sort -u)"
SCHEMA_PHASES="$(printf '%s' "$(rfield "$SCHEMA_FACTS" phaselist)" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u)"
EXPECTED_N="$(printf '%s\n' "$EXPECTED_PHASES" | grep -c . | tr -d ' ')"
SCHEMA_N="$(printf '%s\n' "$SCHEMA_PHASES" | grep -c . | tr -d ' ')"

# VACUITY, first: two empty sets are equal, and a broken grep on either side would prove nothing.
assert_eq "VACUITY: pipeline.md yielded a non-empty phase vocabulary" \
  "$([[ "${EXPECTED_N:-0}" -ge 10 ]] && echo enough || echo "ONLY $EXPECTED_N derived from pipeline.md")" "enough"
assert_eq "VACUITY: and the description's Examples list parsed to a non-empty set" \
  "$([[ "${SCHEMA_N:-0}" -ge 10 ]] && echo enough || echo "ONLY $SCHEMA_N parsed out of the description")" "enough"

MISSING_FROM_SCHEMA="$(comm -23 <(printf '%s\n' "$EXPECTED_PHASES") <(printf '%s\n' "$SCHEMA_PHASES") | tr '\n' ' ' | sed 's/ *$//')"
EXTRA_IN_SCHEMA="$(comm -13 <(printf '%s\n' "$EXPECTED_PHASES") <(printf '%s\n' "$SCHEMA_PHASES") | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "AC5 (direction 1): the description omits nothing pipeline.md writes" "$MISSING_FROM_SCHEMA" ""
assert_eq "AC5 (direction 2): and blessed nothing pipeline.md does not write" "$EXTRA_IN_SCHEMA" ""

# Both directions of the equality, controlled. Without these, "the two sets matched" is equally
# consistent with a comparison that cannot report a difference at all.
CTRL_ADDED="$(comm -13 <(printf '%s\n' "$EXPECTED_PHASES") <(printf '%s\n9-not-a-phase\n' "$SCHEMA_PHASES" | LC_ALL=C sort -u) | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "AC5 CONTROL: a bogus literal added to the list is reported in direction 2" \
  "$CTRL_ADDED" "9-not-a-phase"
CTRL_DROPPED="$(comm -23 <(printf '%s\n' "$EXPECTED_PHASES") <(printf '%s\n' "$SCHEMA_PHASES" | grep -vx '3-impl-complete') | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "AC5 CONTROL: a real literal dropped from the list is reported in direction 1" \
  "$CTRL_DROPPED" "3-impl-complete"

# ---------------------------------------------------------------------------
suite "AC6: halted-error SURVIVES the de-rot (the negative control on the mechanical fix)"
# ---------------------------------------------------------------------------
# The obvious fix derives the list from pipeline.md and therefore DELETES halted-error, because
# pipeline.md writes it nowhere. That would refuse correct work, and nothing would catch it: the
# guard does not read the description.
assert_eq "AC6: halted-error is still named in the description" \
  "$(printf '%s\n' "$SCHEMA_PHASES" | grep -cx 'halted-error' | tr -d ' ')" "1"
assert_eq "AC6: because pipeline.md still writes it NOWHERE (which is what makes deleting it tempting)" \
  "$(printf '%s\n' "$PIPELINE_PHASES" | grep -cx 'halted-error' | tr -d ' ')" "0"
assert_eq "AC6: and the guard still blesses it by name (gate-phase-entry.mjs)" \
  "$([[ "$(grep -c 'halted-error' "$GUARD" | tr -d ' ')" -ge 1 ]] && echo blessed || echo "the guard no longer names it: re-open R3 before removing it here")" "blessed"
assert_contains "AC6: and the schema's own pattern still alternates it" \
  "$(rfield "$SCHEMA_FACTS" pattern)" "halted-error"

# The description's list and the pattern voice-lint enforces must agree, or the schema blesses a
# phase its own regex refuses. Asserted over the whole set, not a representative member.
PATTERN_REJECTS="$(node -e '
  const re = new RegExp(process.argv[1]);
  const bad = process.argv.slice(2).filter((p) => !re.test(p));
  process.stdout.write(bad.join(" "));
' "$(rfield "$SCHEMA_FACTS" pattern)" $SCHEMA_PHASES 2>/dev/null)"
assert_eq "every literal the description names is accepted by the pattern beside it" "$PATTERN_REJECTS" ""
assert_eq "CONTROL: and that check can reject -- a malformed phase is refused by the same pattern" \
  "$(node -e '
    const re = new RegExp(process.argv[1]);
    process.stdout.write(re.test("Phase_Three") ? "accepted" : "refused");
  ' "$(rfield "$SCHEMA_FACTS" pattern)")" "refused"

# ---------------------------------------------------------------------------
suite "AC7: the two rotted literals are gone from the SCHEMA FILE"
# ---------------------------------------------------------------------------
# On the SCHEMA FILE specifically, never repo-wide: `3-scope-drift-adjudication` legitimately
# survives at test-gate-phase-entry.sh:514 as a negative-control INPUT (pipeline.md still writes
# it nowhere, which is exactly what makes it a good input), so a repo-wide grep is red before the
# fix, red after it, and asserts nothing.
assert_eq "AC7: 3-impl-verification-unverified appears nowhere in status.schema.json" \
  "$(grep -c '3-impl-verification-unverified' "$SCHEMA" | tr -d ' ')" "0"
assert_eq "AC7: 3-scope-drift-adjudication appears nowhere in status.schema.json" \
  "$(grep -c '3-scope-drift-adjudication' "$SCHEMA" | tr -d ' ')" "0"
assert_eq "AC7 CONTROL: and that literal is still present as a negative-control INPUT next door, which is why this assertion is file-scoped and not repo-wide" \
  "$([[ "$(grep -c '3-scope-drift-adjudication' "$TESTS_DIR/test-gate-phase-entry.sh" | tr -d ' ')" -ge 1 ]] && echo present || echo "the input is gone: AC7 could now be repo-wide, and test-gate-phase-entry.sh's AC14 cell has lost its subject")" "present"

# ---------------------------------------------------------------------------
suite "AC8: UNCHANGED CONSUMER -- current_phase.pattern is byte-identical"
# ---------------------------------------------------------------------------
# voice-lint.mjs:249 (in phaseShapeFailure) reads exactly this one key out of this file and
# nothing else. Pinned by
# VALUE, not by presence: a presence check survives any edit to the regex, which is the thing the
# only runtime reader actually consumes. The literal below is the pre-change bytes.
assert_eq "AC8: the pattern is byte-identical to its pre-change value" \
  "$(rfield "$SCHEMA_FACTS" pattern)" '^([0-5](\.5)?-[a-z0-9-]+|halted-error)$'
assert_contains "AC8: and voice-lint still reads it out of the schema rather than copying it" \
  "$(cat "$VOICE_LINT")" 'schema?.properties?.current_phase?.pattern'

# ---------------------------------------------------------------------------
suite "AC10: the three rot comments read as HISTORY, not as a live claim"
# ---------------------------------------------------------------------------
# R3 makes the present-tense form of these comments false on landing -- evidence.md's "a control
# anchored to a live defect has a shelf life", arriving on schedule.
#
# THE NEEDLE IS THE CLAIM SHAPE, not the phase literal. `3-scope-drift-adjudication` legitimately
# survives next door as a negative-control input, so keying on it would be red before and after.
# What dies is the pairing "status.schema.json ... <present tense: it names/blesses X>" on one
# line, which is the form all three sites used. The counterpart phrase "pipeline.md never writes
# it" is deliberately NOT part of the needle: that sentence is still TRUE, and still load-bearing,
# for the control input at test-gate-phase-entry.sh:514.
#
# THE VERB IS A CLASS, NOT AN EXAMPLE. The needle used to enumerate one spelling, `blesses`, while
# the assertion below claimed the whole class -- and the escape was not hypothetical: a planted
# `status.schema.json:13 names 3-scope-drift-adjudication` passed green, in the very wording the
# sibling suite at test-gate-phase-entry.sh:511 uses for this subject. Each verb gets its own
# control cell below, because a class proven through one member is an example again. PRESENT
# tense only: `named`/`blessed` are how the re-anchored comments correctly state the history, and
# a needle that swallowed the past tense would refuse the fix it exists to enforce.
#
# The `bl[e]sses`/`n[a]mes` brackets are not decoration: this file is exempt from the walk, but
# the CONTROL cells below grep hand-written strings, and a needle that matched its own definition
# would report the checker instead of the repo.
#
# DISCOVERY IS THE test-*.sh GLOB, with ONE exemption. This suite is exempt because it is the file
# that has to carry the needle and the pre-change wording in order to check them at all -- an
# unexempted walk reports its own source and can never go green, which measures the checker rather
# than the repo. The exemption is by basename and is the only one; a new suite is covered the day
# it lands.
AC10_VERBS='bl[e]sses|n[a]mes|lists|claims'
AC10_NEEDLE="schema\.json.*\b($AC10_VERBS)\b"
AC10_VIOLATORS=""
AC10_EXAMINED=0
for f in "$TESTS_DIR"/test-*.sh; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == "test-status-schema-contract.sh" ]] && continue
  AC10_EXAMINED=$((AC10_EXAMINED + 1))
  if grep -qEn "$AC10_NEEDLE" "$f"; then
    AC10_VIOLATORS="$AC10_VIOLATORS $(basename "$f"):$(grep -En "$AC10_NEEDLE" "$f" | head -1 | cut -d: -f1)"
  fi
done
assert_eq "AC10: no suite still claims in the present tense that the schema names an unwritten phase" \
  "${AC10_VIOLATORS:-none}" "none"
# THE POPULATION IS DERIVED, NOT PINNED -- the same rule this suite applies to AC2's corpus floor,
# applied to its own walk. The floor used to be `-ge 8` against a real population of 33, which is
# room for 24 suites to fall out of the glob in silence: a planted violation in an excluded file
# passed green with 9 walked. Enumerating the glob independently of the loop closes that, and it
# is non-vacuous by construction -- an empty glob yields -1 here against 0 examined, which is red.
AC10_EXPECTED=$(( $(ls "$TESTS_DIR"/test-*.sh 2>/dev/null | grep -c . | tr -d ' ') - 1 ))  # -1 = the single self-exemption
assert_eq "AC10: and the walk examined EVERY suite but its own (population DERIVED from the glob, not pinned)" \
  "$AC10_EXAMINED" "$AC10_EXPECTED"
# The control is the three sites' ACTUAL pre-change wording, one cell each, because a needle
# proven against one hand-written line proves nothing about the other two.
AC10_WAS_1="# insufficient: status.schema.json:13's own description blesses \`3-scope-drift-adjudication\`"
AC10_WAS_2="# The live case, not a hypothetical: status.schema.json:13's own description blesses"
AC10_WAS_3="# Prose alone is provably insufficient: status.schema.json:13 blesses two phases pipeline.md"
for w in "$AC10_WAS_1" "$AC10_WAS_2" "$AC10_WAS_3"; do
  assert_eq "AC10 CONTROL: the needle fires on the pre-change wording -- ${w:0:44}..." \
    "$(printf '%s\n' "$w" | grep -cE "$AC10_NEEDLE" | tr -d ' ')" "1"
done
# ONE CELL PER VERB, over the same sentence, so no member of the class rides on another's cell.
# The `names` cell is the demonstrated escape: this exact line passed green before the widening.
while IFS= read -r verb; do
  assert_eq "AC10 CONTROL: the needle fires on the claim spelled '$verb' (one cell per verb in the class)" \
    "$(printf '%s\n' "# status.schema.json:13 $verb 3-scope-drift-adjudication, and pipeline.md writes it nowhere." \
      | grep -cE "$AC10_NEEDLE" | tr -d ' ')" "1"
done < <(printf '%s\n' "$AC10_VERBS" | tr '|' '\n' | tr -d '[]')
assert_eq "AC10 CONTROL: and it does NOT fire on the surviving true sentence about the control input" \
  "$(printf '%s\n' "# pipeline.md still writes 3-scope-drift-adjudication nowhere, so it stays a valid input" | grep -cE "$AC10_NEEDLE" | tr -d ' ')" "0"
# The PAST tense is the shape the fix itself uses (test-gate-phase-entry.sh:511 "until #42 ...
# named"). A needle that swallowed it would redden on the corrected comments, which is why the
# verb class is anchored on both sides rather than left as a bare substring.
assert_eq "AC10 CONTROL: nor on the re-anchored HISTORY wording, which is the corrected form" \
  "$(printf '%s\n' "# Not a hypothetical: until #42, status.schema.json:13's own description named two phases" | grep -cE "$AC10_NEEDLE" | tr -d ' ')" "0"
for f in test-gate-phase-entry-drift.sh test-gate-phase-entry.sh; do
  assert_eq "AC10: $f restates the rot as history naming #42" \
    "$([[ "$(grep -c 'until #42\|#42' "$TESTS_DIR/$f" | tr -d ' ')" -ge 1 ]] && echo anchored || echo "no #42 reference: the comment was deleted rather than re-anchored")" "anchored"
done


# ---------------------------------------------------------------------------
suite "AC-52a: the secret rule covers EVERY free-text field, and covers it by CONTENT"
# ---------------------------------------------------------------------------
# #34 bounded the two verdict fields. #52 is the half deliberately NOT bounded, and the reason it
# needed a different instrument: status.json reaches a public tree twice (committed, then archived
# VERBATIM at Phase 5), and the rule at commands/pipeline.md named exactly ONE field. Four others
# in the same file were uncovered -- events[].note, flags[].summary, veto_reason and error -- and
# `error` is the sharpest, because the natural content of an error field is COPIED MACHINE OUTPUT.
#
# SECOPS RULED THAT A LENGTH CAP IS THE WRONG INSTRUMENT HERE and that ruling is not re-litigated:
# #34's own 600-char events[0].note is CORRECT WORK (it records a live reproduction of #45), and a
# cap would refuse it to solve a problem length was never the mechanism of. So the assertions
# below come in PAIRS -- the description is present, AND no maxLength appeared -- because the
# cheapest way to make a content problem look solved is to cap the field.
FREETEXT_FACTS="$(node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const ev = (s.properties.events.items || {}).properties || {};
  const fl = (s.properties.flags.items || {}).properties || {};
  const fields = {
    ask_text: s.properties.ask_text,
    veto_reason: s.properties.veto_reason,
    error: s.properties.error,
    "events_note": ev.note,
    "flags_summary": fl.summary,
  };
  let out = "";
  for (const [k, v] of Object.entries(fields)) {
    out += k + "_desc=" + String((v || {}).description ?? "<absent>").replace(/[\r\n]+/g, " ") + "\n";
    out += k + "_max=" + String((v || {}).maxLength ?? "<none>") + "\n";
  }
  process.stdout.write(out);
' "$SCHEMA" 2>/dev/null)"
assert_eq "the free-text extraction produced a report at all" \
  "$([[ -n "$FREETEXT_FACTS" ]] && echo parsed || echo "UNPARSEABLE: $SCHEMA")" "parsed"

# The needle is the EXPOSURE, not a wording: what every one of these descriptions has to tell the
# next author is that the field is archived verbatim. A description that says anything else has
# not stated the reason the rule exists.
for fld in ask_text veto_reason error events_note flags_summary; do
  assert_contains "AC-52a: ${fld}'s description says the field is archived verbatim" \
    "$(rfield "$FREETEXT_FACTS" "${fld}_desc")" "ARCHIVED VERBATIM"
done
# THE PAIRED HALF. Three of the five are unbounded ON PURPOSE and must stay that way; the two that
# do carry a cap carry the pre-existing one, unchanged. Pinned by VALUE, so "someone added a cap"
# and "someone changed the cap" are both visible.
for fld in ask_text veto_reason error events_note; do
  assert_eq "AC-52a: ...and ${fld} still carries NO maxLength (the ruling was CONTENT, not length)" \
    "$(rfield "$FREETEXT_FACTS" "${fld}_max")" "<none>"
done
assert_eq "AC-52a: flags[].summary keeps its pre-existing 140 and gains no new one" \
  "$(rfield "$FREETEXT_FACTS" flags_summary_max)" "140"
assert_contains "AC-52a: ...and says plainly that the 140 is a digest bound, not a secret control" \
  "$(rfield "$FREETEXT_FACTS" flags_summary_desc)" "not a secret control"
assert_contains "AC-52a: events[].note's description records WHY it stays unbounded, so the next author does not 'fix' it" \
  "$(rfield "$FREETEXT_FACTS" events_note_desc)" "600-char note"

# THE WRITER'S COPY. The schema is read by one runtime consumer and it is not the writer; the
# orchestrator reads commands/pipeline.md. A rule that lives only in the schema is a comment.
# Asserted per field, not as one grep, because "the rule mentions free text" is satisfied by
# ask_text alone -- which is the exact hole #52 is about.
PIPELINE_SECRET_RULE="$(sed -n '/NO FREE-TEXT FIELD IN/,/amend the commit/p' "$PIPELINE_MD")"
assert_eq "AC-52b: the free-text secret rule is present in the document the WRITER reads" \
  "$([[ -n "$PIPELINE_SECRET_RULE" ]] && echo present || echo "ABSENT from $PIPELINE_MD")" "present"
for fld in 'ask_text' 'events\[\].note' 'flags\[\].summary' 'veto_reason' 'error'; do
  assert_eq "AC-52b: ...and it names $fld" \
    "$([[ "$(printf '%s' "$PIPELINE_SECRET_RULE" | grep -c "$fld" | tr -d ' ')" -ge 1 ]] && echo named || echo "NOT NAMED: $fld")" "named"
done
assert_contains "AC-52b: ...and states the archival exposure, which is the half the old rule omitted" \
  "$PIPELINE_SECRET_RULE" "knowledge/issue-archive"
assert_contains "AC-52b: ...and refuses the length instrument in the writer's own copy" \
  "$PIPELINE_SECRET_RULE" "CONTENT, not length"
# THE RESIDUAL #52 RECORDED: detection is post-commit, and nothing told the writer what to do
# about that. CI gates the public tree, but by the time it reddens the string is in the branch's
# history and a fix-forward commit does not remove it.
assert_contains "AC-52b: ...and says AMEND rather than fix forward, which detection-after-the-fact requires" \
  "$PIPELINE_SECRET_RULE" "amend the commit; do not fix forward"

# ---------------------------------------------------------------------------
suite "AC-52c: a credential-shaped scan over the committed records AND the archived copies"
# ---------------------------------------------------------------------------
# The population is BOTH, because #52's measurement covered only the first and said so: "the
# archived copy under knowledge/issue-archive/ is walked by nothing." It is walked here. The
# archive is the larger exposure of the two -- 5154 strings against 2030 -- and it is the one
# no test had ever read.
CRED_SCAN="$TEMP_PROJECT/cred-scan.cjs"
cat > "$CRED_SCAN" <<'NODE'
const fs = require("fs");
const files = process.argv.slice(2);
// A GIT SHA IS NOT A SECRET, and this corpus is largely made of them: reviewed_commit,
// merge_base, diff_base, qa_contract_sha, basis_commit, quoted bare AND mid-sentence.
//
// There is NO SHA exemption list here, deliberately. An earlier draft carried one and it was
// removed as DEAD CODE: the mixed-case-and-digit requirement on the entropy class below already
// excludes every hex digest, because hex is single-case, and no mutation to the exemption could
// be made to change a single verdict. An exemption no test can discriminate is a comment that
// looks like a control. What excludes the SHAs is the lookahead pair on `high_entropy`, and the
// two NEGATIVE_*_sha cells below are anchored on that instead -- narrow the character class and
// they redden, which is the property actually being relied on.
const CLASSES = [
  ["aws_akid",     /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
  ["github_pat",   /\bgh[pousr]_[A-Za-z0-9]{36,}\b/],
  ["slack_token",  /\bxox[abprs]-[A-Za-z0-9-]{10,}\b/],
  ["sk_key",       /\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}\b/],
  ["bearer",       /\bBearer\s+[A-Za-z0-9._~+/-]{16,}={0,2}/],
  ["jwt",          /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/],
  ["pem_private",  /-----BEGIN(?: [A-Z]+)* PRIVATE KEY-----/],
  // `pg` leads this alternation deliberately. #52 measured the previous enumeration MISSING
  // `pg://u:p4ssw0rdlong@h/db` and reported the miss rather than patching it out, because a class
  // list is not a proof. This is that miss, closed.
  ["db_url_creds", /\b(?:pg|postgres|postgresql|mysql|mongodb(?:\+srv)?|redis|amqp):\/\/[^\s:/@]+:[^\s@]+@/],
  ["env_line",     /\b[A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*=[^\s"']+/],
  ["assignment",   /\b(?:api[_-]?key|apikey|secret|password|passwd|access[_-]?key|auth[_-]?token)\b\s*[=:]\s*["']?[A-Za-z0-9._\-\/+]{12,}/i],
  // Mixed-case-AND-digit is required, so a slash-separated prose run like
  // "ENTRY/EXIT/UNGUARDED/TERMINAL/satisfyingTokens" is not reported as base64. Controlled below.
  ["high_entropy", /\b(?=[A-Za-z0-9+/]*[a-z])(?=[A-Za-z0-9+/]*[A-Z])(?=[A-Za-z0-9+/]*[0-9])[A-Za-z0-9+/]{40,}={0,2}\b/],
];
const hits = [];
let strings = 0, read = 0;
const unreadable = [];
for (const f of files) {
  let doc;
  try { doc = JSON.parse(fs.readFileSync(f, "utf8")); }
  catch (e) { unreadable.push(f); continue; }
  read++;
  // KEYS ARE WALKED TOO: a credential pasted as an object key reaches the same public tree.
  (function walk(v, p) {
    if (typeof v === "string") {
      strings++;
      for (const [name, re] of CLASSES) if (re.test(v)) hits.push(f + " " + p + " [" + name + "]");
      return;
    }
    if (Array.isArray(v)) return v.forEach((x, i) => walk(x, p + "[" + i + "]"));
    if (v && typeof v === "object")
      return Object.entries(v).forEach(([k, x]) => { walk(k, p + ".<key>"); walk(x, p + "." + k); });
  })(doc, "");
}
process.stdout.write(
  "files=" + files.length + "\nread=" + read + "\nstrings=" + strings + "\nclasses=" + CLASSES.length +
  "\nunreadable=" + unreadable.join(" ;; ") + "\nhits=" + hits.join(" ;; ") + "\n");
NODE

# THE HAND-CHECKED ALLOWLIST. One entry, and it is a real credential SHAPE in a committed file:
# #34's SecOps shard quotes the planted `pg://u:p4ssw0rdlong@h/db` it used as its OWN non-zero
# control while measuring this very exposure. It is a fake in a security report, hand-checked at
# the time and again here. Keyed on file AND json path AND class, so if it moves the suite
# reddens and somebody re-checks -- which is the direction a secret allowlist must fail in.
CRED_ALLOW='knowledge/issue-archive/34.json .peer-review.secops.concerns[2].description [db_url_creds]'

CRED_STATUS_FILES="$(corpus_files "$REPO_ROOT" '.pipeline/*/status.json')"
CRED_ARCHIVE_FILES="$(cd "$REPO_ROOT" && ls -1 knowledge/issue-archive/*.json 2>/dev/null)"
CRED_ALL_FILES="$(printf '%s\n%s\n' "$CRED_STATUS_FILES" "$CRED_ARCHIVE_FILES" | grep -v '^$')"
# Word splitting on the path list is deliberate, as in verdict_report above.
# shellcheck disable=SC2086
CRED_REPORT="$( cd "$REPO_ROOT" 2>/dev/null && node "$CRED_SCAN" $CRED_ALL_FILES )"

# VACUITY FIRST, on BOTH populations independently. A zero over an empty walk is not a result, and
# the two populations are enumerated by different means, so one can go empty while the other does
# not -- which is exactly the silence this would otherwise report as "clean".
assert_eq "VACUITY: the scan produced a report" \
  "$([[ -n "$CRED_REPORT" ]] && echo reported || echo "NO REPORT: the scanner did not run")" "reported"
assert_eq "VACUITY: the archived-copy population is non-empty (it is the half nothing walked before #52)" \
  "$([[ "$(printf '%s\n' "$CRED_ARCHIVE_FILES" | grep -c . | tr -d ' ')" -ge 1 ]] && echo enough || echo "ZERO archives found")" "enough"
assert_eq "VACUITY: and the committed-record population is non-empty too" \
  "$([[ "$(printf '%s\n' "$CRED_STATUS_FILES" | grep -c . | tr -d ' ')" -ge 1 ]] && echo enough || echo "ZERO status records found")" "enough"
assert_eq "VACUITY: every file in both populations parsed" "$(rfield "$CRED_REPORT" unreadable)" ""
assert_eq "VACUITY: and the walk actually inspected strings (which is what makes a clean result a result)" \
  "$([[ "$(rfield "$CRED_REPORT" strings)" -ge 500 ]] && echo inspected || echo "only $(rfield "$CRED_REPORT" strings) strings walked")" "inspected"
assert_eq "VACUITY: with the full class list live, not a subset someone trimmed to go green" \
  "$(rfield "$CRED_REPORT" classes)" "11"

# THE MEASUREMENT.
CRED_UNEXPECTED="$(printf '%s\n' "$(rfield "$CRED_REPORT" hits)" | sed 's/ ;; /\n/g' | sed 's/^ *//;s/ *$//' \
  | grep -v '^$' | grep -vxF "$CRED_ALLOW" | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "AC-52c: no unallowlisted credential-shaped string is committed or archived" "$CRED_UNEXPECTED" ""
# THE ALLOWLIST ENTRY MUST STILL HAVE A SUBJECT. An allowlist that quietly protects nothing is how
# a suite keeps a stale exemption forever; if this fails, the hit moved or the archive was
# regenerated, and the entry needs re-checking, not deleting.
assert_contains "AC-52c: the single allowlisted hit is still exactly where it was hand-checked" \
  "$(rfield "$CRED_REPORT" hits)" "$CRED_ALLOW"

# THE NON-ZERO CONTROL, in-suite and permanent rather than something an author ran once. Every
# class gets its own planted string: a control that fires on one class says nothing about the
# other ten, and #52's own measurement is the precedent -- its DB-URL class MISSED `pg://` while
# the suite around it looked green.
new_tmpdir || exit 90
CRED_PLANT="$NEW_TMPDIR"
mkdir -p "$CRED_PLANT/.pipeline/plant"
cat > "$CRED_PLANT/.pipeline/plant/status.json" <<'PLANT'
{"current_phase":"3-impl","events":[],
 "aws_akid":"AKIAIOSFODNN7EXAMPLE",
 "github_pat":"ghp_012345678901234567890123456789012345",
 "slack_token":"xoxb-123456789012-abcdefghijkl",
 "sk_key":"sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFF",
 "bearer":"Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345",
 "jwt":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk",
 "pem_private":"-----BEGIN RSA PRIVATE KEY-----",
 "db_url_pg_alias":"pg://u:p4ssw0rdlong@h/db",
 "db_url_postgres":"postgres://user:hunter2hunter2@db.internal:5432/app",
 "env_line":"export DATABASE_PASSWORD=s3cr3tvalue",
 "assignment":"api_key = 'aVeryLongLookingKey123456'",
 "high_entropy":"Zm9vYmFyQmF6MTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1A=",
 "NEGATIVE_bare_sha":"2ec6dd73931c16922ea299db73bdc4be96912deb",
 "NEGATIVE_sha_in_prose":"reviewed at 2ec6dd73931c16922ea299db73bdc4be96912deb (origin/main), blob sha256 82bce3d843e89fb6953211e90de2be301bc2c7f125ca3ec465c578f0ac301ff0 unchanged",
 "NEGATIVE_slash_prose":"imports ENTRY/EXIT/UNGUARDED/TERMINAL/satisfyingTokens from the drift suite",
 "NEGATIVE_ordinary":"the 600-char note recording a live reproduction is correct work"}
PLANT
CRED_PLANT_REPORT="$( cd "$CRED_PLANT" && node "$CRED_SCAN" .pipeline/plant/status.json 2>/dev/null )"
CRED_PLANT_HITS="$(rfield "$CRED_PLANT_REPORT" hits)"
# ONE CELL PER CLASS. Eleven classes, eleven cells, because a class proven through one member is
# an example again -- the discipline AC10 applies to its verb class, applied here to the scanner.
for cls in aws_akid github_pat slack_token sk_key bearer jwt pem_private db_url_creds env_line assignment high_entropy; do
  assert_contains "AC-52c NON-ZERO CONTROL: the [$cls] class fires on its planted string" \
    "$CRED_PLANT_HITS" "[$cls]"
done
# BOTH DSN SPELLINGS, because the one #52 measured missing is the one that matters here.
assert_contains "AC-52c NON-ZERO CONTROL: the pg:// alias #52 measured as MISSED now fires" \
  "$CRED_PLANT_HITS" ".db_url_pg_alias [db_url_creds]"
assert_contains "AC-52c NON-ZERO CONTROL: ...and the postgres:// spelling still does too" \
  "$CRED_PLANT_HITS" ".db_url_postgres [db_url_creds]"
# THE NEGATIVE CONTROLS, one per exemption. Without these the scanner could be one that fires on
# everything, and "no unallowlisted hits" over the live corpus would be measuring luck. The two
# SHA cells are what the entropy class's mixed-case-and-digit lookaheads are FOR: widen that class
# to accept single-case runs and both go red, because this repo's records quote commit ids
# everywhere. That mutation is the one these cells exist to catch.
for neg in NEGATIVE_bare_sha NEGATIVE_sha_in_prose NEGATIVE_slash_prose NEGATIVE_ordinary; do
  assert_eq "AC-52c NEGATIVE CONTROL: $neg is NOT reported (the scanner discriminates)" \
    "$(printf '%s' "$CRED_PLANT_HITS" | grep -c "$neg" | tr -d ' ')" "0"
done
# A CREDENTIAL UNDER A KEY, not a value: the walk covers keys, and #52's exposure is prose written
# by an orchestrator that can put a pasted string anywhere.
new_tmpdir || exit 90
CRED_KEY="$NEW_TMPDIR"
mkdir -p "$CRED_KEY/.pipeline/plant"
printf '{"current_phase":"3-impl","events":[],"AKIAIOSFODNN7EXAMPLE":"a credential as a KEY"}' \
  > "$CRED_KEY/.pipeline/plant/status.json"
assert_contains "AC-52c NON-ZERO CONTROL: a credential spelled as an object KEY is reported too" \
  "$(rfield "$( cd "$CRED_KEY" && node "$CRED_SCAN" .pipeline/plant/status.json 2>/dev/null )" hits)" "[aws_akid]"



# ---------------------------------------------------------------------------
suite "AC-54a: the cap is checked against the DECLARED verdict vocabulary, not only against history"
# ---------------------------------------------------------------------------
# AC3 above walks the committed corpus and asserts no STORED verdict exceeds the cap. That is the
# right population for the exposure #34 was filed about, and it leaves the other direction
# unchecked: nothing compared the cap to the vocabulary the project DECLARES. At d8686bc this
# suite referenced review.schema.json and peer-review.schema.json exactly ZERO times.
#
# WHY THAT DIRECTION MATTERS, and it is not symmetry for its own sake. If someone later declares a
# 40-character verdict, the history-side check notices nothing until a run COMMITS one. At that
# moment the failure surfaces as a red corpus check, and the cheapest way to make it green is to
# RAISE THE CAP -- inferring what the field should hold from what it happens to have held. The
# check would be teaching the wrong lesson at the one moment anybody is reading it. This assertion
# fires at the moment of DECLARATION instead, before any record exists to argue from.
#
# THE ASSERTION IS THE BOUND, NOT MEMBERSHIP. A naive "every stored verdict is in the declared
# enum" would refuse 23 of the 29 strings in the current corpus, because the orchestrator
# vocabulary (complete, SKIPPED, NOTE) appears in no declared enum and is correct work.
VERDICT_VOCAB="$TEMP_PROJECT/verdict-vocab.cjs"
cat > "$VERDICT_VOCAB" <<'NODE'
const fs = require("fs");
// BY PROPERTY NAME, not "every enum in the file": these schemas also enumerate severities, panel
// roles, model names and compliance actions, and folding those in would measure the longest
// token in the project rather than the longest VERDICT. `verdict` and `final_verdict` are the two
// spellings the artifact schemas use.
const VERDICT_KEYS = new Set(["verdict", "final_verdict"]);
const tokens = new Set();
const perFile = [];
for (const f of process.argv.slice(2)) {
  let doc;
  try { doc = JSON.parse(fs.readFileSync(f, "utf8")); }
  catch { perFile.push(f + ":UNREADABLE"); continue; }
  let n = 0;
  (function walk(v, key) {
    if (!v || typeof v !== "object") return;
    if (VERDICT_KEYS.has(key) && Array.isArray(v.enum)) {
      for (const t of v.enum) if (typeof t === "string") { tokens.add(t); n++; }
    }
    for (const [k, x] of Object.entries(v)) walk(x, k);
  })(doc, "");
  perFile.push(f.replace(/^.*\//, "") + ":" + n);
}
const list = [...tokens].sort();
const longest = list.reduce((a, t) => (t.length > a.length ? t : a), "");
process.stdout.write(
  "tokens=" + list.join(" ") + "\ncount=" + list.length +
  "\nlongest=" + longest + "\nlongestlen=" + longest.length +
  "\nperfile=" + perFile.join(" ") + "\n");
NODE

VERDICT_SCHEMAS="$PLUGIN_DIR/schemas/review.schema.json $PLUGIN_DIR/schemas/peer-review.schema.json $SCHEMA"
# shellcheck disable=SC2086
VOCAB="$(node "$VERDICT_VOCAB" $VERDICT_SCHEMAS 2>/dev/null)"

# VACUITY, before the bound. A derivation that found nothing has a longest of 0, and 0 <= 32 is
# green -- the exact vacuous pass this whole suite exists to refuse elsewhere.
assert_eq "VACUITY: the vocabulary derivation produced a report" \
  "$([[ -n "$VOCAB" ]] && echo reported || echo "NO REPORT: the extractor did not run")" "reported"
assert_eq "VACUITY: it derived a non-empty verdict set of at least 5 tokens" \
  "$([[ "$(rfield "$VOCAB" count)" -ge 5 ]] && echo enough || echo "ONLY $(rfield "$VOCAB" count) declared verdicts found")" "enough"
# EVERY SOURCE FILE CONTRIBUTED, derived from the file list rather than pinned to a number. A
# count-only floor is satisfied by ONE schema carrying six tokens while the other two are silently
# unread -- which is how a derivation quietly stops covering half its sources.
VOCAB_SILENT="$(printf '%s\n' "$(rfield "$VOCAB" perfile)" | tr ' ' '\n' | grep -v '^$' | grep -E ':(0|UNREADABLE)$' | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "VACUITY: and EVERY verdict schema contributed at least one enum (none silently unread)" \
  "$VOCAB_SILENT" ""
assert_eq "VACUITY: the derivation read all three schemas" \
  "$(printf '%s\n' "$(rfield "$VOCAB" perfile)" | tr ' ' '\n' | grep -c . | tr -d ' ')" "3"
# The set is derived, so this names the CURRENT longest rather than pinning a vocabulary. If it
# changes, the declared vocabulary changed -- re-read the bound below, do not edit this to match.
assert_eq "AC-54a: the longest DECLARED verdict is the 18-char APPROVE_WITH_NOTES" \
  "$(rfield "$VOCAB" longest)/$(rfield "$VOCAB" longestlen)" "APPROVE_WITH_NOTES/18"

# THE BOUND. Both sides are READ -- the cap out of status.schema.json, the vocabulary out of the
# artifact schemas -- so neither can drift without moving this verdict.
assert_eq "AC-54a: the declared vocabulary FITS the cap read from status.schema.json" \
  "$([[ "$(rfield "$VOCAB" longestlen)" -le "$LIVE_CAP" ]] && echo fits || \
     echo "DECLARED '$(rfield "$VOCAB" longest)' is $(rfield "$VOCAB" longestlen) chars against a cap of $LIVE_CAP -- widen the CAP deliberately or shorten the TOKEN; do not infer the cap from the corpus")" "fits"

# THE NON-ZERO CONTROL. A declared 40-character verdict must redden this BEFORE any run commits
# one. Injected into a COPY, so the check is proven falsifiable without a schema edit.
new_tmpdir || exit 90
VOCAB_PLANT="$NEW_TMPDIR"
node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  s.definitions.panelVerdict.properties.verdict.enum.push("A".repeat(40));
  fs.writeFileSync(process.argv[2], JSON.stringify(s, null, 2));
' "$PLUGIN_DIR/schemas/peer-review.schema.json" "$VOCAB_PLANT/peer-review.schema.json"
PLANTED_VOCAB="$(node "$VERDICT_VOCAB" "$PLUGIN_DIR/schemas/review.schema.json" "$VOCAB_PLANT/peer-review.schema.json" "$SCHEMA" 2>/dev/null)"
assert_eq "AC-54a NON-ZERO CONTROL: a 40-char verdict declared in a schema is SEEN by the derivation" \
  "$(rfield "$PLANTED_VOCAB" longestlen)" "40"
assert_eq "AC-54a NON-ZERO CONTROL: ...and the bound REFUSES it, at declaration time" \
  "$([[ "$(rfield "$PLANTED_VOCAB" longestlen)" -le "$LIVE_CAP" ]] && echo fits || echo refused)" "refused"
# CONTROL ON THE CONTROL: the planted file differs from the shipped one only by that token, so the
# cell above is measuring the injection and not a broken read.
assert_eq "AC-54a NON-ZERO CONTROL: the planted schema still yields every real token too" \
  "$([[ "$(rfield "$PLANTED_VOCAB" count)" -eq "$(( $(rfield "$VOCAB" count) + 1 ))" ]] && echo "one more" || \
     echo "planted=$(rfield "$PLANTED_VOCAB" count) live=$(rfield "$VOCAB" count)")" "one more"
# THE KEY FILTER IS LOAD-BEARING, and unasserted it is invisible: drop it and the derivation
# swallows severities and panel roles, whose longest token is unrelated to any verdict.
assert_eq "AC-54a: the derivation is scoped to verdict fields -- a severity is NOT a verdict" \
  "$(printf '%s' "$(rfield "$VOCAB" tokens)" | tr ' ' '\n' | grep -cx 'blocker' | tr -d ' ')" "0"
assert_eq "AC-54a: ...nor is a panel role" \
  "$(printf '%s' "$(rfield "$VOCAB" tokens)" | tr ' ' '\n' | grep -cx 'secops' | tr -d ' ')" "0"
assert_contains "AC-54a: ...while the SecOps veto token, which IS a verdict, is in the set" \
  "$(rfield "$VOCAB" tokens)" "SECOPS_VETO"

# ---------------------------------------------------------------------------
suite "AC-54b: the anti-vacuity floor is anchored to the records this suite's controls NAME"
# ---------------------------------------------------------------------------
# THE LIMIT #54 RECORDED. AC2's floor is max(tracked, ondisk) and every conjunct bottoms out at 1,
# so a corpus that collapsed from six records to one -- on the index and the filesystem at once --
# satisfies it. The floor is derived from the same two enumerations it bounds, so it can only
# detect the two DISAGREEING, never both shrinking together.
#
# THE TWO LENSES DISAGREED AND NEITHER REMEDY IS TAKEN, with reasons.
#   BA proposed pinning 4. Rejected: the corpus is a set of RUN RECORDS and stale ones get pruned
#   deliberately (several .pipeline/<n> dirs here belong to closed issues and are slated for
#   exactly that). A pinned floor turns routine housekeeping into a red suite, which is refusing
#   correct work -- the test this repo applies before adopting any guardrail. It is also the
#   practice evidence.md argued against in 931af1c and that #33 exists to oppose.
#   QA proposed leaving it. Rejected as the whole answer: "it is disclosed" is not a control.
#   The issue's own third option -- derive the floor from the record count at the merge base --
#   is refused too, because #37 rules against a test population derived from a range against a
#   moving ref, and origin/main is exactly that.
#
# WHAT IS BUILT INSTEAD. The floor is anchored to the records this suite's OWN CONTROLS depend on,
# derived by reading those controls rather than by pinning a number. AC3's non-zero control rests
# on .pipeline/17/status.json carrying an 18-char verdict; if that record leaves the corpus, the
# control has lost its subject, and that is a fact this suite can state directly instead of hoping
# a count notices. The list grows by itself the day someone anchors a control to a new record.
# THE DISCRIMINATOR IS THE ID SHAPE, and it is a rule this suite already followed by habit before
# it was written down: a LIVE record is named by its ISSUE NUMBER (.pipeline/17/), while every
# crafted fixture in this file uses a non-numeric id (ev, fl, ok, run, a, b, c, plant,
# unanchored). So a numeric id appearing anywhere in this source is a reference to the real
# corpus, and a crafted tree cannot be mistaken for one. Asserted below rather than assumed.
CORPUS_ANCHORS="$(grep -oE '\.pipeline/[0-9]+/status\.json' "${BASH_SOURCE[0]}" | LC_ALL=C sort -u)"
CORPUS_ANCHOR_N="$(printf '%s\n' "$CORPUS_ANCHORS" | grep -c . | tr -d ' ')"
# VACUITY ON THE VACUITY CONTROL: an empty anchor list makes every assertion below trivially true.
assert_eq "AC-54b VACUITY: the anchor list was derived non-empty from this suite's own controls" \
  "$([[ "${CORPUS_ANCHOR_N:-0}" -ge 1 ]] && echo enough || echo "ZERO anchors derived: the grep found nothing, so the floor below is vacuous")" "enough"

# anchors_missing <corpus-file-list> -> the anchors absent from it
anchors_missing() {
  local corpus="$1" missing="" a
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    printf '%s\n' "$corpus" | grep -qF "$a" || missing="$missing $a"
  done <<< "$CORPUS_ANCHORS"
  printf '%s' "${missing# }"
}
# MEASURED LIMIT, disclosed rather than left to be re-discovered: the population is the tracked
# UNION on-disk walk, so deleting an anchored record from the WORKING TREE alone does not redden
# this -- git's index still lists it, and it is still in the repo. What reddens it is the record
# actually leaving the corpus (untracked AND off disk), which is the state that costs a control
# its subject. Both halves were run against this cell before it shipped.
LIVE_CORPUS_LIST="$(corpus_files "$REPO_ROOT" '.pipeline/*/status.json')"
assert_eq "AC-54b: every record this suite's controls are anchored to is still IN the corpus. If this fails, a control below has lost its subject: re-anchor it to whatever the corpus then holds, do NOT delete it." \
  "$(anchors_missing "$LIVE_CORPUS_LIST")" ""
# AND THE FLOOR RISES WITH THE ANCHORS rather than sitting at 1 forever.
CORPUS_FLOOR_54=$(( CORPUS_FLOOR > CORPUS_ANCHOR_N ? CORPUS_FLOOR : CORPUS_ANCHOR_N ))
assert_eq "AC-54b: the walked corpus meets a floor that accounts for the anchored records too" \
  "$([[ "${CORPUS_N:-0}" -ge "$CORPUS_FLOOR_54" ]] && echo enough || echo "walked=$CORPUS_N floor=$CORPUS_FLOOR_54")" "enough"

# THE NON-ZERO CONTROL, on a tree this file owns. A collapsed corpus that keeps SOME record but
# loses an anchored one now fails, and fails by NAME -- which is the case the max(tracked, ondisk)
# floor passes green.
new_tmpdir || exit 90
COLLAPSED="$NEW_TMPDIR"
mkdir -p "$COLLAPSED/.pipeline/unanchored"
printf '{"current_phase":"3-impl","events":[{"phase":"3-impl","at":"x","verdict":"APPROVE"}]}' \
  > "$COLLAPSED/.pipeline/unanchored/status.json"
COLLAPSED_LIST="$(cd "$COLLAPSED" && ls -1 .pipeline/*/status.json 2>/dev/null)"
assert_eq "AC-54b NON-ZERO CONTROL: a corpus collapsed to one UNANCHORED record is refused, and names what is gone" \
  "$(anchors_missing "$COLLAPSED_LIST")" ".pipeline/17/status.json"
# CONTROL ON THE CONTROL: the same predicate accepts a corpus that still holds the anchor, so the
# cell above is measuring absence and not a helper that always reports something.
assert_eq "AC-54b CONTROL: and a corpus that still holds the anchored record is accepted" \
  "$(anchors_missing '.pipeline/17/status.json
.pipeline/unanchored/status.json')" ""
# THE DISCRIMINATOR ITSELF, asserted: the crafted tree above lives under .pipeline/unanchored/ and
# must NOT be derived as an anchor. Without this cell the derivation would quietly grow an anchor
# every time someone added a numbered fixture, and the floor would then demand a record that only
# ever existed inside this file.
assert_eq "AC-54b: a crafted fixture id is NOT derived as a corpus anchor (numeric ids only)" \
  "$(printf '%s\n' "$CORPUS_ANCHORS" | grep -c 'unanchored' | tr -d ' ')" "0"
assert_eq "AC-54b: ...and every derived anchor really is issue-numbered" \
  "$(printf '%s\n' "$CORPUS_ANCHORS" | grep -v '^$' | grep -cvE '^\.pipeline/[0-9]+/status\.json$' | tr -d ' ')" "0"
# The old floor is UNCHANGED and still asserted above; this is an addition, not a replacement. Its
# limit is stated rather than fixed: a corpus that collapsed to exactly the anchored records still
# passes, because at that point every control still has its subject and the walk still has
# something to be right about. That is the honest boundary of what a vacuity control can claim.
assert_eq "AC-54b: the derived union floor from AC2 is still live alongside this one" \
  "$([[ "${CORPUS_FLOOR:-0}" -ge 1 && "${CORPUS_N:-0}" -ge "$CORPUS_FLOOR" ]] && echo enough || echo "union floor lost: $CORPUS_N vs $CORPUS_FLOOR")" "enough"


finish
