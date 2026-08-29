#!/usr/bin/env node
/**
 * Fail-CLOSED, self-SKIPPING frontend visual-verification gate.
 *
 * Run by the orchestrator AFTER Phase 3 and BEFORE the panel, immediately after
 * gate-pre-phase4.mjs (the Phase 3 to 4 transition). It is the frontend twin of the
 * live-verification gate: an orchestrator gate, NOT a CI step.
 *
 * Structure mirrors gate-pre-phase4.mjs deliberately: the same argv/exit conventions, the
 * same files_removed deletion-exemption pattern when inferring changed paths from
 * impl-report.json, and the same pure runFrontendGate({...}) core that is unit-testable
 * without any I/O.
 *
 * Fail direction (grounded, NOT "treat missing as blocking"):
 *   - The discriminating signal is "a frontend file changed", read from the diff path list
 *     via the SINGLE canonical allowlist in frontend-surface.mjs.
 *   - No frontend file changed  -> clean exit 0 with an explicit no-op message (skip). This
 *     mirrors the live-verification gate exiting 0 when its trigger is absent: no frontend
 *     to verify, nothing to gate. Absence of a trigger is never read as missing evidence.
 *   - A frontend file DID change -> require recorded evidence (a design_review verdict
 *     present + a lint pass + an accessibility (a11y) pass). Missing evidence HALTS (exit 1).
 *   - The changed-path list could NOT be determined (no --changed paths AND the impl-report is
 *     absent, unreadable, unparseable, or records no file list at all) -> HARD ERROR (exit 1),
 *     never a skip. "I could not determine what changed" is a DIFFERENT state from "nothing
 *     frontend changed", and only the latter may pass. Conflating them let a wrong
 *     --impl-report path silently no-op this control into a pass, in exactly the state where
 *     design evidence is most likely absent.
 *
 * Evidence is RECORDED by the Design agent inside its dispatch (it runs the accessibility
 * snapshot and the lint + a11y pass) and lands in peer-review.design_review.json /
 * review.design_review.json. An impl-report.json `design_gate` object is accepted as a
 * fallback (Dev's Phase-3 visual-build loop). This gate only checks for the PRESENCE of that
 * evidence; it never re-runs a11y tooling or starts a server.
 *
 * Security:
 *   - JSON.parse only. No eval, no shell interpolation of any artifact field or path.
 *   - Frontend detection is the glob allowlist in frontend-surface.mjs, never a regex built
 *     from artifact content.
 *   - Any recorded screenshot evidence path MUST live under .pipeline/<issue>/ (gitignored)
 *     and contain no ".." segment. A path outside that tree is refused, as is a ".." segment
 *     even when it would resolve back inside: committing a screenshot that may carry PII or a
 *     secret is a committable-leak vector. The check is string-only and never touches the
 *     filesystem, because this gate routinely runs outside the implementation worktree.
 *
 * Usage:
 *   node gate-pre-phase4-frontend.mjs --issue <n> \
 *     [--changed <path> ...] [--evidence <path>] [--impl-report <path>]
 *
 * --changed defaults to the impl-report.json commits[].files_changed union (with the
 *   files_removed deletion exemption applied).
 * --evidence defaults to .pipeline/<issue>/peer-review.design_review.json, falling back to
 *   .pipeline/<issue>/review.design_review.json, then to the impl-report.json design_gate
 *   object.
 */

import { readFileSync, existsSync } from "node:fs";
import { isMain as isMainScript } from "./lib.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { diffTouchesFrontend } from "./frontend-surface.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
// Runtime artifacts live in the USER project's .pipeline/<issue>/ (gitignored).
const PROJECT_ROOT = process.env.CLAUDE_PROJECT_DIR || process.cwd();

