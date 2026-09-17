#!/usr/bin/env bash
# Phase 4 panel composition, and the ONE thing about it that is a control rather than a
# convenience: what it does when a surface check cannot be evaluated at all.
#
# THE ESCAPES THIS SUITE EXISTS FOR. (1) Issue #17: a two-outcome `process.exit(pred?0:1)` probe
# against a stale ${CLAUDE_PLUGIN_ROOT} exited 1 with zero bytes on both streams, byte-identical
# to "the diff misses the surface", and DBA and DevOps were dropped from a panel. (2) #20: the
# frontend twin of that probe did the same a round later. (3) The zsh escape: a multi-path diff
# passed through an unquoted shell variable arrived as ONE argument under zsh and matched nothing.
# (4) The `$1` template substitution: the probe lived in slash-command prose whose loader rewrites
# bare `$N` tokens before a shell runs it.
#
# Since #164 the composition is scripts/panel-roles.mjs, and the prose carries one call. The fail
# direction is unchanged: an unevaluable probe SEATS the role (exit 21, with a PANEL-NOTE), and a
# script that cannot run at all HALTS (any exit other than 0 or 21, empty stdout). Every case
# below runs the call EXTRACTED FROM the orchestrator prose, because the shipped artifact is that
# text. The roster rules themselves are pinned in test-panel-roles.sh.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

pipeline_md_concat "$PLUGIN_ROOT" || exit 90
PIPELINE_MD="$PIPELINE_MD_CONCAT"
PHASE_MD="$PLUGIN_ROOT/commands/phase.md"

# ---- extraction -------------------------------------------------------------
FULL_CALL="$TEMP_PROJECT/full-call.sh"
awk '/^node "\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/panel-roles.mjs" full /{f=1} f&&/^```$/{exit} f{print}' "$PIPELINE_MD" > "$FULL_CALL"
DELTA_CALL="$TEMP_PROJECT/delta-call.sh"
awk '/^node "\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/panel-roles.mjs" delta /{f=1} f&&/^```$/{exit} f{print}' "$PIPELINE_MD" > "$DELTA_CALL"

suite "the calls under test were extracted (without this, every case below measures an empty file)"

assert_eq "the full-panel call is non-empty" "$([[ -s "$FULL_CALL" ]] && echo yes || echo no)" "yes"
assert_eq "the delta call is non-empty" "$([[ -s "$DELTA_CALL" ]] && echo yes || echo no)" "yes"
assert_eq "the orchestrator prose carries exactly one call of each" \
  "$(grep -c '^node "${CLAUDE_PLUGIN_ROOT}/scripts/panel-roles.mjs" \(full\|delta\) ' "$PIPELINE_MD" | tr -d ' ')" "2"
assert_contains "the full call writes the record" "$(cat "$FULL_CALL")" "--write"
assert_contains "and the roles file the merge reads" "$(cat "$FULL_CALL")" '> "$ARTIFACT_DIR/roles-to-merge.txt"'
assert_eq "neither call is piped (a pipe discards the exit status, which is the contract)" \
  "$(cat "$FULL_CALL" "$DELTA_CALL" | grep -c '| *[a-z]' | tr -d ' ')" "0"
assert_eq "no bare \$N token survives in either call (template substitution)" \
  "$(cat "$FULL_CALL" "$DELTA_CALL" | grep -c '\$[0-9]' | tr -d ' ')" "0"

