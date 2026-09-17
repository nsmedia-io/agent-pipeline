#!/usr/bin/env node
// Render the Phase 4 panel Workflow script from status.json (#157).
//
// The orchestrator used to hand-write one Workflow script per panel: a ~3 KB preamble carrying
// the worktree path, artifact dir, reviewed sha and plugin root, one lens string per role in
// panel_roles, and per-role model/effort values read out of two resolvers. Seven such scripts
// over four issues produced one mistyped reviewed sha (the panel noticed; that was luck) and one
// parse error (an apostrophe inside a single-quoted lens). This script makes every one of those
// values COMPUTED:
//
//   - the reviewed sha is `git rev-parse HEAD` of the worktree, never typed;
//   - the preamble is sliced out of commands/pipeline.md between two HTML-comment markers, so
//     the prose the agents read is the prose the command file documents, with no second copy;
//   - the lens per role comes from scripts/panel-lenses.json, the one lens table;
//   - model and effort come from dispatch-model.mjs / dispatch-effort.mjs for (role, tier, 4,
//     panel-lens, workflow), exactly as the dispatch sites are told to resolve them;
//   - every string is emitted through JSON.stringify, so no quoting class can break the script;
//   - each prompt is static text first and run data last, so a prompt cache can reuse the static
//     part (see CACHE-FRIENDLY ASSEMBLY below).
//
// Usage:
//   node render-panel.mjs --status <status.json> --worktree <path> [--plugin-root <dir>]
//                         [--delta "<roles>" --first-round-head <sha> [--peer-review <file>]]
//                         [--out <file>] [--check]
//
//   --delta        space-separated roles to re-dispatch on a delta round; the preamble then
//                  carries the delta paragraph and only those roles are rendered. Requires
//                  --first-round-head, the HEAD the FIRST round's panel reviewed. --peer-review names
//                  the merged peer-review.json whose open_blocker_ids each delta lens lists.
//   --check        after rendering, write the script to a temp .mjs and run `node --check` on
//                  it; exit non-zero if it does not parse. The test suite uses this; the
//                  orchestrator should too.
//
// Output: the Workflow script on stdout (or --out). Pass it verbatim as the Workflow tool's
// `script` argument. The rendered script's `meta` is a pure literal, as the tool requires.
//
// Fail direction: CLOSED on every input this script owns. A missing marker, an unknown role, a
// worktree whose HEAD cannot be read, or a resolver error for a role that should have one all
// exit non-zero with the reason named. A panel rendered from a guessed sha is the defect this
// script exists to remove, so it never guesses.

import { readFileSync, writeFileSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { isMain as isMainScript } from "./lib.mjs";
import { resolve as resolveModel } from "./dispatch-model.mjs";
import { resolve as resolveEffort } from "./dispatch-effort.mjs";
import { openBlockers as listOpenBlockers } from "./materiality.mjs";
import { encode as toon } from "./toon.mjs";

export const PREAMBLE_BEGIN = "<!-- BEGIN PHASE4-PREAMBLE -->";
export const PREAMBLE_END = "<!-- END PHASE4-PREAMBLE -->";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_PLUGIN_ROOT = path.resolve(HERE, "..");

export function parseArgs(argv) {
  const args = { delta: null, firstRoundHead: null, peerReview: null, out: null, check: false, pluginRoot: DEFAULT_PLUGIN_ROOT };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--status") args.status = argv[++i];
    else if (a === "--worktree") args.worktree = argv[++i];
    else if (a === "--plugin-root") args.pluginRoot = argv[++i];
    else if (a === "--delta") args.delta = argv[++i];
    else if (a === "--first-round-head") args.firstRoundHead = argv[++i];
    else if (a === "--peer-review") args.peerReview = argv[++i];
    else if (a === "--out") args.out = argv[++i];
    else if (a === "--check") args.check = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!args.status) throw new Error("--status <status.json> is required");
  if (!args.worktree) throw new Error("--worktree <path> is required");
  if (args.delta !== null && !args.firstRoundHead) {
    throw new Error("--delta requires --first-round-head <sha> (the HEAD the first round's panel reviewed)");
  }
  return args;
}

