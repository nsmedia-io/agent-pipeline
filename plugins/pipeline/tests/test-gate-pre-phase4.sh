#!/usr/bin/env bash
# gate-pre-phase4.mjs — the fail-CLOSED Phase 3->4 gate.
#
# Every rule is pinned in BOTH directions. A fail-closed gate that only ever gets tested on
# its blocking path can be "fixed" into never blocking without a single red test, which is the
# regression this suite exists to catch: a gate that quietly stops firing.
#
# FIXTURE DISCIPLINE (load-bearing): every impl-report fixture below is schema-VALID except in
# the cases that deliberately test schema rejection. An incomplete fixture exits 1 on a missing
# required field, which would satisfy a naive migration assertion FOR THE WRONG REASON. The
# migration cases additionally assert the stderr carries no "impl-report schema:" line, so an
# exit 1 is attributable to the migration rule and nothing else.
#
# Hermeticity: every case builds its own project root under one registered temp dir and runs
# the gate with cwd AND CLAUDE_PROJECT_DIR pinned there, so .pipeline/<issue>/,
# pipeline.config.json and the migration files all resolve inside the temp tree.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

GATE="$SCRIPTS_DIR/gate-pre-phase4.mjs"
ISSUE=4242

make_temp_project "$ISSUE" || exit 90

# new_project <name>: an isolated project root, so no case has to delete another's fixture.
new_project() {
  PROJ="$TEMP_PROJECT/$1"
  PROJ_ISSUE_DIR="$PROJ/.pipeline/$ISSUE"
  mkdir -p "$PROJ_ISSUE_DIR"
}

# write_report <requirement_text> [commits-json] [files_removed-json]
# Always schema-valid: issue_number, branch, commits, checks_passed, completed_at and a
# non-empty requirement_checks are all present and correctly typed.
write_report() {
  local req="$1" commits="${2:-[]}" removed="${3:-[]}"
  cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": $commits,
  "files_removed": $removed,
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "$req", "status": "PASS", "notes": "recorded by the fixture"}
  ]
}
EOF
}

# write_spec <criterion>
write_spec() {
  cat > "$PROJ_ISSUE_DIR/spec.json" <<EOF
{"issue_number": $ISSUE, "acceptance_criteria": ["$1"]}
EOF
}

# write_report_checks <requirement_checks-json-array>
# The same schema-valid envelope write_report builds, with the checks array supplied whole.
# The coverage rules below turn on RELATIONS BETWEEN ENTRIES -- whether a majority carry an AC
# label, how many distinctive tokens one entry shares -- and a one-entry helper cannot express
# either. Fixture discipline is unchanged: every field the schema requires is present here, so
# an exit 1 in those cases is the coverage rule and not a missing field.
write_report_checks() {
  cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": $1
}
EOF
}

# write_spec_criteria <acceptance_criteria-json-array>
write_spec_criteria() {
  cat > "$PROJ_ISSUE_DIR/spec.json" <<EOF
{"issue_number": $ISSUE, "acceptance_criteria": $1}
EOF
}

write_config() { printf '%s' "$1" > "$PROJ/pipeline.config.json"; }

# write_migration <rel-path> <sql>
write_migration() {
  mkdir -p "$PROJ/$(dirname "$1")"
  printf '%s' "$2" > "$PROJ/$1"
}

# gate <args...> -> RC, OUT, ERR
gate() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" node "$GATE" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

# A down-less migration, used wherever the migration rule is under test.
BAD_SQL='create table foo (id int);
'
# The convention this repo prescribes: an up section plus a COMMENTED-OUT down region.
GOOD_SQL='create table foo (id int);
-- DOWN
-- drop table foo;
'

suite "pre-Phase-4 gate: acceptance-criteria coverage, both directions"

new_project cov-label
write_spec "AC7: the courier roster rotates on the hour"
# No token overlap at all with the criterion: only the shared AC label can cover it, so this
# case exercises the label path specifically rather than the fuzzy path by accident.
write_report "AC7 handled"
gate --issue "$ISSUE"
assert_eq "an AC-label match covers the criterion" "$RC" "0"
assert_contains "a passing gate says so" "$OUT" "OK: pre-Phase-4 gate passed."

new_project cov-tokens
write_spec "Screenshots stay inside the pipeline issue directory"
# No AC label on either side: coverage here can only come from token overlap.
write_report "verify screenshots remain inside the issue directory tree"
gate --issue "$ISSUE"
assert_eq "a token-overlap match covers the criterion" "$RC" "0"

new_project cov-missing
write_spec "Concurrent claims cannot double-assign a courier"
write_report "verify screenshots remain inside the issue directory tree"
gate --issue "$ISSUE"
assert_eq "an uncovered criterion halts the panel" "$RC" "1"
assert_contains "the halt says which rule fired" "$ERR" "acceptance criterion not covered by any requirement_check"
assert_contains "the halt quotes the uncovered criterion" "$ERR" "Concurrent claims cannot double-assign a courier"
assert_contains "the gate announces it blocked" "$ERR" "FAIL: pre-Phase-4 gate blocked the panel."

# =============================================================================
# THE GATE AND THE CONTRACT MUST AGREE ABOUT WHERE A CRITERION MAY LIVE (0.41.0).
# =============================================================================
suite "pre-Phase-4 gate: acceptance_criteria_met covers a criterion too"

