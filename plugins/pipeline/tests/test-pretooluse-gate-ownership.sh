#!/usr/bin/env bash
# #106, part 3 of 5: WHICH RUN owns the deny.
#
# AC12 run ownership over two in-flight dirs, both mtime orderings, identical abstention
# AC13 the in-flight predicate: grain on the FIELD, and the datability split
# AC14 the gate's reading and the phase-entry guard's cannot disagree silently
# AC25 portability: multi-root, and ownership binds across every root consulted
# AC26 no second derivation: the gate follows ISSUE_DIR_RE from its exported home
# AC27 the seam extension is ADDITIVE, verified rather than assumed
# AC28 SubagentStop is untouched
# AC34 review_rounds is not read
# AC37 an undatable record is never the resolved OWNER
# AC38 marker precedence, widen-only, with P1/P2 premises and VOID cells
# AC40 R21(e) is disclosed AND reachable
# AC41 the resolver's raw answer and R5's narrowing are made to DISAGREE
# AC42 ownership under a REAL clone, where the tie is not the variable

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
require_node

make_temp_project 106 || exit 90
GATE_SCRATCH="$TEMP_PROJECT"
gate_cache_declaration

FORBIDDEN_CMD='git commit -a -m "m"'
NOW_MS=60000            # "one minute ago": in flight by CONTENT
STALE_MS=$(( 48 * 60 * 60 * 1000 ))   # 48 h: outside IN_FLIGHT_MS (24 h, gate-phase-entry.mjs:188)

sub_verdict() {  # <root> [payload key=value ...]
  local root="$1"; shift
  gate_reset_env "$root"
  run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-own agent_type=pipeline:qa "$@")"
  printf '%s' "$GATE_DECISION"
}
sub_attribution() {  # <root> [payload key=value ...] -> normalized recovered attribution
  local root="$1"; shift
  gate_reset_env "$root"; GATE_TMPDIR="$TEMP_PROJECT/own-tmp"; mkdir -p "$GATE_TMPDIR"
  gate_run_with_sinks "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-own agent_type=pipeline:qa "$@")" \
    "$TEMP_PROJECT/own-manifest.json" "$root" "$GATE_TMPDIR"
  printf '%s\n%s' "$GATE_ATTRIBUTION" "$GATE_REASON" | gate_normalize_attribution
}

# ===============================================================================================
suite "AC13: the in-flight predicate -- final_verdict FIRST, then databability, grain on the FIELD"
# ===============================================================================================
record "LITERALS FIXED BY THIS PROJECT'S OWN AUTHORITY: IN_FLIGHT_MS = 24*60*60*1000 at plugins/pipeline/scripts/gate-phase-entry.mjs:188; the predicate shape at :548-552"

# (a) an ARCHIVED record with final_verdict is EXCLUDED unconditionally -> zero candidates -> abstain
R_ARCHIVED="$TEMP_PROJECT/r-archived"
gate_status "$R_ARCHIVED/.pipeline/56/status.json" current_phase=4-review-complete \
  "updated_at=agoms:$NOW_MS" final_verdict=APPROVE
assert_eq "AC13(a): a concluded record (final_verdict, fresh updated_at) is excluded -> no candidate -> NOT denied" \
  "$(sub_verdict "$R_ARCHIVED")" "none"

# (b) a record STALE BY updated_at is excluded
R_STALE="$TEMP_PROJECT/r-stale"
gate_inflight_status "$R_STALE/.pipeline/98/status.json" "4-review" "updated_at=agoms:$STALE_MS"
assert_eq "AC13(b): a record stale by updated_at (48 h > IN_FLIGHT_MS) is excluded -> NOT denied" \
  "$(sub_verdict "$R_STALE")" "none"

# (c) a genuine in-flight '4-review' is INCLUDED and is the sole owner
R_LIVE="$TEMP_PROJECT/r-live"
gate_inflight_status "$R_LIVE/.pipeline/106/status.json" "4-review"
assert_eq "AC13(c): a single in-flight '4-review' record IS the owner -> denied" "$(sub_verdict "$R_LIVE")" "deny"

# GRAIN STABILITY: the grain is the FIELD, never the file mtime. A checkout, clone or sync
# refreshes every mtime while leaving updated_at intact; measured on this repo's corpus the mtime
# grain yields 6 candidates against the field grain's 2, which is a gate that abstains forever
# after every clone in exactly the adopting-project deployment R18 protects.
R_TOUCH="$TEMP_PROJECT/r-touch"
gate_inflight_status "$R_TOUCH/.pipeline/106/status.json" "4-review"
gate_status "$R_TOUCH/.pipeline/17/status.json" current_phase=3-impl-complete "updated_at=agoms:$STALE_MS"
gate_status "$R_TOUCH/.pipeline/19/status.json" current_phase=5-archived "updated_at=agoms:$STALE_MS" final_verdict=APPROVE
BEFORE_TOUCH="$(sub_verdict "$R_TOUCH")"
find "$R_TOUCH" -name status.json -exec touch {} \;
AFTER_TOUCH="$(sub_verdict "$R_TOUCH")"
assert_eq "AC13 GRAIN: one in-flight record among two stale-by-CONTENT records -> denied" "$BEFORE_TOUCH" "deny"
assert_eq "AC13 GRAIN: and touching every status.json changes NOTHING (the grain is the field, not the file)" \
  "$AFTER_TOUCH" "$BEFORE_TOUCH"

# DATABILITY CELLS. Re-derived rather than assumed: null, {}, true, [], '' and 'nope' all yield
# NaN from Date.parse; 12345 and '12345' both yield 327403400400000, which is FINITE, so those two
# are AGREEMENT cells and not divergence -- the round-3 spec asserted a difference that does not
# exist. The property under test is that an undatable record PREVENTS NARROWING: it counts toward
# the candidate set, so it can never shrink a set to one.
declare -a NAN_CELLS=( "json:null" "json:{}" "json:true" "json:[]" "" "nope" "__ABSENT__" )
declare -a FINITE_CELLS=( "json:12345" "12345" )

for spelling in "${NAN_CELLS[@]}"; do
  R="$TEMP_PROJECT/nan-$(printf '%s' "$spelling" | tr -c 'A-Za-z0-9' '_')"
  gate_inflight_status "$R/.pipeline/106/status.json" "4-review"           # the datable owner
  gate_status "$R/.pipeline/98/status.json" current_phase=4-review "updated_at=$spelling"
  assert_eq "AC13 DATABILITY [$spelling]: it COUNTS as a candidate, so the set is 2 and the gate abstains" \
    "$(sub_verdict "$R")" "none"
done
for spelling in "${FINITE_CELLS[@]}"; do
  R="$TEMP_PROJECT/fin-$(printf '%s' "$spelling" | tr -c 'A-Za-z0-9' '_')"
  gate_inflight_status "$R/.pipeline/106/status.json" "4-review"
  gate_status "$R/.pipeline/98/status.json" current_phase=4-review "updated_at=$spelling"
  assert_eq "AC13 DATABILITY [$spelling] (AGREEMENT cell, Date.parse is FINITE): also a candidate, set is 2, abstain" \
    "$(sub_verdict "$R")" "none"