/** Slice the preamble out of commands/pipeline.md: between the markers, fences stripped. */
export function extractPreamble(markdown) {
  const b = markdown.indexOf(PREAMBLE_BEGIN);
  const e = markdown.indexOf(PREAMBLE_END);
  if (b === -1 || e === -1 || e < b) {
    throw new Error(`commands/pipeline.md carries no ${PREAMBLE_BEGIN} ... ${PREAMBLE_END} block`);
  }
  const inner = markdown.slice(b + PREAMBLE_BEGIN.length, e);
  const lines = inner.split("\n");
  // Drop blank lines and fence lines at either edge; keep everything in between verbatim.
  while (lines.length && /^\s*(```.*)?\s*$/.test(lines[0])) lines.shift();
  while (lines.length && /^\s*(```.*)?\s*$/.test(lines[lines.length - 1])) lines.pop();
  const text = lines.join("\n").trim();
  if (text.length < 200) throw new Error("the PHASE4-PREAMBLE block is implausibly short; refusing to render");
  return text;
}

export function readHead(worktree) {
  const r = spawnSync("git", ["-C", worktree, "rev-parse", "HEAD"], { encoding: "utf8" });
  if (r.status !== 0 || !/^[0-9a-f]{40}\s*$/.test(r.stdout || "")) {
    throw new Error(`cannot read HEAD of ${worktree}: ${(r.stderr || r.stdout || "").trim()}`);
  }
  return r.stdout.trim();
}

export function loadLenses(pluginRoot) {
  const f = path.join(pluginRoot, "scripts", "panel-lenses.json");
  const j = JSON.parse(readFileSync(f, "utf8"));
  if (!j || typeof j.roles !== "object") throw new Error(`${f}: no roles table`);
  return j.roles;
}

// CACHE-FRIENDLY ASSEMBLY (C2). Every dispatched prompt is STATIC TEXT FIRST and RUN DATA LAST:
//
//   [delta paragraph] preamble run-data-note | lens     | RUN DATA (issue, paths, sha, blockers)
//   shared by every role of the panel        | per role | per dispatch
//
// The placeholders the command file and the lens table use (<issue>, <WORKTREE_PATH>, <HEAD_SHA>,
// <REVIEWED_SHA>, <ARTIFACT_DIR>, <FIRST_ROUND_HEAD>, ${CLAUDE_PLUGIN_ROOT}) are NOT substituted
// into the static text; they are bound once, in the RUN DATA block at the end. The static part
// therefore carries no issue number, sha, worktree or plugin path, so it is byte-identical across
// the roles of one panel, across rounds, and across issues on the same plugin version, which is
// what lets a prompt cache reuse it. test-render-panel.sh pins that property. Substituting a value
// back into the static text (or prepending anything per-run) breaks the cache silently: the panel
// still works, it just pays for the whole preamble on every dispatch.

export const RUN_DATA_NOTE =
  "Placeholders. The issue placeholder, the plugin-root variable and every capitalised name in angle brackets, above and in your lens, stand for the value of the same name in the RUN DATA block at the very end of this prompt; substitute it before you run, read or write anything. The role placeholder is the role your lens names. " +
  "Tables below are TOON: header lists the fields, one row per item (`name[N]{a,b}:` then N rows of a,b; `name[N]: x,y` is an inline list; a quoted cell is a JSON string). " +
  "Every file RUN DATA names is the full JSON artifact; Read it when a table is not enough.";

// The delta stance (review convergence). The old paragraph told every delta reviewer to "assume the
// remediation introduced a defect until evidence says otherwise", on top of a preamble telling it to
// surface the strongest flaw it could find. Together those never converge: a reviewer instructed to
// find a defect finds one. A delta reviewer now rules on its own open blockers, and a NEW finding
// blocks only when the fix commits introduced it AND it has a merge_class.
export const DELTA_STANCE =
  "Rule only on your open blockers listed below. A new finding blocks only if the fix commits introduced it and it has a merge_class; everything else is a note.";

