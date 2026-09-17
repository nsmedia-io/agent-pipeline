#!/usr/bin/env bash
# voice-moment.mjs: the register, sections and facts for the owner-facing message (#164 row 21).
#
# owner-handoff.md listed the full-voice moments and told the orchestrator how to derive a
# migration and the BA defaults by hand, while voice-lint.mjs kept its own copy of the moment
# table. The table now lives in voice-moment.mjs and the lint imports it. These cells pin the one
# table, each register, both facts (including the unknown direction), every exit code, and that
# the prose calls the script instead of carrying the list.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

VM="$SCRIPTS_DIR/voice-moment.mjs"
LINT="$SCRIPTS_DIR/voice-lint.mjs"
HANDOFF="$PLUGIN_ROOT/orchestrator/owner-handoff.md"

make_temp_project 71 || exit 90
ST="$TEMP_ISSUE_DIR/status.json"
SPEC="$TEMP_ISSUE_DIR/spec.json"
WT="$TEMP_PROJECT/wt"

vm() {
  ( cd "$TEMP_PROJECT" && node "$VM" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}
phase() { printf '{"issue_number":71,"current_phase":"%s"}' "$1" > "$ST"; }

# ONE TABLE. The lint's VOICE_MOMENTS is the very object this module exports, not an equal copy,
# so a key added to one cannot be missing from the other.
suite "voice-moment: the lint reads the same table"

SAME="$(node --input-type=module -e '
  const a = await import(process.argv[1]);
  const b = await import(process.argv[2]);
  console.log(a.VOICE_MOMENTS === b.VOICE_MOMENTS && Object.keys(a.VOICE_MOMENTS).length > 0);
' "$VM" "$LINT" 2>&1)"
assert_eq "voice-lint.mjs re-exports the voice-moment.mjs object itself" "$SAME" "true"
assert_eq "and voice-lint.mjs no longer declares a table of its own" \
  "$(grep -c '^export const VOICE_MOMENTS' "$LINT" | tr -d ' ')" "0"

# THE FIXTURE REPOSITORY. A worktree with a base commit and a head that adds a migration, so the
# migration fact reads yes against the base and no against the head itself.
g() { git -C "$WT" "$@" >/dev/null 2>&1; }
mkdir -p "$WT"
g init -q
g config user.email t@example.com
g config user.name t
g config commit.gpgsign false
printf 'x\n' > "$WT/app.js"
g add app.js
g commit -q -m base
BASE="$(git -C "$WT" rev-parse HEAD)"
mkdir -p "$WT/db/migrations"
printf 'create table t();\n' > "$WT/db/migrations/001.sql"
g add db
g commit -q -m migration

# REGISTERS. A keyed moment is full voice with its sections; a mechanical halt or an -error
# checkpoint is reduced; everything else is a progress tick with nothing required.
suite "voice-moment: register and sections"

phase 5-archived
vm --status "$ST" --worktree "$WT" --base "$BASE"
assert_eq "a completion report: exit 0" "$RC" "0"
assert_contains "full voice" "$OUT" "REGISTER: full"
assert_contains "with the three scales and the replication block" "$OUT" "**Blast radius:** | **Reversibility:** | **Confidence:** | ### See it yourself"
phase 2.5-design-owner-decision
vm --status "$ST"
assert_contains "the design-lock requires the decision block" "$OUT" "### I need a decision"
assert_not_contains "and not the scales" "$OUT" "**Blast radius:**"
phase 3-impl-gate-failed
vm --status "$ST"
assert_contains "a gate failure is reduced voice" "$OUT" "REGISTER: reduced"
phase 4-error
vm --status "$ST"
assert_contains "an -error checkpoint is reduced voice" "$OUT" "REGISTER: reduced"
phase 3-impl
vm --status "$ST"
assert_contains "an ordinary checkpoint is a progress tick" "$OUT" "REGISTER: progress"
assert_contains "with nothing required" "$OUT" "SECTIONS: none required"
assert_contains "and the full-voice list is printed at every checkpoint" "$OUT" "Presenting a PR as ready for human merge."

# THE MIGRATION FACT. A migration in the diff is yes with its path and the one-way-door line; the
# head against itself is no; a worktree git cannot diff, or none given, is unknown, never no.
suite "voice-moment: the migration fact"

phase 4-review-complete
vm --status "$ST" --worktree "$WT" --base "$BASE"
assert_contains "a diff adding db/migrations/001.sql reads yes, with the path" "$OUT" "FACT migration: yes (db/migrations/001.sql)"
assert_contains "and says the one-way-door words are owed" "$OUT" "this is a one way door"
vm --status "$ST" --worktree "$WT" --base HEAD
assert_contains "CONTROL: the head against itself reads no" "$OUT" "FACT migration: no"
vm --status "$ST" --worktree "$TEMP_PROJECT/not-a-repo" --base "$BASE"
assert_contains "a worktree git cannot read is unknown" "$OUT" "FACT migration: unknown"
assert_eq "and still exits 0" "$RC" "0"
vm --status "$ST"
assert_contains "no --worktree is unknown too" "$OUT" "FACT migration: unknown"

# THE BA-DEFAULT FACT. Every question a BA default answered is listed from the spec next to the
# status record, an owner answer is not, and a spec that cannot be read is unknown.
suite "voice-moment: the ba_default fact"

printf '{"open_questions":[{"id":"q1","question":"which cadence?","blocking":false,"resolution":{"answer":"hourly","answered_by":"ba_default","at":"t"}},{"id":"q2","question":"who?","blocking":true,"resolution":{"answer":"me","answered_by":"owner","at":"t"}}]}' > "$SPEC"
vm --status "$ST"
assert_contains "the defaulted question is listed" "$OUT" "FACT ba_default: q1"
assert_contains "with its answer" "$OUT" '"which cadence?" answered by default: "hourly"'
assert_not_contains "and the owner-answered one is not" "$OUT" "q2:"
printf '{"open_questions":[]}' > "$SPEC"
vm --status "$ST"
assert_contains "a spec with no defaults says none" "$OUT" "FACT ba_default: none"
rm -f "$SPEC"
vm --status "$ST"
assert_contains "no readable spec is unknown, not none" "$OUT" "FACT ba_default: unknown"

# EXIT CODES. The JSON form carries the same record; a record with no phase, a missing file and a
# bad argument are exit 1, so an unreadable checkpoint is never described as a progress tick.
suite "voice-moment: exit codes"

phase 5-archived
vm --status "$ST" --json
assert_eq "--json: exit 0" "$RC" "0"
assert_eq "and it parses with the register in it" \
  "$(printf '%s' "$OUT" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).register)')" "full"
printf '{"issue_number":71}' > "$ST"
vm --status "$ST"
assert_eq "a status record with no current_phase: exit 1" "$RC" "1"
vm --status "$TEMP_PROJECT/missing.json"
assert_eq "a missing status file: exit 1" "$RC" "1"
vm
assert_eq "no --status: exit 1" "$RC" "1"
vm --status "$ST" --bogus
assert_eq "an unknown argument: exit 1" "$RC" "1"

# THE PROSE. owner-handoff.md calls the script and no longer carries the list or the mechanics.
suite "owner-handoff.md calls voice-moment.mjs"

assert_contains "the full-voice register calls the script" "$(cat "$HANDOFF")" 'scripts/voice-moment.mjs" --status'
assert_not_contains "the moment list is gone" "$(cat "$HANDOFF")" "- The live-verification halt (the owner has to go run something"
assert_not_contains "the migration predicate mechanics are gone" "$(cat "$HANDOFF")" "whose glob set is the built-in presets unioned with"
assert_not_contains "the ba_default mechanics are gone" "$(cat "$HANDOFF")" 'Then check `spec.open_questions` for any resolution'

finish