# ---- fixtures ---------------------------------------------------------------
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
DL_REPO="$TEMP_PROJECT/repo-datalayer"; make_diff_repo "$DL_REPO" "db/queries/orders.ts"
FE_REPO="$TEMP_PROJECT/repo-frontend"; make_diff_repo "$FE_REPO" "src/ui/Button.tsx"
CLEAN_REPO="$TEMP_PROJECT/repo-clean"; make_diff_repo "$CLEAN_REPO" "docs/notes.txt"
DL_MULTI="$TEMP_PROJECT/repo-datalayer-multi"; make_diff_repo "$DL_MULTI" "db/migrate/001_add_users.rb" "src/app.ts"
INFRA_MULTI="$TEMP_PROJECT/repo-infra-multi"; make_diff_repo "$INFRA_MULTI" ".github/workflows/ci.yml" "src/app.ts"
FE_MULTI="$TEMP_PROJECT/repo-frontend-multi"; make_diff_repo "$FE_MULTI" "src/ui/Button.tsx" "src/lib/util.ts"
CLEAN_MULTI="$TEMP_PROJECT/repo-clean-multi"; make_diff_repo "$CLEAN_MULTI" "docs/notes.txt" "docs/more.txt"
EMPTY_REPO="$TEMP_PROJECT/repo-empty-diff"; make_diff_repo "$EMPTY_REPO"
NO_REMOTE="$TEMP_PROJECT/repo-no-origin-main"; mkdir -p "$NO_REMOTE"; git -C "$NO_REMOTE" init -q
git -C "$NO_REMOTE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m only

