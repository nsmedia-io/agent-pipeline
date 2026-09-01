#!/usr/bin/env bash
# #106, part 5 of 5: the ARTIFACT this issue exists to make honest.
#
# AC29 the retired sentence is gone from all ten files; the replacement lands in exactly ten;
#      byte-identity across the NINE agents/*.md only; every residual clause present in all TEN
# AC30 each of the six residuals has a PAYLOAD FIXTURE whose outcome the sentence claims
# AC31 the catcher names the missing clause, and its expected set is held where the deletion
#      cannot edit it
# AC32 stale-claim sync: the "three hooks" fact and its three other consumers
# AC33 every <path>:<n> citation opens
#
# NO MECHANICAL DIGEST EXISTS TODAY for either replicated span (R24), so this is new test surface
# rather than something already wired. Do not assume an existing check would catch a drifted copy.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
require_node

make_temp_project 106 || exit 90
GATE_SCRATCH="$TEMP_PROJECT"
gate_cache_declaration

AGENTS_DIR="$GATE_PLUGIN_DIR/agents"
PIPELINE_MD="$GATE_PIPELINE_MD"
PLUGIN_README="$GATE_PLUGIN_DIR/README.md"
ROOT_README="$GATE_REPO_ROOT/README.md"
RETIRED="nothing mechanically enforces it either"

AGENT_FILES=()
while IFS= read -r f; do AGENT_FILES+=("$f"); done < <(ls "$AGENTS_DIR"/*.md | LC_ALL=C sort)
TEN_FILES=("${AGENT_FILES[@]}" "$PIPELINE_MD")

assert_eq "FIXTURE PREMISE: there are NINE agents/*.md files (the population every count below is stated against)" \
  "${#AGENT_FILES[@]}" "9"
assert_eq "FIXTURE PREMISE: and TEN files carry the block in total, the tenth being commands/pipeline.md" \
  "${#TEN_FILES[@]}" "10"

# ===============================================================================================
suite "AC29: the retirement, the ten-file landing, and the nine-file byte-identity"
# ===============================================================================================

# tests/ IS EXCLUDED, and that exclusion is the point rather than a convenience. A scanner cannot
# tell a QUOTATION from a CLAIM: this suite must name the sentence it is retiring in order to
# search for it, and test-pretooluse-gate-verdicts.sh carries it inside AC7's quote-aware fixture
# because this issue's own doc-retirement commit message is the fixture. A ban that fires on the
# diff that retires it is the recorded shape of this defect. The scan therefore covers every
# shipped surface -- agents/, commands/, hooks/, scripts/, schemas/, README.md -- and only the
# suite that has to quote the string is out.
RETIRED_HITS="$(grep -rl "$RETIRED" "$GATE_PLUGIN_DIR" 2>/dev/null \
  | grep -v "^$GATE_PLUGIN_DIR/tests/" | LC_ALL=C sort | sed "s|^$GATE_REPO_ROOT/||" | tr '\n' ' ' | sed 's/ *$//')"
record "files under plugins/pipeline/ still carrying the retired sentence: ${RETIRED_HITS:-<none>}"
assert_eq "AC29: '$RETIRED' appears in ZERO files under plugins/pipeline/" "$RETIRED_HITS" ""
# NON-ZERO CONTROL for the grep: it must be able to find the sentence when the sentence is there.
printf 'x %s y\n' "$RETIRED" > "$TEMP_PROJECT/planted.md"
assert_eq "NON-ZERO CONTROL: the same grep DOES find a planted copy (a zero result needs one)" \
  "$(grep -rl "$RETIRED" "$TEMP_PROJECT" 2>/dev/null | grep -c 'planted.md' | tr -d ' ')" "1"
# ...and the EXCLUSION is doing work rather than hiding a hole: tests/ genuinely still carries the
# string, so "zero hits outside tests/" is a narrower claim than "zero hits", stated as such.
assert_eq "EXCLUSION CONTROL: tests/ really does still carry the string (the exclusion is narrow and named, not a blanket)" \
  "$([[ "$(grep -rl "$RETIRED" "$GATE_PLUGIN_DIR/tests" 2>/dev/null | grep -c . | tr -d ' ')" -ge 1 ]] && echo carries || echo "tests/ carries none, so the exclusion above hides nothing and can be deleted")" "carries"

# The commit-hygiene paragraph is extracted from each of the nine and compared BYTE FOR BYTE.
hygiene_para() {  # <file> -> the "**Commit hygiene.**" paragraph, verbatim
  awk '/^\*\*Commit hygiene\.\*\*/{f=1} f{print} f&&/^$/{exit}' "$1"
}
NINE_DIGESTS=""
for f in "${AGENT_FILES[@]}"; do
  d="$(hygiene_para "$f" | gate_digest)"
  NINE_DIGESTS="$NINE_DIGESTS$d $(basename "$f")
