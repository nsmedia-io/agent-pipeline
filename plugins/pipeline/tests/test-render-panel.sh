#!/usr/bin/env bash
# render-panel.mjs (#157): the Phase 4 panel Workflow script is RENDERED from status.json, never
# hand-written. The properties pinned here are the ones a hand-written script got wrong on real
# runs: the reviewed sha is read from git (a typed sha once diverged after nine characters), the
# script parses (an apostrophe inside a single-quoted lens once cost a retry), the roles are
# exactly panel_roles (or exactly the delta subset), and model/effort come from the resolvers.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

RENDER="$SCRIPTS_DIR/render-panel.mjs"
PLUGIN_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

make_temp_project || exit 90

# A scratch git worktree with one commit, so `git rev-parse HEAD` has something to read.
WT="$TEMP_PROJECT/wt"
mkdir -p "$WT"
( cd "$WT" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'x\n' > f && git add f && git commit -q -m init ) || exit 91
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"

STATUS="$TEMP_PROJECT/status.json"
write_status() {
  # write_status <tier> <panel_roles-json>
  cat > "$STATUS" <<EOF
{"issue_number": 77, "current_phase": "4-review", "risk_tier": "$1", "panel_roles": $2,
 "pr_url": "https://example.invalid/pull/1", "started_at": "2026-01-01T00:00:00Z",
 "updated_at": "2026-01-01T00:00:00Z", "events": [], "flags": []}
EOF
}

# render <args...> -> RC, OUT, ERR
render() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$TEMP_PROJECT" && node "$RENDER" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

count_agents() { printf '%s' "$1" | grep -c "() => agent(PREAMBLE + "; }

suite "render-panel: a standard four-role panel renders, parses, and carries the git HEAD"

write_status standard '["ba","dev","qa","secops"]'
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --check
assert_eq "renders and passes --check" "$RC" "0"
assert_contains "the reviewed sha in the script is git rev-parse HEAD of the worktree" "$OUT" "$HEAD_SHA"
assert_contains "the preamble names the worktree's artifact dir" "$OUT" "$WT/.pipeline/77"
assert_contains "the plugin root is substituted for \${CLAUDE_PLUGIN_ROOT}" "$OUT" "$PLUGIN_ROOT/evidence.md"
assert_not_contains "no raw \${CLAUDE_PLUGIN_ROOT} placeholder survives" "$OUT" 'CLAUDE_PLUGIN_ROOT}'
assert_not_contains "no raw <ARTIFACT_DIR> placeholder survives" "$OUT" '<ARTIFACT_DIR>'
assert_not_contains "no raw <issue> placeholder survives" "$OUT" '<issue>'
assert_eq "exactly four agent() calls for four roles" "$(count_agents "$OUT")" "4"
assert_contains "meta is a pure literal naming the issue" "$OUT" 'export const meta = { name: "phase4-panel-77"'
assert_contains "ba is dispatched as pipeline:ba" "$OUT" '"agentType":"pipeline:ba"'
assert_contains "secops is dispatched as pipeline:secops" "$OUT" '"agentType":"pipeline:secops"'
assert_contains "every call carries an effort (workflow surface always emits one)" "$OUT" '"effort":"'
assert_contains "the ba lens resolves to sonnet at standard (dispatch-model table)" "$OUT" '"agentType":"pipeline:ba","model":"sonnet"'
assert_not_contains "secops carries NO model key (pinned in code, frontmatter governs)" "$OUT" '"agentType":"pipeline:secops","model"'
assert_contains "the qa lens text is present" "$OUT" 'binding independent test verdict'

suite "render-panel: an architectural six-role panel"

write_status architectural '["ba","dba","devops","secops","dev","qa"]'
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --check
assert_eq "renders and passes --check" "$RC" "0"
assert_eq "exactly six agent() calls" "$(count_agents "$OUT")" "6"
assert_contains "secops effort is xhigh at architectural" "$OUT" '"agentType":"pipeline:secops","effort":"xhigh"'
assert_contains "dba is dispatched as pipeline:dba" "$OUT" '"agentType":"pipeline:dba"'

suite "render-panel: a delta round renders only the delta roles and names the first-round head"