GOOD_ROOT="$PLUGIN_ROOT"
BROKEN_ROOT="$TEMP_PROJECT/stale-plugin-cache"; mkdir -p "$BROKEN_ROOT"
THROW_ROOT="$TEMP_PROJECT/throwing-plugin"; mkdir -p "$THROW_ROOT/scripts"
cp "$SCRIPTS_DIR"/*.mjs "$SCRIPTS_DIR"/*.json "$THROW_ROOT/scripts/" 2>/dev/null
printf 'throw new Error("boom on import");\n' > "$THROW_ROOT/scripts/data-layer-surface.mjs"

export CLAUDE_PROJECT_DIR="$TEMP_PROJECT"
PB="$TEMP_PROJECT/pb"; mkdir -p "$PB/42"
ARTD="$TEMP_PROJECT/artifacts"; mkdir -p "$ARTD"

# Runners: bash, bash with IFS emptied (field splitting disabled, the zsh defect condition in a
# shell every checkout has), and real zsh when present (declared through optional_tool).
RUNNERS=(bash bash-nosplit)
if optional_tool zsh; then RUNNERS+=(zsh); fi
in_shell() {  # $1 = runner, $2 = script text; stdout only
  case "$1" in
    bash)         bash -c "$2" 2>/dev/null ;;
    bash-nosplit) bash -c "IFS=; $2" 2>/dev/null ;;
    zsh)          zsh  -c "$2" 2>/dev/null ;;
  esac
}

# run_call <call file> <runner> <worktree> <plugin root> <status json> -> "RC=<n> ROLES=<a b c>"
run_call() {
  local call="$1" runner="$2" wt="$3" root="$4"
  printf '%s' "$5" > "$PB/42/status.json"
  rm -f "$ARTD/roles-to-merge.txt"
  sed -e "s#<issue>#42#g; s#<WORKTREE_PATH>#$wt#g; s#<FIRST_ROUND_HEAD>#origin/main#g" "$call" > "$TEMP_PROJECT/call.sh"
  CLAUDE_PLUGIN_ROOT="$root" PIPELINE_BASE="$PB" ARTIFACT_DIR="$ARTD" \
    in_shell "$runner" ". \"$TEMP_PROJECT/call.sh\"; RC=\$?; printf 'RC=%s ROLES=' \"\$RC\"; while IFS= read -r r; do printf '%s ' \"\$r\"; done < \"\$ARTIFACT_DIR/roles-to-merge.txt\""
}
STD='{"risk_tier":"standard"}'
DELTA_ST='{"panel_roles":["ba","dev","qa","secops"]}'
printf '%s' '{"qa":{"verdict":"APPROVE","materiality":{"open_blocker_ids":[],"blocks_merge":false}}}' > "$ARTD/peer-review.json"
full_run() { run_call "$FULL_CALL" "${3:-bash}" "$1" "$2" "$STD"; }
delta_run() { run_call "$DELTA_CALL" "${3:-bash}" "$1" "$2" "$DELTA_ST"; }

suite "NON-ZERO CONTROLS FIRST: with working modules the call discriminates"

assert_eq "a data-layer path seats dba and nothing else extra" "$(full_run "$DL_REPO" "$GOOD_ROOT")" "RC=0 ROLES=ba dev qa secops dba "
assert_eq "a frontend path seats design_review and nothing else extra" "$(full_run "$FE_REPO" "$GOOD_ROOT")" "RC=0 ROLES=ba dev qa secops design_review "
assert_eq "a diff that touches no surface seats nobody" "$(full_run "$CLEAN_REPO" "$GOOD_ROOT")" "RC=0 ROLES=ba dev qa secops "
assert_eq "--write recorded the panel the call printed" \
  "$(full_run "$DL_REPO" "$GOOD_ROOT" >/dev/null; node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).panel_roles.join(" "))' "$PB/42/status.json")" \
  "ba dev qa secops dba"

suite "THE BLOCKER: an unevaluable probe seats the specialist instead of silently dropping it"

for runner in "${RUNNERS[@]}"; do
  assert_eq "[$runner] a diff with NO paths seats all three probe roles, exit 21" \
    "$(full_run "$EMPTY_REPO" "$GOOD_ROOT" "$runner")" "RC=21 ROLES=ba dev qa secops dba devops design_review "
  assert_eq "[$runner] a WORKTREE_PATH that is not a git repo does the same" \
    "$(full_run "$TEMP_PROJECT/does-not-exist" "$GOOD_ROOT" "$runner")" "RC=21 ROLES=ba dev qa secops dba devops design_review "
  assert_eq "[$runner] a repo with no origin/main does the same" \
    "$(full_run "$NO_REMOTE" "$GOOD_ROOT" "$runner")" "RC=21 ROLES=ba dev qa secops dba devops design_review "
done
assert_eq "the indeterminate panel is materially different from the clean-diff panel" \
  "$([[ "$(full_run "$EMPTY_REPO" "$GOOD_ROOT")" == "$(full_run "$CLEAN_REPO" "$GOOD_ROOT")" ]] && echo IDENTICAL || echo different)" "different"
assert_eq "the seats are recorded as PANEL-NOTE flags, one per seat" \
  "$(full_run "$NO_REMOTE" "$GOOD_ROOT" >/dev/null; node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).flags.map(f=>f.summary.split(" ")[1]).join(" "))' "$PB/42/status.json")" \
  "dba devops design_review"

suite "a script that cannot RUN halts: it never impersonates a clean diff"

# The #17 and #20 shape: a stale plugin root. The old probe read that as "no match"; the call now
# exits with node's own failure code and prints no roles, and the prose halts on it.
BROKEN_OUT="$(full_run "$FE_REPO" "$BROKEN_ROOT")"
assert_not_contains "a plugin root with no scripts/ does not exit 0" "$BROKEN_OUT" "RC=0 "
assert_not_contains "nor 21" "$BROKEN_OUT" "RC=21 "
assert_contains "and yields no roles to dispatch" "$BROKEN_OUT" "ROLES="
assert_eq "so it can never equal the clean-diff answer" \
  "$([[ "$BROKEN_OUT" == "$(full_run "$CLEAN_REPO" "$GOOD_ROOT")" ]] && echo IDENTICAL || echo different)" "different"
THROW_OUT="$(full_run "$CLEAN_REPO" "$THROW_ROOT")"
assert_eq "a surface module that THROWS on import halts the same way, with no roles" \
  "$(case "$THROW_OUT" in "RC=0 "*|"RC=21 "*) echo DISPATCHABLE ;; *" ROLES=") echo halted ;; *) echo "OTHER: $THROW_OUT" ;; esac)" "halted"
assert_contains "the prose halts on any exit other than 0 and 21" "$(cat "$PIPELINE_MD")" \
  '**Any other exit** is a failure to run: halt, and do not dispatch from the file.'

suite "THE ZSH ESCAPE: the same answer in every cell of shell x path count"

for runner in "${RUNNERS[@]}"; do
  assert_eq "[$runner] MULTI-path data-layer diff seats dba" "$(full_run "$DL_MULTI" "$GOOD_ROOT" "$runner")" "RC=0 ROLES=ba dev qa secops dba "
  assert_eq "[$runner] MULTI-path infra diff seats devops" "$(full_run "$INFRA_MULTI" "$GOOD_ROOT" "$runner")" "RC=0 ROLES=ba dev qa secops devops "
  assert_eq "[$runner] MULTI-path frontend diff seats design_review" "$(full_run "$FE_MULTI" "$GOOD_ROOT" "$runner")" "RC=0 ROLES=ba dev qa secops design_review "
  assert_eq "[$runner] MULTI-path clean diff seats nobody" "$(full_run "$CLEAN_MULTI" "$GOOD_ROOT" "$runner")" "RC=0 ROLES=ba dev qa secops "
  assert_eq "[$runner] delta: a MULTI-path data-layer fix seats dba and secops" "$(delta_run "$DL_MULTI" "$GOOD_ROOT" "$runner")" "RC=0 ROLES=dba secops "
  assert_eq "[$runner] delta: a MULTI-path infra fix seats devops" "$(delta_run "$INFRA_MULTI" "$GOOD_ROOT" "$runner")" "RC=0 ROLES=devops "
  assert_eq "[$runner] delta: a MULTI-path frontend fix reseats nobody" "$(delta_run "$FE_MULTI" "$GOOD_ROOT" "$runner")" "RC=0 ROLES="
  assert_eq "[$runner] delta: an unreadable diff seats every merge-class role, exit 21" \
    "$(delta_run "$TEMP_PROJECT/does-not-exist" "$GOOD_ROOT" "$runner")" "RC=21 ROLES=dba secops qa devops "
done

suite "THE PLACEHOLDER: an unsubstituted first-round head refuses instead of over-seating"

UNSUB="$(printf '%s' "$DELTA_ST" > "$PB/42/status.json"; rm -f "$ARTD/roles-to-merge.txt"
  sed -e "s#<issue>#42#g; s#<WORKTREE_PATH>#$DL_REPO#g" "$DELTA_CALL" > "$TEMP_PROJECT/unsub.sh"
  CLAUDE_PLUGIN_ROOT="$GOOD_ROOT" PIPELINE_BASE="$PB" ARTIFACT_DIR="$ARTD" bash -c ". \"$TEMP_PROJECT/unsub.sh\"; echo \"RC=\$?\"" 2>&1)"
assert_contains "the verbatim placeholder exits 1" "$UNSUB" "RC=1"
assert_contains "and names the flag" "$UNSUB" "--first-round-head"
assert_eq "and creates no file named after the placeholder" "$([[ -e "$TEMP_PROJECT/FIRST_ROUND_HEAD" ]] && echo CREATED || echo none)" "none"

suite "the MANUAL entry point carries the same contract and keeps no second copy"

sec="$(awk '/^### peer-review$/{f=1;next} f&&/^### /{exit} f{print}' "$PHASE_MD")"
assert_eq "phase.md has a peer-review section to check" "$([[ -n "$sec" ]] && echo present || echo ABSENT)" "present"
assert_contains "it calls panel-roles.mjs full" "$sec" "panel-roles.mjs full"
assert_contains "it calls panel-roles.mjs delta" "$sec" "panel-roles.mjs delta"
assert_contains "it states the seat-on-indeterminate exit" "$sec" "21"
assert_contains "and the PANEL-NOTE that goes with it" "$sec" "PANEL-NOTE"
assert_contains "it forbids piping the call" "$sec" "never pipe the call"
assert_eq "phase.md keeps no probe body of its own" "$(grep -c 'process.exit(\|surface_probe' "$PHASE_MD" | tr -d ' ')" "0"
assert_eq "CONTROL: the same grep finds a planted probe body" \
  "$(printf 'surface_probe data-layer-surface.mjs diffTouchesDataLayer\n' | grep -c 'process.exit(\|surface_probe' | tr -d ' ')" "1"

finish
