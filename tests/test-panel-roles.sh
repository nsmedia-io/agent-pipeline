#!/usr/bin/env bash
# panel-roles.mjs (#164 rows 1 and 3): the Phase 4 full panel and the delta set, as a tested script
# instead of two shell blocks in orchestrator prose. Every tier, every cost_class, every surface
# probe, every delta seeding case and the tooling exceptions, each against a real throwaway git
# repo, plus the exit-code contract and a pin that the removed bash stays removed.
#
# Output contract under test: roles on stdout one per line; PANEL-NOTE on stderr; exit 0 ok,
# 21 a printed role was seated on an unevaluable probe, 1 bad input.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90
PR="$SCRIPTS_DIR/panel-roles.mjs"
# No pipeline.config.json here, so every predicate runs on its defaults.
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
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m change
}
CLEAN="$TEMP_PROJECT/r-clean"; make_diff_repo "$CLEAN" docs/notes.txt
DL="$TEMP_PROJECT/r-dl"; make_diff_repo "$DL" db/queries/orders.ts
INFRA="$TEMP_PROJECT/r-infra"; make_diff_repo "$INFRA" .github/workflows/ci.yml
FE="$TEMP_PROJECT/r-fe"; make_diff_repo "$FE" src/ui/Button.tsx
SEC="$TEMP_PROJECT/r-sec"; make_diff_repo "$SEC" src/auth/session.ts
TESTS="$TEMP_PROJECT/r-tests"; make_diff_repo "$TESTS" tests/login.test.ts
ALL="$TEMP_PROJECT/r-all"; make_diff_repo "$ALL" db/migrate/001_users.rb .github/workflows/ci.yml src/ui/Button.tsx src/app.ts
DL_FE="$TEMP_PROJECT/r-dl-fe"; make_diff_repo "$DL_FE" db/queries/orders.ts src/ui/Button.tsx
EMPTY="$TEMP_PROJECT/r-empty"; make_diff_repo "$EMPTY"
NOREPO="$TEMP_PROJECT/not-a-repo"; mkdir -p "$NOREPO"
NOBASE="$TEMP_PROJECT/r-nobase"; mkdir -p "$NOBASE"; git -C "$NOBASE" init -q
git -C "$NOBASE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m only

ART="$TEMP_PROJECT/art"; mkdir -p "$ART"
VC="$TEMP_PROJECT/art-vc"; mkdir -p "$VC"; printf '{}' > "$VC/visual-contract.json"

# st <name> <json> -> path of a status.json holding <json>
st() { printf '%s' "$2" > "$TEMP_PROJECT/$1.json"; printf '%s' "$TEMP_PROJECT/$1.json"; }
# pr <args...> -> OUT (stdout, newlines as spaces), ERR, RC
pr() {
  node "$PR" "$@" > "$TEMP_PROJECT/o" 2> "$TEMP_PROJECT/e"; RC=$?
  OUT="$(tr '\n' ' ' < "$TEMP_PROJECT/o" | sed 's/ $//')"; ERR="$(cat "$TEMP_PROJECT/e")"
}
full() {  # <tier> <cost_class or -> <worktree> [artifact dir] [extra args...]
  local tier="$1" cc="$2" wt="$3" art="${4:-$ART}"; shift 4 2>/dev/null || shift 3
  local json="{\"risk_tier\":\"$tier\"}"
  [[ "$cc" != "-" ]] && json="{\"risk_tier\":\"$tier\",\"cost_class\":\"$cc\"}"
  pr full --status "$(st "s-$tier-$cc" "$json")" --worktree "$wt" --artifact-dir "$art" "$@"
}

suite "full: the tier panels on a diff that touches no surface (exit 0, no note)"

full architectural - "$CLEAN"; assert_eq "architectural seats the six" "$OUT/$RC" "ba dba devops secops dev qa/0"
assert_eq "and says nothing on stderr" "$ERR" ""
full standard - "$CLEAN"; assert_eq "standard seats the four" "$OUT/$RC" "ba dev qa secops/0"
full trivial - "$CLEAN"; assert_eq "trivial seats qa secops" "$OUT/$RC" "qa secops/0"
full standard product "$CLEAN"; assert_eq "cost_class product is the tier panel" "$OUT" "ba dev qa secops"
full standard product-money "$DL"; assert_eq "cost_class product-money is the tier panel plus its probes" "$OUT" "ba dev qa secops dba"
full standard nonsense "$CLEAN"; assert_eq "an unknown cost_class in the record reads as product" "$OUT/$RC" "ba dev qa secops/0"
assert_eq "stdout is one role per line" "$(wc -l < "$TEMP_PROJECT/o" | tr -d ' ')" "4"