# THE DEFECT. This gate read `requirement_checks` alone, while agents/dev.md and the schema both
# describe that array as "one entry per spec.requirements" and ship `acceptance_criteria_met` as
# the array whose entries ARE criteria. A Dev followed the contract, put the AC labels where the
# contract says criteria go, and the gate refused the panel over a report that had said
# everything it was asked to say. It happened on two runs; the first passed only because that
# Dev happened to echo the labels into requirement_checks as well.
#
# WHAT CHANGED IS WHERE THE GATE LOOKS, NEVER HOW LENIENTLY. Same label authority, same token
# floor, over the union of the two arrays. The uncovered cell below is what pins that.

new_project cov-acmet-only
write_spec_criteria '["AC7: the courier roster rotates on the hour"]'
# The criterion is named ONLY in acceptance_criteria_met. requirement_checks carries an entry
# with no label and no shared vocabulary at all, so nothing but the new array can cover this.
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "wire the scheduler module", "status": "PASS", "notes": "done"}
  ],
  "acceptance_criteria_met": [
    {"criterion": "AC7: the courier roster rotates on the hour", "met": true, "evidence": "test: rotation case"}
  ]
}
EOF
gate --issue "$ISSUE"
assert_eq "a criterion covered ONLY in acceptance_criteria_met passes" "$RC" "0"
assert_contains "and the gate says it passed" "$OUT" "OK: pre-Phase-4 gate passed."

# NON-ZERO CONTROL, and it is the whole reason this widening is not a loosening: a criterion
# named in NEITHER array still halts. Same fixture, same two arrays, one criterion added.
new_project cov-acmet-missing
write_spec_criteria '["AC7: the courier roster rotates on the hour","AC8: concurrent claims cannot double-assign a courier"]'
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC7 wire the scheduler module", "status": "PASS", "notes": "done"}
  ],
  "acceptance_criteria_met": [
    {"criterion": "AC7: the courier roster rotates on the hour", "met": true, "evidence": "test: rotation case"}
  ]
}
EOF
gate --issue "$ISSUE"
assert_eq "a criterion in NEITHER array still halts" "$RC" "1"
assert_contains "and the halt names the uncovered criterion" "$ERR" "AC8: concurrent claims"
assert_contains "and the message names both places a criterion may be covered" \
  "$ERR" "acceptance_criteria_met"
assert_contains "and it is attributable to the coverage rule, not the schema" \
  "$ERR" "acceptance criterion not covered"
assert_eq "...with no schema complaint about the fixture" \
  "$(printf '%s' "$ERR" | grep -c 'impl-report schema:' | tr -d ' ')" "0"

# A criterion recorded as NOT met is still ADDRESSED. Whether the pipeline should ship it is the
# panel's question; treating "met: false" as absent would refuse the honest report while passing
# the one that omits the row entirely.
new_project cov-acmet-false
write_spec_criteria '["AC7: the courier roster rotates on the hour"]'
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "wire the scheduler module", "status": "PASS", "notes": "done"}
  ],
  "acceptance_criteria_met": [
    {"criterion": "AC7: the courier roster rotates on the hour", "met": false, "evidence": "blocked on the queue owner"}
  ]
}
EOF
gate --issue "$ISSUE"
assert_eq "a criterion recorded as NOT met is still covered (the gate asks addressed, not passed)" "$RC" "0"

# =============================================================================
# THE DEFERRAL LEDGER (0.41.0): a deferral with no resolvable ref HALTS the panel.
# =============================================================================
suite "pre-Phase-4 gate: every deferral carries a ref the configured tracker can resolve"

# The ledger is exercised in DIRECTORY mode throughout: it is the one tracker whose refs this
# suite can construct, and the routing itself is covered in test-deferral.sh. The fixtures below
# are otherwise the standard schema-valid envelope, so an exit 1 here is the deferral rule.
DEFERRAL_CFG='{"deferralTracker":"directory","deferralDir":"ledger"}'

new_project defer-no-ref
write_config "$DEFERRAL_CFG"
write_spec "AC1 handled"
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "n"}
  ],
  "deferred": [
    {"what": "the notify retry backoff is still linear", "reason": "needs the queue owner", "tracker_ref": ""}
  ]
}
EOF
gate --issue "$ISSUE"
assert_eq "a deferral with an empty tracker_ref HALTS" "$RC" "1"
assert_contains "the halt names the entry by index" "$ERR" "deferred[0]"
assert_contains "and quotes the item, so the reader knows which deferral" \
  "$ERR" "the notify retry backoff is still linear"
assert_contains "and says no ref was recorded" "$ERR" "no tracker_ref recorded"
assert_contains "and names the REMEDY, not just the refusal" "$ERR" "scripts/deferral.mjs record"
assert_contains "and names the destination this project configured" "$ERR" "ledger/"
assert_eq "and it is attributable to the deferral rule, not the schema" \
  "$(printf '%s' "$ERR" | grep -c 'impl-report schema:' | tr -d ' ')" "0"

