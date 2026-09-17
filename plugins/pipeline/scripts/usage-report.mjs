#!/usr/bin/env node
/**
 * Token use and cost per model, effort, role, phase and issue, per day and per run (#163).
 *
 *   node usage-report.mjs [--dispatch-log <file>] [--otel <file|dir>]... [--transcripts <file|dir>]...
 *                         [--session <id>]... [--issue <n>]... [--since <date>] [--until <date>]
 *                         [--window-hours <n>] [--prices <file>] [--json]
 *
 * TWO INPUTS, JOINED. The dispatch log (scripts/dispatch-log.mjs) says which issue, phase, role,
 * tier and routing rule each dispatch had. A usage source says how many tokens each request used
 * and on which model. Usage sources, either or both:
 *
 *   --otel         OTLP JSON lines as the OpenTelemetry Collector's file exporter writes them
 *                  (one ExportLogsServiceRequest or ExportMetricsServiceRequest per line). The
 *                  `claude_code.api_request` log event is used per request (tokens, cost_usd,
 *                  model, effort, agent.name, query_source, session.id, event.timestamp); the
 *                  `claude_code.token.usage` and `claude_code.cost.usage` metrics are used only for
 *                  a session with no api_request events, since they are aggregates.
 *   --transcripts  Claude Code session transcripts (~/.claude/projects/<project>/<session>.jsonl and
 *                  <session>/subagents/**\/agent-<id>.jsonl, with each agent's .meta.json). Assistant
 *                  lines carry message.model and message.usage; a message streamed over several lines
 *                  repeats one message.id, so usage is counted once per id (the line with the largest
 *                  output_tokens). Transcripts carry no cost and no effort: cost is printed only with
 *                  --prices, and effort comes from the dispatch log. Only ids, timestamps, model and
 *                  usage numbers are read into records; no message content is kept or printed.
 *
 * With neither flag: OTel files in the telemetry directory if any exist, else the transcripts named
 * by the dispatch log's transcript_path values (and their subagent files).
 *
 * THE JOIN (see joinUsage). Exact where the data allows, by time where it does not, and the method is
 * counted in the output so a reader can see how much rests on each:
 *   tool_use_id     a subagent transcript's meta.json toolUseId equals the dispatch line's tool_use_id.
 *   agent_type      same session, the latest unclaimed dispatch of that subagent type at or before
 *                   the agent's first message, inside the window.
 *   workflow_order  Workflow agents (no toolUseId): the batch's agents, ordered by first message,
 *                   matched to its lines in batch order when counts and model families agree.
 *   workflow_batch  a Workflow agent the order could not place: issue and phase from its batch,
 *                   role left unattributed.
 *   signature       OTel subagent requests: the latest dispatch in the session whose agent name,
 *                   model family and effort agree.
 *   session_time    main-thread requests: role "orchestrator", issue and phase of the latest
 *                   dispatch in the session at or before the request, inside the window.
 *   session_lookahead  main-thread requests before the session's first dispatch, when one follows
 *                   within 30 minutes: that run's issue, phase labelled "<N" (before phase N).
 * Usage that joins nothing is reported as UNATTRIBUTED, with its share, never dropped.
 */

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { isMain, nativePath } from "./lib.mjs";
import { dispatchLogPath, LOG_FILE_NAME, projectDir, readConfig, roleOf, telemetryDir } from "./dispatch-log.mjs";

const HOUR = 3600 * 1000;
export const DEFAULT_WINDOW_HOURS = 12;
const SKEW_MS = 5000;
export const LOOKAHEAD_MS = 30 * 60 * 1000;
const TOKEN_KEYS = ["input", "output", "cache_read", "cache_write"];

// ---------------------------------------------------------------- reading

function jsonLines(file) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    return { rows: [], bad: 0, missing: true };
  }
  const rows = [];
  let bad = 0;
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      rows.push(JSON.parse(line));
    } catch {
      bad++;
    }
  }
  return { rows, bad, missing: false };
}

export function loadDispatchLog(file) {
  const { rows, bad, missing } = jsonLines(file);
  const lines = rows
    .filter((r) => r && typeof r === "object" && typeof r.ts === "string")
    .map((r) => ({ ...r, t: Date.parse(r.ts) }))
    .filter((r) => Number.isFinite(r.t))
    .sort((a, b) => a.t - b.t);
  return { lines, bad, missing };
}

