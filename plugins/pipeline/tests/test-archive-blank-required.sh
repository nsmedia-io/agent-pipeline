#!/usr/bin/env bash
# #122 -- the empty string still satisfies every REQUIRED free-text field on the review
# artifacts. This is #71's property 3, which #71 deliberately shipped without:
#
#   "Whatever distinguishes a present-but-empty value from a meaningful one is applied at the
#    moment of writing, by something that runs, and its failure to run is distinguishable in
#    the output from a clean pass."
#
# THE SEAT. #122 named validate-pipeline-artifact.mjs as the only write-time seat and recorded
# itself blocked on #66, which records that validator as inert under namespaced agent dispatch --
# the shipping default. That framing was incomplete. The Phase 5 archive write runs
# UNCONDITIONALLY in every deployment mode, and #71 had already demonstrated it as a working
# write-time seat, so the check sits there and this issue never needed #66.
#
# THE FAIL DIRECTION IS *WARN*, AND IT IS THE LOAD-BEARING DECISION HERE. By the time archiveIssue
# runs the run is FINISHED and the archive is its only durable copy. #71's credential guard
# REFUSES because shipping the secret IS the harm; refusing here would BE the harm -- destroying
# the record to punish a blank field. Suite 1 is that property, and its sharpest cell is "the file
# was written anyway", which fails exactly when someone re-implements this by analogy with the
# credential guard.
#
# THE CORRECT WORK THIS MUST NOT REPORT, named, because a guardrail whose cost is unnamed has not
# been costed -- and here a false positive is the whole risk, since the population is CLEAN today:
# 3,173 required free-text slots present across the 10 committed archives at 73ee2aa, 0 blank.
#   (a) an `info` vulnerabilities[] row whose honest remediation is "none required" -- the case
#       #122 names by hand. Non-blank, so not reported; a check demanding a PROPERTY-shaped
#       remediation would refuse correct work.
#   (b) an OPTIONAL free-text field left as "" -- `location`, `rationale_not_checked`. Where the
#       schema does not require the field, "" and absent say the same thing.
#   (c) a MISSING required key, which is already refused wherever the validator runs.
# Suite 3 is those three, one cell each.
#
# THE MUTATION BATTERY THIS SUITE WAS BUILT AGAINST is recorded in the PR and in
# test-archive-sidecar-scan.sh's header, which carries the DECLARED SURVIVOR for both halves.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

STORE="$SCRIPTS_DIR/knowledge-store.mjs"
ARCHIVE="$SCRIPTS_DIR/archive-pipeline.mjs"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SCHEMA_DIR="$PLUGIN_ROOT/schemas"

make_temp_project || exit 90

# archive <issue> <artifact-dir> <root> -> RC / OUT / ERR
archive() {
  local issue="$1" from="$2" root="$3"
  local outf="$TEMP_PROJECT/b-out.txt" errf="$TEMP_PROJECT/b-err.txt"
  ( cd "$TEMP_PROJECT" && node "$STORE" --archive-issue "$issue" --from "$from" --root "$root" ) \
    >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

# A FRESH ROOT PER CASE. The write assertions below check whether the archive file exists, and a
# root reused from an earlier successful archive already holds one -- a pass for the wrong reason.
fixture_dir() {
  new_tmpdir || return 90
  FIXROOT="$NEW_TMPDIR"
  FIXDIR="$FIXROOT/.pipeline/$1"
  mkdir -p "$FIXDIR"
}


# =============================================================================
suite "#122: a blank required field is REPORTED and the archive is still WRITTEN"
# =============================================================================
fixture_dir 801 || exit 90
cat > "$FIXDIR/review.json" <<'FIX'
{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"high","description":"the handler runs before verification","must_satisfy":""}],
 "notes":"ok",
 "vulnerabilities":[{"severity":"low","description":"unbounded body","remediation":""}]}}
