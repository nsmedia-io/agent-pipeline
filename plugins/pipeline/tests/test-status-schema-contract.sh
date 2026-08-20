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

finish
