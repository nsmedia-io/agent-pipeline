#!/usr/bin/env node
/**
 * The dispatch log (#163): one JSONL line per subagent dispatch, so token use can later be read
 * per model, effort, role, phase and issue. Claude Code's own usage data (OpenTelemetry or the
 * session transcripts) carries the model and, on OTel, the effort, but never the pipeline context:
 * which issue, which phase, which role, which routing rule chose the model. This file writes that
 * half; scripts/usage-report.mjs joins the two.
 *
 *   node dispatch-log.mjs hook            PreToolUse payload on stdin (Agent, Task or Workflow)
 *   node dispatch-log.mjs path            print the log file this project writes to
 *   node dispatch-log.mjs status          print enabled/disabled and why
 *
 * WHY A HOOK AND NOT THE RESOLVER CALL. Only five dispatch sites ask dispatch-model.mjs for a
 * model (the 0.5 map, the 2.5 sketches and judge, and the renderer's two panel lenses); Phase 1 BA,
 * the Phase 2 reviewers and the Phase 3 Dev and QA dispatches carry no resolver call, because
 * frontmatter governs there. A log written from the resolver would miss most dispatches and read
 * as complete. A PreToolUse hook on the Agent and Workflow tools sees every dispatch, including
 * ad hoc re-dispatches, and needs no prose step (hooks/dispatch-log.sh, hooks/hooks.json).
 *
 * WHAT IS WRITTEN. The fields in LOG_FIELDS and nothing else: every record passes through
 * sanitize(), which copies an allowlist. No prompt, no description, no tool arguments. The one
 * path written is the session's transcript_path, which the report uses to find usage without a
 * collector; the log lives in the git common dir (never committed) or a configured directory.
 *
 * OFF BY DEFAULT. Enabled by `usageTelemetry.enabled: true` in pipeline.config.json or by
 * CLAUDE_PIPELINE_USAGE_TELEMETRY=1 (which also wins over config; `0` disables). Disabled means:
 * nothing read beyond the enable check, nothing written, exit 0, no output.
 *
 * FAILURE. Never blocks a dispatch: the hook exits 0 with no decision on stdout. When ENABLED and
 * the line cannot be written, this exits 3 with one fixed-vocabulary reason on stderr, and
 * hooks/dispatch-log.sh turns that into the 0.43.0 visible disarm (stderr line, systemMessage,
 * disarm log). Reasons are constants in this file, never payload text.
 */

import { appendFileSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMain, nativePath } from "./lib.mjs";
import { inFlightObservations } from "./run-candidates.mjs";
import {
  DEFAULT_TABLE as MODEL_TABLE,
  normalizeRole,
  resolve as resolveModel,
} from "./dispatch-model.mjs";
import { resolve as resolveEffort } from "./dispatch-effort.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

export const LOG_VERSION = 1;
export const LOG_FILE_NAME = "dispatch.jsonl";
export const DEFAULT_DIR_NAME = "agent-pipeline-telemetry";
export const ENV_ENABLE = "CLAUDE_PIPELINE_USAGE_TELEMETRY";
export const ENV_LOG_FILE = "CLAUDE_PIPELINE_DISPATCH_LOG";

/** The closed set of fields a dispatch line may carry. */
export const LOG_FIELDS = [
  "v",
  "ts",
  "session_id",
  "agent_id",
  "tool_use_id",
  "surface",
  "batch_index",
  "subagent_type",
  "role",
  "issue",
  "phase",
  "current_phase",
  "tier",
  "cost_class",
  "site",
  "model",
  "model_reason",
  "effort",
  "effort_reason",
  "session_effort",
  "transcript_path",
];

export const REASONS = {
  noDir: "the dispatch log directory could not be resolved (no git common dir and no usageTelemetry.dir)",
  append: "the dispatch log could not be appended",
  payload: "the PreToolUse payload did not parse as JSON",
};

/** The leading phase number of a status.json current_phase. */
const PHASE_OF_STATUS = /^([0-5](?:\.5)?)-/;

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

export function projectDir(env = process.env) {
  return nativePath(env.CLAUDE_PROJECT_DIR || process.cwd());
}

export function readConfig(dir) {
  const cfg = readJson(path.join(dir, "pipeline.config.json"));
  return cfg && typeof cfg === "object" && !Array.isArray(cfg) ? cfg : {};
}

/**
 * @returns {{enabled: boolean, source: string, dir: string|null}}
 * The env var wins in both directions so a single session can opt in or out without a config edit.
 */
