#!/usr/bin/env bash
# #71 -- credential material in the free-text fields of the REVIEW artifacts.
#
# THE GAP, ESTABLISHED BY MEASUREMENT AND NOT BY READING. #52 closed the no-secrets rule against
# status.json only, and commands/pipeline.md scoped the sole secret rule in the repo to that one
# file. But knowledge-store.mjs's ARCHIVE_ARTIFACTS is seven names long, review and peer-review
# are two of them, and knowledge/issue-archive/ is tracked and committed. Measured at fbc5212,
# before this change: a review.json carrying four planted credentials -- a DSN in
# concerns[].description, an .env line in concerns[].location, a Bearer header in notes, an AWS
# key id in compliance_flags[].concern -- archived VERBATIM at exit 0, and the run printed
# "absolute paths redacted: 1" while doing it. The redactor had rewritten the leading /etc/app.env
# path in that location and left DATABASE_PASSWORD=s3cr3tvalue standing in the same string.
# A redaction COUNTING a hit is not a redaction COVERING it.
#
# THE OTHER HALF OF THE MEASUREMENT, which decides the shape of the fix. AC-52c in
# test-status-schema-contract.sh ALREADY walks knowledge/issue-archive/*.json in full, so the
# archived review blocks were not unscanned: at fbc5212 that population reached 161
# concerns[].description strings, 126 concerns[].location, 62 notes and 3
# compliance_flags[].concern. What was missing was not detection over the corpus. It was
# (i) anything at the moment of WRITING, and (ii) any statement on the fields at all.
#
# So this suite covers the half that was actually open, and it is deliberately NOT a second copy
# of AC-52c: that suite keeps its own independently re-derived scanner over the committed corpus,
# which is what makes it an oracle rather than a restatement. What is asserted here instead is the
# SEAM between the two class tables (suite 5), so a narrowing of either goes red.
#
# WHY THE CONTROL IS AT THE ARCHIVE WRITE and not on the writers: review.json's free-text fields
# are written by five different subagents from five different contracts, and `advisory_notes` and
# `knowledge_drift_claims[].evidence` are ARCHIVED while being declared in NO schema, so no
# per-field annotation could ever have covered them. The walk is over the document archiveIssue
# assembles FROM ARCHIVE_ARTIFACTS, so the population is DERIVED and a field added later is
# covered the day it appears. Suite 2 is that property, driven off the list in the source.
#
# THE MUTATION BATTERY THIS SUITE WAS BUILT AGAINST, and the one mutation that is EXPECTED to
# survive -- because a battery where everything reddens cannot tell coverage from a rubber stamp.
# Eight mutations, seven red: dropping the refusal while keeping the scan (9 red); scanning the
# RAW archive instead of the redacted bytes (2 red -- and it survived until the /opt/ci/AKIA...
# cell below was added, which is why that cell exists); dropping the object-KEY walk (2);
# widening high_entropy's mixed-case lookaheads (9); dropping the pg:// alias from db_url_creds
# (9); trimming a class from the shipped table (5, via the seam); stripping the note off one
# schema field (2); reverting the writer-copy widening (1).
#
# THE SURVIVOR, DECLARED: mutating the `p || "<root>"` fallback in findCredentialMaterial changes
# no verdict, and it is a THEOREM rather than lost coverage. archiveIssue always builds `archive`
# as an OBJECT ({issue_number, archived_at, ...}), so a string leaf is never at path "" and that
# branch is unreachable from the only caller that writes a file. It is reachable only by an
# external caller passing a bare string to the exported function -- verified directly:
# findCredentialMaterial("AKIA...") returns path "<root>", findCredentialMaterial({a:"AKIA..."})
# returns ".a". If a caller is ever added that hands it a bare string, this stops being a theorem
# and needs a cell.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

STORE="$SCRIPTS_DIR/knowledge-store.mjs"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SCHEMA_DIR="$PLUGIN_ROOT/schemas"
PIPELINE_MD="$PLUGIN_ROOT/commands/pipeline.md"
STATUS_SUITE="$TESTS_DIR/test-status-schema-contract.sh"

make_temp_project || exit 90