# THE PASSING DIRECTION, on a ref that is a file this test actually created. Without it the
# refusal above could have been bought by refusing every deferral there is.
mkdir -p "$PROJ/ledger"
printf 'x\n' > "$PROJ/ledger/847-backoff.md"
node -e '
  const fs = require("fs");
  const f = process.argv[1];
  const j = JSON.parse(fs.readFileSync(f, "utf8"));
  j.deferred[0].tracker_ref = "ledger/847-backoff.md";
  fs.writeFileSync(f, JSON.stringify(j));
' "$PROJ_ISSUE_DIR/impl-report.json"
gate --issue "$ISSUE"
assert_eq "the SAME report with a real ledger file passes" "$RC" "0"
assert_contains "and the gate says so" "$OUT" "OK: pre-Phase-4 gate passed."

# A ref that names a file nobody wrote is the exact shape the rule exists for: "routed to #N"
# claimed in an artifact and written nowhere. It must not pass on plausibility.
new_project defer-phantom-ref
write_config "$DEFERRAL_CFG"
write_spec "AC1 handled"
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "n"}
  ],
  "deferred": [
    {"what": "an item nobody wrote down", "reason": "r", "tracker_ref": "ledger/never-written.md"}
  ]
}
EOF
gate --issue "$ISSUE"
assert_eq "a ref naming a file that does not exist HALTS" "$RC" "1"
assert_contains "and says the file is not there" "$ERR" "names no file"

# THE SHAPE A DEV ACTUALLY WROTE IN THE WILD, before `deferred[]` existed. A gate reading only
# the declared name would have enforced NOTHING on the very run that motivated the rule, while
# reporting a clean pass -- this gate's own defect class wearing the new rule's clothes.
new_project defer-observations-shape
write_config "$DEFERRAL_CFG"
write_spec "AC1 handled"
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "n"}
  ],
  "scope_drift": {
    "detected": true,
    "observations_reported_not_fixed": [
      {"what": "the settings gate reads one contact row", "reason": "out of scope for this issue"}
    ]
  }
}
EOF
gate --issue "$ISSUE"
assert_eq "scope_drift.observations_reported_not_fixed is read the same way" "$RC" "1"
assert_contains "and the halt names THAT array, so the writer knows which one" \
  "$ERR" "scope_drift.observations_reported_not_fixed[0]"

# CONTROL: a report with no deferrals at all is untouched by this rule. Without it every case
# above would be consistent with a gate that halts on every report.
new_project defer-none
write_config "$DEFERRAL_CFG"
write_spec "AC1 handled"
write_report "AC1 handled"
gate --issue "$ISSUE"
assert_eq "CONTROL: a report recording no deferrals passes" "$RC" "0"

# CONTROL: an EMPTY deferred array is not a deferral either. `deferred: []` is what an honest
# report with nothing to defer looks like, and refusing it would tax every clean run.
new_project defer-empty
write_config "$DEFERRAL_CFG"
write_spec "AC1 handled"
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "n"}
  ],
  "deferred": []
}
EOF
gate --issue "$ISSUE"
assert_eq "CONTROL: an empty deferred[] passes" "$RC" "0"

# The schema half: an entry missing a REQUIRED key is a schema violation, reported as one, so a
# report that omits `reason` is told which rule it broke rather than only that something is off.
new_project defer-schema
write_config "$DEFERRAL_CFG"
write_spec "AC1 handled"
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "n"}
  ],
  "deferred": [
    {"what": "an item with no reason", "tracker_ref": "ledger/x.md"}
  ]
}
EOF
gate --issue "$ISSUE"
assert_eq "a deferred entry missing a required key is refused" "$RC" "1"
assert_contains "and it is named as a schema violation" "$ERR" "impl-report schema:"
assert_contains "naming the missing field" "$ERR" 'missing required field "reason"'

suite "pre-Phase-4 gate: artifact I/O fails CLOSED"

new_project io-missing-report
write_spec "AC1: something"
gate --issue "$ISSUE"
assert_eq "an absent impl-report.json halts" "$RC" "1"
assert_contains "the halt names the missing artifact" "$ERR" "impl-report.json not found"

new_project io-bad-json
write_spec "AC1: something"
printf '%s' '{"issue_number": }' > "$PROJ_ISSUE_DIR/impl-report.json"
gate --issue "$ISSUE"
assert_eq "an unparseable impl-report.json halts" "$RC" "1"
assert_contains "the halt says it is not valid JSON" "$ERR" "impl-report.json is not valid JSON"

new_project io-missing-spec
write_report "AC1 handled"
gate --issue "$ISSUE"
assert_eq "an absent spec.json halts" "$RC" "1"
assert_contains "the halt names the missing spec" "$ERR" "spec.json not found"

suite "pre-Phase-4 gate: schema rejection (the deliberately invalid fixtures)"

new_project schema-missing-field
write_spec "AC1: something"
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/x",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "n"}
  ]
}
EOF
gate --issue "$ISSUE"
assert_eq "a schema violation halts" "$RC" "1"
assert_contains "the halt is attributed to the schema" "$ERR" "impl-report schema:"
assert_contains "the halt names the missing field" "$ERR" 'missing required field "lint"'

new_project schema-empty-checks
write_spec "AC1: something"
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/x",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": []
}
EOF
gate --issue "$ISSUE"
assert_eq "an empty requirement_checks halts (minItems)" "$RC" "1"
assert_contains "the halt names the minItems rule" "$ERR" "expected at least 1 item"

