#!/usr/bin/env node
/**
 * merge-ready.mjs -- may this PR be presented to the owner as ready to merge? (#164 row 15)
 *
 *   node merge-ready.mjs --issue <n> --worktree <path> --impl-report <impl-report.json>
 *                        [--pr-url <url>] [--ref <deferral ref>]... [--no-ci] [--root <project root>]
 *
 * Three mechanical preconditions, every failure reported (not just the first):
 *   1. The PR head is the reviewed commit: `gh pr view --json headRefOid` equals
 *      `git -C <worktree> rev-parse HEAD`. A push after the panel means the head was never reviewed.
 *   2. CI on that head is green: every statusCheckRollup entry is a completed CheckRun concluding
 *      SUCCESS, NEUTRAL or SKIPPED, or a StatusContext in state SUCCESS. Pending is not green. No
 *      checks at all is not green either (CI may not have registered yet); pass --no-ci for a
 *      project with no remote CI.
 *   3. Every deferral reference verifies, through deferral.mjs's verifyDeferralRef, the function the
 *      pre-Phase-4 gate also calls: impl-report deferred[].tracker_ref, the legacy
 *      scope_drift.observations_reported_not_fixed[].tracker_ref, and each --ref (the checklist and
 *      issue refs recorded in status.json flags).
 *
 * The PR is --pr-url, else impl-report pr_url. Tracker routing comes from pipeline.config.json
 * under --root (default: CLAUDE_PROJECT_DIR, else the cwd).
 *
 * EXIT CODES. 0 ready. 2 not ready, one `- reason` line each. 1 usage or an unreadable input.
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { isMain, nativePath } from "./lib.mjs";
import { verifyDeferralRef, readPipelineConfig, trackerFromConfig, deferralDirFromConfig } from "./deferral.mjs";

const USAGE =
  "usage: node merge-ready.mjs --issue <n> --worktree <path> --impl-report <impl-report.json> [--pr-url <url>] [--ref <ref>]... [--no-ci] [--root <dir>]\n";
const GREEN_CONCLUSIONS = new Set(["SUCCESS", "NEUTRAL", "SKIPPED"]);

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

/** Every deferral ref the report and the caller name, with where each came from. */
export function deferralRefs(report, extra = []) {
  const refs = [];
  const sources = [
    ["deferred", report && report.deferred],
    ["scope_drift.observations_reported_not_fixed", report && report.scope_drift && report.scope_drift.observations_reported_not_fixed],
  ];
  for (const [label, rows] of sources) {
    if (!Array.isArray(rows)) continue;
    rows.forEach((row, i) => refs.push({ where: `${label}[${i}]`, ref: row && typeof row === "object" ? row.tracker_ref : undefined }));
  }
  extra.forEach((ref, i) => refs.push({ where: `--ref[${i}]`, ref }));
  return refs;
}

/**
 * @returns {{ready: boolean, reasons: string[], warnings: string[], head: string|null}}
 */
export function mergeReady({ report, reviewedSha, prUrl, requireCi = true, extraRefs = [], exec, verify }) {
  const reasons = [];
  const warnings = [];
  let head = null;

  if (!reviewedSha) reasons.push("the worktree HEAD could not be read, so there is no reviewed commit to compare");
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
      head = typeof pr.headRefOid === "string" ? pr.headRefOid : null;
      if (reviewedSha && head !== reviewedSha) {
        reasons.push(`PR head ${head ? head.slice(0, 12) : "(unknown)"} is not the reviewed commit ${reviewedSha.slice(0, 12)}: push the reviewed head or review what was pushed`);
      }
      const ci = ciState(pr.statusCheckRollup);
      if (ci.state === "failing") reasons.push(`CI is failing on the PR head: ${ci.names.join(", ")}`);
      else if (ci.state === "pending") reasons.push(`CI has not finished on the PR head: ${ci.names.join(", ")}`);
      else if (ci.state === "none" && requireCi) reasons.push("no CI checks are reported on the PR head (pass --no-ci only for a project with no remote CI)");
    }
  }

  for (const { where, ref } of deferralRefs(report, extraRefs)) {
    const v = verify(ref);
    if (v.warning) warnings.push(`${where}: ${v.warning}`);
    if (!v.ok) reasons.push(`${where} is not in the deferral ledger: ${v.message}`);
  }
  return { ready: reasons.length === 0, reasons, warnings, head };
}

export function main(argv, { exec = run, out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s), verify } = {}) {
  const a = { refs: [] };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--issue") a.issue = argv[++i];
    else if (k === "--worktree") a.worktree = argv[++i];
    else if (k === "--impl-report") a.implReport = argv[++i];
    else if (k === "--pr-url") a.prUrl = argv[++i];
    else if (k === "--ref") a.refs.push(argv[++i]);
    else if (k === "--root") a.root = argv[++i];
    else if (k === "--no-ci") a.noCi = true;
    else {
      err(`merge-ready: unknown argument ${k}\n${USAGE}`);
      return 1;
    }
  }
  if (!a.issue || !a.worktree || !a.implReport) {
    err(USAGE);
    return 1;
  }
  let report;
  try {
    report = JSON.parse(readFileSync(nativePath(a.implReport), "utf8"));
  } catch (e) {
    err(`merge-ready: cannot read --impl-report ${a.implReport}: ${e.message}\n`);
    return 1;
  }
  if (report && report.issue_number !== undefined && report.issue_number !== null && String(report.issue_number) !== String(a.issue)) {
    err(`merge-ready: impl-report issue_number ${report.issue_number} is not --issue ${a.issue}; wrong artifact\n`);
    return 1;
  }
  const root = resolve(nativePath(a.root || process.env.CLAUDE_PROJECT_DIR || process.cwd()));
  const worktree = nativePath(a.worktree);
  const h = exec("git", ["-C", worktree, "rev-parse", "HEAD"], root);
  const reviewedSha = h.ran && h.status === 0 ? h.stdout.trim() : null;
  let verifyRef = verify;
  if (!verifyRef) {
    const cfg = readPipelineConfig(root);
    const opts = { tracker: trackerFromConfig(cfg), dir: deferralDirFromConfig(cfg), root };
    verifyRef = (ref) => verifyDeferralRef(ref, opts);
  }
  const r = mergeReady({
    report,
    reviewedSha,
    prUrl: a.prUrl || (typeof report.pr_url === "string" ? report.pr_url : ""),
    requireCi: !a.noCi,
    extraRefs: a.refs,
    exec: (cmd, args) => exec(cmd, args, root),
    verify: verifyRef,
  });
  for (const w of r.warnings) err(`merge-ready: WARNING ${w}\n`);
  if (r.ready) {
    out(`READY: #${a.issue} PR head ${reviewedSha.slice(0, 12)} is the reviewed commit, CI is ${a.noCi ? "not required" : "green"}, every deferral ref verifies\n`);
    return 0;
  }
  out(`NOT READY: #${a.issue}\n`);
  for (const reason of r.reasons) out(`- ${reason}\n`);
  return 2;
}

if (isMain("merge-ready.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