function walk(p, pred, out = []) {
  let st;
  try {
    st = statSync(p);
  } catch {
    return out;
  }
  if (st.isFile()) {
    if (pred(p)) out.push(p);
    return out;
  }
  for (const name of readdirSync(p)) walk(path.join(p, name), pred, out);
  return out;
}

// ---- OpenTelemetry (OTLP JSON)

function anyValue(v) {
  if (!v || typeof v !== "object") return undefined;
  if ("stringValue" in v) return v.stringValue;
  if ("intValue" in v) return Number(v.intValue);
  if ("doubleValue" in v) return Number(v.doubleValue);
  if ("boolValue" in v) return v.boolValue;
  return undefined;
}

function attrMap(list, into = {}) {
  for (const a of Array.isArray(list) ? list : []) {
    if (a && typeof a.key === "string") into[a.key] = anyValue(a.value);
  }
  return into;
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function nanoToMs(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.floor(n / 1e6) : NaN;
}

function usageRecord(fields) {
  return {
    t: NaN,
    session: null,
    agentId: null,
    agentType: null,
    toolUseId: null,
    sidechain: false,
    querySource: null,
    model: null,
    effort: null,
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cost: null,
    requests: 0,
    source: null,
    ...fields,
  };
}

/** api_request log events, and token/cost metric data points, from one OTLP JSON object. */
export function parseOtelObject(obj) {
  const events = [];
  const points = [];
  for (const rl of (obj && obj.resourceLogs) || []) {
    const res = attrMap(rl.resource && rl.resource.attributes);
    for (const sl of rl.scopeLogs || []) {
      for (const lr of sl.logRecords || []) {
        const a = attrMap(lr.attributes, { ...res });
        const body = lr.body ? anyValue(lr.body) : undefined;
        if (a["event.name"] !== "api_request" && body !== "claude_code.api_request") continue;
        const t = Date.parse(a["event.timestamp"]) || nanoToMs(lr.timeUnixNano) || nanoToMs(lr.observedTimeUnixNano);
        const agentName = typeof a["agent.name"] === "string" ? a["agent.name"] : null;
        events.push(usageRecord({
          t,
          session: a["session.id"] ?? null,
          agentType: agentName,
          querySource: a.query_source ?? null,
          sidechain: a.query_source === "subagent" || Boolean(agentName),
          model: a.model ?? null,
          effort: a.effort ?? null,
          input: num(a.input_tokens),
          output: num(a.output_tokens),
          cache_read: num(a.cache_read_tokens),
          cache_write: num(a.cache_creation_tokens),
          cost: a.cost_usd === undefined ? null : num(a.cost_usd),
          requests: 1,
          source: "otel-event",
        }));
      }
    }
  }
  for (const rm of (obj && obj.resourceMetrics) || []) {
    const res = attrMap(rm.resource && rm.resource.attributes);
    for (const sm of rm.scopeMetrics || []) {
      for (const m of sm.metrics || []) {
        if (m.name !== "claude_code.token.usage" && m.name !== "claude_code.cost.usage") continue;
        const agg = m.sum || m.gauge || {};
        const temporality = String(agg.aggregationTemporality ?? "");
        const cumulative = temporality === "2" || /CUMULATIVE/.test(temporality);
        for (const dp of agg.dataPoints || []) {
          points.push({
            metric: m.name,
            cumulative,
            attrs: attrMap(dp.attributes, { ...res }),
            start: String(dp.startTimeUnixNano ?? ""),
            t: nanoToMs(dp.timeUnixNano),
            value: num(dp.asDouble ?? dp.asInt),
          });
        }
      }
    }
  }
  return { events, points };
}

/** Metric data points to usage records. Cumulative series are differenced per series. */
export function metricRecords(points) {
  const series = new Map();
  for (const p of points) {
    const a = { ...p.attrs };
    const key = `${p.metric}|${p.start}|${JSON.stringify(Object.keys(a).sort().map((k) => [k, a[k]]))}`;
    if (!series.has(key)) series.set(key, []);
    series.get(key).push(p);
  }
  const out = [];
  for (const list of series.values()) {
    list.sort((x, y) => x.t - y.t);
    let prev = 0;
    for (const p of list) {
      const value = p.cumulative ? p.value - prev : p.value;
      prev = p.cumulative ? p.value : prev;
      if (value <= 0) continue;
      const a = p.attrs;
      const agentName = typeof a["agent.name"] === "string" ? a["agent.name"] : null;
      const rec = usageRecord({
        t: p.t,
        session: a["session.id"] ?? null,
        agentType: agentName,
        querySource: a.query_source ?? null,
        sidechain: a.query_source === "subagent" || Boolean(agentName),
        model: a.model ?? null,
        effort: a.effort ?? null,
        source: "otel-metric",
      });
      if (p.metric === "claude_code.cost.usage") rec.cost = value;
      else {
        const type = { input: "input", output: "output", cacheRead: "cache_read", cacheCreation: "cache_write" }[a.type];
        if (!type) continue;
        rec[type] = value;
      }
      out.push(rec);
    }
  }
  return out;
}

export function loadOtel(files) {
  const events = [];
  const points = [];
  let bad = 0;
  for (const f of files) {
    const r = jsonLines(f);
    bad += r.bad;
    for (const obj of r.rows) {
      const parsed = parseOtelObject(obj);
      events.push(...parsed.events);
      points.push(...parsed.points);
    }
  }
  const withEvents = new Set(events.map((e) => e.session));
  const metrics = metricRecords(points).filter((m) => !withEvents.has(m.session));
  return { records: [...events, ...metrics].filter((r) => Number.isFinite(r.t)), bad };
}

// ---- transcripts

function readMeta(jsonlFile) {
  const meta = jsonlFile.replace(/\.jsonl$/, ".meta.json");
  if (!existsSync(meta)) return {};
  try {
    const m = JSON.parse(readFileSync(meta, "utf8"));
    return {
      agentType: typeof m.agentType === "string" ? m.agentType : null,
      toolUseId: typeof m.toolUseId === "string" ? m.toolUseId : null,
    };
  } catch {
    return {};
  }
}

/** Usage records from transcript files, one per distinct message id. */
export function loadTranscripts(files) {
  const byId = new Map();
  let bad = 0;
  for (const f of files) {
    const meta = readMeta(f);
    const { rows, bad: b } = jsonLines(f);
    bad += b;
    for (const o of rows) {
      if (!o || o.type !== "assistant" || !o.message || !o.message.usage) continue;
      const u = o.message.usage;
      const model = typeof o.message.model === "string" ? o.message.model : null;
      if (model === "<synthetic>") continue;
      const id = o.message.id || `${o.requestId || ""}|${o.uuid || ""}`;
      const rec = usageRecord({
        t: Date.parse(o.timestamp),
        session: typeof o.sessionId === "string" ? o.sessionId : null,
        agentId: typeof o.agentId === "string" ? o.agentId : null,
        agentType: o.agentId ? meta.agentType ?? null : null,
        toolUseId: o.agentId ? meta.toolUseId ?? null : null,
        sidechain: o.isSidechain === true || Boolean(o.agentId),
        model,
        input: num(u.input_tokens),
        output: num(u.output_tokens),
        cache_read: num(u.cache_read_input_tokens),
        cache_write: num(u.cache_creation_input_tokens),
        requests: 1,
        source: "transcript",
      });
      const prev = byId.get(id);
      if (!prev || rec.output >= prev.output) byId.set(id, prev && !Number.isFinite(rec.t) ? { ...rec, t: prev.t } : rec);
    }
  }
  return { records: [...byId.values()].filter((r) => Number.isFinite(r.t)), bad };
}

/** A session transcript plus every subagent transcript beside it. */
export function transcriptFilesFor(sessionFile) {
  const files = existsSync(sessionFile) ? [sessionFile] : [];
  const sub = path.join(sessionFile.replace(/\.jsonl$/, ""), "subagents");
  return files.concat(walk(sub, (p) => /agent-[^/\\]+\.jsonl$/.test(p)));
}

// ---------------------------------------------------------------- joining

function family(model) {
  if (typeof model !== "string") return null;
  const m = /(opus|sonnet|haiku|fable)/i.exec(model);
  return m ? m[1].toLowerCase() : null;
}

function modelsAgree(a, b) {
  const fa = family(a);
  const fb = family(b);
  return !fa || !fb || fa === fb;
}

function sameType(usageType, line) {
  if (!usageType || !line.subagent_type) return false;
  if (usageType === line.subagent_type) return true;
  const r = roleOf(usageType);
  return Boolean(r) && r === line.role;
}

const GENERIC_AGENT_TYPES = new Set(["workflow-subagent", "custom"]);

function attributionFrom(line, method, { role = line.role || line.subagent_type || null } = {}) {
  return {
    method,
    role,
    issue: line.issue ?? null,
    phase: line.phase ?? null,
    tier: line.tier ?? null,
    dispatchEffort: line.effort ?? null,
    sessionEffort: line.session_effort ?? null,
    run: line.issue ? `#${line.issue}@${String(line.session_id || "").slice(0, 8)}` : null,
  };
}

/**
 * Attach an `attr` to every usage record. Pure over (records, lines, windowMs).
 * @returns {Array<object>} the records, each with `attr` (null when unattributed)
 */
export function joinUsage(records, lines, { windowMs = DEFAULT_WINDOW_HOURS * HOUR } = {}) {
  const bySession = new Map();
  for (const l of lines) {
    if (!bySession.has(l.session_id)) bySession.set(l.session_id, []);
    bySession.get(l.session_id).push(l);
  }
  const byToolUse = new Map();
  for (const l of lines) if (l.surface === "agent" && l.tool_use_id) byToolUse.set(l.tool_use_id, l);
  const claimed = new Set();
  const inWindow = (l, t) => l.t <= t + SKEW_MS && t - l.t <= windowMs;

  // 1. subagent transcripts, joined once per agent
  const agents = new Map();
  for (const r of records) {
    if (!r.agentId) continue;
    const k = `${r.session}|${r.agentId}`;
    const g = agents.get(k);
    if (!g) agents.set(k, { session: r.session, agentId: r.agentId, agentType: r.agentType, toolUseId: r.toolUseId, first: r.t, model: r.model, records: [r] });
    else {
      g.records.push(r);
      if (r.t < g.first) {
        g.first = r.t;
        g.model = r.model;
      }
    }
  }
  const agentAttr = new Map();
  const pendingWorkflow = new Map();
  for (const g of [...agents.values()].sort((a, b) => a.first - b.first)) {
    const k = `${g.session}|${g.agentId}`;
    const exact = g.toolUseId && byToolUse.get(g.toolUseId);
    if (exact) {
      claimed.add(exact);
      agentAttr.set(k, attributionFrom(exact, "tool_use_id"));
      continue;
    }
    const cands = (bySession.get(g.session) || []).filter((l) => inWindow(l, g.first) && !claimed.has(l));
    if (g.agentType && !GENERIC_AGENT_TYPES.has(g.agentType)) {
      const typed = cands.filter((l) => sameType(g.agentType, l) && modelsAgree(g.model, l.model));
      if (typed.length > 0) {
        const hit = typed[typed.length - 1];
        claimed.add(hit);
        agentAttr.set(k, attributionFrom(hit, "agent_type"));
        continue;
      }
    }
    const wf = cands.filter((l) => l.surface === "workflow");
    if (wf.length > 0) {
      const batchId = wf[wf.length - 1].tool_use_id || `t${wf[wf.length - 1].t}`;
      if (!pendingWorkflow.has(batchId)) pendingWorkflow.set(batchId, { lines: wf.filter((l) => (l.tool_use_id || `t${l.t}`) === batchId), groups: [] });
      pendingWorkflow.get(batchId).groups.push({ k, g });
    }
  }
  for (const { lines: batch, groups } of pendingWorkflow.values()) {
    const open = batch.filter((l) => !claimed.has(l)).sort((a, b) => (a.batch_index ?? 0) - (b.batch_index ?? 0));
    const ordered = groups.slice().sort((a, b) => a.g.first - b.g.first);
    const orderFits = open.length === ordered.length && ordered.every((x, i) => modelsAgree(x.g.model, open[i].model));
    ordered.forEach((x, i) => {
      if (orderFits) {
        claimed.add(open[i]);
        agentAttr.set(x.k, attributionFrom(open[i], "workflow_order"));
        return;
      }
      const fit = open.filter((l) => !claimed.has(l) && modelsAgree(x.g.model, l.model));
      if (fit.length === 1) {
        claimed.add(fit[0]);
        agentAttr.set(x.k, attributionFrom(fit[0], "workflow_order"));
      } else {
        agentAttr.set(x.k, attributionFrom(batch[0], "workflow_batch", { role: null }));
      }
    });
  }

  // 2. everything else, per record
  for (const r of records) {
    if (r.agentId) {
      r.attr = agentAttr.get(`${r.session}|${r.agentId}`) || null;
      continue;
    }
    const cands = (bySession.get(r.session) || []).filter((l) => inWindow(l, r.t));
    if (cands.length === 0) {
      // Main-thread work before the session's first dispatch (Phase 0 setup, the checkpoint that
      // precedes BA) belongs to the run that dispatch opens, if it follows closely. Its phase is
      // labelled "<N", before phase N's first dispatch, rather than claimed as phase N.
      const next = r.sidechain ? null : (bySession.get(r.session) || []).find((l) => l.t > r.t && l.t - r.t <= LOOKAHEAD_MS);
      r.attr = next
        ? { ...attributionFrom(next, "session_lookahead", { role: "orchestrator" }), phase: next.phase ? `<${next.phase}` : null }
        : null;
      continue;
    }
    if (r.sidechain) {
      const named = r.agentType && !GENERIC_AGENT_TYPES.has(r.agentType);
      const fit = cands.filter(
        (l) => (!named || sameType(r.agentType, l)) && modelsAgree(r.model, l.model) && (!r.effort || !l.effort || r.effort === l.effort),
      );
      r.attr = fit.length > 0 ? attributionFrom(fit[fit.length - 1], "signature") : null;
      continue;
    }
    const last = cands[cands.length - 1];
    r.attr = attributionFrom(last, "session_time", { role: r.querySource === "auxiliary" ? "auxiliary" : "orchestrator" });
  }
  return records;
}

// ---------------------------------------------------------------- aggregating

export function loadPrices(file) {
  if (!file) return null;
  const raw = JSON.parse(readFileSync(file, "utf8"));
  return raw && typeof raw === "object" ? raw : null;
}

function priceFor(prices, model) {
  if (!prices || !model) return null;
  if (prices[model]) return prices[model];
  const fam = family(model);
  return fam && prices[fam] ? prices[fam] : null;
}

export function costOf(r, prices) {
  if (r.cost !== null && r.cost !== undefined) return r.cost;
  const p = priceFor(prices, r.model);
  if (!p) return null;
  return (r.input * num(p.input) + r.output * num(p.output) + r.cache_read * num(p.cache_read) + r.cache_write * num(p.cache_write)) / 1e6;
}

export function totalTokens(r) {
  return TOKEN_KEYS.reduce((s, k) => s + num(r[k]), 0);
}

const DIMENSIONS = {
  model: (r) => r.model || "(unknown)",
  effort: (r) => effortOf(r),
  "model x effort": (r) => `${r.model || "(unknown)"} / ${effortOf(r)}`,
  role: (r) => (r.attr && r.attr.role) || "(unattributed)",
  phase: (r) => (r.attr && r.attr.phase) || "(unattributed)",
  issue: (r) => (r.attr && r.attr.issue ? `#${r.attr.issue}` : "(unattributed)"),
  "role x phase": (r) => `${(r.attr && r.attr.role) || "(unattributed)"} / ${(r.attr && r.attr.phase) || "(unattributed)"}`,
  day: (r) => new Date(r.t).toISOString().slice(0, 10),
  "day x model x effort": (r) => `${new Date(r.t).toISOString().slice(0, 10)} ${r.model || "(unknown)"} / ${effortOf(r)}`,
  run: (r) => (r.attr && r.attr.run) || "(unattributed)",
  "join method": (r) => (r.attr ? r.attr.method : "unattributed"),
};

/** Effort as the usage source reports it, else what the dispatch ran at, else the session's. */
export function effortOf(r) {
  if (r.effort) return r.effort;
  if (r.attr && r.attr.role !== "orchestrator" && r.attr.role !== "auxiliary" && r.attr.dispatchEffort) return r.attr.dispatchEffort;
  if (r.attr && r.attr.sessionEffort) return `${r.attr.sessionEffort} (session)`;
  return "(unknown)";
}

export function aggregate(records, dims = Object.keys(DIMENSIONS), prices = null) {
  const out = {};
  for (const d of dims) {
    const fn = DIMENSIONS[d];
    const rows = new Map();
    for (const r of records) {
      const k = fn(r);
      if (!rows.has(k)) rows.set(k, { key: k, requests: 0, input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0, cost: 0, costKnown: 0, costMissing: 0 });
      const row = rows.get(k);
      row.requests += r.requests;
      for (const t of TOKEN_KEYS) row[t] += num(r[t]);
      row.total += totalTokens(r);
      const c = costOf(r, prices);
      if (c === null) row.costMissing++;
      else {
        row.cost += c;
        row.costKnown++;
      }
    }
    out[d] = [...rows.values()].sort((a, b) => (d.startsWith("day") ? a.key.localeCompare(b.key) : b.total - a.total));
  }
  return out;
}

export function attribution(records) {
  let total = 0;
  let full = 0;
  let partial = 0;
  for (const r of records) {
    const n = totalTokens(r);
    total += n;
    if (r.attr && r.attr.role && r.attr.phase) full += n;
    else if (r.attr && (r.attr.issue || r.attr.phase)) partial += n;
  }
  const pct = (x) => (total ? (100 * x) / total : 0);
  return {
    total,
    attributed: full,
    attributedPct: pct(full),
    partial,
    partialPct: pct(partial),
    unattributed: total - full,
    unattributedPct: pct(total - full),
  };
}

// ---------------------------------------------------------------- output

function fmtInt(n) {
  return Math.round(n).toLocaleString("en-US");
}

function fmtCost(row) {
  if (row.costKnown === 0) return "n/a";
  return `$${row.cost.toFixed(2)}${row.costMissing ? "+" : ""}`;
}

export function formatReport({ tables, attr, notes, sources }) {
  const lines = [];
  lines.push("usage-report (agent-pipeline #163)");
  for (const s of sources) lines.push(`  source: ${s}`);
  for (const n of notes) lines.push(`  note: ${n}`);
  lines.push("");
  lines.push(`total tokens: ${fmtInt(attr.total)}`);
  lines.push(`attributed to a role and phase: ${fmtInt(attr.attributed)} (${attr.attributedPct.toFixed(1)}%)`);
  lines.push(`unattributed to a role and phase: ${fmtInt(attr.unattributed)} (${attr.unattributedPct.toFixed(1)}%), of which ${fmtInt(attr.partial)} (${attr.partialPct.toFixed(1)}%) still carry an issue or phase`);
  for (const [dim, rows] of Object.entries(tables)) {
    lines.push("");
    lines.push(`by ${dim}`);
    const header = ["", "requests", "input", "output", "cache_read", "cache_write", "total", "share", "cost"];
    const body = rows.map((r) => [
      r.key,
      fmtInt(r.requests),
      fmtInt(r.input),
      fmtInt(r.output),
      fmtInt(r.cache_read),
      fmtInt(r.cache_write),
      fmtInt(r.total),
      `${attr.total ? ((100 * r.total) / attr.total).toFixed(1) : "0.0"}%`,
      fmtCost(r),
    ]);
    const widths = header.map((h, i) => Math.max(h.length, ...body.map((b) => b[i].length)));
    const row = (cells) => "  " + cells.map((c, i) => (i === 0 ? c.padEnd(widths[i]) : c.padStart(widths[i]))).join("  ");
    lines.push(row(header));
    for (const b of body) lines.push(row(b));
  }
  lines.push("");
  lines.push("cost: from OTel cost_usd where present, else --prices; n/a means neither; a trailing + means some rows lacked a price.");
  return lines.join("\n") + "\n";
}

// ---------------------------------------------------------------- CLI

export function parseArgs(argv) {
  const a = { otel: [], transcripts: [], session: [], issue: [], json: false, windowHours: DEFAULT_WINDOW_HOURS };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => {
      if (i + 1 >= argv.length) throw new Error(`${k} needs a value`);
      return argv[++i];
    };
    if (k === "--dispatch-log") a.dispatchLog = nativePath(v());
    else if (k === "--otel") a.otel.push(nativePath(v()));
    else if (k === "--transcripts") a.transcripts.push(nativePath(v()));
    else if (k === "--session") a.session.push(v());
    else if (k === "--issue") a.issue.push(String(v()).replace(/^#/, ""));
    else if (k === "--since") a.since = Date.parse(v());
    else if (k === "--until") a.until = Date.parse(v());
    else if (k === "--window-hours") a.windowHours = Number(v());
    else if (k === "--prices") a.prices = nativePath(v());
    else if (k === "--json") a.json = true;
    else throw new Error(`unknown argument ${k}`);
  }
  if (!Number.isFinite(a.windowHours) || a.windowHours <= 0) throw new Error("--window-hours must be a positive number");
  return a;
}

export function buildReport(args, env = process.env) {
  const notes = [];
  const sources = [];
  const dir = projectDir(env);
  const cfg = readConfig(dir);
  const logFile = args.dispatchLog || dispatchLogPath(dir, cfg, env);
  const log = logFile ? loadDispatchLog(logFile) : { lines: [], bad: 0, missing: true };
  if (log.missing) notes.push(`no dispatch log at ${logFile || "(unresolvable path)"}; every record is unattributed`);
  else sources.push(`dispatch log ${logFile} (${log.lines.length} dispatches${log.bad ? `, ${log.bad} unparsable lines skipped` : ""})`);

  let otelFiles = args.otel.flatMap((p) => walk(p, (f) => f.endsWith(".jsonl") && path.basename(f) !== LOG_FILE_NAME));
  let transcriptFiles = args.transcripts.flatMap((p) => (statSafe(p)?.isFile() ? transcriptFilesFor(p) : walk(p, (f) => f.endsWith(".jsonl"))));
  const scopeToLog = args.otel.length === 0 && args.transcripts.length === 0;
  if (scopeToLog) {
    const tdir = telemetryDir(dir, cfg, env);
    otelFiles = tdir ? walk(tdir, (f) => f.endsWith(".jsonl") && path.basename(f) !== LOG_FILE_NAME) : [];
    if (otelFiles.length === 0) {
      notes.push(`no OpenTelemetry export files in ${tdir || "(no telemetry dir)"}; using the transcripts the dispatch log names`);
      const sessions = [...new Set(log.lines.map((l) => l.transcript_path).filter(Boolean))];
      transcriptFiles = sessions.flatMap((p) => transcriptFilesFor(nativePath(p)));
    }
  }
  let records = [];
  if (otelFiles.length) {
    const o = loadOtel(otelFiles);
    records.push(...o.records);
    sources.push(`OpenTelemetry: ${otelFiles.length} file(s), ${o.records.length} usage records${o.bad ? `, ${o.bad} unparsable lines` : ""}`);
  }
  if (transcriptFiles.length) {
    const t = loadTranscripts(transcriptFiles);
    records.push(...t.records);
    sources.push(`transcripts: ${transcriptFiles.length} file(s), ${t.records.length} distinct messages${t.bad ? `, ${t.bad} unparsable lines` : ""}`);
  }
  if (records.length === 0) notes.push("no usage records found");

  if (scopeToLog) {
    const logged = new Set(log.lines.map((l) => l.session_id));
    records = records.filter((r) => logged.has(r.session));
  }
  if (args.session.length) records = records.filter((r) => args.session.includes(r.session));
  if (Number.isFinite(args.since)) records = records.filter((r) => r.t >= args.since);
  if (Number.isFinite(args.until)) records = records.filter((r) => r.t < args.until);

  joinUsage(records, log.lines, { windowMs: args.windowHours * HOUR });
  if (args.issue.length) records = records.filter((r) => r.attr && args.issue.includes(String(r.attr.issue)));
  const prices = loadPrices(args.prices);
  if (!records.some((r) => r.cost !== null) && !prices) notes.push("no cost in the usage source and no --prices file; cost prints n/a");
  return { tables: aggregate(records, undefined, prices), attr: attribution(records), notes, sources, records };
}

function statSafe(p) {
  try {
    return statSync(p);
  } catch {
    return null;
  }
}

function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (e) {
    process.stderr.write(`usage-report: ${e.message}\n`);
    return 2;
  }
  let report;
  try {
    report = buildReport(args);
  } catch (e) {
    process.stderr.write(`usage-report: ${e.message}\n`);
    return 1;
  }
  if (args.json) {
    const { records, ...rest } = report;
    process.stdout.write(JSON.stringify({ ...rest, records: records.length }, null, 2) + "\n");
  } else {
    process.stdout.write(formatReport(report));
  }
  return 0;
}

if (isMain("usage-report.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
