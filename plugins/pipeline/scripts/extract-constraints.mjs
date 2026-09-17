#!/usr/bin/env node
/**
 * extract-constraints.mjs -- the Phase 2-lite constraint checklists, copied out of the agent files
 * (#164 row 19).
 *
 * WHY. The prose ran a `sed -n '/BEGIN.../,/END.../p'` loop over dba, devops and secops, appending
 * to one file, and said "if extraction produces an empty file, HALT". One role's markers missing
 * still leaves the other roles' blocks in the file, so the file is never empty and the halt never
 * fires: Dev is dispatched with a checklist silently short by a whole specialist. A missing END
 * marker was worse: sed prints to the end of the agent file.
 *
 * This extracts each role's block from `<!-- BEGIN STANDARD-TIER CONSTRAINTS` through the next
 * `<!-- END STANDARD-TIER CONSTRAINTS` line, inclusive, and writes them in role order, each
 * followed by one blank line (the bytes the sed loop produced). A role whose file is missing,
 * whose BEGIN or END marker is missing, or whose block is empty is named, and then NOTHING is
 * written: --out is left empty, so the phase-entry guard refuses it too.
 *
 *   node extract-constraints.mjs --out <constraints.md> [--agents-dir <dir>] [--roles dba,devops,secops]
 *
 * EXIT CODES. 0 written. 2 at least one role's markers are missing (every such role named on
 * stderr). 1 usage or an unwritable --out.
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { isMain, nativePath } from "./lib.mjs";

export const DEFAULT_ROLES = ["dba", "devops", "secops"];
const BEGIN = "<!-- BEGIN STANDARD-TIER CONSTRAINTS";
const END = "<!-- END STANDARD-TIER CONSTRAINTS";
const USAGE = "usage: node extract-constraints.mjs --out <constraints.md> [--agents-dir <dir>] [--roles dba,devops,secops]\n";

/** One role's block from an agent file's text. {block} or {missing: reason}. */
export function extractBlock(text) {
  const lines = String(text).split(/\r?\n/);
  const b = lines.findIndex((l) => l.includes(BEGIN));
  if (b < 0) return { missing: "no BEGIN STANDARD-TIER CONSTRAINTS marker" };
  let e = -1;
  for (let i = b + 1; i < lines.length; i++) {
    if (lines[i].includes(END)) {
      e = i;
      break;
    }
  }
  if (e < 0) return { missing: "no END STANDARD-TIER CONSTRAINTS marker after BEGIN" };
  if (lines.slice(b + 1, e).every((l) => l.trim() === "")) return { missing: "the block between the markers is empty" };
  return { block: `${lines.slice(b, e + 1).join("\n")}\n` };
}

/** {text, missing: [{role, reason}]} over the roles, reading `<agentsDir>/<role>.md`. */
export function extractConstraints(agentsDir, roles = DEFAULT_ROLES) {
  const missing = [];
  let text = "";
  for (const role of roles) {
    const file = join(agentsDir, `${role}.md`);
    if (!existsSync(file)) {
      missing.push({ role, reason: `${file} does not exist` });
      continue;
    }
    const r = extractBlock(readFileSync(file, "utf8"));
    if (r.missing) missing.push({ role, reason: r.missing });
    else text += `${r.block}\n`;
  }
  return { text: missing.length ? "" : text, missing };
}

export function main(argv, { err = (s) => process.stderr.write(s), out = (s) => process.stdout.write(s) } = {}) {
  let outFile = "";
  let agentsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "agents");
  let roles = DEFAULT_ROLES;
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--out") outFile = argv[++i] || "";
    else if (k === "--agents-dir") agentsDir = nativePath(argv[++i] || "");
    else if (k === "--roles") roles = String(argv[++i] || "").split(",").map((s) => s.trim()).filter(Boolean);
    else {
      err(`extract-constraints: unknown argument ${k}\n${USAGE}`);
      return 1;
    }
  }
  if (!outFile || roles.length === 0) {
    err(USAGE);
    return 1;
  }
  const { text, missing } = extractConstraints(agentsDir, roles);
  try {
    writeFileSync(nativePath(outFile), text);
  } catch (e) {
    err(`extract-constraints: cannot write ${outFile}: ${e.message}\n`);
    return 1;
  }
  if (missing.length) {
    for (const m of missing) err(`extract-constraints: ${m.role}: ${m.reason}\n`);
    err(`extract-constraints: HALT: constraints missing for ${missing.map((m) => m.role).join(", ")}; ${outFile} left empty. Do not dispatch Phase 3.\n`);
    return 2;
  }
  out(`extract-constraints: wrote ${roles.join(", ")} to ${outFile}\n`);
  return 0;
}

if (isMain("extract-constraints.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
