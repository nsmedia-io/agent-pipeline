#!/usr/bin/env bash
# extract-constraints.mjs: the Phase 2-lite constraint checklists (#164 row 19).
#
# THE BUG. The prose's sed loop appended each role's marker block to one file and halted only on
# an EMPTY file. With one role's markers missing the other roles still land, the file is not
# empty, and Phase 3 is dispatched short a specialist. The first cells run that old loop on the
# same fixture, so the regression cells are shown to separate the two behaviours.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

EC="$SCRIPTS_DIR/extract-constraints.mjs"
LITE="$PLUGIN_ROOT/orchestrator/phase-2-lite.md"

make_temp_project || exit 90
AG="$TEMP_PROJECT/agents"
mkdir -p "$AG"
block() { printf '# %s\n\n<!-- BEGIN STANDARD-TIER CONSTRAINTS (%s) -->\n- %s rule one\n<!-- END STANDARD-TIER CONSTRAINTS (%s) -->\n\ntail\n' "$1" "$1" "$1" "$1" > "$AG/$1.md"; }
block dba; block devops; block secops

# ec <args...> -> RC, OUT, ERR
ec() {
  ( cd "$TEMP_PROJECT" && node "$EC" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}
old_loop() {  # the removed prose, verbatim apart from the agents dir
  local CONSTRAINTS="$1" role
  : > "$CONSTRAINTS"
  for role in dba devops secops; do
    sed -n '/<!-- BEGIN STANDARD-TIER CONSTRAINTS/,/<!-- END STANDARD-TIER CONSTRAINTS/p' \
      "$AG/$role.md" >> "$CONSTRAINTS"
    printf '\n' >> "$CONSTRAINTS"
  done
}

suite "extract-constraints: every role present"

old_loop "$TEMP_PROJECT/old.md"
ec --out "$TEMP_PROJECT/new.md" --agents-dir "$AG"
assert_eq "all markers present exits 0" "$RC" "0"
assert_eq "and the bytes equal what the sed loop produced" "$(cmp -s "$TEMP_PROJECT/old.md" "$TEMP_PROJECT/new.md" && echo same || echo differ)" "same"
assert_contains "and every role's block is in it" "$(cat "$TEMP_PROJECT/new.md")" "secops rule one"
assert_not_contains "and nothing outside the markers" "$(cat "$TEMP_PROJECT/new.md")" "tail"

suite "extract-constraints: one role's markers missing (the bug)"

printf '# devops\n\nno markers here\n' > "$AG/devops.md"
old_loop "$TEMP_PROJECT/old.md"
assert_eq "CONTROL (old behaviour): the sed loop leaves a NON-EMPTY file, so its empty-file halt never fires" \
  "$([[ -s "$TEMP_PROJECT/old.md" ]] && echo non-empty || echo empty)" "non-empty"
ec --out "$TEMP_PROJECT/new.md" --agents-dir "$AG"
assert_eq "REGRESSION: one role's markers missing exits 2" "$RC" "2"
assert_contains "and names the role" "$ERR" "devops: no BEGIN"
assert_eq "and leaves --out empty, so the phase-entry guard refuses it as well" \
  "$([[ -s "$TEMP_PROJECT/new.md" ]] && echo non-empty || echo empty)" "empty"

printf '# secops\n<!-- BEGIN STANDARD-TIER CONSTRAINTS (secops) -->\n- rule\n' > "$AG/secops.md"
ec --out "$TEMP_PROJECT/new.md" --agents-dir "$AG"
assert_eq "two roles missing exits 2" "$RC" "2"
assert_contains "and names the first" "$ERR" "devops:"
assert_contains "and names the second, whose END marker is missing (sed printed to end of file)" "$ERR" "secops: no END"
assert_contains "and the halt line lists both" "$ERR" "missing for devops, secops"

printf '<!-- BEGIN STANDARD-TIER CONSTRAINTS (secops) -->\n\n<!-- END STANDARD-TIER CONSTRAINTS (secops) -->\n' > "$AG/secops.md"
block devops
ec --out "$TEMP_PROJECT/new.md" --agents-dir "$AG"
assert_eq "an empty block between the markers exits 2" "$RC" "2"
assert_contains "and says the block is empty" "$ERR" "secops: the block between the markers is empty"

rm -f "$AG/dba.md"
block secops
ec --out "$TEMP_PROJECT/new.md" --agents-dir "$AG"
assert_eq "a missing agent file exits 2" "$RC" "2"
assert_contains "and names the role" "$ERR" "dba:"

suite "extract-constraints: usage and the shipped agent files"

ec --agents-dir "$AG"
assert_eq "no --out is usage (1)" "$RC" "1"
ec --out "$TEMP_PROJECT/x.md" --what
assert_eq "an unknown flag is usage (1)" "$RC" "1"
ec --out "$TEMP_PROJECT/shipped.md"
assert_eq "the plugin's own dba, devops and secops files extract cleanly (0)" "$RC" "0"
assert_contains "and carry the secops block" "$(cat "$TEMP_PROJECT/shipped.md")" "END STANDARD-TIER CONSTRAINTS (secops)"

suite "extract-constraints: the prose calls the script, and the sed loop stays removed"

L="$(cat "$LITE")"
assert_contains "phase-2-lite.md calls extract-constraints.mjs" "$L" 'scripts/extract-constraints.mjs" --out "$ARTIFACT_DIR/constraints.md"'
assert_contains "and halts on exit 2" "$L" "Exit 2 names every role whose markers are missing"
assert_not_contains "the sed extraction is gone" "$L" "sed -n"
assert_not_contains "the empty-file halt rule is gone" "$L" "If extraction produces an empty file"

finish