export function telemetrySettings(cfg, env = process.env) {
  const block = cfg && typeof cfg.usageTelemetry === "object" && cfg.usageTelemetry !== null && !Array.isArray(cfg.usageTelemetry)
    ? cfg.usageTelemetry
    : {};
  const dir = typeof block.dir === "string" && block.dir.trim() !== "" ? block.dir : null;
  const raw = env[ENV_ENABLE];
  if (raw === "1" || raw === "true") return { enabled: true, source: `env ${ENV_ENABLE}`, dir };
  if (raw === "0" || raw === "false") return { enabled: false, source: `env ${ENV_ENABLE}`, dir };
  if (block.enabled === true) return { enabled: true, source: "usageTelemetry.enabled", dir };
  return { enabled: false, source: "default (off)", dir };
}

export function gitCommonDir(dir) {
  const r = spawnSync("git", ["-C", dir, "rev-parse", "--git-common-dir"], { encoding: "utf8" });
  if (r.status !== 0) return null;
  const out = (r.stdout || "").trim();
  if (!out) return null;
  const native = nativePath(out);
  return path.isAbsolute(native) ? native : path.resolve(dir, native);
}

/**
 * The telemetry directory: usageTelemetry.dir (absolute, or relative to the project root), else
 * <git common dir>/agent-pipeline-telemetry. Every worktree of one repository shares it.
 */
export function telemetryDir(dir, cfg, env = process.env) {
  const { dir: configured } = telemetrySettings(cfg, env);
  if (configured) {
    const native = nativePath(configured);
    return path.isAbsolute(native) ? native : path.resolve(dir, native);
  }
  const common = gitCommonDir(dir);
  return common ? path.join(common, DEFAULT_DIR_NAME) : null;
}

export function dispatchLogPath(dir, cfg, env = process.env) {
  if (env[ENV_LOG_FILE]) return nativePath(env[ENV_LOG_FILE]);
  const t = telemetryDir(dir, cfg, env);
  return t ? path.join(t, LOG_FILE_NAME) : null;
}

/** "4-review" -> "4", "0.5-map" -> "0.5", "2.5-design-owner-decision" -> "2.5". */
export function phaseOf(currentPhase) {
  const m = typeof currentPhase === "string" ? PHASE_OF_STATUS.exec(currentPhase) : null;
  return m ? m[1] : null;
}

/**
 * The run a dispatch belongs to. CLAUDE_PIPELINE_ACTIVE_ISSUE names it when set; otherwise the one
 * in-flight record (run-candidates.mjs's reading), or the strictly newest `updated_at` among
 * several. Nothing resolvable means null: the line is still written, with no issue.
 */
export function activeRun(pipelineDir, env = process.env, now = Date.now()) {
  let names;
  try {
    names = readdirSync(pipelineDir).filter((n) => /^(\d+|exp-[a-z0-9-]+)$/.test(n));
  } catch {
    return null;
  }
  const load = (n) => {
    const s = readJson(path.join(pipelineDir, n, "status.json"));
    return s && typeof s === "object" ? { name: n, status: s } : null;
  };
  const named = env.CLAUDE_PIPELINE_ACTIVE_ISSUE || env.PIPELINE_ACTIVE_ISSUE;
  if (named && names.includes(String(named))) {
    const hit = load(String(named));
    if (hit) return runFields(hit);
  }
  const live = names.map(load).filter((r) => r && inFlightObservations(r.status, now).inFlight);
  if (live.length === 0) return null;
  if (live.length === 1) return runFields(live[0]);
  live.sort((a, b) => Date.parse(b.status.updated_at) - Date.parse(a.status.updated_at));
  if (Date.parse(live[0].status.updated_at) === Date.parse(live[1].status.updated_at)) return null;
  return runFields(live[0]);
}

function runFields({ name, status }) {
  const issue = status.issue_number ?? status.experiment_id ?? name;
  return {
    issue: String(issue),
    phase: phaseOf(status.current_phase),
    current_phase: typeof status.current_phase === "string" ? status.current_phase : null,
    tier: typeof status.risk_tier === "string" ? status.risk_tier : null,
    cost_class: typeof status.cost_class === "string" ? status.cost_class : null,
  };
}

/** "pipeline:secops" -> "secops"; "general-purpose" -> null (not a pipeline role). */
export function roleOf(subagentType) {
  if (typeof subagentType !== "string" || subagentType === "") return null;
  const bare = subagentType.includes(":") ? subagentType.slice(subagentType.lastIndexOf(":") + 1) : subagentType;
  return normalizeRole(bare);
}

const AGENT_FILE = { design_review: "design", art_director: "art-director" };

