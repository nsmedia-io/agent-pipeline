#!/usr/bin/env node
/**
 * merge-ready.mjs -- may this PR be presented to the owner as ready to merge? (#164 row 15)
 *
 *   node merge-ready.mjs --issue <n> --worktree <path> --impl-report <impl-report.json>
 *                        --peer-review <peer-review.json> [--pr-url <url>] [--ref <deferral ref>]...
 *                        [--root <project root>]
 *
 * Three mechanical preconditions, every failure reported (not just the first):
 *   1. The PR head is the commit the PANEL REVIEWED. The reviewed commit is read from what the panel
 *      recorded (`reviewed_sha` or `reviewed_commit` on each role in peer-review.json), never from
 *      the worktree HEAD at check time, which a later push moves. On a delta round roles record
 *      different commits; the reviewed commit is the one every other recorded commit is an ancestor
 *      of. None recorded, one that does not resolve in the worktree, or recorded commits that do not
 *      form one line of history: not ready. The only commits allowed between the reviewed commit and
 *      the PR head are the orchestrator's own "chore: apply Phase 4 panel notes for #<issue>" commits.
 *   2. CI on the PR head is green: every statusCheckRollup entry is a completed CheckRun concluding
 *      SUCCESS, NEUTRAL or SKIPPED, or a StatusContext in state SUCCESS. Pending is not green. No
 *      checks at all is not green either, unless pipeline.config.json sets ciRequiredForMerge: false
 *      (a project with no remote CI). There is no per-call override.
 *   3. Every deferral reference verifies, through deferral.mjs's verifyDeferralRef, the function the
 *      pre-Phase-4 gate also calls: impl-report deferred[].tracker_ref, the legacy
 *      scope_drift.observations_reported_not_fixed[].tracker_ref, every `tracker_ref` anywhere in
 *      peer-review.json (panel shards that deferred a note), and each --ref (the checklist and issue
 *      refs recorded in status.json flags).
 *
 * The PR is --pr-url, else impl-report pr_url. Config is read from --root (default:
 * CLAUDE_PROJECT_DIR, else the cwd).
 *
 * EXIT CODES. 0 ready. 2 not ready, one `- reason` line each. 1 usage or an unreadable input.
 * Only 0 means ready.
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { isMain, nativePath } from "./lib.mjs";
import { verifyDeferralRef, readPipelineConfig, trackerFromConfig, deferralDirFromConfig } from "./deferral.mjs";

const USAGE =
  "usage: node merge-ready.mjs --issue <n> --worktree <path> --impl-report <impl-report.json> --peer-review <peer-review.json> [--pr-url <url>] [--ref <ref>]... [--root <dir>]\n";
const GREEN_CONCLUSIONS = new Set(["SUCCESS", "NEUTRAL", "SKIPPED"]);
const SHA_KEYS = ["reviewed_sha", "reviewed_commit"];

export function run(cmd, args, cwd) {
  let r;
  try {
    r = spawnSync(cmd, args, { encoding: "utf8", ...(cwd ? { cwd } : {}) });
  } catch (e) {
    return { ran: false, status: null, stdout: "", stderr: String(e && e.message) };
  }
  if (r.error) return { ran: false, status: null, stdout: "", stderr: String(r.error.message) };
  return { ran: true, status: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

/** ciRequiredForMerge from a parsed config: true unless it is exactly false. */
export function ciRequiredFromConfig(cfg) {
  return !(cfg && cfg.ciRequiredForMerge === false);
}

/** {state: "green"|"pending"|"failing"|"none", names: string[]} over a statusCheckRollup array. */
export function ciState(rollup) {
  const list = Array.isArray(rollup) ? rollup : [];
  if (list.length === 0) return { state: "none", names: [] };
  const failing = [];
  const pending = [];
  for (const c of list) {
    const name = (c && (c.name || c.context)) || "(unnamed)";
    if (c && c.__typename === "StatusContext") {
      if (c.state === "SUCCESS") continue;
      if (c.state === "PENDING" || c.state === "EXPECTED") pending.push(name);
      else failing.push(name);
      continue;
    }
    if (!c || c.status !== "COMPLETED") pending.push(name);
    else if (!GREEN_CONCLUSIONS.has(c.conclusion)) failing.push(name);
  }
  if (failing.length) return { state: "failing", names: failing };
  if (pending.length) return { state: "pending", names: pending };
  return { state: "green", names: [] };
}

