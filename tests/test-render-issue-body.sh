#!/usr/bin/env bash
# render-issue-body.mjs: the issue body as a render of spec.json, and the drift check (#164 row 23).
#
# ba.md step 8 had BA render the body by hand and diff it by eye on every later round. A ruling
# was once lost for two rounds that way, with both copies well formed. These cells pin the render,
# the round trip, each kind of drift, the gh path through a planted CLI, every exit code, and
# that ba.md calls the script.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

RIB="$SCRIPTS_DIR/render-issue-body.mjs"
BA="$PLUGIN_ROOT/agents/ba.md"
NODE_BIN="$(command -v node)"

make_temp_project 5 || exit 90
SPEC="$TEMP_ISSUE_DIR/spec.json"
BODY="$TEMP_PROJECT/body.md"

rib() {
  ( cd "$TEMP_PROJECT" && node "$RIB" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}

cat > "$SPEC" <<'EOF'
{"issue_number":5,"title":"t","problem":"Couriers get double-booked.","requirements":["Reject a second claim","Log the  refusal"],
 "acceptance_criteria":["AC1. a second claim for one courier is refused","AC2. the refusal is logged"],
 "impacted_domains":["api","data"],"risk_tier":"standard"}
EOF

# THE RENDER AND ITS ROUND TRIP. The printed body carries the spec's sections, and comparing the
# body against the spec it came from is in sync, which is what makes every drift cell below a
# change of one input rather than a formatting mismatch.
suite "render-issue-body: render"

rib --spec "$SPEC"
assert_eq "render: exit 0" "$RC" "0"
assert_contains "requirements are numbered, whitespace collapsed" "$OUT" "2. Log the refusal"
assert_contains "criteria are checkboxes" "$OUT" "- [ ] AC1. a second claim for one courier is refused"
assert_contains "the problem is rendered" "$OUT" "Couriers get double-booked."
printf '%s\n' "$OUT" > "$BODY"
rib --spec "$SPEC" --body-file "$BODY"
assert_eq "the render compared with its own spec: exit 0" "$RC" "0"
assert_contains "and it says IN SYNC with the counts" "$OUT" "IN SYNC: 2 requirement(s) and 2 acceptance criteria"

# DRIFT. A reworded criterion, a body missing a requirement, a body carrying an extra one and a
# body missing a whole section are each exit 2 naming the difference. Checked-off boxes, other
# prose and an indented wrap are not drift.
suite "render-issue-body: drift"

sed 's/is logged/is printed/' "$BODY" > "$TEMP_PROJECT/b1.md"
rib --spec "$SPEC" --body-file "$TEMP_PROJECT/b1.md"
assert_eq "a reworded criterion: exit 2" "$RC" "2"
assert_contains "and both wordings are printed" "$OUT" "the body says:   AC2. the refusal is printed"
grep -v 'Log the refusal' "$BODY" > "$TEMP_PROJECT/b2.md"
rib --spec "$SPEC" --body-file "$TEMP_PROJECT/b2.md"
assert_contains "a requirement missing from the body is named" "$OUT" "in spec.json, missing from the body: Log the refusal"
sed 's/^2\. Log the refusal$/2. Log the refusal\n3. Page the owner/' "$BODY" > "$TEMP_PROJECT/b3.md"
rib --spec "$SPEC" --body-file "$TEMP_PROJECT/b3.md"
assert_contains "an extra requirement in the body is named" "$OUT" "in the body, not in spec.json: Page the owner"
grep -v '^## Acceptance criteria' "$BODY" > "$TEMP_PROJECT/b4.md"
rib --spec "$SPEC" --body-file "$TEMP_PROJECT/b4.md"
assert_eq "a body with no criteria heading: exit 2" "$RC" "2"
assert_contains "and the missing section is named" "$OUT" "Acceptance criteria: section missing"
{ printf 'Owner notes above the render.\n\n'; sed -e 's/- \[ \] AC1/- [x] AC1/' -e 's/^1\. Reject a second claim$/1. Reject a second\n   claim/' "$BODY"; } > "$TEMP_PROJECT/b5.md"
rib --spec "$SPEC" --body-file "$TEMP_PROJECT/b5.md"
assert_eq "CONTROL: a ticked box, an indented wrap and extra prose are not drift" "$RC" "0"

# GH AND EXIT CODES. --compare reads the body through gh; a planted gh stands in for the tracker so
# the cell does not depend on the host. A gh failure is exit 1, never a match.
suite "render-issue-body: --compare and exit codes"

BIN="$TEMP_PROJECT/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\ncat "%s"\n' "$TEMP_PROJECT/b1.md" > "$BIN/gh"
chmod +x "$BIN/gh"
( cd "$TEMP_PROJECT" && PATH="$BIN" "$NODE_BIN" "$RIB" --spec "$SPEC" --compare 5 ) >"$TEMP_PROJECT/o" 2>&1
assert_eq "--compare reads the planted gh body and finds the drift: exit 2" "$?" "2"
printf '#!/bin/sh\necho "HTTP 401" >&2\nexit 1\n' > "$BIN/gh"
( cd "$TEMP_PROJECT" && PATH="$BIN" "$NODE_BIN" "$RIB" --spec "$SPEC" --compare 5 ) >"$TEMP_PROJECT/o" 2>&1
assert_eq "gh failing: exit 1, never in sync" "$?" "1"
assert_contains "and gh's words are carried" "$(cat "$TEMP_PROJECT/o")" "HTTP 401"
rib --spec "$SPEC" --compare five
assert_eq "a non-numeric issue: exit 1" "$RC" "1"
rib --spec "$SPEC" --compare 5 --body-file "$BODY"
assert_eq "--compare and --body-file together: exit 1" "$RC" "1"
rib --spec "$TEMP_PROJECT/missing.json"
assert_eq "a missing spec: exit 1" "$RC" "1"
rib
assert_eq "no arguments: exit 1" "$RC" "1"

suite "ba.md step 8 calls the script"

assert_contains "the body is created from the render" "$(cat "$BA")" 'scripts/render-issue-body.mjs" --spec <spec.json> > body.md'
assert_contains "and later rounds run the compare" "$(cat "$BA")" 'scripts/render-issue-body.mjs" --spec <spec.json> --compare <issue>'
assert_not_contains "the hand render placeholder is gone" "$(cat "$BA")" '...formatted markdown from spec.json...'
assert_not_contains "the hand diff instruction is gone" "$(cat "$BA")" "diff them against the published body"

finish
