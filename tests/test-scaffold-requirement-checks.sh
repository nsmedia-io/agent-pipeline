#!/usr/bin/env bash
# scaffold-requirement-checks.mjs: the coverage skeleton Dev fills (#164 row 24).
#
# dev.md step 8 described the requirement_checks shape and the gate's own-label rule in prose, and
# a Dev who missed a label learned it when gate-pre-phase4.mjs halted a round later. The skeleton
# is now printed from spec.json with ac_id set by the gate's own criterionLabel. These cells pin
# the shape, the label rule's cases, that a filled skeleton passes the gate's coverage while the
# unfilled one cannot pass the schema, every exit code, and that dev.md calls the script.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

SC="$SCRIPTS_DIR/scaffold-requirement-checks.mjs"
DEV="$PLUGIN_ROOT/agents/dev.md"

make_temp_project 12 || exit 90
SPEC="$TEMP_ISSUE_DIR/spec.json"
SK="$TEMP_PROJECT/skeleton.json"

sc() {
  ( cd "$TEMP_PROJECT" && node "$SC" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}
jq_() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(eval("j"+process.argv[2])))' "$SK" "$1"; }

LONG="AC9: the roster rotates on the hour and never assigns one courier to two overlapping deliveries at once"
cat > "$SPEC" <<EOF
{"requirements":["$LONG","plain requirement","Keep the fallback path, unlike AC3 which changes it"],
 "acceptance_criteria":["AC1. leading label","the roster rotates (AC4)","unlike AC1, AC3 is ambiguous","no label at all"]}
EOF

# THE SHAPE AND THE LABEL RULE. One check per requirement with its index and first 80 characters;
# one criterion entry per criterion. A leading label and a single trailing label both set ac_id;
# two labels with none leading, or none at all, leave it unset, exactly as the gate reads them.
# A REQUIREMENT answers only with its own leading label: one that mentions a label mid-sentence
# must not claim it.
suite "scaffold: shape and labels"

sc --spec "$SPEC"
assert_eq "a spec: exit 0" "$RC" "0"
printf '%s' "$OUT" > "$SK"
assert_eq "one check per requirement" "$(jq_ '.requirement_checks.length')" "3"
assert_eq "requirement_index is the position" "$(jq_ '.requirement_checks[1].requirement_index')" "1"
assert_eq "requirement_text is the first 80 characters" "$(jq_ '.requirement_checks[0].requirement_text.length')" "80"
assert_eq "a requirement's own label sets its ac_id" "$(jq_ '.requirement_checks[0].ac_id')" '"AC9"'
assert_eq "an unlabelled requirement has none" "$(jq_ '.requirement_checks[1].ac_id')" "undefined"
assert_eq "a requirement that only MENTIONS a label gets no ac_id (the gate would count it as covering AC3)" "$(jq_ '.requirement_checks[2].ac_id')" "undefined"
assert_eq "a leading criterion label: AC1" "$(jq_ '.acceptance_criteria_met[0].ac_id')" '"AC1"'
assert_eq "a single trailing label: AC4" "$(jq_ '.acceptance_criteria_met[1].ac_id')" '"AC4"'
assert_eq "two labels, none leading: no ac_id" "$(jq_ '.acceptance_criteria_met[2].ac_id')" "undefined"
assert_eq "no label: no ac_id" "$(jq_ '.acceptance_criteria_met[3].ac_id')" "undefined"
assert_eq "and the unlabelled count says so" "$(jq_ '.unlabelled_criteria')" "2"
assert_eq "status is left null for Dev" "$(jq_ '.requirement_checks[0].status')" "null"

# AGAINST THE GATE. The skeleton, with only its blanks filled, covers every criterion under the
# gate's own coverageVerdict. The unfilled skeleton fails the impl-report schema's status enum, so
# it cannot be mistaken for a filled one. The gate path is argv[2], not argv[1]: in argv[1] its
# basename would match isMain and the import would run the gate CLI instead of this program.
suite "scaffold: the gate reads it as covered once filled"

GATE="$SCRIPTS_DIR/gate-pre-phase4.mjs"
COVERED="$(node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const g = await import(process.argv[2]);
  const sk = JSON.parse(readFileSync(process.argv[3], "utf8"));
  const spec = JSON.parse(readFileSync(process.argv[4], "utf8"));
  for (const c of sk.requirement_checks) { c.status = "PASS"; c.notes = "unrelated words only"; }
  for (const a of sk.acceptance_criteria_met) { a.met = true; a.evidence = "e"; }
  const cands = g.coverageCandidates(sk);
  console.log(spec.acceptance_criteria.map((c) => g.coverageVerdict(c, cands).covered).join(","));
' not-the-gate "$GATE" "$SK" "$SPEC" 2>&1)"
assert_eq "every criterion is covered" "$COVERED" "true,true,true,true"
STATUS_ENUM="$(node -e 'const s=require(process.argv[1]);console.log(s.properties.requirement_checks.items.properties.status.enum.includes(null))' "$PLUGIN_ROOT/schemas/impl-report.schema.json")"
assert_eq "CONTROL: the schema's status enum does not admit the skeleton's null" "$STATUS_ENUM" "false"

suite "scaffold: exit codes"

printf '{"acceptance_criteria":["AC1. x"]}' > "$TEMP_PROJECT/noreq.json"
sc --spec "$TEMP_PROJECT/noreq.json"
assert_eq "a spec with no requirements array: exit 1" "$RC" "1"
sc --spec "$TEMP_PROJECT/missing.json"
assert_eq "a missing spec: exit 1" "$RC" "1"
sc
assert_eq "no arguments: exit 1" "$RC" "1"
sc --spec "$SPEC" --extra
assert_eq "an extra argument: exit 1" "$RC" "1"

suite "dev.md step 8 calls the script"

assert_contains "step 8 starts from the skeleton" "$(cat "$DEV")" 'scripts/scaffold-requirement-checks.mjs" --spec'
assert_not_contains "the hand field list is gone" "$(cat "$DEV")" '(0-based integer, matching the position in `spec.requirements`)'
assert_not_contains "the restated label rule is gone" "$(cat "$DEV")" "a label mentioned mid-sentence or in \`notes\` covers nothing"

finish
