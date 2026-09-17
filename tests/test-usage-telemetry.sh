#!/usr/bin/env bash
# Usage telemetry (#163): the dispatch log writer (scripts/dispatch-log.mjs through
# hooks/dispatch-log.sh), the resolvers' rule labels it records, and the usage report's join
# (scripts/usage-report.mjs) over fixture transcripts and fixture OpenTelemetry exports.
#
# What must hold:
#   - off by default: no config key and no env var writes nothing and prints nothing;
#   - one line per dispatch, carrying exactly the allowlisted fields and never prompt text;
#   - a Workflow panel rendered by render-panel.mjs logs one line per agent, with the routing rule;
#   - enabled but unwritable is a visible disarm, and the hook still exits 0;
#   - the report joins exactly where the data allows, counts usage once per message id, and
#     reports what it cannot join as unattributed, with its share.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

LOGW="$SCRIPTS_DIR/dispatch-log.mjs"
REPORT="$SCRIPTS_DIR/usage-report.mjs"
HOOK="$HOOKS_DIR/dispatch-log.sh"

make_temp_project 42 || exit 90
PROJ="$TEMP_PROJECT"
git -C "$PROJ" init -q
git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
node -e '
  const fs = require("fs");
  const now = new Date().toISOString();
  fs.writeFileSync(process.argv[1], JSON.stringify({
    issue_number: 42, current_phase: "4-review", risk_tier: "standard", cost_class: "product",
    panel_roles: ["ba", "secops"], started_at: now, updated_at: now, branch: "b", events: [],
  }));' "$PROJ/.pipeline/42/status.json"