suite "pre-Phase-4 gate: migration up/down rule, structural cases"

# Positive control for every migration case below: this exact fixture, with no migration in
# play, exits 0. Any exit 1 in this section is therefore the migration rule, not the fixture.
new_project mig-control
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["src/x.ts"]}]'
gate --issue "$ISSUE"
assert_eq "the shared fixture is schema-valid and passes on its own" "$RC" "0"

new_project mig-good
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/001_good.sql"]}]'
write_migration "migrations/001_good.sql" "$GOOD_SQL"
gate --issue "$ISSUE"
assert_eq "an up section plus a -- DOWN marker passes" "$RC" "0"

new_project mig-no-down
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/002_bad.sql"]}]'
write_migration "migrations/002_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "a migration with no down section halts" "$RC" "1"
assert_contains "the halt quotes the exact down-section message" "$ERR" \
  'migration "migrations/002_bad.sql" has no down section (expected a "-- DOWN" marker)'
assert_not_contains "the halt is the migration rule, not an incidental schema error" "$ERR" "impl-report schema:"

new_project mig-no-up
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/003_noup.sql"]}]'
write_migration "migrations/003_noup.sql" '-- DOWN
-- drop table foo;
'
gate --issue "$ISSUE"
assert_eq "a migration with no up section halts" "$RC" "1"
# The up-section message carries NO marker text. An assertion demanding the marker in both
# messages would false-fail here, so the two messages are asserted separately and exactly.
assert_contains "the halt quotes the exact up-section message" "$ERR" \
  'migration "migrations/003_noup.sql" has no up section'
assert_not_contains "the up-section failure does not claim a missing down section" "$ERR" "has no down section"
assert_not_contains "the up-section halt is not an incidental schema error" "$ERR" "impl-report schema:"

new_project mig-comment-only-up
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/004_comments.sql"]}]'
write_migration "migrations/004_comments.sql" '-- create table foo (id int);
-- DOWN
-- drop table foo;
'
gate --issue "$ISSUE"
assert_eq "an all-comment head is not an up section" "$RC" "1"
assert_contains "and it reports the up-section failure" "$ERR" "has no up section"

suite "pre-Phase-4 gate: the custom down marker is ADDITIVE, not exclusive"

new_project marker-custom-only
write_config '{"migrationDownMarker":"-- ROLLBACK"}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/005.sql"]}]'
write_migration "migrations/005.sql" 'create table foo (id int);
-- ROLLBACK
-- drop table foo;
'
gate --issue "$ISSUE"
assert_eq "a file using only the configured custom marker passes" "$RC" "0"

new_project marker-builtin-while-custom-configured
write_config '{"migrationDownMarker":"-- ROLLBACK"}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/006.sql"]}]'
write_migration "migrations/006.sql" "$GOOD_SQL"
gate --issue "$ISSUE"
assert_eq "the builtin -- DOWN still passes while a custom marker is configured" "$RC" "0"

new_project marker-neither
write_config '{"migrationDownMarker":"-- ROLLBACK"}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/007.sql"]}]'
write_migration "migrations/007.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "neither marker present still halts" "$RC" "1"
assert_contains "the message quotes the CONFIGURED marker" "$ERR" 'expected a "-- ROLLBACK" marker'

suite "pre-Phase-4 gate: pipeline.config.json parsing falls back silently but safely"

new_project cfg-blank-marker
write_config '{"migrationDownMarker":"   "}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/008.sql"]}]'
write_migration "migrations/008.sql" "$GOOD_SQL"
gate --issue "$ISSUE"
assert_eq "a whitespace-only marker falls back to the default" "$RC" "0"

new_project cfg-empty-marker
write_config '{"migrationDownMarker":""}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/009.sql"]}]'
write_migration "migrations/009.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "an empty marker still halts a down-less migration" "$RC" "1"
assert_contains "and the message quotes the DEFAULT marker" "$ERR" 'expected a "-- DOWN" marker'

new_project cfg-wrongtype-marker
write_config '{"migrationDownMarker":42}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/010.sql"]}]'
write_migration "migrations/010.sql" "$GOOD_SQL"
gate --issue "$ISSUE"
assert_eq "a non-string marker falls back to the default" "$RC" "0"

new_project cfg-unparseable
write_config '{"migrationGlobs": }'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/011.sql"]}]'
write_migration "migrations/011.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "an unparseable config does not crash the gate: defaults still apply" "$RC" "1"
assert_contains "the default globs still find the migration" "$ERR" 'migration "migrations/011.sql" has no down section'

new_project cfg-absent
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/012.sql"]}]'
write_migration "migrations/012.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "an absent config applies the default globs" "$RC" "1"

suite "pre-Phase-4 gate: migrationGlobs semantics (AC19)"

new_project globs-empty-inference
write_config '{"migrationGlobs":[]}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/013_bad.sql"]}]'
write_migration "migrations/013_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "migrationGlobs: [] disarms the INFERENCE path" "$RC" "0"