done

# EVALUATION-ORDER CELL. R5 fixes the order: final_verdict is evaluated FIRST and excludes
# UNCONDITIONALLY; databability is asked only of records that are NOT concluded. The two readings
# differ in the DENY direction, and round 4 found the spec did not say which -- so this cell
# decides a verdict rather than a label.
for second in "unparseable" "absent"; do
  R="$TEMP_PROJECT/order-$second"
  gate_inflight_status "$R/.pipeline/106/status.json" "4-review"
  if [[ "$second" == "absent" ]]; then
    gate_status "$R/.pipeline/56/status.json" current_phase=5-archived final_verdict=APPROVE updated_at=__ABSENT__
  else
    gate_status "$R/.pipeline/56/status.json" current_phase=5-archived final_verdict=APPROVE updated_at=nope
  fi
  assert_eq "AC13 ORDER [$second updated_at + final_verdict]: concluded FIRST, so the set is ONE and the payload IS denied" \
    "$(sub_verdict "$R")" "deny"
  # DISCRIMINATION: remove ONLY the final_verdict and the outcome must flip to abstain (1 -> 2
  # candidates). Without this the fixture passes whether the order is applied or not.
  if [[ "$second" == "absent" ]]; then
    gate_status "$R/.pipeline/56/status.json" current_phase=5-archived updated_at=__ABSENT__
  else
    gate_status "$R/.pipeline/56/status.json" current_phase=5-archived updated_at=nope
  fi
  assert_eq "AC13 ORDER DISCRIMINATION [$second]: removing ONLY the final_verdict flips it to abstain" \
    "$(sub_verdict "$R")" "none"
done

# ===============================================================================================
suite "AC14: the gate's reading and the phase-entry guard's cannot disagree SILENTLY"
# ===============================================================================================
#
# THE PHASE-ENTRY GUARD'S VERDICT IS OBSERVED, not re-derived: run gate-phase-entry.mjs with cwd
# pinned to a root holding exactly the record under test at '4-review' with no impl-report. It
# exits 2 when it considers that record IN FLIGHT and 0 when it does not. Measured on this tree:
# a fresh ISO updated_at -> 2; 'nope' -> 0; null -> 0; '12345' -> 2.
#
# THE GATE'S reading is observed through the consequence R5 gives it: an undatable record COUNTS
# toward the candidate set, so adding it beside one datable in-flight record takes the set from
# one to two and turns a deny into an abstention. That is the only place the two readings are
# observable side by side, and it is where R5 says they deliberately differ.

gpe_says() {  # <updated_at spelling> -> inflight|excluded
  local sp="$1" r
  r="$(gate_fresh_root)" || return 90
  gate_status "$r/.pipeline/106/status.json" current_phase=4-review "updated_at=$sp"
  ( cd "$r" && "$GATE_REAL_NODE" "$GATE_PLUGIN_DIR/scripts/gate-phase-entry.mjs" >/dev/null 2>&1 )
  [[ $? -eq 2 ]] && printf 'inflight' || printf 'excluded'
}
gate_counts() {  # <updated_at spelling> -> counts|excluded, read off the deny/abstain flip
  local sp="$1" r
  r="$(gate_fresh_root)" || return 90
  gate_inflight_status "$r/.pipeline/106/status.json" "4-review"
  gate_status "$r/.pipeline/98/status.json" current_phase=4-review "updated_at=$sp"
  local v; v="$(sub_verdict "$r")"
  case "$v" in
    none) printf 'counts' ;;
    deny) printf 'excluded' ;;
    *)    printf 'UNREADABLE(%s)' "$v" ;;
  esac
}

# NON-ZERO CONTROL on the gate-phase-entry probe itself: a datable in-flight record must read
# `inflight`, or every `excluded` below is a statement about a broken probe.
assert_eq "NON-ZERO CONTROL: the gate-phase-entry probe reports 'inflight' for a fresh, datable record" \
  "$(gpe_says "$(printf '%s' "$("$GATE_REAL_NODE" -e 'process.stdout.write(new Date(Date.now()-60000).toISOString())')")")" \
  "inflight"

DIVERGE_ACTUAL=""
for sp in "${NAN_CELLS[@]}" "${FINITE_CELLS[@]}"; do
  G="$(gpe_says "$sp")"; C="$(gate_counts "$sp")"
  # UNREADABLE is its own label and is NEVER folded into AGREE. Two verdicts nobody could read are
  # not two verdicts that agree, and the first draft of this loop printed nine cheerful `AGREE`
  # lines against a gate that does not exist yet.
  case "$C" in
    UNREADABLE*) label="UNREADABLE" ;;
    *)
      label="AGREE"
      [[ "$G" == "excluded" && "$C" == "counts" ]] && label="DIVERGE"
      [[ "$G" == "inflight" && "$C" == "excluded" ]] && label="DIVERGE"
      ;;
  esac
  DIVERGE_ACTUAL="$DIVERGE_ACTUAL$sp=$label "
  record "AC14 CELL [$sp]: phase-entry guard says $G, the gate says $C -> $label"
done
# The expected label set is stated IN ADVANCE, not read off the run: the NaN spellings diverge and
# the finite ones agree. A cell where they agree must be RECORDED as agreement, never asserted as
# divergence -- which is the round-3 defect this row exists to prevent recurring.
DIVERGE_EXPECTED="json:null=DIVERGE json:{}=DIVERGE json:true=DIVERGE json:[]=DIVERGE =DIVERGE nope=DIVERGE __ABSENT__=DIVERGE json:12345=AGREE 12345=AGREE "
assert_eq "AC14: the divergence set is EXACTLY the NaN spellings; the finite ones AGREE" \
  "$DIVERGE_ACTUAL" "$DIVERGE_EXPECTED"

# ===============================================================================================
suite "AC37: an undatable record is NEVER the resolved OWNER"
# ===============================================================================================
#
# Inclusion alone was unsafe in the direction the round-3 spec did not state: it can grow the set
# from zero to one, and R4 would then treat a record whose recency is by construction unknowable
# -- an arbitrarily old abandoned run -- as the owner and deny on its authority. Both reviewers
# found this independently.
for sp in "__ABSENT__" "nope" "json:null" "json:{}" "json:true"; do
  R="$TEMP_PROJECT/sole-undatable-$(printf '%s' "$sp" | tr -c 'A-Za-z0-9' '_')"
  gate_status "$R/.pipeline/106/status.json" current_phase=4-review "updated_at=$sp"
  assert_eq "AC37 [$sp]: the SOLE candidate cannot be dated, so it is not the owner -> NOT denied" \
    "$(sub_verdict "$R")" "none"
  # DISCRIMINATION: give that same record a fresh parseable updated_at and the verdict must flip.
  gate_inflight_status "$R/.pipeline/106/status.json" "4-review"
  assert_eq "AC37 DISCRIMINATION [$sp]: re-dating the SAME record flips abstain -> deny" \
    "$(sub_verdict "$R")" "deny"
done

