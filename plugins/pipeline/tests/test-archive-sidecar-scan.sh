#!/usr/bin/env bash
# #125 -- knowledge/issue-archive/ holds committed, agent-authored *.md and *.sh sidecars that
# NEITHER credential control reaches, and both scopings are by CONSTRUCTION rather than by
# oversight: AC-52c (test-status-schema-contract.sh) builds its population from
# `ls -1 knowledge/issue-archive/*.json`, and archiveIssue writes only `<n>.json`, so #71's
# write-time refusal never sees anything else. Measured on merged main at 73ee2aa: six sidecars,
# 404,889 bytes, 6,486 lines, scanned by nothing. (#125's own table says 403,389 over the same
# six files; the two `.sh` batteries grew between that measurement and this one. The number
# carries its window: this suite RE-TAKES it every run rather than quoting either figure.)
#
# THE POPULATION IS CLEAN TODAY -- 0 hits across all six files, all eleven classes. This is a
# RATCHET, not a live leak. Its value is that a future sidecar carrying a pasted DSN would reach
# the tree exactly the way #71's `location` field would have, and nothing would notice.
#
# WHY THIS IS A SEPARATE READER AND NOT A WIDER GLOB, which is #125's load-bearing constraint.
# AC-52c's vacuity assertion requires every file in its population to JSON.parse; feeding it a
# `.sh` reddens it for the wrong reason, which is worse than not covering it. So the raw-text
# pass is kept separate -- and the CLASS TABLE IS NOT. findCredentialMaterialInText calls the
# shipped findCredentialMaterial once per line, so there is exactly one predicate and narrowing
# it narrows both passes together (suite H).
#
# THE FAIL DIRECTION HERE IS *REFUSE*, WHICH IS THE OPPOSITE OF #122's, AND DELIBERATELY. Both
# ship in the same change, so the contrast is worth stating: a credential in a committed sidecar
# is a SAFETY defect and refusing the merge destroys nothing, because the file already exists on
# disk. #122's blank field is a QUALITY defect at a point where refusing would destroy the run's
# only record. Same repository, same week, opposite directions, decided by what the refusal costs.
#
# THE FALSE-POSITIVE DIRECTION, WHICH #125 SAYS TO THINK THROUGH OR THE CHECK GETS SWITCHED OFF.
# Measured, not reasoned: the shipped class table run line-by-line over this repository's 79
# committed .md/.sh files (38,493 lines) fires 52 times, and every one is a fixture, a comment
# quoting a fixture, or documentation prose. ZERO are real secrets. Two instruments handle that,
# in this order:
#   1. A DERIVED PLANT-STRIP. The repo has ONE canonical set of planted credential fixtures --
#      the AC-52c plant document in test-status-schema-contract.sh -- and each of its strings has
#      been hand-checked at least twice already. A hit survives only if it still fires after every
#      canonical plant is removed FROM THE LINE, so a line quoting a known fake is exempt while a
#      line quoting a known fake NEXT TO a real DSN is not (suite E). Measured: 52 raw hits fall
#      to 13, a 75% cut, with no class narrowed and nothing hand-listed.
#   2. A HAND-CHECKED ALLOWLIST for the residue, keyed on file + class + a DIGEST of the line, so
#      it survives a line move, reddens on an edit, and NEVER PRINTS THE MATCHED TEXT -- a secret
#      scanner that echoes its hits into a CI log has moved the exposure rather than closed it.
#      It holds ZERO entries today and the count is PINNED, so growing it is a reviewed act.
# Suite F asserts the three residual false-positive CLASSES that remain, by name, so the cost of
# this check is measured in the suite rather than asserted in a comment.
#
# THE MUTATION BATTERY, AND THE ONE MUTATION DECLARED TO SURVIVE -- because a battery where
# everything reddens cannot tell coverage from a rubber stamp. Full matrix in the PR. The
# SURVIVOR is the `String(text)` coercion in findCredentialMaterialInText: every caller today
# reads its input with readFileSync(..., "utf8") and hands over a string already, so removing the
# coercion changes no verdict. That is a THEOREM about the callers, not lost coverage, and it
# stops being one the day a caller passes a Buffer -- at which point it needs a cell, exactly the
# way #71's `<root>` theorem needed one and got it in suite G below.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

