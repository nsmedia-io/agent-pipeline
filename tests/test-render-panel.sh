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
# C2: placeholders stay in the static text and are BOUND in the RUN DATA block at the end of each
# prompt, so the static part is cacheable. The values must still reach the agent.
# A path value is compared as node resolves it (forward slashes), and read out of the first prompt's
# RUN DATA with any TOON quoting removed: a Windows path renders quoted ("C:/..."), and the quotes
# are not part of the value, which is what the RUN DATA note tells the agent.
native_path() { node -e 'console.log(require("path").resolve(process.argv[1]).replace(/\\/g, "/"))' "$1"; }
run_value() {  # <name> -> the value bound to <name> in the first prompt's RUN DATA, unquoted
  OUT="$OUT" node -e '
const out = process.env.OUT;
const call = out.match(/^  \(\) => agent\(PREAMBLE \+ (".*"), \{.*\}\),$/m);
const run = call ? JSON.parse(call[1]).split("RUN DATA\n")[1] || "" : "";
const m = run.match(new RegExp("^" + process.argv[1] + ": (.*)$", "m"));
if (m) console.log(m[1].startsWith("\"") ? JSON.parse(m[1]) : m[1]);
' "$1"
}
assert_eq "RUN DATA binds the worktree's artifact dir" "$(run_value ARTIFACT_DIR)" "$(native_path "$WT")/.pipeline/77"
assert_eq "RUN DATA binds \${CLAUDE_PLUGIN_ROOT} to the plugin root" "$(run_value CLAUDE_PLUGIN_ROOT)" "$(native_path "$PLUGIN_ROOT")"
assert_contains "RUN DATA binds <REVIEWED_SHA> to the git HEAD" "$OUT" "REVIEWED_SHA: $HEAD_SHA"
assert_contains "the static preamble keeps the placeholder form" "$OUT" '${CLAUDE_PLUGIN_ROOT}/evidence.md'
assert_contains "the prompt says once that its tables are TOON" "$OUT" "Tables below are TOON: header lists the fields, one row per item"
# Every UPPER_CASE placeholder and every lowercase one that stands for a run value (<issue>) in the
# static text has a binding in every RUN DATA block. A lowercase placeholder is either such a value
# or one the agent fills itself (<role> is the role its lens names; <path>, <dest>, <parent>,
# <isolated> and <observation> are what the agent picks while it works). A lowercase name in
# neither list is reported too, so a new run value spelled in lowercase cannot slip past the
# upper-case pattern unbound. A placeholder added to the preamble or the lens table without a
# binding is caught here.
BIND_CHECK='
const out = process.env.OUT;
const plant = process.env.PLANT || "";
const AGENT_FILLED = new Set(["role", "path", "dest", "parent", "isolated", "observation"]);
const pre = JSON.parse(out.match(/^const PREAMBLE = (.*)$/m)[1]);
const calls = [...out.matchAll(/^  \(\) => agent\(PREAMBLE \+ (".*"), \{.*\}\),$/gm)].map((m) => JSON.parse(m[1]));
const bad = [];
for (const c of calls) {
  const [lens, run] = c.split("RUN DATA\n");
  const text = pre + lens + plant;
  const names = new Set([...text.matchAll(/<([A-Z][A-Z_]+)>|\$\{(CLAUDE_PLUGIN_ROOT)\}/g)].map((m) => m[1] || m[2]));
  for (const m of text.matchAll(/<([a-z][a-z_-]*)>/g)) if (!AGENT_FILLED.has(m[1])) names.add(m[1]);
  for (const n of names) if (!new RegExp("^" + n + ": ", "m").test(run)) bad.push(n);
}
console.log(calls.length === 0 ? "no calls parsed" : [...new Set(bad)].join(" ") || "none");
'
UNBOUND="$(OUT="$OUT" node -e "$BIND_CHECK")"
assert_eq "every placeholder in the static text is bound in RUN DATA" "$UNBOUND" "none"
# NON-ZERO CONTROL: a lowercase run-value placeholder with no binding is reported, and so is an
# upper-case one, so the "none" above is not a pattern that can never match.
assert_eq "NON-ZERO CONTROL: an unbound lowercase placeholder (<head_sha>) and an unbound <BASE_SHA> are reported" \
  "$(OUT="$OUT" PLANT=' <head_sha> <BASE_SHA>' node -e "$BIND_CHECK")" "BASE_SHA head_sha"
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
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --check
assert_eq "renders and passes --check" "$RC" "0"
assert_eq "exactly six agent() calls" "$(count_agents "$OUT")" "6"
assert_contains "secops effort is xhigh at architectural" "$OUT" '"agentType":"pipeline:secops","effort":"xhigh"'

