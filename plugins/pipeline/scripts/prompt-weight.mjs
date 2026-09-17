#!/usr/bin/env node
// Measure what the pipeline puts in front of a model, in bytes and ESTIMATED tokens (C2).
//
//   node prompt-weight.mjs [--plugin-root <dir>] [--fixture <issue-artifact-dir>] [--json]
//
// Reports:
//   1. orchestrator: the command files, and commands/pipeline.md split at its `## ` headings, so a
//      per-phase load can be read off (today the slash command loads the whole file in every phase);
//   2. agents: each agent definition under agents/;
//   3. with --fixture: the rendered Phase 4 panel prompts for that issue (per role: static prefix,
//      run data, total), the cacheable static prefix, and the run data encoded as JSON vs TOON;
//      then every JSON artifact in the fixture (spec.json, impl-report.json, peer-review*.json,
//      review*.json) as compact JSON vs TOON, whole file and per uniform (tabular) array.
//
// TOKEN COUNTS ARE AN ESTIMATE: ceil(characters / 4). No tokenizer is loaded (the plugin has no
// dependencies), so a real count can differ in either direction, and most for punctuation-dense
// text. Bytes are exact (UTF-8). Every figure describes the files it was run on; name that
// population when quoting one. The JSON baseline is COMPACT JSON (JSON.stringify with no
// indentation), the cheapest JSON form, so a TOON saving is not flattered by whitespace; the
// artifact totals also report the files as stored on disk.
//
// The fixture is read, never written. A status.json whose risk_tier is not one of the plugin's
// three tiers (a consumer's own tier name) is rendered at architectural, and roles with no entry in
// panel-lenses.json (a consumer's own reviewers) are skipped; both are named in the report.

import { readFileSync, readdirSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMain } from "./lib.mjs";
import { encode as toon } from "./toon.mjs";
import { assemble, loadLenses, openBlockerMap } from "./render-panel.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ESTIMATOR = "ceil(chars/4), an estimate, not a tokenizer count";

export function weigh(text) {
  return { bytes: Buffer.byteLength(text, "utf8"), est_tokens: Math.ceil(text.length / 4) };
}

function saving(json, toonText) {
  const j = weigh(json);
  const t = weigh(toonText);
  return {
    json_bytes: j.bytes,
    toon_bytes: t.bytes,
    json_est_tokens: j.est_tokens,
    toon_est_tokens: t.est_tokens,
    saved_bytes: j.bytes - t.bytes,
    saved_pct: j.bytes === 0 ? 0 : Math.round((1000 * (j.bytes - t.bytes)) / j.bytes) / 10,
  };
}