# The two non-actions must be TELLABLE APART: "two candidates, cannot choose" is a different
# diagnosis from "one candidate, cannot date it", and a reader gets one look.
R_TWO="$TEMP_PROJECT/attr-two-candidates"
gate_inflight_status "$R_TWO/.pipeline/106/status.json" "4-review"
gate_inflight_status "$R_TWO/.pipeline/98/status.json" "3-impl"
R_UNDATABLE="$TEMP_PROJECT/attr-undatable-sole"
gate_status "$R_UNDATABLE/.pipeline/106/status.json" current_phase=4-review updated_at=nope
ATTR_TWO="$(sub_attribution "$R_TWO")"
ATTR_UND="$(sub_attribution "$R_UNDATABLE")"
# VACUITY GUARD for every later `attribution == ATTR_TWO` comparison in this file (AC40, AC42(i)):
# two empty strings are equal, so a gate that recovers nothing at all would satisfy them silently.
assert_eq "VACUITY: the R4 ownership abstention's attribution is itself non-empty (every later comparison against it depends on this)" \
  "$([[ -n "$(printf '%s' "$ATTR_TWO" | tr -d '[:space:]')" ]] && echo non-empty || echo "EMPTY: nothing is recoverable, so the comparisons below prove nothing")" "non-empty"
assert_eq "AC37: the undatable-sole-candidate attribution is non-empty" \
  "$([[ -n "$(printf '%s' "$ATTR_UND" | tr -d '[:space:]')" ]] && echo non-empty || echo EMPTY)" "non-empty"
assert_eq "AC37: and is DISTINCT from the R4 ownership abstention's" \
  "$([[ "$ATTR_UND" != "$ATTR_TWO" ]] && echo distinct || echo "COLLAPSED into one attribution")" "distinct"

# ===============================================================================================
suite "AC12: run ownership over TWO in-flight dirs, both mtime orderings, IDENTICAL abstention"
# ===============================================================================================
#
# SIMPLIFIED BY R4's CLEAN RULE: with two in-flight candidates and no honoured marker the gate
# abstains REGARDLESS of mtime order, so (i) needs no reasoning about which dir is newer. Both
# orderings are asserted and must produce the IDENTICAL abstention, which is itself the check that
# no mtime selection survives anywhere. Three rounds running reintroduced that derivation in a new
# shape -- selector, then tie-break, then "select among" -- which is why it is now a prohibition.
mk_two() {  # <which dir to touch LAST> -> prints a FRESH root
  local last="$1" r
  r="$(gate_fresh_root)" || return 90
  gate_inflight_status "$r/.pipeline/39/status.json" "3-impl"
  gate_inflight_status "$r/.pipeline/98/status.json" "4-review"
  sleep 0.05
  touch "$r/.pipeline/$last/status.json"
  printf '%s' "$r"
}
R_A="$(mk_two 98)"
R_B="$(mk_two 39)"

V_A="$(sub_verdict "$R_A")"; V_B="$(sub_verdict "$R_B")"
assert_eq "AC12(i): two in-flight dirs, the '4-review' one NEWEST by mtime -> NOT denied" "$V_A" "none"
assert_eq "AC12(i): two in-flight dirs, the '3-impl' one NEWEST by mtime -> NOT denied" "$V_B" "none"
assert_eq "AC12(i): and the two orderings produce the IDENTICAL outcome (no mtime selection survives)" "$V_A" "$V_B"

# CONTROL that the mtime orderings really differed, or the row above compares two identical roots.
MT_A="$("$GATE_REAL_NODE" -e 'const {statSync}=require("node:fs");const a=statSync(process.argv[1]).mtimeMs,b=statSync(process.argv[2]).mtimeMs;process.stdout.write(a>b?"98-newer":a<b?"39-newer":"TIE")' "$R_A/.pipeline/98/status.json" "$R_A/.pipeline/39/status.json")"
MT_B="$("$GATE_REAL_NODE" -e 'const {statSync}=require("node:fs");const a=statSync(process.argv[1]).mtimeMs,b=statSync(process.argv[2]).mtimeMs;process.stdout.write(a>b?"98-newer":a<b?"39-newer":"TIE")' "$R_B/.pipeline/98/status.json" "$R_B/.pipeline/39/status.json")"
assert_eq "FIXTURE CONTROL: the two roots really do carry OPPOSITE mtime orderings ($MT_A vs $MT_B)" \
  "$([[ "$MT_A" == "98-newer" && "$MT_B" == "39-newer" ]] && echo opposite || echo "NOT OPPOSITE: $MT_A / $MT_B")" "opposite"

# (ii) the same payload against a SINGLE in-flight '4-review' dir IS denied.
assert_eq "AC12(ii): a single in-flight '4-review' dir -> DENIED" "$(sub_verdict "$R_LIVE")" "deny"

# The abstention in (i) is asserted AS an abstention, never as an indistinguishable allow.
ATTR_ABSTAIN="$(sub_attribution "$R_A")"
ATTR_ALLOWED="$(gate_reset_env "$R_LIVE"; GATE_TMPDIR="$TEMP_PROJECT/own-tmp"; mkdir -p "$GATE_TMPDIR"; \
  gate_run_with_sinks "$(gate_payload 'git add plugins/pipeline/agents/qa.md' agent_id=sub-own agent_type=pipeline:qa)" \
  "$TEMP_PROJECT/own-manifest.json" "$R_LIVE" "$GATE_TMPDIR"; \
  printf '%s\n%s' "$GATE_ATTRIBUTION" "$GATE_REASON" | gate_normalize_attribution)"
assert_eq "AC12: the ownership ABSTENTION is recoverable and distinct from an ordinary allow" \
  "$([[ -n "$(printf '%s' "$ATTR_ABSTAIN" | tr -d '[:space:]')" && "$ATTR_ABSTAIN" != "$ATTR_ALLOWED" ]] && echo distinct || echo "INDISTINGUISHABLE FROM AN ALLOW")" "distinct"

# ===============================================================================================
suite "AC25: PORTABILITY -- multi-root, and ownership binds across EVERY root consulted"
# ===============================================================================================
#
# An adopting project that gitignores .pipeline -- which this repo's own .gitignore advises --
# leaves a Phase 4 dispatch worktree with none, so a gate that resolves only from cwd is silent in
# the deployment R18 protects.
EMPTY_CWD="$TEMP_PROJECT/adopting-project-no-pipeline"
mkdir -p "$EMPTY_CWD"
gate_reset_env "$EMPTY_CWD"
GATE_PROJECT_DIR="$R_LIVE"
run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-25 agent_type=pipeline:qa "cwd=$EMPTY_CWD")"
assert_eq "AC25: cwd has NO .pipeline, CLAUDE_PROJECT_DIR does -> still DENIED" "$GATE_DECISION" "deny"

# Removing CLAUDE_PROJECT_DIR from resolution reddens this and only this.
gate_reset_env "$EMPTY_CWD"
GATE_PROJECT_DIR="__UNSET__"
run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-25 agent_type=pipeline:qa "cwd=$EMPTY_CWD")"
assert_eq "AC25 CONTROL: with CLAUDE_PROJECT_DIR unset and no .pipeline anywhere, nothing is denied" \
  "$GATE_DECISION" "none"

