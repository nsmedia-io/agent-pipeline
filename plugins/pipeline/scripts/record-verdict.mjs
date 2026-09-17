#!/usr/bin/env node
/**
 * record-verdict.mjs -- the Phase 4 final verdict, its record and its loop target, as code (#164).
 *
 * WHY. finalVerdict() and countVerdicts() already held the rubric and the tally, with no command
 * over them, so the orchestrator applied a five-row rubric by hand, counted verdicts with a
 * `node -e` one-liner (over the delta subset, more than once, instead of the full panel), and
 * read the loop-back target and the budget numbers out of a table restated in six places. A hand
 * reading that disagrees with the code is the defect the rubric itself names.
 *
 *   node record-verdict.mjs --status <status.json> --peer-review <peer-review.json>
 *                           [--note N] [--veto-reason R] [--pr-body <file>] [--commit]
 *
 * WHAT IT DOES. Reads the FULL panel from status.json panel_roles (never a delta subset), refuses
 * when any seated role has no recoverable verdict, computes final_verdict with materiality.mjs's
 * finalVerdict and the counts with merge-peer-review.mjs's countVerdicts, and writes them through
 * checkpoint.mjs's ENTER transition in one write: the 4-review exit event carrying the panel's
 * verdict token, then current_phase 4-review-complete (4-veto-rework-required on a SecOps veto,
 * with veto_reason). It prints, one KEY=VALUE per line:
 *   final_verdict=<V>   counts=<json>   next=merge|dev|ba|judge   [then=<target>]
 *   budget=<fix-round|spec-revision> round=<n> of=<budget> allowed=yes|no|override
 * and, when the budget refuses, the owner decision block from round-budget.mjs.
 *
 * NEXT. APPROVE and APPROVE_WITH_NOTES: merge. REQUEST_CHANGES and REQUEST_REFACTOR: dev, through
 * `checkpoint.mjs enter 3-impl --loopback`, which spends the fix round; when the round is allowed
 * only by an owner override at the architectural tier, the judge re-opens the design first
 * (next=judge then=dev). SECOPS_VETO: ba, through `checkpoint.mjs enter 1-ba --loopback`, which
 * spends a spec revision; at the architectural tier then=judge, before the next implementation.
 *
 * --pr-body writes the Phase 4 summary comment: one row per panel role with its verdict and open
 * blocker ids, the lenses not seated below the architectural tier, and the final verdict.
 *
 * EXIT CODES. 0 APPROVE or APPROVE_WITH_NOTES. 3 REQUEST_CHANGES or REQUEST_REFACTOR. 4
 * SECOPS_VETO. 1 usage, an unreadable input, a missing verdict or an empty panel; nothing was
 * written. 2 the checkpoint refused the write.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { isMain, nativePath } from "./lib.mjs";
import { finalVerdict, normVerdict } from "./materiality.mjs";
import { countVerdicts } from "./merge-peer-review.mjs";
import { checkRoundBudget } from "./round-budget.mjs";
import { applyEnter, readStatus, writeAtomic, commitStatus, RefusalError } from "./checkpoint.mjs";

export const EXIT_FOR = {
  APPROVE: 0,
  APPROVE_WITH_NOTES: 0,
  REQUEST_CHANGES: 3,
  REQUEST_REFACTOR: 3,
  SECOPS_VETO: 4,
};
const PANEL_VERDICTS = new Set(["APPROVE", "APPROVE_WITH_NOTES", "REQUEST_CHANGES", "REQUEST_REFACTOR", "VETO"]);
export const CORE_LENSES = ["ba", "dba", "devops", "secops", "dev", "qa"];
export const ROLE_NAMES = {
  ba: "BA",
  dba: "DBA",
  devops: "DevOps",
  secops: "SecOps",
  dev: "Dev",
  qa: "QA",
  design_review: "Design",
  art_director: "Art Director",
};

/** Verdict, counts, loop target and budget, pure. Throws RefusalError(1) on an unusable input. */
export function decide(status, peerReview) {
  const roles = Array.isArray(status && status.panel_roles) ? status.panel_roles.filter((r) => typeof r === "string") : [];
  if (roles.length === 0) throw new RefusalError("status.json carries no panel_roles; the verdict is computed over the FULL recorded panel", 1);
  if (!peerReview || typeof peerReview !== "object" || Array.isArray(peerReview)) throw new RefusalError("peer-review.json is not an object", 1);
  const missing = roles.filter((r) => !PANEL_VERDICTS.has(normVerdict(peerReview[r] && peerReview[r].verdict)));
  if (missing.length) {
    throw new RefusalError(`no recoverable verdict for panel role(s) ${missing.join(", ")} in peer-review.json; a missing review is a halt, not a pass`, 1);
  }
  const verdict = finalVerdict(peerReview, roles);
  if (!verdict) throw new RefusalError("the rubric reached no verdict over the panel", 1);
  const counts = countVerdicts(peerReview, roles);
  const architectural = status.risk_tier === "architectural";
  let next = "merge";
  let then = null;
  let budget = null;
  if (verdict === "REQUEST_CHANGES" || verdict === "REQUEST_REFACTOR") {
    budget = checkRoundBudget(status, "fix-round");
    next = "dev";
    if (budget.allowed && budget.override && architectural) {
      next = "judge";
      then = "dev";
    }
  } else if (verdict === "SECOPS_VETO") {
    budget = checkRoundBudget(status, "spec-revision");
    next = "ba";
    if (architectural) then = "judge";
  }
  return { roles, verdict, counts, next, then, budget, exitCode: EXIT_FOR[verdict] };
}