# archive <issue> <artifact-dir> <root> [env-assignment]  -> RC / OUT / ERR
archive() {
  local issue="$1" from="$2" root="$3" envset="${4:-}"
  local outf="$TEMP_PROJECT/a-out.txt" errf="$TEMP_PROJECT/a-err.txt"
  if [[ -n "$envset" ]]; then
    ( cd "$TEMP_PROJECT" && env "$envset" node "$STORE" --archive-issue "$issue" --from "$from" --root "$root" ) \
      >"$outf" 2>"$errf"
  else
    ( cd "$TEMP_PROJECT" && node "$STORE" --archive-issue "$issue" --from "$from" --root "$root" ) \
      >"$outf" 2>"$errf"
  fi
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

# fixture_dir -> FIXDIR, a fresh <root>/.pipeline/<issue> under a fresh registered temp root.
# A FRESH ROOT PER CASE, not a shared one: the refusal assertions below check that
# knowledge/issue-archive/ was never created, and a root reused from an earlier successful
# archive would already hold it -- an assertion that passes for the wrong reason.
fixture_dir() {
  new_tmpdir || return 90
  FIXROOT="$NEW_TMPDIR"
  FIXDIR="$FIXROOT/.pipeline/$1"
  mkdir -p "$FIXDIR"
}


# =============================================================================
suite "#71: the archive write REFUSES credential material, one cell per class"
# =============================================================================
# ONE CELL PER CLASS, because a control proven through one member is an example. Each planted
# string sits in a DIFFERENT concerns[] row, so the reported json path names which row fired and
# a single over-eager class cannot stand in for the other ten.
CRED_PLANTS='aws_akid|AKIAIOSFODNN7EXAMPLE
github_pat|ghp_012345678901234567890123456789012345
slack_token|xoxb-123456789012-abcdefghijkl
sk_key|sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFF
bearer|Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345
jwt|eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk
pem_private|-----BEGIN RSA PRIVATE KEY-----
db_url_creds|pg://u:p4ssw0rdlong@h/db
env_line|export DATABASE_PASSWORD=s3cr3tvalue
assignment|api_key = '"'"'aVeryLongLookingKey123456'"'"'
high_entropy|Zm9vYmFyQmF6MTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1A='

# The four NEGATIVE controls, in the same document. Without them "refused" is satisfied by a
# scanner that fires on everything, and this repo's records quote git SHAs everywhere: widen the
# entropy class to accept single-case runs and the two SHA cells go red.
CRED_NEGATIVES='bare_sha|2ec6dd73931c16922ea299db73bdc4be96912deb
sha_in_prose|reviewed at 2ec6dd73931c16922ea299db73bdc4be96912deb (origin/main), blob sha256 82bce3d843e89fb6953211e90de2be301bc2c7f125ca3ec465c578f0ac301ff0 unchanged
slash_prose|imports ENTRY/EXIT/UNGUARDED/TERMINAL/satisfyingTokens from the drift suite
ordinary|the 600-char note recording a live reproduction is correct work'

fixture_dir 701 || exit 90
node -e '
  const fs = require("fs");
  const rows = [];
  for (const line of process.argv[2].split("\n")) {
    const i = line.indexOf("|");
    rows.push({ severity: "high", description: line.slice(0, i) + ": " + line.slice(i + 1),
                must_satisfy: "x", location: "services/api/src/routes/hook.ts:23" });
  }
  for (const line of process.argv[3].split("\n")) {
    const i = line.indexOf("|");
    rows.push({ severity: "nit", description: "NEGATIVE_" + line.slice(0, i) + ": " + line.slice(i + 1),
                must_satisfy: "x" });
  }
  fs.writeFileSync(process.argv[1], JSON.stringify({
    secops: { verdict: "REQUEST_CHANGES", reviewed_at: "2026-08-31T00:00:00Z",
              concerns: rows, notes: "clean prose", vulnerabilities: [] } }));
' "$FIXDIR/review.json" "$CRED_PLANTS" "$CRED_NEGATIVES"

archive 701 "$FIXDIR" "$FIXROOT"
assert_eq "the CLI refuses (exit 1) rather than writing the archive" "$RC" "1"
assert_contains "and says so in the refusal, not only in a warning" "$ERR" "archive refused"
# PREVENTION, NOT ANNOUNCEMENT. The whole value of siting this at the write is that nothing lands.
assert_eq "and NO archive file was written" \
  "$([[ -e "$FIXROOT/knowledge/issue-archive/701.json" ]] && echo "WROTE IT ANYWAY" || echo absent)" "absent"
assert_eq "and the issue-archive directory was not even created" \
  "$([[ -e "$FIXROOT/knowledge/issue-archive" ]] && echo "created before refusing" || echo absent)" "absent"
# The refusal has to tell the operator what to DO, because detection-at-write still leaves a
# string in whatever the reviewer already committed.
assert_contains "the refusal says AMEND rather than fix forward" "$ERR" "AMEND"
assert_contains "the refusal names the override rather than leaving it undiscoverable" \
  "$ERR" "PIPELINE_ARCHIVE_ALLOW_CREDENTIAL_SHAPES"

while IFS= read -r row; do
  cls="${row%%|*}"
  assert_contains "NON-ZERO CONTROL: the [$cls] class fires on its planted string" "$ERR" "[$cls]"
done < <(printf '%s\n' "$CRED_PLANTS")

while IFS= read -r row; do
  neg="${row%%|*}"
  # Locate the negative's OWN row index and assert THAT path is not among the hits. A bare
  # "$ERR does not contain NEGATIVE_bare_sha" would pass vacuously, since the error names json
  # paths and never the string content.
  IDX="$(node -e '
    const d = require(process.argv[1]);
    const i = d.secops.concerns.findIndex((c) => c.description.startsWith("NEGATIVE_" + process.argv[2] + ":"));
    process.stdout.write(String(i));
  ' "$FIXDIR/review.json" "$neg")"
  assert_eq "  NEGATIVE_$neg was placed in the document at all (the fixture constructs the case)" \
    "$([[ "$IDX" -ge 0 ]] && echo placed || echo "NOT IN THE FIXTURE")" "placed"
  assert_not_contains "NEGATIVE CONTROL: NEGATIVE_$neg's row is NOT reported (the scanner discriminates)" \
    "$ERR" ".review.secops.concerns[$IDX].description"
done < <(printf '%s\n' "$CRED_NEGATIVES")


# =============================================================================
suite "#71: every free-text field named in the issue is reached, by json path"
# =============================================================================
# THE FIXTURE MATRIX, not a representative fixture. #71 names five fields; a plant in
# concerns[].description alone would leave the other four in the branch that never runs.
# `advisory_notes` is the load-bearing cell: it is declared in NO schema, so it is the field that
# proves the walk is over the DOCUMENT and not over a list of annotated fields.
fixture_dir 702 || exit 90
cat > "$FIXDIR/review.json" <<'FIX'
{"secops":{"verdict":"VETO","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"high","must_satisfy":"x",
   "description":"repro: psql pg://svc:hunter2hunter2@db.internal/app failed",
   "location":"/etc/app.env:12 DATABASE_PASSWORD=s3cr3tvalue"}],
 "notes":"curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345' returned 403",
 "compliance_flags":[{"statute":"X","concern":"AKIAIOSFODNN7EXAMPLE is in the handler","action":"block"}],
 "vulnerabilities":[{"severity":"high","description":"tok ghp_012345678901234567890123456789012345",
   "location":"deploy.yml:9 API_TOKEN=abcdefghijklmnop","remediation":"rotate it"}]},
 "design_review":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z","concerns":[],"notes":"ok",
   "advisory_notes":["the fixture header carried xoxb-123456789012-abcdefghijkl"]}}