# AC12's ownership property, re-asserted with .pipeline reachable from TWO roots. A second root's
# NEWER record must not override the first root's ownership resolution: across roots the candidate
# set is still two, so R4(3) abstains.
ROOT_ONE="$TEMP_PROJECT/multiroot-cwd"
gate_inflight_status "$ROOT_ONE/.pipeline/39/status.json" "3-impl"
ROOT_TWO="$TEMP_PROJECT/multiroot-project"
gate_inflight_status "$ROOT_TWO/.pipeline/98/status.json" "4-review"
sleep 0.05; touch "$ROOT_TWO/.pipeline/98/status.json"
gate_reset_env "$ROOT_ONE"
GATE_PROJECT_DIR="$ROOT_TWO"
run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-25 agent_type=pipeline:qa "cwd=$ROOT_ONE")"
assert_eq "AC25: a SECOND root's newer '4-review' record does not override the first root's ownership -> abstain" \
  "$GATE_DECISION" "none"

# ===============================================================================================
suite "AC26/AC27: the seam extension is ADDITIVE, and the gate FOLLOWS it"
# ===============================================================================================
#
# The new export is DISCOVERED rather than named. QA authors this contract before the
# implementation exists, so pinning an export name would be authoring the implementation's shape
# and would force Dev to match a guess. What the criterion actually requires is behavioural: a
# reachable export that DISTINGUISHES a marker resolution from an inferred one -- which today's
# bare-path return cannot express.
BASE_EXPORTS="ISSUE_DIR_RE acLabel acLabels activeIssueDir checkArtifacts groundFalsifiability groundImplReport groundOpenQuestions tokens validate"
NOW_EXPORTS="$("$GATE_REAL_NODE" --input-type=module -e "
  const m = await import('file://$GATE_PLUGIN_DIR/scripts/validate-pipeline-artifact.mjs');
  process.stdout.write(Object.keys(m).sort().join(' '));" 2>/dev/null)"
record "validate-pipeline-artifact.mjs exports NOW: $NOW_EXPORTS"
NEW_EXPORTS="$(comm -13 <(printf '%s\n' $BASE_EXPORTS | LC_ALL=C sort) <(printf '%s\n' $NOW_EXPORTS | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "AC26: the reviewed commit's ten exports are all still there (the extension is ADDITIVE)" \
  "$(comm -23 <(printf '%s\n' $BASE_EXPORTS | LC_ALL=C sort) <(printf '%s\n' $NOW_EXPORTS | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ *$//')" ""
assert_eq "AC27: at least one NEW export is reachable (found: [$NEW_EXPORTS])" \
  "$([[ -n "$NEW_EXPORTS" ]] && echo present || echo "NO NEW EXPORT")" "present"

# The new export must return a value that DISTINGUISHES marker from inference. Same resolved dir,
# two provenances: with the marker set and without it, against a root where the sole in-flight
# record is the one the marker names.
SEAM_ROOT="$TEMP_PROJECT/seam-root"
gate_inflight_status "$SEAM_ROOT/.pipeline/106/status.json" "4-review"
DISTINGUISHES="$("$GATE_REAL_NODE" --input-type=module -e "
  const m = await import('file://$GATE_PLUGIN_DIR/scripts/validate-pipeline-artifact.mjs');
  const dir = '$SEAM_ROOT/.pipeline';
  const base = new Set(['ISSUE_DIR_RE','acLabel','acLabels','activeIssueDir','checkArtifacts','groundFalsifiability','groundImplReport','groundOpenQuestions','tokens','validate']);
  const found = [];
  for (const [k, v] of Object.entries(m)) {
    if (base.has(k) || typeof v !== 'function') continue;
    let a, b;
    try { a = JSON.stringify(v(dir, { active_issue: '106' })); } catch { continue; }
    try { b = JSON.stringify(v(dir, {})); } catch { continue; }
    if (a !== undefined && b !== undefined && a !== b) found.push(k + ': marker=' + a + ' inferred=' + b);
  }
  process.stdout.write(found.length ? found.join(' | ') : 'NONE');" 2>/dev/null)"
record "AC27 seam probe: $DISTINGUISHES"
assert_eq "AC27: a new export distinguishes a MARKER resolution from an INFERRED one for the same resolved dir" \
  "$([[ "$DISTINGUISHES" != "NONE" && -n "$DISTINGUISHES" ]] && echo distinguishes || echo "NO EXPORT DISTINGUISHES THEM")" "distinguishes"

# activeIssueDir's own behaviour is UNCHANGED for all four resolution cases. These pass at the
# reviewed commit and must keep passing: they are the regression half of "additive".
ADIR_PROBE() {  # <pipelineDir> <input-json> -> the basename of the resolved dir, or NULL
  # `import path from` and NOT `require`: node refuses a script carrying both a top-level await and
  # a require() with ERR_AMBIGUOUS_MODULE_SYNTAX, and the first draft of this probe swallowed that
  # on stderr and returned the empty string -- four rows then failed for a reason that had nothing
  # to do with the behaviour under test.
  "$GATE_REAL_NODE" --input-type=module -e "
    import path from 'node:path';
    const m = await import('file://$GATE_PLUGIN_DIR/scripts/validate-pipeline-artifact.mjs');
    const r = m.activeIssueDir(process.argv[1], JSON.parse(process.argv[2]));
    process.stdout.write(r === null || r === undefined ? 'NULL' : path.basename(r));" "$1" "$2" 2>/dev/null
}
A_MARKER="$TEMP_PROJECT/adir-marker"; gate_inflight_status "$A_MARKER/.pipeline/39/status.json" "3-impl"; gate_inflight_status "$A_MARKER/.pipeline/98/status.json" "4-review"
A_EMPTY="$TEMP_PROJECT/adir-empty"; mkdir -p "$A_EMPTY/.pipeline"
A_TIE="$TEMP_PROJECT/adir-tie"; gate_inflight_status "$A_TIE/.pipeline/39/status.json" "3-impl"; gate_inflight_status "$A_TIE/.pipeline/98/status.json" "4-review"
touch -t 202601010000 "$A_TIE/.pipeline/39/status.json" "$A_TIE/.pipeline/98/status.json"
A_NEWEST="$TEMP_PROJECT/adir-newest"; gate_inflight_status "$A_NEWEST/.pipeline/39/status.json" "3-impl"; gate_inflight_status "$A_NEWEST/.pipeline/98/status.json" "4-review"; sleep 0.05; touch "$A_NEWEST/.pipeline/98/status.json"

assert_eq "AC27: activeIssueDir, MARKER case, unchanged" "$(ADIR_PROBE "$A_MARKER/.pipeline" '{"active_issue":"39"}')" "39"
assert_eq "AC27: activeIssueDir, STRICT-NEWEST case, unchanged" "$(ADIR_PROBE "$A_NEWEST/.pipeline" '{}')" "98"
assert_eq "AC27: activeIssueDir, TIE case, unchanged (a tie is the ABSENCE of a signal)" "$(ADIR_PROBE "$A_TIE/.pipeline" '{}')" "NULL"
assert_eq "AC27: activeIssueDir, EMPTY-ROOT case, unchanged" "$(ADIR_PROBE "$A_EMPTY/.pipeline" '{}')" "NULL"

