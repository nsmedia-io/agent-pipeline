#!/usr/bin/env bash
# Review convergence: the delta seating, the tooling panel, the panel stance, the tooling effort
# row and the one-checklist deferral, each RUN from the shipped artifact rather than read.
#
# Measured on one consumer before this change: a single tooling issue ran 21 spec revisions and
# 8 Phase 4 panel rounds with six reviewers, and produced 79 acceptance criteria, a
# 676-assertion prover and 35 follow-up issues. The rules pinned here are the ones that stop
# each of those, and each positive cell has a control beside it that differs in one input.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

# The orchestrator prose is a core plus per-phase files; pins read all of it (harness.sh).
pipeline_md_concat "$PLUGIN_ROOT" || exit 90
PIPELINE_MD="$PIPELINE_MD_CONCAT"
DEFERRAL="$SCRIPTS_DIR/deferral.mjs"
EFFORT="$SCRIPTS_DIR/dispatch-effort.mjs"
RENDER="$SCRIPTS_DIR/render-panel.mjs"

# ---- the roster script the orchestrator prose calls (panel-roles.mjs, #164) --------------------
PANEL_ROLES_MJS="$SCRIPTS_DIR/panel-roles.mjs"
export CLAUDE_PROJECT_DIR="$TEMP_PROJECT"

make_diff_repo() {  # $1 = dest dir, remaining args = paths added in the HEAD commit
  local dir="$1"; shift
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$dir" branch origin/main
  local p
  for p in "$@"; do
    mkdir -p "$dir/$(dirname "$p")"; printf 'x\n' > "$dir/$p"; git -C "$dir" add "$p"
  done
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m change
}
DL_REPO="$TEMP_PROJECT/repo-dl"; make_diff_repo "$DL_REPO" "db/queries/orders.ts"
INFRA_REPO="$TEMP_PROJECT/repo-infra"; make_diff_repo "$INFRA_REPO" ".github/workflows/ci.yml"
SEC_REPO="$TEMP_PROJECT/repo-sec"; make_diff_repo "$SEC_REPO" "src/auth/session.ts"
FE_REPO="$TEMP_PROJECT/repo-fe"; make_diff_repo "$FE_REPO" "src/ui/Button.tsx"
CLEAN_REPO="$TEMP_PROJECT/repo-clean"; make_diff_repo "$CLEAN_REPO" "docs/notes.txt"

# run_panel <worktree> <cost_class> -> ROLES=... (standard tier)
run_panel() {
  printf '{"risk_tier":"standard","cost_class":"%s"}' "$2" > "$TEMP_PROJECT/st-panel.json"
  node "$PANEL_ROLES_MJS" full --status "$TEMP_PROJECT/st-panel.json" --worktree "$1" \
    --artifact-dir "$TEMP_PROJECT/no-artifacts" > "$TEMP_PROJECT/panel.out" 2>/dev/null
  printf 'ROLES=%s\n' "$(tr '\n' ' ' < "$TEMP_PROJECT/panel.out" | sed 's/ $//')"
}
# run_delta <worktree> <cost_class> [<artifact dir>] -> DELTA=<roles> plus any PANEL-NOTE lines. The
# first-round panel on the record is "ba dev qa secops dba".
run_delta() {
  printf '{"panel_roles":["ba","dev","qa","secops","dba"],"cost_class":"%s"}' "$2" > "$TEMP_PROJECT/st-delta.json"
  local art="${3:-$TEMP_PROJECT/art-empty}"
  node "$PANEL_ROLES_MJS" delta --status "$TEMP_PROJECT/st-delta.json" --worktree "$1" --first-round-head origin/main \
    --peer-review "$art/peer-review.json" > "$TEMP_PROJECT/delta.out" 2> "$TEMP_PROJECT/delta.err"
  printf 'DELTA=%s\n' "$(tr '\n' ' ' < "$TEMP_PROJECT/delta.out" | sed 's/ $//')"
  grep '^PANEL-NOTE' "$TEMP_PROJECT/delta.err"
}