FIX
archive 801 "$FIXDIR" "$FIXROOT"
# THE FAIL DIRECTION, and it is the whole point of this suite. If these two cells ever go red
# together with a non-zero RC, somebody re-implemented this as a refusal by analogy with #71's
# credential guard -- read the header before "fixing" them.
assert_eq "the CLI still exits 0: a blank field is a QUALITY defect, not a safety one" "$RC" "0"
assert_eq "and the archive file IS written (refusing here would destroy the run's only record)" \
  "$([[ -f "$FIXROOT/knowledge/issue-archive/801.json" ]] && echo written || echo "REFUSED THE WRITE")" "written"
assert_contains "the warning names the blank must_satisfy by json path" \
  "$ERR" ".review.secops.concerns[0].must_satisfy"
assert_contains "and the blank remediation by json path" \
  "$ERR" ".review.secops.vulnerabilities[0].remediation"
# NEVER SILENT, on the same principle as #71's overrides: a warning that does not say what to do
# is a warning that gets scrolled past.
assert_contains "the warning says the archive WAS written, so the reader is not hunting a refusal" \
  "$ERR" "The archive WAS written"
assert_contains "  and says what to do instead: fix the source artifact and archive again" \
  "$ERR" "archive again to correct the record"
assert_contains "  and cites the issue, so the fail-direction reasoning is one lookup away" "$ERR" "#122"
# The machine-readable half, on stdout, with its denominator.
assert_contains "stdout carries the count rather than reporting a clean run" \
  "$OUT" "blank required free-text fields: 2 (of "
# THE WARNING STAYS OFF STDOUT, on the contract test-archive-pipeline.sh pins: archive-pipeline.mjs
# must remain a byte-identical re-dispatch, and a warning on stdout would make that false.
assert_not_contains "and the warning stays OFF stdout (the thin-re-dispatch contract)" \
  "$OUT" "The archive WAS written"


# =============================================================================
suite "#122: every SPELLING of blank, not just the empty string"
# =============================================================================
# GUARD WHERE IT LANDED, NOT HOW IT WAS SPELLED. `""`, `"   "`, `[]` and `["",\" \"]` are the same
# non-signal, and `notes` is typed string-OR-array by the schema, so covering only the first
# spelling would leave three one-keystroke bypasses of the same check. One cell per spelling,
# each in its own row, so the reported json path names which one fired.
fixture_dir 802 || exit 90
cat > "$FIXDIR/review.json" <<'FIX'
{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"high","description":"EMPTY_STRING","must_satisfy":""},
             {"severity":"high","description":"WHITESPACE","must_satisfy":"   "},
             {"severity":"high","description":"TAB_ONLY","must_satisfy":"\t"}],
 "notes":[]},
 "dba":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z","concerns":[],"notes":["","  "]}}
FIX
archive 802 "$FIXDIR" "$FIXROOT"
assert_eq "  (and it still archives)" "$RC" "0"
for cell in \
  'the empty string|.review.secops.concerns[0].must_satisfy' \
  'a whitespace-only run|.review.secops.concerns[1].must_satisfy' \
  'a lone tab|.review.secops.concerns[2].must_satisfy' \
  'an EMPTY ARRAY on the string-or-array notes|.review.secops.notes' \
  'an array whose every element is blank|.review.dba.notes'
do
  assert_contains "${cell%%|*} is reported" "$ERR" "${cell##*|}"
done
assert_contains "  and all five are counted, not just the first" \
  "$OUT" "blank required free-text fields: 5 (of "


# =============================================================================
suite "#122: the NEGATIVE controls -- the correct work this must not report"
# =============================================================================
# Without these, "reports the blanks" is also satisfied by a check that reports EVERY field, and
# this repo has shipped a reviewer ceiling that refused both of the client's live production
# configs. Each cell is a shape #122 or the schemas name as correct.
fixture_dir 803 || exit 90
cat > "$FIXDIR/review.json" <<'FIX'
{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"info","description":"OPTIONAL_BLANKS","must_satisfy":"x",
              "location":"","rationale_not_checked":""},
             {"severity":"nit","description":"MISSING_KEY"}],
 "notes":"ok",
 "vulnerabilities":[{"severity":"info","description":"no security impact","remediation":"none required"}]},
 "dba":{"verdict":"APPROVE","reviewed_at":"","concerns":[],"notes":"ok"}}