# AC26's behavioural half: widening ISSUE_DIR_RE in that module changes the GATE's behaviour,
# because the gate imports it rather than carrying a private copy. An exp-<slug> in-flight dir
# must resolve for the gate too -- voice-lint.mjs's private /^\d+$/ is the recorded precedent for
# what a second copy costs.
R_EXP="$TEMP_PROJECT/exp-dir-root"
gate_inflight_status "$R_EXP/.pipeline/exp-airlock/status.json" "4-review"
assert_eq "AC26: an exp-<slug> in-flight dir resolves for the gate (the shared ISSUE_DIR_RE admits it)" \
  "$(sub_verdict "$R_EXP")" "deny"
R_NONISSUE="$TEMP_PROJECT/nonissue-dir-root"
gate_inflight_status "$R_NONISSUE/.pipeline/_archived/status.json" "4-review"
assert_eq "AC26 CONTROL: a name ISSUE_DIR_RE rejects ('_archived') is not a candidate -> not denied" \
  "$(sub_verdict "$R_NONISSUE")" "none"

# ===============================================================================================
suite "AC34: review_rounds is NOT read"
# ===============================================================================================
#
# It is optional, hand-maintained, and this repo's own telemetry records it disagreeing with the
# events it summarizes on 5 of 7 committed records IN BOTH DIRECTIONS. Pinned behaviourally
# rather than by a grep alone, so it holds however the gate is written.
R_RR_HI="$TEMP_PROJECT/rr-plus2"; gate_inflight_status "$R_RR_HI/.pipeline/43/status.json" "4-review" "review_rounds=json:5" "events=json:[]"
R_RR_LO="$TEMP_PROJECT/rr-minus2"; gate_inflight_status "$R_RR_LO/.pipeline/56/status.json" "4-review" "review_rounds=json:0" "events=json:[]"
assert_eq "AC34: review_rounds=5 with an empty events[] (+2 shape) -> denied, per current_phase alone" \
  "$(sub_verdict "$R_RR_HI")" "deny"
assert_eq "AC34: review_rounds=0 with an empty events[] (-2 shape) -> denied just the same" \
  "$(sub_verdict "$R_RR_LO")" "deny"
GATE_SRC_FILE="$(gate_resolved_command "$GATE_PLUGIN_DIR" | awk '{print $1}')"
# `head -1` is load-bearing, not tidying. On ZERO matches `grep -c` prints `0` AND exits 1, so
# `|| echo 0` fires too and the substitution yields TWO lines -- an embedded newline in a record()
# message, which _ledger writes as two ledger lines against one counted assertion, tripping
# _assert_count_guard (failed=0 rc=1) with nothing behaviourally wrong. The `|| echo 0` still has
# a job: a MISSING/unreadable file exits 2 with no stdout at all. Three paths, exactly one line.
record "AC34 grep: review_rounds occurs $( { grep -c 'review_rounds' "$GATE_SRC_FILE" 2>/dev/null || echo 0; } | head -1 | tr -d ' ') time(s) in the declared gate command's own file"

# ===============================================================================================
suite "AC41: the resolver's RAW answer and R5's narrowing are made to DISAGREE"
# ===============================================================================================
#
# The shared resolver R16 mandates is in-flight-BLIND on both its paths: it consults directory
# names, status.json mtime and the marker, and never reads final_verdict or updated_at. Every
# fixture population elsewhere in this spec is built from in-flight dirs, so the resolver and R5's
# candidate set agree in every cell -- and a mutation DELETING THE NARROWING ENTIRELY would pass
# the whole suite. This is the population where they actively disagree.
mk_disagree() {  # <how the 4-review record is excluded: stale|verdict> -> prints a FRESH root
  local how="$1" r
  r="$(gate_fresh_root)" || return 90
  gate_inflight_status "$r/.pipeline/39/status.json" "3-impl"
  if [[ "$how" == "stale" ]]; then
    gate_status "$r/.pipeline/98/status.json" current_phase=4-review "updated_at=agoms:$STALE_MS"
  else
    gate_status "$r/.pipeline/98/status.json" current_phase=4-review "updated_at=agoms:$NOW_MS" final_verdict=APPROVE
  fi
  sleep 0.05; touch "$r/.pipeline/98/status.json"   # NEWEST by mtime: the raw resolver returns it
  printf '%s' "$r"
}
for how in stale verdict; do
  R="$(mk_disagree "$how")"
  assert_eq "AC41 FIXTURE CONTROL [$how]: the RAW resolver really does return the EXCLUDED dir" \
    "$(ADIR_PROBE "$R/.pipeline" '{}')" "98"
  assert_eq "AC41 [$how]: the narrowing excludes it, so the resolver's raw answer is discarded -> NOT denied" \
    "$(sub_verdict "$R")" "none"
  for ch in payload env1 env2; do
    case "$ch" in
      payload) V="$(sub_verdict "$R" active_issue=98)" ;;
      env1)    gate_reset_env "$R"; GATE_EXTRA_ENV=("CLAUDE_PIPELINE_ACTIVE_ISSUE=98"); run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-own agent_type=pipeline:qa)"; V="$GATE_DECISION" ;;
      env2)    gate_reset_env "$R"; GATE_EXTRA_ENV=("PIPELINE_ACTIVE_ISSUE=98"); run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-own agent_type=pipeline:qa)"; V="$GATE_DECISION" ;;
    esac
    assert_eq "AC41 [$how] marker channel '$ch' naming the EXCLUDED dir is NOT honoured (R25(a)) -> still not denied" "$V" "none"
  done
done

# DISCRIMINATION, TWO CELLS, because round 5 collapsed them and took the wrong branch.
# CELL (i): re-date the excluded record so it IS in flight, leaving the '3-impl' record in place.
# The candidate set becomes TWO and the verdict STAYS not-denied -- but the ATTRIBUTION must
# change, from "the resolver named a record the narrowing excludes" to the R4 ownership
# abstention. The verdict is identical in both states, so attribution is the only thing that can
# discriminate here, and a criterion asserting the verdict alone would pass under either.
R_I="$(mk_disagree stale)"
ATTR_BEFORE="$(sub_attribution "$R_I")"
gate_inflight_status "$R_I/.pipeline/98/status.json" "4-review"
ATTR_AFTER="$(sub_attribution "$R_I")"
assert_eq "AC41 CELL (i): re-dating leaves the verdict unchanged (still not denied)" "$(sub_verdict "$R_I")" "none"
assert_eq "AC41 CELL (i): but the ATTRIBUTION changes -- resolver-named-an-excluded-record vs the R4 ownership abstention" \
  "$([[ -n "$(printf '%s' "$ATTR_BEFORE" | tr -d '[:space:]')" && "$ATTR_BEFORE" != "$ATTR_AFTER" ]] && echo changed || echo "IDENTICAL: the two abstentions are indistinguishable")" "changed"

