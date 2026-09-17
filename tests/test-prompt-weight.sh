#!/usr/bin/env bash
# prompt-weight.mjs (C2): the measurement behind the TOON and prompt-cache changes. Pins that it
# runs on a fixture issue, labels its token figures as an estimate, reports the cacheable static
# prefix the renderer actually produces, compares JSON with TOON on the fixture's uniform arrays,
# and never writes into the fixture.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

PW="$SCRIPTS_DIR/prompt-weight.mjs"
RENDER="$SCRIPTS_DIR/render-panel.mjs"
PLUGIN_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
make_temp_project || exit 90
FX="$TEMP_PROJECT/fixture"
mkdir -p "$FX"

cat > "$FX/status.json" <<'EOF'
{"issue_number": 4242, "risk_tier": "money", "panel_roles": ["qa", "secops", "ledger"], "head": "abcdef1"}
EOF
cat > "$FX/spec.json" <<'EOF'
{"issue_number": 4242, "acceptance_criteria": [
  {"id": "AC1", "text": "the merge refuses an unrated blocker", "test": "tests/a.sh"},
  {"id": "AC2", "text": "a note ships", "test": "tests/b.sh"},
  {"id": "AC3", "text": "the budget counts rounds", "test": "tests/c.sh"}]}
EOF
cat > "$FX/peer-review.qa.json" <<'EOF'
{"verdict": "REQUEST_CHANGES", "concerns": [
  {"id": "qa-1", "severity": "blocker", "likelihood": "normal-use", "harm": "internal", "merge_class": "wrong-pass", "location": "x.mjs:1", "description": "d"}],
 "materiality": {"open_blocker_ids": ["qa-1"], "blocks_merge": true}}
EOF
BEFORE="$(cd "$FX" && cat -- * | cksum)"

suite "prompt-weight: runs on a fixture and labels its estimate"

OUT_TXT="$(node "$PW" --fixture "$FX" 2>&1)"
assert_eq "text report exits 0" "$?" "0"
assert_contains "the token figures are labelled an estimate" "$OUT_TXT" "an estimate, not a tokenizer count"
assert_contains "a consumer tier is named, not silently mapped" "$OUT_TXT" 'risk_tier "money" is not a plugin tier'
assert_contains "a consumer role with no plugin lens is named" "$OUT_TXT" "skipped: ledger"
assert_contains "every agent definition is weighed" "$OUT_TXT" "agents/secops.md"
assert_contains "pipeline.md is split per phase section" "$OUT_TXT" "Phase 4: Peer Review Panel"

J="$(node "$PW" --fixture "$FX" --json)"
FIG="$(J="$J" MOD="$RENDER" ROOT="$PLUGIN_ROOT" node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(process.env.J);
const m = await import(process.env.MOD);
const pre = m.extractPreamble(readFileSync(process.env.ROOT + "/commands/pipeline.md", "utf8")) + "\n\n" + m.RUN_DATA_NOTE + "\n\n";
const ac = r.artifacts.tables.find((t) => t.file === "spec.json" && t.path === "$.acceptance_criteria");
const qaDelta = r.panel.delta.dispatches.find((d) => d.role === "qa");
console.log([
  "static=" + (r.panel.full.static_preamble.bytes === Buffer.byteLength(pre)),
  "est=" + (r.panel.full.static_preamble.est_tokens === Math.ceil(pre.length / 4)),
  "table_found=" + Boolean(ac),
  "toon_smaller=" + Boolean(ac && ac.toon_bytes < ac.json_bytes),
  "delta_qa=" + Boolean(qaDelta),
  "prefix_dominates=" + r.panel.full.dispatches.every((d) => d.static_prefix.bytes > d.run_data.bytes),
].join(" "));
')"
for k in static=true est=true table_found=true toon_smaller=true delta_qa=true prefix_dominates=true; do
  assert_contains "json report: $k" "$FIG" "$k"
done
assert_eq "the fixture is not modified" "$(cd "$FX" && cat -- * | cksum)" "$BEFORE"

node "$PW" --fixture "$TEMP_PROJECT/missing" >/dev/null 2>&1
assert_eq "a missing fixture exits non-zero" "$?" "1"

finish