FIX
archive 803 "$FIXDIR" "$FIXROOT"
assert_eq "the fixture archives cleanly" "$RC" "0"
# (a) THE CASE #122 NAMES BY HAND. An `info` row whose honest remediation is "none required" is
# non-blank and must not be reported; a check demanding a PROPERTY-shaped remediation would be
# wrong, and this is the cell that fails if anyone builds one.
assert_not_contains "an info row's honest \"none required\" remediation is NOT reported (#122 names this)" \
  "$ERR" ".review.secops.vulnerabilities[0].remediation"
# (b) OPTIONAL blanks. `location` and `rationale_not_checked` are not in any required list, so ""
# and absent say the same thing and neither is a defect.
assert_not_contains "an OPTIONAL location left blank is NOT reported" \
  "$ERR" ".review.secops.concerns[0].location"
assert_not_contains "an OPTIONAL rationale_not_checked left blank is NOT reported" \
  "$ERR" ".review.secops.concerns[0].rationale_not_checked"
# (c) A MISSING required key is a different defect with a different owner.
assert_not_contains "a MISSING required must_satisfy is not reported as a BLANK one" \
  "$ERR" ".review.secops.concerns[1].must_satisfy"
# (d) STRUCTURAL EXCLUSION, not an exemption list: reviewed_at carries format date-time, so it is
# not free text. Mutate the format test out of isFreeTextSchema and this cell reddens.
assert_not_contains "a blank reviewed_at is NOT free text (date-time format excludes it structurally)" \
  "$ERR" ".review.dba.reviewed_at"
assert_contains "and the whole document reports ZERO blanks over a non-zero denominator" \
  "$OUT" "blank required free-text fields: 0 (of "
NEG_N="$(printf '%s\n' "$OUT" | sed -n 's/.*fields: 0 (of \([0-9]*\) present.*/\1/p')"
assert_eq "  and that denominator is non-zero, so the clean result is a result" \
  "$([[ "${NEG_N:-0}" -ge 4 ]] && echo checked || echo "checked only ${NEG_N:-<unparsed>} fields")" "checked"

# THE PEER-REVIEW BOUNDARY, asserted rather than assumed. #38: peer-review.json's concerns[]
# subschema has NO required list at all, so a blank must_satisfy there is invisible to a check
# whose population is DERIVED from `required`. 123 of the 230 concerns[] rows #122 measured live
# in that half. This is stated as a cell so the boundary is MEASURED, not believed.
#
# WHEN THIS CELL FAILS, #38 CLOSED and this check widened for free -- that is the payoff of a
# derived population. Re-anchor the cell to the new boundary; do not re-open the hole to keep it
# green.
fixture_dir 804 || exit 90
cat > "$FIXDIR/peer-review.json" <<'FIX'
{"final_verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "secops":{"verdict":"APPROVE","concerns":[{"severity":"nit","description":"","must_satisfy":""}],"notes":""}}
FIX
archive 804 "$FIXDIR" "$FIXROOT"
assert_eq "TODAY'S BOUNDARY (#38): a blank peer-review must_satisfy is not reachable by a required-derived check" \
  "$(printf '%s\n' "$OUT" | sed -n 's/.*blank required free-text fields: \([0-9]*\) .*/\1/p')" "0"
assert_eq "  and the premise is REAL: peer-review's concerns items declare no required list" \
  "$(node -e '
     const s = JSON.parse(require("fs").readFileSync(process.argv[1] + "/peer-review.schema.json", "utf8"));
     let found = "none";
     (function walk(n, p) {
       if (!n || typeof n !== "object") return;
       if (p === "#panelVerdict.concerns[]" && Array.isArray(n.required)) found = n.required.join(",");
       for (const [k, v] of Object.entries(n.properties || {})) walk(v, p + "." + k);
       if (n.items) walk(n.items, p + "[]");
       for (const v of n.allOf || []) walk(v, p);
       for (const [k, v] of Object.entries(n.definitions || {})) walk(v, "#" + k);
     })(s, "");
     process.stdout.write(found);' "$SCHEMA_DIR")" "none"


# =============================================================================
suite "#122: the population is DERIVED from the shipped schemas, never listed in code"
# =============================================================================
# The same property #71 asserts for ARCHIVE_ARTIFACTS, at the field grain. If the guard were a
# hand-written list of field names, a field that becomes required tomorrow would be covered the
# day somebody remembers it rather than the day the schema says so.
#
# HALF ONE: the shipped source names no field. A `["must_satisfy", "remediation"]` table is the
# obvious wrong implementation and this is what refuses it.
for fld in must_satisfy remediation; do
  assert_eq "knowledge-store.mjs does not name \`$fld\` as a literal (a hand-list is the wrong instrument)" \
    "$(grep -c "\"$fld\"" "$STORE" | tr -d ' ')" "0"