// Pure check core. Given whether the diff touched frontend and the parsed evidence, return
// { skipped, failures }. Injectable inputs so tests drive logic without the FS. Throws
// nothing; the caller treats a thrown I/O error as a separate fail-closed halt, exactly like
// gate-pre-phase4.mjs.
export function runFrontendGate({ touchesFrontend, evidence }) {
  if (!touchesFrontend) {
    return { skipped: true, failures: [] };
  }
  const failures = [];
  const ev = evidence || {};

  // A present Design verdict is required (the reviewer ran). An absent design_review on a
  // frontend diff means the reviewer was never dispatched: that is a halt, not a pass.
  if (typeof ev.verdict !== "string") {
    failures.push("frontend diff but no design_review verdict recorded");
  }
  if (ev.lint_pass !== true) {
    failures.push("frontend diff but lint pass not recorded (lint_pass !== true)");
  }
  if (ev.a11y_pass !== true) {
    failures.push("frontend diff but accessibility (a11y) pass not recorded (a11y_pass !== true)");
  }

  // Hygiene: any recorded screenshot path must live under .pipeline/<issue>/. A path
  // outside that gitignored tree is a committable-PII vector and is refused here.
  for (const shot of ev.screenshots || []) {
    if (typeof shot !== "string") {
      failures.push("screenshot evidence entry is not a string path");
      continue;
    }
    const norm = shot.replace(/\\/g, "/").replace(/^\.\//, "");
    if (!norm.startsWith(".pipeline/")) {
      failures.push(`screenshot evidence path outside .pipeline/: "${norm.slice(0, 120)}"`);
      continue;
    }
    // A `..` SEGMENT escapes the tree while satisfying the prefix, so the prefix alone is not
    // containment. Segment-wise, not a substring test: `shot..png` is a legitimate filename.
    // Deliberately string-only, no filesystem resolution: the gate runs outside the
    // implementation worktree, where a screenshot that exists there does not exist here.
    if (norm.split("/").includes("..")) {
      failures.push(
        `screenshot evidence path escapes .pipeline/ via a ".." segment: "${norm.slice(0, 120)}"`,
      );
    }
  }

  return { skipped: false, failures };
}

// Normalize a Design-shard or impl-report design_gate object to the flat evidence shape
// runFrontendGate consumes. Both record the same three facts (verdict, lint, a11y) under
// their own field names; this maps either onto { verdict, lint_pass, a11y_pass, screenshots }.
// Legacy token_lint / axe field names are accepted as aliases. Only JSON.parse'd objects
// flow through here.
export function normalizeEvidence(raw) {
  if (!raw || typeof raw !== "object") return {};
  const ev = {};
  if (typeof raw.verdict === "string") ev.verdict = raw.verdict;
  // lint pass: a boolean flag or a "pass" string, under the generic `lint` name or the
  // legacy `token_lint` name.
  if (
    raw.lint_pass === true ||
    raw.lint === "pass" ||
    raw.token_lint_pass === true ||
    raw.token_lint === "pass"
  ) {
    ev.lint_pass = true;
  }
  // a11y pass: a boolean flag or an { status: "pass" } object, under the generic `a11y`
  // name or the legacy `axe` name.
  if (
    raw.a11y_pass === true ||
    (raw.a11y && raw.a11y.status === "pass") ||
    raw.axe_pass === true ||
    (raw.axe && raw.axe.status === "pass")
  ) {
    ev.a11y_pass = true;
  }
  if (Array.isArray(raw.screenshots)) ev.screenshots = raw.screenshots;
  return ev;
}

// ---- argv + I/O (production path) -------------------------------------------

function parseArgs(argv) {
  const args = { changed: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--issue") args.issue = argv[++i];
    else if (a === "--changed") args.changed.push(argv[++i]);
    else if (a === "--evidence") args.evidence = argv[++i];
    else if (a === "--impl-report") args.implReport = argv[++i];
  }
  return args;
}

// Read + JSON.parse, failing CLOSED. A missing file or a parse error is a hard halt,
// matching gate-pre-phase4.mjs. Never eval; JSON.parse only.
function loadJsonOrThrow(file, label) {
  if (!file || !existsSync(file)) {
    throw new Error(`${label} not found at ${file || "(no path resolved)"}`);
  }
  let raw;
  try {
    raw = readFileSync(file, "utf8");
  } catch (e) {
    throw new Error(`${label} could not be read: ${e.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new Error(`${label} is not valid JSON: ${e.message}`);
  }
}

// Derive the changed-path list from impl-report.json commits[].files_changed when --changed
// is not passed. A path the report also records as removed (top-level files_removed or the
// commit's own files_removed) is excluded, mirroring migrationFilesFromReport in
// gate-pre-phase4.mjs: a truthfully-recorded deletion leaves no file behind and must not be
// treated as a present frontend change.
export function changedFilesFromReport(report) {
  const out = new Set();
  const topRemoved = new Set((report.files_removed || []).filter((f) => typeof f === "string"));
  for (const commit of report.commits || []) {
    const removed = new Set(topRemoved);
    for (const r of commit.files_removed || []) {
      if (typeof r === "string") removed.add(r);
    }
    for (const f of commit.files_changed || []) {
      if (typeof f !== "string") continue;
      if (removed.has(f)) continue; // recorded deletion: not on disk, do not infer
      out.add(f);
    }
  }
  return [...out];
}

// True when the report records ANY file list at all (changed or removed, on any commit or at the
// top level). A report that records none is INCONCLUSIVE about what changed: deriving [] from it
// and skipping would be the same fail-open as reading no report at all. files_removed counts, so a
// delete-only diff stays conclusive and is still evaluated.
export function reportRecordsAnyFiles(report) {
  if (!report || typeof report !== "object") return false;
  if ((report.files_removed || []).some((f) => typeof f === "string")) return true;
  for (const commit of report.commits || []) {
    if (!commit || typeof commit !== "object") continue;
    if ((commit.files_changed || []).some((f) => typeof f === "string")) return true;
    if ((commit.files_removed || []).some((f) => typeof f === "string")) return true;
  }
  return false;
}

// Same derivation as changedFilesFromReport, but REFUSES to return an inconclusive empty list.
// Throwing here routes into main()'s fail-closed catch (exit 1) instead of falling through to
// diffTouchesFrontend([]) === false, which prints SKIP and exits 0.
export function changedFilesFromReportStrict(report, label = "impl-report.json") {
  if (!reportRecordsAnyFiles(report)) {
    throw new Error(
      `${label} records no files_changed/files_removed on any commit: cannot determine what the ` +
        `diff touched. Refusing to infer an empty diff (that would skip this gate).`,
    );
  }
  return changedFilesFromReport(report);
}

function resolveImplReportPath(args, issueDir) {
  if (args.implReport) return args.implReport;
  if (!issueDir) return null;
  return path.join(issueDir, "impl-report.json");
}

// Evidence resolution order: an explicit --evidence path, else the Phase 4 Design shard,
// else the Phase 2 Design shard, else the impl-report.json design_gate fallback. Returns the
// raw parsed object (or {} when nothing is present, which is the canonical halt).
function loadEvidence(args, issueDir, implReportPath) {
  if (args.evidence) return loadJsonOrThrow(args.evidence, "design_review evidence");
  if (issueDir) {
    const panel = path.join(issueDir, "peer-review.design_review.json");
    if (existsSync(panel)) return loadJsonOrThrow(panel, "design_review evidence");
    const review = path.join(issueDir, "review.design_review.json");
    if (existsSync(review)) return loadJsonOrThrow(review, "design_review evidence");
  }
  if (implReportPath && existsSync(implReportPath)) {
    const report = loadJsonOrThrow(implReportPath, "impl-report.json");
    if (report && typeof report === "object" && report.design_gate) return report.design_gate;
  }
  return {};
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const issueDir = args.issue ? path.join(PROJECT_ROOT, ".pipeline", String(args.issue)) : null;
  const implReportPath = resolveImplReportPath(args, issueDir);

  // Explicit --changed paths are authoritative. Otherwise the impl-report is the ONLY source for
  // what the diff touched, so an absent/unreadable/unparseable/fileless report is a hard error,
  // NOT an empty change list: loadJsonOrThrow and changedFilesFromReportStrict both throw into the
  // fail-closed catch below. Do not reintroduce an existsSync short-circuit here; that is the
  // fail-open this replaced.
  let changed = args.changed;
  if (changed.length === 0) {
    if (!implReportPath) {
      throw new Error(
        "cannot determine the changed-path list: no --changed paths given and neither --issue " +
          "nor --impl-report resolved an impl-report.json path",
      );
    }
    changed = changedFilesFromReportStrict(
      loadJsonOrThrow(implReportPath, "impl-report.json"),
      implReportPath,
    );
  }
  const touchesFrontend = diffTouchesFrontend(changed);

  let evidence = null;
  if (touchesFrontend) {
    // A frontend diff with no evidence at all is the canonical halt case: loadEvidence
    // returns {} so runFrontendGate reports every missing-evidence failure.
    evidence = normalizeEvidence(loadEvidence(args, issueDir, implReportPath));
  }

  const { skipped, failures } = runFrontendGate({ touchesFrontend, evidence });

  if (skipped) {
    process.stdout.write("SKIP: no frontend surface in the diff; frontend gate is a no-op.\n");
    return;
  }
  if (failures.length === 0) {
    process.stdout.write("OK: frontend visual-verification gate passed.\n");
    return;
  }
  process.stderr.write("FAIL: frontend visual-verification gate blocked the panel.\n");
  for (const f of failures) process.stderr.write(`  - ${f}\n`);
  process.exit(1);
}

const isMain = isMainScript("gate-pre-phase4-frontend.mjs");

if (isMain) {
  main().catch((err) => {
    // FAIL CLOSED: any error (missing/unparseable artifact, internal fault) halts.
    process.stderr.write(`FAIL: frontend gate halted: ${err.message}\n`);
    process.exit(1);
  });
}
