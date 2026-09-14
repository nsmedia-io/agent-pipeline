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
import { normalizeBlock } from "./materiality.mjs";

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

// PROVISIONAL SHARD REFUSAL (#155). A shard that declares itself unfinished, or that carries a
// verdict with nothing behind it, is refused exactly as a missing shard is. Origin: two panelists
// ran out of turns and left placeholder shards ({"verdict":"APPROVE_WITH_NOTES","concerns":[],
// "notes":"PROVISIONAL - review in progress"}), and the merge folded both into peer-review.json as
// real verdicts. A missing shard halts; a hollow one passed, which is the worse failure because
// it looks like a review that happened. Two tests, either one refuses:
//   (1) any top-level string field matches the self-declared-unfinished vocabulary;
//   (2) the shard carries no concerns AND no evidence-bearing prose at all (no non-empty string
//       value other than the verdict and the reviewed_* identifiers): the bare
//       {"verdict":"APPROVE"} shape, which is what an agent writes as a placeholder before it
//       starts and never returns to. A verdict with nothing behind it is a verdict nobody rendered.
// A real APPROVE with any note, a VETO carrying its veto_ground, or an APPROVE_WITH_NOTES with one
// concern all pass; the threshold is deliberately "nothing", not a word count, so a terse but
// real review is never refused for being short.
export const PROVISIONAL_RE = /\b(provisional|in progress|in-progress|not yet complete|placeholder|will update before final|review pending)\b/i;
const NON_EVIDENCE_KEYS = new Set(["verdict", "verdict_as_returned", "reviewed_at", "reviewed_sha", "reviewed_commit", "role", "agent"]);

function evidenceStrings(value, key, out) {
  if (typeof value === "string") {
    if (!NON_EVIDENCE_KEYS.has(key)) out.push(value);
    return;
  }
  if (Array.isArray(value)) {
    for (const v of value) evidenceStrings(v, key, out);
    return;
  }
  if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) evidenceStrings(v, k, out);
  }
}

// Returns null for a full shard, or a one-line reason when the (unwrapped) block is provisional.
export function provisionalReason(block) {
  if (!block || typeof block !== "object") return null;
  for (const [k, v] of Object.entries(block)) {
    if (typeof v === "string" && !NON_EVIDENCE_KEYS.has(k) && PROVISIONAL_RE.test(v)) {
      return `top-level "${k}" declares the review unfinished: ${JSON.stringify(v.slice(0, 80))}`;
    }
  }
  const concerns = Array.isArray(block.concerns) ? block.concerns.length : 0;
  if (concerns === 0) {
    const strings = [];
    evidenceStrings(block, "", strings);
    const chars = strings.join("").trim().length;
    if (chars === 0) {
      return "no concerns and no evidence-bearing text of any kind: a verdict with nothing behind it";
    }
  }
  return null;
}

export function isProvisionalShard(block) {
  return provisionalReason(block) !== null;
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
  // HALT on a self-declared-unfinished or evidence-less shard BEFORE anything is written (#155),
  // naming the role and the reason. Checked on the unwrapped block, like the verdict check below.
  for (const role of Object.keys(shards)) {
    const reason = provisionalReason(merged[role]);
    if (reason !== null) {
      console.error(`PROVISIONAL SHARD: ${role} (${reason}); re-dispatch the reviewer, do not merge a placeholder`);
      process.exit(2);
    }
  }
  // HALT on a present-but-verdict-less shard (recovered-but-null), matching the
  // pipeline.md rubric: such a role carries no verdict the rubric can read, so it is a
  // missing review, not a pass. Checked against the merged (unwrapped) block.
  for (const role of Object.keys(shards)) {
    if (!hasRecoverableVerdict(merged[role])) {
      console.error(`NO RECOVERABLE VERDICT: ${role} (shard present but yields no verdict after unwrap)`);
      process.exit(2);
    }
  }
  // MATERIALITY (0.40.0). Every shard folded on THIS invocation is normalized: a
  // REQUEST_CHANGES with no blocking concern is recorded as APPROVE_WITH_NOTES, a VETO with
  // no named veto_ground as REQUEST_CHANGES, an APPROVE carrying a blocking concern as
  // REQUEST_CHANGES. The reviewer's own verdict is kept as verdict_as_returned whenever the
  // two differ, and the change is said on stderr, so the rubric reads the ruling and the
  // archive keeps the finding. Standing blocks from earlier rounds are NOT re-normalized:
  // they were normalized when they were folded, and re-reading them would be a second
  // ruling on the same evidence.
  for (const role of Object.keys(shards)) {
    const before = merged[role];
    const after = normalizeBlock(before, role);
    merged[role] = after;
    if (after && after.verdict_as_returned !== undefined && after.verdict !== before.verdict) {
      console.error(`normalized ${role}: ${before.verdict} -> ${after.verdict} (${(after.materiality?.notes || []).join(" ")})`);
    } else if (after && after.materiality && after.materiality.unrated_concerns > 0) {
      console.error(`normalized ${role}: verdict unchanged, ${after.materiality.unrated_concerns} unrated blocking-severity concern(s) treated as blocking`);
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
