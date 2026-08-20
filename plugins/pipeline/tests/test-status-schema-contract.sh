#!/usr/bin/env bash
# status.schema.json's own contract: the verdict cap (#34) and the current_phase example
# list (#42).
#
# WHY THIS FILE EXISTS. status.schema.json has exactly ONE runtime reader -- voice-lint.mjs:224,
# which reads properties.current_phase.pattern and nothing else. The file appears in no
# AGENT_RULES entry in validate-pipeline-artifact.mjs, and that walker does not implement
# maxLength at all, so a maxLength written into this schema refuses nothing by itself. Both
# defects this suite pins are the same condition: a constraint nobody reads can be absent
# (#34's unbounded verdict) or wrong (#42's rotted phase list) indefinitely with nothing going
# red. So the reader is HERE. The population is the committed corpus, because that is the
# population #34 cares about -- status.json is committed AND archived verbatim into the
# knowledge store, so whatever lands in it lands in a public tree at full length.
#
# THE CAP IS READ FROM THE SCHEMA, NEVER COPIED. One site below holds the literal 32, and it is
# the pin on the value the spec ruled (q2). Every assertion OVER THE CORPUS uses the value read
# out of the schema, so changing the schema alone moves this suite's verdict. A test carrying
# its own copy of 32 would stay green while the schema drifted away underneath it.

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

# THE ONE SITE THAT HOLDS THE LITERAL. This is the pin on the ruled value (spec q2: 32 = the
# 18-char longest DECLARED verdict plus headroom for a longer token, below the length of the
# prose sentence the bound refuses). Every corpus assertion below reads the schema instead.
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
assert_contains "AC3 NON-ZERO CONTROL: ...names the FLAGS entry, not an events entry" \
  "$(rfield "$C17" violations)" "flags["
assert_contains "AC3 NON-ZERO CONTROL: ...and quotes the offending value" \
  "$(rfield "$C17" violations)" "APPROVE_WITH_NOTES"
assert_eq "AC3 NON-ZERO CONTROL: the corpus maximum is still the 18-char value this control rests on" \
  "$(rfield "$LIVE" longestvalue)/$(rfield "$LIVE" longest)" "APPROVE_WITH_NOTES/18"

# BOTH FIELDS, mutated independently. At cap 17 only flags[] fires: events[] tops out at
# REQUEST_CHANGES (15) and sits in the passing cell of the conjunction, so a control drawn from
# the 17-cap alone never exercises the events[] branch at all.
C14="$(verdict_report "$REPO_ROOT" 14)"
assert_contains "AC3 FIXTURE MATRIX: at cap 14 the events[] branch fires too" \
  "$(rfield "$C14" violations)" "events["
assert_eq "AC3 FIXTURE MATRIX: and the events[] branch was silent at cap 17 (so the two cells differ)" \
  "$(printf '%s' "$(rfield "$C17" violations)" | grep -c 'events\[' | tr -d ' ')" "0"

# The same two branches against CRAFTED records at the REAL cap, so the matrix does not depend on
# lowering the cap to reach a cell.
new_tmpdir || exit 90
OVER_ROOT="$NEW_TMPDIR"
mkdir -p "$OVER_ROOT/.pipeline/ev" "$OVER_ROOT/.pipeline/fl" "$OVER_ROOT/.pipeline/ok"
LONG_VERDICT="$(node -e 'process.stdout.write("A".repeat(Number(process.argv[1])+1))' "$LIVE_CAP")"
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
# voice-lint.mjs:224 reads exactly this one key out of this file and nothing else. Pinned by
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
# DISCOVERY IS THE test-*.sh GLOB, with ONE exemption. This suite is exempt because it is the file
# that has to carry the needle and the pre-change wording in order to check them at all -- an
# unexempted walk reports its own source and can never go green, which measures the checker rather
# than the repo. The exemption is by basename and is the only one; a new suite is covered the day
# it lands.
AC10_NEEDLE='schema\.json.*bl[e]sses'
AC10_VIOLATORS=""
AC10_EXAMINED=0
for f in "$TESTS_DIR"/test-*.sh; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == "test-status-schema-contract.sh" ]] && continue
  AC10_EXAMINED=$((AC10_EXAMINED + 1))
  if grep -qn "$AC10_NEEDLE" "$f"; then
    AC10_VIOLATORS="$AC10_VIOLATORS $(basename "$f"):$(grep -n "$AC10_NEEDLE" "$f" | head -1 | cut -d: -f1)"
  fi
done
assert_eq "AC10: no suite still claims in the present tense that the schema names an unwritten phase" \
  "${AC10_VIOLATORS:-none}" "none"
assert_eq "AC10: and the walk examined the suites rather than passing against an empty glob" \
  "$([[ "$AC10_EXAMINED" -ge 8 ]] && echo ok || echo "only $AC10_EXAMINED examined")" "ok"
# The control is the three sites' ACTUAL pre-change wording, one cell each, because a needle
# proven against one hand-written line proves nothing about the other two.
AC10_WAS_1="# insufficient: status.schema.json:13's own description blesses \`3-scope-drift-adjudication\`"
AC10_WAS_2="# The live case, not a hypothetical: status.schema.json:13's own description blesses"
AC10_WAS_3="# Prose alone is provably insufficient: status.schema.json:13 blesses two phases pipeline.md"
for w in "$AC10_WAS_1" "$AC10_WAS_2" "$AC10_WAS_3"; do
  assert_eq "AC10 CONTROL: the needle fires on the pre-change wording -- ${w:0:44}..." \
    "$(printf '%s\n' "$w" | grep -c "$AC10_NEEDLE" | tr -d ' ')" "1"
done
assert_eq "AC10 CONTROL: and it does NOT fire on the surviving true sentence about the control input" \
  "$(printf '%s\n' "# pipeline.md still writes 3-scope-drift-adjudication nowhere, so it stays a valid input" | grep -c "$AC10_NEEDLE" | tr -d ' ')" "0"
for f in test-gate-phase-entry-drift.sh test-gate-phase-entry.sh; do
  assert_eq "AC10: $f restates the rot as history naming #42" \
    "$([[ "$(grep -c 'until #42\|#42' "$TESTS_DIR/$f" | tr -d ' ')" -ge 1 ]] && echo anchored || echo "no #42 reference: the comment was deleted rather than re-anchored")" "anchored"
done

finish