STORE="$SCRIPTS_DIR/knowledge-store.mjs"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
STATUS_SUITE="$TESTS_DIR/test-status-schema-contract.sh"

make_temp_project || exit 90

# THE CANONICAL PLANT SET, extracted from AC-52c's own plant document rather than restated here.
# A restatement would be a third copy of the fixtures, free to drift; this way a plant that
# changes in that suite changes the exemption here in the same commit. The heredoc is
# single-quoted, so what sed lifts is the literal JSON the suite writes to disk.
PLANTS_JSON="$(sed -n "/<<'PLANT'/,/^PLANT\$/p" "$STATUS_SUITE" | sed '1d;$d')"

# The scanner, shared by every case below. It takes a DIRECTORY and reports the partition, the
# measurement, and the surviving hits by file + class + line-digest.
SIDECAR_SCAN="$TEMP_PROJECT/sidecar-scan.mjs"
cat > "$SIDECAR_SCAN" <<'NODE'
import { readdirSync, readFileSync, statSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
const { findCredentialMaterial, findCredentialMaterialInText } = await import(process.env.STORE_URL);
const DIR = process.env.SCAN_DIR;
// NEGATIVE_* rows are the plant document's own negative controls, not plants; excluding them is
// what keeps this exemption from quietly whitelisting a git SHA.
const plants = Object.entries(JSON.parse(process.env.PLANTS_JSON))
  .filter(([k, v]) => typeof v === "string" && v && !k.startsWith("NEGATIVE_") && k !== "current_phase")
  .map(([, v]) => v);
const entries = existsSync(DIR) ? readdirSync(DIR).sort() : [];
const dirs = [], json = [], text = [], unreadable = [];
for (const e of entries) {
  if (statSync(`${DIR}/${e}`).isDirectory()) { dirs.push(e); continue; }
  (e.endsWith(".json") ? json : text).push(e);
}
let bytes = 0, lines = 0, raw = 0;
const hits = [], locs = [];
for (const e of text) {
  let body;
  try { body = readFileSync(`${DIR}/${e}`, "utf8"); } catch { unreadable.push(e); continue; }
  bytes += Buffer.byteLength(body);
  const r = findCredentialMaterialInText(body);
  lines += r.scanned;
  for (const h of r.hits) {
    raw++;
    // THE PLANT-STRIP, applied to the LINE and re-scanned rather than used as a line-level
    // whitelist: a canonical fake standing beside a real credential must still be reported.
    const stripped = plants.reduce((s, p) => s.split(p).join(" "), h.text);
    if (!findCredentialMaterial(stripped).hits.some((x) => x.class === h.class)) continue;
    // The line's DIGEST, never its text. A secret scanner that prints its hits into a CI log has
    // moved the exposure, not closed it. The digest is a stable allowlist key and a reader who
    // needs the content opens the file at the line number reported beside it.
    const digest = createHash("sha1").update(h.text).digest("hex").slice(0, 12);
    hits.push(`${e} [${h.class}] ${digest}`);
    locs.push(`${e}:${h.line} [${h.class}] ${digest}`);
  }
}
process.stdout.write(
  `entries=${entries.length}\njson=${json.length}\ntext=${text.length}\ndirs=${dirs.join(" ")}\n` +
  `unreadable=${unreadable.join(" ")}\nbytes=${bytes}\nlines=${lines}\nplants=${plants.length}\n` +
  `raw=${raw}\nhits=${hits.join(" ;; ")}\nlocs=${locs.join(" ;; ")}\n`);
NODE

scan() {
  SCAN_DIR="$1" STORE_URL="file://$STORE" PLANTS_JSON="$PLANTS_JSON" node "$SIDECAR_SCAN" 2>&1
}
sfield() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }


# =============================================================================
suite "#125: every committed file in knowledge/issue-archive/ is reached by SOME reader"
# =============================================================================
# THE DURABLE RATCHET, and it matters more than the scan itself. A check that reads what RAN
# cannot see what never ran: both existing controls are scoped to `.json`, and nothing anywhere
# asked whether the DIRECTORY held anything else. This partition is derived from the directory
# LISTING -- configuration, not history -- so a `.yaml` sidecar nobody has thought of yet lands in
# the text half automatically, and a shape neither half can read (a subdirectory) is a failure
# rather than a silence.
CORPUS="$(scan "$REPO_ROOT/knowledge/issue-archive")"
assert_eq "VACUITY: the partition scan produced a report" \
  "$([[ -n "$(sfield "$CORPUS" entries)" ]] && echo reported || echo "NO REPORT: $CORPUS")" "reported"
assert_eq "VACUITY: over a non-empty directory" \
  "$([[ "$(sfield "$CORPUS" entries)" -ge 10 ]] && echo enough || echo "only $(sfield "$CORPUS" entries) entries")" "enough"
assert_eq "VACUITY: the JSON half (AC-52c's population) is non-empty" \
  "$([[ "$(sfield "$CORPUS" json)" -ge 5 ]] && echo enough || echo "only $(sfield "$CORPUS" json) json files")" "enough"
assert_eq "VACUITY: and the raw-text half is non-empty, which is the half #125 is about" \
  "$([[ "$(sfield "$CORPUS" text)" -ge 1 ]] && echo enough || echo "ZERO sidecars: this suite would range over nothing")" "enough"
assert_eq "the two populations PARTITION the directory: nothing is in neither" \
  "$(( $(sfield "$CORPUS" json) + $(sfield "$CORPUS" text) ))" "$(sfield "$CORPUS" entries)"
# A SUBDIRECTORY IS A SHAPE NOBODY HAS DECIDED ABOUT. Neither reader can take one, so it must
# surface as a decision rather than be silently counted into the text half and then fail to read.
assert_eq "no entry is a DIRECTORY (a new shape needs a decision, not a silent skip)" \
  "$(sfield "$CORPUS" dirs)" ""
assert_eq "and every text-half member was readable" "$(sfield "$CORPUS" unreadable)" ""
# THE SEAM WITH AC-52c. If that suite ever widens its glob past *.json, this partition starts
# DOUBLE-covering and its vacuity assertion starts reddening on an unparseable sidecar -- the
# exact failure #125 says to avoid. Pinned so the widening cannot happen quietly.
assert_eq "AC-52c's population is still the *.json glob, so the two halves stay disjoint" \
  "$(grep -c "ls -1 knowledge/issue-archive/\*\.json" "$STATUS_SUITE" | tr -d ' ')" "1"
record "MEASURED at this commit: $(sfield "$CORPUS" entries) entries = $(sfield "$CORPUS" json) json + $(sfield "$CORPUS" text) sidecars, $(sfield "$CORPUS" bytes) bytes / $(sfield "$CORPUS" lines) lines of raw text"


# =============================================================================
suite "#125: the raw-text scan over the REAL committed sidecars"
# =============================================================================
# THE HAND-CHECKED ALLOWLIST. EMPTY, and the emptiness is PINNED rather than left implicit: an
# allowlist that can grow without anyone noticing is how a stale exemption lives forever. To add
# one: open the file at the line number the failure prints, hand-check the hit, then add
# `<file> [<class>] <digest>` here AND raise the count below. Both edits are visible in a diff,
# which is the point.
SIDECAR_ALLOW=""
SIDECAR_ALLOW_N=0

assert_eq "VACUITY: the scan actually read bytes (a zero over an empty walk is not a result)" \
  "$([[ "$(sfield "$CORPUS" bytes)" -ge 100000 ]] && echo read || echo "only $(sfield "$CORPUS" bytes) bytes")" "read"
assert_eq "VACUITY: and inspected lines" \
  "$([[ "$(sfield "$CORPUS" lines)" -ge 1000 ]] && echo inspected || echo "only $(sfield "$CORPUS" lines) lines")" "inspected"
assert_eq "VACUITY: with the canonical plant set actually extracted (an empty set would silently widen this)" \
  "$([[ "$(sfield "$CORPUS" plants)" -ge 10 ]] && echo extracted || echo "only $(sfield "$CORPUS" plants) plants: the sed in this suite matched nothing")" "extracted"
