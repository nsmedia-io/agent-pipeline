#!/usr/bin/env node
/**
 * owner-gate.mjs -- the two owner gates as code (#164 rows 12, 13).
 *
 *   node owner-gate.mjs open-questions --spec <spec.json> --status <status.json> [--experiment]
 *   node owner-gate.mjs design-lock    --design <design.json> --status <status.json>
 *
 * OPEN-QUESTIONS (Phase 1, after BA returns).
 *   1. The spec's required fields are present: issue_number, title, problem, requirements,
 *      acceptance_criteria, impacted_domains, trivial. A missing one is exit 2 (INVALID).
 *   2. Every open_questions entry with blocking: false and no resolution gets one written into
 *      the spec in place: answered_by "ba_default", answer = ba_recommendation, at = now. The
 *      default is then recorded rather than assumed, which is what Phase 4 checks the build against.
 *   3. The FIRST blocking entry with no resolution is exit 2 (ASK), printed as JSON for the
 *      decision block. One question, not a batch: early answers routinely dissolve later ones.
 *   Experiment mode (--experiment, or a spec whose issue_number is an exp-<slug> placeholder)
 *   never blocks: every unresolved entry resolves to ba_default, because an unattended harness
 *   cannot answer a question.
 *
 * DESIGN-LOCK (Phase 2.5, after the judge returns; also on a resumed or seeded design.json).
 *   owner_decision absent, `required` not a boolean, or required true with any of question,
 *   option_a, option_b, recommendation missing or blank: exit 3, re-dispatch the JUDGE. The key
 *   is optional in design.schema.json and the validator has no if/then, so this is the only check.
 *   required false, or required true and resolved: exit 0.
 *   required true, complete, unresolved: exit 2, ask the owner (the block is printed as JSON).
 *
 * --status is read to refuse a spec or design whose issue_number disagrees with the run record,
 * which is how a gate reads the wrong run's artifact. It is never written.
 *
 * EXIT CODES. 0 proceed. 2 ask the owner (or, INVALID, report and halt). 3 re-dispatch the judge.
 * 1 usage or an unreadable input.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { isMain, nativePath } from "./lib.mjs";

export const SPEC_REQUIRED = ["issue_number", "title", "problem", "requirements", "acceptance_criteria", "impacted_domains", "trivial"];
export const DECISION_FIELDS = ["question", "option_a", "option_b", "recommendation"];

const USAGE =
  "usage:\n" +
  "  node owner-gate.mjs open-questions --spec <spec.json> --status <status.json> [--experiment]\n" +
  "  node owner-gate.mjs design-lock --design <design.json> --status <status.json>\n";

const blank = (v) => typeof v !== "string" || v.trim() === "";

export function isExperimentSpec(spec) {
  return typeof (spec && spec.issue_number) === "string" && /^exp-/.test(spec.issue_number);
}

/**
 * @returns {{code: 0|2, kind: "proceed"|"invalid"|"ask", spec: object, changed: boolean,
 *            missing?: string[], question?: object, remaining?: number, defaulted: string[]}}
 */
export function openQuestionsGate(spec, { experiment = false, now = new Date().toISOString() } = {}) {
  const missing = SPEC_REQUIRED.filter((k) => spec[k] === undefined || spec[k] === null || (typeof spec[k] === "string" && spec[k].trim() === ""));
  if (missing.length) return { code: 2, kind: "invalid", spec, changed: false, missing, defaulted: [] };

  const exp = experiment || isExperimentSpec(spec);
  const list = Array.isArray(spec.open_questions) ? spec.open_questions : [];
  const defaulted = [];
  const unresolvedNoRec = [];
  let changed = false;
  for (const q of list) {
    if (!q || typeof q !== "object" || q.resolution) continue;
    if (q.blocking === true && !exp) continue;
    if (blank(q.ba_recommendation)) {
      unresolvedNoRec.push(q.id || "(no id)");
      continue;
    }
    q.resolution = { answer: q.ba_recommendation, answered_by: "ba_default", at: now };
    defaulted.push(q.id || "(no id)");
    changed = true;
  }
  if (unresolvedNoRec.length) {
    return { code: 2, kind: "invalid", spec, changed, missing: unresolvedNoRec.map((id) => `open_questions[${id}].ba_recommendation`), defaulted };
  }
  const open = exp ? [] : list.filter((q) => q && typeof q === "object" && q.blocking === true && !q.resolution);
  if (open.length) {
    const q = open[0];
    const question = { id: q.id, question: q.question, why_it_matters: q.why_it_matters, options: q.options || [], ba_recommendation: q.ba_recommendation };
    return { code: 2, kind: "ask", spec, changed, question, remaining: open.length - 1, defaulted };
  }
  return { code: 0, kind: "proceed", spec, changed, defaulted };
}