suite "full: the surface probes, per tier"

full standard - "$DL"; assert_eq "standard, data layer: + dba" "$OUT" "ba dev qa secops dba"
full standard - "$INFRA"; assert_eq "standard, infra: + devops" "$OUT" "ba dev qa secops devops"
full standard - "$FE"; assert_eq "standard, frontend: + design_review" "$OUT" "ba dev qa secops design_review"
full standard - "$SEC"; assert_eq "standard, security path alone seats nothing extra (secops already sits)" "$OUT" "ba dev qa secops"
full standard - "$ALL"; assert_eq "standard, multi-path diff over three surfaces: all three" "$OUT/$RC" "ba dev qa secops dba devops design_review/0"
full architectural - "$FE"; assert_eq "architectural, frontend: + design_review" "$OUT" "ba dba devops secops dev qa design_review"
full architectural - "$DL"; assert_eq "architectural, data layer: dba is not seated twice" "$OUT" "ba dba devops secops dev qa"
full trivial - "$DL"; assert_eq "trivial, data layer: no dba (the tripwire re-tiers instead)" "$OUT" "qa secops"
full trivial - "$INFRA"; assert_eq "trivial, infra: no devops" "$OUT" "qa secops"
full trivial - "$FE"; assert_eq "trivial, frontend: + design_review (every tier)" "$OUT" "qa secops design_review"

suite "full: art_director sits only when visual-contract.json exists"

full standard - "$CLEAN" "$VC"; assert_eq "standard with a contract: + art_director" "$OUT" "ba dev qa secops art_director"
full trivial - "$FE" "$VC"; assert_eq "trivial frontend with a contract: design_review then art_director" "$OUT" "qa secops design_review art_director"
full architectural - "$CLEAN" "$VC"; assert_eq "architectural with a contract" "$OUT" "ba dba devops secops dev qa art_director"
full standard - "$CLEAN" "$ART"; assert_not_contains "CONTROL: no contract, no art_director" "$OUT" "art_director"

suite "full: the tooling exception, at every tier"

for tier in architectural standard trivial; do
  full "$tier" tooling "$INFRA"; assert_eq "[$tier] tooling, infra: qa secops devops" "$OUT/$RC" "qa secops devops/0"
  full "$tier" tooling "$DL"; assert_eq "[$tier] tooling, data layer: qa secops dba" "$OUT" "qa secops dba"
  full "$tier" tooling "$FE"; assert_eq "[$tier] tooling, frontend: qa secops design_review" "$OUT" "qa secops design_review"
  full "$tier" tooling "$CLEAN"; assert_eq "[$tier] tooling, no surface: qa secops dev" "$OUT" "qa secops dev"
done
full standard tooling "$ALL"; assert_eq "tooling order: devops before dba and design_review" "$OUT" "qa secops devops"
full standard tooling "$DL_FE"; assert_eq "tooling order: dba before design_review" "$OUT" "qa secops dba"
full standard tooling "$FE" "$VC"; assert_eq "a tooling panel omits art_director even with a contract" "$OUT" "qa secops design_review"
full standard tooling "$CLEAN"; assert_contains "the tooling panel is announced as a PANEL-NOTE" "$ERR" "PANEL-NOTE: cost_class tooling panel: qa secops dev (one round)."
full standard product "$CLEAN" "$ART" --cost-class tooling
assert_eq "--cost-class tooling overrides the record" "$OUT" "qa secops dev"

suite "full: an unevaluable probe SEATS the role, exits 21 and says which"

