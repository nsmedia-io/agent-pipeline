#!/usr/bin/env bash
# The mis-tier tripwire, END TO END, across the seam. Issue #17.
#
# WHY THIS SUITE EXISTS SEPARATELY FROM test-data-layer-surface.sh
# ----------------------------------------------------------------
# That suite proves the PREDICATE is right. This one proves the predicate is WIRED right, and
# the two are different failures. The production defect this issue closes is not a wrong
# regex in a module; it is a correct decision that the shell around it discards. So every case
# below EXTRACTS the bash block the orchestrator actually executes from commands/pipeline.md
# and RUNS it. A hand-copied restatement of that block would be a restatement of the contract
# rather than an observation of it, and would track whoever last remembered to update it.
#
# THE FAIL DIRECTION IS THE POINT (spec R4a / C1). The tripwire fails CLOSED: module absent,
# unparseable, throwing, or exiting non-zero => HALT as indeterminate, loop back to BA, NEVER
# proceed to the panel on an unevaluated tripwire. The model resolver in the same change fails
# OPEN (omit the key). Opposite directions, both deliberate; an implementer "handling a missing
# module consistently" breaks one of them, which is why AC38 below is ONE composite run rather
# than two criteria that each pass alone.
#
# WHAT DEV MUST PROVIDE FOR THIS SUITE TO GO GREEN
# ------------------------------------------------
# The `### Mis-tier tripwire` section of commands/pipeline.md must carry a self-contained bash
# block that, given WORKTREE_PATH, RISK_TIER and CLAUDE_PLUGIN_ROOT in the environment:
#   * prints a line containing MIS-TIER when the diff carries a data-layer path;
#   * prints a line containing the literal 3-impl-tripwire-indeterminate when the surface
#     module cannot be evaluated (absent / throws / non-zero exit), for ANY diff;
#   * prints neither when the module is healthy and the diff carries no data-layer path;
#   * NEVER pipes the module invocation into anything, because a pipe discards the module's
#     exit status and is precisely how the pre-fix silent pass returns.
# Both literals are contract, not QA invention: MIS-TIER is what the block prints at
# origin/main, and 3-impl-tripwire-indeterminate is the phase value the spec names (R4a).
#
# Every fixture repository is created by `mktemp -d`. Nothing is committed to THIS repo under
# a path the narrow set matches: `tests/fixtures/migrations/0001.sql` was verified at spec time
# to TRIP the preset union, so the obvious fixture layout would make this repository halt on
# its own test data forever, with no config escape (R5c).

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"