/** Static: the shas and the role list are placeholders bound in RUN DATA. */
export const DELTA_PARAGRAPH =
  "DELTA RE-REVIEW. This is NOT a fresh full panel. The first round reviewed <FIRST_ROUND_HEAD>; " +
  "the reviewed commit is now <HEAD_SHA>, and the fix diff is git diff <FIRST_ROUND_HEAD>...HEAD. " +
  "Only the roles in delta.roles in RUN DATA are re-dispatched; every other role's standing verdict holds " +
  `and is merged additively. ${DELTA_STANCE} The fix-round budget is counted by scripts/round-budget.mjs, ` +
  "and a round past it goes to the owner, not to another panel.\n";

/** The per-role sentence naming the open blocker ids a delta reviewer rules on. */
export function openBlockerLine(role, openBlockers) {
  if (openBlockers === null || openBlockers === undefined) {
    return "Your open blockers: none recorded (no peer-review.json was given to the renderer); rule on the blocking concerns you raised last round.";
  }
  const entry = openBlockers[role];
  const rec = Array.isArray(entry) ? { open: entry, demoted: [], unnamed: false } : entry || { open: [], demoted: [], unnamed: false };
  const demoted = rec.demoted.length > 0
    ? ` Demoted past the cap last round, and still yours to rule on: ${rec.demoted.join(", ")}.`
    : "";
  if (rec.open.length > 0) {
    return `Your open blockers: ${rec.open.join(", ")}. For each, say closed or still open, with evidence.${demoted}`;
  }
  if (rec.unnamed) {
    return "Your open blockers: not named (a legacy record marks your block as refusing the merge without ids); rule on every blocking concern you raised last round, with evidence.";
  }
  return "Your open blockers: none. You were seated because the fix commits touched your surface; only a new merge_class finding the fix introduced can block.";
}

/** { role: { open: [ids], demoted: [ids], unnamed } } from a merged peer-review.json. */
export function openBlockerMap(peerReview) {
  const out = {};
  for (const { role, id, demoted } of listOpenBlockers(peerReview)) {
    const rec = (out[role] ||= { open: [], demoted: [], unnamed: false });
    if (id === null) rec.unnamed = true;
    else (demoted ? rec.demoted : rec.open).push(id);
  }
  return out;
}

/** The fields a delta lens gets per open blocker; the prose (description, must_satisfy) stays in the file. */
export const BLOCKER_FIELDS = ["id", "severity", "likelihood", "harm", "merge_class", "location"];

function cell(v) {
  if (v === undefined) return null;
  return v !== null && typeof v === "object" ? JSON.stringify(v) : v;
}

/**
 * One uniform row per open or demoted blocker this role holds, read from the merged
 * peer-review.json's concerns. A legacy concern with no id is matched by its positional name
 * (<role>-<1-based index>), the same naming scripts/materiality.mjs uses.
 */
export function openBlockerRows(role, peerReview, openBlockers) {
  const rec = openBlockers?.[role];
  const ids = rec ? [...(rec.open || []), ...(rec.demoted || [])] : [];
  const concerns = Array.isArray(peerReview?.[role]?.concerns) ? peerReview[role].concerns : [];
  const rows = [];
  concerns.forEach((c, i) => {
    if (!c || typeof c !== "object") return;
    const id = typeof c.id === "string" && c.id ? c.id : `${role}-${i + 1}`;
    if (!ids.includes(id)) return;
    rows.push(Object.fromEntries(BLOCKER_FIELDS.map((f) => [f, f === "id" ? id : cell(c[f])])));
  });
  return rows;
}