new_project globs-empty-explicit
write_config '{"migrationGlobs":[]}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["src/x.ts"]}]'
write_migration "migrations/014_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE" --migrations-added "migrations/014_bad.sql"
# A project CANNOT disarm the migration gate for EXPLICITLY-NAMED migrations by setting
# migrationGlobs: []. collectMigrationSources reads explicit --migrations-added paths before
# any glob test, and that ordering is deliberate: a path passed on the command line is the
# orchestrator asserting "this IS a migration", and a discovery FILTER must never override an
# explicit assertion. If this case ever goes red, check whether the code changed to match the docstring
# before assuming the test is stale -- that change would be a bypass on a fail-closed gate.
assert_eq "migrationGlobs: [] does NOT disarm an explicitly-named migration" "$RC" "1"
assert_contains "the explicit path is still checked for a down section" "$ERR" \
  'migration "migrations/014_bad.sql" has no down section'
assert_not_contains "the explicit-path halt is not an incidental schema error" "$ERR" "impl-report schema:"

new_project globs-custom-match
write_config '{"migrationGlobs":["db/changes/**"]}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["db/changes/015_bad.sql"]}]'
write_migration "db/changes/015_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "a custom glob matches what it names" "$RC" "1"
assert_contains "and reports that file" "$ERR" 'migration "db/changes/015_bad.sql" has no down section'

new_project globs-custom-nonmatch
write_config '{"migrationGlobs":["db/changes/**"]}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/016_bad.sql"]}]'
write_migration "migrations/016_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "a custom glob matches ONLY what it names" "$RC" "0"

new_project globs-wrongtype
write_config '{"migrationGlobs":"migrations/**"}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/017_bad.sql"]}]'
write_migration "migrations/017_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "a non-array migrationGlobs falls back to the defaults" "$RC" "1"

new_project globs-badelem
write_config '{"migrationGlobs":["db/changes/**",42]}'
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/018_bad.sql"]}]'
write_migration "migrations/018_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "a non-string glob element falls back to the defaults" "$RC" "1"

suite "pre-Phase-4 gate: deletion exemption (a bypass on a fail-closed gate, AC20)"

# The exempted migration EXISTS on disk with down-less content in every case below, so a pass
# proves the exemption fired rather than proving the file was merely unreadable.
new_project del-top-level
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" \
  '[{"sha":"a1","message":"m","files_changed":["migrations/019_bad.sql"]}]' \
  '["migrations/019_bad.sql"]'
write_migration "migrations/019_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "a migration recorded in top-level files_removed is exempt" "$RC" "0"

new_project del-not-removed
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/020_bad.sql"]}]'
write_migration "migrations/020_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "the same migration NOT recorded as removed still halts" "$RC" "1"
assert_contains "and is reported by name" "$ERR" 'migration "migrations/020_bad.sql" has no down section'

new_project del-per-commit
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" \
  '[{"sha":"a1","message":"m","files_changed":["migrations/021_bad.sql"],"files_removed":["migrations/021_bad.sql"]}]'
write_migration "migrations/021_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "a per-commit files_removed exempts that commit" "$RC" "0"

new_project del-no-leak
write_spec "AC1: migrations are reversible"
# Commit a1 deletes the file; commit a2 touches the same path again (a re-add). The exemption
# must NOT leak forward: the file is on disk after a2, so the gate has something to check.
write_report "AC1 handled" \
  '[{"sha":"a1","message":"drop","files_changed":["migrations/022_bad.sql"],"files_removed":["migrations/022_bad.sql"]},{"sha":"a2","message":"re-add","files_changed":["migrations/022_bad.sql"]}]'
write_migration "migrations/022_bad.sql" "$BAD_SQL"
gate --issue "$ISSUE"
assert_eq "a per-commit exemption does not leak to a later commit" "$RC" "1"
assert_contains "the re-added migration is reported" "$ERR" 'migration "migrations/022_bad.sql" has no down section'

suite "pre-Phase-4 gate: the executable down region is a GUARANTEE, not a boundary"

# INVERTED IN PLACE, per this case's own FUTURE AUTHOR instruction, when issue #16 closed. The
# gate now classifies the down REGION (everything after the marker LINE) as clean, executable
# or indeterminate, and both non-clean values halt. dba.md requires a down region to be
# commented-out documentation, never executable SQL -- an executable down block is a live
# data-destruction statement sitting in a migration file -- and the gate now enforces that
# rather than being silent on it. The full classifier matrix lives in
# test-gate-down-classifier.sh; this case stays here so the site that recorded the gap also
# records that it closed, and a reader can tell coverage from a guarantee.
new_project guarantee-executable-down
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/023_exec_down.sql"]}]'
write_migration "migrations/023_exec_down.sql" 'create table foo (id int);
-- DOWN
drop table foo;
'
gate --issue "$ISSUE"
assert_eq "GUARANTEE: an executable (uncommented) down region now halts" "$RC" "1"

suite "pre-Phase-4 gate: the up section is CLASSIFIED, not line-prefix matched (#31)"

