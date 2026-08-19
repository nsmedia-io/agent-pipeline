#!/usr/bin/env bash
# The SITE discriminator on the dispatch routing table, and the seventh pin site. Issue #17.
#
# WHY THIS FILE EXISTS SEPARATELY FROM test-dispatch-model-resolver.sh
# -------------------------------------------------------------------
# AC18 requires the resolver to reproduce today's model at all seven pin sites, and two of
# them COLLIDE on one key: the Phase 2.5 design sketches (commands/pipeline.md, pinned sonnet)
# and the Phase 2.5 bake-off judge (pinned opus) are BOTH dispatched with
# subagent_type "dev" in phase 2.5. A resolver keyed on (role, risk_tier, phase) cannot return
# two values for (dev, architectural, 2.5). QA asserted the other five pairs and deliberately
# left that pair untested rather than pick a resolution.
#
# The resolution implemented, and the reason it is forced rather than chosen: the spec's own
# non-negotiable is BEHAVIOUR-NEUTRALITY, and both dispatches must keep the model they carry
# today, so the key must carry a fourth dimension. `--site` is that dimension. Changing either
# site's model to dissolve the collision would break the property the table exists to
# preserve, so it is not an available option.
#
# Every assertion below is about that fourth dimension and about the sites being WIRED, which
# is the half a resolver test cannot see: a correct table nobody calls is the same defect as a
# wrong one.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"
RESOLVER="$SCRIPTS_DIR/dispatch-model.mjs"
NOCFG="$TEMP_PROJECT/nocfg"
mkdir -p "$NOCFG"

r() { ( cd "$NOCFG" && CLAUDE_PROJECT_DIR="$NOCFG" node "$RESOLVER" "$@" 2>/dev/null ); }
r_rc() { ( cd "$NOCFG" && CLAUDE_PROJECT_DIR="$NOCFG" node "$RESOLVER" "$@" >/dev/null 2>&1 ); printf '%s' "$?"; }
r_err() { ( cd "$NOCFG" && CLAUDE_PROJECT_DIR="$NOCFG" node "$RESOLVER" "$@" 2>&1 1>/dev/null ); }

suite "AC18: the (dev, 2.5) collision, resolved by a site discriminator rather than by moving a model"

assert_eq "the design sketches still resolve to sonnet"  "$(r dev architectural 2.5 --site design-sketch)" "sonnet"
assert_eq "the bake-off judge still resolves to opus"    "$(r dev architectural 2.5 --site bakeoff-judge)" "opus"
# The whole point: ONE (role, tier, phase) key, TWO answers. Asserted as a difference, because
# two separate equality assertions both pass against a table that returns one value for both
# if the fixtures happen to expect the same one.
assert_eq "the two sites at the SAME (role, tier, phase) return DIFFERENT models" \
  "$([[ "$(r dev architectural 2.5 --site design-sketch)" != "$(r dev architectural 2.5 --site bakeoff-judge)" ]] && echo different || echo same)" \
  "different"
assert_eq "both are usable values, so 'different' is not two error strings" \
  "$(r dev architectural 2.5 --site design-sketch)/$(r dev architectural 2.5 --site bakeoff-judge)" \
  "sonnet/opus"

suite "AC18: a multi-site row without a --site is answered AND reported, never silently guessed"

assert_eq "it resolves to the sketch row (the majority dispatch at that key)" "$(r dev architectural 2.5)" "sonnet"
assert_eq "and exits 0: a missing site is not a caller bug, it is an underspecified call" \
  "$(r_rc dev architectural 2.5)" "0"
assert_contains "and it SAYS the key carries more than one site" "$(r_err dev architectural 2.5)" "dispatch sites"
assert_contains "naming both of them" "$(r_err dev architectural 2.5)" "bakeoff-judge"
# NON-ZERO CONTROL: a single-site row must NOT emit that report, or the warning is noise that
# fires everywhere and tells a reader nothing.
assert_not_contains "CONTROL: a single-site row reports no ambiguity" "$(r_err ba architectural 4)" "dispatch sites"

suite "AC18: an unknown site falls back to the row's default and says so, rather than resolving to nothing"

assert_eq "an unrecognized site still returns the default row's model" "$(r dev architectural 2.5 --site typo-site)" "sonnet"
assert_contains "and names the site it did not recognize" "$(r_err dev architectural 2.5 --site typo-site)" "typo-site"

suite "AC19: all seven pin sites defer to the table, and the two Phase 2.5 sites pass their --site"

# The sites are asserted in the FILE the orchestrator executes, not in a restatement: a table
# that is correct and uncalled is the eighth source of truth this change exists to remove.
assert_eq "the Phase 0.5 map dispatch calls the resolver" \
  "$(grep -c 'dispatch-model.mjs" ba <risk_tier> 0.5 --site map' "$PIPELINE_MD" | tr -d ' ')" "1"
assert_eq "the design-sketch dispatch calls it with --site design-sketch" \
  "$(grep -c 'dispatch-model.mjs" dev <risk_tier> 2.5 --site design-sketch' "$PIPELINE_MD" | tr -d ' ')" "1"
assert_eq "the bake-off judge calls it with --site bakeoff-judge" \
  "$(grep -c 'dispatch-model.mjs" dev <risk_tier> 2.5 --site bakeoff-judge' "$PIPELINE_MD" | tr -d ' ')" "1"
assert_eq "the BA Phase 4 lens defers to the table" \
  "$(grep -c 'dispatch-model.mjs ba <risk_tier> 4 --site panel-lens' "$PIPELINE_MD" | tr -d ' ')" "1"
assert_eq "the Dev Phase 4 lens defers to the table" \
  "$(grep -c 'dispatch-model.mjs dev <risk_tier> 4 --site panel-lens' "$PIPELINE_MD" | tr -d ' ')" "1"
assert_eq "the prose restatement is gone: no sentence still assigns the lens models by hand" \
  "$(grep -c 'The BA and Dev lenses are pinned to' "$PIPELINE_MD" | tr -d ' ')" "0"
assert_eq "and README no longer restates the assignments either" \
  "$(grep -c 'sonnet` for the map, the sketches' "$PLUGIN_DIR/README.md" | tr -d ' ')" "0"
assert_eq "while README does point at the table (config table row + the aliases bullet)" \
  "$(grep -c 'scripts/dispatch-model.mjs' "$PLUGIN_DIR/README.md" | tr -d ' ')" "2"

# NON-ZERO CONTROL for every grep above: the same invocation against a file that deliberately
# carries the string, so a zero from a mistyped pattern cannot read as a satisfied criterion.
PROBE="$TEMP_PROJECT/site-probe.md"
printf '%s\n' 'node "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-model.mjs" dev <risk_tier> 2.5 --site bakeoff-judge' > "$PROBE"
assert_eq "CONTROL: the same grep DOES find a byte-identical call" \
  "$(grep -c 'dispatch-model.mjs" dev <risk_tier> 2.5 --site bakeoff-judge' "$PROBE" | tr -d ' ')" "1"

suite "AC13-adjacent: the emission rule is stated where the dispatch sites can read it"

assert_contains "the file states the exit-0-and-one-token conjunction" \
  "$(cat "$PIPELINE_MD")" "ONLY IF \`MODEL_RC\` is 0 AND \`\$MODEL\` is exactly one token"
assert_contains "and names the OPPOSITE fail direction so the two consumers are not unified" \
  "$(cat "$PIPELINE_MD")" "OPPOSITE fail direction from the mis-tier tripwire"

finish
