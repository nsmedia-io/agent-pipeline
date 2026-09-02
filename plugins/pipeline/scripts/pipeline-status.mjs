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
// #74 s1. The 24h window and the no-final-verdict term used to be spelled again, right here, as
// `age > 24 * 60 * 60 * 1000 && !r.final_verdict`. That was an independent copy: no symbol was
// shared with gate-phase-entry.mjs, so the two literals could diverge while both modules compiled
// and every suite stayed green. The predicate now comes from the leaf that already owns it.
import { inFlightObservations } from "./run-candidates.mjs";

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
      // DISPLAY value. Falls back to the file's mtime so the table's Updated column is never
      // blank. That fallback is a DIFFERENT QUANTITY from the record's own claim -- the same
      // mtime-vs-updated_at grain mismatch #74 s2 records against session-start.sh, which the
      // phase-entry guard's header had already measured in this module and which nothing tested.
      updated_at: status?.updated_at ?? mtime,
      // DECISION value, added as a sibling rather than by redefining `updated_at`, which callers
      // of --json already read. Only the record's OWN claim about itself, never the file's mtime:
      // a fresh `git clone` rewrites every mtime to checkout time, so mtime is a property of the
      // clone and not of the run. This is the field the stuck filter reads, and it is null when
      // the record makes no claim -- which is what stops an mtime standing in for one.
      updated_at_claimed: status?.updated_at ?? null,
      impacted_domains: spec?.impacted_domains ?? [],
    });
  }

  // String()-coerced on both sides. `updated_at` is schema-typed `date-time` but nothing
  // validates a status.json before this reads it, and a non-string value (a bare number, say)
  // has no .localeCompare, so the sort used to THROW and take the whole report with it -- which
  // also meant the stuck filter below was never reached on any path for such a record.
  rows.sort((a, b) =>
    String(b.updated_at ?? "").localeCompare(String(a.updated_at ?? "")),
  );
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

  // The window and the no-final-verdict term are READ, not restated: `stuck` is derived in
  // run-candidates.mjs from the same `ceilingMs` term `inFlight` uses, so the reporter and the
  // phase-entry guard cannot drift apart on the number. A mutation of the leaf's IN_FLIGHT_MS
  // reddens this module's suite and the PreToolUse gate's suite together; that is the check that
  // the unification actually bites, and it is asserted in tests/test-pipeline-status.sh.
  const now = Date.now();
  const observe = (r) =>
    inFlightObservations(
      { final_verdict: r.final_verdict, updated_at: r.updated_at_claimed },
      now,
    );
  const stuck = rows.filter((r) => observe(r).stuck);

  // WHAT DROPPING THE MTIME FALLBACK COSTS, PAID HERE RATHER THAN LEFT AS A SILENCE. Reading
  // only the record's own claim means a run that never wrote a parseable `updated_at` can no
  // longer be called stuck -- previously its file mtime stood in, so it appeared under the
  // heading above as soon as the FILE was a day old, a figure about the checkout rather than
  // about the run. Such a record is not dropped from the report: it is named here, as the
  // undatable thing it is, so "we cannot judge this one" never reads as "this one is fine".
  // `updated_at` is in status.schema.json's `required` list, so this section firing at all is
  // itself a finding.
  const undatable = rows.filter((r) => {
    const o = observe(r);
    return !o.concluded && !o.datable;
  });
  if (undatable.length) {
    lines.push("## Cannot be dated (no parseable updated_at, no final verdict)");
    lines.push("");
    for (const r of undatable) {
      lines.push(
        "- #" +
          r.issue_number +
          " at `" +
          r.current_phase +
          "`. Its `updated_at` is absent or unparseable, so neither in-flight nor stuck can be decided for it.",
      );
    }
    lines.push("");
  }

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