# THE HOLE, and why a bare RC pin would not have caught it. The up rule used to ask whether any
# non-blank line before the marker failed to start with `--`. A block-commented up section has
# no such line -- `/*`, the statements, and `*/` all fail the prefix test -- so the gate called
# it an up section and passed a migration that applies NOTHING. The direction is the one this
# whole suite exists to catch: a check saying yes too easily. It is the same divergence class
# #30 closed for the down region, so it closes the same way, through the SAME classifier.
new_project up-block-commented
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/024_block_up.sql"]}]'
write_migration "migrations/024_block_up.sql" '/*
create table foo (id int);
*/
-- DOWN
-- drop table foo;
'
gate --issue "$ISSUE"
assert_eq "a block-commented up region is NOT an up section" "$RC" "1"
assert_contains "and it reports the up-section failure" "$ERR" \
  'migration "migrations/024_block_up.sql" has no up section'
assert_contains "the message says what the region actually is" "$ERR" \
  "nothing before the down marker is live SQL"
# A NARROWING OWES A REMEDY. An adopting project that meets a new refusal with no way out
# deletes the gate, so the message naming the fix is part of the rule, not decoration.
assert_contains "and names the remedy for the block form specifically" "$ERR" \
  'remedy: uncomment the up statements, or remove the enclosing `/* */` delimiters.'
assert_contains "and names the correct work it refuses" "$ERR" "REFUSES a placeholder migration"
assert_not_contains "the up-section halt is not an incidental schema error" "$ERR" "impl-report schema:"
assert_not_contains "and does not claim the down section is missing" "$ERR" "has no down section"
assert_not_contains "the down region of this file is clean and is not reported" "$ERR" "down region"

# NON-ZERO CONTROL for the case above: the SAME statements with the two delimiter lines removed
# pass. Without this, a fixture that halted for any unrelated reason would read as the rule
# firing, and the narrowing could be "fixed" into refusing every migration with the case above
# still green.
new_project up-block-commented-control
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/024_ctl.sql"]}]'
write_migration "migrations/024_ctl.sql" 'create table foo (id int);
-- DOWN
-- drop table foo;
'
gate --issue "$ISSUE"
assert_eq "CONTROL: the same statements unwrapped ARE an up section" "$RC" "0"

# THE FALSE-HALT CONTROL, and the one that bounds the narrowing. A block comment is ordinary in
# a real migration -- a header, a ticket link, a note above the DDL -- and refusing every file
# that opens with one would be a far worse bug than the one being fixed. The scan is
# first-token-wins, so what matters is that a CLOSED block is stepped over rather than treated
# as the whole region.
new_project up-block-preamble
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/025_preamble.sql"]}]'
write_migration "migrations/025_preamble.sql" '/* seeds the table the courier roster reads */
create table foo (id int);
-- DOWN
-- drop table foo;
'
gate --issue "$ISSUE"
assert_eq "a block-comment PREAMBLE above live statements is still an up section" "$RC" "0"

# The other non-clean verdict, isolated. This file carries NO `*/` anywhere, so the down region
# ("-- drop table foo;") classifies clean and the up rule is the only rule that can fire. Both
# non-clean verdicts refuse, and they refuse with DIFFERENT messages -- pinning RC alone would
# leave which-one-fired resting on nothing.
new_project up-unterminated
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/026_unterm.sql"]}]'
write_migration "migrations/026_unterm.sql" '/*
create table foo (id int);
-- DOWN
-- drop table foo;
'
gate --issue "$ISSUE"
assert_eq "an unterminated block comment before the marker is NOT an up section" "$RC" "1"
assert_contains "and it reports the up-section failure" "$ERR" \
  'migration "migrations/026_unterm.sql" has no up section'
assert_contains "naming the unterminated block and where it opened" "$ERR" \
  "an unterminated block comment opened at line 1, column 1"
assert_contains "and its own remedy, which is not the commented-out one" "$ERR" \
  "remedy: close the block, or delete its"
assert_not_contains "the indeterminate message is NOT the commented-out message" "$ERR" \
  "nothing before the down marker is live SQL"
assert_not_contains "the up-section halt is not an incidental schema error" "$ERR" "impl-report schema:"
assert_not_contains "and the clean down region is not reported" "$ERR" "down region is"

# THE REGION BOUND, which is the one behaviour a scan borrowed wholesale from the down rule
# gets wrong. Here a `/*` opens before the marker and its `*/` lands AFTER it. An unbounded
# lookahead finds that `*/`, calls the up region closed, runs off the end of the region and
# reports `clean` -- i.e. "every statement here is commented out", vouched for by a delimiter
# from outside the region. Both readings refuse the file, so RC cannot tell them apart; the
# MESSAGE is the whole assertion, and the not_contains below is what goes red on a regression.
new_project up-block-straddles-marker
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/027_straddle.sql"]}]'
write_migration "migrations/027_straddle.sql" '/*
create table foo (id int);
-- DOWN
*/
-- drop table foo;
'
gate --issue "$ISSUE"
assert_eq "a block that opens before the marker and closes after it halts" "$RC" "1"
assert_contains "and the up region is reported" "$ERR" \
  'migration "migrations/027_straddle.sql" has no up section'
assert_contains "as UNTERMINATED, because the closing delimiter is outside the region" "$ERR" \
  "an unterminated block comment opened at line 1, column 1"
assert_not_contains "NOT as commented-out: a \`*/\` past the marker must not vouch for the region" \
  "$ERR" "nothing before the down marker is live SQL"