FIX
archive 702 "$FIXDIR" "$FIXROOT"
assert_eq "the whole-document walk refuses" "$RC" "1"
for path in \
  '.review.secops.concerns[0].description' \
  '.review.secops.concerns[0].location' \
  '.review.secops.notes' \
  '.review.secops.compliance_flags[0].concern' \
  '.review.secops.vulnerabilities[0].description' \
  '.review.secops.vulnerabilities[0].location' \
  '.review.design_review.advisory_notes[0]'
do
  assert_contains "the hit at $path is reported by its json path" "$ERR" "$path"
done
# THE LOCATION CASE IS THE ONE #71 WAS FILED ON, so it is asserted as its own property rather
# than left inside the loop: the redactor rewrote the leading /etc/app.env span and the .env line
# after it survived into the archive. This cell fails if anyone concludes that redaction covers it.
assert_contains "the .env line SURVIVING the leading-path redaction is what fires" \
  "$ERR" ".review.secops.concerns[0].location [env_line]"
assert_contains "and advisory_notes -- declared in NO schema -- is covered by the same walk" \
  "$ERR" ".review.design_review.advisory_notes[0] [slack_token]"

# GUARD WHERE IT LANDED, NOT HOW IT WAS SPELLED. redactAbsolutePaths sits between the artifact
# and the file, so the bytes the guard must judge are the REDACTED ones. Here the only
# credential-shaped run in the document is inside an absolute path that redaction replaces
# WHOLESALE, so the written archive genuinely does not contain it -- and refusing would be a
# false refusal the operator cannot act on, since there is nothing in the output to redact.
#
# THIS CELL IS THE ONE THAT DISCRIMINATES the two candidate sitings. Measured: with the scan
# moved from the redacted document to the raw one, every other assertion in this file still
# passes and only this cell reddens.
fixture_dir 704 || exit 90
cat > "$FIXDIR/review.json" <<'FIX'
{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"nit","must_satisfy":"x","description":"see the CI log",
   "location":"/opt/ci/AKIAIOSFODNN7EXAMPLE/build.log"}],"notes":"ok"}}