/** model and effort from agents/<role>.md frontmatter; the values that govern when none is passed. */
export function frontmatter(pluginRoot, role) {
  if (!role) return { model: null, effort: null };
  let text;
  try {
    text = readFileSync(path.join(pluginRoot, "agents", `${AGENT_FILE[role] || role}.md`), "utf8");
  } catch {
    return { model: null, effort: null };
  }
  const m = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  const block = m ? m[1] : "";
  const field = (k) => {
    const hit = new RegExp(`^${k}:\\s*["']?([A-Za-z0-9_.\\[\\]-]+)["']?\\s*$`, "m").exec(block);
    return hit ? hit[1] : null;
  };
  return { model: field("model"), effort: field("effort") };
}

/** Copy only the allowlisted fields, in order. Anything else a caller attached is dropped. */
export function sanitize(record) {
  const out = {};
  for (const k of LOG_FIELDS) out[k] = record[k] === undefined ? null : record[k];
  return out;
}

function tokenSite(role, phase, tier, model) {
  // A dispatch site is not in the Agent call; recover it only where the table makes it unique:
  // the one row for (role, phase) whose model equals the one the call carried.
  const rows = MODEL_TABLE.filter(
    (r) => r.role === role && r.phase === phase && (r.tier === undefined || r.tier === tier) && r.model === model,
  );
  return rows.length === 1 ? rows[0].site : null;
}

/** Why the Agent call ran on the model it did. */
function agentModelReason({ role, run, passed, fm, cfg }) {
  if (!role) return passed ? "dispatch-site literal (not a pipeline role)" : "agent definition or session (not a pipeline role)";
  if (!passed) {
    return `frontmatter agents/${AGENT_FILE[role] || role}.md`;
  }
  if (run && run.tier && run.phase) {
    const site = tokenSite(role, run.phase, run.tier, passed);
    const r = resolveModel({ role, tier: run.tier, phase: run.phase, site: site || undefined, cfg });
    if (!r.error && r.model === passed) return r.rule;
  }
  return fm.model === passed ? `dispatch-site literal equal to frontmatter` : "dispatch-site literal (not from the routing table)";
}

/** One line for an Agent (or legacy Task) tool call. */
export function agentRecord(payload, ctx) {
  const input = (payload && payload.tool_input) || {};
  const subagentType = typeof input.subagent_type === "string" ? input.subagent_type : null;
  const role = roleOf(subagentType);
  const fm = frontmatter(ctx.pluginRoot, role);
  const passed = typeof input.model === "string" && input.model !== "" ? input.model : null;
  const run = ctx.run;
  const site = role && run && run.phase && passed ? tokenSite(role, run.phase, run.tier, passed) : null;
  const eff = role && run && run.tier && run.phase
    ? resolveEffort({ role, tier: run.tier, phase: run.phase, surface: "agent", cfg: ctx.cfg })
    : null;
  return sanitize({
    ...baseFields(payload, ctx),
    surface: "agent",
    subagent_type: subagentType,
    role,
    site,
    model: passed || fm.model,
    model_reason: agentModelReason({ role, run, passed, fm, cfg: ctx.cfg }),
    effort: fm.effort,
    effort_reason: role ? (eff && !eff.error ? eff.rule : "agent-surface:frontmatter") : "agent definition or session (not a pipeline role)",
  });
}

function baseFields(payload, ctx) {
  const run = ctx.run || {};
  const sessionEffort = payload && payload.effort && typeof payload.effort.level === "string" ? payload.effort.level : null;
  return {
    v: LOG_VERSION,
    ts: new Date(ctx.now).toISOString(),
    session_id: typeof payload.session_id === "string" ? payload.session_id : null,
    agent_id: null,
    tool_use_id: typeof payload.tool_use_id === "string" ? payload.tool_use_id : null,
    issue: run.issue ?? null,
    phase: run.phase ?? null,
    current_phase: run.current_phase ?? null,
    tier: run.tier ?? null,
    cost_class: run.cost_class ?? null,
    session_effort: sessionEffort,
    transcript_path: typeof payload.transcript_path === "string" ? payload.transcript_path : null,
  };
}

/**
 * The per-agent options render-panel.mjs emits, one per line, JSON-stringified:
 *   () => agent(PREAMBLE + "...", {"agentType":"pipeline:ba","model":"sonnet","effort":"medium","label":"ba-panel"}),
 * Only that JSON object is parsed; the prompt string before it is skipped, never read into a field.
 */