full standard - "$NOREPO"
assert_eq "not a git repo: standard seats all three probe roles, exit 21" "$OUT/$RC" "ba dev qa secops dba devops design_review/21"
assert_contains "git's failure is named with its exit status" "$ERR" "SURFACE-INDETERMINATE: git diff --name-only -z exited"
assert_contains "dba's seat is noted" "$ERR" "PANEL-NOTE: dba SEATED on an INDETERMINATE data-layer probe, not on a match."
assert_contains "devops's seat is noted" "$ERR" "PANEL-NOTE: devops SEATED on an INDETERMINATE infra probe, not on a match."
assert_contains "design_review's seat is noted" "$ERR" "PANEL-NOTE: design_review SEATED on an INDETERMINATE frontend probe, not on a match."
full standard - "$NOBASE"; assert_eq "a repo with no origin/main: the same seats, exit 21" "$OUT/$RC" "ba dev qa secops dba devops design_review/21"
full standard - "$EMPTY"; assert_eq "an EMPTY diff is indeterminate, never clean" "$OUT/$RC" "ba dev qa secops dba devops design_review/21"
assert_contains "and says so" "$ERR" "empty path list: an unread diff is not a clean diff"
full architectural - "$NOREPO"; assert_eq "architectural: only design_review rides on a probe" "$OUT/$RC" "ba dba devops secops dev qa design_review/21"
assert_not_contains "and dba, seated by tier, gets no note" "$ERR" "PANEL-NOTE: dba"
full trivial - "$NOREPO"; assert_eq "trivial: design_review on the frontend probe, exit 21" "$OUT/$RC" "qa secops design_review/21"
full standard tooling "$NOREPO"; assert_eq "tooling: the first specialist in order is seated on indeterminacy" "$OUT/$RC" "qa secops devops/21"
assert_contains "and noted" "$ERR" "PANEL-NOTE: devops SEATED on an INDETERMINATE infra probe"
full standard - "$FE"; assert_eq "CONTROL: a real probe run exits 0" "$RC" "0"
assert_not_contains "and prints no PANEL-NOTE" "$ERR" "PANEL-NOTE"

suite "full: bad input exits 1 and prints no roles"

pr full --status "$(st s-notier '{"cost_class":"product"}')" --worktree "$CLEAN" --artifact-dir "$ART"
assert_eq "absent risk_tier: exit 1, empty stdout (absence is not trivial)" "$RC/$OUT" "1/"
assert_contains "and names the field" "$ERR" "risk_tier"
pr full --status "$(st s-badtier '{"risk_tier":"huge"}')" --worktree "$CLEAN" --artifact-dir "$ART"
assert_eq "unknown risk_tier: exit 1" "$RC" "1"
printf '{not json' > "$TEMP_PROJECT/s-broken.json"
pr full --status "$TEMP_PROJECT/s-broken.json" --worktree "$CLEAN" --artifact-dir "$ART"; assert_eq "unreadable status.json: exit 1" "$RC" "1"
pr full --status "$TEMP_PROJECT/missing.json" --worktree "$CLEAN" --artifact-dir "$ART"; assert_eq "missing status.json: exit 1" "$RC" "1"
STD="$(st s-std '{"risk_tier":"standard"}')"
pr full --status "$STD" --artifact-dir "$ART"; assert_eq "missing --worktree: exit 1" "$RC" "1"
pr full --status "$STD" --worktree "$CLEAN"; assert_eq "missing --artifact-dir: exit 1" "$RC" "1"
pr full --status "$STD" --worktree "$CLEAN" --artifact-dir "$ART" --frobnicate; assert_eq "unknown argument: exit 1" "$RC" "1"
pr full --status "$STD" --worktree "$CLEAN" --artifact-dir "$ART" --cost-class cheap; assert_eq "unknown --cost-class: exit 1" "$RC" "1"
pr full --status "$STD" --worktree "$CLEAN" --artifact-dir "$ART" --base --output=x; assert_eq "a --base that is an option: exit 1" "$RC" "1"
pr --status "$STD"; assert_eq "no subcommand: exit 1" "$RC" "1"
pr panel --status "$STD"; assert_eq "unknown subcommand: exit 1" "$RC" "1"

suite "full --write: panel_roles and flags, nothing else"