# A path handed to node through the ENVIRONMENT, spelled so node reads the file bash does. Git Bash
# rewrites /tmp paths in the environment only sometimes; cygpath makes it certain.
np() {
  if [[ "$PIPELINE_ON_WINDOWS" == "1" ]] && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

new_tmpdir || exit 90
OUT="$NEW_TMPDIR"
LOG="$OUT/dispatch.jsonl"
DISARM_LOG="$OUT/disarm.log"

AGENT_PAYLOAD='{"session_id":"s-1","tool_use_id":"toolu_1","transcript_path":"/x/s-1.jsonl","tool_name":"Agent","effort":{"level":"xhigh"},"tool_input":{"subagent_type":"pipeline:dba","model":"sonnet","description":"DESCRIPTION-TEXT","prompt":"PROMPT-TEXT-MUST-NOT-LEAK"}}'

run_hook() { # <payload> [env assignments...]
  local payload="$1"
  shift
  printf '%s' "$payload" | env CLAUDE_PROJECT_DIR="$(np "$PROJ")" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    CLAUDE_PIPELINE_DISPATCH_LOG="$(np "$LOG")" CLAUDE_PIPELINE_DISARM_LOG="$(np "$DISARM_LOG")" "$@" sh "$HOOK"
}

field() { # <json line> <field>
  node -e 'const o = JSON.parse(process.argv[1]); const v = o[process.argv[2]]; process.stdout.write(v === null ? "null" : String(v));' "$1" "$2"
}

# OFF BY DEFAULT. Telemetry writes to the git common dir of a consumer project, so the default has
# to be nothing at all: no file, no output, and an exit 0 that lets the dispatch run. The env var
# wins over the config key in both directions, so one session can opt out of a project that opted
# in. The absent log file is the observation, not the exit code, because a hook that wrote a line
# and exited 0 would pass an exit-code check.
suite "#163 dispatch log: off by default"

STDOUT="$(run_hook "$AGENT_PAYLOAD" 2>/dev/null)"
RC=$?
assert_eq "no config key and no env var: the hook exits 0" "$RC" "0"
assert_eq "no config key and no env var: nothing on stdout" "$STDOUT" ""
assert_eq "no config key and no env var: no log file is created" "$([[ -e "$LOG" ]] && echo exists || echo absent)" "absent"

printf '%s' '{"usageTelemetry":{"enabled":false}}' > "$PROJ/pipeline.config.json"
run_hook "$AGENT_PAYLOAD" >/dev/null 2>&1
assert_eq "usageTelemetry.enabled false: no log file" "$([[ -e "$LOG" ]] && echo exists || echo absent)" "absent"

printf '%s' '{"usageTelemetry":{"enabled":true}}' > "$PROJ/pipeline.config.json"
run_hook "$AGENT_PAYLOAD" CLAUDE_PIPELINE_USAGE_TELEMETRY=0 >/dev/null 2>&1
assert_eq "env var 0 wins over an enabling config: no log file" "$([[ -e "$LOG" ]] && echo exists || echo absent)" "absent"

# ONE LINE PER DISPATCH. The field list is compared with the exported allowlist as a whole, so a new
# field fails here before it reaches a log. The prompt and description are planted as marker words
# that must not appear. Issue, phase, tier and cost class come from the in-flight status record, the
# model from the call or the agent frontmatter, and the effort from the frontmatter, because the
# Agent tool carries none. A Bash call is the control that the matcher, not luck, keeps it quiet.
suite "#163 dispatch log: one Agent dispatch, one line"

STDOUT="$(run_hook "$AGENT_PAYLOAD" 2>/dev/null)"
RC=$?
assert_eq "enabled: the hook exits 0" "$RC" "0"
assert_eq "enabled: no decision and no message on stdout" "$STDOUT" ""
assert_eq "one dispatch appends exactly one line" "$(grep -c . "$LOG" | tr -d ' ')" "1"
LINE="$(head -n 1 "$LOG")"
assert_eq "the line carries exactly the allowlisted fields, in order" \
  "$(MOD="$LOGW" LINE="$LINE" node --input-type=module -e '
    const { LOG_FIELDS } = await import(process.env.MOD);
    process.stdout.write(Object.keys(JSON.parse(process.env.LINE)).join(",") === LOG_FIELDS.join(",") ? "same" : "DIFFERENT");')" "same"
assert_not_contains "no prompt text in the log" "$(cat "$LOG")" "PROMPT-TEXT"
assert_not_contains "no description text in the log" "$(cat "$LOG")" "DESCRIPTION-TEXT"
assert_eq "session id" "$(field "$LINE" session_id)" "s-1"
assert_eq "tool_use_id, the exact join key for a subagent transcript" "$(field "$LINE" tool_use_id)" "toolu_1"
assert_eq "role from a plugin-scoped subagent_type" "$(field "$LINE" role)" "dba"
assert_eq "issue from the in-flight status record" "$(field "$LINE" issue)" "42"
assert_eq "phase from current_phase" "$(field "$LINE" phase)" "4"
assert_eq "tier" "$(field "$LINE" tier)" "standard"
assert_eq "cost_class" "$(field "$LINE" cost_class)" "product"
assert_eq "model as the call passed it" "$(field "$LINE" model)" "sonnet"
assert_eq "model_reason names the routing-table row that yields it" "$(field "$LINE" model_reason)" "table:dba/4/standard/panel-lens"
assert_eq "site recovered where the table makes it unique" "$(field "$LINE" site)" "panel-lens"
assert_eq "effort is what the frontmatter declares on the Agent surface" "$(field "$LINE" effort)" "high"
assert_eq "effort_reason says the Agent surface carries no effort" "$(field "$LINE" effort_reason)" "agent-surface:frontmatter"
assert_eq "the session's effort level from the hook payload is kept apart" "$(field "$LINE" session_effort)" "xhigh"

run_hook '{"session_id":"s-1","tool_use_id":"toolu_2","tool_name":"Agent","tool_input":{"subagent_type":"secops","prompt":"x"}}' >/dev/null 2>&1
LINE="$(sed -n 2p "$LOG")"
assert_eq "no model passed: the frontmatter model is recorded" "$(field "$LINE" model)" "opus"
assert_eq "no model passed: the reason names the frontmatter file" "$(field "$LINE" model_reason)" "frontmatter agents/secops.md"
assert_eq "secops frontmatter effort" "$(field "$LINE" effort)" "xhigh"

run_hook '{"session_id":"s-1","tool_use_id":"toolu_3","tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}' >/dev/null 2>&1
LINE="$(sed -n 3p "$LOG")"
assert_eq "a non-pipeline subagent is still logged, with no role" "$(field "$LINE" role)" "null"
assert_eq "and its subagent_type is kept" "$(field "$LINE" subagent_type)" "general-purpose"

run_hook '{"session_id":"s-1","tool_name":"Bash","tool_input":{"command":"ls"}}' >/dev/null 2>&1
assert_eq "a non-dispatch tool writes nothing" "$(grep -c . "$LOG" | tr -d ' ')" "3"

# WORKFLOW. The panel is rendered by the real renderer rather than written by hand, so a change to
# the renderer output shape reddens this block instead of leaving the writer reading a script that
# no longer exists.
suite "#163 dispatch log: a rendered Workflow panel logs one line per agent"

node "$SCRIPTS_DIR/render-panel.mjs" --status "$PROJ/.pipeline/42/status.json" --worktree "$PROJ" --out "$OUT/panel.mjs" 2>/dev/null
assert_eq "the panel fixture rendered" "$([[ -s "$OUT/panel.mjs" ]] && echo yes || echo no)" "yes"
WF_PAYLOAD="$(node -e '
  const fs = require("fs");
  process.stdout.write(JSON.stringify({ session_id: "s-1", tool_use_id: "toolu_wf", tool_name: "Workflow", tool_input: { script: fs.readFileSync(process.argv[1], "utf8") } }));' "$OUT/panel.mjs")"
run_hook "$WF_PAYLOAD" >/dev/null 2>&1
assert_eq "two panel roles, two more lines" "$(grep -c . "$LOG" | tr -d ' ')" "5"
BA="$(sed -n 4p "$LOG")"
SEC="$(sed -n 5p "$LOG")"
assert_eq "workflow line 1 is ba" "$(field "$BA" role)/$(field "$BA" surface)/$(field "$BA" batch_index)" "ba/workflow/0"
assert_eq "ba model and its rule" "$(field "$BA" model) $(field "$BA" model_reason)" "sonnet table:ba/4/panel-lens"
assert_eq "ba effort and its rule" "$(field "$BA" effort) $(field "$BA" effort_reason)" "medium table:ba/4/panel-lens"
assert_eq "secops carries no model key, so the frontmatter model and the pin are recorded" \
  "$(field "$SEC" model) $(field "$SEC" model_reason)" "opus pinned:secops (no model key; frontmatter)"
assert_eq "secops effort and its tiered rule" "$(field "$SEC" effort) $(field "$SEC" effort_reason)" "high table:secops/4/standard/panel-lens"
assert_eq "the Workflow call's issue comes from the rendered meta name" "$(field "$SEC" issue)" "42"
assert_not_contains "no lens or preamble text in the log" "$(cat "$LOG")" "Your role"
assert_eq "a well-formed line rejects nothing" "$(field "$SEC" rejected_fields)" "0"

# CRAFTED INPUT. Every value is held to a shape before it is written: a number or exp id for the
# issue, an alias or model id for the model, one of five effort levels, and short tokens for ids.
# The crafted values below carry a secret-shaped token and free words, and each must be written as
# null and counted, while a well-formed agent in the same script keeps its values.
suite "#163 dispatch log: a crafted script or payload cannot write free text into the log"

SECRET_SCRIPT="$(printf '%s\n' \
  'export const meta = { name: "phase4-panel-SECRET sk-ant-xyz", description: "x", phases: [{ title: "Panel" }] }' \
  '  () => agent(PREAMBLE + "lens", {"agentType":"pipeline:ba SECRET sk-ant-xyz","model":"sk-ant-xyz secret","effort":"medium; touch pwned","label":"ba-panel"}),' \
  '  () => agent(PREAMBLE + "lens", {"agentType":"pipeline:qa","model":"opus","effort":"high","label":"qa-panel"}),')"
SECRET_WF="$(SCRIPT="$SECRET_SCRIPT" node -e '
  process.stdout.write(JSON.stringify({ session_id: "s-1", tool_use_id: "toolu_secret", tool_name: "Workflow", tool_input: { script: process.env.SCRIPT } }));')"
run_hook "$SECRET_WF" >/dev/null 2>&1
run_hook '{"session_id":"s-1 sk-ant-xyz","tool_use_id":"toolu_4","tool_name":"Agent","effort":{"level":"sk-ant-xyz leak"},"tool_input":{"subagent_type":"general purpose sk-ant-xyz","model":"sk-ant-xyz","prompt":"x"}}' >/dev/null 2>&1
assert_eq "the crafted workflow gave two lines and the crafted Agent call one" "$(grep -c . "$LOG" | tr -d ' ')" "8"
assert_not_contains "no secret-shaped value reaches the log" "$(cat "$LOG")" "sk-ant"
assert_not_contains "no free text from the meta name reaches the log" "$(cat "$LOG")" "SECRET"
W1="$(sed -n 6p "$LOG")"
W2="$(sed -n 7p "$LOG")"
AG="$(sed -n 8p "$LOG")"
assert_eq "a meta-name issue outside the issue pattern is null" "$(field "$W1" issue)" "null"
assert_eq "agentType, model and effort outside the token pattern are null" \
  "$(field "$W1" subagent_type)/$(field "$W1" model)/$(field "$W1" effort)" "null/null/null"
assert_eq "and every rejection is counted (issue, subagent_type, model, effort)" "$(field "$W1" rejected_fields)" "4"
assert_eq "the well-formed agent in the same script keeps its values, issue still rejected" \
  "$(field "$W2" role)/$(field "$W2" model)/$(field "$W2" effort)/$(field "$W2" issue)/$(field "$W2" rejected_fields)" "qa/opus/high/null/1"
assert_eq "a crafted Agent payload: session, subagent_type, model and session effort are null" \
  "$(field "$AG" session_id)/$(field "$AG" subagent_type)/$(field "$AG" model)/$(field "$AG" session_effort)/$(field "$AG" rejected_fields)" "null/null/null/null/4"

# DISARM, NEVER BLOCK. When the line cannot be written, the dispatch still runs, and the hook says
# so on the systemMessage channel and in the disarm log, which is the rule every hook here follows
# since 0.43.0. The cells cover an unwritable log, a missing script and a payload that is not JSON.
suite "#163 dispatch log: enabled but not writable is a visible disarm, never a block"

printf 'a file, not a directory' > "$OUT/blocker"
STDOUT="$(printf '%s' "$AGENT_PAYLOAD" | env CLAUDE_PROJECT_DIR="$(np "$PROJ")" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  CLAUDE_PIPELINE_DISPATCH_LOG="$(np "$OUT")/blocker/dispatch.jsonl" CLAUDE_PIPELINE_DISARM_LOG="$(np "$DISARM_LOG")" sh "$HOOK" 2>/dev/null)"
RC=$?
assert_eq "unwritable log: the hook still exits 0" "$RC" "0"
assert_contains "unwritable log: a systemMessage says the check did not run" "$STDOUT" "pipeline check dispatch-log did not run: the dispatch log could not be appended"
assert_not_contains "unwritable log: no permission decision is emitted" "$STDOUT" "permissionDecision"
assert_contains "unwritable log: the disarm log records it" "$(cat "$DISARM_LOG" 2>/dev/null)" "PreToolUse pipeline check dispatch-log did not run"

new_tmpdir || exit 90
NOSCRIPT="$NEW_TMPDIR"
mkdir -p "$NOSCRIPT/hooks"
cp "$HOOKS_DIR/disarm.sh" "$HOOKS_DIR/dispatch-log.sh" "$NOSCRIPT/hooks/"
STDOUT="$(printf '%s' "$AGENT_PAYLOAD" | env CLAUDE_PROJECT_DIR="$(np "$PROJ")" CLAUDE_PLUGIN_ROOT="$NOSCRIPT" \
  CLAUDE_PIPELINE_DISPATCH_LOG="$(np "$LOG")" CLAUDE_PIPELINE_DISARM_LOG="$(np "$DISARM_LOG")" sh "$NOSCRIPT/hooks/dispatch-log.sh" 2>/dev/null)"
RC=$?
assert_eq "script not installed: the hook exits 0" "$RC" "0"
assert_contains "script not installed: the disarm names it" "$STDOUT" "scripts/dispatch-log.mjs is not installed"

printf '%s' 'not json' | env CLAUDE_PROJECT_DIR="$(np "$PROJ")" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  CLAUDE_PIPELINE_DISPATCH_LOG="$(np "$LOG")" CLAUDE_PIPELINE_DISARM_LOG="$(np "$DISARM_LOG")" sh "$HOOK" >"$OUT/bad.out" 2>/dev/null
assert_contains "an unparsable payload is a disarm, not a crash" "$(cat "$OUT/bad.out")" "the PreToolUse payload did not parse as JSON"

suite "#163 dispatch log: the hook is declared for every dispatch tool"

DECL="$(node -e '
  const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const e = (h.hooks.PreToolUse || []).find((x) => (x.hooks || []).some((y) => /dispatch-log\.sh/.test(y.command)));
  if (!e) { process.stdout.write("UNDECLARED"); process.exit(0); }
  const re = new RegExp("^(?:" + e.matcher + ")$");
  process.stdout.write(["Agent", "Task", "Workflow"].map((t) => t + "=" + re.test(t)).join(" ") + " Bash=" + re.test("Bash"));' "$HOOKS_DIR/hooks.json")"
assert_eq "the dispatch-log PreToolUse matcher admits Agent, Task and Workflow and not Bash" "$DECL" "Agent=true Task=true Workflow=true Bash=false"

# THE REPORT OVER TRANSCRIPTS. The fixtures are small transcripts in the shape Claude Code writes,
# with a subagent file carrying the tool use id of its dispatch. The join is checked method by
# method, most exact first, and a streamed message repeating its id is counted once. Transcripts
# carry no cost, so a cost appears only when a price table is passed.
suite "#163 report: transcripts joined to the dispatch log"

new_tmpdir || exit 90
FX="$NEW_TMPDIR"
node - "$FX" <<'EOF'
const fs = require("fs");
const path = require("path");
const fx = process.argv[2];
const S1 = "sess-1111";
const S2 = "sess-2222";
const lines = [
  { ts: "2026-09-01T10:00:00Z", session_id: S1, tool_use_id: "toolu_A", surface: "agent", subagent_type: "pipeline:ba", role: "ba", issue: "7", phase: "1", model: "opus", effort: "high", session_effort: "xhigh" },
  { ts: "2026-09-01T11:00:00Z", session_id: S1, tool_use_id: "toolu_B", surface: "agent", subagent_type: "pipeline:dev", role: "dev", issue: "7", phase: "3", model: "opus", effort: "high", session_effort: "xhigh" },
  { ts: "2026-09-01T12:00:00Z", session_id: S1, tool_use_id: "toolu_W", surface: "workflow", batch_index: 0, subagent_type: "pipeline:ba", role: "ba", issue: "7", phase: "4", model: "sonnet", effort: "medium" },
  { ts: "2026-09-01T12:00:00Z", session_id: S1, tool_use_id: "toolu_W", surface: "workflow", batch_index: 1, subagent_type: "pipeline:secops", role: "secops", issue: "7", phase: "4", model: "opus", effort: "high" },
];
fs.writeFileSync(path.join(fx, "dispatch.jsonl"), lines.map((l) => JSON.stringify(l)).join("\n") + "\nnot json\n");
const msg = (session, ts, id, model, u, extra = {}) => JSON.stringify({
  type: "assistant", sessionId: session, timestamp: ts, isSidechain: Boolean(extra.agentId), ...extra,
  message: { id, model, role: "assistant", content: [{ type: "text", text: "CONTENT-MUST-NOT-PRINT" }], usage: u },
});
const u = (i, o) => ({ input_tokens: i, output_tokens: o, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 });
const dir = path.join(fx, "projects", "p");
fs.mkdirSync(path.join(dir, S1, "subagents", "workflows", "wf_1"), { recursive: true });
fs.writeFileSync(path.join(dir, `${S1}.jsonl`), [
  msg(S1, "2026-09-01T09:50:00Z", "m1", "claude-opus-4-8", u(100, 10)),
  msg(S1, "2026-09-01T10:30:00Z", "m2", "claude-opus-4-8", u(200, 5)),
  msg(S1, "2026-09-01T10:30:01Z", "m2", "claude-opus-4-8", u(200, 50)),
  msg(S1, "2026-09-01T11:30:00Z", "m3", "claude-opus-4-8", u(300, 30)),
  msg(S1, "2026-09-01T11:31:00Z", "m4", "<synthetic>", u(9999, 9999)),
  JSON.stringify({ type: "user", sessionId: S1, timestamp: "2026-09-01T11:32:00Z", message: { content: "CONTENT-MUST-NOT-PRINT" } }),
].join("\n") + "\n");
const sub = path.join(dir, S1, "subagents");
fs.writeFileSync(path.join(sub, "agent-a1.jsonl"), msg(S1, "2026-09-01T10:01:00Z", "s1", "claude-opus-4-8", u(1000, 100), { agentId: "a1" }) + "\n");
fs.writeFileSync(path.join(sub, "agent-a1.meta.json"), JSON.stringify({ agentType: "pipeline:ba", toolUseId: "toolu_A" }));
fs.writeFileSync(path.join(sub, "agent-a2.jsonl"), msg(S1, "2026-09-01T11:01:00Z", "s2", "claude-opus-4-8", u(2000, 200), { agentId: "a2" }) + "\n");
fs.writeFileSync(path.join(sub, "agent-a2.meta.json"), JSON.stringify({ agentType: "pipeline:dev" }));
const wf = path.join(sub, "workflows", "wf_1");
fs.writeFileSync(path.join(wf, "agent-w1.jsonl"), msg(S1, "2026-09-01T12:00:05Z", "w1", "claude-sonnet-4-6", u(400, 40), { agentId: "w1" }) + "\n");
fs.writeFileSync(path.join(wf, "agent-w1.meta.json"), JSON.stringify({ agentType: "workflow-subagent" }));
fs.writeFileSync(path.join(wf, "agent-w2.jsonl"), msg(S1, "2026-09-01T12:00:03Z", "w2", "claude-opus-4-8", u(800, 80), { agentId: "w2" }) + "\n");
fs.writeFileSync(path.join(wf, "agent-w2.meta.json"), JSON.stringify({ agentType: "workflow-subagent" }));
fs.writeFileSync(path.join(dir, `${S2}.jsonl`), msg(S2, "2026-09-02T08:00:00Z", "o1", "claude-opus-4-8", u(5000, 0)) + "\n");
EOF

TXT="$(CLAUDE_PROJECT_DIR="$FX" node "$REPORT" --dispatch-log "$FX/dispatch.jsonl" --transcripts "$FX/projects" 2>&1)"
assert_not_contains "the report prints no message content" "$TXT" "CONTENT-MUST-NOT-PRINT"
assert_contains "the report prints the unattributed share" "$TXT" "unattributed to a role and phase: 5,000 (48.5%)"
assert_contains "an unparsable dispatch line is counted, not fatal" "$TXT" "1 unparsable lines skipped"

JSON="$(CLAUDE_PROJECT_DIR="$FX" node "$REPORT" --dispatch-log "$FX/dispatch.jsonl" --transcripts "$FX/projects" --json 2>/dev/null)"
q() { # <js expression over `r`, the parsed report>
  node -e 'const r = JSON.parse(process.argv[1]); const row = (d, k) => { const x = r.tables[d].find((y) => y.key === k); return x ? x.total : "absent"; }; process.stdout.write(String(eval(process.argv[2])));' "$JSON" "$1"
}
assert_eq "total tokens: a streamed message counts once, a <synthetic> line not at all" "$(q 'r.attr.total')" "10310"
assert_eq "attributed to role and phase" "$(q 'r.attr.attributed')" "5310"
assert_eq "unattributed (a session with no dispatches is not dropped)" "$(q 'r.attr.unattributed')" "5000"
assert_eq "orchestrator main thread (look-ahead, and two after dispatches)" "$(q 'row("role","orchestrator")')" "690"
assert_eq "ba: exact tool_use_id join plus the workflow batch line" "$(q 'row("role","ba")')" "1540"
assert_eq "dev: joined by agent type and time" "$(q 'row("role","dev")')" "2200"
assert_eq "secops: workflow agent placed by model family when start order does not fit" "$(q 'row("role","secops")')" "880"
assert_eq "unattributed role row" "$(q 'row("role","(unattributed)")')" "5000"
assert_eq "main-thread work before the first dispatch is phase <1" "$(q 'row("phase","<1")')" "110"
assert_eq "phase 4 is the two workflow agents" "$(q 'row("phase","4")')" "1320"
assert_eq "issue #7" "$(q 'row("issue","#7")')" "5310"
assert_eq "join method tool_use_id" "$(q 'row("join method","tool_use_id")')" "1100"
assert_eq "join method agent_type" "$(q 'row("join method","agent_type")')" "2200"
assert_eq "join method workflow_order" "$(q 'row("join method","workflow_order")')" "1320"
assert_eq "join method session_lookahead" "$(q 'row("join method","session_lookahead")')" "110"
assert_eq "join method session_time" "$(q 'row("join method","session_time")')" "580"
assert_eq "effort from the dispatch for a subagent (workflow ba at medium)" "$(q 'row("model x effort","claude-sonnet-4-6 / medium")')" "440"
assert_eq "effort from the session for the main thread" "$(q 'row("effort","xhigh (session)")')" "690"
assert_eq "per day" "$(q 'row("day","2026-09-01")')/$(q 'row("day","2026-09-02")')" "5310/5000"
assert_eq "per run" "$(q 'row("run","#7@sess-111")')" "5310"
assert_eq "transcripts carry no cost, so none is invented" "$(q 'r.tables.model.every((x) => x.costKnown === 0)')" "true"

printf '%s' '{"opus":{"input":10,"output":20,"cache_read":1,"cache_write":12},"sonnet":{"input":1,"output":2,"cache_read":0,"cache_write":0}}' > "$FX/prices.json"
JSON="$(CLAUDE_PROJECT_DIR="$FX" node "$REPORT" --dispatch-log "$FX/dispatch.jsonl" --transcripts "$FX/projects" --prices "$FX/prices.json" --json 2>/dev/null)"
assert_eq "--prices costs a transcript row per MTok (dev: 2000 in, 200 out on opus)" \
  "$(node -e 'const r = JSON.parse(process.argv[1]); process.stdout.write(r.tables.role.find((x) => x.key === "dev").cost.toFixed(4));' "$JSON")" "0.0240"

# THE REPORT OVER OPENTELEMETRY. Metric points and api request events as the file exporter writes
# them. Cumulative cost is differenced between points rather than summed, and a request with no
# dispatch in its session is reported as unattributed instead of being guessed onto a role.
suite "#163 report: OpenTelemetry file-exporter lines"

node - "$FX" <<'EOF'
const fs = require("fs");
const path = require("path");
const fx = process.argv[2];
fs.mkdirSync(path.join(fx, "otel"), { recursive: true });
const s = (k, v) => ({ key: k, value: { stringValue: String(v) } });
const i = (k, v) => ({ key: k, value: { intValue: String(v) } });
const d = (k, v) => ({ key: k, value: { doubleValue: v } });
const ev = (session, ts, attrs) => ({
  timeUnixNano: String(Date.parse(ts) * 1e6),
  body: { stringValue: "claude_code.api_request" },
  attributes: [s("event.name", "api_request"), s("event.timestamp", ts), ...attrs],
});
const logs = {
  resourceLogs: [{
    resource: { attributes: [s("service.name", "claude-code")] },
    scopeLogs: [{ logRecords: [
      ev("sess-3333", "2026-09-03T13:05:00Z", [s("session.id", "sess-3333"), s("agent.name", "custom"), s("query_source", "subagent"), s("model", "claude-opus-4-8"), s("effort", "medium"), i("input_tokens", 10), i("output_tokens", 20), i("cache_read_tokens", 30), i("cache_creation_tokens", 40), d("cost_usd", 0.5)]),
      ev("sess-3333", "2026-09-03T13:06:00Z", [s("session.id", "sess-3333"), s("query_source", "main"), s("model", "claude-opus-4-8"), s("effort", "xhigh"), i("input_tokens", 1), i("output_tokens", 1), d("cost_usd", 0.01)]),
      ev("sess-9999", "2026-09-03T13:07:00Z", [s("session.id", "sess-9999"), s("model", "claude-sonnet-4-6"), i("input_tokens", 7), d("cost_usd", 0.1)]),
      { timeUnixNano: "1", body: { stringValue: "claude_code.user_prompt" }, attributes: [s("event.name", "user_prompt"), s("prompt", "PROMPT-MUST-NOT-COUNT")] },
    ] }],
  }],
};
const point = (ts, attrs, v) => ({ attributes: attrs, startTimeUnixNano: "1000", timeUnixNano: String(Date.parse(ts) * 1e6), asDouble: v });
const metrics = {
  resourceMetrics: [{
    resource: { attributes: [s("session.id", "sess-4444")] },
    scopeMetrics: [{ metrics: [
      { name: "claude_code.token.usage", sum: { aggregationTemporality: 2, isMonotonic: true, dataPoints: [
        point("2026-09-03T14:00:00Z", [s("type", "output"), s("model", "claude-opus-4-8"), s("effort", "high")], 100),
        point("2026-09-03T14:01:00Z", [s("type", "output"), s("model", "claude-opus-4-8"), s("effort", "high")], 250),
      ] } },
      { name: "claude_code.cost.usage", sum: { aggregationTemporality: "AGGREGATION_TEMPORALITY_CUMULATIVE", dataPoints: [
        point("2026-09-03T14:00:00Z", [s("model", "claude-opus-4-8")], 1.0),
        point("2026-09-03T14:01:00Z", [s("model", "claude-opus-4-8")], 1.5),
      ] } },
    ] }],
  }, {
    resource: { attributes: [s("session.id", "sess-3333")] },
    scopeMetrics: [{ metrics: [{ name: "claude_code.token.usage", sum: { aggregationTemporality: 1, dataPoints: [point("2026-09-03T13:05:00Z", [s("type", "input"), s("model", "claude-opus-4-8")], 99999)] } }] }],
  }],
};
fs.writeFileSync(path.join(fx, "otel", "claude-code-logs.jsonl"), JSON.stringify(logs) + "\n");
fs.writeFileSync(path.join(fx, "otel", "claude-code-metrics.jsonl"), JSON.stringify(metrics) + "\n");
fs.writeFileSync(path.join(fx, "otel-dispatch.jsonl"), JSON.stringify({ ts: "2026-09-03T13:00:00Z", session_id: "sess-3333", tool_use_id: "toolu_C", surface: "agent", subagent_type: "pipeline:qa", role: "qa", issue: "9", phase: "4", model: "opus", effort: "medium", session_effort: "xhigh" }) + "\n");
EOF

JSON="$(CLAUDE_PROJECT_DIR="$FX" node "$REPORT" --dispatch-log "$FX/otel-dispatch.jsonl" --otel "$FX/otel" --json 2>/dev/null)"
assert_eq "OTel total: events, plus cumulative metrics differenced, and metrics dropped for a session that has events" "$(q 'r.attr.total')" "359"
assert_eq "an OTel subagent request joins by session, model family and effort" "$(q 'row("role","qa")')" "100"
assert_eq "an OTel main-thread request is the orchestrator" "$(q 'row("role","orchestrator")')" "2"
assert_eq "OTel usage with no dispatch is unattributed" "$(q 'r.attr.unattributed')" "257"
assert_eq "effort comes from the OTel attribute when present" "$(q 'row("effort","xhigh")')" "2"
assert_eq "cost_usd is summed as reported" "$(node -e 'const r = JSON.parse(process.argv[1]); process.stdout.write(r.tables.role.find((x) => x.key === "qa").cost.toFixed(2));' "$JSON")" "0.50"
assert_eq "cumulative cost is differenced, not summed" "$(node -e 'const r = JSON.parse(process.argv[1]); process.stdout.write(r.tables.role.find((x) => x.key === "(unattributed)").cost.toFixed(2));' "$JSON")" "1.60"

# ONE SOURCE PER SESSION. A session present in both sources is counted once, from OpenTelemetry,
# and every message dropped for that reason or for an unreadable timestamp is printed as a note, so
# the total can be reconciled by hand.
suite "#163 report: one usage source per session when both are given"

mkdir -p "$FX/t3"
node - "$FX" <<'EOF'
const fs = require("fs");
const path = require("path");
const fx = process.argv[2];
const line = (session, ts, id, input) => JSON.stringify({
  type: "assistant", sessionId: session, timestamp: ts,
  message: { id, model: "claude-opus-4-8", usage: { input_tokens: input, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } },
});
fs.writeFileSync(path.join(fx, "t3", "sess-3333.jsonl"), line("sess-3333", "2026-09-03T13:05:00Z", "dup1", 1000) + "\n");
fs.writeFileSync(path.join(fx, "t3", "sess-7777.jsonl"), [
  line("sess-7777", "2026-09-03T15:00:00Z", "only1", 500),
  line("sess-7777", "not a time", "undated1", 42),
].join("\n") + "\n");
EOF
BOTH="$(CLAUDE_PROJECT_DIR="$FX" node "$REPORT" --dispatch-log "$FX/otel-dispatch.jsonl" --otel "$FX/otel" --transcripts "$FX/t3" --json 2>/dev/null)"
JSON="$BOTH"
assert_eq "a session with OTel records does not also count its transcript (359 OTel + 500 from a transcript-only session)" "$(q 'r.attr.total')" "859"
assert_eq "the qa row is OTel's 100, not 100 plus the transcript's 1000" "$(q 'row("role","qa")')" "100"
assert_contains "the dropped transcript messages are reported" "$(q 'r.notes.join(" | ")')" "1 transcript message(s) dropped: their session also has OpenTelemetry records"
assert_contains "records with no parseable timestamp are counted, not silently lost" "$(q 'r.notes.join(" | ")')" "1 transcript message(s) dropped: no parseable timestamp"
assert_contains "usage from sessions with no dispatch line is reported" "$(q 'r.notes.join(" | ")')" "757 tokens (6 records) come from sessions with no dispatch line; reported as unattributed"

suite "#163 resolvers: the rule label is a label, not a new decision"

# Module paths go through the environment, not argv: both resolvers run main() when argv[1] names them.
RULES="$(DM="$SCRIPTS_DIR/dispatch-model.mjs" DE="$SCRIPTS_DIR/dispatch-effort.mjs" node --input-type=module -e '
  const m = await import(process.env.DM);
  const e = await import(process.env.DE);
  const out = [
    m.resolve({ role: "qa", tier: "standard", phase: "4", cfg: {} }).rule,
    m.resolve({ role: "devops", tier: "standard", phase: "4", cfg: { dispatchModels: { devops: "haiku" } } }).rule,
    m.resolve({ role: "dev", tier: "architectural", phase: "2.5", site: "bakeoff-judge", cfg: {} }).rule,
    m.resolve({ role: "librarian", tier: "standard", phase: "5", cfg: {} }).rule,
    m.resolve({ role: "nobody", tier: "standard", phase: "4", cfg: {} }).rule,
    e.resolve({ role: "secops", tier: "trivial", phase: "4", site: "panel-lens", surface: "workflow", costClass: "tooling", cfg: {} }).rule,
    e.resolve({ role: "secops", tier: "trivial", phase: "4", cfg: {} }).rule,
    e.resolve({ role: "ba", tier: "standard", phase: "4", surface: "workflow", cfg: { dispatchEfforts: { ba: "low" } } }).rule,
  ];
  process.stdout.write(out.join(" "));')"
assert_eq "model and effort rule labels" "$RULES" \
  "pinned:qa config:dispatchModels.devops table:dev/2.5/bakeoff-judge no-row:frontmatter error table:secops/4/tooling/panel-lens agent-surface:frontmatter config:dispatchEfforts.ba"

finish