done
# HALF TWO, and it is the one that actually proves derivation: point the walker at a COPY of the
# schema directory carrying a field that does not exist in the shipped schemas, and watch it get
# picked up with NO code change. Its control is the same field left OPTIONAL.
new_tmpdir || exit 90
DERIVED="$NEW_TMPDIR"
node -e '
  const fs = require("fs");
  const [src, dst, mode] = process.argv.slice(1);
  fs.mkdirSync(dst, { recursive: true });
  for (const f of fs.readdirSync(src)) fs.copyFileSync(src + "/" + f, dst + "/" + f);
  const s = JSON.parse(fs.readFileSync(dst + "/review.schema.json", "utf8"));
  const block = s.definitions.agentBlock;
  block.properties.note_from_the_future = { type: "string", description: "a field nobody has written yet" };
  if (mode === "required") block.required = [...block.required, "note_from_the_future"];
  fs.writeFileSync(dst + "/review.schema.json", JSON.stringify(s, null, 2));
' "$SCHEMA_DIR" "$DERIVED/required" required
node -e '
  const fs = require("fs");
  const [src, dst] = process.argv.slice(1);
  fs.mkdirSync(dst, { recursive: true });
  for (const f of fs.readdirSync(src)) fs.copyFileSync(src + "/" + f, dst + "/" + f);
  const s = JSON.parse(fs.readFileSync(dst + "/review.schema.json", "utf8"));
  s.definitions.agentBlock.properties.note_from_the_future = { type: "string", description: "optional" };
  fs.writeFileSync(dst + "/review.schema.json", JSON.stringify(s, null, 2));
' "$SCHEMA_DIR" "$DERIVED/optional"

DERIVED_DOC='{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z","concerns":[],"notes":"ok","note_from_the_future":""}}'
derived_blanks() {
  STORE_URL="file://$STORE" DOC="$DERIVED_DOC" SDIR="$1" node --input-type=module -e '
    const { findBlankRequiredFields } = await import(process.env.STORE_URL);
    const r = findBlankRequiredFields({ review: JSON.parse(process.env.DOC) }, process.env.SDIR);
    process.stdout.write(r.blanks.join(" ") + " || read=" + r.schemasRead + "/" + r.schemasExpected);'
}
assert_eq "VACUITY: the modified schema copy was actually built" \
  "$([[ -f "$DERIVED/required/review.schema.json" ]] && echo built || echo "NOT BUILT")" "built"
assert_contains "a field that becomes REQUIRED tomorrow is covered with no code change" \
  "$(derived_blanks "$DERIVED/required")" ".review.secops.note_from_the_future"
assert_not_contains "CONTROL: the same field left OPTIONAL is not reported (it is \`required\` that drives this)" \
  "$(derived_blanks "$DERIVED/optional")" ".review.secops.note_from_the_future"