FIX
archive 704 "$FIXDIR" "$FIXROOT"
assert_eq "a token that redaction REMOVES is not a refusal (the guard judges what lands)" "$RC" "0"
# The premise, asserted rather than assumed: without this the cell above passes whenever the
# fixture simply has no token in it, which is a green light for the wrong reason.
assert_contains "  and the fixture really did carry one before redaction" \
  "$(cat "$FIXDIR/review.json")" "AKIAIOSFODNN7EXAMPLE"
assert_eq "  and the written archive genuinely does not contain it" \
  "$(grep -c 'AKIAIOSFODNN7EXAMPLE' "$FIXROOT/knowledge/issue-archive/704.json" | tr -d ' ')" "0"

# A CREDENTIAL SPELLED AS AN OBJECT KEY, not a value. Reviewer prose can put a pasted string
# anywhere, and a walk that reads values only would archive this one.
fixture_dir 703 || exit 90
printf '{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z","concerns":[],"notes":"x","AKIAIOSFODNN7EXAMPLE":"a credential as a KEY"}}' \
  > "$FIXDIR/review.json"
archive 703 "$FIXDIR" "$FIXROOT"
assert_eq "a credential spelled as an object KEY is refused too" "$RC" "1"
assert_contains "  and reported at the <key> position" "$ERR" ".<key> [aws_akid]"


# =============================================================================
suite "#71: the population is DERIVED from ARCHIVE_ARTIFACTS, never hand-listed"
# =============================================================================
# Property 1 of the issue. The list is read out of the SOURCE and every name in it is driven,
# so a name added to ARCHIVE_ARTIFACTS tomorrow is covered without this suite being edited --
# and a name added to the source while the guard grows an exemption goes red here.
ARCHIVE_NAMES="$(sed -n 's/^const ARCHIVE_ARTIFACTS = \[\(.*\)\];$/\1/p' "$STORE" \
  | tr ',' '\n' | tr -d ' "' | grep -v '^$')"
ARCHIVE_N="$(printf '%s\n' "$ARCHIVE_NAMES" | grep -c . | tr -d ' ')"
# VACUITY FIRST: a failed sed yields an empty list and a loop over nothing reports zero problems,
# which is output-identical to a guard that covers everything.
assert_eq "VACUITY: the ARCHIVE_ARTIFACTS list was extracted from the source at all" \
  "$([[ "$ARCHIVE_N" -ge 5 ]] && echo extracted || echo "extracted only $ARCHIVE_N names")" "extracted"
assert_contains "  and it is the real list (review is in it, which is what #71 is about)" \
  "$ARCHIVE_NAMES" "review"
assert_contains "  and peer-review, the Phase 4 half" "$ARCHIVE_NAMES" "peer-review"

DERIVED_MISSES=""
IDX=710
while IFS= read -r name; do
  IDX=$((IDX + 1))
  fixture_dir "$IDX" || exit 90
  # A free-text field NO schema declares, in every artifact: `note_from_the_future` stands in for
  # the field somebody adds next year. If the guard were keyed on annotated fields it would miss
  # every one of these.
  printf '{"note_from_the_future":"psql pg://u:p4ssw0rdlong@h/db"}' > "$FIXDIR/${name}.json"
  archive "$IDX" "$FIXDIR" "$FIXROOT"
  [[ "$RC" == "1" && "$ERR" == *"[db_url_creds]"* ]] || DERIVED_MISSES="$DERIVED_MISSES $name"
done < <(printf '%s\n' "$ARCHIVE_NAMES")
assert_eq "every ARCHIVE_ARTIFACTS member is walked, in an UNDECLARED field" \
  "${DERIVED_MISSES:-none}" "none"
assert_eq "  and the loop actually ran over every name it extracted" \
  "$((IDX - 710))" "$ARCHIVE_N"

# THE CONTROL ON THAT LOOP: a file that is NOT an ARCHIVE_ARTIFACTS member is not read by
# archiveIssue at all, so the same planted string in `constraints.json` must NOT produce a
# refusal -- it produces the no-artifacts error instead. Without this, "every name refused" is
# also satisfied by a guard that refuses every directory it is pointed at.
fixture_dir 740 || exit 90
printf '{"note":"psql pg://u:p4ssw0rdlong@h/db"}' > "$FIXDIR/constraints.json"
archive 740 "$FIXDIR" "$FIXROOT"
assert_eq "CONTROL: a non-ARCHIVE_ARTIFACTS file is not read, so it is not the reason for a refusal" \
  "$RC" "1"
assert_contains "  (it fails as 'no pipeline artifacts', proving the refusal above was the SCAN)" \
  "$ERR" "no pipeline artifacts found"