suite "delta seating: the seed is the roles holding OPEN BLOCKER ids"

ART="$TEMP_PROJECT/art-blockers"; mkdir -p "$ART"
printf '%s' '{"qa":{"verdict":"REQUEST_CHANGES","materiality":{"open_blocker_ids":["qa-1"],"blocks_merge":true}},"ba":{"verdict":"APPROVE_WITH_NOTES","verdict_as_returned":"REQUEST_CHANGES","materiality":{"open_blocker_ids":[],"blocks_merge":false}},"secops":{"verdict":"APPROVE","materiality":{"open_blocker_ids":[],"blocks_merge":false}}}' > "$ART/peer-review.json"
OUT="$(run_delta "$CLEAN_REPO" product "$ART")"
assert_contains "a role holding an open blocker id is seeded" "$OUT" "DELTA=qa"
assert_not_contains "a role whose REQUEST_CHANGES was downgraded to a note is NOT reseated" "$OUT" "ba"
assert_not_contains "nor a standing approval" "$OUT" "secops"
ART0="$TEMP_PROJECT/art-noblockers"; mkdir -p "$ART0"
printf '%s' '{"qa":{"verdict":"APPROVE_WITH_NOTES","materiality":{"open_blocker_ids":[],"blocks_merge":false}}}' > "$ART0/peer-review.json"
assert_eq "CONTROL: no open blocker ids and a clean fix seats nobody" "$(run_delta "$CLEAN_REPO" product "$ART0")" "DELTA="
LEG="$TEMP_PROJECT/art-legacy"; mkdir -p "$LEG"
printf '%s' '{"dba":{"verdict":"REQUEST_CHANGES","materiality":{"blocks_merge":true,"blocking_concerns":1}},"qa":{"verdict":"APPROVE","materiality":{"blocks_merge":false}}}' > "$LEG/peer-review.json"
assert_eq "a LEGACY block with blocks_merge:true and no open_blocker_ids is reseated, not dropped" \
  "$(run_delta "$CLEAN_REPO" product "$LEG")" "DELTA=dba"
BAD="$TEMP_PROJECT/art-unreadable"; mkdir -p "$BAD"; printf '{not json' > "$BAD/peer-review.json"
OUT="$(run_delta "$CLEAN_REPO" product "$BAD")"
assert_contains "an UNREADABLE peer-review.json seeds the FULL panel rather than nobody" "$OUT" "DELTA=ba dev qa secops dba"
assert_contains "and says so" "$OUT" "PANEL-NOTE: open blocker ids UNREADABLE"

suite "delta seating: a role by surface only where its MERGE-CLASS surface changed"

assert_contains "product: a data-layer fix seats dba" "$(run_delta "$DL_REPO" product "$ART0")" "dba"
assert_contains "product: and secops" "$(run_delta "$DL_REPO" product "$ART0")" "secops"
assert_not_contains "tooling: a data-layer fix still seats dba but NOT secops" "$(run_delta "$DL_REPO" tooling "$ART0")" "secops"
assert_contains "tooling: (dba is still seated there)" "$(run_delta "$DL_REPO" tooling "$ART0")" "dba"
assert_contains "tooling: a SECURITY path does seat secops" "$(run_delta "$SEC_REPO" tooling "$ART0")" "secops"
assert_contains "product: an infra fix seats devops" "$(run_delta "$INFRA_REPO" product "$ART0")" "devops"
assert_eq "tooling: an infra (CI) fix reseats nobody, because CI config IS the tooling change" "$(run_delta "$INFRA_REPO" tooling "$ART0")" "DELTA="
assert_eq "a frontend fix reseats nobody at any cost class (no merge-class surface)" "$(run_delta "$FE_REPO" product "$ART0")" "DELTA="
assert_contains "the prose states full-round SecOps seating stays mandatory" "$(cat "$PIPELINE_MD")" \
  "SecOps seating on a FULL round stays mandatory at every tier and every cost class"

suite "tooling panel: qa + secops + ONE surface specialist"