/** Sections of a markdown file at `## ` headings (fenced blocks respected). */
export function sections(markdown) {
  const out = [];
  let title = "(before the first ## heading)";
  let buf = [];
  let fence = false;
  const flush = () => {
    const text = buf.join("\n");
    if (text.trim()) out.push({ title, ...weigh(text) });
  };
  for (const line of markdown.split("\n")) {
    if (/^\s*```/.test(line)) fence = !fence;
    if (!fence && /^## /.test(line)) {
      flush();
      title = line.slice(3).trim();
      buf = [];
    }
    buf.push(line);
  }
  flush();
  return out;
}

function mdFiles(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isFile() && d.name.endsWith(".md"))
    .map((d) => d.name)
    .sort();
}

export function orchestratorWeight(pluginRoot) {
  const dir = path.join(pluginRoot, "commands");
  const files = mdFiles(dir).map((f) => ({ file: `commands/${f}`, ...weigh(readFileSync(path.join(dir, f), "utf8")) }));
  const md = readFileSync(path.join(dir, "pipeline.md"), "utf8");
  return { files, pipeline_sections: sections(md) };
}

export function agentWeight(pluginRoot) {
  const dir = path.join(pluginRoot, "agents");
  return mdFiles(dir).map((f) => ({ file: `agents/${f}`, ...weigh(readFileSync(path.join(dir, f), "utf8")) }));
}

/** Uniform arrays of objects (TOON's tabular form) anywhere in a value, with their JSON path. */
export function tabularArrays(value, at = "$", out = []) {
  if (Array.isArray(value)) {
    const first = value[0];
    const isRow = (x) => x && typeof x === "object" && !Array.isArray(x) && Object.values(x).every((v) => v === null || typeof v !== "object");
    if (value.length >= 2 && value.every(isRow)) {
      const keys = Object.keys(first).sort().join(",");
      if (keys && value.every((x) => Object.keys(x).sort().join(",") === keys)) out.push({ path: at, value });
    }
    value.forEach((v, i) => {
      if (v && typeof v === "object") tabularArrays(v, `${at}[${i}]`, out);
    });
  } else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) if (v && typeof v === "object") tabularArrays(v, `${at}.${k}`, out);
  }
  return out;
}

const ARTIFACT = /^(spec|impl-report|map|design|tasks)\.json$|^(peer-review|review)(\.[A-Za-z_-]+)?\.json$/;

export function artifactWeight(fixture) {
  const rows = [];
  const tables = [];
  for (const f of readdirSync(fixture).filter((n) => ARTIFACT.test(n)).sort()) {
    const raw = readFileSync(path.join(fixture, f), "utf8");
    const value = JSON.parse(raw);
    rows.push({ file: f, disk_bytes: weigh(raw).bytes, ...saving(JSON.stringify(value), toon(value)) });
    for (const t of tabularArrays(value)) {
      const body = toon(t.value);
      tables.push({ file: f, path: t.path, items: t.value.length, ...saving(JSON.stringify(t.value), body) });
    }
  }
  const sum = (list) => {
    const s = list.reduce((a, r) => ({ json: a.json + r.json_bytes, toon: a.toon + r.toon_bytes, jt: a.jt + r.json_est_tokens, tt: a.tt + r.toon_est_tokens }), { json: 0, toon: 0, jt: 0, tt: 0 });
    return {
      json_bytes: s.json, toon_bytes: s.toon, json_est_tokens: s.jt, toon_est_tokens: s.tt,
      saved_bytes: s.json - s.toon, saved_pct: s.json === 0 ? 0 : Math.round((1000 * (s.json - s.toon)) / s.json) / 10,
    };
  };
  const disk = rows.reduce((a, r) => a + r.disk_bytes, 0);
  const toonBytes = rows.reduce((a, r) => a + r.toon_bytes, 0);
  const asStored = { disk_bytes: disk, toon_bytes: toonBytes, saved_pct: disk === 0 ? 0 : Math.round((1000 * (disk - toonBytes)) / disk) / 10 };
  tables.sort((a, b) => b.json_bytes - a.json_bytes);
  return { files: rows, tables, totals: { files: sum(rows), tables: sum(tables), as_stored: asStored } };
}

function readJson(file) {
  return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : null;
}

export function panelWeight(fixture, pluginRoot) {
  const status = readJson(path.join(fixture, "status.json")) || {};
  const lenses = loadLenses(pluginRoot);
  const notes = [];
  let tier = status.risk_tier;
  if (!["trivial", "standard", "architectural"].includes(tier)) {
    notes.push(`risk_tier ${JSON.stringify(tier)} is not a plugin tier; rendered at architectural`);
    tier = "architectural";
  }
  const seated = Array.isArray(status.panel_roles) && status.panel_roles.length ? status.panel_roles : ["ba", "dev", "qa", "secops"];
  const skipped = seated.filter((r) => !lenses[r]);
  if (skipped.length) notes.push(`roles with no plugin lens skipped: ${skipped.join(", ")}`);
  const roles = seated.filter((r) => lenses[r]);
  // A merged peer-review record from the fixture's shards (or its merged file), for a delta render.
  const merged = readJson(path.join(fixture, "peer-review.json")) || {};
  for (const f of readdirSync(fixture)) {
    const m = /^peer-review\.([A-Za-z_-]+)\.json$/.exec(f);
    if (m && !merged[m[1]]) merged[m[1]] = readJson(path.join(fixture, f));
  }
  const cleanStatus = { issue_number: status.issue_number ?? 0, risk_tier: tier, panel_roles: roles };
  if (["product-money", "product", "tooling"].includes(status.cost_class)) cleanStatus.cost_class = status.cost_class;
  const common = {
    status: cleanStatus,
    worktree: "/work/fixture-worktree",
    head: typeof status.head === "string" && /^[0-9a-f]{7,40}$/.test(status.head) ? status.head : "f".repeat(40),
    pluginRoot: "/plugins/pipeline",
    lenses,
    preambleMarkdown: readFileSync(path.join(pluginRoot, "commands", "pipeline.md"), "utf8"),
  };
  const full = assemble(common);
  const deltaRoles = roles.filter((r) => merged[r]).join(" ") || roles[0];
  const delta = assemble({ ...common, delta: deltaRoles, firstRoundHead: "e".repeat(40), openBlockers: openBlockerMap(merged), peerReview: merged, peerReviewPath: "/work/fixture-worktree/.pipeline/peer-review.json" });
  const describe = (a) => ({
    static_preamble: weigh(a.preamble),
    dispatches: a.dispatches.map((d) => ({
      role: d.role,
      static_prefix: weigh(a.preamble + d.lensText),
      run_data: weigh(d.runData),
      prompt: weigh(d.prompt),
      run_data_json_vs_toon: saving(JSON.stringify(d.runValues), toon(d.runValues)),
    })),
  });
  return { notes, roles, full: describe(full), delta: { roles: deltaRoles.split(" "), ...describe(delta) } };
}

export function report({ pluginRoot, fixture }) {
  const out = { estimator: ESTIMATOR, plugin_root: pluginRoot, orchestrator: orchestratorWeight(pluginRoot), agents: agentWeight(pluginRoot) };
  if (fixture) {
    out.fixture = path.basename(path.resolve(fixture));
    out.panel = panelWeight(fixture, pluginRoot);
    out.artifacts = artifactWeight(fixture);
  }
  return out;
}

const row = (label, w) => `  ${label.padEnd(58)} ${String(w.bytes).padStart(8)} B ${String(w.est_tokens).padStart(7)} est.tok`;
const cmp = (label, s) =>
  `  ${label.padEnd(58)} JSON ${String(s.json_bytes).padStart(8)} B / ${String(s.json_est_tokens).padStart(7)} est.tok   TOON ${String(s.toon_bytes).padStart(8)} B / ${String(s.toon_est_tokens).padStart(7)} est.tok   saved ${s.saved_pct}%`;

export function formatText(r) {
  const lines = [`Prompt weight. Tokens are estimated: ${r.estimator}.`, "", "Orchestrator command files (the /pipeline command loads pipeline.md whole in every phase):"];
  for (const f of r.orchestrator.files) lines.push(row(f.file, f));
  lines.push("", "commands/pipeline.md by `## ` section (what a per-phase split would load):");
  for (const s of r.orchestrator.pipeline_sections) lines.push(row(s.title.slice(0, 58), s));
  lines.push("", "Agent definitions:");
  for (const a of r.agents) lines.push(row(a.file, a));
  if (r.panel) {
    lines.push("", `Fixture ${r.fixture}: rendered Phase 4 prompts`);
    for (const n of r.panel.notes) lines.push(`  note: ${n}`);
    for (const [name, p] of [["full panel", r.panel.full], [`delta (${r.panel.delta.roles.join(", ")})`, r.panel.delta]]) {
      lines.push(`  ${name}: cacheable static preamble ${p.static_preamble.bytes} B / ${p.static_preamble.est_tokens} est.tok, shared by every role`);
      for (const d of p.dispatches) {
        lines.push(row(`${d.role}: static prefix (preamble + lens)`, d.static_prefix));
        lines.push(row(`${d.role}: run data`, d.run_data));
        lines.push(cmp(`${d.role}: run data values`, d.run_data_json_vs_toon));
      }
    }
    lines.push("", `Fixture ${r.fixture}: artifacts, compact JSON vs TOON`);
    for (const f of r.artifacts.files) lines.push(cmp(f.file, f));
    lines.push(cmp("TOTAL (whole files)", r.artifacts.totals.files));
    const st = r.artifacts.totals.as_stored;
    lines.push(`  as stored on disk (pretty JSON): ${st.disk_bytes} B vs TOON ${st.toon_bytes} B, saved ${st.saved_pct}%`);
    const top = r.artifacts.tables.slice(0, 10);
    if (r.artifacts.tables.length > top.length) lines.push(`  uniform arrays: the ${top.length} largest of ${r.artifacts.tables.length} (--json lists all)`);
    for (const t of top) lines.push(cmp(`${t.file} ${t.path} (${t.items} rows)`.slice(0, 58), t));
    lines.push(cmp("TOTAL (uniform arrays only)", r.artifacts.totals.tables));
  }
  return lines.join("\n") + "\n";
}

function main(argv) {
  const args = { pluginRoot: path.resolve(HERE, ".."), fixture: null, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--plugin-root") args.pluginRoot = path.resolve(argv[++i]);
    else if (a === "--fixture") args.fixture = argv[++i];
    else if (a === "--json") args.json = true;
    else {
      console.error(`prompt-weight: unknown argument: ${a}`);
      process.exit(1);
    }
  }
  if (args.fixture && !existsSync(args.fixture)) {
    console.error(`prompt-weight: no fixture directory at ${args.fixture}`);
    process.exit(1);
  }
  try {
    const r = report(args);
    process.stdout.write(args.json ? JSON.stringify(r, null, 2) + "\n" : formatText(r));
  } catch (e) {
    console.error(`prompt-weight: ${e.message}`);
    process.exit(2);
  }
}

if (isMain("prompt-weight.mjs")) main(process.argv.slice(2));