# =============================================================================
suite "#71: the clean path is silent, and says how much it walked"
# =============================================================================
# The negative control at the whole-artifact grain. A guard that refuses everything would pass
# every assertion above, and this repo has shipped a reviewer ceiling that refused both of the
# client's live production configs.
fixture_dir 750 || exit 90
cat > "$FIXDIR/review.json" <<'FIX'
{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"high","must_satisfy":"the signature is verified before any side effect",
   "description":"reproduced at 2ec6dd73931c16922ea299db73bdc4be96912deb; the handler runs first",
   "location":"services/api/src/routes/hook.ts:23"}],
 "notes":"imports ENTRY/EXIT/UNGUARDED/TERMINAL/satisfyingTokens from the drift suite",
 "compliance_flags":[{"statute":"GDPR Art. 9","concern":"biometric path without consent","action":"block"}],
 "vulnerabilities":[{"severity":"info","description":"none","remediation":"none required"}]}}
FIX
archive 750 "$FIXDIR" "$FIXROOT"
assert_eq "a clean review artifact archives (exit 0)" "$RC" "0"
assert_eq "  and the file is written" \
  "$([[ -f "$FIXROOT/knowledge/issue-archive/750.json" ]] && echo written || echo MISSING)" "written"
assert_eq "  with nothing on stderr" "$ERR" ""
# A ZERO NEEDS ITS DENOMINATOR. "0 hits" over 0 strings and "0 hits" over 3000 are different
# results, and a scan that never reports its population is indistinguishable from one that
# never ran -- which is the failure mode a check over an EMPTY record set always has.
assert_contains "  and the clean path REPORTS the scan, with its denominator" \
  "$OUT" "credential-shaped strings: 0 (of "
CLEAN_N="$(printf '%s\n' "$OUT" | sed -n 's/.*(of \([0-9]*\) strings scanned).*/\1/p')"
assert_eq "  and that denominator is non-zero, so the clean result is a result" \
  "$([[ "${CLEAN_N:-0}" -ge 10 ]] && echo walked || echo "walked only ${CLEAN_N:-<unparsed>} strings")" "walked"
# The denominator MOVES with the document: a constant would satisfy the cell above forever.
fixture_dir 751 || exit 90
node -e '
  const fs = require("fs");
  const concerns = [];
  for (let i = 0; i < 40; i++)
    concerns.push({ severity: "nit", description: "row " + i, must_satisfy: "x", location: "a.ts:1" });
  fs.writeFileSync(process.argv[1], JSON.stringify({
    secops: { verdict: "APPROVE", reviewed_at: "2026-08-31T00:00:00Z", concerns, notes: "ok" } }));
' "$FIXDIR/review.json"
archive 751 "$FIXDIR" "$FIXROOT"
BIG_N="$(printf '%s\n' "$OUT" | sed -n 's/.*(of \([0-9]*\) strings scanned).*/\1/p')"
assert_eq "  and the denominator TRACKS the document rather than being a constant" \
  "$([[ "${BIG_N:-0}" -gt "${CLEAN_N:-0}" ]] && echo tracks || echo "$BIG_N vs $CLEAN_N")" "tracks"


# =============================================================================
suite "#71: the override exists, is loud, and is the named cost of this guard"
# =============================================================================
# THE CORRECT WORK THIS GUARD REFUSES, NAMED, because a guardrail whose refused-correct-work is
# unnamed has not been costed. knowledge/issue-archive/34.json quotes a planted
# pg://u:p4ssw0rdlong@h/db inside a SecOps concern description -- the fake that review used as
# its OWN non-zero control. Re-archiving #34 now throws. The override is how a hand-check gets
# recorded, and it mirrors PIPELINE_ARCHIVE_ALLOW_STALE, which exists for the same shape.
fixture_dir 760 || exit 90
cat > "$FIXDIR/peer-review.json" <<'FIX'
{"final_verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "secops":{"verdict":"APPROVE","reviewed_at":"2026-08-31T00:00:00Z",
 "concerns":[{"severity":"info","must_satisfy":"x",
   "description":"CONTROL: the scanner fired on a planted pg://u:p4ssw0rdlong@h/db"}],"notes":"ok"}}
FIX
archive 760 "$FIXDIR" "$FIXROOT"
assert_eq "without the override the hand-checked FAKE is refused too (it is a shape scan)" "$RC" "1"
archive 760 "$FIXDIR" "$FIXROOT" "PIPELINE_ARCHIVE_ALLOW_CREDENTIAL_SHAPES=1"
assert_eq "with the override it archives" "$RC" "0"
assert_eq "  and the file lands" \
  "$([[ -f "$FIXROOT/knowledge/issue-archive/760.json" ]] && echo written || echo MISSING)" "written"