# CELL (ii): re-date AND remove the '3-impl' record, so the '4-review' record is the SOLE
# candidate. Only this cell may assert a deny.
# `rm -f` on the record, never `rm -rf` on the directory: tests/test-harness.sh refuses a
# hand-rolled `rm -rf` in a new suite, and an issue dir with no status.json is not a candidate,
# which is the removal this cell actually needs.
rm -f "$R_I/.pipeline/39/status.json"
assert_eq "AC41 CELL (ii): sole candidate at a Phase 4 phase -> the verdict FLIPS to denied" "$(sub_verdict "$R_I")" "deny"

# THE REDDENING SET IS NAMED IN ADVANCE. Round 5 and round 6 both asserted "AC41 reddens and no
# other criterion does"; DBA measured that the narrowing-deletion mutation reddens SIX. A mutation
# that reddens six is not a defect in the mutation; asserting it reddens one is a defect in the
# spec. Recorded here so the Phase 4 mutation run has the expected set to compare against.
record "AC41 EXPECTED REDDENING SET for 'delete the narrowing, pass the resolver's raw answer through': {AC41, AC12, AC30(c), AC38, AC40, AC42}. Any criterion outside that set going red is itself the finding."

# ===============================================================================================
suite "AC38: MARKER PRECEDENCE, widen-only, with P1/P2 premises and VOID cells"
# ===============================================================================================
#
# R25 reverses round 4: an explicit signal MUST NOT be able to NARROW the subject. That is this
# repo's existing decision, not a new one -- scripts/gate-phase-entry.mjs:30-33 states it and
# :700-711 implements it. So: no cell may go from deny to non-deny; a cell naming an in-flight
# Phase 4 record MAY go from abstain to deny; and a marker naming a record R5 EXCLUDES is not
# honoured at all.
#
# PRECONDITIONS ARE ASSERTED AND A CELL WHOSE PRECONDITION FAILS IS VOID -- reported as not-run
# with the failing premise NAMED, never as a pass, never as a failure, and never as "the channel
# does not reach the hook", which is the misreading that turns a fixture-construction defect into
# a phantom mechanism defect. A run in which every cell is VOID fails the suite, because a matrix
# that never fired has measured nothing.
MK_ROOT=""
mk_marker_root() {
  MK_ROOT="$(gate_fresh_root)" || return 90
  gate_inflight_status "$MK_ROOT/.pipeline/39/status.json" "3-impl"
  gate_inflight_status "$MK_ROOT/.pipeline/98/status.json" "4-review"
}
mk_marker_root

marker_verdict() {  # <channel> <issue> -> decision
  local ch="$1" iss="$2"
  gate_reset_env "$MK_ROOT"
  case "$ch" in
    payload) run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-38 agent_type=pipeline:qa "active_issue=$iss")" ;;
    CLAUDE_PIPELINE_ACTIVE_ISSUE|PIPELINE_ACTIVE_ISSUE)
      GATE_EXTRA_ENV=("$ch=$iss")
      run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-38 agent_type=pipeline:qa)" ;;
  esac
  printf '%s' "$GATE_DECISION"
}

VOID_CELLS=0
FIRED_CELLS=0

# P1: with the marker UNSET the root ABSTAINS.
BASE_VERDICT="$(sub_verdict "$MK_ROOT")"
assert_eq "AC38 P1: with NO marker, the two-candidate root abstains (the premise every verdict-changing cell rests on)" \
  "$BASE_VERDICT" "none"
# P2: the record the marker names IS in R5's candidate set for that root, so R25(a) honours it.
P2_OK="$(gate_status "$TEMP_PROJECT/p2probe.json" >/dev/null 2>&1; "$GATE_REAL_NODE" -e '
  const s = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  const parsed = Date.parse(s.updated_at);
  const inflight = !s.final_verdict && Number.isFinite(parsed) && (Date.now() - parsed) <= 24*60*60*1000;
  process.stdout.write(inflight && String(s.current_phase).startsWith("4-") ? "in-candidate-set" : "NOT-IN-SET");
' "$MK_ROOT/.pipeline/98/status.json")"
assert_eq "AC38 P2: the record the marker names (98, '4-review') IS in R5's candidate set for this root" \
  "$P2_OK" "in-candidate-set"

for ch in payload CLAUDE_PIPELINE_ACTIVE_ISSUE PIPELINE_ACTIVE_ISSUE; do
  if [[ "$BASE_VERDICT" != "none" || "$P2_OK" != "in-candidate-set" ]]; then
    VOID_CELLS=$((VOID_CELLS + 1))
    assert_eq "AC38 VERDICT-CHANGING CELL [$ch] is VOID: premise $( [[ "$BASE_VERDICT" != "none" ]] && echo P1 || echo P2 ) failed -- reported as NOT RUN, not as a pass" \
      "VOID" "VOID"
  else
    FIRED_CELLS=$((FIRED_CELLS + 1))
    assert_eq "AC38 VERDICT-CHANGING CELL [$ch]: naming the in-flight '4-review' record moves abstain -> DENY" \
      "$(marker_verdict "$ch" 98)" "deny"
  fi
  # The marker cannot SUPPRESS: naming the '3-impl' record resolves a subject at a non-Phase-4
  # phase, which is an abstain, never a way to turn a deny off.
  assert_eq "AC38 [$ch]: naming the '3-impl' record does not manufacture a deny (and could not suppress one)" \
    "$(marker_verdict "$ch" 39)" "none"
done

assert_eq "AC38: at least one verdict-changing cell FIRED (an all-VOID matrix has measured nothing and fails the suite)" \
  "$([[ "$FIRED_CELLS" -ge 1 ]] && echo fired || echo "ALL $VOID_CELLS CELLS VOID")" "fired"

# THE HONOURING PRECONDITION, which is the genuinely mutable term (the union-vs-override control
# round 5 named cannot fire: given R25(a) and R4's resolution order the two designs produce the
# identical verdict in every reachable state, so it is a theorem and is recorded in
# falsifiability_pass.unmutable rather than left as a control that quietly passes).
MK_EXCL=""
for how in concluded stale; do
  MK_EXCL="$(gate_fresh_root)"
  gate_inflight_status "$MK_EXCL/.pipeline/39/status.json" "3-impl"
  if [[ "$how" == "concluded" ]]; then
    gate_status "$MK_EXCL/.pipeline/98/status.json" current_phase=4-review "updated_at=agoms:$NOW_MS" final_verdict=APPROVE
  else
    gate_status "$MK_EXCL/.pipeline/98/status.json" current_phase=4-review "updated_at=agoms:$STALE_MS"
  fi
  gate_reset_env "$MK_EXCL"
  run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-38 agent_type=pipeline:qa active_issue=98)"
  assert_eq "AC38 HONOURING PRECONDITION [$how]: a marker naming a record R5 EXCLUDES is NOT honoured -> falls back to the inference -> not denied" \
    "$GATE_DECISION" "none"
done