# ---- module discovery (same contract as test-data-layer-surface.sh) ----------
DL_MODULE=""
for f in "$SCRIPTS_DIR"/*.mjs; do
  [[ -f "$f" ]] || continue
  if grep -q 'migrationGlobsForTripwire' "$f" 2>/dev/null; then DL_MODULE="$f"; break; fi
done
DL_BASENAME="data-layer-surface.mjs"
[[ -n "$DL_MODULE" ]] && DL_BASENAME="$(basename "$DL_MODULE")"

# ---- extract the block the orchestrator really runs -------------------------
# All fenced bash blocks under `### Mis-tier tripwire`, up to the next heading, concatenated.
# Concatenated rather than "the first one" so a Dev who splits the snippet across two fences
# is not failed for a formatting choice.
TRIPWIRE_BLOCK="$TEMP_PROJECT/tripwire-block.sh"
awk '
  /^### Mis-tier tripwire/ { inSec=1; next }
  inSec && /^##+ / { inSec=0 }
  inSec && /^```bash$/ { inFence=1; next }
  inSec && inFence && /^```$/ { inFence=0; next }
  inSec && inFence { print }
' "$PIPELINE_MD" > "$TRIPWIRE_BLOCK"

suite "the tripwire block is extractable and non-empty (the harness's own precondition)"

# If this fails, every behavioral case below is measuring the empty string, and a suite that
# quietly measures nothing is the failure this repo is built around. Asserted first, and
# loudly, rather than discovered as forty confusing downstream failures.
assert_eq "a bash block exists under '### Mis-tier tripwire' in commands/pipeline.md" \
  "$([[ -s "$TRIPWIRE_BLOCK" ]] && echo yes || echo no)" "yes"
assert_eq "the extracted block invokes git against the worktree under review" \
  "$(grep -c 'WORKTREE_PATH' "$TRIPWIRE_BLOCK" | tr -d ' ')" "1"

# ---- fixture repositories ---------------------------------------------------
# make_diff_repo <name> <path>... -> echoes the repo dir. `git diff origin/main...HEAD`
# inside it yields exactly the named paths, which is what the block under test consumes.
make_diff_repo() {
  local name="$1"; shift
  local dir="$TEMP_PROJECT/repo-$name" p
  mkdir -p "$dir"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  for p in "$@"; do
    mkdir -p "$dir/$(dirname "$p")"
    printf 'fixture\n' > "$dir/$p"
    git -C "$dir" add -- "$p"
  done
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m change
  printf '%s' "$dir"
}

REPO_DBMIG=$(make_diff_repo dbmig 'db/migrations/0042.sql')
REPO_SUPA=$(make_diff_repo supa 'supabase/migrations/x.sql')
REPO_ROOTMIG=$(make_diff_repo rootmig 'migrations/0001.sql')
REPO_CLEAN=$(make_diff_repo clean 'src/x.ts')

# ---- plugin roots, healthy and broken ---------------------------------------
# Each broken root is a PRECISE mutation of one condition, not a generically empty directory:
# a root missing everything would fail for reasons unrelated to the surface module.
ROOT_OK="$PLUGIN_DIR"

ROOT_ABSENT="$TEMP_PROJECT/root-absent"
mkdir -p "$ROOT_ABSENT"
cp -R "$PLUGIN_DIR/scripts" "$ROOT_ABSENT/scripts" 2>/dev/null
rm -f "$ROOT_ABSENT/scripts/$DL_BASENAME"

# The REAL live condition named in the spec: ${CLAUDE_PLUGIN_ROOT} resolving to a stale
# installed cache that predates this change and contains no such script at all.
ROOT_STALE="$TEMP_PROJECT/root-stale-cache"
mkdir -p "$ROOT_STALE"

ROOT_THROWS="$TEMP_PROJECT/root-throws"
mkdir -p "$ROOT_THROWS"
cp -R "$PLUGIN_DIR/scripts" "$ROOT_THROWS/scripts" 2>/dev/null
cat > "$ROOT_THROWS/scripts/$DL_BASENAME" <<'EOF'
throw new Error("surface module is unloadable in this deployment");
EOF

ROOT_EXITS="$TEMP_PROJECT/root-exits"
mkdir -p "$ROOT_EXITS"
cp -R "$PLUGIN_DIR/scripts" "$ROOT_EXITS/scripts" 2>/dev/null
cat > "$ROOT_EXITS/scripts/$DL_BASENAME" <<'EOF'
process.exit(7);
EOF

# run_tripwire <plugin-root> <repo> -- returns the block's combined output.
# CLAUDE_PROJECT_DIR is the fixture repo, so the block reads THAT repo's pipeline.config.json
# and never this checkout's.
run_tripwire() {
  local root="$1" repo="$2"
  ( cd "$repo" \
      && CLAUDE_PLUGIN_ROOT="$root" \
         WORKTREE_PATH="$repo" \
         CLAUDE_PROJECT_DIR="$repo" \
         RISK_TIER="standard" \
         ARTIFACT_DIR="$repo/.pipeline/17" \
         bash "$TRIPWIRE_BLOCK" 2>&1 )
}

# write_config <repo> <json>
write_config() { printf '%s' "$2" > "$1/pipeline.config.json"; }

# classify <output> -> indeterminate | mis-tier | silent
# A three-valued verdict rather than two independent `not.toContain` checks. Two absence
# checks over the same output BOTH pass when the block produced nothing at all, so a block
# that cannot run reads as "correctly did not halt" -- the exact silent pass this issue is
# about. One classifier forces every case to name which of the three states it expects.
classify() {
  case "$1" in
    *"$INDET"*) printf 'indeterminate' ;;
    *MIS-TIER*) printf 'mis-tier' ;;
    *) printf 'silent' ;;
  esac
}
INDET="3-impl-tripwire-indeterminate"

# =============================================================================
# AC1 / AC2 -- the two paths that ship the production bug today, END TO END.
# =============================================================================
suite "AC1/AC2: a data-layer path in a standard-tier diff actually halts the run"

OUT_DBMIG=$(run_tripwire "$ROOT_OK" "$REPO_DBMIG")
OUT_SUPA=$(run_tripwire "$ROOT_OK" "$REPO_SUPA")
OUT_ROOTMIG=$(run_tripwire "$ROOT_OK" "$REPO_ROOTMIG")
OUT_CLEAN=$(run_tripwire "$ROOT_OK" "$REPO_CLEAN")

assert_contains "AC1: db/migrations/0042.sql trips the tripwire (today's '^migrations/' literal misses it)" \
  "$OUT_DBMIG" "MIS-TIER"
assert_contains "AC2: supabase/migrations/x.sql trips the tripwire" "$OUT_SUPA" "MIS-TIER"
assert_contains "no-regression: migrations/0001.sql, the ONE path the pre-fix literal caught, still trips" \
  "$OUT_ROOTMIG" "MIS-TIER"

# NON-ZERO CONTROL for every "does not trip" assertion in this file. Without an observed HIT
# from the same harness, "no MIS-TIER in the output" is equally satisfied by a block that
# cannot run at all.
assert_eq "non-zero control: the harness has been OBSERVED reporting a hit before any absence is asserted" \
  "$(printf '%s' "$OUT_DBMIG" | grep -c 'MIS-TIER' | tr -d ' ' | head -1)" "1"
assert_not_contains "over-refusal control: a diff of only src/x.ts does NOT trip" "$OUT_CLEAN" "MIS-TIER"

# =============================================================================
# AC37 -- THE TRIPWIRE FAILS CLOSED. The highest-value criterion in this change.
# =============================================================================
suite "AC37: an unevaluable surface module HALTS as indeterminate, in three failure modes"

assert_eq "module file ABSENT: halts as indeterminate" \
  "$(classify "$(run_tripwire "$ROOT_ABSENT" "$REPO_DBMIG")")" "indeterminate"
assert_eq "PLUGIN_ROOT points at a stale cache with no scripts at all (the live condition in this repo): halts as indeterminate" \
  "$(classify "$(run_tripwire "$ROOT_STALE" "$REPO_DBMIG")")" "indeterminate"
assert_eq "module THROWS at import: halts as indeterminate" \
  "$(classify "$(run_tripwire "$ROOT_THROWS" "$REPO_DBMIG")")" "indeterminate"
assert_eq "module EXITS NON-ZERO: halts as indeterminate" \
  "$(classify "$(run_tripwire "$ROOT_EXITS" "$REPO_DBMIG")")" "indeterminate"

# An unevaluated tripwire is indeterminate REGARDLESS of the diff: the run cannot know the
# path was clean, because the thing that would have decided did not run. This cell is what
# separates "fails closed" from "fails closed only when we already know the answer".
# ...and the two states stay DISTINGUISHABLE, because they need different operator responses:
# re-tier the spec, versus fix your plugin root. The classifier asserts which one, not merely
# that something happened.
assert_eq "absent module + a diff of only src/x.ts: STILL halts, and as INDETERMINATE not as a tripwire hit" \
  "$(classify "$(run_tripwire "$ROOT_ABSENT" "$REPO_CLEAN")")" "indeterminate"

# MANDATORY over-refusal control: without it the criterion is satisfied by an unconditional
# halt, which would pass all five cases above and wedge every run in the field.
assert_eq "control: a HEALTHY module + src/x.ts is SILENT (no halt of either kind)" "$(classify "$OUT_CLEAN")" "silent"
assert_eq "control: a HEALTHY module + a real hit is a TRIPWIRE hit, not an indeterminate halt" \
  "$(classify "$OUT_DBMIG")" "mis-tier"

suite "AC37 SHAPE: no pipe consumes the surface-module invocation"

# This defect is INVISIBLE in behavior until the module breaks, so behavior alone would pass
# on a healthy machine and fail open in the field. `<node cmd> | grep -q HIT` discards the
# module's exit status: a throwing module exits non-zero with empty stdout, the condition
# reads false, and no halt fires -- silently restoring the exact pre-fix state.
# The detector strips `||` first, so a legitimate short-circuit is not counted as a pipe.
pipe_offenders() { # <file>
  local f="$1" line n=0
  while IFS= read -r line; do
    case "$line" in *node*|*"$DL_BASENAME"*) ;; *) continue ;; esac
    local stripped="${line//||/}"
    case "$stripped" in *"|"*) n=$((n + 1)) ;; esac
  done < "$f"
  printf '%s' "$n"
}

# PRECONDITION, and it is load-bearing: a detector that only inspects lines invoking the
# surface module reports ZERO offenders for a block that never invokes it. At origin/main the
# block is a bare `grep -qE`, so without this line the shape assertion below is a green over
# an empty population -- a test passing because the thing it audits does not exist yet.
assert_eq "the block INVOKES the surface module (without this, 'no pipes' is vacuous)" \
  "$(grep -cE "node|$DL_BASENAME" "$TRIPWIRE_BLOCK" | tr -d ' ')" "1"
assert_eq "no line invoking the surface module pipes its output anywhere" \
  "$(pipe_offenders "$TRIPWIRE_BLOCK")" "0"

# NON-ZERO CONTROL for the detector itself. A "zero offenders" result from a detector that
# cannot detect anything is the reading this rule exists to refuse.
PIPE_PROBE="$TEMP_PROJECT/pipe-probe.sh"
cat > "$PIPE_PROBE" <<EOF
if node -e 'import(process.env.CLAUDE_PLUGIN_ROOT + "/scripts/$DL_BASENAME")' | grep -q HIT; then
  echo "MIS-TIER"
fi
EOF
assert_eq "control: the SAME detector reports 1 offender against the prohibited shape" \
  "$(pipe_offenders "$PIPE_PROBE")" "1"
PIPE_PROBE_OK="$TEMP_PROJECT/pipe-probe-ok.sh"
cat > "$PIPE_PROBE_OK" <<EOF
HIT_OUT="\$(node -e 'x' )" || { echo "$INDET"; exit 0; }
EOF
assert_eq "control: the detector does NOT report the compliant capture-then-branch shape" \
  "$(pipe_offenders "$PIPE_PROBE_OK")" "0"

# =============================================================================
# AC25 -- CONFIG MAY ONLY WIDEN THE HALT, END TO END. Five shapes, and the two
# individually load-bearing cells are marked so a later trim cannot delete the only
# falsifying case and leave four green ones behind.
# =============================================================================
suite "AC25: the tripwire cannot be disarmed by config (five shapes, run through the real block)"

CFG_EMPTY='{"migrationGlobs":[]}'
CFG_CUSTOM='{"migrationGlobs":["db/changes/**"]}'
CFG_WRONG='{"migrationGlobs":"db/**"}'
CFG_POISON='{"migrationGlobs":[null,123,{}]}'
CFG_BROKEN='{"migrationGlobs": [ this is not json'

write_config "$REPO_ROOTMIG" "$CFG_EMPTY"
assert_contains "shape 1 {migrationGlobs:[]}: migrations/0001.sql STILL trips" \
  "$(run_tripwire "$ROOT_OK" "$REPO_ROOTMIG")" "MIS-TIER"

# LOAD-BEARING: the ONLY one of the five that reddens under the `cfg.length ? cfg : DEFAULTS`
# mutation, i.e. a fallback masquerading as a union. Verified 1 of 5 at spec time. Do not trim.
write_config "$REPO_SUPA" "$CFG_CUSTOM"
assert_contains "shape 2 {migrationGlobs:[db/changes/**]}: supabase/migrations/x.sql STILL trips (LOAD-BEARING)" \
  "$(run_tripwire "$ROOT_OK" "$REPO_SUPA")" "MIS-TIER"

write_config "$REPO_DBMIG" "$CFG_WRONG"
assert_contains "shape 3 wrong-typed migrationGlobs: db/migrations/0042.sql STILL trips" \
  "$(run_tripwire "$ROOT_OK" "$REPO_DBMIG")" "MIS-TIER"

write_config "$REPO_DBMIG" "$CFG_BROKEN"
assert_contains "shape 4 unparseable config file: db/migrations/0042.sql STILL trips" \
  "$(run_tripwire "$ROOT_OK" "$REPO_DBMIG")" "MIS-TIER"

# The SECOND load-bearing cell, for a different mutation: dropping the
# `.filter(g => typeof g === "string")` element guard. globToRegExp(null) THROWS TypeError
# while 123/{}/[] compile harmlessly to /^$/, so this is the only shape that distinguishes a
# guarded union from an unguarded spread -- and under the pre-fix shell shape a thrown
# resolver reads as "no hit". A battery keeping only shapes 1 and 4 passes both mutations.
write_config "$REPO_DBMIG" "$CFG_POISON"
OUT_POISON=$(run_tripwire "$ROOT_OK" "$REPO_DBMIG")
assert_contains "shape 5 {migrationGlobs:[null,123,{}]}: db/migrations/0042.sql STILL trips (LOAD-BEARING)" \
  "$OUT_POISON" "MIS-TIER"
assert_eq "shape 5: the verdict is a TRIPWIRE HIT, not an indeterminate halt -- the poisoned element is dropped, not compiled" \
  "$(classify "$OUT_POISON")" "mis-tier"

suite "AC25 NON-ZERO CONTROL: src/x.ts trips under NONE of the five configs"

# Mandatory. Without it the criterion is satisfied by a predicate that returns true for
# everything, which would pass all five cells above.
for cfg_name in EMPTY CUSTOM WRONG POISON BROKEN; do
  case "$cfg_name" in
    EMPTY)  write_config "$REPO_CLEAN" "$CFG_EMPTY" ;;
    CUSTOM) write_config "$REPO_CLEAN" "$CFG_CUSTOM" ;;
    WRONG)  write_config "$REPO_CLEAN" "$CFG_WRONG" ;;
    POISON) write_config "$REPO_CLEAN" "$CFG_POISON" ;;
    BROKEN) write_config "$REPO_CLEAN" "$CFG_BROKEN" ;;
  esac
  assert_not_contains "control: src/x.ts does not trip under config shape $cfg_name" \
    "$(run_tripwire "$ROOT_OK" "$REPO_CLEAN")" "MIS-TIER"
done
rm -f "$REPO_CLEAN/pipeline.config.json"

# =============================================================================
# AC5 -- no inline data-layer or infra regex survives outside the module.
# =============================================================================
suite "AC5: the hand-typed regexes are GONE from every markdown consumer"

# BYTE-FOR-BYTE literals taken from the files at origin/main, not re-derived approximations:
# a near-miss spelling would let a byte-identical copy survive under different quoting.
LIT_DATA='^(migrations/|db/)'
LIT_INFRA='(^\.github/|^infra/|^deploy)'

md_hits() { # <literal>
  local n
  n=$( { grep -Fl -- "$1" "$PLUGIN_DIR"/commands/*.md "$PLUGIN_DIR"/agents/*.md 2>/dev/null || true; } | wc -l )
  printf '%s' "$(printf '%s' "$n" | tr -d ' ')"
}

assert_eq "the data-layer literal appears in no commands/*.md or agents/*.md file" "$(md_hits "$LIT_DATA")" "0"
assert_eq "the infra literal appears in no commands/*.md or agents/*.md file" "$(md_hits "$LIT_INFRA")" "0"

# NON-ZERO CONTROL for the grep itself: the same invocation, the same quoting, against a file
# that deliberately contains a byte-identical copy. At origin/main the data-layer literal was
# present in 1 file (commands/pipeline.md, at :597 and :722) and the infra literal in 1 file
# (same), so this assertion started RED and its going green is the observation, not an
# assumption about a pattern that may never have matched anything.
PROBE_DIR="$TEMP_PROJECT/grep-probe"
mkdir -p "$PROBE_DIR"
printf 'echo "$CHANGED" | grep -qE %s && PANEL_ROLES="$PANEL_ROLES dba"\n' "'$LIT_DATA'" > "$PROBE_DIR/copy.md"
printf 'echo "$CHANGED" | grep -qE %s && PANEL_ROLES="$PANEL_ROLES devops"\n' "'$LIT_INFRA'" >> "$PROBE_DIR/copy.md"
assert_eq "control: the same grep DOES find a byte-identical copy of the data-layer literal" \
  "$(grep -Fc -- "$LIT_DATA" "$PROBE_DIR/copy.md" | tr -d ' ')" "1"
assert_eq "control: the same grep DOES find a byte-identical copy of the infra literal" \
  "$(grep -Fc -- "$LIT_INFRA" "$PROBE_DIR/copy.md" | tr -d ' ')" "1"

# =============================================================================
# AC38 -- THE TWO FAIL DIRECTIONS HOLD SIMULTANEOUSLY, IN ONE RUN.
# =============================================================================
suite "AC38: with BOTH modules absent, the tripwire HALTS and the dispatch OMITS the model key"

# This is the criterion, and it is composite on purpose. The likeliest defect in this whole
# change is an implementer applying ONE fail direction to BOTH consumers -- "handle a missing
# module consistently" -- and two separately-passing criteria cannot see that. Both halves are
# evaluated against the SAME broken plugin root, in the same environment, in this block.
#
# The model resolver is DISCOVERED from the rewired dispatch sites rather than assumed by
# filename: whatever script commands/pipeline.md tells the orchestrator to run is the script
# under test. If nothing new is referenced there, the resolver has not been wired in and every
# assertion below reports that.
# #104: collect every survivor rather than `break`ing on the first. A single `break` is
# `sort -u` ORDER with no identity check behind it -- adding dispatch-effort.mjs (it sorts
# before dispatch-model.mjs) silently handed this suite the wrong resolver until the exclusion
# below was added by hand, and the next early-sorting scripts/*.mjs reference walks into the
# identical trap. Zero survivors stays the pre-existing "not wired" state; more than one is now
# a loud, self-diagnosing failure naming every candidate, never a silent wrong pick.
CANDIDATES_REL=()
for cand in $(grep -oE 'scripts/[a-zA-Z0-9_-]+\.mjs' "$PIPELINE_MD" | sort -u); do
  base="${cand#scripts/}"
  case "$base" in
    frontend-surface.mjs|gate-pre-phase4.mjs|gate-pre-phase4-frontend.mjs|merge-peer-review.mjs) continue ;;
    archive-pipeline.mjs|knowledge-store.mjs|validate-pipeline-artifact.mjs|voice-lint.mjs) continue ;;
    pipeline-status.mjs|config-doctor.mjs|lib.mjs|sync-manifests.mjs) continue ;;
    "$DL_BASENAME") continue ;;
    # The EFFORT resolver sorts BEFORE dispatch-model.mjs, and its agent surface emits nothing
    # BY DESIGN (the Agent tool has no effort parameter), so without this line `sort -u` hands
    # this suite the wrong script and the AC37 "the resolver EMITS a token" rows below fail
    # against a resolver that was never supposed to emit on that surface. #101. Excluded by
    # NAME (an identity check), not relied on to sort elsewhere, now that ambiguity halts too.
    dispatch-effort.mjs) continue ;;
    # #104's own discriminating find: these two ALREADY survived the pre-fix denylist and were
    # ALREADY ambiguous with dispatch-model.mjs, masked only because "d" sorts before "g" and
    # "p" in the single-survivor `break` this suite used to take. See the twin comment in
    # test-dispatch-model-resolver.sh.
    gate-phase-entry.mjs|pipeline-telemetry.mjs) continue ;;
    # #117's write-time verdict-cap checker, referenced from the durable-checkpoint recipe. It
    # sorts FIRST of every candidate ("c"), so it is the "next early-sorting scripts/*.mjs
    # reference" the comment above predicted; the ambiguity halt named it instead of silently
    # handing this suite a script that resolves no model. See the twin in
    # test-dispatch-model-resolver.sh.
    check-status-record.mjs) continue ;;
    # #74's in-flight/datability leaf, newly REFERENCED from pipeline.md by #110's clearing rule.
    # The file itself is not new (#106 added it); only its first mention in pipeline.md is, so a
    # REFERENCE rather than a script tripped the halt here. It resolves no model. See the twin in
    # test-dispatch-model-resolver.sh.
    run-candidates.mjs) continue ;;
    # 0.40.0: the materiality normalizer and the delta-round security/test surface module.
    # Neither resolves a model nor takes a (role, tier, phase) triple. Excluded by NAME, as in
    # the twin in test-dispatch-model-resolver.sh.
    materiality.mjs|security-surface.mjs) continue ;;
  esac
  CANDIDATES_REL+=("$cand")
done

RESOLVER_REL=""
if [[ "${#CANDIDATES_REL[@]}" -eq 1 ]]; then
  RESOLVER_REL="${CANDIDATES_REL[0]}"
elif [[ "${#CANDIDATES_REL[@]}" -gt 1 ]]; then
  echo "AMBIGUOUS RESOLVER DISCOVERY: ${#CANDIDATES_REL[@]} candidates survived the denylist: ${CANDIDATES_REL[*]}" >&2
  echo "Add the new script to this suite's denylist (with a reason), or give it its own identity check, before this suite can tell which one it means." >&2
fi

assert_eq "commands/pipeline.md names a model-resolver script at its dispatch sites" \
  "$([[ -n "$RESOLVER_REL" ]] && echo yes || echo "no: only the pre-existing scripts are referenced")" "yes"
# #104: discovery found EXACTLY one candidate, not merely "a" candidate off sort-order luck.
assert_eq "AC (#104): resolver discovery is unambiguous -- exactly one candidate survived" \
  "${#CANDIDATES_REL[@]}" "1"

# One environment, both modules gone: ROOT_STALE contains neither the surface module nor the
# resolver, which is exactly the stale-plugin-cache condition that is LIVE in this worktree.
COMPOSITE_TRIPWIRE_OUT=$(run_tripwire "$ROOT_STALE" "$REPO_DBMIG")

# GUARDED. With RESOLVER_REL empty (nothing wired yet) an unguarded probe would run
# `node <root>/`, get a non-zero exit and empty stdout, and every "the absent resolver omits"
# assertion would pass -- proving only that a path that was never built does not work. The
# guard makes the unwired state its own visible answer instead.
resolver_stdout() { # <plugin-root> <role> <tier> <phase>
  [[ -n "$RESOLVER_REL" ]] || { printf 'ERR:no-resolver-referenced-in-pipeline.md'; return 0; }
  ( CLAUDE_PLUGIN_ROOT="$1" CLAUDE_PROJECT_DIR="$REPO_CLEAN" \
      node "$1/$RESOLVER_REL" "$2" "$3" "$4" 2>/dev/null )
}
resolver_rc() {
  [[ -n "$RESOLVER_REL" ]] || { printf 'ERR:no-resolver-referenced-in-pipeline.md'; return 0; }
  ( CLAUDE_PLUGIN_ROOT="$1" CLAUDE_PROJECT_DIR="$REPO_CLEAN" \
      node "$1/$RESOLVER_REL" "$2" "$3" "$4" >/dev/null 2>&1 ); printf '%s' "$?"
}
# emission <plugin-root> <role> <tier> <phase> -> emit | omit | ERR:...
# The dispatch site's rule, stated once as the conjunction the emission depends on: emit
# `model:` ONLY IF the resolver exited 0 AND printed exactly one token.
emission() {
  local rc out
  rc=$(resolver_rc "$@"); out=$(resolver_stdout "$@")
  case "$rc$out" in *ERR:*) printf 'ERR:no-resolver-referenced-in-pipeline.md'; return 0 ;; esac
  if [[ "$rc" == "0" && "$(printf '%s' "$out" | wc -w | tr -d ' ')" == "1" ]]; then printf 'emit'; else printf 'omit'; fi
}

assert_eq "half 1 (FAIL CLOSED): the tripwire halts as indeterminate" \
  "$(classify "$COMPOSITE_TRIPWIRE_OUT")" "indeterminate"
assert_eq "half 2 (FAIL OPEN): the SAME absent-module condition makes the dispatch OMIT the model key, not halt" \
  "$(emission "$ROOT_STALE" dev standard 4)" "omit"

suite "AC38: the other three cells of the matrix, so the composite is not a single lucky cell"

# THE DECOUPLING CELL, and the only one in either suite that can catch C1 being violated.
# ROOT_ABSENT is the surface module removed with the resolver left healthy, so it is the SAME
# root that halts the tripwire at the two assertions above (surface absent => indeterminate, on
# both a data-layer diff and a clean one). The two fail directions therefore meet on one root:
# the condition that HALTS the tripwire must leave the dispatch EMITTING. An implementer who
# unifies the directions -- importing the surface module from the resolver, or guarding both
# consumers behind one presence check -- reddens here and nowhere else: both-absent (composite,
# above) and both-present (control, below) stay green under that defect because neither
# separates the two modules.
#
# THE FOURTH CELL (resolver ABSENT + surface PRESENT) IS DELETED RATHER THAN ASSERTED. It is
# not a cell that can fail independently: with the resolver gone there is no code left to
# consult the surface module, so the observation is `node <missing file>` either way. Measured
# on both fixtures, the rc and stdout are identical -- rc=1, empty stdout -- which is byte for
# byte what ROOT_STALE already asserts as half 2 of the composite, and what the resolver
# suite's own absent-script case asserts again. Keeping it would add a green that no defect can
# turn red: coverage in appearance, a duplicate in fact.
assert_eq "surface module ABSENT + resolver PRESENT: the dispatch still EMITS (the fail directions stay separate)" \
  "$(emission "$ROOT_ABSENT" dev standard 4)" "emit"
# NON-ZERO CONTROL for the whole omit column: a healthy resolver must be observed EMITTING,
# or every "omit" above is satisfied by a resolver that can never emit anything.
assert_eq "surface module PRESENT + resolver PRESENT: the resolver EMITS a token" \
  "$(emission "$ROOT_OK" dev standard 4)" "emit"
assert_eq "surface module PRESENT + resolver PRESENT: and the tripwire is silent on a clean diff" \
  "$(classify "$OUT_CLEAN")" "silent"

# =============================================================================
# THE SECOND ESCAPE: SHELL crossed with PATH COUNT.
# =============================================================================
#
# Every fixture above this line is a ONE-PATH diff and every run above this line is `bash`.
# Both dimensions that produce the defect were pinned to their safe value in every assertion,
# so this whole suite passed while the control it guards did not fire on the orchestrator's
# own shell.
#
# The defect: the block passed the path list to the module through an UNQUOTED `$CHANGED`,
# which relies on the shell word-splitting a parameter expansion. zsh does not do that, and
# zsh is what the orchestrator's shell tool runs. A multi-file diff therefore arrived as ONE
# newline-joined argument; the surface globs compile to `.`-based regexes and `.` does not
# match a newline, so tripwireReport returned no hits and the run PROCEEDED. Measured on
# `{db/migrate/001_add_users.rb, src/app.ts}`: bash halted, zsh was silent. This is the
# control the whole issue exists to protect, so it gets the matrix nobody had.

# The zsh column is DECLARED, not discovered. A bare `command -v zsh` opened this column on a
# developer's machine and closed it with a self-equal assertion on ubuntu-latest, so eight
# assertions here simply did not exist where CI enforces the gate (#47). optional_tool records
# the answer either way and, under PIPELINE_TESTS_REQUIRE_CAPABILITIES=1 (which the workflow
# sets), fails by NAME rather than shrinking the population in silence.
RUNNERS=(bash bash-nosplit)
ZSH_PRESENT=no
if optional_tool zsh; then RUNNERS+=(zsh); ZSH_PRESENT=yes; fi

# `bash-nosplit` is bash with IFS emptied, i.e. field splitting off: the defect condition
# itself, in a shell every checkout has, so this dimension is never skipped for want of zsh.
run_tripwire_in() {  # $1 = runner, $2 = plugin root, $3 = repo, $4 = block file (default: the extracted one)
  local body=". \"${4:-$TRIPWIRE_BLOCK}\""
  (
    cd "$3" || return 1
    export CLAUDE_PLUGIN_ROOT="$2" WORKTREE_PATH="$3" CLAUDE_PROJECT_DIR="$3" \
           RISK_TIER="standard" ARTIFACT_DIR="$3/.pipeline/17"
    case "$1" in
      bash)         bash -c "$body" ;;
      bash-nosplit) bash -c "IFS=; $body" ;;
      zsh)          zsh  -c "$body" ;;
    esac
  ) 2>&1
}

# MULTI-path fixtures: the dimension that did not exist. Each pairs a migration path with an
# ordinary one, which is what a real mis-tiered diff looks like.
REPO_MULTI=$(make_diff_repo multi 'db/migrate/001_add_users.rb' 'src/app.ts')
REPO_MULTI_CLEAN=$(make_diff_repo multiclean 'src/app.ts' 'docs/notes.txt')
# Built directly rather than through make_diff_repo: with no paths to add, that helper's final
# `git commit` finds nothing to commit and prints "nothing to commit" to STDOUT, which the
# helper's `$(...)` capture folds into the returned directory name. The `cd` then fails and
# every case reads as SILENT -- a fixture that never constructs the state it claims to test.
REPO_EMPTY="$TEMP_PROJECT/repo-emptydiff"
mkdir -p "$REPO_EMPTY"
git -C "$REPO_EMPTY" init -q
git -C "$REPO_EMPTY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$REPO_EMPTY" update-ref refs/remotes/origin/main HEAD
git -C "$REPO_EMPTY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m change
assert_eq "the empty-diff fixture really has an empty diff (else the cases below test nothing)" \
  "$(git -C "$REPO_EMPTY" diff --name-only origin/main...HEAD | wc -l | tr -d ' ')" "0"

suite "NON-ZERO CONTROL FIRST: the pre-fix shape is OBSERVED failing on exactly this matrix"

# Without this, "the new block halts in every cell" is equally satisfied by a matrix that
# cannot tell the cells apart. This is the shipped shape as of d35da61, verbatim.
OLD_TRIPWIRE="$TEMP_PROJECT/old-tripwire-block.sh"
cat > "$OLD_TRIPWIRE" <<'EOF'
CHANGED="$(git -C "$WORKTREE_PATH" diff --name-only origin/main...HEAD)"
TRIPWIRE_OUT="$(node -e 'import(process.env.CLAUDE_PLUGIN_ROOT + "/scripts/data-layer-surface.mjs").then(m=>{const r=m.tripwireReport(process.argv.slice(1));if(r.note)console.error("TRIPWIRE-NOTE: "+r.note);if(r.hits.length)console.log(r.hits.join(" "))}).catch(e=>{console.log("unevaluable: "+(e&&e.message));process.exit(1)})' $CHANGED)"
TRIPWIRE_RC=$?
if [ "$TRIPWIRE_RC" -ne 0 ]; then
  echo "3-impl-tripwire-indeterminate: could not be evaluated (exit $TRIPWIRE_RC). $TRIPWIRE_OUT"
elif [ -n "$TRIPWIRE_OUT" ]; then
  echo "MIS-TIER: data-layer path in a $RISK_TIER diff: $TRIPWIRE_OUT"
fi
EOF

assert_eq "the pre-fix shape HALTS on a one-path migration diff under bash (which is why it shipped)" \
  "$(classify "$(run_tripwire_in bash "$ROOT_OK" "$REPO_DBMIG" "$OLD_TRIPWIRE")")" "mis-tier"
assert_eq "and halts on a MULTI-path diff under bash, the only cell the old suite ever ran" \
  "$(classify "$(run_tripwire_in bash "$ROOT_OK" "$REPO_MULTI" "$OLD_TRIPWIRE")")" "mis-tier"
assert_eq "and on a one-path diff under a NON-SPLITTING shell: there is nothing to split" \
  "$(classify "$(run_tripwire_in bash-nosplit "$ROOT_OK" "$REPO_DBMIG" "$OLD_TRIPWIRE")")" "mis-tier"
# THE CELL. Both dimensions are needed; neither alone shows anything.
assert_eq "THE DEFECT: a MULTI-path migration diff under a NON-SPLITTING shell is SILENT" \
  "$(classify "$(run_tripwire_in bash-nosplit "$ROOT_OK" "$REPO_MULTI" "$OLD_TRIPWIRE")")" "silent"
if [[ "$ZSH_PRESENT" == yes ]]; then
  assert_eq "real zsh -- the orchestrator's own shell -- reproduces it: the halting control does not fire" \
    "$(classify "$(run_tripwire_in zsh "$ROOT_OK" "$REPO_MULTI" "$OLD_TRIPWIRE")")" "silent"
  # On the PARAMETER-expansion form -- which is the shipped defect -- the two agree exactly.
  # They diverge on unquoted command substitution, where zsh splits and the stand-in does not;
  # that boundary is measured and pinned in test-panel-composition-fail-direction.sh, and the
  # divergence runs in the safe direction (the stand-in splits strictly less, so it reddens on
  # every shape zsh reddens on).
  assert_eq "and the stand-in reproduces it byte-for-byte on this form" \
    "$(run_tripwire_in zsh "$ROOT_OK" "$REPO_MULTI" "$OLD_TRIPWIRE")" \
    "$(run_tripwire_in bash-nosplit "$ROOT_OK" "$REPO_MULTI" "$OLD_TRIPWIRE")"
fi

suite "THE FIX: the shipped tripwire gives the same verdict in every cell of shell x path count"

for runner in "${RUNNERS[@]}"; do
  assert_eq "[$runner] one-path migration diff HALTS" \
    "$(classify "$(run_tripwire_in "$runner" "$ROOT_OK" "$REPO_DBMIG")")" "mis-tier"
  assert_eq "[$runner] MULTI-path migration diff HALTS (the cell the escape lived in)" \
    "$(classify "$(run_tripwire_in "$runner" "$ROOT_OK" "$REPO_MULTI")")" "mis-tier"
  # OVER-REFUSAL CONTROL in the same column: a block that halted unconditionally would pass
  # both cells above, so each column carries its own negative at both path counts.
  assert_eq "[$runner] one-path clean diff is SILENT" \
    "$(classify "$(run_tripwire_in "$runner" "$ROOT_OK" "$REPO_CLEAN")")" "silent"
  assert_eq "[$runner] MULTI-path clean diff is SILENT" \
    "$(classify "$(run_tripwire_in "$runner" "$ROOT_OK" "$REPO_MULTI_CLEAN")")" "silent"
  # And the fail-closed direction survives the new plumbing, at both path counts.
  assert_eq "[$runner] a stale plugin root still halts as INDETERMINATE on a multi-path diff" \
    "$(classify "$(run_tripwire_in "$runner" "$ROOT_STALE" "$REPO_MULTI")")" "indeterminate"
done

suite "an unreadable or empty path list is INDETERMINATE, never a clean diff"

# git's own exit status, which `CHANGED="$(git ...)"` discarded. A WORKTREE_PATH that is not a
# repository and a repository with no origin/main ref both print `fatal:` and yield an EMPTY
# list on stdout -- byte-identical to a clean diff. The second appears in this repository's own
# CI log, so it is not hypothetical.
REPO_NO_REMOTE="$TEMP_PROJECT/repo-no-origin-main"
mkdir -p "$REPO_NO_REMOTE"
git -C "$REPO_NO_REMOTE" init -q
git -C "$REPO_NO_REMOTE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m only
for runner in "${RUNNERS[@]}"; do
  assert_eq "[$runner] a diff with NO paths at all HALTS as indeterminate, not as clean" \
    "$(classify "$(run_tripwire_in "$runner" "$ROOT_OK" "$REPO_EMPTY")")" "indeterminate"
  assert_eq "[$runner] a repo with no origin/main ref HALTS as indeterminate" \
    "$(classify "$(run_tripwire_in "$runner" "$ROOT_OK" "$REPO_NO_REMOTE")")" "indeterminate"
done
assert_contains "and the git failure is named with its own exit status, distinct from the module's" \
  "$(run_tripwire_in bash "$ROOT_OK" "$REPO_NO_REMOTE")" \
  "3-impl-tripwire-indeterminate: git diff --name-only -z exited"
# The two indeterminate causes stay DISTINGUISHABLE: they need different operator responses
# (fix your worktree, versus fix your plugin root).
assert_contains "a stale plugin root names the module instead" \
  "$(run_tripwire_in bash "$ROOT_STALE" "$REPO_DBMIG")" \
  "the data-layer surface module under"
# NON-ZERO CONTROL for the pair above: the same block, same runner, on a healthy repo and root,
# says neither -- so "names the git failure" is a verdict rather than a string that always appears.
assert_eq "CONTROL: a healthy root and a readable one-path clean diff say neither" \
  "$(classify "$(run_tripwire_in bash "$ROOT_OK" "$REPO_CLEAN")")" "silent"
# The halt message carries no absolute filesystem path: it is recorded into status.json, which
# is committed and archived verbatim.
assert_eq "the git-failure halt message carries no absolute path (status.json is archived verbatim)" \
  "$(run_tripwire_in bash "$ROOT_OK" "$REPO_NO_REMOTE" | grep -c "$TEMP_PROJECT" | tr -d ' ')" "0"

suite "DBA nit: tripwireReport never returns a HIT and 'it cannot fire here' at the same time"

# tripwireReport() had zero direct coverage. It returned `hits` and the zero-match note
# together, computed over two different populations (the changed paths, and the tracked tree),
# so a repository whose tracked files match nothing but whose DIFF adds a migration got both.
# pipeline.md:572 tells the orchestrator to file that note in status.json (`flags`), so the run
# that halted ON a hit would have recorded a flag saying the tripwire cannot fire here.
report() { # <repo-dir> <changed-path>... -> "hits=<n> note=<yes|no>"
  [[ -n "$DL_MODULE" ]] || { printf 'ERR:no-module'; return 0; }
  MOD="$DL_MODULE" DIR="$1" node --input-type=module -e '
    const m = await import(process.env.MOD);
    const r = m.tripwireReport(process.argv.slice(1), process.env.DIR);
    console.log("hits=" + r.hits.length + " note=" + (r.note ? "yes" : "no"));
  ' "${@:2}"
}

# A repo whose TRACKED files match nothing the narrow set matches. Both fixtures below are the
# same repository: the only thing that varies is the changed-path list handed in, so the two
# outcomes are attributable to the hits and to nothing else.
BARE_REPO="$TEMP_PROJECT/tripwire-report-repo"
mkdir -p "$BARE_REPO/src"
git -C "$BARE_REPO" init -q
printf 'x\n' > "$BARE_REPO/src/app.ts"
git -C "$BARE_REPO" add src/app.ts
git -C "$BARE_REPO" -c user.email=t@t -c user.name=t commit -q -m init

# A second repository whose TRACKED tree does contain a migration, so the note's own condition
# can be observed going both ways rather than only one.
MIGRATED_REPO="$TEMP_PROJECT/tripwire-report-repo-migrated"
mkdir -p "$MIGRATED_REPO/migrations"
git -C "$MIGRATED_REPO" init -q
printf 'select 1;\n' > "$MIGRATED_REPO/migrations/0001.sql"
git -C "$MIGRATED_REPO" add migrations/0001.sql
git -C "$MIGRATED_REPO" -c user.email=t@t -c user.name=t commit -q -m init

# NON-ZERO CONTROLS FIRST, and they are what make the suppression below meaningful: on a clean
# diff this same repository DOES produce the note, and a repo whose tree matches does NOT.
# Without both, "note=no" on a hit is satisfied by a note that never fires at all.
assert_eq "CONTROL: a clean diff in a repo whose tree matches nothing DOES carry the note" \
  "$(report "$BARE_REPO" 'src/app.ts')" "hits=0 note=yes"
assert_eq "CONTROL: with no changed paths at all, the same repo reports it too" \
  "$(report "$BARE_REPO")" "hits=0 note=yes"
assert_eq "CONTROL: a repo whose TRACKED tree does contain a migration never carries the note" \
  "$(report "$MIGRATED_REPO" 'src/app.ts')" "hits=0 note=no"
# THE CONTRADICTION, on the one input that can construct it: tracked tree matches nothing,
# changed paths add a migration. Before the fix this returned `hits=1 note=yes`.
assert_eq "a HIT suppresses the 'cannot fire here' note: the two are never both returned" \
  "$(report "$BARE_REPO" 'migrations/0001.sql')" "hits=1 note=no"
assert_eq "and the hit is still reported where the tracked tree matches (the ordinary case)" \
  "$(report "$MIGRATED_REPO" 'migrations/0002.sql')" "hits=1 note=no"
# The .md exclusion reaches tripwireReport too, so its hits are the NARROW predicate's and not
# a second, looser copy of the rule.
assert_eq "a .md path under migrations/ is not a hit here either" \
  "$(report "$BARE_REPO" 'docs/migrations/guide.md')" "hits=0 note=yes"
assert_eq "but its .txt sibling is" \
  "$(report "$BARE_REPO" 'docs/migrations/notes.txt')" "hits=1 note=no"

finish