assert_contains "  and the control really read the schema set (not a zero from an unreadable dir)" \
  "$(derived_blanks "$DERIVED/optional")" "read=1/1"


# =============================================================================
suite "#122: the denominator, and the NOT-CHECKED path that makes a zero a result"
# =============================================================================
# Property 3's last clause: "its failure to run is distinguishable in the output from a clean
# pass". A walk that could read no schema reports 0 blank truthfully and vacuously.
fixture_dir 805 || exit 90
cat > "$FIXDIR/review.json" <<'FIX'
{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"high","description":"d","must_satisfy":"m"}],"notes":"ok"}}
FIX
archive 805 "$FIXDIR" "$FIXROOT"
SMALL_N="$(printf '%s\n' "$OUT" | sed -n 's/.*fields: 0 (of \([0-9]*\) present.*/\1/p')"
assert_eq "a clean review reports 0 over a non-zero denominator" \
  "$([[ "${SMALL_N:-0}" -ge 3 ]] && echo counted || echo "counted ${SMALL_N:-<unparsed>}")" "counted"
assert_contains "  and names how many artifact schemas it read, so a partial walk is visible" \
  "$OUT" "artifact schemas)"
fixture_dir 806 || exit 90
node -e '
  const fs = require("fs");
  const concerns = [];
  for (let i = 0; i < 30; i++) concerns.push({ severity: "nit", description: "row " + i, must_satisfy: "m" });
  fs.writeFileSync(process.argv[1], JSON.stringify({
    secops: { verdict: "APPROVE", reviewed_at: "2026-08-31T00:00:00Z", concerns, notes: "ok" } }));
' "$FIXDIR/review.json"
archive 806 "$FIXDIR" "$FIXROOT"
BIG_N="$(printf '%s\n' "$OUT" | sed -n 's/.*fields: 0 (of \([0-9]*\) present.*/\1/p')"
assert_eq "  and the denominator TRACKS the document rather than being a constant" \
  "$([[ "${BIG_N:-0}" -gt "${SMALL_N:-0}" ]] && echo tracks || echo "$BIG_N vs $SMALL_N")" "tracks"

# THE DEGRADED PATH IS REACHABLE, not hypothetical: test-knowledge-store.sh and test-scripts-lib.sh
# both copy this script into a scratch dir WITHOUT its ../schemas sibling. Same shape here.
new_tmpdir || exit 90
NOSCHEMA="$NEW_TMPDIR"
copy_script_with_deps "$SCRIPTS_DIR" "knowledge-store.mjs" "$NOSCHEMA"
fixture_dir 807 || exit 90
cat > "$FIXDIR/review.json" <<'FIX'
{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"high","description":"d","must_satisfy":""}],"notes":"ok"}}
FIX
NS_OUT=$( cd "$TEMP_PROJECT" && node "$NOSCHEMA/knowledge-store.mjs" --archive-issue 807 \
  --from "$FIXDIR" --root "$FIXROOT" 2>"$TEMP_PROJECT/ns-err.txt" )
NS_RC=$?
NS_ERR=$(cat "$TEMP_PROJECT/ns-err.txt")
assert_contains "with no schemas readable the line says NOT CHECKED, not 0" "$NS_OUT" "NOT CHECKED"
assert_contains "  and names the directory it looked in, so the operator can act on it" \
  "$NS_ERR" "artifact schemas under"
assert_contains "  and says the count is not a clean result" "$NS_ERR" "treat it as unchecked"
# The WARN posture survives its own degradation: an unreadable schema set must not cost the record.
assert_eq "  and the archive is STILL written (a missing schema is not a reason to lose the run)" \
  "$([[ -f "$FIXROOT/knowledge/issue-archive/807.json" ]] && echo written || echo "REFUSED")" "written"
assert_eq "  at exit 0" "$NS_RC" "0"