/** @returns {{code: 0|2|3, reason: string, block?: object}} */
export function designLockGate(design) {
  if (!design || typeof design !== "object" || !("owner_decision" in design)) {
    return { code: 3, reason: "owner_decision is absent: re-dispatch the judge to add its ruling" };
  }
  const od = design.owner_decision;
  if (!od || typeof od !== "object" || typeof od.required !== "boolean") {
    return { code: 3, reason: "owner_decision.required is not a boolean: re-dispatch the judge" };
  }
  if (od.required === false) return { code: 0, reason: "the stances converged (required: false)" };
  const gaps = DECISION_FIELDS.filter((k) => blank(od[k]));
  if (gaps.length) {
    return { code: 3, reason: `owner_decision is required but ${gaps.join(", ")} missing or empty: re-dispatch the judge; do not fill it in yourself` };
  }
  const res = od.resolution;
  if (res && typeof res === "object" && !blank(res.chosen) && !blank(res.resolved_at)) {
    return { code: 0, reason: `the owner resolved it (${res.chosen})` };
  }
  return {
    code: 2,
    reason: "the stances materially diverged and the call is the owner's",
    block: { question: od.question, option_a: od.option_a, option_b: od.option_b, recommendation: od.recommendation },
  };
}

function readJson(file, label) {
  try {
    return JSON.parse(readFileSync(nativePath(file), "utf8"));
  } catch (e) {
    throw new Error(`cannot read --${label} ${file}: ${e.message}`);
  }
}

function sameIssue(doc, status) {
  const a = doc && doc.issue_number;
  const b = status && status.issue_number;
  if (a === undefined || a === null || b === undefined || b === null) return true;
  return String(a) === String(b);
}

export function main(argv, { out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s), now } = {}) {
  const [cmd, ...rest] = argv;
  const a = {};
  for (let i = 0; i < rest.length; i++) {
    const k = rest[i];
    if (k === "--spec" || k === "--status" || k === "--design") a[k.slice(2)] = rest[++i];
    else if (k === "--experiment") a.experiment = true;
    else {
      err(`owner-gate: unknown argument ${k}\n${USAGE}`);
      return 1;
    }
  }
  try {
    if (cmd === "open-questions") {
      if (!a.spec || !a.status) {
        err(USAGE);
        return 1;
      }
      const spec = readJson(a.spec, "spec");
      const status = readJson(a.status, "status");
      if (!sameIssue(spec, status)) {
        err(`owner-gate: spec issue_number ${spec.issue_number} is not status issue_number ${status.issue_number}; wrong artifact\n`);
        return 1;
      }
      const r = openQuestionsGate(spec, { experiment: !!a.experiment, now });
      if (r.changed) writeFileSync(nativePath(a.spec), `${JSON.stringify(r.spec, null, 2)}\n`);
      if (r.defaulted.length) out(`DEFAULTED: ${r.defaulted.join(", ")} resolved to ba_default\n`);
      if (r.kind === "invalid") {
        out(`INVALID: missing or empty: ${r.missing.join(", ")}\n`);
        return 2;
      }
      if (r.kind === "ask") {
        out(`ASK: ${JSON.stringify(r.question)}\n`);
        out(`REMAINING: ${r.remaining}\n`);
        return 2;
      }
      out("PROCEED\n");
      return 0;
    }
    if (cmd === "design-lock") {
      if (!a.design || !a.status) {
        err(USAGE);
        return 1;
      }
      const design = readJson(a.design, "design");
      const status = readJson(a.status, "status");
      if (!sameIssue(design, status)) {
        err(`owner-gate: design issue_number ${design.issue_number} is not status issue_number ${status.issue_number}; wrong artifact\n`);
        return 1;
      }
      const r = designLockGate(design);
      if (r.code === 2) {
        out(`ASK: ${JSON.stringify(r.block)}\n`);
        return 2;
      }
      out(`${r.code === 0 ? "PROCEED" : "REDISPATCH_JUDGE"}: ${r.reason}\n`);
      return r.code;
    }
  } catch (e) {
    err(`owner-gate: ${e.message}\n`);
    return 1;
  }
  err(USAGE);
  return 1;
}

if (isMain("owner-gate.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
