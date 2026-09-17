#!/usr/bin/env node
/**
 * render-issue-body.mjs -- the tracker issue body as a RENDER of spec.json, and the check that
 * the published body still matches it (#164 row 23).
 *
 *   node render-issue-body.mjs --spec <spec.json>                       print the body
 *   node render-issue-body.mjs --spec <spec.json> --compare <issue>     diff against `gh issue view`
 *   node render-issue-body.mjs --spec <spec.json> --body-file <file>    diff against a saved body
 *
 * WHY. agents/ba.md step 8 told BA to render the body by hand and, on every round after the first,
 * to render requirements and acceptance criteria again and diff them against the published body.
 * The recorded failure: a spec reworked over four rounds had its body regenerated at round 4 and
 * spec.json left at round 3, so a ruling every downstream agent read from the artifact was lost
 * for two rounds. Both copies were well formed, which is why nothing surfaced it.
 *
 * THE COMPARE READS ONLY WHAT IT RENDERS: the items under `## Requirements` and
 * `## Acceptance criteria`, list markers and checkboxes stripped, whitespace collapsed. Other
 * prose in the published body is not the artifact's and is not compared. A missing section is
 * drift, not a pass.
 *
 * EXIT. 0 rendered, or the body matches. 2 drift (every difference printed). 1 usage, an
 * unreadable spec, or a body that could not be fetched.
 */

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { isMain, nativePath } from "./lib.mjs";

export const SECTIONS = [
  ["requirements", "Requirements"],
  ["acceptance_criteria", "Acceptance criteria"],
];

const flat = (s) => String(s ?? "").replace(/\s+/g, " ").trim();
const list = (v) => (Array.isArray(v) ? v.map(flat).filter(Boolean) : []);

export function renderBody(spec) {
  const out = [];
  if (flat(spec.problem)) out.push("## Problem", "", flat(spec.problem), "");
  out.push("## Requirements", "", ...list(spec.requirements).map((r, i) => `${i + 1}. ${r}`), "");
  out.push("## Acceptance criteria", "", ...list(spec.acceptance_criteria).map((a) => `- [ ] ${a}`), "");
  if (list(spec.impacted_domains).length) out.push("## Impacted domains", "", list(spec.impacted_domains).join(", "), "");
  if (list(spec.out_of_scope).length) out.push("## Out of scope", "", ...list(spec.out_of_scope).map((o) => `- ${o}`), "");
  const meta = [spec.risk_tier && `Risk tier: ${flat(spec.risk_tier)}.`, spec.cost_class && `Cost class: ${flat(spec.cost_class)}.`].filter(Boolean);
  if (meta.length) out.push(meta.join(" "), "");
  out.push("<!-- Rendered from spec.json by scripts/render-issue-body.mjs. Edit spec.json, then re-render; never edit this body alone. -->");
  return out.join("\n") + "\n";
}

/** The items under a `## <heading>` section, or null when the section is absent. */
export function sectionItems(body, heading) {
  const lines = String(body ?? "").replace(/\r\n/g, "\n").split("\n");
  const start = lines.findIndex((l) => new RegExp(`^##\\s+${heading}\\s*$`, "i").test(l.trim()));
  if (start === -1) return null;
  const items = [];
  let inItem = false;
  // Any heading ends the section, `###` included: a list under a sub-heading is not an item here.
  for (let i = start + 1; i < lines.length && !/^#{1,6}\s/.test(lines[i]); i++) {
    const m = /^\s*(?:\d+[.)]|[-*+])\s+(?:\[[ xX]\]\s+)?(.*)$/.exec(lines[i]);
    if (m) {
      items.push(flat(m[1]));
      inItem = true;
    } else if (inItem && /^\s+\S/.test(lines[i])) {
      items[items.length - 1] = flat(`${items[items.length - 1]} ${lines[i]}`); // an indented wrap of the item above
    } else {
      inItem = false;
    }
  }
  return items;
}

/** Every difference between the spec and a published body, as strings. Empty means in sync. */
export function compareBody(spec, body) {
  const drift = [];
  for (const [key, heading] of SECTIONS) {
    const want = list(spec[key]);
    const got = sectionItems(body, heading);
    if (got === null) {
      drift.push(`${heading}: section missing from the published body`);
      continue;
    }
    const n = Math.max(want.length, got.length);
    for (let i = 0; i < n; i++) {
      if (want[i] === got[i]) continue;
      if (got[i] === undefined) drift.push(`${heading} #${i + 1}: in spec.json, missing from the body: ${want[i]}`);
      else if (want[i] === undefined) drift.push(`${heading} #${i + 1}: in the body, not in spec.json: ${got[i]}`);
      else drift.push(`${heading} #${i + 1}: spec.json says: ${want[i]}\n  the body says:   ${got[i]}`);
    }
  }
  return drift;
}

const USAGE = "usage: node render-issue-body.mjs --spec <spec.json> [--compare <issue> | --body-file <file>]\n";

export function main(argv, { out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s) } = {}) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (["--spec", "--compare", "--body-file"].includes(k) && argv[i + 1] !== undefined && !argv[i + 1].startsWith("--")) a[k.slice(2)] = argv[++i];
    else {
      err(`unknown or incomplete argument: ${k}\n${USAGE}`);
      return 1;
    }
  }
  if (!a.spec || (a.compare && a["body-file"])) {
    err(USAGE);
    return 1;
  }
  let spec;
  try {
    spec = JSON.parse(readFileSync(nativePath(a.spec), "utf8"));
  } catch (e) {
    err(`cannot read --spec ${a.spec}: ${e.message}\n`);
    return 1;
  }
  if (!spec || typeof spec !== "object") {
    err(`--spec ${a.spec} is not a JSON object\n`);
    return 1;
  }
  if (!a.compare && !a["body-file"]) {
    out(renderBody(spec));
    return 0;
  }
  let body;
  if (a["body-file"]) {
    try {
      body = readFileSync(nativePath(a["body-file"]), "utf8");
    } catch (e) {
      err(`cannot read --body-file ${a["body-file"]}: ${e.message}\n`);
      return 1;
    }
  } else {
    if (!/^\d+$/.test(a.compare)) {
      err(`--compare takes an issue number, got ${JSON.stringify(a.compare)}\n`);
      return 1;
    }
    const r = spawnSync("gh", ["issue", "view", a.compare, "--json", "body", "-q", ".body"], { encoding: "utf8" });
    if (r.error || r.status !== 0) {
      // An unfetched body is not a matching body.
      err(`gh issue view ${a.compare} failed (${r.error ? r.error.code : `exit ${r.status}`}): ${(r.stderr || "").trim()}\n`);
      return 1;
    }
    body = r.stdout;
  }
  const drift = compareBody(spec, body);
  if (drift.length === 0) {
    out(`IN SYNC: ${list(spec.requirements).length} requirement(s) and ${list(spec.acceptance_criteria).length} acceptance criteria match the published body\n`);
    return 0;
  }
  out(`DRIFT: ${drift.length} difference(s). spec.json is the source: re-render the body from it and publish that.\n`);
  for (const d of drift) out(`  ${d}\n`);
  return 2;
}

// Self-run only as a real CLI entry: an eval that imports this module with its own path in argv[1]
// must not run the CLI (the hazard voice-lint.mjs documents at its foot).
const evalEntry = process.execArgv.some((x) => x === "-e" || x === "--eval" || x === "--input-type=module" || /^--eval=/.test(x));
if (isMain("render-issue-body.mjs") && !evalEntry) process.exit(main(process.argv.slice(2)));
