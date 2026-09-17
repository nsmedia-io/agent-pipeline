#!/usr/bin/env bash
# next-phase.mjs: which phase runs now, which orchestrator files to read before it, and which
# phase follows (#164 row 20).
#
# The routing used to live in three places in the prose: the loading table in the core, the
# "Route by tier" and "Skip if" lines in phase-1-ba.md, and the tier gate in phase-0.5-map.md.
# These cells check the script gives the answers those lines gave, that the core's loading
# table is the script's own output, and that the replaced lines stay gone.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

NP="$SCRIPTS_DIR/next-phase.mjs"
CORE="$PLUGIN_ROOT/commands/pipeline.md"
P05="$PLUGIN_ROOT/orchestrator/phase-0.5-map.md"
P1="$PLUGIN_ROOT/orchestrator/phase-1-ba.md"
P25="$PLUGIN_ROOT/orchestrator/phase-2.5-design.md"

make_temp_project 7 || exit 90
D="$TEMP_ISSUE_DIR"

# Write the run record and the spec for one case. An empty argument leaves that file out.
put() {
  rm -f "$D/status.json" "$D/spec.json" "$D/visual-contract.json"
  [[ -n "$1" ]] && printf '%s' "$1" > "$D/status.json"
  [[ -n "$2" ]] && printf '%s' "$2" > "$D/spec.json"
  return 0
}
# Run the script against the case; sets OUT and RC.
np() {
  OUT="$(node "$NP" --status "$D/status.json" --spec "$D/spec.json" "$@" 2>&1)"
  RC=$?
}
run_of() { printf '%s' "$OUT" | sed -n 's/^RUN: //p' | cut -d' ' -f1; }
then_of() { printf '%s' "$OUT" | sed -n 's/^THEN: //p'; }

suite "next-phase: a run with no record starts at setup"

put "" ""
np
assert_eq "no status.json exits 0" "$RC" "0"
assert_eq "and runs 0-setup" "$(run_of)" "0-setup"
assert_contains "reading the setup file" "$OUT" "READ: phase-0-setup.md"
assert_contains "and the status record file" "$OUT" "READ: status-record.md"
assert_eq "then the map phase" "$(then_of)" "0.5-map"

suite "next-phase: the tier decides what follows BA, as the old Route by tier lines did"

put '{"current_phase":"1-ba-complete"}' '{"risk_tier":"trivial"}'
np
assert_eq "trivial goes straight to Phase 3" "$(run_of)" "3-impl"
put '{"current_phase":"1-ba-complete"}' '{"risk_tier":"standard"}'
np
assert_eq "standard runs Phase 2-lite" "$(run_of)" "2-constraints"
assert_contains "and reads its file" "$OUT" "READ: phase-2-lite.md"
assert_eq "then Phase 3" "$(then_of)" "3-impl"
put '{"current_phase":"1-ba-complete"}' '{"risk_tier":"architectural"}'
np
assert_eq "architectural runs the Phase 2 review" "$(run_of)" "2-review"
assert_eq "then the design bake-off" "$(then_of)" "2.5-design"
put '{"current_phase":"2-review-complete"}' '{"risk_tier":"architectural"}'
np
assert_eq "after the review, the bake-off" "$(run_of)" "2.5-design"
assert_contains "which reads the routing file for its model lines" "$OUT" "READ: dispatch-routing.md"
put '{"current_phase":"1-ba-complete"}' '{"trivial":true}'
np
assert_eq "the legacy trivial flag still means trivial" "$(run_of)" "3-impl"
put '{"current_phase":"1-ba-complete","risk_tier":"standard"}' ""
np
assert_eq "with no spec, the tier comes from status.json" "$(run_of)" "2-constraints"
assert_contains "and says where it came from" "$OUT" "TIER: standard (status.json)"

suite "next-phase: no tier where one is needed is a halt, not a guess"

put '{"current_phase":"1-ba-complete"}' '{}'
np
assert_eq "BA finished with no tier exits 2" "$RC" "2"
assert_contains "and names the missing tier" "$OUT" "no risk_tier"
put '{"current_phase":"1-ba"}' '{}'
np
assert_eq "entering BA with no tier yet is normal and exits 0" "$RC" "0"
assert_contains "and says BA's tier sets what follows" "$OUT" "THEN: set by BA's tier"
put '{"current_phase":"2-constraints"}' '{"risk_tier":"architectural"}'
np
assert_eq "a standard-only phase recorded on an architectural run exits 2" "$RC" "2"
put '{"current_phase":"9-nothing"}' '{"risk_tier":"standard"}'
np
assert_eq "a phase name the map does not know exits 2" "$RC" "2"

suite "next-phase: the Phase 0.5 depth by tier, as the old tier gate stated it"

