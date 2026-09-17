#!/usr/bin/env bash
# gate-pre-phase4.mjs — the EMPTY down region (issue #30, commit B).
#
# BEHAVIOURAL CONTRACT, authored at Phase 3a before the implementation exists.
#
# SEPARATE FILE ON PURPOSE. Commit B is the only requirement in #30 that NARROWS what the
# gate accepts, and it is the one item carrying its own DBA ruling. Keeping its contract in
# its own suite is what makes a Phase 4 REQUEST_CHANGES on B surgically revertable without
# touching commit A's classifier contract (spec E1).
#
# THE RULE (spec B1, DBA's YES on Q-DBA-1). In this project a down region is DOCUMENTATION,
# not executable SQL, so an empty region does not mean "nothing to roll back" -- it means
# nobody wrote the one sentence saying what the operator does at 3am. The requirement is AT
# LEAST ONE NON-BLANK COMMENT LINE. It is NOT a length test: see the AC20 control.
#
# THE MESSAGE (spec B2, DBA's condition, taken verbatim). The RC=1 message must NAME THE
# REMEDY -- that at least one comment line is required, and that an intentionally irreversible
# migration satisfies the gate by SAYING SO in a comment. A refusal that does not name its
# one-line escape hatch is how an adopting project ends up deleting the gate.
#
# NO NEW SENTINEL TOKEN (spec B3, DBA's condition). `-- DOWN: NONE`, `-- IRREVERSIBLE` and
# friends are new vocabulary every adopting project must learn, each needing its own parsing,
# config key and drift risk, and they buy nothing over the free-text prose the gate already
# accepts. Asserted as a source read at the bottom of this file.
#
# BLAST RADIUS, recorded so the narrowing is not re-litigated against a cost that was never
# real: collectMigrationSources (gate-pre-phase4.mjs:303-321) builds its list from
# --migrations-added or from the migrations named in THIS diff's impl-report. It NEVER walks
# a project's migrations directory, so an adopter's existing backlog is out of reach; the
# refusal is bounded to migrations the current change adds or touches.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

GATE="$SCRIPTS_DIR/gate-pre-phase4.mjs"
GATE_SRC="$SCRIPTS_DIR/gate-pre-phase4.mjs"
ISSUE=4244

make_temp_project "$ISSUE" || exit 90

new_project() {
  PROJ="$TEMP_PROJECT/$1"
  PROJ_ISSUE_DIR="$PROJ/.pipeline/$ISSUE"
  mkdir -p "$PROJ_ISSUE_DIR"
}

write_report() {
  local rel="$1"
  cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "fix/enforce-what-we-claim",
  "commits": [{"sha":"a1","message":"m","files_changed":["$rel"]}],
  "files_removed": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "recorded by the fixture"}
  ]
}
EOF
}

write_spec() {
  cat > "$PROJ_ISSUE_DIR/spec.json" <<EOF
{"issue_number": $ISSUE, "acceptance_criteria": ["AC1: migrations are reversible"]}
EOF
}

write_migration() {
  mkdir -p "$PROJ/$(dirname "$1")"
  printf '%s' "$2" > "$PROJ/$1"
}

gate() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" node "$GATE" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

# run_case <case-name> <rel-path> <full-sql>
run_case() {
  local name="$1" rel="$2" sql="$3"
  new_project "$name"
  write_spec
  write_report "$rel"
  write_migration "$rel" "$sql"
  gate --issue "$ISSUE"
}

assert_not_schema() {
  assert_not_contains "$1 (attributable: not a schema rejection)" "$ERR" "impl-report schema:"
}

suite "gate empty down region: AC7 -- a marker with nothing under it is refused"

# The marker line is present, so the PRESENCE check the gate ships today is satisfied. What
# is missing is the content the presence check is read as guaranteeing.
run_case ac7-bare "migrations/060_bare.sql" "create table foo (id int);
-- DOWN
"
assert_eq "AC7: a down marker with no content at all halts" "$RC" "1"
assert_not_schema "AC7 bare"
assert_contains "AC7: and names the migration" "$ERR" "migrations/060_bare.sql"

# "No non-blank content" is the rule, so blank lines are not content. This cell is not
# represented by the bare cell: an implementation testing `region.length === 0` passes the
# bare case and lets this one through.
run_case ac7-blank "migrations/061_blank.sql" "create table foo (id int);
-- DOWN


"
assert_eq "AC7: a down region of blank lines halts" "$RC" "1"
assert_not_schema "AC7 blank"

# Nor is whitespace content. Same argument, different residue.
run_case ac7-ws "migrations/062_ws.sql" "create table foo (id int);
-- DOWN

"
assert_eq "AC7: a down region of whitespace only halts" "$RC" "1"
assert_not_schema "AC7 whitespace"

suite "gate empty down region: AC20 -- the refusal names its own escape hatch"

run_case ac20-msg "migrations/063_msg.sql" "create table foo (id int);
-- DOWN
"
assert_eq "AC20: the empty-down refusal is RC=1" "$RC" "1"
assert_not_schema "AC20"
# Mutation (i) -- strip the remedy clause -- must redden THESE while the RC assertion above
# stays green, so the criterion cannot be satisfied by the refusal alone.
assert_contains "AC20 MESSAGE: says at least one comment line is required" \
  "$ERR" "at least one comment line"
assert_contains "AC20 MESSAGE: says an irreversible migration satisfies the gate by saying so" \
  "$ERR" "irreversible"

# THE NON-ZERO CONTROL, and the cell that decides what the refusal actually means. DBA's own
# example: one comment line IS content. Mutation (ii) -- fire on "fewer than N characters"
# instead of "no non-blank content" -- reddens here and nowhere else, which is what proves the
# refusal is "no rollback note" and not "a short rollback note".
run_case ac20-ctl "migrations/064_irrev.sql" "create table foo (id int);
-- DOWN
-- irreversible: forward-only backfill, restore via PITR
"
assert_eq "AC20 CONTROL: a single comment line satisfies the gate" "$RC" "0"
assert_contains "AC20 CONTROL: and the gate says so" "$OUT" "OK: pre-Phase-4 gate passed."

# A second control at the short end, so "one line" is not silently read as "one LONG line".
run_case ac20-ctl-short "migrations/065_short.sql" "create table foo (id int);
-- DOWN
-- n/a
"
assert_eq "AC20 CONTROL: even a four-character note satisfies the gate" "$RC" "0"

suite "gate empty down region: B3 -- no new sentinel token enters the vocabulary"

# A source read, in the idiom AC22 uses for the docstring. The refusal must be satisfiable by
# FREE-TEXT PROSE; if a literal sentinel appears in the gate it has become a term every
# adopting project must learn, with its own parsing and its own drift risk.
GATE_TEXT=$(cat "$GATE_SRC")
assert_not_contains "B3: no \`DOWN: NONE\` sentinel is introduced" "$GATE_TEXT" "DOWN: NONE"
assert_not_contains "B3: no \`IRREVERSIBLE\` sentinel is introduced" "$GATE_TEXT" "-- IRREVERSIBLE"
assert_not_contains "B3: no \`NO ROLLBACK\` sentinel is introduced" "$GATE_TEXT" "NO ROLLBACK"

finish