assert_eq "tooling, infra diff: qa secops devops" "$(run_panel "$INFRA_REPO" tooling)" "ROLES=qa secops devops"
assert_eq "tooling, data-layer diff: qa secops dba" "$(run_panel "$DL_REPO" tooling)" "ROLES=qa secops dba"
assert_eq "tooling, frontend diff: qa secops design_review" "$(run_panel "$FE_REPO" tooling)" "ROLES=qa secops design_review"
assert_eq "tooling, no surface: qa secops dev" "$(run_panel "$CLEAN_REPO" tooling)" "ROLES=qa secops dev"
assert_eq "CONTROL: product, no surface, is the standard four" "$(run_panel "$CLEAN_REPO" product)" "ROLES=ba dev qa secops"
assert_eq "CONTROL: product, infra diff, seats devops beside the four" "$(run_panel "$INFRA_REPO" product)" "ROLES=ba dev qa secops devops"

suite "tooling effort: SecOps runs at medium on a tooling panel, whatever the tier"

eff() { ( cd "$TEMP_PROJECT" && node "$EFFORT" "$@" 2>/dev/null ); }
for tier in architectural standard trivial; do
  assert_eq "secops $tier tooling -> medium" "$(eff secops $tier 4 --site panel-lens --surface workflow --cost-class tooling)" "medium"
done
assert_eq "CONTROL: secops architectural product -> xhigh" "$(eff secops architectural 4 --site panel-lens --surface workflow --cost-class product)" "xhigh"
assert_eq "CONTROL: secops architectural with no cost class -> xhigh" "$(eff secops architectural 4 --site panel-lens --surface workflow)" "xhigh"
( cd "$TEMP_PROJECT" && node "$EFFORT" secops architectural 4 --surface workflow --cost-class cheap ) >/dev/null 2>&1
assert_eq "an unknown cost class is a dispatch-site error (exit 2)" "$?" "2"

suite "panel stance: report the most serious real defect; no manufactured findings"

PREAMBLE="$(RENDER="$RENDER" MD="$PIPELINE_MD" node --input-type=module -e 'import {readFileSync} from "node:fs";const m=await import(process.env.RENDER);console.log(m.extractPreamble(readFileSync(process.env.MD,"utf8")))')"
assert_contains "the preamble carries the new stance" "$PREAMBLE" \
  "Report the most serious real defect your lens finds, with evidence. If nothing reaches a merge_class, APPROVE with at most three notes. Do not manufacture findings; an evidenced APPROVE is a complete review."
assert_not_contains "the strongest-flaw instruction is gone" "$PREAMBLE" "STRONGEST flaw"
assert_not_contains "and so is 'do not hunt for reasons to approve'" "$PREAMBLE" "do not hunt for reasons to approve"
assert_contains "the evidence requirement survives: cite file:line" "$PREAMBLE" "every concern cites specific evidence (a file:line"
assert_contains "and the grep vacuity rule survives" "$PREAMBLE" "the grep you ran plus a control showing that grep can match"
assert_contains "the preamble names merge_class in the materiality rule" "$PREAMBLE" "merge_class (wrong-pass: a gate or test reports green on a real failure"
assert_contains "and scopes evidence-controls.md at tooling" "$PREAMBLE" "At cost_class tooling the controls file binds only on a gate's own pass/fail logic"
assert_eq "the delta paragraph no longer says assume the remediation introduced a defect" \
  "$(grep -c 'assume the remediation introduced a defect until' "$SCRIPTS_DIR/render-panel.mjs" | tr -d ' ')" "0"

suite "deferrals: one checklist per issue; a separate issue only for a merge_class or owner-marked note"