FIRST="0123456789abcdef0123456789abcdef01234567"
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --delta "qa dba" --first-round-head "$FIRST" --check
assert_eq "delta render passes --check" "$RC" "0"
assert_eq "exactly two agent() calls for two delta roles" "$(count_agents "$OUT")" "2"
assert_contains "the delta paragraph names the first-round head" "$OUT" "The first round reviewed $FIRST"
assert_contains "the delta paragraph names the fix diff" "$OUT" "git diff $FIRST...HEAD"
assert_contains "the delta paragraph carries the introduced-defect stance" "$OUT" "assume the remediation introduced a defect"
assert_contains "meta names the delta" "$OUT" 'name: "phase4-delta-77"'
assert_not_contains "ba is NOT rendered on a qa+dba delta" "$OUT" '"agentType":"pipeline:ba"'

suite "render-panel: surface-conditional roles render when seated"

write_status standard '["ba","dev","qa","secops","design_review","art_director"]'
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --check
assert_eq "renders with design_review and art_director" "$RC" "0"
assert_contains "design_review dispatches pipeline:design" "$OUT" '"agentType":"pipeline:design"'
assert_contains "art_director dispatches pipeline:art-director" "$OUT" '"agentType":"pipeline:art-director"'

suite "render-panel: FAILS CLOSED on every input it owns"

render --status "$STATUS" --worktree "$TEMP_PROJECT/no-such-worktree" --plugin-root "$PLUGIN_ROOT"
assert_eq "an unreadable worktree HEAD exits non-zero" "$RC" "2"
assert_contains "the failure names the HEAD read" "$ERR" "cannot read HEAD"

write_status standard '["ba","wizard"]'
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT"
assert_eq "an unknown role exits non-zero" "$RC" "2"
assert_contains "the failure names the role" "$ERR" 'role "wizard" has no entry'

write_status standard '[]'
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT"
assert_eq "an empty panel_roles exits non-zero" "$RC" "2"

cat > "$STATUS" <<'EOF'
{"issue_number": 77, "current_phase": "4-review", "panel_roles": ["ba"], "events": [], "flags": []}
EOF
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT"
assert_eq "a record with no risk_tier exits non-zero (the panel cannot be routed)" "$RC" "2"

write_status standard '["ba"]'
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --delta "qa"
assert_eq "--delta without --first-round-head exits non-zero" "$RC" "1"

# A plugin root whose command file lost its markers must refuse rather than render an empty preamble.
FAKE_ROOT="$TEMP_PROJECT/fake-root"
mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/commands"
cp "$PLUGIN_ROOT/scripts/panel-lenses.json" "$FAKE_ROOT/scripts/"
printf '# no markers here\n' > "$FAKE_ROOT/commands/pipeline.md"
render --status "$STATUS" --worktree "$WT" --plugin-root "$FAKE_ROOT"
assert_eq "a command file without the PHASE4-PREAMBLE markers exits non-zero" "$RC" "2"
assert_contains "the failure names the markers" "$ERR" "PHASE4-PREAMBLE"

suite "render-panel: --check catches a script that would not parse"

# Drive the checker directly with a deliberately broken script through the module API.
CHK="$TEMP_PROJECT/chk.mjs"
cat > "$CHK" <<'EOF'
const m = await import(process.env.MOD);
const r = m.checkScript("const x = 'unterminated\nreturn { returns: [] }");
console.log(r.ok ? "ok" : "broken");
const g = m.checkScript('export const meta = { name: "n", description: "d", phases: [{ title: "P" }] }\nphase("P")\nconst results = await parallel([])\nreturn { returns: results }\n');
console.log(g.ok ? "ok" : "broken");
EOF
CHK_OUT="$(MOD="$RENDER" node "$CHK" 2>/dev/null)"
assert_eq "a broken script is reported broken and a good one ok" "$(printf '%s' "$CHK_OUT" | tr '\n' ' ')" "broken ok"

suite "render-panel: the lens table and the command file agree on the role set"

# Every role the command file's panel composition can seat has a lens, and every lens names a
# shipped agentType; a role added to one and not the other renders nothing or dispatches nothing.
LENS_ROLES="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(j.roles).sort().join(" "))' "$PLUGIN_ROOT/scripts/panel-lenses.json")"
assert_eq "the lens table carries the eight panel roles" "$LENS_ROLES" "art_director ba dba design_review dev devops qa secops"
for a in ba dba devops secops dev qa design art-director; do
  assert_eq "agent file exists for lens agentType pipeline:$a" "$(test -f "$PLUGIN_ROOT/agents/$a.md" && echo yes || echo no)" "yes"
done

finish