CORPUS_UNEXPECTED="$(printf '%s\n' "$(sfield "$CORPUS" hits)" | sed 's/ ;; /\n/g' | sed 's/^ *//;s/ *$//' \
  | grep -v '^$' | { [[ -n "$SIDECAR_ALLOW" ]] && grep -vxF "$SIDECAR_ALLOW" || cat; } | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "no unallowlisted credential-shaped line in any committed sidecar" "$CORPUS_UNEXPECTED" ""
assert_eq "  and the hand-checked allowlist still holds exactly $SIDECAR_ALLOW_N entries" \
  "$(printf '%s\n' "$SIDECAR_ALLOW" | grep -c . | tr -d ' ')" "$SIDECAR_ALLOW_N"
# EVERY ALLOWLIST ENTRY MUST STILL HAVE A SUBJECT. Vacuous while the list is empty, live the
# moment it is not -- an exemption protecting nothing is how a suite keeps a stale one forever.
ALLOW_ORPHANS=""
if [[ -n "$SIDECAR_ALLOW" ]]; then
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    printf '%s\n' "$(sfield "$CORPUS" hits)" | sed 's/ ;; /\n/g' | grep -qxF "$entry" \
      || ALLOW_ORPHANS="$ALLOW_ORPHANS $entry"
  done < <(printf '%s\n' "$SIDECAR_ALLOW")
fi
assert_eq "  and no allowlist entry has lost its subject (a moved hit needs re-checking, not deleting)" \
  "${ALLOW_ORPHANS:-none}" "none"
# THE LOCATIONS, printed only when there is something to print, so a red run is actionable
# without the suite ever echoing a credential into the log.
if [[ -n "$CORPUS_UNEXPECTED" ]]; then
  printf '        locations: %s\n' "$(sfield "$CORPUS" locs)"
  printf '        Open each file at that line, hand-check it, and either redact it (AMEND the\n'
  printf '        commit; a fix-forward does not remove it from history) or add its\n'
  printf '        "<file> [<class>] <digest>" key to SIDECAR_ALLOW above and raise the count.\n'
fi


# =============================================================================
suite "#125 NON-ZERO CONTROL: one cell per class, in a .md and in a .sh"
# =============================================================================
# A scan that has never reported anything is indistinguishable from one that cannot. Eleven
# classes, eleven cells: a control that fires on one class says nothing about the other ten, and
# #52's own measurement is the precedent -- its DB-URL class MISSED `pg://` while the suite
# around it looked green. BOTH EXTENSIONS are planted, because the population is both and a
# control proven through one is an example again.
new_tmpdir || exit 90
PLANT_DIR="$NEW_TMPDIR/issue-archive"
mkdir -p "$PLANT_DIR"
cat > "$PLANT_DIR/900-qa-battery-record.md" <<'MD'
# QA battery record for #900
line two, deliberately ordinary
aws_akid AKIAIOSFODNN7EXAMPLE
github_pat ghp_012345678901234567890123456789012345
slack_token xoxb-123456789012-abcdefghijkl
sk_key sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFF
bearer Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345
jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk
MD
cat > "$PLANT_DIR/900-verify-900.sh" <<'SH'
#!/usr/bin/env bash
# pem_private -----BEGIN RSA PRIVATE KEY-----
# db_url_creds psql pg://u:p4ssw0rdlong@h/db
export DATABASE_PASSWORD=s3cr3tvalue
api_key = 'aVeryLongLookingKey123456'
echo Zm9vYmFyQmF6MTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1A=
SH
# The plant document's own strings are the CANONICAL fakes, so the plant-strip would exempt every
# one of them. That is correct behaviour and it would also make this control vacuous, so the
# control runs with an EMPTY plant set -- the exemption gets its own suite (E) below.
PLANT_REPORT="$(SCAN_DIR="$PLANT_DIR" STORE_URL="file://$STORE" PLANTS_JSON='{}' node "$SIDECAR_SCAN" 2>&1)"
PLANT_HITS="$(sfield "$PLANT_REPORT" locs)"
assert_eq "VACUITY: the control scan read both planted sidecars" "$(sfield "$PLANT_REPORT" text)" "2"
assert_eq "  and inspected their lines" \
  "$([[ "$(sfield "$PLANT_REPORT" lines)" -ge 12 ]] && echo inspected || echo "only $(sfield "$PLANT_REPORT" lines)")" "inspected"