put '{"current_phase":"0.5-map"}' '{"risk_tier":"architectural"}'
np
assert_contains "architectural runs a separate map dispatch" "$OUT" "MAP: separate"
assert_contains "and reads the routing file for its model line" "$OUT" "READ: dispatch-routing.md"
put '{"current_phase":"0.5-map"}' '{"risk_tier":"standard"}'
np
assert_contains "standard folds the map into BA" "$OUT" "MAP: folded"
assert_not_contains "and needs no routing file" "$OUT" "dispatch-routing.md"
put '{"current_phase":"0.5-map"}' '{"risk_tier":"trivial"}'
np
assert_contains "trivial skips the deep map" "$OUT" "MAP: skip"
put '{"current_phase":"0.5-map"}' ""
np
assert_eq "before BA has written a spec, the map phase routes without a tier" "$RC" "0"
assert_contains "and says the depth waits for BA, rather than defaulting to folded" "$OUT" "MAP: pending"

suite "next-phase: resume states"

put '{"current_phase":"3-impl","risk_tier":"architectural"}' ""
np
assert_eq "an entry marker re-runs its own phase" "$(run_of)" "3-impl"
assert_contains "architectural adds the QA-first file" "$OUT" "READ: phase-3-architectural.md"
assert_not_contains "and not the gate file, which the 3-impl-complete step reads" "$OUT" "phase-3-4-gate.md"
put '{"current_phase":"3-impl","risk_tier":"standard"}' ""
np
assert_not_contains "standard does not read the QA-first file" "$OUT" "phase-3-architectural.md"
put '{"current_phase":"2.5-design-owner-decision","risk_tier":"architectural"}' ""
np
assert_contains "a parked state resumes inside its phase" "$OUT" "RUN: 2.5-design (parked"
put '{"current_phase":"4-veto-rework-required","risk_tier":"architectural"}' ""
np
assert_eq "a veto rework goes back to BA" "$(run_of)" "1-ba"
assert_contains "and reads the loop-back file" "$OUT" "READ: loop-backs.md"
put '{"current_phase":"3-impl-error"}' ""
np
assert_eq "an error state exits 3" "$RC" "3"
put '{"current_phase":"5-archived"}' ""
np
assert_eq "an archived run is done and exits 0" "$RC" "0"
assert_contains "with nothing to run" "$OUT" "RUN: none"
put '{"current_phase":"4-review-complete"}' '{"risk_tier":"standard"}'
np
assert_eq "after the panel, the archive" "$(run_of)" "5-archive"
put '{nope' ""
np
assert_eq "a status.json that will not parse exits 1" "$RC" "1"

suite "next-phase: 3-impl-complete runs the fail-closed pre-Phase-4 gate before the panel, at every tier"

# phase-3-impl.md writes 3-impl-complete BEFORE phase3-exit.mjs runs, so routing that state straight
# to 4-review would skip the tripwire and both pre-Phase-4 gates.
for tier in trivial standard architectural; do
  put "{\"current_phase\":\"3-impl-complete\",\"risk_tier\":\"$tier\"}" ""
  np
  assert_eq "$tier: 3-impl-complete runs the gate step, not the panel" "$(run_of)" "3-4-gate"
  assert_contains "$tier: and reads the gate file" "$OUT" "READ: phase-3-4-gate.md"
  assert_contains "$tier: and names the gate command" "$OUT" "scripts/phase3-exit.mjs"
  assert_not_contains "$tier: and loads no panel file yet" "$OUT" "phase-4-panel.md"
  assert_eq "$tier: the panel comes after the gate" "$(then_of)" "4-review"
done

suite "next-phase: a tripwire loops back to BA; a refused gate loops back to Phase 3"

for state in 3-impl-tripwire 3-impl-tripwire-indeterminate; do
  put "{\"current_phase\":\"$state\",\"risk_tier\":\"standard\"}" ""
  np
  assert_eq "$state goes back to BA to re-tier" "$(run_of)" "1-ba"
  assert_not_contains "$state is not resumed inside Phase 3" "$OUT" "RUN: 3-impl"
  assert_contains "$state reads the loop-back file" "$OUT" "READ: loop-backs.md"
done
put '{"current_phase":"3-impl-gate-failed","risk_tier":"standard"}' ""
np
assert_eq "a refused gate goes back to Phase 3" "$(run_of)" "3-impl"
assert_contains "and reads the loop-back file" "$OUT" "READ: loop-backs.md"

suite "next-phase: no tier recorded anywhere is exit 2 wherever the phase depends on it"

# Each of these would otherwise silently take the standard shape: a folded map, no 2.5-design, no
# phase-3-architectural.md.
for state in 0.5-map 2-review-complete 3-impl 3-impl-complete 4-review; do
  put "{\"current_phase\":\"$state\"}" '{"title":"no tier"}'
  np
  assert_eq "$state with a spec but no tier anywhere exits 2" "$RC" "2"
  assert_contains "$state: and says the tier is missing" "$OUT" "no risk_tier"
  assert_not_contains "$state: and routes nothing" "$OUT" "RUN:"