/** The per-run values of one dispatch, as data (prompt-weight.mjs encodes them both ways). */
export function runDataValues({ issue, worktree, head, artifactDir, pluginRoot, tier, costClass, deltaRoles, firstRoundHead, peerReviewPath, role, openBlockers, peerReview }) {
  // Forward slashes on every platform: a Windows backslash would be escaped (doubled) inside a
  // quoted TOON cell, and node, git and Git Bash all accept the forward-slash form.
  const slash = (p) => String(p).replace(/\\/g, "/");
  const data = { issue, WORKTREE_PATH: slash(worktree), HEAD_SHA: head, REVIEWED_SHA: head, ARTIFACT_DIR: artifactDir, CLAUDE_PLUGIN_ROOT: slash(pluginRoot), risk_tier: tier };
  if (costClass !== undefined) data.cost_class = costClass;
  if (deltaRoles) {
    data.FIRST_ROUND_HEAD = firstRoundHead;
    data.delta = { roles: deltaRoles, fix_diff: `git diff ${firstRoundHead}...HEAD` };
    if (peerReviewPath) data.delta.peer_review = peerReviewPath;
    const rows = openBlockerRows(role, peerReview, openBlockers);
    if (rows.length > 0) data.delta.open_blockers = rows;
  }
  return data;
}

/** The RUN DATA block for one dispatch: the per-run values, TOON-encoded, then the delta sentence. */
export function runDataBlock(input) {
  let text = `RUN DATA\n${toon(runDataValues(input))}\n`;
  if (input.deltaRoles) text += `${openBlockerLine(input.role, input.openBlockers)}\n`;
  return text;
}

/**
 * Assemble every dispatch of one panel. Pure given its inputs. Returns the shared static preamble
 * and, per role, the static lens text and the run data, so a caller (the renderer, the test,
 * prompt-weight.mjs) can see where the cacheable prefix ends.
 */
export function assemble({ status, worktree, head, pluginRoot, lenses, preambleMarkdown, delta = null, firstRoundHead = null, openBlockers = null, peerReview = null, peerReviewPath = null, cfg }) {
  const issue = status.issue_number ?? status.experiment_id;
  if (issue === undefined || issue === null) throw new Error("status.json carries no issue_number");
  const tier = status.risk_tier;
  if (!["trivial", "standard", "architectural"].includes(tier)) {
    throw new Error(`status.json risk_tier is ${JSON.stringify(tier)}; the panel cannot be routed without a determined tier`);
  }
  const costClass = status.cost_class;
  if (costClass !== undefined && !["product-money", "product", "tooling"].includes(costClass)) {
    throw new Error(`status.json cost_class is ${JSON.stringify(costClass)}; expected product-money, product or tooling`);
  }
  const panel = Array.isArray(status.panel_roles) ? status.panel_roles : null;
  if (!panel || panel.length === 0) throw new Error("status.json panel_roles is absent or empty; resolve the panel first");
  const roles = delta ? delta.split(/\s+/).filter(Boolean) : panel;
  if (roles.length === 0) throw new Error("no roles to render");
  for (const r of roles) {
    if (!lenses[r]) throw new Error(`role "${r}" has no entry in scripts/panel-lenses.json`);
  }
  const artifactDir = path.posix.join(worktree.replace(/\\/g, "/"), ".pipeline", String(issue));
  const preamble = (delta ? DELTA_PARAGRAPH : "") + extractPreamble(preambleMarkdown) + "\n\n" + RUN_DATA_NOTE + "\n\n";

  const dispatches = roles.map((role) => {
    const lens = lenses[role];
    const opts = { agentType: lens.agentType };
    const m = resolveModel({ role, tier, phase: "4", site: "panel-lens", cfg });
    if (!m.error && typeof m.model === "string" && /^[a-z]+$/.test(m.model)) opts.model = m.model;
    const e = resolveEffort({ role, tier, phase: "4", site: "panel-lens", surface: "workflow", cfg, costClass });
    if (e.error) throw new Error(`effort resolver refused ${role}: ${e.error}`);
    if (typeof e.effort === "string" && e.effort) opts.effort = e.effort;
    opts.label = lens.label;
    const lensText = `${lens.lens}\n\n`;
    const runInput = {
      issue, worktree, head, artifactDir, pluginRoot, tier, costClass,
      deltaRoles: delta ? roles : null, firstRoundHead, peerReviewPath, role, openBlockers, peerReview,
    };
    const runData = runDataBlock(runInput);
    return { role, opts, lensText, runData, runValues: runDataValues(runInput), prompt: preamble + lensText + runData };
  });
  return { issue, tier, roles, preamble, dispatches };
}

