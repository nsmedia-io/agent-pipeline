#!/usr/bin/env bash
# materiality.mjs --explain <cost_class> (#164 row 18).
#
# evidence.md and the Phase 4 preamble each restated which ratings block and the per-reviewer cap,
# beside the code that applies the rule. Reviewers rated against the copy. The table is now printed
# from rateConcern itself, and both prose sites point at the call. These cells pin the table's
# cells against the rule as it was written before the move (so the move changed nothing about what
# blocks), every exit code, and that the restatements stay removed.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

MAT="$SCRIPTS_DIR/materiality.mjs"
EVID="$PLUGIN_ROOT/evidence.md"
PRE="$PLUGIN_ROOT/orchestrator/phase-4-panel-preamble.md"

make_temp_project || exit 90

mx() {
  node "$MAT" "$@" >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}
# cell <cost_class> <merge_class> <likelihood> -> BLOCKS or note, read from the --json table.
cell() {
  node "$MAT" --explain "$1" --json | node -e '
    const t = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const row = t.rows.find((r) => r.merge_class === process.argv[1]);
    console.log(row ? row.cells[t.likelihoods.indexOf(process.argv[2])] : "NO-ROW");
  ' "$2" "$3"
}

# THE RULE AS IT WAS WRITTEN. normal-use blocks for every class but none; edge-case only at
# product-money; adversarial only for security-exposure; hypothetical never; tooling only
# wrong-pass and security-exposure. One cell per clause, and each clause has its control.
suite "materiality --explain: the table matches the rule it replaced"

assert_eq "product: normal-use data-loss BLOCKS" "$(cell product data-loss normal-use)" "BLOCKS"
assert_eq "product: edge-case data-loss is a note" "$(cell product data-loss edge-case)" "note"
assert_eq "product-money: edge-case data-loss BLOCKS" "$(cell product-money data-loss edge-case)" "BLOCKS"
assert_eq "product: adversarial security-exposure BLOCKS" "$(cell product security-exposure adversarial)" "BLOCKS"
assert_eq "CONTROL: product: adversarial money is a note" "$(cell product money adversarial)" "note"
assert_eq "product-money: hypothetical security-exposure is a note" "$(cell product-money security-exposure hypothetical)" "note"
assert_eq "product: normal-use none is a note" "$(cell product none normal-use)" "note"
assert_eq "tooling: normal-use money is a note" "$(cell tooling money normal-use)" "note"
assert_eq "tooling: normal-use wrong-pass BLOCKS" "$(cell tooling wrong-pass normal-use)" "BLOCKS"
assert_eq "tooling: normal-use security-exposure BLOCKS" "$(cell tooling security-exposure normal-use)" "BLOCKS"

# THE TEXT FORM AND THE EXIT CODES. The text names the cost class, the cap and the verdict
# re-reading, so a reviewer holding only the printout has the whole rule. An unknown cost class or
# a missing argument is exit 1, never a table for a default class the caller did not ask for.
suite "materiality --explain: text and exit codes"

mx --explain product
assert_eq "a known cost_class: exit 0" "$RC" "0"
assert_contains "the heading names the class" "$OUT" "Materiality at cost_class product:"
assert_contains "the cap is printed from BLOCKING_CAP" "$OUT" "at most 2 blocking concerns per reviewer"
assert_contains "and the VETO re-reading" "$OUT" "VETO stands only from SecOps"
mx --explain spaceship
assert_eq "an unknown cost_class: exit 1" "$RC" "1"
assert_contains "and it lists the known ones" "$ERR" "product-money, product, tooling"
mx --explain
assert_eq "--explain with no class: exit 1" "$RC" "1"
mx
assert_eq "no arguments: exit 1" "$RC" "1"
IMPORTED="$(node --input-type=module -e 'const m = await import(process.argv[1]); console.log(typeof m.rateConcern)' "$MAT" 2>&1)"
assert_eq "importing the module does not run the CLI (the merge imports it)" "$IMPORTED" "function"

# THE PROSE. evidence.md and the preamble point at the call; the restated predicate and cap are gone.
suite "the restatements are gone and the call replaces them"

assert_contains "evidence.md points at --explain" "$(cat "$EVID")" 'scripts/materiality.mjs" --explain <cost_class>'
assert_not_contains "evidence.md no longer restates the blocking predicate" "$(cat "$EVID")" "likelihood \`normal-use\`. The run's \`cost_class\`"
assert_not_contains "evidence.md no longer restates the cap" "$(cat "$EVID")" "At most two blocking concerns per reviewer, enforced."
assert_contains "the preamble points at --explain" "$(cat "$PRE")" "scripts/materiality.mjs --explain"
assert_not_contains "the preamble no longer restates the predicate" "$(cat "$PRE")" "A concern BLOCKS only when its severity is blocker/critical/high"
assert_not_contains "the preamble no longer restates the cap" "$(cat "$PRE")" "at most TWO stay blockers"

finish