"
done
DISTINCT_NINE="$(printf '%s' "$NINE_DIGESTS" | awk 'NF{print $1}' | LC_ALL=C sort -u | grep -c . | tr -d ' ')"
record "the nine agents/*.md commit-hygiene paragraphs hash to $DISTINCT_NINE distinct digest(s)"
assert_eq "AC29: the replacement is BYTE-IDENTICAL across the NINE agents/*.md copies" "$DISTINCT_NINE" "1"
# VACUITY: nine EMPTY paragraphs also hash to one digest. The paragraph must have been found.
assert_eq "VACUITY: and the extracted paragraph is non-empty (nine empty strings are also byte-identical)" \
  "$([[ -n "$(hygiene_para "${AGENT_FILES[0]}" | tr -d '[:space:]')" ]] && echo found || echo "EXTRACTED NOTHING from $(basename "${AGENT_FILES[0]}")")" "found"

# ...and commands/pipeline.md's COMPRESSED restatement stays NON-identical, so an over-widening
# reddens. Compression is WORDING, not content: the compressed copy carries all six residuals.
PIPELINE_HYGIENE="$(grep -n 'Before any Phase 4 fix commit' "$PIPELINE_MD" | head -1 | cut -d: -f1)"
assert_eq "AC29: commands/pipeline.md still carries its own restatement of the commit-hygiene rule" \
  "$([[ -n "$PIPELINE_HYGIENE" ]] && echo present || echo ABSENT)" "present"
assert_eq "AC29: and it is NOT byte-identical to the nine (it is a compressed restatement, and forcing identity is an over-widening)" \
  "$([[ "$(sed -n "${PIPELINE_HYGIENE:-1}p" "$PIPELINE_MD" | gate_digest)" != "$(printf '%s' "$NINE_DIGESTS" | awk 'NF{print $1; exit}')" ]] && echo distinct || echo "IDENTICAL")" "distinct"