# NEVER SILENT. An override that prints nothing is an override nobody notices being left on.
assert_contains "  and the override WARNS on stderr" "$ERR" "CREDENTIAL-SHAPED"
assert_contains "  naming every hit, so it cannot be exercised without the hits being read" \
  "$ERR" ".peer-review.secops.concerns[0].description [db_url_creds]"
assert_contains "  and naming the variable that is set, so the warning explains itself" \
  "$ERR" "PIPELINE_ARCHIVE_ALLOW_CREDENTIAL_SHAPES"
# The count on stdout is the second, machine-readable half of the same fact.
assert_contains "  and stdout records the count rather than reporting a clean run" \
  "$OUT" "credential-shaped strings: 1 (of "
# THE WARNING STAYS OFF STDOUT, on the same contract test-archive-pipeline.sh pins for the
# staleness warning: archive-pipeline.mjs must remain a byte-identical re-dispatch.
assert_not_contains "  and the warning stays OFF stdout (the thin-re-dispatch contract)" \
  "$OUT" "CREDENTIAL-SHAPED"


# =============================================================================
suite "#71: the two credential class tables are one predicate, not two"
# =============================================================================
# THE SEAM. test-status-schema-contract.sh's AC-52c re-derives its own scanner over the committed
# corpus, deliberately, so it is an oracle rather than a restatement of the shipped code. The cost
# of that is two tables that can drift: narrow the shipped one and the archive guard stops
# refusing something AC-52c still reports, which reads as "the corpus is dirty" rather than as
# "the guard was narrowed". Asserted over the class NAMES in both sources.
SHIPPED_CLASSES="$(sed -n '/^const CREDENTIAL_CLASSES = \[/,/^\];/p' "$STORE" \
  | sed -n 's/^  \["\([a-z_]*\)".*/\1/p' | LC_ALL=C sort)"
SUITE_CLASSES="$(sed -n '/^const CLASSES = \[/,/^\];/p' "$STATUS_SUITE" \
  | sed -n 's/^  \["\([a-z_]*\)".*/\1/p' | LC_ALL=C sort)"
assert_eq "VACUITY: the shipped class list was extracted" \
  "$([[ "$(printf '%s\n' "$SHIPPED_CLASSES" | grep -c .)" -ge 5 ]] && echo extracted || echo "EMPTY: sed matched nothing in $STORE")" "extracted"
assert_eq "VACUITY: AC-52c's class list was extracted" \
  "$([[ "$(printf '%s\n' "$SUITE_CLASSES" | grep -c .)" -ge 5 ]] && echo extracted || echo "EMPTY: sed matched nothing in $STATUS_SUITE")" "extracted"
assert_eq "the shipped guard and AC-52c enumerate the SAME credential classes" \
  "$SHIPPED_CLASSES" "$SUITE_CLASSES"
assert_eq "  and there are 11 of them, pinned by value so a trim is visible" \
  "$(printf '%s\n' "$SHIPPED_CLASSES" | grep -c . | tr -d ' ')" "11"


# =============================================================================
suite "#71: every archived free-text field STATES the rule (the half a scan cannot do)"
# =============================================================================
# Property 2 of the issue: a reader of any ONE field can tell, from that field alone, whether
# anything mechanical protects it. Before this change three fields said "this is a norm, not a
# control" and the rest said nothing, which reads as protection by omission.
#
# THE POPULATION IS DERIVED FROM THE SCHEMA, with NO exemption list. Free text is defined
# structurally -- a string-typed leaf with no enum and no date-time format -- so a field added
# later is visibly missing rather than silently absent, which is the property #71 asks for.
FIELD_REPORT="$(node -e '
  const fs = require("fs");
  let free = 0, missing = [], capped = [];
  for (const f of ["review", "peer-review"]) {
    const s = JSON.parse(fs.readFileSync(process.argv[1] + "/" + f + ".schema.json", "utf8"));
    (function walk(n, p) {
      if (!n || typeof n !== "object") return;
      const t = n.type;
      if (t === "string" || (Array.isArray(t) && t.includes("string"))) {
        if (!n.enum && n.format !== "date-time") {
          free++;
          if (!/paste credential material/i.test(n.description || "")) missing.push(f + p);
          if (n.maxLength !== undefined) capped.push(f + p + "=" + n.maxLength);
        }
      }
      for (const [k, v] of Object.entries(n.properties || {})) walk(v, p + "." + k);
      if (n.items) walk(n.items, p + "[]");
      for (const v of n.allOf || []) walk(v, p);
      for (const [k, v] of Object.entries(n.definitions || {})) walk(v, "#" + k);
    })(s, "");
  }
  process.stdout.write("free=" + free + "\nmissing=" + missing.join(" ") + "\ncapped=" + capped.join(" ") + "\n");