export function renderedAgentOptions(script) {
  const out = [];
  if (typeof script !== "string") return out;
  for (const line of script.split("\n")) {
    if (!/^\s*\(\)\s*=>\s*agent\(/.test(line)) continue;
    const start = line.lastIndexOf(', {"agentType":');
    const end = line.lastIndexOf("})");
    if (start === -1 || end <= start) continue;
    try {
      const opts = JSON.parse(line.slice(start + 2, end + 1));
      if (opts && typeof opts.agentType === "string") out.push(opts);
    } catch {
      // not a rendered line; skipped
    }
  }
  return out;
}

/** Lines for a Workflow tool call: one per agent() the rendered panel script declares. */
export function workflowRecords(payload, ctx) {
  const input = (payload && payload.tool_input) || {};
  const script = typeof input.script === "string" ? input.script : "";
  const meta = /name:\s*"phase4-(?:panel|delta)-([^"]+)"/.exec(script);
  const run = { ...(ctx.run || {}) };
  if (meta) {
    run.issue = run.issue && run.issue === meta[1] ? run.issue : meta[1];
    run.phase = "4";
  }
  const base = baseFields(payload, { ...ctx, run });
  const opts = renderedAgentOptions(script);
  if (opts.length === 0) {
    return [sanitize({ ...base, surface: "workflow", model_reason: "unparsed workflow script", effort_reason: "unparsed workflow script" })];
  }
  return opts.map((o, i) => {
    const role = roleOf(o.agentType);
    const fm = frontmatter(ctx.pluginRoot, role);
    let modelReason = o.model ? "workflow opts (not from the routing table)" : `frontmatter agents/${AGENT_FILE[role] || role}.md`;
    let effortReason = o.effort ? "workflow opts (not from the routing table)" : "session or frontmatter (no effort in opts)";
    if (role && run.tier && run.phase) {
      const m = resolveModel({ role, tier: run.tier, phase: run.phase, site: "panel-lens", cfg: ctx.cfg });
      if (!m.error && (m.model || null) === (o.model || null)) modelReason = m.model ? m.rule : `${m.rule} (no model key; frontmatter)`;
      const e = resolveEffort({ role, tier: run.tier, phase: run.phase, site: "panel-lens", surface: "workflow", cfg: ctx.cfg, costClass: run.cost_class || undefined });
      if (!e.error && e.effort === (o.effort || null)) effortReason = e.rule;
    }
    return sanitize({
      ...base,
      surface: "workflow",
      batch_index: i,
      subagent_type: o.agentType,
      role,
      site: role ? "panel-lens" : null,
      model: o.model || fm.model,
      model_reason: modelReason,
      effort: o.effort || fm.effort,
      effort_reason: effortReason,
    });
  });
}

export function recordsFromPayload(payload, ctx) {
  const tool = payload && payload.tool_name;
  if (tool === "Agent" || tool === "Task") return [agentRecord(payload, ctx)];
  if (tool === "Workflow") return workflowRecords(payload, ctx);
  return [];
}

export function appendRecords(file, records) {
  if (records.length === 0) return;
  mkdirSync(path.dirname(file), { recursive: true });
  appendFileSync(file, records.map((r) => JSON.stringify(r)).join("\n") + "\n");
}

/** The hook body, pure over its inputs so tests can drive it. Returns {code, reason}. */
export function runHook(stdinText, { env = process.env, now = Date.now(), pluginRoot = path.resolve(SCRIPT_DIR, "..") } = {}) {
  const dir = projectDir(env);
  const cfg = readConfig(dir);
  if (!telemetrySettings(cfg, env).enabled) return { code: 0, reason: null, written: 0 };
  let payload;
  try {
    payload = JSON.parse(stdinText);
  } catch {
    return { code: 3, reason: REASONS.payload, written: 0 };
  }
  const file = dispatchLogPath(dir, cfg, env);
  if (!file) return { code: 3, reason: REASONS.noDir, written: 0 };
  const run = activeRun(path.join(dir, ".pipeline"), env, now);
  const records = recordsFromPayload(payload, { cfg, run, now, pluginRoot });
  try {
    appendRecords(file, records);
  } catch {
    return { code: 3, reason: REASONS.append, written: 0 };
  }
  return { code: 0, reason: null, written: records.length };
}

function main(argv) {
  const cmd = argv[0];
  if (cmd === "hook") {
    const r = runHook(readFileSync(0, "utf8"));
    if (r.reason) process.stderr.write(`dispatch-log: disarm: ${r.reason}\n`);
    return r.code;
  }
  const dir = projectDir();
  const cfg = readConfig(dir);
  if (cmd === "path") {
    const file = dispatchLogPath(dir, cfg);
    if (!file) {
      process.stderr.write(`dispatch-log: ${REASONS.noDir}\n`);
      return 2;
    }
    process.stdout.write(`${file}\n`);
    return 0;
  }
  if (cmd === "status") {
    const s = telemetrySettings(cfg);
    process.stdout.write(`${s.enabled ? "enabled" : "disabled"} (${s.source}); log: ${dispatchLogPath(dir, cfg) || "unresolvable"}\n`);
    return 0;
  }
  process.stderr.write("usage: dispatch-log.mjs hook|path|status\n");
  return 2;
}

if (isMain("dispatch-log.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