# ---- the SIX residual clauses, present in all TEN files -----------------------------------------
#
# THE EXPECTED CLAUSE SET IS HELD HERE, in a source the deletion does not edit. A check that
# iterated the clauses PRESENT in the text would run over four after a deletion, find all four
# consistent, and pass green -- which is evidence.md rule 19 exactly, and is the defect this
# criterion was re-pinned to prevent.
#
# EACH CLAUSE IS DETECTED BY CONTENT THE SPEC ITSELF FIXES -- an issue number, a phase literal, a
# field name -- rather than by wording QA invented, so a legitimate rewrite does not redden and a
# deletion cannot hide. Where no such literal exists the detector is a small alternation and is
# marked; if Dev's wording carries the content but not the token, that is a QA conversation, not a
# reason to widen the detector until it matches whatever shipped.
CLAUSE_IDS="a b c1 c2 d e f"
clause_regex() {
  case "$1" in
    # (a) NOT 'orchestrator': that word is already in the block today, so a detector spelled that
    # way reported clause (a) present in all ten before a word of it had been written. The token
    # is `agent_id`, which is the TERM R2 fixes as doing the exempting and which appears in none
    # of the ten today.
    a)  printf '%s' 'agent_id' ;;
    b)  printf '%s' '3-impl' ;;                             # (b) a REQUEST_CHANGES fix round loops to the Dev step at '3-impl'
    c1) printf '%s' '#111' ;;                               # (c1) two-or-more candidates, no marker -> abstain; closable by #111
    c2) printf '%s' '[Zz]ero in.flight|no in.flight record' ;;  # (c2) zero candidates -> abstain; NOT closable by the marker
    d)  printf '%s' 'non-panelist|general-purpose|not pipeline panelists' ;;  # (d) R3's over-refusal
    e)  printf '%s' 'enlarg|one tool call|one plain Write' ;;                 # (e) the deny is suppressible by enlarging the candidate set
    f)  printf '%s' '#110' ;;                               # (f) a delta round carrying a STALE final_verdict is excluded
  esac
}
clause_label() {
  case "$1" in
    a)  printf '%s' "(a) the orchestrator's own blanket commit is exempt by design" ;;
    b)  printf '%s' "(b) a REQUEST_CHANGES fix round runs at '3-impl'" ;;
    c1) printf '%s' "(c1) two-or-more in-flight candidates and no honoured marker -> abstain, closable by #111" ;;
    c2) printf '%s' "(c2) ZERO in-flight candidates -> abstain, NOT closable by the marker, by construction" ;;
    d)  printf '%s' "(d) R3's over-refusal of a non-panelist subagent" ;;
    e)  printf '%s' "(e) the deny is suppressible in one tool call by enlarging the candidate set" ;;
    f)  printf '%s' "(f) a delta round carrying a stale final_verdict is excluded (#110)" ;;
  esac
}

# SCOPED TO THE BLOCK, not to the whole file. A whole-file grep for 'orchestrator' passes on every
# one of these files TODAY, before a single residual has been written -- so an unscoped detector
# would have reported clause (a) present in all ten against the reviewed commit, which is the
# always-green shape this criterion exists to refuse.
clause_scope() {  # <file> -> the replicated block's text
  case "$1" in
    *"/commands/pipeline.md") grep -F 'Phase 4 tracked-write isolation' "$1" ;;
    *) hygiene_para "$1" ;;
  esac
}

MISSING_CLAUSES=""
for cid in $CLAUSE_IDS; do
  n=0
  for f in "${TEN_FILES[@]}"; do
    clause_scope "$f" | grep -Eq "$(clause_regex "$cid")" && n=$((n + 1))
  done
  # THE COUNT IS STATED IN ADVANCE -- ten, per R21's compression-is-wording-not-content ruling --
  # and asserted, rather than read off the run and reported as whatever it was.
  assert_eq "AC29 per-clause presence: $(clause_label "$cid") appears in all TEN files" "$n" "10"
  [[ "$n" -eq 10 ]] || MISSING_CLAUSES="$MISSING_CLAUSES $cid(in $n/10)"
done
assert_eq "AC31: the catcher NAMES the missing clause rather than reporting a mismatched count" \
  "$MISSING_CLAUSES" ""

# ===============================================================================================
suite "AC30/AC31: each residual has a PAYLOAD FIXTURE, and its outcome matches what the text says"
# ===============================================================================================
#
# Round 4 said "four" here while R21, AC29 and AC31 said five, which left (e) -- the only live
# agent-reachable residual -- bound to nothing while AC31 reported a complete pass. Six are bound
# now, and (e)'s fixture is AC40's, delegated BY NAME rather than duplicated:
#   see test-pretooluse-gate-ownership.sh, suite "AC40: R21(e) is DISCLOSED and REACHABLE".
FORBIDDEN_CMD='git commit -a -m "m"'
res_verdict() { gate_reset_env "$1"; run_gate "$2"; printf '%s' "$GATE_DECISION"; }

# (a) no agent_id at '4-review' with a forbidden command -> NOT denied (the orchestrator is exempt)
RA="$TEMP_PROJECT/res-a"; gate_inflight_status "$RA/.pipeline/106/status.json" "4-review"
assert_eq "AC30(a): the orchestrator's own blanket commit (no agent_id) at '4-review' is NOT denied, as the sentence says" \
  "$(res_verdict "$RA" "$(gate_payload "$FORBIDDEN_CMD" agent_id=__ABSENT__)")" "none"