for cls in aws_akid github_pat slack_token sk_key bearer jwt pem_private db_url_creds env_line assignment high_entropy; do
  assert_contains "NON-ZERO CONTROL: the [$cls] class fires on its planted sidecar line" \
    "$PLANT_HITS" "[$cls]"
done
# BOTH EXTENSIONS, named, so "eleven classes fired" cannot be satisfied by the .md alone.
assert_contains "  and the .md half is covered" "$PLANT_HITS" "900-qa-battery-record.md:"
assert_contains "  and the .sh half is covered" "$PLANT_HITS" "900-verify-900.sh:"
# THE LINE NUMBER IS RIGHT, not merely present: an off-by-one makes every hand-check start in the
# wrong place. `aws_akid` sits on line 3 of the .md by construction.
assert_contains "  and the reported line number is the real one (line 3 of the .md)" \
  "$PLANT_HITS" "900-qa-battery-record.md:3 [aws_akid]"
# THE PROPERTY THAT MAKES THIS A SEPARATE READER: the file it just scanned is not JSON, so
# AC-52c's population could not have contained it without its vacuity assertion reddening.
assert_eq "  and the file it scanned would BREAK a JSON walk, which is why this reader exists" \
  "$(node -e 'try { JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write("parsed"); } catch { process.stdout.write("unparseable"); }' "$PLANT_DIR/900-verify-900.sh")" \
  "unparseable"


# =============================================================================
suite "#125 NEGATIVE CONTROL: the scanner discriminates"
# =============================================================================
# Without these, "no hits in the corpus" measures luck: a scanner that fires on everything passes
# every cell above. This repo's records quote git SHAs everywhere, so the two SHA cells are what
# the entropy class's mixed-case-and-digit lookaheads are FOR -- widen that class and they redden.
new_tmpdir || exit 90
NEG_DIR="$NEW_TMPDIR/issue-archive"
mkdir -p "$NEG_DIR"
cat > "$NEG_DIR/901-qa-battery-record.md" <<'MD'
NEGATIVE_bare_sha 2ec6dd73931c16922ea299db73bdc4be96912deb
NEGATIVE_sha_in_prose reviewed at 2ec6dd73931c16922ea299db73bdc4be96912deb (origin/main), blob sha256 82bce3d843e89fb6953211e90de2be301bc2c7f125ca3ec465c578f0ac301ff0 unchanged
NEGATIVE_slash_prose imports ENTRY/EXIT/UNGUARDED/TERMINAL/satisfyingTokens from the drift suite
NEGATIVE_ordinary the 600-char note recording a live reproduction is correct work
MD
NEG_REPORT="$(SCAN_DIR="$NEG_DIR" STORE_URL="file://$STORE" PLANTS_JSON='{}' node "$SIDECAR_SCAN" 2>&1)"
assert_eq "VACUITY: the negative fixture was actually scanned" \
  "$([[ "$(sfield "$NEG_REPORT" lines)" -ge 4 ]] && echo scanned || echo "only $(sfield "$NEG_REPORT" lines) lines")" "scanned"
assert_eq "a bare git SHA, a SHA in prose, slash-separated prose and ordinary prose are NOT reported" \
  "$(sfield "$NEG_REPORT" raw)" "0"


# =============================================================================
suite "#125: the plant-strip exemption, and the control that keeps it honest"
# =============================================================================
# The exemption is DERIVED from AC-52c's plant document, not listed here, so a plant that changes
# there changes this in the same commit. And it strips the LINE and re-scans rather than
# whitelisting the line, so a known fake standing beside an unknown one is still reported.
new_tmpdir || exit 90
EX_DIR="$NEW_TMPDIR/issue-archive"
mkdir -p "$EX_DIR"
cat > "$EX_DIR/902-qa-battery-record.md" <<'MD'
CANONICAL: the battery planted pg://u:p4ssw0rdlong@h/db and watched it fire
MIXED: pg://u:p4ssw0rdlong@h/db fired, and so did pg://svc:hunter2hunter2@db.internal/app
NEARMISS: pg://u:p4ssw0rdlonG@h/db is one character off the canonical fake
MD
EX_REPORT="$(SCAN_DIR="$EX_DIR" STORE_URL="file://$STORE" PLANTS_JSON="$PLANTS_JSON" node "$SIDECAR_SCAN" 2>&1)"
EX_LOCS="$(sfield "$EX_REPORT" locs)"
assert_eq "VACUITY: all three lines were scanned and all three fired before the exemption" \
  "$(sfield "$EX_REPORT" raw)" "3"