# A DOCUMENTED BOUNDARY, pinned so the next editor meets the intent rather than the behaviour.
# The down rule REFUSES a `/*!` opener because MySQL/MariaDB RUN its body. For the up region
# that same fact is the answer to the question being asked -- something does run -- so it
# counts as an up section. Tightening it is not available at this scan's granularity: the scan
# returns at the FIRST token, so an ordinary mysqldump `/*!40101 SET NAMES utf8 */` preamble
# above a perfectly good `create table` would take the whole migration down with it.
new_project up-conditional-execution
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/028_cond.sql"]}]'
write_migration "migrations/028_cond.sql" '/*!40101 SET NAMES utf8 */;
-- DOWN
-- session-scoped, nothing to undo;
'
gate --issue "$ISSUE"
assert_eq "BOUNDARY: a MySQL conditional-execution opener counts as an up section" "$RC" "0"

suite "pre-Phase-4 gate: an AC label is AUTHORITATIVE, not a hint (#48)"

# THE #48 REPRODUCTION, in miniature and as a non-zero control. On the real 54-criterion spec
# that found this, AC23 and AC28 were deleted from requirement_checks and the gate still
# reported full coverage: token overlap from the OTHER 52 entries covered them. The three
# entries below are that shape -- criterion AC23, checks AC22 and AC24, and wording so close
# that the token path matches on 7 shared tokens. Restore the fall-through to token overlap and
# this case goes green while the gate is once again claiming coverage it never checked.
new_project label-authoritative
write_spec_criteria '["AC23: the pre-Phase-4 gate halts when a migration down region contains executable SQL"]'
write_report_checks '[
  {"requirement_index": 0, "requirement_text": "AC22: the pre-Phase-4 gate halts when a migration down region is empty", "status": "PASS", "notes": "pinned by the fixture"},
  {"requirement_index": 1, "requirement_text": "AC24: the pre-Phase-4 gate halts when a migration down region is indeterminate", "status": "PASS", "notes": "pinned by the fixture"}
]'
gate --issue "$ISSUE"
assert_eq "a labelled criterion no check names is uncovered, despite heavy token overlap" "$RC" "1"
assert_contains "the halt says which rule fired" "$ERR" \
  "acceptance criterion not covered by any requirement_check"
assert_contains "and names the label that went unanswered" "$ERR" "no check names AC23"
assert_contains "and says token overlap was deliberately not consulted" "$ERR" \
  "Token overlap is deliberately not consulted here"
assert_contains "and names the remedy in the convention the report already uses" "$ERR" \
  "remedy: name AC23 in the covering check's requirement_text or notes"
assert_not_contains "the coverage halt is not an incidental schema error" "$ERR" "impl-report schema:"

# NON-ZERO CONTROL: the same fixture with the label written down passes. This is what proves the
# rule is about the LABEL and not about the fixture being unmatchable by any means.
new_project label-authoritative-control
write_spec_criteria '["AC23: the pre-Phase-4 gate halts when a migration down region contains executable SQL"]'
write_report_checks '[
  {"requirement_index": 0, "requirement_text": "AC22: the pre-Phase-4 gate halts when a migration down region is empty", "status": "PASS", "notes": "pinned by the fixture"},
  {"requirement_index": 1, "requirement_text": "AC23: refuses a down region a database would run", "status": "PASS", "notes": "pinned by the fixture"}
]'
gate --issue "$ISSUE"
assert_eq "CONTROL: the same criterion passes once one check names AC23" "$RC" "0"
# ...and the covering check's WORDING shares almost nothing with the criterion, so this also
# pins the reason the label path exists at all: BA and Dev write these arrays independently.

# THE PRECONDITION, first direction. A report whose checks carry no labels at all is NOT made
# stricter -- the label is not a shared vocabulary there, and demanding one would false-halt
# every project that does not use them. Coverage falls back to wording, as it always did.
new_project label-not-in-force
write_spec_criteria '["AC5: screenshots stay inside the pipeline issue directory"]'
write_report_checks '[
  {"requirement_index": 0, "requirement_text": "verify screenshots remain inside the issue directory tree", "status": "PASS", "notes": "pinned by the fixture"}
]'
gate --issue "$ISSUE"
assert_eq "a labelled criterion still matches on wording when NO check carries a label" "$RC" "0"

# THE PRECONDITION, second direction, and the reason it is a MAJORITY rather than "any". One
# stray `see AC4 for context` in one entry's notes is not evidence a report keeps the
# convention. If a single label armed the strict rule, that one phrase would refuse every
# labelled criterion in an otherwise label-free report -- a mass false halt produced by a
# passing remark.
new_project label-one-stray
write_spec_criteria '["AC9: the courier roster rotates on the hour"]'
write_report_checks '[
  {"requirement_index": 0, "requirement_text": "the courier roster rotates on the hour", "status": "PASS", "notes": "pinned by the fixture"},
  {"requirement_index": 1, "requirement_text": "couriers cannot be double-assigned", "status": "PASS", "notes": "see AC4 for context"},
  {"requirement_index": 2, "requirement_text": "screenshots stay inside the issue directory", "status": "PASS", "notes": "pinned by the fixture"}
]'
gate --issue "$ISSUE"
assert_eq "one labelled check out of three does NOT arm the strict rule" "$RC" "0"