W="$(st s-write '{"risk_tier":"standard","cost_class":"product","events":[{"phase":"4-review","at":"x"}],"flags":[{"phase":"3","agent":"dev","at":"y"}]}')"
cp "$W" "$TEMP_PROJECT/s-write.before"
pr full --status "$W" --worktree "$DL" --artifact-dir "$ART"
assert_eq "without --write the record is byte-identical" "$(cmp -s "$W" "$TEMP_PROJECT/s-write.before" && echo same || echo changed)" "same"
pr full --status "$W" --worktree "$NOREPO" --artifact-dir "$ART" --write
jqr() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(eval(process.argv[2]))' "$1" "$2"; }
assert_eq "--write records panel_roles as printed" "$(jqr "$W" 's.panel_roles.join(" ")')" "$OUT"
assert_eq "and appends one flag per PANEL-NOTE, after the existing one" "$(jqr "$W" 's.flags.length')" "4"
assert_eq "each flag is a schema-shaped 4-review entry" "$(jqr "$W" 's.flags.slice(1).every(f=>f.phase==="4-review"&&f.agent==="panel-roles"&&f.at&&f.summary.startsWith("PANEL-NOTE: ")&&f.summary.length<=140)')" "true"
assert_eq "other fields survive" "$(jqr "$W" 's.events.length+"-"+s.cost_class')" "1-product"
assert_eq "no absolute path reaches the record" "$(grep -c "$TEMP_PROJECT\|not-a-repo" "$W" | tr -d ' ')" "0"
pr full --status "$W" --worktree "$NOREPO" --artifact-dir "$ART" --write
assert_eq "a second --write does not duplicate the flags" "$(jqr "$W" 's.flags.length')" "4"
pr full --status "$W" --worktree "$CLEAN" --artifact-dir "$ART" --write
assert_eq "a clean re-run rewrites panel_roles" "$(jqr "$W" 's.panel_roles.join(" ")')" "ba dev qa secops"

# ---- delta -----------------------------------------------------------------------------------
PANEL='"panel_roles":["ba","dev","qa","secops","dba"]'
DS="$(st d-product "{$PANEL}")"
DT="$(st d-tooling "{$PANEL,\"cost_class\":\"tooling\"}")"
peer() { printf '%s' "$2" > "$TEMP_PROJECT/$1.json"; printf '%s' "$TEMP_PROJECT/$1.json"; }
NONE="$(peer p-none '{"qa":{"verdict":"APPROVE_WITH_NOTES","materiality":{"open_blocker_ids":[],"blocks_merge":false}}}')"
BLOCK="$(peer p-block '{"qa":{"verdict":"REQUEST_CHANGES","materiality":{"open_blocker_ids":["qa-1"],"blocks_merge":true}},"ba":{"verdict":"APPROVE_WITH_NOTES","verdict_as_returned":"REQUEST_CHANGES","materiality":{"open_blocker_ids":[],"blocks_merge":false}},"secops":{"verdict":"APPROVE","materiality":{"open_blocker_ids":[],"blocks_merge":false}}}')"
LEGACY="$(peer p-legacy '{"dba":{"verdict":"REQUEST_CHANGES","materiality":{"blocks_merge":true,"blocking_concerns":1}},"qa":{"verdict":"APPROVE","materiality":{"blocks_merge":false}}}')"
DESIGN="$(peer p-design '{"design_review":{"verdict":"REQUEST_CHANGES","materiality":{"open_blocker_ids":["design_review-1"],"blocks_merge":true}}}')"
SECOPS="$(peer p-secops '{"secops":{"verdict":"REQUEST_CHANGES","materiality":{"open_blocker_ids":["secops-1"],"blocks_merge":true}}}')"
printf '{not json' > "$TEMP_PROJECT/p-bad.json"
delta() {  # <status> <peer-review> <worktree> [extra...]
  local s="$1" p="$2" wt="$3"; shift 3
  pr delta --status "$s" --worktree "$wt" --first-round-head origin/main --peer-review "$p" "$@"
}

suite "delta: the seed is the roles holding open blocker ids"