assert_not_contains "a line quoting ONLY a canonical hand-checked plant is exempt" \
  "$EX_LOCS" "902-qa-battery-record.md:1"
assert_contains "CONTROL: a canonical plant standing beside an UNKNOWN DSN is still reported" \
  "$EX_LOCS" "902-qa-battery-record.md:2"
assert_contains "CONTROL: a one-character near-miss of the canonical plant is still reported" \
  "$EX_LOCS" "902-qa-battery-record.md:3"
assert_eq "  so the exemption removes exactly one of the three, not the line and not the class" \
  "$(printf '%s\n' "$EX_LOCS" | sed 's/ ;; /\n/g' | grep -c . | tr -d ' ')" "2"
# THE FAIL DIRECTION OF THE EXEMPTION ITSELF: if the extraction ever breaks, the exemption
# vanishes and the scan gets NOISIER, never quieter. Asserted with an empty plant set.
EX_NOPLANTS="$(SCAN_DIR="$EX_DIR" STORE_URL="file://$STORE" PLANTS_JSON='{}' node "$SIDECAR_SCAN" 2>&1)"
assert_eq "a BROKEN plant extraction fails SAFE: every hit comes back, none is lost" \
  "$(printf '%s\n' "$(sfield "$EX_NOPLANTS" locs)" | sed 's/ ;; /\n/g' | grep -c . | tr -d ' ')" "3"


# =============================================================================
suite "#125: the residual FALSE-POSITIVE classes, measured rather than claimed"
# =============================================================================
# #125 warns that a noisy check gets switched off, so the noise is measured here instead of being
# reasoned about in a comment. These three shapes fire and are NOT secrets. They are the cost of
# this check, they survive the plant-strip, and the remedy is a hand-checked allowlist entry --
# NOT a narrowed class, which would blunt the guard for the JSON half too, since the table is
# shared.
#
# WHEN ONE OF THESE CELLS GOES RED, the class stopped firing on that shape. That is a NARROWING of
# the shared table and it needs checking against #71's suite, not a green light here.
new_tmpdir || exit 90
FP_DIR="$NEW_TMPDIR/issue-archive"
mkdir -p "$FP_DIR"
cat > "$FP_DIR/903-verify-903.sh" <<'SH'
archive 760 "$FIXDIR" "$FIXROOT" "PIPELINE_ARCHIVE_ALLOW_CREDENTIAL_SHAPES=1"
R_ALLKEYS=$(make_repo_with allkeys '{"checkCommand":"npm test"}')
assert_eq "Flyway" "apps/web/src/main/resources/db/migration/V1__init.sql" "true"
SH
FP_REPORT="$(SCAN_DIR="$FP_DIR" STORE_URL="file://$STORE" PLANTS_JSON="$PLANTS_JSON" node "$SIDECAR_SCAN" 2>&1)"
FP_LOCS="$(sfield "$FP_REPORT" locs)"
assert_contains "FALSE POSITIVE 1: documenting the override env var with its =1 fires [env_line]" \
  "$FP_LOCS" "903-verify-903.sh:1 [env_line]"
assert_contains "FALSE POSITIVE 2: an ordinary shell variable named R_ALLKEYS fires [env_line]" \
  "$FP_LOCS" "903-verify-903.sh:2 [env_line]"
assert_contains "FALSE POSITIVE 3: a long slash-separated FILE PATH fires [high_entropy]" \
  "$FP_LOCS" "903-verify-903.sh:3 [high_entropy]"
record "COST OF THIS CHECK: 52 raw hits over this repo's 79 committed .md/.sh files (38,493 lines), 13 after the plant-strip, 0 real secrets; the sidecar population itself is at 0"