# =============================================================================
suite "#122: both entry points report it, and the re-dispatch stays byte-identical"
# =============================================================================
# archive-pipeline.mjs is contractually a thin re-dispatch (test-archive-pipeline.sh pins the two
# stdouts against each other). A new report line added to one and not the other is exactly the
# divergence that contract exists to catch, so it is asserted from this side too.
fixture_dir 808 || exit 90
cat > "$FIXDIR/review.json" <<'FIX'
{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"high","description":"d","must_satisfy":""}],"notes":"ok"}}
FIX
new_tmpdir || exit 90
WRAP_ROOT="$NEW_TMPDIR"
WRAP_OUT=$( cd "$TEMP_PROJECT" && node "$ARCHIVE" --issue 808 --from "$FIXDIR" --root "$WRAP_ROOT" 2>/dev/null )
archive 808 "$FIXDIR" "$FIXROOT"
assert_contains "the wrapper prints the blank-field line too" \
  "$WRAP_OUT" "blank required free-text fields: 1 (of "
assert_eq "  and the two stdouts agree once the root is normalized" \
  "${WRAP_OUT//$WRAP_ROOT/<root>}" "${OUT//$FIXROOT/<root>}"


# =============================================================================
suite "#122: the SHIPPED walker over the REAL committed archive corpus"
# =============================================================================
# The measurement #122 asks a later reader to be able to re-take, run by the code that actually
# ships rather than by a re-derivation. Measured at 73ee2aa: 10 files, 3,173 required free-text
# slots present, ZERO blank.
#
# IF THIS GOES RED, an archived run carried a blank required field. The remedy is to fill the
# field in the source artifact and re-archive -- NOT to relax the assertion. Refusing a COMMIT
# that adds one is a different question from refusing the WRITE that produced it: the record
# already exists on disk by then, so nothing is destroyed by asking for the field.
CORPUS="$( cd "$REPO_ROOT" && STORE_URL="file://$STORE" node --input-type=module -e '
  const { findBlankRequiredFields } = await import(process.env.STORE_URL);
  const { readFileSync, readdirSync, existsSync } = await import("node:fs");
  const files = [];
  if (existsSync("knowledge/issue-archive"))
    for (const f of readdirSync("knowledge/issue-archive").sort())
      if (f.endsWith(".json")) files.push("knowledge/issue-archive/" + f);
  let checked = 0, partial = 0; const blanks = [], unreadable = [];
  for (const f of files) {
    let doc;
    try { doc = JSON.parse(readFileSync(f, "utf8")); } catch { unreadable.push(f); continue; }
    const r = findBlankRequiredFields(doc);
    checked += r.checked;
    if (r.schemasRead !== r.schemasExpected) partial++;
    for (const b of r.blanks) blanks.push(f + " " + b);
  }
  process.stdout.write("files=" + files.length + "\nchecked=" + checked + "\npartial=" + partial +
    "\nunreadable=" + unreadable.join(" ;; ") + "\nblanks=" + blanks.join(" ;; ") + "\n");
' 2>&1 )"
bfield() { printf '%s\n' "$CORPUS" | sed -n "s/^$1=//p"; }
assert_eq "VACUITY: the corpus walk produced a report" \
  "$([[ -n "$(bfield files)" ]] && echo reported || echo "NO REPORT: $CORPUS")" "reported"
assert_eq "VACUITY: over a non-empty population" \
  "$([[ "$(bfield files)" -ge 5 ]] && echo enough || echo "only $(bfield files) archives")" "enough"
assert_eq "VACUITY: and it actually inspected required fields (a zero over zero is not a result)" \
  "$([[ "$(bfield checked)" -ge 500 ]] && echo inspected || echo "only $(bfield checked) required fields")" "inspected"
assert_eq "VACUITY: every archive parsed" "$(bfield unreadable)" ""
assert_eq "VACUITY: and no archive fell down the NOT-CHECKED path" "$(bfield partial)" "0"
assert_eq "no required free-text field is blank in the committed archive corpus" "$(bfield blanks)" ""

finish
