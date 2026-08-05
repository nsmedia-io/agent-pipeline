#!/usr/bin/env node
// Additive peer-review shard merge for /pipeline Phase 4 and /phase peer-review.
//
// Merges the given role shards INTO an existing peer-review.json instead of
// resetting it. On a full round the target is absent (or {}) so every panel role
// is folded in; on a delta re-review round the target already carries the standing
// approvals of roles that were NOT re-dispatched, and those verdicts are preserved
// because only the roles named on THIS invocation are overwritten. This is the one
// merge mechanism both the auto re-review (pipeline.md) and the manual re-run
// (phase.md /phase peer-review) call, so the two cannot diverge.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { isMain as isMainScript } from "./lib.mjs";

// unwrap defends against a shard that wrapped its block under its role key
// ({"dba": {...}}) instead of writing a bare block, so a wrapped verdict is
// recovered rather than silently read as null and passed through a gate.
export function unwrap(block, key) {
  if (block && typeof block === "object" && !Array.isArray(block)) {
    if ("verdict" in block) return block;
    const inner = block[key];
    if (inner && typeof inner === "object" && !Array.isArray(inner)) return inner;
  }
  return block;
}

// existing: current merged object ({} on a full round). shards: { role: rawBlock }.
// Returns a NEW object: every existing role preserved, each provided role set to its
// unwrapped shard. Roles absent from `shards` keep their prior (standing) verdict.
export function additiveMerge(existing, shards) {
  const out = { ...(existing ?? {}) };
  for (const [role, raw] of Object.entries(shards)) {
    out[role] = unwrap(raw, role);
  }
  return out;
}

function normVerdict(v) {
  if (typeof v !== "string") return null;
  const u = v.trim().toUpperCase();
  if (u === "APPROVE_WITH_NITS") return "APPROVE_WITH_NOTES";
  return u;
}

// True when an (already-unwrapped) block carries a non-empty string verdict. A block
// that survives merge but has no recoverable verdict is the "recovered-but-null"
// review the pipeline.md prose HALTs on: the CLI treats it exactly like a missing
// shard (non-zero exit) so the code honors the prose guarantee, not softens it.
export function hasRecoverableVerdict(block) {
  return (
    block != null &&
    typeof block === "object" &&
    typeof block.verdict === "string" &&
    block.verdict.trim() !== ""
  );
}

// Counts verdicts across the FULL panel (pass the original panel_roles, not the
// delta subset) so the tally reflects the whole panel after a delta round. A role
// with no recoverable verdict is not counted; the caller halts on a missing review.
export function countVerdicts(merged, roles) {
  const counts = {
    approve: 0,
    approve_with_notes: 0,
    request_changes: 0,
    request_refactor: 0,
    veto: 0,
  };
  for (const role of roles) {
    switch (normVerdict(merged?.[role]?.verdict)) {
      case "APPROVE":
        counts.approve++;
        break;
      case "APPROVE_WITH_NOTES":
        counts.approve_with_notes++;
        break;
      case "REQUEST_CHANGES":
        counts.request_changes++;
        break;
      case "REQUEST_REFACTOR":
        counts.request_refactor++;
        break;
      case "VETO":
        counts.veto++;
        break;
      default:
        break;
    }
  }
  return counts;
}

function main(argv) {
  const [target, ...pairs] = argv;
  if (!target || pairs.length === 0) {
    console.error(
      "usage: merge-peer-review.mjs <peer-review.json> <role>=<shard.json> [<role>=<shard.json> ...]",
    );
    process.exit(1);
  }
  const existing = existsSync(target) ? JSON.parse(readFileSync(target, "utf-8")) : {};
  const shards = {};
  for (const pair of pairs) {
    const eq = pair.indexOf("=");
    if (eq === -1) {
      console.error(`bad role=shard argument: ${pair}`);
      process.exit(1);
    }
    const role = pair.slice(0, eq);
    const file = pair.slice(eq + 1);
    if (!existsSync(file)) {
      console.error(`MISSING SHARD: ${role} (${file})`);
      process.exit(2);
    }
    shards[role] = JSON.parse(readFileSync(file, "utf-8"));
  }
  const merged = additiveMerge(existing, shards);
  // HALT on a present-but-verdict-less shard (recovered-but-null), matching the
  // pipeline.md rubric: such a role carries no verdict the rubric can read, so it is a
  // missing review, not a pass. Checked against the merged (unwrapped) block.
  for (const role of Object.keys(shards)) {
    if (!hasRecoverableVerdict(merged[role])) {
      console.error(`NO RECOVERABLE VERDICT: ${role} (shard present but yields no verdict after unwrap)`);
      process.exit(2);
    }
  }
  writeFileSync(target, `${JSON.stringify(merged, null, 2)}\n`);
}

// Match the script NAME, not a path: fileURLToPath(import.meta.url) realpaths while argv[1]
// keeps the path as invoked, so under a symlinked plugin root the two differ, main() never
// runs, and the merge silently no-ops with exit 0. See knowledge-store.mjs for the full note.
const isMain = isMainScript("merge-peer-review.mjs");

if (isMain) {
  main(process.argv.slice(2));
}