# WIDEN-ONLY, the direction itself: a root where the INFERENCE already denies must not be talked
# out of it by any marker naming a record outside the candidate set.
MK_DENY="$TEMP_PROJECT/marker-cannot-suppress"
gate_inflight_status "$MK_DENY/.pipeline/106/status.json" "4-review"
gate_status "$MK_DENY/.pipeline/56/status.json" current_phase=5-archived "updated_at=agoms:$NOW_MS" final_verdict=APPROVE
for ch in payload CLAUDE_PIPELINE_ACTIVE_ISSUE PIPELINE_ACTIVE_ISSUE; do
  gate_reset_env "$MK_DENY"
  case "$ch" in
    payload) run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-38 agent_type=pipeline:qa active_issue=56)" ;;
    *) GATE_EXTRA_ENV=("$ch=56"); run_gate "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-38 agent_type=pipeline:qa)" ;;
  esac
  assert_eq "AC38 WIDEN-ONLY [$ch]: a marker naming a concluded record cannot turn an inferred DENY into a non-deny" \
    "$GATE_DECISION" "deny"
done

# R25(b): a deny whose subject came from the MARKER carries its own distinct attribution, so an
# over-refusal is diagnosable in one look.
mk_marker_root
ATTR_MARKER_DENY="$(gate_reset_env "$MK_ROOT"; GATE_TMPDIR="$TEMP_PROJECT/own-tmp"; mkdir -p "$GATE_TMPDIR"; \
  gate_run_with_sinks "$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-38 agent_type=pipeline:qa active_issue=98)" \
  "$TEMP_PROJECT/own-manifest.json" "$MK_ROOT" "$GATE_TMPDIR"; \
  printf '%s\n%s' "$GATE_ATTRIBUTION" "$GATE_REASON" | gate_normalize_attribution)"
ATTR_INFER_DENY="$(sub_attribution "$R_LIVE")"
assert_eq "AC38 R25(b): a MARKER-subject deny is attributed differently from an INFERENCE-subject deny" \
  "$([[ -n "$(printf '%s' "$ATTR_MARKER_DENY" | tr -d '[:space:]')" && "$ATTR_MARKER_DENY" != "$ATTR_INFER_DENY" ]] && echo distinct || echo "COLLAPSED: an over-refusal is not diagnosable")" "distinct"

# ===============================================================================================
suite "AC40: R21(e) is DISCLOSED and REACHABLE -- the one-tool-call suppression"
# ===============================================================================================
#
# NOT a fix requirement. This asserts that the disclosed behaviour IS the actual behaviour:
# closing it would require refusing the shard writes AC8 exists to permit. One plain Write of a
# valid-JSON status.json with no parseable updated_at, under a directory panelists write to as
# routine work, enlarges the candidate set and abstains the gate.
R_E="$TEMP_PROJECT/residual-e"
gate_inflight_status "$R_E/.pipeline/106/status.json" "4-review"
PAY_E="$(gate_payload "$FORBIDDEN_CMD" agent_id=sub-40 agent_type=pipeline:qa)"
gate_reset_env "$R_E"; run_gate "$PAY_E"
assert_eq "AC40 BEFORE: the byte-identical payload IS denied" "$GATE_DECISION" "deny"

# THE ONE TOOL CALL: a plain Write of a valid-JSON status.json with no parseable updated_at.
mkdir -p "$R_E/.pipeline/999"
printf '%s\n' '{"issue_number":999,"current_phase":"4-review","updated_at":"not-a-date"}' > "$R_E/.pipeline/999/status.json"
gate_reset_env "$R_E"; run_gate "$PAY_E"
assert_eq "AC40 AFTER: the SAME payload now abstains -- the disclosed suppression is the real behaviour" \
  "$GATE_DECISION" "none"
ATTR_E="$(sub_attribution "$R_E")"
assert_eq "AC40: and the non-action carries the R4 OWNERSHIP attribution, matching the two-candidate case" \
  "$([[ "$ATTR_E" == "$ATTR_TWO" ]] && echo ownership-abstention || echo "DIFFERENT ATTRIBUTION: [$ATTR_E] vs [$ATTR_TWO]")" \
  "ownership-abstention"

# ===============================================================================================
suite "AC42: ownership under a REAL clone, where the TIE is not the variable"
# ===============================================================================================
#
# Round 6 built this criterion on an mtime TIE and that premise is false for the deployment it was
# written about. MEASURED on an actual `git clone --no-hardlinks` of this repo: every tracked
# status.json shares ONE whole second while node's mtimeMs carries sub-millisecond decimals and
# all of them are DISTINCT, so the resolver's strict-max finds a winner and NO tie occurs. A
# `touch -t`-forced equality does NOT reproduce a clone and is not used here.
#
# What actually decides the clone case is the CANDIDATE COUNT, not the timestamps.
CLONE="$TEMP_PROJECT/real-clone"
CLONE_OK=no
if git clone -q --no-hardlinks "file://$GATE_REPO_ROOT" "$CLONE" >/dev/null 2>&1; then CLONE_OK=yes; fi
assert_eq "PRECONDITION: a real \`git clone --no-hardlinks\` of this repo (a synthetic touch-built root does not reproduce one)" \
  "$CLONE_OK" "yes"