/** The distinct commits the panel recorded, with the roles that recorded each. */
export function recordedShas(peerReview) {
  const map = new Map();
  if (!peerReview || typeof peerReview !== "object") return map;
  for (const [role, shard] of Object.entries(peerReview)) {
    if (!shard || typeof shard !== "object" || Array.isArray(shard)) continue;
    for (const k of SHA_KEYS) {
      const v = shard[k];
      if (typeof v === "string" && /^[0-9a-f]{7,40}$/i.test(v.trim())) {
        const sha = v.trim().toLowerCase();
        if (!map.has(sha)) map.set(sha, []);
        map.get(sha).push(role);
      }
    }
  }
  return map;
}

/** Every deferral ref the report, the panel and the caller name, with where each came from. */
export function deferralRefs(report, peerReview, extra = []) {
  const refs = [];
  const sources = [
    ["deferred", report && report.deferred],
    ["scope_drift.observations_reported_not_fixed", report && report.scope_drift && report.scope_drift.observations_reported_not_fixed],
  ];
  for (const [label, rows] of sources) {
    if (!Array.isArray(rows)) continue;
    rows.forEach((row, i) => refs.push({ where: `impl-report ${label}[${i}]`, ref: row && typeof row === "object" ? row.tracker_ref : undefined }));
  }
  (function walk(node, path) {
    if (Array.isArray(node)) node.forEach((v, i) => walk(v, `${path}[${i}]`));
    else if (node && typeof node === "object") {
      for (const [k, v] of Object.entries(node)) {
        if (k === "tracker_ref") refs.push({ where: `peer-review ${path}.tracker_ref`, ref: v });
        else walk(v, path ? `${path}.${k}` : k);
      }
    }
  })(peerReview, "");
  extra.forEach((ref, i) => refs.push({ where: `--ref[${i}]`, ref }));
  return refs;
}

/**
 * Resolve the reviewed commit from the recorded ones with git in the worktree.
 * @returns {{sha: string|null, reason: string|null}}
 */
export function reviewedCommit(recorded, git) {
  if (recorded.size === 0) return { sha: null, reason: "the panel recorded no reviewed commit (reviewed_sha or reviewed_commit in peer-review.json), so there is nothing to compare the PR head to" };
  const full = [];
  for (const [sha, roles] of recorded) {
    const r = git(["rev-parse", "--verify", "--quiet", `${sha}^{commit}`]);
    if (!(r.ran && r.status === 0 && r.stdout.trim())) return { sha: null, reason: `the reviewed commit ${sha} recorded by ${roles.join(", ")} does not resolve in the worktree` };
    full.push(r.stdout.trim());
  }
  const uniq = [...new Set(full)];
  const tip = uniq.find((c) => uniq.every((o) => o === c || (() => { const a = git(["merge-base", "--is-ancestor", o, c]); return a.ran && a.status === 0; })()));
  if (!tip) return { sha: null, reason: `the panel recorded commits that are not one line of history (${uniq.map((s) => s.slice(0, 12)).join(", ")})` };
  return { sha: tip, reason: null };
}

