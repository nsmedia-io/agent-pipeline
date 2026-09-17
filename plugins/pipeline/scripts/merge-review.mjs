#!/usr/bin/env node
// Phase 2 shard merge and verdict gate (#164 row 5).
//
// Replaces the two jq recipes Phase 2 carried (the three-role merge and the design_review fold)
// and the hand-read verdict cases after them. The jq merge aborted on a missing shard with a jq
// error rather than a named halt, had no fallback path for a reviewer whose primary write was
// refused, and never applied the materiality rule, so a Phase 2 REQUEST_CHANGES with nothing
// blocking behind it sent the spec back to BA. This script is the Phase 2 twin of
// merge-peer-review.mjs and reuses its pieces: the same unwrap defense, the same additive merge,
// the same provisional-shard refusal, the same stray-copy naming, and the same normalizeBlock.
//
//   node merge-review.mjs [--status <status.json> | --cost-class <c>] [--fresh] <artifact-dir> <role>...
//
// Each <role> (dba, devops, secops, design_review) is read from <artifact-dir>/review.<role>.json,
// or, when that is absent, from <artifact-dir>/fallback-shards/review.<role>.json. The roles are
// folded INTO <artifact-dir>/review.json (--fresh starts from {} instead), the consumed shards are
// removed, and the outcome is computed over EVERY role the merged file holds.
//
// Exit codes, which the prose branches on:
//   0  every block is APPROVE or APPROVE_WITH_NOTES
//   3  at least one REQUEST_CHANGES (or REQUEST_REFACTOR), no standing VETO
//   4  a SecOps VETO that stands (a valid veto_ground and a blocking concern)
//   2  a shard missing, unparseable, provisional or verdict-less, or a null block in review.json;
//      nothing is written on a shard refusal
//   1  usage error

import { readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import path from "node:path";
import { isMain as isMainScript } from "./lib.mjs";
import { normalizeBlock, normVerdict, VETO_GROUNDS } from "./materiality.mjs";
import {
  additiveMerge,
  hasRecoverableVerdict,
  provisionalReason,
  resolveCostClass,
  strayShardCopies,
} from "./merge-peer-review.mjs";

export const PHASE2_ROLES = ["dba", "devops", "secops", "design_review"];

/** The two places a Phase 2 shard may be: the primary path, then the refused-write fallback. */
export function shardCandidates(artifactDir, role) {
  return [
    path.join(artifactDir, `review.${role}.json`),
    path.join(artifactDir, "fallback-shards", `review.${role}.json`),
  ];
}

/** The first candidate that exists, or null. */
export function resolveShard(artifactDir, role) {
  return shardCandidates(artifactDir, role).find((f) => existsSync(f)) ?? null;
}

/**
 * One block's verdict for the Phase 2 gate: APPROVE | CHANGES | VETO, or null when it carries
 * no verdict the gate can read. A VETO stands only from SecOps on an enumerated veto_ground; a
 * standing block that never went through normalizeBlock (no materiality record) is read through
 * it here, for the reading only, so a legacy groundless VETO cannot send a spec back to BA.
 */
export function gateReading(role, block, costClass) {
  if (!block || typeof block !== "object" || Array.isArray(block)) return null;
  let b = block;
  if (!b.materiality) b = normalizeBlock(b, role, { costClass });
  const v = normVerdict(b.verdict);
  if (v === "APPROVE" || v === "APPROVE_WITH_NOTES") return "APPROVE";
  if (v === "REQUEST_CHANGES" || v === "REQUEST_REFACTOR") return "CHANGES";
  if (v === "VETO") {
    const ground = typeof b.veto_ground === "string" ? b.veto_ground.trim().toLowerCase() : "";
    return role === "secops" && VETO_GROUNDS.includes(ground) ? "VETO" : "CHANGES";
  }
  return null;
}

/**
 * The outcome over a merged review object. Returns { code, outcome, roles: [{role, verdict,
 * reading}], unreadable: [role] }. Pure.
 */
export function phase2Outcome(merged, costClass) {
  const roles = [];
  const unreadable = [];
  for (const [role, block] of Object.entries(merged ?? {})) {
    if (!PHASE2_ROLES.includes(role)) continue;
    const reading = gateReading(role, block, costClass);
    if (reading === null) unreadable.push(role);
    roles.push({ role, verdict: block && typeof block === "object" ? block.verdict ?? null : null, reading, veto_ground: block?.veto_ground ?? null });
  }
  if (unreadable.length > 0 || roles.length === 0) return { code: 2, outcome: "UNREADABLE", roles, unreadable };
  if (roles.some((r) => r.reading === "VETO")) return { code: 4, outcome: "VETO", roles, unreadable };
  if (roles.some((r) => r.reading === "CHANGES")) return { code: 3, outcome: "REQUEST_CHANGES", roles, unreadable };
  return { code: 0, outcome: "APPROVE", roles, unreadable };
}

function halt(msg) {
  console.error(msg);
  process.exit(2);
}

function main(argvIn) {
  const positional = [];
  let costClassArg = null;
  let statusFile = null;
  let fresh = false;
  for (let i = 0; i < argvIn.length; i++) {
    if (argvIn[i] === "--cost-class") costClassArg = argvIn[++i];
    else if (argvIn[i] === "--status") statusFile = argvIn[++i];
    else if (argvIn[i] === "--fresh") fresh = true;
    else positional.push(argvIn[i]);
  }
  const [artifactDir, ...roles] = positional;
  if (!artifactDir || roles.length === 0 || roles.some((r) => !PHASE2_ROLES.includes(r))) {
    console.error(
      `usage: merge-review.mjs [--status <status.json> | --cost-class <product-money|product|tooling>] [--fresh] <artifact-dir> <role>... (roles: ${PHASE2_ROLES.join(", ")})`,
    );
    process.exit(1);
  }
  let costClass;
  try {
    costClass = resolveCostClass({ costClass: costClassArg, statusFile });
  } catch (e) {
    halt(`UNRESOLVABLE COST CLASS: ${e.message}; the cost_class decides what blocks, so the merge refuses to guess`);
  }

  const target = path.join(artifactDir, "review.json");
  let existing = {};
  if (!fresh && existsSync(target)) {
    try {
      existing = JSON.parse(readFileSync(target, "utf-8"));
    } catch (e) {
      halt(`UNREADABLE review.json: ${e.message}; nothing merged`);
    }
  }

  const shards = {};
  const consumed = [];
  for (const role of roles) {
    const [primary, fallback] = shardCandidates(artifactDir, role);
    const file = resolveShard(artifactDir, role);
    if (file === null) {
      console.error(`MISSING SHARD: ${role} (${primary}; no fallback at ${fallback} either)`);
      const strays = strayShardCopies(primary);
      for (const s of strays) {
        console.error(`  a file with this name exists at ${s}: the reviewer may have written it into the wrong checkout; move it to ${primary} and re-run the merge`);
      }
      if (strays.length === 0) {
        console.error(`  no copy under ${path.join(process.env.CLAUDE_PROJECT_DIR || process.cwd(), ".pipeline")}/*/ either`);
      }
      process.exit(2);
    }
    if (file === fallback) console.error(`read ${role} from the fallback path ${fallback}`);
    try {
      shards[role] = JSON.parse(readFileSync(file, "utf-8"));
    } catch (e) {
      halt(`UNPARSEABLE SHARD: ${role} (${file}): ${e.message}`);
    }
    consumed.push(file);
  }

  const merged = additiveMerge(existing, shards);
  for (const role of roles) {
    const reason = provisionalReason(merged[role]);
    if (reason !== null) halt(`PROVISIONAL SHARD: ${role} (${reason}); re-dispatch the reviewer, do not merge a placeholder`);
  }
  for (const role of roles) {
    if (!hasRecoverableVerdict(merged[role])) halt(`NO RECOVERABLE VERDICT: ${role} (shard present but yields no verdict after unwrap)`);
  }
  for (const role of roles) {
    const before = merged[role];
    const after = normalizeBlock(before, role, { costClass });
    merged[role] = after;
    if (after && after.verdict_as_returned !== undefined && after.verdict !== before.verdict) {
      console.error(`normalized ${role}: ${before.verdict} -> ${after.verdict} (${(after.materiality?.notes || []).join(" ")})`);
    }
  }

  writeFileSync(target, `${JSON.stringify(merged, null, 2)}\n`);
  for (const f of consumed) rmSync(f, { force: true });

  const result = phase2Outcome(merged, costClass);
  const line = result.roles
    .map((r) => `${r.role}=${r.verdict ?? "null"}${r.reading === "VETO" ? `(${r.veto_ground})` : ""}`)
    .join(" ");
  console.log(`ROLES: ${line}`);
  if (result.code === 2) {
    console.log(`OUTCOME: UNREADABLE (${result.unreadable.join(", ") || "no Phase 2 role in review.json"})`);
  } else {
    console.log(`OUTCOME: ${result.outcome}`);
  }
  process.exit(result.code);
}

const isMain = isMainScript("merge-review.mjs");

if (isMain) {
  main(process.argv.slice(2));
}