if [[ "$CLONE_OK" == "yes" ]]; then
  # (iii) NON-ZERO CONTROL ON THE MEASUREMENT ITSELF -- this is where round 6 went wrong. A cell
  # asserting a clone produces a tie must FAIL.
  MEAS="$("$GATE_REAL_NODE" -e '
    const { readdirSync, statSync } = require("node:fs"); const path = require("node:path");
    const root = path.join(process.argv[1], ".pipeline");
    const files = readdirSync(root, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => path.join(root, d.name, "status.json"))
      .filter((f) => { try { statSync(f); return true; } catch { return false; } });
    const ms = files.map((f) => statSync(f).mtimeMs);
    const secs = files.map((f) => Math.floor(statSync(f).mtimeMs / 1000));
    const distinct = (a) => new Set(a).size;
    process.stdout.write(`n=${files.length} distinctMs=${distinct(ms)} distinctSec=${distinct(secs)}`);
  ' "$CLONE")"
  record "AC42(iii) MEASUREMENT on the real clone: $MEAS"
  CN="$(printf '%s' "$MEAS" | sed -n 's/n=\([0-9]*\).*/\1/p')"
  DMS="$(printf '%s' "$MEAS" | sed -n 's/.*distinctMs=\([0-9]*\).*/\1/p')"
  DSEC="$(printf '%s' "$MEAS" | sed -n 's/.*distinctSec=\([0-9]*\).*/\1/p')"
  assert_eq "AC42(iii): the clone's status.json mtimeMs values are ALL DISTINCT, so the resolver's strict-max finds a WINNER (no tie)" \
    "$([[ "${DMS:-0}" -eq "${CN:-0}" && "${CN:-0}" -ge 2 ]] && echo all-distinct || echo "NOT ALL DISTINCT: $MEAS")" "all-distinct"
  assert_eq "AC42(iii): while their WHOLE SECONDS collapse, which is why a seconds-grained fixture would have concluded 'tie'" \
    "$([[ "${DSEC:-99}" -lt "${DMS:-0}" ]] && echo seconds-collapse || echo "SECONDS DO NOT COLLAPSE: $MEAS")" "seconds-collapse"

  # (iv) the RAW resolver on the clone returns SOME dir (no tie), and that answer is not what
  # decides ownership. Recorded rather than pinned to a literal: which dir wins depends on the
  # checkout order of a clone taken now, and a transcribed name would be stale before it is read.
  RAW_ON_CLONE="$(ADIR_PROBE "$CLONE/.pipeline" '{}')"
  record "AC42(iv) the RAW resolver on this clone returns: $RAW_ON_CLONE"
  assert_eq "AC42(iv): the raw resolver finds a STRICT winner on a real clone (this is what makes an mtime rule dangerous rather than merely useless)" \
    "$([[ "$RAW_ON_CLONE" != "NULL" && -n "$RAW_ON_CLONE" ]] && echo resolves || echo "NULL: the clone tied after all, which contradicts (iii)")" "resolves"

  # (i) the clone with TWO in-flight records, at least one at a Phase 4 phase -> NOT denied, with
  # the ownership abstention. The clone's own records are dated by CONTENT and go stale with the
  # calendar, so the two candidates are established by re-dating IN THE CLONE -- which changes
  # updated_at, never the mtime ordering the criterion is about. That keeps the real clone's real
  # mtimes as the thing under test.
  gate_status "$CLONE/.pipeline/98/status.json" current_phase=4-review "updated_at=agoms:$NOW_MS" issue_number=json:98
  gate_status "$CLONE/.pipeline/39/status.json" current_phase=3-impl "updated_at=agoms:$NOW_MS" issue_number=json:39
  INFLIGHT_N="$("$GATE_REAL_NODE" -e '
    const { readdirSync, readFileSync, statSync } = require("node:fs"); const path = require("node:path");
    const root = path.join(process.argv[1], ".pipeline");
    let n = 0;
    for (const d of readdirSync(root, { withFileTypes: true })) {
      if (!d.isDirectory() || !/^(\d+|exp-[a-z0-9]+(-[a-z0-9]+)*)$/.test(d.name)) continue;
      const f = path.join(root, d.name, "status.json");
      let s; try { s = JSON.parse(readFileSync(f, "utf8")); } catch { continue; }
      if (s.final_verdict) continue;
      const p = Date.parse(s.updated_at);
      if (!Number.isFinite(p)) { n++; continue; }
      if (Date.now() - p <= 24*60*60*1000) n++;
    }
    process.stdout.write(String(n));
  ' "$CLONE")"
  record "AC42(i) PREMISE: the clone now carries $INFLIGHT_N in-flight record(s) by R5's predicate"
  assert_eq "AC42(i) PREMISE: the clone carries TWO OR MORE in-flight records (otherwise cell (i) is VOID, not a pass)" \
    "$([[ "${INFLIGHT_N:-0}" -ge 2 ]] && echo two-or-more || echo "ONLY $INFLIGHT_N")" "two-or-more"
  assert_eq "AC42(i): on a real clone with two in-flight records, the payload is NOT denied -- round 6's rule would have let 98 own the deny and refuse correct work in 106's session" \
    "$(sub_verdict "$CLONE")" "none"
  ATTR_CLONE="$(sub_attribution "$CLONE")"
  assert_eq "AC42(i): and it carries the R4 OWNERSHIP abstention attribution" \
    "$([[ "$ATTR_CLONE" == "$ATTR_TWO" ]] && echo ownership-abstention || echo "DIFFERENT: [$ATTR_CLONE]")" "ownership-abstention"

  # (ii) the same clone reduced to exactly ONE in-flight record at a Phase 4 phase -> DENIED, with
  # the owner resolved from record CONTENT and the resolver's raw answer irrelevant.
  gate_status "$CLONE/.pipeline/39/status.json" current_phase=3-impl "updated_at=agoms:$STALE_MS" issue_number=json:39
  for d in "$CLONE"/.pipeline/*/; do
    b="$(basename "$d")"
    [[ "$b" == "98" || "$b" == "_archived" || "$b" == "schemas" ]] && continue
    [[ -f "$d/status.json" ]] || continue
    "$GATE_REAL_NODE" -e '
      const fs = require("node:fs"); const f = process.argv[1];
      const s = JSON.parse(fs.readFileSync(f, "utf8"));
      s.final_verdict = s.final_verdict || "APPROVE";
      fs.writeFileSync(f, JSON.stringify(s, null, 2) + "\n");' "$d/status.json" 2>/dev/null
  done
  assert_eq "AC42(ii): reduced to exactly ONE in-flight record at a Phase 4 phase -> DENIED" \
    "$(sub_verdict "$CLONE")" "deny"
else
  assert_eq "AC42: the clone did not happen, so cells (i)-(iv) did not run -- reported as a FAILURE, never a skip" \
    "clone-failed" "cloned"
fi

# ===============================================================================================
suite "AC28: SubagentStop is UNTOUCHED"
# ===============================================================================================
#
# This criterion exists to catch the failure this issue is ABOUT, one level up: a change reviewed
# for one thing silently altering a shipped gate. Paired same-run capture against the reviewed
# commit, from one pinned cwd against one record-store state.
SS_BASE_SHA="$(git -C "$GATE_REPO_ROOT" merge-base HEAD origin/main 2>/dev/null || git -C "$GATE_REPO_ROOT" rev-parse HEAD~1 2>/dev/null || printf '')"
SS_WT="$TEMP_PROJECT/subagentstop-base"
SS_OK=no
if [[ -n "$SS_BASE_SHA" ]] && git -C "$GATE_REPO_ROOT" worktree add -q --detach "$SS_WT" "$SS_BASE_SHA" >/dev/null 2>&1; then SS_OK=yes; fi
assert_eq "PRECONDITION: the reviewed commit is checked out for the SubagentStop paired capture" "$SS_OK" "yes"

if [[ "$SS_OK" == "yes" ]]; then
  SS_ROOT="$TEMP_PROJECT/subagentstop-two-dirs"
  gate_inflight_status "$SS_ROOT/.pipeline/39/status.json" "3-impl"
  gate_inflight_status "$SS_ROOT/.pipeline/98/status.json" "4-review"
  sleep 0.05; touch "$SS_ROOT/.pipeline/98/status.json"
  ss_capture() {
    local sd="$1" o e r
    o="$( ( cd "$SS_ROOT" && printf '%s' '{"hook_event_name":"SubagentStop","session_id":"ac28","agent_type":"pipeline:qa"}' \
        | CLAUDE_PROJECT_DIR="$SS_ROOT" "$GATE_REAL_NODE" "$sd/validate-pipeline-artifact.mjs" 2>"$TEMP_PROJECT/ss.err" ) )"; r=$?
    e="$(cat "$TEMP_PROJECT/ss.err")"
    printf 'rc=%s out=[%s] err=[%s]' "$r" "$o" "$e"
  }
  SS_A="$(ss_capture "$SS_WT/plugins/pipeline/scripts")"
  SS_B="$(ss_capture "$GATE_PLUGIN_DIR/scripts")"
  record "AC28 reviewed-commit SubagentStop resolution on a two-in-flight-dir root: $SS_A"
  assert_eq "AC28: the SubagentStop path resolves EXACTLY as it does at the reviewed commit" "$SS_B" "$SS_A"
  git -C "$GATE_REPO_ROOT" worktree remove --force "$SS_WT" >/dev/null 2>&1
else
  assert_eq "AC28: the paired capture did not run -- reported as a FAILURE, never a skip" "could-not-check-out" "ran"
fi

finish