delta "$DS" "$BLOCK" "$CLEAN"; assert_eq "a role with an open blocker id is seeded; a downgraded one and an approval are not" "$OUT/$RC" "qa/0"
delta "$DS" "$NONE" "$CLEAN"; assert_eq "no open blockers and a clean fix: empty set, exit 0" "$OUT/$RC" "/0"
delta "$DS" "$LEGACY" "$CLEAN"; assert_eq "a LEGACY blocks_merge:true block is reseated" "$OUT" "dba"
delta "$DS" "$DESIGN" "$FE"; assert_eq "design_review re-sits while it holds an open blocker" "$OUT" "design_review"
delta "$DS" "$TEMP_PROJECT/p-bad.json" "$CLEAN"
assert_eq "an UNREADABLE peer-review.json seeds the FULL panel, exit 21" "$OUT/$RC" "ba dev qa secops dba/21"
assert_contains "and says so" "$ERR" "PANEL-NOTE: open blocker ids UNREADABLE from peer-review.json; the delta seeds the FULL panel (ba dev qa secops dba)."
delta "$DS" "$TEMP_PROJECT/p-missing.json" "$CLEAN"; assert_eq "a MISSING peer-review.json does the same" "$OUT/$RC" "ba dev qa secops dba/21"

suite "delta: a role by surface only where its merge-class surface changed"

delta "$DS" "$NONE" "$DL"; assert_eq "product, data layer: dba and secops" "$OUT" "dba secops"
delta "$DT" "$NONE" "$DL"; assert_eq "tooling, data layer: dba only" "$OUT" "dba"
delta "$DS" "$NONE" "$SEC"; assert_eq "product, security path: secops" "$OUT" "secops"
delta "$DT" "$NONE" "$SEC"; assert_eq "tooling, security path: secops still" "$OUT" "secops"
delta "$DS" "$NONE" "$TESTS"; assert_eq "a test file: qa" "$OUT" "qa"
delta "$DS" "$NONE" "$INFRA"; assert_eq "product, infra: devops" "$OUT" "devops"
delta "$DT" "$NONE" "$INFRA"; assert_eq "tooling, infra: nobody (CI config IS the change)" "$OUT/$RC" "/0"
delta "$DS" "$NONE" "$FE"; assert_eq "a frontend fix reseats nobody (no merge-class surface)" "$OUT" ""
delta "$DS" "$SECOPS" "$DL"; assert_eq "a seeded role is not listed twice" "$OUT" "secops dba"
delta "$DS" "$NONE" "$DL" --cost-class tooling; assert_eq "--cost-class tooling overrides the record" "$OUT" "dba"

suite "delta: an unevaluable probe seats, exit 21"

delta "$DS" "$NONE" "$NOREPO"; assert_eq "product, not a repo: dba secops qa devops, exit 21" "$OUT/$RC" "dba secops qa devops/21"
assert_contains "dba noted" "$ERR" "PANEL-NOTE: dba SEATED on an INDETERMINATE data-layer probe"
assert_contains "qa noted on the test-surface probe" "$ERR" "PANEL-NOTE: qa SEATED on an INDETERMINATE test-surface probe"
delta "$DT" "$NONE" "$NOREPO"; assert_eq "tooling, not a repo: dba secops qa (no devops)" "$OUT/$RC" "dba secops qa/21"
assert_contains "tooling secops is noted on the security-surface probe" "$ERR" "PANEL-NOTE: secops SEATED on an INDETERMINATE security-surface probe"
delta "$DS" "$NONE" "$EMPTY"; assert_eq "an empty fix diff is indeterminate" "$RC" "21"
delta "$DS" "$SECOPS" "$NOREPO"; assert_not_contains "a SEEDED role seated again by indeterminacy gets no note" "$ERR" "PANEL-NOTE: secops"
PURE="$(SCRIPT="$PR" node --input-type=module -e '
  const m = await import(process.env.SCRIPT);
  const r = m.composeDelta({ fullPanel: ["qa"], seed: [], costClass: "product", probes: { dataLayer: "indeterminate", security: "match", tests: "no-match", infra: "no-match" } });
  console.log(r.roles.join(" ") + "|" + r.notes.join(";") + "|" + r.indeterminate);')"
assert_eq "secops seated by a MATCH is not noted when its other surface was indeterminate" "$PURE" "dba secops|dba SEATED on an INDETERMINATE data-layer probe, not on a match.|true"

suite "delta: bad input exits 1"