/**
 * Render the Workflow script. Pure given its inputs, so the test can drive it with a fixture
 * status record and a scratch worktree.
 */
export function render(input) {
  const { issue, tier, roles, preamble, dispatches } = assemble(input);
  const calls = dispatches.map((d) => `  () => agent(PREAMBLE + ${JSON.stringify(d.lensText + d.runData)}, ${JSON.stringify(d.opts)}),`);
  const name = input.delta ? `phase4-delta-${issue}` : `phase4-panel-${issue}`;
  const desc = input.delta
    ? `Phase 4 delta re-review for #${issue} (${roles.join(", ")})`
    : `Phase 4 peer review panel for #${issue} (${tier} tier: ${roles.join(", ")})`;
  const phaseTitle = input.delta ? "Delta" : "Panel";
  return [
    `export const meta = { name: ${JSON.stringify(name)}, description: ${JSON.stringify(desc)}, phases: [{ title: ${JSON.stringify(phaseTitle)} }] }`,
    `phase(${JSON.stringify(phaseTitle)})`,
    `// Rendered by render-panel.mjs from status.json; reviewed HEAD ${input.head}. Do not edit by hand.`,
    `// PREAMBLE and each lens are static; each prompt ends with its RUN DATA, so the cache reuses the rest.`,
    `const PREAMBLE = ${JSON.stringify(preamble)}`,
    `const results = await parallel([`,
    ...calls,
    `])`,
    `return { returns: results }`,
    ``,
  ].join("\n");
}

export function checkScript(script) {
  const dir = mkdtempSync(path.join(os.tmpdir(), "render-panel-"));
  const f = path.join(dir, "panel.mjs");
  try {
    // The Workflow runtime reads `export const meta` at module top level and runs the REST of the
    // script as an async function body in which `return`, `phase`, `parallel` and `agent` are
    // provided. Emulate exactly that split for the parse: the meta line stays at top level (the
    // file is .mjs, so `export` is legal there), everything else goes inside the wrapper.
    const lines = script.split("\n");
    const metaIdx = lines.findIndex((l) => l.startsWith("export const meta"));
    const metaLine = metaIdx === -1 ? "" : lines[metaIdx];
    const body = lines.filter((_, i) => i !== metaIdx).join("\n");
    writeFileSync(f, `${metaLine}\nasync function __wf(phase, parallel, agent) {\n${body}\n}\n`);
    const r = spawnSync(process.execPath, ["--check", f], { encoding: "utf8" });
    return { ok: r.status === 0, stderr: r.stderr || "" };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (e) {
    console.error(`render-panel: ${e.message}`);
    process.exit(1);
  }
  try {
    const status = JSON.parse(readFileSync(args.status, "utf8"));
    const head = readHead(args.worktree);
    const lenses = loadLenses(args.pluginRoot);
    const md = readFileSync(path.join(args.pluginRoot, "commands", "pipeline.md"), "utf8");
    const peerReview = args.peerReview ? JSON.parse(readFileSync(args.peerReview, "utf8")) : null;
    const script = render({
      status,
      worktree: path.resolve(args.worktree),
      head,
      pluginRoot: path.resolve(args.pluginRoot),
      lenses,
      preambleMarkdown: md,
      delta: args.delta,
      firstRoundHead: args.firstRoundHead,
      openBlockers: peerReview ? openBlockerMap(peerReview) : null,
      peerReview,
      peerReviewPath: args.peerReview ? path.resolve(args.peerReview).replace(/\\/g, "/") : null,
    });
    if (args.check) {
      const c = checkScript(script);
      if (!c.ok) {
        console.error(`render-panel: rendered script does not parse:\n${c.stderr}`);
        process.exit(3);
      }
    }
    if (args.out) {
      writeFileSync(args.out, script);
      console.error(`render-panel: wrote ${args.out} (reviewed HEAD ${head})`);
    } else {
      process.stdout.write(script);
    }
  } catch (e) {
    console.error(`render-panel: ${e.message}`);
    process.exit(2);
  }
}

if (isMainScript("render-panel.mjs")) {
  main(process.argv.slice(2));
}