' "$SCHEMA_DIR" 2>&1)"
rfld() { printf '%s\n' "$FIELD_REPORT" | sed -n "s/^$1=//p"; }
assert_eq "VACUITY: the schema walk found free-text fields to check" \
  "$([[ "$(rfld free)" -ge 15 ]] && echo walked || echo "only $(rfld free) free-text fields found: $FIELD_REPORT")" "walked"
assert_eq "every free-text field on BOTH review schemas carries the no-credential rule" \
  "$(rfld missing)" ""
# THE PAIRED HALF, and it is the half #52 ruled on: the cheapest way to make a CONTENT problem
# look solved is to cap the field. A long description recording a real reproduction is correct
# work, and a cap would destroy it without addressing the actual risk.
assert_eq "...and NOT ONE of them grew a maxLength (the instrument is CONTENT, not length)" \
  "$(rfld capped)" ""
# THE FIVE FIELDS #71 NAMES, pinned individually rather than trusted to the aggregate above: an
# aggregate over a walk that silently missed a subtree would still read zero.
for probe in \
  'review#agentBlock.concerns[].description' \
  'review#agentBlock.concerns[].location' \
  'review#agentBlock.notes' \
  'review.secops.compliance_flags[].concern' \
  'review.secops.vulnerabilities[].location' \
  'peer-review#panelVerdict.concerns[].description' \
  'peer-review#panelVerdict.concerns[].location' \
  'peer-review#panelVerdict.notes'
do
  HAS="$(node -e '
    const fs = require("fs");
    const [dir, probe] = process.argv.slice(1);
    const f = probe.startsWith("peer-review") ? "peer-review" : "review";
    const rest = probe.slice(f.length);
    const s = JSON.parse(fs.readFileSync(dir + "/" + f + ".schema.json", "utf8"));
    let out = "NOT-FOUND";
    (function walk(n, p) {
      if (!n || typeof n !== "object") return;
      const t = n.type;
      if ((t === "string" || (Array.isArray(t) && t.includes("string"))) && p === rest)
        out = /paste credential material/i.test(n.description || "") ? "RULE" : "MISSING";
      for (const [k, v] of Object.entries(n.properties || {})) walk(v, p + "." + k);
      if (n.items) walk(n.items, p + "[]");
      for (const v of n.allOf || []) walk(v, p);
      for (const [k, v] of Object.entries(n.definitions || {})) walk(v, "#" + k);
    })(s, "");
    process.stdout.write(out);
  ' "$SCHEMA_DIR" "$probe")"
  assert_eq "  $probe carries it (and the path resolves, so this is not a vacuous pass)" "$HAS" "RULE"
done
# THE CLAIM THE OLD DESCRIPTIONS MADE IS NOW FALSE and must not survive. #40 wrote "there is no
# length check, no pattern check and no redaction of credential material on this path" into three
# field descriptions. The pattern check now exists; a schema that still says otherwise is a schema
# lying about its own controls, which is worse than one that says nothing.
for f in review peer-review; do
  assert_eq "$f.schema.json no longer claims there is no pattern check" \
    "$(grep -c 'there is no length check, no pattern check and no redaction of credential material' "$SCHEMA_DIR/$f.schema.json" | tr -d ' ')" "0"
  assert_eq "  and it says what the control does NOT cover, so the correction is not an overclaim" \
    "$([[ "$(grep -c 'spelled as prose' "$SCHEMA_DIR/$f.schema.json" | tr -d ' ')" -ge 1 ]] && echo stated || echo "NOT STATED")" "stated"
done


# =============================================================================
suite "#71: the WRITER's copy names the review artifacts, not status.json alone"
# =============================================================================
# A rule that lives only in a JSON description is a comment: nobody writing a review shard reads
# review.schema.json end to end. commands/pipeline.md is the document the orchestrator reads, and
# at fbc5212 its sole secret rule was scoped to status.json by its own first sentence.
SECRET_RULE="$(sed -n '/NO FREE-TEXT FIELD IN/,/amend the commit/p' "$PIPELINE_MD")"
assert_eq "VACUITY: the secret rule was extracted from the writer's document" \
  "$([[ -n "$SECRET_RULE" ]] && echo present || echo "ABSENT from $PIPELINE_MD")" "present"
# #52's five status.json fields are NOT dropped by the widening. Asserted here as well as in
# AC-52b, because a widening that quietly narrows is the failure this pairing exists to catch.
for fld in 'ask_text' 'events\[\].note' 'flags\[\].summary' 'veto_reason' 'error'; do
  assert_eq "  it still names $fld (#52's half is not dropped by the widening)" \
    "$([[ "$(printf '%s' "$SECRET_RULE" | grep -c "$fld" | tr -d ' ')" -ge 1 ]] && echo named || echo "NOT NAMED: $fld")" "named"
