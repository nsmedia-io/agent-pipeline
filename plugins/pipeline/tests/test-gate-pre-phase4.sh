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
# explicit assertion. The script's own docstring (gate-pre-phase4.mjs:18, "Set
# migrationGlobs: [] to disable it entirely") is WRONG on this point; tracked as follow-up doc
# issue 3. If this case ever goes red, check whether the code changed to match the docstring
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

suite "pre-Phase-4 gate: KNOWN COVERAGE BOUNDARY (not a guarantee)"

# KNOWN GAP, recorded deliberately rather than left silent. hasUpSection only inspects the
# text BEFORE the down marker, and nothing after the marker is examined at all, so a down
# region of UNCOMMENTED, EXECUTABLE SQL passes this gate today. dba.md requires a down region
# to be commented-out documentation, never executable SQL (an executable down block is a live
# data-destruction statement sitting in a migration file), so the gate is silent on a rule the
# project actually enforces. Tracked as follow-up issue 4.
#
# FUTURE AUTHOR: if this case goes RED, the gap was CLOSED. INVERT the assertion (expect 1)
# and delete this boundary label. Do NOT delete the case: a boundary that silently disappears
# when it moves leaves the next reader with no way to tell coverage from a guarantee.
new_project boundary-executable-down
write_spec "AC1: migrations are reversible"
write_report "AC1 handled" '[{"sha":"a1","message":"m","files_changed":["migrations/023_exec_down.sql"]}]'
write_migration "migrations/023_exec_down.sql" 'create table foo (id int);
-- DOWN
drop table foo;
'
gate --issue "$ISSUE"
assert_eq "BOUNDARY: an executable (uncommented) down region passes today" "$RC" "0"

finish