/** The PR summary comment, pure. */
export function prBody(status, peerReview, d) {
  const tier = typeof status.risk_tier === "string" ? status.risk_tier : "standard";
  const lines = [`## Phase 4 Peer Review (${tier} tier panel)`, "| Agent | Verdict | Blockers |", "|---|---|---|"];
  for (const r of d.roles) {
    const b = peerReview[r] || {};
    const ids = Array.isArray(b.materiality && b.materiality.open_blocker_ids) ? b.materiality.open_blocker_ids : [];
    const shown = normVerdict(b.verdict) + (b.verdict_as_returned && normVerdict(b.verdict_as_returned) !== normVerdict(b.verdict) ? ` (returned ${normVerdict(b.verdict_as_returned)})` : "");
    lines.push(`| ${ROLE_NAMES[r] || r} | ${shown} | ${ids.length ? ids.join(", ") : "-"} |`);
  }
  lines.push("");
  const unseated = CORE_LENSES.filter((l) => !d.roles.includes(l)).map((l) => ROLE_NAMES[l]);
  if (unseated.length && tier !== "architectural") lines.push(`Not on panel (${tier} tier): ${unseated.join(", ")}`);
  lines.push(`**Final verdict:** ${d.verdict}`);
  return `${lines.join("\n")}\n`;
}

const USAGE =
  "usage: node record-verdict.mjs --status <status.json> --peer-review <peer-review.json> [--note N] [--veto-reason R] [--pr-body <file>] [--commit]\n";

export function main(argv, io = { out: (s) => process.stdout.write(s), err: (s) => process.stderr.write(s) }) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (["--status", "--peer-review", "--note", "--veto-reason", "--pr-body"].includes(a)) {
      if (i + 1 >= argv.length) {
        io.err(`record-verdict: ${a} needs a value\n${USAGE}`);
        return 1;
      }
      o[a.slice(2)] = argv[++i];
    } else if (a === "--commit") o.commit = true;
    else {
      io.err(`record-verdict: unknown argument ${a}\n${USAGE}`);
      return 1;
    }
  }
  try {
    if (!o.status || !o["peer-review"]) throw new RefusalError(`--status and --peer-review are required\n${USAGE}`, 1);
    const statusFile = nativePath(o.status);
    const status = readStatus(statusFile);
    let peerReview;
    try {
      peerReview = JSON.parse(readFileSync(nativePath(o["peer-review"]), "utf8"));
    } catch (e) {
      throw new RefusalError(`cannot read peer-review ${o["peer-review"]}: ${e.message}`, 1);
    }
    const d = decide(status, peerReview);
    const veto = d.verdict === "SECOPS_VETO";
    const extra = { final_verdict: d.verdict, peer_review_verdict_counts: d.counts };
    if (veto && o["veto-reason"] !== undefined) extra.veto_reason = o["veto-reason"];
    const { status: written } = applyEnter(status, veto ? "4-veto-rework-required" : "4-review-complete", {
      exitVerdict: veto ? "VETO" : d.verdict,
      exitPhase: "4-review",
      note: o.note,
      extra,
    });
    writeAtomic(statusFile, written);
    if (o["pr-body"]) writeFileSync(nativePath(o["pr-body"]), prBody(status, peerReview, d));
    const out = [`final_verdict=${d.verdict}`, `counts=${JSON.stringify(d.counts)}`, `next=${d.next}`];
    if (d.then) out.push(`then=${d.then}`);
    if (d.budget) {
      const allowed = !d.budget.allowed ? "no" : d.budget.override ? "override" : "yes";
      out.push(`budget=${d.budget.kind} round=${d.budget.next === null ? "unreadable" : d.budget.next} of=${d.budget.budget} allowed=${allowed}`);
    }
    const delta = written.telemetry && written.telemetry.review_rounds_recorded_delta;
    if (delta) out.push(`review_rounds_recorded_delta=${delta}`);
    if (o.commit) out.push(`committed=${commitStatus(statusFile, written, `record Phase 4 verdict ${d.verdict}`)}`);
    io.out(`${out.join("\n")}\n`);
    if (d.budget && !d.budget.allowed) io.out(`${d.budget.decision}\n`);
    return d.exitCode;
  } catch (e) {
    if (e instanceof RefusalError) {
      if (e.stdout) io.out(e.stdout);
      io.err(`record-verdict: ${e.message}\n`);
      return e.code;
    }
    io.err(`record-verdict: ${e.message}; nothing was written\n`);
    return 1;
  }
}

if (isMain("record-verdict.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