PROJ="$TEMP_PROJECT/defer"; mkdir -p "$PROJ"
printf '%s' '{"deferralTracker":"directory","deferralDir":"ledger"}' > "$PROJ/pipeline.config.json"
cat > "$PROJ/peer-review.json" <<'JSON'
{"final_verdict":"APPROVE_WITH_NOTES","reviewed_at":"2026-09-16T00:00:00Z",
 "qa":{"verdict":"APPROVE_WITH_NOTES","concerns":[
   {"severity":"major","likelihood":"normal-use","harm":"internal","merge_class":"none","description":"assertion name is vague","location":"tests/a.sh:10"},
   {"severity":"high","likelihood":"edge-case","harm":"user-visible","merge_class":"data-loss","description":"edge-case truncation","location":"src/x.ts:4"},
   {"severity":"nit","likelihood":"normal-use","harm":"cosmetic","merge_class":"none","description":"typo","suggested_patch":"--- a\n+++ b"}
 ],"materiality":{"open_blocker_ids":[],"blocks_merge":false}},
 "dev":{"verdict":"REQUEST_CHANGES","concerns":[
   {"severity":"blocker","likelihood":"normal-use","harm":"money","merge_class":"money","description":"fee rounding"},
   {"severity":"low","likelihood":"normal-use","harm":"internal","merge_class":"none","description":"rename helper"}
 ],"materiality":{"open_blocker_ids":["dev-1"],"blocks_merge":true}}}
JSON
dfr() { local o="$TEMP_PROJECT/d.out" e="$TEMP_PROJECT/d.err"; ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" node "$DEFERRAL" "$@" ) >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); }
dfr checklist --issue 42 --peer-review peer-review.json
assert_eq "checklist exits 0" "$RC" "0"
assert_eq "exactly ONE checklist ref is printed" "$(printf '%s\n' "$OUT" | grep -c '^checklist	')" "1"
assert_eq "and ONE separate issue, for the merge_class note" "$(printf '%s\n' "$OUT" | grep -c '^issue	')" "1"
assert_contains "the separate issue is the data-loss note" "$OUT" "issue	qa-2	"
assert_eq "the ledger holds two files, not one per note" "$(ls "$PROJ/ledger" | wc -l | tr -d ' ')" "2"
CL="$(cat "$PROJ"/ledger/42-deferred-review-notes-for-42.md 2>/dev/null)"
assert_contains "the checklist carries the merge_class none note as a box" "$CL" "- [ ] **qa qa-1** (tests/a.sh:10)"
assert_contains "and the other role's note" "$CL" "**dev dev-2**"
assert_not_contains "but not the open blocker" "$CL" "dev-1"
assert_not_contains "nor the note whose patch was applied" "$CL" "qa-3"
assert_not_contains "nor the note that got its own issue" "$CL" "qa-2"
rm -f "$PROJ"/ledger/*.md
dfr checklist --issue 42 --peer-review peer-review.json --own dev-2 --unapplied qa-3
assert_eq "an owner-marked note becomes its own issue too" "$(printf '%s\n' "$OUT" | grep -c '^issue	')" "2"
CL="$(cat "$PROJ"/ledger/42-deferred-review-notes-for-42.md 2>/dev/null)"
assert_contains "and a patch that did not apply is back on the checklist" "$CL" "qa-3"
assert_not_contains "and the owner-marked note left the checklist" "$CL" "dev-2"
dfr checklist --issue 42 --peer-review peer-review.json --dry-run
assert_contains "--dry-run prints the checklist" "$OUT" "- [ ] **qa qa-1**"
assert_contains "and names the own-issue notes" "$OUT" "own issues: qa-2"
dfr checklist --issue 42
assert_eq "a missing --peer-review is a usage error" "$RC" "1"

suite "the contradictions named in the brief are gone"

assert_eq "no lens or agent says a design major may block" \
  "$(grep -c 'blocker/major' "$SCRIPTS_DIR/panel-lenses.json" "$PLUGIN_ROOT/agents/design.md" | grep -cv ':0$' | tr -d ' ')" "0"
assert_contains "peer-review.schema.json says trivial seats qa+secops" \
  "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).description)' "$PLUGIN_ROOT/schemas/peer-review.schema.json")" \
  "qa+secops at trivial tier"
assert_contains "evidence-controls.md scopes itself at tooling" "$(cat "$PLUGIN_ROOT/evidence-controls.md")" \
  "At \`cost_class: tooling\` the scope is narrower, whatever the tier."

finish
