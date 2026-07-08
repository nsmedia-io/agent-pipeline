#!/usr/bin/env node
// pipeline-status.mjs — summarize in-flight pipeline state in the current project.
// Scans .pipeline/<n>/status.json and reports each issue's phase, verdict, branch, PR, and last update.
//
// Output: markdown table to stdout (or --output=PATH), or a JSON payload with --json.
//
// Limitation: .pipeline/<n>/ dirs are runtime-local and gitignored, so this only
// shows pipelines active in the current checkout. Durable, cross-checkout history
// lives in the knowledge store (Phase 5 archival, knowledge/issue-archive/*.json).
//
// Usage:
//   node pipeline-status.mjs
//   node pipeline-status.mjs --output=/tmp/pipelines.md
//   node pipeline-status.mjs --json

import {
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
  existsSync,
} from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(process.cwd());
const PIPELINE_DIR = join(ROOT, ".pipeline");

// Parse args. Supports both --key=value and --key value forms.
function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const eq = a.indexOf("=");
    if (eq !== -1) {
      out[a.slice(2, eq)] = a.slice(eq + 1);
    } else {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        out[key] = next;
        i++;
      } else {
        out[key] = true;
      }
    }
  }
  return out;
}
const args = parseArgs(process.argv.slice(2));
const OUTPUT = typeof args.output === "string" ? args.output : null;
const JSON_MODE = Boolean(args.json);

function readJsonSafe(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

// Prefer the invariant risk_tier; fall back to the legacy `trivial` boolean.
function resolveTier(status, spec) {
  if (typeof status?.risk_tier === "string") return status.risk_tier;
  if (typeof spec?.risk_tier === "string") return spec.risk_tier;
  if (spec?.trivial === true) return "trivial";
  return "-";
}

function listActive() {
  if (!existsSync(PIPELINE_DIR)) return [];

  const entries = readdirSync(PIPELINE_DIR, { withFileTypes: true }).filter(
    (e) => e.isDirectory() && /^[0-9]+$/.test(e.name),
  );

  const rows = [];
  for (const e of entries) {
    const issue = e.name;
    const statusPath = join(PIPELINE_DIR, issue, "status.json");
    const specPath = join(PIPELINE_DIR, issue, "spec.json");

    const status = readJsonSafe(statusPath);
    const spec = readJsonSafe(specPath);

    let mtime = null;
    try {
      mtime = statSync(statusPath).mtime.toISOString();
    } catch {
      continue;
    }

    rows.push({
      issue_number: Number(issue),
      title: spec?.title ?? status?.ask_text?.slice(0, 60) ?? "(untitled)",
      current_phase: status?.current_phase ?? "?",
      tier: resolveTier(status, spec),
      final_verdict: status?.final_verdict ?? null,
      branch: status?.branch ?? null,
      pr_url: status?.pr_url ?? null,
      updated_at: status?.updated_at ?? mtime,
      impacted_domains: spec?.impacted_domains ?? [],
    });
  }

  rows.sort((a, b) => (b.updated_at ?? "").localeCompare(a.updated_at ?? ""));
  return rows;
}

function renderMarkdown(rows) {
  const lines = [];
  lines.push("# Active pipelines (" + ROOT + ")");
  lines.push("");
  lines.push("Generated: " + new Date().toISOString());
  lines.push("");

  if (rows.length === 0) {
    lines.push("No active pipelines here. Start one with `/pipeline <ask>`.");
    lines.push("");
    return lines.join("\n") + "\n";
  }

  lines.push("| Issue | Title | Phase | Tier | Verdict | Branch | PR | Updated |");
  lines.push("|---|---|---|---|---|---|---|---|");
  for (const r of rows) {
    const pr = r.pr_url ? "[link](" + r.pr_url + ")" : "-";
    const br = r.branch ? "`" + r.branch + "`" : "-";
    const verdict = r.final_verdict ?? "-";
    const title = (r.title ?? "").replace(/\|/g, "\\|").slice(0, 60);
    const updated = (r.updated_at ?? "").slice(0, 19).replace("T", " ");
    lines.push(
      "| #" +
        r.issue_number +
        " | " +
        title +
        " | `" +
        r.current_phase +
        "` | " +
        r.tier +
        " | " +
        verdict +
        " | " +
        br +
        " | " +
        pr +
        " | " +
        updated +
        " |",
    );
  }
  lines.push("");

  const stuck = rows.filter((r) => {
    if (!r.updated_at) return false;
    const age = Date.now() - new Date(r.updated_at).getTime();
    return age > 24 * 60 * 60 * 1000 && !r.final_verdict;
  });
  if (stuck.length) {
    lines.push("## Possibly stuck (over 24h, no final verdict)");
    lines.push("");
    for (const r of stuck) {
      lines.push(
        "- #" +
          r.issue_number +
          " at `" +
          r.current_phase +
          "`. Resume with `/pipeline --resume " +
          r.issue_number +
          "`.",
      );
    }
    lines.push("");
  }

  return lines.join("\n") + "\n";
}

function main() {
  const rows = listActive();

  if (JSON_MODE) {
    const payload = { pipelines: rows, generated_at: new Date().toISOString() };
    const out = JSON.stringify(payload, null, 2) + "\n";
    if (OUTPUT) writeFileSync(OUTPUT, out);
    process.stdout.write(out);
    return;
  }

  const md = renderMarkdown(rows);
  if (OUTPUT) writeFileSync(OUTPUT, md);
  process.stdout.write(md);
}

main();