done
put '{"current_phase":"0.5-map"}' '{"title":"no tier"}'
np
assert_not_contains "no MAP: folded is printed without a tier" "$OUT" "MAP: folded"
put '{"current_phase":"0.5-map","risk_tier":"architectural"}' '{"title":"no tier in spec"}'
np
assert_eq "CONTROL: the tier recorded in status.json is enough" "$RC" "0"

suite "next-phase: conditional files"

put '{"current_phase":"1-ba-complete"}' '{"risk_tier":"standard","impacted_domains":["api","frontend"]}'
np
assert_contains "a frontend-scoped spec reads the art director contract at routing" "$OUT" "READ: art-director-contract.md (spec is frontend-scoped)"
put '{"current_phase":"1-ba-complete"}' '{"risk_tier":"standard","impacted_domains":["api"]}'
np
assert_not_contains "a spec with no frontend domain does not" "$OUT" "art-director-contract.md"
put '{"current_phase":"4-review","risk_tier":"standard"}' ""
printf '{}' > "$D/visual-contract.json"
np
assert_contains "a visual contract on disk reads it at Phase 4" "$OUT" "READ: art-director-contract.md (visual-contract.json exists)"
put '{"current_phase":"4-review","risk_tier":"standard","review_rounds":2}' ""
np
assert_contains "a second panel round reads the delta file" "$OUT" "READ: phase-4-delta.md"
put '{"current_phase":"4-review","risk_tier":"standard","review_rounds":1}' ""
np
assert_not_contains "the first round, already counted at its own checkpoint, does not" "$OUT" "phase-4-delta.md"
put '{"current_phase":"3-impl","risk_tier":"standard","review_rounds":0}' ""
np
assert_not_contains "and neither does a run with no panel yet" "$OUT" "phase-4-delta.md"

suite "next-phase: --existing-issue skips BA only when the spec is already approved"

put '{"current_phase":"0.5-map-complete"}' '{"risk_tier":"standard","ba_approved_at":"2026-01-01T00:00:00Z"}'
np --existing-issue
assert_contains "an approved spec skips BA" "$OUT" "SKIP: 1-ba"
assert_eq "and routes by its tier" "$(run_of)" "2-constraints"
np
assert_eq "without the flag BA runs (a rework re-entry keeps an approved spec too)" "$(run_of)" "1-ba"
put '{"current_phase":"0.5-map-complete"}' '{"risk_tier":"standard"}'
np --existing-issue
assert_eq "with the flag but no approval BA runs" "$(run_of)" "1-ba"

suite "next-phase: the core's loading table is the script's table"

TABLE="$(node "$NP" --table)"
assert_eq "--table exits 0" "$?" "0"
assert_eq "commands/pipeline.md carries exactly the --table output as its loading table" \
  "$(grep '^|' "$CORE")" "$TABLE"
MISSING=""
for f in "$PLUGIN_ROOT"/orchestrator/*.md; do
  n="$(basename "$f")"
  [[ "$n" == "phase-4-panel-preamble.md" ]] && continue
  printf '%s' "$TABLE" | grep -qF "\`$n\`" || MISSING="$MISSING $n"
done
assert_eq "every orchestrator file but the rendered preamble is in the script's map" "$MISSING" ""
# A check that the comparison above can fail: change one row and compare again.
MUTATED="$(printf '%s' "$TABLE" | sed 's/phase-2-lite.md/phase-2-gone.md/')"
assert_eq "CONTROL: a table with one file renamed does not match the core" \
  "$([[ "$(grep '^|' "$CORE")" == "$MUTATED" ]] && echo same || echo differs)" "differs"

suite "next-phase: the prose it replaced stays removed"

assert_eq "phase-1-ba.md no longer routes by tier by hand" "$(grep -c 'Route by tier' "$P1" | tr -d ' ')" "0"
assert_eq "phase-1-ba.md no longer carries the Skip if rule" "$(grep -c 'Skip if' "$P1" | tr -d ' ')" "0"
assert_eq "phase-0.5-map.md no longer carries the tier gate" "$(grep -c 'Gate by risk tier' "$P05" | tr -d ' ')" "0"
assert_eq "phase-2.5-design.md no longer restates when it is skipped" "$(grep -c 'it is SKIPPED' "$P25" | tr -d ' ')" "0"
assert_contains "the core runs next-phase.mjs at each transition" "$(cat "$CORE")" 'scripts/next-phase.mjs" --status'
assert_contains "phase-1-ba.md routes through it" "$(cat "$P1")" "next-phase.mjs --status"
assert_contains "phase-0.5-map.md reads the MAP line" "$(cat "$P05")" '`MAP:` line'

finish