suite "render-panel: cost_class tooling routes SecOps effort to medium at any tier"

cat > "$STATUS" <<EOF
{"issue_number": 77, "current_phase": "4-review", "risk_tier": "architectural", "cost_class": "tooling", "panel_roles": ["qa","secops","devops"],
 "started_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "events": [], "flags": []}
EOF
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --check
assert_eq "a tooling panel renders" "$RC" "0"
assert_contains "secops effort is medium at cost_class tooling, even at architectural" "$OUT" '"agentType":"pipeline:secops","effort":"medium"'
assert_eq "exactly three agent() calls for the tooling panel" "$(count_agents "$OUT")" "3"
cat > "$STATUS" <<EOF
{"issue_number": 77, "current_phase": "4-review", "risk_tier": "architectural", "cost_class": "cheap", "panel_roles": ["qa","secops"],
 "started_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "events": [], "flags": []}
EOF
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT"
assert_eq "an off-enum cost_class exits non-zero rather than routing on a guess" "$RC" "2"
write_status architectural '["ba","dba","devops","secops","dev","qa"]'
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --check
assert_contains "dba is dispatched as pipeline:dba" "$OUT" '"agentType":"pipeline:dba"'

suite "render-panel: a delta round renders only the delta roles and names the first-round head"

FIRST="0123456789abcdef0123456789abcdef01234567"
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --delta "qa dba" --first-round-head "$FIRST" --check
assert_eq "delta render passes --check" "$RC" "0"
assert_eq "exactly two agent() calls for two delta roles" "$(count_agents "$OUT")" "2"
assert_contains "the delta paragraph names the first-round head (a placeholder)" "$OUT" "The first round reviewed <FIRST_ROUND_HEAD>"
assert_contains "and RUN DATA binds it" "$OUT" "FIRST_ROUND_HEAD: $FIRST"
assert_contains "RUN DATA lists the delta roles inline" "$OUT" "roles[2]: qa,dba"
assert_contains "the delta paragraph names the fix diff" "$OUT" "git diff $FIRST...HEAD"
# Review convergence: the delta stance rules on open blockers; the old "assume the remediation
# introduced a defect" instruction is gone, because a reviewer told to find a defect finds one.
assert_contains "the delta paragraph carries the open-blocker stance" "$OUT" "Rule only on your open blockers listed below. A new finding blocks only if the fix commits introduced it and it has a merge_class; everything else is a note."
assert_not_contains "and no longer tells the reviewer to assume the remediation introduced a defect" "$OUT" "assume the remediation introduced a defect"
assert_contains "with no --peer-review, each delta lens says no blocker ids were given" "$OUT" "Your open blockers: none recorded"
PR_FILE="$TEMP_PROJECT/peer-review.json"
printf '%s' '{"qa":{"verdict":"REQUEST_CHANGES","materiality":{"open_blocker_ids":["qa-2","qa-7"],"blocks_merge":true}},"dba":{"verdict":"APPROVE","materiality":{"open_blocker_ids":[],"blocks_merge":false}}}' > "$PR_FILE"
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --delta "qa dba" --first-round-head "$FIRST" --peer-review "$PR_FILE" --check
assert_eq "a delta render with --peer-review passes --check" "$RC" "0"
assert_contains "the qa lens lists qa's open blocker ids" "$OUT" "Your open blockers: qa-2, qa-7."
assert_contains "RUN DATA names the peer-review file the agent can Read" "$OUT" "peer_review: "
assert_contains "a role holding none is told it was seated by surface" "$OUT" "Your open blockers: none. You were seated because the fix commits touched your surface"
printf '%s' '{"qa":{"verdict":"REQUEST_CHANGES","materiality":{"open_blocker_ids":["qa-2","qa-7"],"demoted_ids":["qa-9"],"blocks_merge":true}},"dba":{"verdict":"REQUEST_CHANGES","materiality":{"blocks_merge":true}}}' > "$PR_FILE"
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --delta "qa dba" --first-round-head "$FIRST" --peer-review "$PR_FILE" --check
assert_eq "a delta render with demoted and legacy records passes --check" "$RC" "0"
assert_contains "a demoted blocker stays visible to its role on the next delta round" "$OUT" "Demoted past the cap last round, and still yours to rule on: qa-9."
assert_contains "a legacy blocks_merge:true with no ids tells the role to rule on every blocker it raised" "$OUT" "Your open blockers: not named"
assert_contains "meta names the delta" "$OUT" 'name: "phase4-delta-77"'
assert_not_contains "ba is NOT rendered on a qa+dba delta" "$OUT" '"agentType":"pipeline:ba"'
# C2: a role's open blockers reach its prompt as ONE TOON table (fields named once), including a
# legacy concern matched by its positional id; the prose fields stay in peer-review.json.
printf '%s' '{"qa":{"verdict":"REQUEST_CHANGES","concerns":[{"id":"qa-2","severity":"blocker","likelihood":"normal-use","harm":"internal","merge_class":"wrong-pass","location":"a.mjs:3","description":"d"},{"id":"qa-5","severity":"nit","likelihood":"hypothetical","harm":"cosmetic","merge_class":"none"},{"severity":"high","likelihood":"normal-use","harm":"money","merge_class":"money"}],"materiality":{"open_blocker_ids":["qa-2","qa-3"],"blocks_merge":true}}}' > "$PR_FILE"
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --delta "qa" --first-round-head "$FIRST" --peer-review "$PR_FILE" --check
assert_eq "a delta render with concerns passes --check" "$RC" "0"
assert_contains "the open blockers are a TOON table with one header" "$OUT" 'open_blockers[2]{id,severity,likelihood,harm,merge_class,location}:\n    qa-2,blocker,normal-use,internal,wrong-pass,\"a.mjs:3\"\n    qa-3,high,normal-use,money,money,null\n'
assert_not_contains "a concern that is not an open blocker is not tabled" "$OUT" "qa-5,"
assert_not_contains "the concern prose stays in the file, not the prompt" "$OUT" '"description"'

suite "render-panel: surface-conditional roles render when seated"

write_status standard '["ba","dev","qa","secops","design_review","art_director"]'
render --status "$STATUS" --worktree "$WT" --plugin-root "$PLUGIN_ROOT" --check
assert_eq "renders with design_review and art_director" "$RC" "0"
assert_contains "design_review dispatches pipeline:design" "$OUT" '"agentType":"pipeline:design"'
assert_contains "art_director dispatches pipeline:art-director" "$OUT" '"agentType":"pipeline:art-director"'

suite "render-panel: the static prefix is byte-identical across issues and roles (prompt cache)"

# Two dispatches that differ in everything per-run: issue, worktree, reviewed sha, plugin root,
# tier, and role. Both roles are seated on the same panel shape, so they share the preamble. The
# static prefix must be byte-identical and at least as long as the preamble the renderer computed
# (N comes from the render, not a literal), and no per-run value may appear inside it. A second
# pair holds the ROLE fixed across issues, so the whole static part, preamble plus lens, matches.
CACHE="$(MOD="$RENDER" ROOT="$PLUGIN_ROOT" node --input-type=module -e '
import { readFileSync } from "node:fs";
const m = await import(process.env.MOD);
const root = process.env.ROOT;
const md = m.readPreambleMarkdown(root);
const lenses = m.loadLenses(root);
const one = (issue, tier, worktree, head, pluginRoot, delta) => m.assemble({
  status: { issue_number: issue, risk_tier: tier, panel_roles: ["qa", "secops", "dba"] },
  worktree, head, pluginRoot, lenses, preambleMarkdown: md,
  delta, firstRoundHead: delta ? "f".repeat(40) : null, openBlockers: delta ? {} : null,
});
const a = one(48151, "standard", "/work/a/wt", "a".repeat(40), "/plugins/pipeline/0.43.0", null);
const b = one(62342, "architectural", "/elsewhere/b-wt", "b".repeat(40), "/other/cache/pipeline", null);
const qaA = a.dispatches.find((d) => d.role === "qa");
const secB = b.dispatches.find((d) => d.role === "secops");
const qaB = b.dispatches.find((d) => d.role === "qa");
let i = 0;
while (i < qaA.prompt.length && qaA.prompt[i] === secB.prompt[i]) i++;
const shared = Buffer.byteLength(qaA.prompt.slice(0, i));
const N = Buffer.byteLength(a.preamble);
const staticA = a.preamble + qaA.lensText, staticB = b.preamble + qaB.lensText;
const leaks = ["48151", "62342", "/work/a", "/elsewhere", "a".repeat(12), "b".repeat(12), "/plugins/pipeline/0.43.0", "/other/cache"]
  .filter((v) => (a.preamble + a.dispatches.map((d) => d.lensText).join("")).includes(v) || (b.preamble + b.dispatches.map((d) => d.lensText).join("")).includes(v));
const da = one(48151, "standard", "/work/a/wt", "a".repeat(40), "/p", "qa dba"), db = one(62342, "standard", "/w/b", "b".repeat(40), "/q", "qa");
console.log([
  "preambles_equal=" + (a.preamble === b.preamble),
  "prefix_ge_N=" + (shared >= N && N > 1000),
  "prompts_start_with_preamble=" + (qaA.prompt.startsWith(a.preamble) && secB.prompt.startsWith(b.preamble)),
  "same_role_static_equal=" + (staticA === staticB && qaA.prompt.startsWith(staticA) && qaB.prompt.startsWith(staticB)),
  "run_data_differs=" + (qaA.runData !== qaB.runData),
  "run_data_last=" + (qaA.prompt.endsWith(qaA.runData) && qaA.runData.startsWith("RUN DATA\n")),
  "delta_preambles_equal=" + (da.preamble === db.preamble),
  "leaks=" + (leaks.join(",") || "none"),
].join(" "));
console.error("static prefix " + N + " bytes; shared across the two dispatches " + shared + " bytes");
')"
for k in preambles_equal=true prefix_ge_N=true prompts_start_with_preamble=true same_role_static_equal=true run_data_differs=true run_data_last=true delta_preambles_equal=true leaks=none; do
  assert_contains "cache prefix: $k" "$CACHE" "$k"
done
# CONTROL: the same comparison sees a difference when a per-run value is put back into the static
# part, so the byte-identity assertions above are not vacuous.
CONTROL="$(MOD="$RENDER" node --input-type=module -e '
const m = await import(process.env.MOD);
const pre = (issue) => "Phase 4 peer review for #" + issue + ".\n" + m.RUN_DATA_NOTE;
console.log(pre(77) === pre(912) ? "equal" : "differs");
')"
assert_eq "CONTROL: a static part carrying the issue number is not byte-identical" "$CONTROL" "differs"

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

# A plugin root whose preamble file (orchestrator/phase-4-panel-preamble.md) lost its markers must refuse rather than render an empty preamble.
FAKE_ROOT="$TEMP_PROJECT/fake-root"
mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/orchestrator"
cp "$PLUGIN_ROOT/scripts/panel-lenses.json" "$FAKE_ROOT/scripts/"
printf '# no markers here\n' > "$FAKE_ROOT/orchestrator/phase-4-panel-preamble.md"
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
