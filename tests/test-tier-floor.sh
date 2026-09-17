#!/usr/bin/env bash
# tier-floor.mjs (#164 row 7): the architectural floor from the spec, the built-in triggers and
# the architecturalTriggers union, computed instead of reasoned through. Also the diff half
# (#76): a changed path that matches a path trigger.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

TF="$SCRIPTS_DIR/tier-floor.mjs"
make_temp_project 5 || exit 90
P="$TEMP_PROJECT"

spec() { # <risk_tier> <domains-json> <extra-json-fields>
  printf '{"issue_number":5,"title":"t","problem":"p","risk_tier":"%s","impacted_domains":%s,"requirements":["r"],"acceptance_criteria":["a"]%s}' \
    "$1" "$2" "${3:-}" > "$P/spec.json"
}
cfg() { printf '%s' "$1" > "$P/pipeline.config.json"; }
floor() { # <args...> -> RC OUT
  OUT="$( cd "$P" && CLAUDE_PROJECT_DIR="$P" node "$TF" --spec "$P/spec.json" "$@" 2>&1 )"
  RC=$?
}

suite "tier-floor: the built-in floor with no config at all"

rm -f "$P/pipeline.config.json"
spec standard '["api"]'
floor
assert_eq "a plain standard spec is ok (exit 0)" "$RC" "0"
assert_contains "and prints no floor above trivial" "$OUT" "TIER-FLOOR: trivial"

spec standard '["compliance"]'
floor
assert_eq "the compliance domain under-tiers a standard spec (exit 2) with no config present" "$RC" "2"
assert_contains "and names the reason" "$OUT" "REASON: domain compliance is an architectural trigger"
assert_contains "and says to promote" "$OUT" "UNDER-TIERED"

spec architectural '["compliance"]'
floor
assert_eq "CONTROL: the same spec at architectural is ok" "$RC" "0"

spec standard '["api"]' ',"requirements":["change the tripwire glob in `pipeline.config.json`."]'
floor
assert_eq "a spec that names pipeline.config.json under-tiers with no config present" "$RC" "2"
assert_contains "and the path trigger is the reason" "$OUT" "matches path trigger pipeline.config.json"

spec standard '["api"]' ',"requirements":["edit plugins/pipeline/pipeline.config.example.json"]'
floor
assert_eq "CONTROL: a different file with a similar name is not the trigger" "$RC" "0"

spec trivial '["api"]' ',"impacted_packages":["pipeline.config.json"]'
floor
assert_eq "an impacted package that is the config file under-tiers a trivial spec" "$RC" "2"

suite "tier-floor: absent, malformed and wrong-typed config all mean {} (the floor still holds)"

for c in '{"architecturalTriggers": [ not json' '[]' '{"architecturalTriggers":"x"}' '{"architecturalTriggers":{"paths":"x","domains":7,"keywords":{}}}' '{"architecturalTriggers":{"domains":[null,3]}}'; do
  cfg "$c"
  spec standard '["compliance"]'
  floor
  assert_eq "config [$c]: compliance still under-tiers" "$RC" "2"
  spec standard '["api"]'
  floor
  assert_eq "config [$c]: and a plain spec is still ok" "$RC" "0"
done

suite "tier-floor: config UNIONS onto the floor, never replaces it"

cfg '{"architecturalTriggers":{"paths":["infra/**"],"domains":["security"],"keywords":["ledger"]}}'
spec standard '["security"]'
floor
assert_eq "a config domain under-tiers" "$RC" "2"
spec standard '["api"]' ',"impacted_packages":["infra/terraform/main.tf"]'
floor
assert_eq "a config path glob under-tiers" "$RC" "2"
spec standard '["compliance"]'
floor
assert_eq "the built-in domain survives a config that lists other domains" "$RC" "2"
spec standard '["api"]' ',"requirements":["touch pipeline.config.json"]'
floor
assert_eq "the built-in path survives a config that lists other paths" "$RC" "2"

suite "tier-floor: keywords are an ADVISORY signal, never a trigger"

spec standard '["api"]' ',"problem":"the ledger total drifts"'
floor
assert_eq "a keyword match alone does not under-tier (exit 0)" "$RC" "0"
assert_contains "but is reported" "$OUT" 'ADVISORY: keyword "ledger" appears in the spec'
spec standard '["api"]' ',"problem":"the header drifts"'
floor
assert_not_contains "CONTROL: no keyword, no advisory line" "$OUT" "ADVISORY"

suite "tier-floor: a diff touching pipeline.config.json (#76)"

rm -f "$P/pipeline.config.json"
spec standard '["api"]'
floor --changed src/app.ts --changed pipeline.config.json
assert_eq "a changed pipeline.config.json under-tiers a standard spec" "$RC" "2"
assert_contains "and names the diff" "$OUT" "the diff touches pipeline.config.json"
floor --changed src/app.ts --changed docs/pipeline.config.json.md
assert_eq "CONTROL: a diff without it is ok" "$RC" "0"
floor --changed './pipeline.config.json'
assert_eq "a ./-prefixed spelling still matches" "$RC" "2"

suite "tier-floor: an unreadable spec is not a pass"

printf 'not json' > "$P/spec.json"
floor
assert_eq "an unparseable spec exits 1" "$RC" "1"

suite "tier-floor: the prose it replaced stays removed, and the config doctor names a reader"

assert_eq "ba.md no longer tells BA to union each sub-key by hand" \
  "$(grep -c 'UNION each sub-key' "$PLUGIN_ROOT/agents/ba.md" | tr -d ' ')" "0"
assert_eq "ba.md calls tier-floor.mjs" "$(grep -c 'scripts/tier-floor.mjs' "$PLUGIN_ROOT/agents/ba.md" | tr -d ' ')" "1"
assert_eq "pipeline.md no longer says no predicate evaluates a diff for this rule" \
  "$(grep -c 'No path predicate evaluates a diff' "$PLUGIN_ROOT/commands/pipeline.md" | tr -d ' ')" "0"
assert_eq "pipeline.md calls tier-floor.mjs" "$(grep -c 'scripts/tier-floor.mjs' "$PLUGIN_ROOT/commands/pipeline.md" | tr -d ' ')" "1"
assert_eq "no agent says a script awaits #76 any more" \
  "$(grep -l 'mechanical seat this awaits' "$PLUGIN_ROOT"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')" "0"
READER="$(DOC="$SCRIPTS_DIR/config-doctor.mjs" node -e 'import(process.env.DOC).then(m=>console.log(m.ALL_KEYS.architecturalTriggers.reader))')"
assert_contains "config-doctor names tier-floor.mjs as the reader of architecturalTriggers" "$READER" "scripts/tier-floor.mjs"
assert_not_contains "and no longer says no script reads it" "$READER" "no script reads it"
printf 'UNION each sub-key\n' > "$P/probe.md"
assert_eq "CONTROL: the absence grep finds a planted copy" "$(grep -c 'UNION each sub-key' "$P/probe.md" | tr -d ' ')" "1"

finish