new_project label-majority-arms
write_spec_criteria '["AC9: the courier roster rotates on the hour"]'
write_report_checks '[
  {"requirement_index": 0, "requirement_text": "the courier roster rotates on the hour", "status": "PASS", "notes": "pinned by the fixture"},
  {"requirement_index": 1, "requirement_text": "AC4: couriers cannot be double-assigned", "status": "PASS", "notes": "pinned by the fixture"},
  {"requirement_index": 2, "requirement_text": "AC7: screenshots stay inside the issue directory", "status": "PASS", "notes": "pinned by the fixture"}
]'
gate --issue "$ISSUE"
assert_eq "two labelled checks out of three DO arm it, and AC9 goes unanswered" "$RC" "1"
assert_contains "naming the unanswered label" "$ERR" "no check names AC9"

suite "pre-Phase-4 gate: the token floor is proportional, not flat (#48)"

# `min(3, half)` asked the same three tokens of a 19-token criterion as of a six-token one --
# roughly 16% overlap -- and long criteria are exactly where unrelated text accumulates three
# shared words by accident. The criterion below carries 19 distinctive tokens and the check
# shares precisely three of them (`report`, `commit`, `list`). Under the flat threshold that
# was full coverage; the quarter floor asks for five.
new_project token-floor-long
write_spec_criteria '["The orchestrator refuses a peer-review panel whenever the implementation report omits the branch name, the commit list, or the completion timestamp recorded during phase three"]'
write_report_checks '[
  {"requirement_index": 0, "requirement_text": "verified the report names each commit in the list", "status": "PASS", "notes": "pinned by the fixture"}
]'
gate --issue "$ISSUE"
assert_eq "three incidental words do not cover a 19-token criterion" "$RC" "1"
assert_contains "and the halt quotes the criterion" "$ERR" \
  "The orchestrator refuses a peer-review panel"
assert_not_contains "the token-floor halt is not the label rule wearing its message" "$ERR" \
  "Token overlap is deliberately not consulted here"
assert_not_contains "nor an incidental schema error" "$ERR" "impl-report schema:"

# NON-ZERO CONTROL, and the one that keeps the floor honest. A stricter matcher that refused
# everything would satisfy the case above. This check is a genuine paraphrase of the SAME
# criterion -- different sentence, six shared tokens -- and it must still pass, or the floor has
# stopped catching noise and started policing wording.
new_project token-floor-long-control
write_spec_criteria '["The orchestrator refuses a peer-review panel whenever the implementation report omits the branch name, the commit list, or the completion timestamp recorded during phase three"]'
write_report_checks '[
  {"requirement_index": 0, "requirement_text": "verified the report omits neither the branch nor the commit list before the panel opens", "status": "PASS", "notes": "pinned by the fixture"}
]'
gate --issue "$ISSUE"
assert_eq "CONTROL: a real paraphrase of the same long criterion still covers it" "$RC" "0"

# THE FLOOR DOES NOT MOVE FOR SHORT AND MID-LENGTH CRITERIA, which is what makes it a bounded
# change rather than a new policy. Below 13 distinctive tokens `max(3, size/4)` is still 3, so
# every match that passed before still passes -- `cov-tokens` above is the mid-length case, and
# this is the short one, three tokens matched out of four.
new_project token-floor-short-unchanged
write_spec_criteria '["Concurrent claims cannot double-assign a courier"]'
write_report_checks '[
  {"requirement_index": 0, "requirement_text": "concurrent claims are rejected for one courier", "status": "PASS", "notes": "pinned by the fixture"}
]'
gate --issue "$ISSUE"
assert_eq "a short criterion still matches on three tokens, exactly as before" "$RC" "0"

# =============================================================================
# Multi-repo impl-report: the shape check runs BEFORE any inference reads it.
# A service estate keys `commits` BY REPOSITORY. Inference walked it as an array, so that shape
# threw `TypeError: object is not iterable` out of the migration helper -- before the schema
# check that names the problem in one line. The fix is ORDER, not shape-acceptance: `commits`
# is an array by contract, and a report that disagrees should be TOLD SO.
# =============================================================================
new_project multirepo-commits-object
write_spec "a criterion"
cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "feat/multi-repo",
  "commits": {"svc-a": [{"sha": "a1", "message": "m"}], "svc-b": []},
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "a criterion", "status": "PASS", "notes": "recorded by the fixture"}
  ]
}
EOF
gate --issue "$ISSUE"
assert_eq "a commits object is REFUSED rather than crashing the gate" "$RC" "1"
assert_eq "and it is named as a shape error, not a TypeError" \
  "$(printf '%s' "$ERR" | grep -c 'commits: expected type "array", got object')" "1"
# The whole point of ordering it here: the raw TypeError must be GONE, not merely accompanied.
assert_eq "no TypeError reaches the operator" \
  "$(printf '%s' "$ERR" | grep -ci 'not iterable')" "0"
# CONTROL: the same report with a flat commits array PASSES, so the assertions above measure
# the shape and not a fixture that was broken for some other reason.
new_project multirepo-commits-array-control
write_spec "a criterion"
write_report "a criterion" '[{"sha": "a1", "message": "m"}]'
gate --issue "$ISSUE"
assert_eq "CONTROL: the identical report with a flat commits array passes" "$RC" "0"

finish
