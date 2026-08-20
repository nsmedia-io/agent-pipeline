#!/usr/bin/env node
// archive-pipeline.mjs — thin wrapper (Phase 5): consolidate a finished run's
// .pipeline/<n>/*.json artifacts into knowledge/issue-archive/<n>.json. No network.

import { join, resolve } from "node:path";
import { archiveIssue } from "./knowledge-store.mjs";

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const eq = a.indexOf("=");
    if (eq !== -1) {
      out[a.slice(2, eq)] = a.slice(eq + 1);
      continue;
    }
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next !== undefined && !next.startsWith("--")) {
      out[key] = next;
      i++;
    } else {
      out[key] = true;
    }
  }
  return out;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const issue = args.issue;
  if (issue === undefined || issue === true) {
    console.error("Usage: archive-pipeline.mjs --issue <n> [--from <dir>] [--root <dir>]");
    process.exit(1);
  }

  const root = typeof args.root === "string" ? args.root : process.cwd();
  // Default artifact dir is the runtime pipeline dir for this issue.
  const from =
    typeof args.from === "string"
      ? args.from
      : join(resolve(root), ".pipeline", String(issue));

  try {
    const { outPath, found, redactions } = archiveIssue({ root, issue, from });
    console.log(`Archived issue #${issue} -> ${outPath}`);
    console.log(`  artifacts: ${found.join(", ")}`);
    // The archive is a committed file, so archiveIssue rewrites absolute paths on the way in.
    // Counted and printed rather than done in silence: a redaction nobody can see is one
    // nobody notices stopping, and the count is the operator's cue to check what it caught.
    console.log(`  absolute paths redacted: ${redactions}`);
  } catch (e) {
    console.error(`Error: ${e.message}`);
    process.exit(1);
  }
}

main();