done
for fld in 'concerns\[\].description' 'concerns\[\].location' 'compliance_flags\[\].concern' 'advisory_notes' 'ARCHIVE_ARTIFACTS'; do
  assert_eq "  and now names $fld, which is #71's half" \
    "$([[ "$(printf '%s' "$SECRET_RULE" | grep -c "$fld" | tr -d ' ')" -ge 1 ]] && echo named || echo "NOT NAMED: $fld")" "named"
done
assert_contains "  it names review.json and peer-review.json as reaching the same tree" \
  "$SECRET_RULE" "peer-review.json"
# THE TWO DIRECTIONS, stated to the writer, because they imply different remedies.
assert_contains "  it distinguishes PREVENTION at the archive write..." "$SECRET_RULE" "PREVENTION"
assert_contains "  ...from DETECTION after the fact" "$SECRET_RULE" "DETECTION AFTER THE FACT"
assert_contains "  and still says AMEND rather than fix forward, which detection requires" \
  "$SECRET_RULE" "amend the commit; do not fix forward"
assert_contains "  and still refuses the length instrument" "$SECRET_RULE" "CONTENT, not length"
assert_contains "  and states the half neither mechanism covers" "$SECRET_RULE" "spelled as prose"


# =============================================================================
suite "#71: the SHIPPED guard over the REAL committed archive"
# =============================================================================
# AC-52c runs its own scanner over this corpus. This runs the SHIPPED one, which is the table
# that actually refuses a write, over the same files -- so "the corpus is clean" is a claim about
# the code that protects it and not only about a test-local re-derivation.
#
# ONE ALLOWLISTED HIT, keyed on file AND json path AND class, so if it moves the suite reddens and
# somebody re-checks. It is #34's peer-review SecOps shard quoting the planted
# pg://u:p4ssw0rdlong@h/db it used as its own non-zero control -- hand-checked benign at the time,
# again by AC-52c, and again here.
CORPUS_ALLOW='knowledge/issue-archive/34.json .peer-review.secops.concerns[2].description [db_url_creds]'
CORPUS_REPORT="$( cd "$REPO_ROOT" && STORE_URL="file://$STORE" node --input-type=module -e '
  const { findCredentialMaterial } = await import(process.env.STORE_URL);
  const { readFileSync, readdirSync, existsSync } = await import("node:fs");
  const files = [];
  if (existsSync("knowledge/issue-archive"))
    for (const f of readdirSync("knowledge/issue-archive").sort())
      if (f.endsWith(".json")) files.push("knowledge/issue-archive/" + f);
  if (existsSync(".pipeline"))
    for (const d of readdirSync(".pipeline").sort()) {
      const p = ".pipeline/" + d + "/status.json";
      if (existsSync(p)) files.push(p);
    }
  let strings = 0; const hits = []; const unreadable = [];
  for (const f of files) {
    let doc;
    try { doc = JSON.parse(readFileSync(f, "utf8")); } catch { unreadable.push(f); continue; }
    const r = findCredentialMaterial(doc);
    strings += r.scanned;
    for (const h of r.hits) hits.push(f + " " + h.path + " [" + h.class + "]");
  }
  process.stdout.write("files=" + files.length + "\nstrings=" + strings +
    "\nunreadable=" + unreadable.join(" ;; ") + "\nhits=" + hits.join(" ;; ") + "\n");
' 2>&1 )"
cfield() { printf '%s\n' "$CORPUS_REPORT" | sed -n "s/^$1=//p"; }
assert_eq "VACUITY: the corpus scan produced a report" \
  "$([[ -n "$(cfield files)" ]] && echo reported || echo "NO REPORT: $CORPUS_REPORT")" "reported"
assert_eq "VACUITY: over a non-empty population" \
  "$([[ "$(cfield files)" -ge 5 ]] && echo enough || echo "only $(cfield files) files")" "enough"
assert_eq "VACUITY: and it actually inspected strings" \
  "$([[ "$(cfield strings)" -ge 500 ]] && echo inspected || echo "only $(cfield strings) strings")" "inspected"
assert_eq "VACUITY: every file parsed" "$(cfield unreadable)" ""
CORPUS_UNEXPECTED="$(printf '%s\n' "$(cfield hits)" | sed 's/ ;; /\n/g' | sed 's/^ *//;s/ *$//' \
  | grep -v '^$' | grep -vxF "$CORPUS_ALLOW" | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "the SHIPPED guard reports no unallowlisted credential in the committed corpus" \
  "$CORPUS_UNEXPECTED" ""
assert_contains "and the single allowlisted hit is still exactly where it was hand-checked" \
  "$(cfield hits)" "$CORPUS_ALLOW"

finish
