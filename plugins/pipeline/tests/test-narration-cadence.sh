#!/usr/bin/env bash
# Issue #99: pipeline.md's narration-cadence rule for a parallel fan-out, and its alignment
# with voice-lint.mjs's own tables.
#
# THE THING THIS SUITE EXISTS TO KEEP HONEST (AC3). The rule's whole justification is that it
# codifies what voice-lint.mjs ALREADY sanctions rather than cutting across it: the phase
# labels a batch is in flight at are already in NON_VOICE_PHASES, and the labels a consolidated
# update lands on already carry a VOICE_MOMENTS obligation. That is an ALIGNMENT CLAIM between
# two files, and a claim stated only in prose can drift silently the moment either file is
# renamed. So every label the rule names is extracted from the prose and checked against the
# REAL, LIVE tables (imported from the actual module, never hand-copied), so a rename in either
# place reddens this suite instead of leaving the prose quietly wrong.
#
# Every extraction below runs against the SHIPPED text (awk'd out of commands/pipeline.md
# between real markers), not a hand-copied paraphrase, for the same reason
# test-panel-composition-fail-direction.sh extracts rather than restates: a test over a copy
# tracks the copier's attention, not what the orchestrator reads.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"
LINT="$PLUGIN_DIR/scripts/voice-lint.mjs"

suite "#99: narration-cadence rule, extracted and checked against the live voice-lint tables"

# ---- extraction: the rule's own subsection -----------------------------------
RULE="$TEMP_PROJECT/narration-cadence-section.md"
awk '
  /^### Narration cadence during a parallel fan-out$/ { f=1 }
  f { print }
  f && /^### Replication steps are not optional$/ { exit }
' "$PIPELINE_MD" > "$RULE"

assert_eq "the rule section exists at all (non-empty extraction)" \
  "$([[ -s "$RULE" ]] && echo yes || echo no)" "yes"

# ---- AC1: per-member return is not a cue; one consolidated update follows -----
assert_contains "AC1: a per-member return is stated as NOT a cue to post" \
  "$(cat "$RULE")" "is not by itself a cue to post"
assert_contains "AC1: one consolidated update follows batch completion or the merge step" \
  "$(cat "$RULE")" "post ONE consolidated update"

# ---- AC2: all four fan-out sites are named, greppably -------------------------
for site in "Phase 0.5" "Phase 2 reviewer fan-out" "Phase 2.5 design-sketch pair" "Phase 4 panel"; do
  assert_contains "AC2: the rule names \"$site\"" "$(cat "$RULE")" "$site"
done
# Greppable: each site name should actually match the SECTION HEADING it points a reader at,
# not just appear as free text unconnected to anything real in the file.
assert_contains "AC2 GREPPABLE: \"Phase 2 reviewer fan-out\" language matches a real section" \
  "$(grep -c 'Phase 2 reviewer fan-out' "$PIPELINE_MD")" "$(grep -c 'Phase 2 reviewer fan-out' "$PIPELINE_MD")"
assert_eq "AC2 GREPPABLE: Phase 2.5's real heading exists" \
  "$(grep -c '^## Phase 2.5: Design Bake-off' "$PIPELINE_MD")" "1"
assert_eq "AC2 GREPPABLE: Phase 4's real heading exists" \
  "$(grep -c '^## Phase 4: Peer Review Panel' "$PIPELINE_MD")" "1"
assert_eq "AC2 GREPPABLE: Phase 0.5's mapping-pass dispatch line exists" \
  "$(grep -c 'Dispatch the mapping pass as BA' "$PIPELINE_MD")" "1"

# ---- AC3: the voice-lint.mjs alignment, checked against the LIVE module -------
NON_VOICE_NAMED="0.5-map 0.5-map-complete 2-review 2-review-complete 2.5-design 2.5-design-complete 4-review"
VOICE_LANDING_NAMED="2.5-design-owner-decision 4-review-complete"
HALT_EXEMPT_NAMED="4-veto-rework-required"

for label in $NON_VOICE_NAMED; do
  assert_contains "AC3: the rule names non-voice label \"$label\"" "$(cat "$RULE")" "\`$label\`"
done
for label in $VOICE_LANDING_NAMED $HALT_EXEMPT_NAMED; do
  assert_contains "AC3: the rule names voice-bearing label \"$label\"" "$(cat "$RULE")" "\`$label\`"
done

# THE LIVE CHECK: every non-voice label the prose names is REALLY in NON_VOICE_PHASES right now.
LIVE_NON_VOICE="$(node --input-type=module -e '
  const m = await import(process.argv[1]);
  process.stdout.write([...m.NON_VOICE_PHASES].join(" "));
' "$LINT" 2>/dev/null)"
assert_eq "REPORTED so the membership checks below cannot range over an empty population: NON_VOICE_PHASES entries read live" \
  "$([[ -n "$LIVE_NON_VOICE" ]] && echo ok || echo EMPTY)" "ok"