# (b) agent_id present, current_phase '3-impl' with a prior '4-review' in events[] -- the fix-round
#     shape .pipeline/19 and .pipeline/43 carry.
RB="$TEMP_PROJECT/res-b"
gate_inflight_status "$RB/.pipeline/106/status.json" "3-impl" \
  'events=json:[{"phase":"4-review","verdict":"REQUEST_CHANGES","at":"2026-08-31T00:00:00Z"}]'
assert_eq "AC30(b): a REQUEST_CHANGES fix round at '3-impl' with a prior '4-review' in events[] is NOT denied" \
  "$(res_verdict "$RB" "$(gate_payload "$FORBIDDEN_CMD" agent_id=res-b agent_type=pipeline:dev)")" "none"

# (c) THE PAIR that makes (c)'s sentence say both the abstention and its remedy: two in-flight
#     records one of which is at '4-review' -> abstain; the SAME root with a marker naming the
#     '4-review' record -> per R25 it DENIES.
RC="$TEMP_PROJECT/res-c"
gate_inflight_status "$RC/.pipeline/39/status.json" "3-impl"
gate_inflight_status "$RC/.pipeline/98/status.json" "4-review"
assert_eq "AC30(c1): two in-flight records, no marker -> the gate enforces nothing (abstains)" \
  "$(res_verdict "$RC" "$(gate_payload "$FORBIDDEN_CMD" agent_id=res-c agent_type=pipeline:qa)")" "none"
assert_eq "AC30(c1): and a marker naming the '4-review' record resolves it -> DENY (this is the remedy the sentence attaches to c1, and only to c1)" \
  "$(res_verdict "$RC" "$(gate_payload "$FORBIDDEN_CMD" agent_id=res-c agent_type=pipeline:qa active_issue=98)")" "deny"
# (c2) ZERO in-flight records: NOT closable by the marker, BY CONSTRUCTION -- R25(a) honours a
# marker only when the record it names is itself in-flight, and a zero-candidate root has no such
# record. Asserted with the marker SET, which is what makes it a claim about the remedy rather
# than a restatement of the abstention.
RC2="$TEMP_PROJECT/res-c2"
gate_status "$RC2/.pipeline/98/status.json" current_phase=4-review "updated_at=agoms:$(( 48*60*60*1000 ))"
assert_eq "AC30(c2): ZERO in-flight records -> abstain" \
  "$(res_verdict "$RC2" "$(gate_payload "$FORBIDDEN_CMD" agent_id=res-c2 agent_type=pipeline:qa)")" "none"
assert_eq "AC30(c2): and a marker naming that record does NOT lift it, so the remedy attaches to c1 only" \
  "$(res_verdict "$RC2" "$(gate_payload "$FORBIDDEN_CMD" agent_id=res-c2 agent_type=pipeline:qa active_issue=98)")" "none"

# (d) AC6's non-pipeline-role payload.
assert_eq "AC30(d): a non-panelist subagent's blanket staging IS denied while a Phase 4 run is the resolved owner" \
  "$(res_verdict "$RA" "$(gate_payload "$FORBIDDEN_CMD" agent_id=res-d agent_type=general-purpose)")" "deny"

# (e) DELEGATED BY NAME to AC40's fixture in the ownership suite. Restated here only as the
#     cross-reference the criterion requires, so a reader of THIS file knows where it lives and a
#     future edit cannot quietly drop it.
record "AC30(e): fixture delegated by name to test-pretooluse-gate-ownership.sh, suite \"AC40: R21(e) is DISCLOSED and REACHABLE\" -- one plain Write of a valid-JSON status.json with no parseable updated_at, replayed against a byte-identical previously-denied payload"

# (f) a record at a Phase 4 phase carrying a STALE final_verdict from a prior delta round (the
#     .pipeline/19-at-c337579 shape): the gate ABSTAINS because R5 excludes it, and the sentence
#     must say so. This is #110 and this issue does not fix it.
RF="$TEMP_PROJECT/res-f"
gate_status "$RF/.pipeline/19/status.json" current_phase=4-review "updated_at=agoms:60000" \
  final_verdict=APPROVE_WITH_NOTES 'events=json:[{"phase":"4-review","verdict":"DELTA","at":"2026-08-31T00:00:00Z"}]'