export function mergeReady({ issue, report, peerReview, prUrl, requireCi = true, extraRefs = [], exec, git, verify }) {
  const reasons = [];
  const warnings = [];

  const rc = reviewedCommit(recordedShas(peerReview), git);
  if (rc.reason) reasons.push(rc.reason);

  if (!prUrl) {
    reasons.push("no PR url (pass --pr-url or record pr_url in impl-report.json)");
  } else {
    const r = exec("gh", ["pr", "view", prUrl, "--json", "headRefOid,statusCheckRollup"]);
    let pr = null;
    if (r.ran && r.status === 0) {
      try {
        pr = JSON.parse(r.stdout);
      } catch {
        pr = null;
      }
    }
    if (!pr) {
      reasons.push(`cannot read ${prUrl}: ${(r.stderr || r.stdout || "unparseable gh output").trim().split("\n")[0]}`);
    } else {
      const head = typeof pr.headRefOid === "string" ? pr.headRefOid : "";
      if (rc.sha && head !== rc.sha) {
        const between = git(["log", "--format=%H %s", `${rc.sha}..${head}`]);
        const anc = git(["merge-base", "--is-ancestor", rc.sha, head]);
        const notesSubject = `chore: apply Phase 4 panel notes for #${issue}`;
        const lines = between.ran && between.status === 0 ? between.stdout.split("\n").filter(Boolean) : null;
        const onlyNotes = anc.ran && anc.status === 0 && lines && lines.length > 0 && lines.every((l) => l.slice(41) === notesSubject);
        if (!onlyNotes) {
          reasons.push(`PR head ${head ? head.slice(0, 12) : "(unknown)"} is not the reviewed commit ${rc.sha.slice(0, 12)}, and the commits between are not only "${notesSubject}": push the reviewed head or review what was pushed`);
        }
      }
      const ci = ciState(pr.statusCheckRollup);
      if (ci.state === "failing") reasons.push(`CI is failing on the PR head: ${ci.names.join(", ")}`);
      else if (ci.state === "pending") reasons.push(`CI has not finished on the PR head: ${ci.names.join(", ")}`);
      else if (ci.state === "none" && requireCi) reasons.push("no CI checks are reported on the PR head, and ciRequiredForMerge is not false in pipeline.config.json");
    }
  }

  for (const { where, ref } of deferralRefs(report, peerReview, extraRefs)) {
    const v = verify(ref);
    if (v.warning) warnings.push(`${where}: ${v.warning}`);
    if (!v.ok) reasons.push(`${where} is not in the deferral ledger: ${v.message}`);
  }
  return { ready: reasons.length === 0, reasons, warnings, reviewed: rc.sha };
}

function readJson(file, label) {
  try {
    return JSON.parse(readFileSync(nativePath(file), "utf8"));
  } catch (e) {
    throw new Error(`cannot read --${label} ${file}: ${e.message}`);
  }
}

export function main(argv, { exec = run, out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s), verify } = {}) {
  const a = { refs: [] };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--issue") a.issue = argv[++i];
    else if (k === "--worktree") a.worktree = argv[++i];
    else if (k === "--impl-report") a.implReport = argv[++i];
    else if (k === "--peer-review") a.peerReview = argv[++i];
    else if (k === "--pr-url") a.prUrl = argv[++i];
    else if (k === "--ref") a.refs.push(argv[++i]);
    else if (k === "--root") a.root = argv[++i];
    else {
      err(`merge-ready: unknown argument ${k}\n${USAGE}`);
      return 1;
    }
  }
  if (!a.issue || !a.worktree || !a.implReport || !a.peerReview) {
    err(USAGE);
    return 1;
  }
  let report;
  let peerReview;
  try {
    report = readJson(a.implReport, "impl-report");
    peerReview = readJson(a.peerReview, "peer-review");
  } catch (e) {
    err(`merge-ready: ${e.message}\n`);
    return 1;
  }
  if (report && report.issue_number !== undefined && report.issue_number !== null && String(report.issue_number) !== String(a.issue)) {
    err(`merge-ready: impl-report issue_number ${report.issue_number} is not --issue ${a.issue}; wrong artifact\n`);
    return 1;
  }
  const root = resolve(nativePath(a.root || process.env.CLAUDE_PROJECT_DIR || process.cwd()));
  const worktree = nativePath(a.worktree);
  const cfg = readPipelineConfig(root);
  let verifyRef = verify;
  if (!verifyRef) {
    const opts = { tracker: trackerFromConfig(cfg), dir: deferralDirFromConfig(cfg), root };
    verifyRef = (ref) => verifyDeferralRef(ref, opts);
  }
  const requireCi = ciRequiredFromConfig(cfg);
  const r = mergeReady({
    issue: a.issue,
    report,
    peerReview,
    prUrl: a.prUrl || (typeof report.pr_url === "string" ? report.pr_url : ""),
    requireCi,
    extraRefs: a.refs,
    exec: (cmd, args) => exec(cmd, args, root),
    git: (args) => exec("git", ["-C", worktree, ...args], root),
    verify: verifyRef,
  });
  for (const w of r.warnings) err(`merge-ready: WARNING ${w}\n`);
  if (r.ready) {
    out(`READY: #${a.issue} PR head carries the reviewed commit ${r.reviewed.slice(0, 12)}, CI is ${requireCi ? "green" : "green or absent (ciRequiredForMerge: false)"}, every deferral ref verifies\n`);
    return 0;
  }
  out(`NOT READY: #${a.issue}\n`);
  for (const reason of r.reasons) out(`- ${reason}\n`);
  return 2;
}

if (isMain("merge-ready.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