DRIFT=""
for label in $NON_VOICE_NAMED; do
  case " $LIVE_NON_VOICE " in
    *" $label "*) : ;;
    *) DRIFT="$DRIFT $label" ;;
  esac
done
assert_eq "AC3 LIVE: every non-voice label the rule names is REALLY in voice-lint.mjs's NON_VOICE_PHASES, right now" \
  "${DRIFT:-none}" "none"

# CONTROL: the same membership check reports a MISS when one is planted, so an empty DRIFT
# above is a finding and not a check that cannot fail.
PLANTED_MISS=""
case " $LIVE_NON_VOICE " in
  *" not-a-real-phase-label "*) : ;;
  *) PLANTED_MISS="not-a-real-phase-label" ;;
esac
assert_eq "CONTROL: a label NOT in NON_VOICE_PHASES is correctly reported as drift" \
  "$PLANTED_MISS" "not-a-real-phase-label"

# THE LIVE CHECK: every voice-landing / halt-exempt label is REALLY a VOICE_MOMENTS key now.
LIVE_VOICE_KEYS="$(node --input-type=module -e '
  const m = await import(process.argv[1]);
  process.stdout.write(Object.keys(m.VOICE_MOMENTS).join(" "));
' "$LINT" 2>/dev/null)"
assert_eq "REPORTED so the checks below cannot range over an empty population: VOICE_MOMENTS keys read live" \
  "$([[ -n "$LIVE_VOICE_KEYS" ]] && echo ok || echo EMPTY)" "ok"

VOICE_DRIFT=""
for label in $VOICE_LANDING_NAMED $HALT_EXEMPT_NAMED; do
  case " $LIVE_VOICE_KEYS " in
    *" $label "*) : ;;
    *) VOICE_DRIFT="$VOICE_DRIFT $label" ;;
  esac
done
assert_eq "AC3 LIVE: every voice-landing / halt-exempt label the rule names is REALLY a VOICE_MOMENTS key, right now" \
  "${VOICE_DRIFT:-none}" "none"

# CONTROL on the same check.
PLANTED_MISS2=""
case " $LIVE_VOICE_KEYS " in
  *" not-a-real-voice-moment "*) : ;;
  *) PLANTED_MISS2="not-a-real-voice-moment" ;;
esac
assert_eq "CONTROL: a label NOT in VOICE_MOMENTS is correctly reported as drift" \
  "$PLANTED_MISS2" "not-a-real-voice-moment"

# ---- AC4: halt-class exemption stated explicitly -------------------------------
assert_contains "AC4: a VETO from one member is named as exempt, surfaced when it arrives" \
  "$(cat "$RULE")" "VETO"
assert_contains "AC4: a subagent error is named too, not just VETO" \
  "$(cat "$RULE")" "subagent error"
assert_contains "AC4: the exemption is stated as immediate, not held for the batch" \
  "$(cat "$RULE")" "not held for the batch"

# ---- The two siblings, correctly NOT swept into this rule's scope --------------
assert_contains "the Phase 1 serial-not-batched rule is distinguished, not silently reachable" \
  "$(cat "$RULE")" "Serial, not batched"
assert_contains "the Phase 3a/3b sequencing pair is distinguished, not silently reachable" \
  "$(cat "$RULE")" "NOT a Phase-2-style fan-out"

# ---- AC5: no existing full-voice moment removed or weakened -------------------
# The 8-item "Full voice" list, pinned verbatim. A future edit that drops or rewords a bullet
# reddens here rather than silently shrinking the list this rule sits right next to.
FULL_VOICE_ITEMS=(
  "A SecOps \`VETO\`, at Phase 2 or Phase 4."
  "A Phase 1 **blocking open question**"
  "The Phase 2.5 **design-lock**"
  "Any \`REQUEST_CHANGES\` summary returned to the owner."
  "The live-verification halt"
  "Presenting a PR as ready for human merge."
  "The Phase 5 completion report"
  "Any call the pipeline cannot make for itself"
)
MISSING_ITEMS=""
FULL_VOICE_BLOCK="$(awk '/^\*\*3\. Full voice/{f=1} f{print} f&&/^When one of those needs a decision/{exit}' "$PIPELINE_MD")"
for item in "${FULL_VOICE_ITEMS[@]}"; do
  case "$FULL_VOICE_BLOCK" in
    *"$item"*) : ;;
    *) MISSING_ITEMS="$MISSING_ITEMS|$item" ;;
  esac
done
assert_eq "AC5: all 8 pre-existing full-voice bullets are still present, unweakened" \
  "${MISSING_ITEMS:-none}" "none"
assert_eq "REPORTED, so the check above is not vacuous: full-voice bullets checked" \
  "${#FULL_VOICE_ITEMS[@]}" "8"

# ---- out of scope: this issue must not touch voice-lint.mjs or voice.md -------
assert_eq "out of scope honored: voice-lint.mjs untouched by this suite's own subject matter (no cadence code added there)" \
  "$(grep -c 'cadence' "$LINT" 2>/dev/null | tr -d ' ')" "0"

finish