pr delta --status "$(st d-nopanel '{}')" --worktree "$CLEAN" --first-round-head origin/main --peer-review "$NONE"
assert_eq "no panel_roles on the record: exit 1" "$RC" "1"
pr delta --status "$DS" --worktree "$CLEAN" --first-round-head "<FIRST_ROUND_HEAD>" --peer-review "$NONE"
assert_eq "an unsubstituted <FIRST_ROUND_HEAD>: exit 1, not a quiet over-seat" "$RC/$OUT" "1/"
assert_contains "and names the flag" "$ERR" "--first-round-head"
pr delta --status "$DS" --worktree "$CLEAN" --peer-review "$NONE"; assert_eq "missing --first-round-head: exit 1" "$RC" "1"
pr delta --status "$DS" --worktree "$CLEAN" --first-round-head origin/main; assert_eq "missing --peer-review: exit 1" "$RC" "1"

suite "delta --write: flags only, panel_roles untouched"

DW="$(st d-write "{$PANEL}")"
delta "$DW" "$NONE" "$NOREPO" --write
assert_eq "panel_roles stays the full panel" "$(jqr "$DW" 's.panel_roles.join(" ")')" "ba dev qa secops dba"
assert_eq "the four notes are flags" "$(jqr "$DW" 's.flags.length')" "4"

suite "the removed bash stays removed from the prose"

PROSE_FILES=("$PLUGIN_ROOT"/commands/*.md "$PLUGIN_ROOT"/orchestrator/*.md "$PLUGIN_ROOT"/agents/*.md "$PLUGIN_ROOT"/shared/*.md)
prose_count() { cat "${PROSE_FILES[@]}" | grep -cF -- "$1" | tr -d ' '; }
for gone in 'surface_probe' 'PANEL_ROLES="' 'OBJECTING_ROLES' 'FIX_CHANGED_PATHS' 'process.exit(f(paths)?0:20)' 'for role in $' 'visual-contract.json" ] &&' 'SPECIALIST="dev"'; do
  assert_eq "no prose file carries: $gone" "$(prose_count "$gone")" "0"
done
OLD="$TEMP_PROJECT/old-prose.md"
if git -C "$PLUGIN_ROOT" show 71a2ef9:plugins/pipeline/orchestrator/phase-4-delta.md > "$OLD" 2>/dev/null; then
  assert_eq "CONTROL: the same grep finds surface_probe in the pre-#164 delta file" "$(grep -cF 'surface_probe' "$OLD" | tr -d ' ')" "5"
else
  printf 'surface_probe data-layer-surface.mjs diffTouchesDataLayer < "$P"\n' > "$OLD"
  assert_eq "CONTROL: the same grep finds surface_probe in a planted copy (history unavailable)" "$(grep -cF 'surface_probe' "$OLD" | tr -d ' ')" "1"
fi
PANEL_MD="$PLUGIN_ROOT/orchestrator/phase-4-panel.md"
DELTA_MD="$PLUGIN_ROOT/orchestrator/phase-4-delta.md"
assert_contains "phase-4-panel.md calls panel-roles.mjs full" "$(cat "$PANEL_MD")" 'scripts/panel-roles.mjs" full --status'
assert_contains "phase-4-delta.md calls panel-roles.mjs delta" "$(cat "$DELTA_MD")" 'scripts/panel-roles.mjs" delta --status'
assert_contains "phase-4-panel.md says what exit 21 obliges" "$(cat "$PANEL_MD")" '- **21**: the same, and at least one role was seated'
assert_contains "phase-4-delta.md states exit 21" "$(cat "$DELTA_MD")" 'Exit **21**'
assert_contains "phase.md points both runs at the script" "$(cat "$PLUGIN_ROOT/commands/phase.md")" 'panel-roles.mjs delta'
assert_contains "art-director-contract.md Duty B defers to the script" "$(cat "$PLUGIN_ROOT/orchestrator/art-director-contract.md")" 'panel-roles.mjs full'
assert_eq "no bare \$1 in the panel or delta prose (template substitution)" "$(cat "$PANEL_MD" "$DELTA_MD" | grep -c '\$[1-9]' | tr -d ' ')" "0"

finish