assert_eq "AC30(f): a live delta round carrying a STALE final_verdict is excluded, so the gate abstains on a genuinely live Phase 4 run (#110)" \
  "$(res_verdict "$RF" "$(gate_payload "$FORBIDDEN_CMD" agent_id=res-f agent_type=pipeline:qa)")" "none"

# ===============================================================================================
suite "AC32: STALE-CLAIM SYNC -- every consumer of the 'three hooks' fact"
# ===============================================================================================
assert_eq "AC32: plugins/pipeline/README.md no longer says 'The three hooks'" \
  "$(grep -c 'The three hooks' "$PLUGIN_README" | tr -d ' ')" "0"
assert_eq "AC32: and its end-to-end coverage sentence NAMES the new hook (a count fixed without the claim is half a fix)" \
  "$( { grep 'drives each hook end to end' "$PLUGIN_README" | grep -ci 'pretooluse' || true; } | tr -d ' ')" "1"
assert_eq "AC32: the ROOT README.md's hooks/ tree listing names it (currently line 24: 'session-start, stop, subagent-stop')" \
  "$( { grep 'hooks/ ' "$ROOT_README" | grep -ci 'pretooluse\|pre-tool' || true; } | tr -d ' ')" "1"
assert_eq "AC32: commands/pipeline.md's checkpoint dependency note names this hook as the commit-triggered automation whose filter a widened checkpoint would newly match" \
  "$( { grep -i 'commit-triggered automation' "$PIPELINE_MD" | grep -ci 'pretooluse\|pre-tool' || true; } | tr -d ' ')" "1"
# NON-ZERO CONTROL for the three greps above: each pattern must be able to find its CURRENT,
# pre-change text, or a 0 result would mean the pattern is broken rather than the claim unsynced.
assert_eq "NON-ZERO CONTROL: 'drives each hook end to end' is a line that exists to be amended" \
  "$(grep -c 'drives each hook end to end' "$PLUGIN_README" | tr -d ' ')" "1"
assert_eq "NON-ZERO CONTROL: the root README's hooks/ listing line exists to be amended" \
  "$(grep -c 'hooks/ ' "$ROOT_README" | tr -d ' ')" "1"
assert_eq "NON-ZERO CONTROL: pipeline.md's commit-triggered-automation note exists to be amended" \
  "$(grep -ci 'commit-triggered automation' "$PIPELINE_MD" | tr -d ' ')" "1"

# ===============================================================================================
suite "AC33: every <path>:<n> citation OPENS"
# ===============================================================================================
#
# BOTH CITATION FAMILIES, not just README. Round 6 carried 20 citations written as
# `commands/pipeline.md:<n>` -- a path that does not resolve from the repository root, because the
# file is at `plugins/pipeline/commands/pipeline.md` -- and the round-6 check looked only at the
# README family, so nothing caught them. The root README.md is 39 lines; a bare `README.md:84`
# fails this. A citation whose path does not resolve AT ALL is a failure, not a skip.
CITE_MJS="$TEMP_PROJECT/citations.mjs"
cat > "$CITE_MJS" <<'MJS'
import { readFileSync, existsSync, statSync } from "node:fs";
import path from "node:path";
const [, , repoRoot, ...files] = process.argv;
const RE = /(?<![A-Za-z0-9_@/.-])((?:[A-Za-z0-9_.-]+\/)*[A-Za-z0-9_.-]+\.(?:md|mjs|sh|json|ts|js|yml)):(\d+)\b/g;
const bad = [];
let total = 0;
for (const f of files) {
  let src; try { src = readFileSync(f, "utf8"); } catch { continue; }
  for (const m of src.matchAll(RE)) {
    const [, p, nStr] = m;
    const n = Number(nStr);
    total++;
    const abs = path.resolve(repoRoot, p);
    if (!existsSync(abs) || !statSync(abs).isFile()) { bad.push(`${path.basename(f)}: ${p}:${n} -> PATH DOES NOT RESOLVE from the repo root`); continue; }
    const lines = readFileSync(abs, "utf8").split("\n").length;
    if (n < 1 || n > lines) bad.push(`${path.basename(f)}: ${p}:${n} -> the file has only ${lines} lines`);
  }
}
process.stdout.write(JSON.stringify({ total, bad }));
MJS