# =============================================================================
suite "#125: #71's <root> theorem, retired -- this is the caller it named"
# =============================================================================
# #71's battery declared the `p || \"<root>\"` fallback in findCredentialMaterial an EXPECTED
# SURVIVOR: archiveIssue always hands that function an OBJECT, so a string leaf is never at path
# \"\", and no mutation to that literal could change a verdict. Its declaration wrote down the
# condition that would end it -- \"if a caller is ever added that hands it a bare string, this
# stops being a theorem and needs a cell\". findCredentialMaterialInText is that caller. This is
# the cell.
ROOT_PATH="$(STORE_URL="file://$STORE" node --input-type=module -e '
  const { findCredentialMaterial } = await import(process.env.STORE_URL);
  const bare = findCredentialMaterial("AKIAIOSFODNN7EXAMPLE");
  const wrapped = findCredentialMaterial({ a: "AKIAIOSFODNN7EXAMPLE" });
  process.stdout.write(bare.hits[0].path + " | " + wrapped.hits[0].path + " | " + bare.scanned);')"
assert_eq "a BARE STRING reports the <root> path, so the branch #71 called a theorem is live" \
  "$ROOT_PATH" "<root> | .a | 1"
assert_eq "  and the shipped text pass is the caller that reaches it" \
  "$(grep -c 'findCredentialMaterial(lines\[i\])' "$STORE" | tr -d ' ')" "1"
# ASSERTED POSITIVELY, not as an absence. #71's battery record is kept rather than deleted -- the
# seven mutations that reddened are still the record of what it covered -- so what must be true is
# that the entry is marked RETIRED and points at the cell above. An absence check would also be
# satisfied by somebody deleting the paragraph, and it would fire on a note that merely QUOTED the
# old wording, which is the quotation-versus-claim failure this repo has already shipped once.
CRED_SUITE_HDR="$(sed -n '1,60p' "$TESTS_DIR/test-archive-credential-guard.sh")"
assert_contains "  and #71's own record marks that survivor RETIRED rather than leaving it standing" \
  "$CRED_SUITE_HDR" "RETIRED BY #125"
assert_contains "  and points at the cell that replaced it, so the claim is followable" \
  "$CRED_SUITE_HDR" "test-archive-sidecar-scan.sh"


# =============================================================================
suite "#125: ONE class table, two readers -- the JSON walk and the text walk agree"
# =============================================================================
# The text pass calls findCredentialMaterial per line rather than re-deriving the regexes, so
# there is no second table to drift. Asserted rather than left to the reader of the source: the
# two entry points are driven over the SAME strings and their class sets compared.
SEAM="$(PLANTS_JSON="$PLANTS_JSON" STORE_URL="file://$STORE" node --input-type=module -e '
  const { findCredentialMaterial, findCredentialMaterialInText } = await import(process.env.STORE_URL);
  const doc = JSON.parse(process.env.PLANTS_JSON);
  const viaJson = [...new Set(findCredentialMaterial(doc).hits.map((h) => h.class))].sort();
  const text = Object.values(doc).filter((v) => typeof v === "string").join("\n");
  const viaText = [...new Set(findCredentialMaterialInText(text).hits.map((h) => h.class))].sort();
  process.stdout.write("json=" + viaJson.join(",") + "\ntext=" + viaText.join(",") +
    "\nn=" + viaJson.length + "\n");')"
assert_eq "VACUITY: the seam probe fired at all" \
  "$([[ "$(sfield "$SEAM" n)" -ge 10 ]] && echo fired || echo "only $(sfield "$SEAM" n) classes fired: $SEAM")" "fired"
assert_eq "the JSON walk and the raw-text walk report the SAME class set over the same strings" \
  "$(sfield "$SEAM" text)" "$(sfield "$SEAM" json)"
# And the shipped table is still the full eleven, pinned by value so a trim is visible from here
# too -- test-archive-credential-guard.sh pins the same number against AC-52c's copy.
assert_eq "  and the shipped table is still eleven classes" \
  "$(sed -n '/^const CREDENTIAL_CLASSES = \[/,/^\];/p' "$STORE" | sed -n 's/^  \["\([a-z_]*\)".*/\1/p' | grep -c . | tr -d ' ')" "11"

finish