SHIPPED=("${TEN_FILES[@]}" "$PLUGIN_README" "$ROOT_README")
GATE_FILE="$(gate_resolved_command "$GATE_PLUGIN_DIR" | awk '{print $1}')"
[[ -n "$GATE_FILE" && -f "$GATE_FILE" ]] && SHIPPED+=("$GATE_FILE")
CITE_JSON="$("$GATE_REAL_NODE" "$CITE_MJS" "$GATE_REPO_ROOT" "${SHIPPED[@]}" 2>/dev/null)"
CITE_TOTAL="$("$GATE_REAL_NODE" -e 'process.stdout.write(String(JSON.parse(process.argv[1]).total))' "$CITE_JSON")"
CITE_BAD="$("$GATE_REAL_NODE" -e 'process.stdout.write(JSON.parse(process.argv[1]).bad.join(" | "))' "$CITE_JSON")"
record "AC33: $CITE_TOTAL <path>:<n> citation(s) scanned across the shipped artifacts and comments"
assert_eq "VACUITY: the citation scanner found a non-empty population (an empty scan proves nothing)" \
  "$([[ "${CITE_TOTAL:-0}" -ge 5 ]] && echo enough || echo "ONLY ${CITE_TOTAL:-0} citations found -- the scanner is broken, not the artifacts")" "enough"
assert_eq "AC33: every citation in the SHIPPED artifacts opens (path resolves from the repo root, line exists)" \
  "$CITE_BAD" ""

# NON-ZERO CONTROL: the scanner must reject both failure shapes the criterion names -- the bare
# `README.md:84` form against a 39-line root README, and a path missing its plugins/pipeline
# prefix. Planted in a scratch file, never in the tree.
PLANT="$TEMP_PROJECT/planted-citations.md"
printf 'see README.md:84 and commands/pipeline.md:812 for the rule\n' > "$PLANT"
PLANT_JSON="$("$GATE_REAL_NODE" "$CITE_MJS" "$GATE_REPO_ROOT" "$PLANT" 2>/dev/null)"
PLANT_BAD="$("$GATE_REAL_NODE" -e 'process.stdout.write(String(JSON.parse(process.argv[1]).bad.length))' "$PLANT_JSON")"
assert_eq "NON-ZERO CONTROL: the scanner rejects BOTH planted shapes -- the bare 'README.md:84' and the prefix-less 'commands/pipeline.md:812'" \
  "$PLANT_BAD" "2"

# AND THE SPEC ITSELF, which AC33 names explicitly. Reported separately from the shipped artifacts
# so a spec-side citation defect is not mistaken for a code-side one; it is still an assertion,
# because "a citation whose path does not resolve at all is a failure, not a skip".
SPEC_JSON_FILE="$GATE_REPO_ROOT/.pipeline/106/spec.json"
if [[ -f "$SPEC_JSON_FILE" ]]; then
  SPEC_CITE="$("$GATE_REAL_NODE" "$CITE_MJS" "$GATE_REPO_ROOT" "$SPEC_JSON_FILE" 2>/dev/null)"
  SPEC_BAD="$("$GATE_REAL_NODE" -e 'const b=JSON.parse(process.argv[1]).bad; process.stdout.write(b.length+" bad: "+b.slice(0,8).join(" | "))' "$SPEC_CITE")"
  record "AC33 SPEC SCAN: $SPEC_BAD"
  assert_eq "AC33: every <path>:<n> citation in .pipeline/106/spec.json also opens" \
    "$("$GATE_REAL_NODE" -e 'process.stdout.write(JSON.parse(process.argv[1]).bad.join(" | "))' "$SPEC_CITE")" ""
else
  assert_eq "AC33: the spec is present to scan -- reported as a FAILURE, never a skip" "spec.json missing" "present"
fi

finish
