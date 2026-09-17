#!/usr/bin/env node
/**
 * round-budget.mjs -- the review-loop budget as code, not prose.
 *
 * WHY. The convergence budget in commands/pipeline.md said "one fix round by default, a second
 * is the owner's call" for several releases, and nothing counted. Measured on one consumer: a
 * single tooling issue ran 21 spec revisions and 8 Phase 4 panel rounds. Each loop-back was
 * individually justified, which is exactly why a sentence could not stop it: the orchestrator
 * reading the sentence was also the one holding a real finding. So the count lives in
 * status.json (fix_rounds, spec_revisions), the budget lives here, and going past it needs an
 * owner_overrides entry that only the owner's answer produces.
 *
 *   node round-budget.mjs check fix-round      --status <status.json>
 *   node round-budget.mjs enter fix-round      --status <status.json>   (check, then +1 and write)
 *   node round-budget.mjs check spec-revision  --status <status.json>
 *   node round-budget.mjs enter spec-revision  --status <status.json>
 *   node round-budget.mjs spec-size            --spec <spec.json> [--status <status.json>]
 *
 * EXIT CODES. 0 allowed. 2 REFUSED: the round is past the budget and no override covers it, or a
 * tooling spec is over size without a justification; stdout carries the owner decision block to
 * bring to the owner verbatim. 1 usage or an unreadable input: a budget that cannot read its
 * counter cannot know the round is inside the budget, so it does not say yes.
 *
 * BUDGETS. Phase 4 fix rounds: tooling 1, product 2, product-money 2. Spec revisions after
 * Phase 2: 2 at every cost class. A record with no cost_class reads as product, and a record
 * with no counter reads as 0; both are said on stderr (a pre-schema_version-2 run).
 *
 * The functions are exported so a phase-entry gate can call them directly; this change wires
 * them from the prose at the fix-round and spec-revision points only.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { isMain } from "./lib.mjs";
import { normCostClass, COST_CLASSES } from "./materiality.mjs";

export const STATUS_SCHEMA_VERSION = 2;
export const FIX_ROUND_BUDGET = { tooling: 1, product: 2, "product-money": 2 };
export const SPEC_REVISION_BUDGET = 2;
export const TOOLING_AC_LIMIT = 12;
export const KINDS = ["fix-round", "spec-revision"];

const COUNTER = { "fix-round": "fix_rounds", "spec-revision": "spec_revisions" };

export function budgetFor(kind, costClass) {
  if (kind === "fix-round") return FIX_ROUND_BUDGET[normCostClass(costClass)];
  if (kind === "spec-revision") return SPEC_REVISION_BUDGET;
  throw new Error(`unknown kind ${JSON.stringify(kind)}; expected one of ${KINDS.join(", ")}`);
}

/** The override entry that covers round `n` of `kind`, or null. */
export function coveringOverride(status, kind, n) {
  const list = Array.isArray(status && status.owner_overrides) ? status.owner_overrides : [];
  return (
    list.find(
      (o) => o && typeof o === "object" && o.kind === kind && Number.isInteger(o.up_to) && o.up_to >= n && typeof o.at === "string" && o.at !== "",
    ) || null
  );
}

/**
 * Decide whether the NEXT round of `kind` may start. Pure.
 * @returns {{allowed, kind, next, budget, costClass, override, warnings, decision}}
 */
export function checkRoundBudget(status, kind) {
  if (!KINDS.includes(kind)) throw new Error(`unknown kind ${JSON.stringify(kind)}; expected one of ${KINDS.join(", ")}`);
  const st = status && typeof status === "object" ? status : {};
  const warnings = [];
  const costClass = normCostClass(st.cost_class);
  // The warning names the class the budget ACTUALLY applies: a mixed-case "Tooling" is read as
  // tooling (normCostClass lowercases), and only a value that normalizes to nothing known reads
  // as product.
  if (st.cost_class === undefined) warnings.push("status.json carries no cost_class; reading it as product");
  else if (!COST_CLASSES.includes(st.cost_class)) {
    warnings.push(
      costClass === String(st.cost_class).trim().toLowerCase()
        ? `status.json cost_class ${JSON.stringify(st.cost_class)} is not spelled as one of ${COST_CLASSES.join(", ")}; reading it as ${costClass}`
        : `status.json cost_class ${JSON.stringify(st.cost_class)} is not one of ${COST_CLASSES.join(", ")}; reading it as ${costClass}`,
    );
  }
  const field = COUNTER[kind];
  const raw = st[field];
  const budget = budgetFor(kind, costClass);
  let done = 0;
  if (raw === undefined) warnings.push(`status.json carries no ${field} (a record older than schema_version ${STATUS_SCHEMA_VERSION}); counting from 0`);
  else if (Number.isInteger(raw) && raw >= 0) done = raw;
  else {
    // A counter that is present but unreadable (null, a string, a negative) cannot say the round
    // is inside the budget, and no override can cover a round nobody can number. It is a
    // REFUSAL with the owner decision, not a bare error: the owner still needs the choice.
    warnings.push(`status.json ${field} is ${JSON.stringify(raw)}, not a non-negative integer; the round cannot be counted`);
    return {
      allowed: false,
      kind,
      next: null,
      budget,
      costClass,
      override: null,
      warnings,
      decision: decisionBlock({ kind, next: null, budget, costClass, issue: st.issue_number, unreadable: field }),
    };
  }
  const next = done + 1;
  const override = next > budget ? coveringOverride(st, kind, next) : null;
  const allowed = next <= budget || override !== null;
  return {
    allowed,
    kind,
    next,
    budget,
    costClass,
    override,
    warnings,
    decision: allowed ? null : decisionBlock({ kind, next, budget, costClass, issue: st.issue_number }),
  };
}

/** The plain-language owner decision block, in voice.md's shape. */
export function decisionBlock({ kind, next, budget, costClass, issue, unreadable = null }) {
  const what = kind === "fix-round" ? "fix round" : "spec revision";
  const issueRef = issue === undefined || issue === null ? "this issue" : `issue #${issue}`;
  const nextLabel = next === null ? "another" : String(next);
  const why = unreadable
    ? `The record that counts ${what}s (${unreadable} in status.json) is unreadable, so the pipeline cannot tell whether another round is inside the budget of ${budget} for a ${costClass} change.`
    : kind === "fix-round"
      ? `The reviewers still hold a blocking finding after ${budget} fix round(s), which is the budget for a ${costClass} change. Another round is more likely to trade one finding for the next than to finish.`
      : `The spec has already been revised ${budget} time(s) after its first review. A spec that keeps changing after review usually holds more than one piece of work.`;
  return [
    "### I need a decision",
    "",
    unreadable
      ? `**What I'm asking:** ${issueRef} cannot count its ${what}s. Should we ship it with the open findings written down, split it, or stop?`
      : `**What I'm asking:** ${issueRef} has used its ${what} budget (${budget}). Should we ship it with the open findings written down, split it, or stop?`,
    "",
    `**Why I'm asking:** ${why} Going past the budget is your call, not the pipeline's.`,
    "",
    "**Options:**",
    "  A) Ship with deferrals - merge what passed; every open finding goes on the issue's deferral checklist, and only a finding that could cost money, data, security or a false green gets its own tracker issue.",
    `  B) Split - keep the part that passed review in this issue and open a new issue for the rest, which starts with a fresh budget.`,
    `  C) Stop - leave the branch unmerged; nothing changes for users, and the work so far stays on the branch.`,
    unreadable
      ? `  D) Keep going - I first correct ${unreadable} in status.json to the number of ${what}s actually run, then run the budget check again, and record an owner_overrides entry only if that round is past the budget.`
      : `  D) Keep going - allow ${what} ${nextLabel}. I record your answer in status.json owner_overrides as {"kind": "${kind}", "up_to": ${nextLabel}, "at": "<now>", "reason": "<your reason>"} and continue.`,
    "",
    "**My recommendation:** [fill in from the open blockers: A when they are notes in all but name, B when they sit in a different part of the change from the rest]",
    "",
    "**Blast radius:** [Contained / Spreading / Foundation]",
    "**Reversibility:** [Undo button / Some cleanup / One way door]",
    "**Confidence:** [Solid / Reasoned / Guess]",
  ].join("\n");
}

/** A tooling spec over the AC limit with no size_justification is refused. Pure. */
export function checkSpecSize(spec, status) {
  const s = spec && typeof spec === "object" ? spec : {};
  const costClass = normCostClass(s.cost_class ?? (status && status.cost_class));
  const acs = Array.isArray(s.acceptance_criteria) ? s.acceptance_criteria.length : 0;
  const justified = typeof s.size_justification === "string" && s.size_justification.trim() !== "";
  const allowed = !(costClass === "tooling" && acs > TOOLING_AC_LIMIT && !justified);
  return {
    allowed,
    costClass,
    acceptanceCriteria: acs,
    message: allowed
      ? `spec size ok: ${acs} acceptance criteria at cost_class ${costClass}${justified ? " (size_justification present)" : ""}`
      : `REFUSED: a tooling spec carries ${acs} acceptance criteria (limit ${TOOLING_AC_LIMIT}) and no size_justification. Return it to BA: split it, cut it, or write size_justification saying why this is one issue.`,
  };
}

function readJson(file, label) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    throw new Error(`cannot read ${label} ${file}: ${e.message}`);
  }
}

const USAGE =
  "usage:\n" +
  "  node round-budget.mjs <check|enter> <fix-round|spec-revision> --status <status.json>\n" +
  "  node round-budget.mjs spec-size --spec <spec.json> [--status <status.json>]\n";

export function main(argv, io = { out: (s) => process.stdout.write(s), err: (s) => process.stderr.write(s) }) {
  const pos = [];
  let statusFile = null;
  let specFile = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--status") statusFile = argv[++i];
    else if (argv[i] === "--spec") specFile = argv[++i];
    else if (argv[i].startsWith("--")) {
      io.err(`round-budget: unknown flag ${argv[i]}\n${USAGE}`);
      return 1;
    } else pos.push(argv[i]);
  }
  const [cmd, kind] = pos;
  try {
    if (cmd === "spec-size") {
      if (!specFile) throw new Error("--spec <spec.json> is required");
      const status = statusFile ? readJson(statusFile, "status") : null;
      const r = checkSpecSize(readJson(specFile, "spec"), status);
      (r.allowed ? io.out : io.err)(`round-budget: ${r.message}\n`);
      return r.allowed ? 0 : 2;
    }
    if ((cmd === "check" || cmd === "enter") && KINDS.includes(kind)) {
      if (!statusFile) throw new Error("--status <status.json> is required");
      const status = readJson(statusFile, "status");
      const r = checkRoundBudget(status, kind);
      for (const w of r.warnings) io.err(`round-budget: ${w}\n`);
      if (!r.allowed) {
        io.err(
          r.next === null
            ? `round-budget: REFUSED ${kind}: the counter is unreadable, so the round cannot be counted against the budget of ${r.budget}. Bring the owner the decision below; do not start the round.\n`
            : `round-budget: REFUSED ${kind} ${r.next}: the budget at cost_class ${r.costClass} is ${r.budget} and no owner_overrides entry covers it. Bring the owner the decision below; do not start the round.\n`,
        );
        io.out(`${r.decision}\n`);
        return 2;
      }
      const how = r.override ? `, covered by the owner override recorded at ${r.override.at}` : "";
      if (cmd === "enter") {
        status[COUNTER[kind]] = r.next;
        if (status.schema_version === undefined || status.schema_version < STATUS_SCHEMA_VERSION) status.schema_version = STATUS_SCHEMA_VERSION;
        writeFileSync(statusFile, `${JSON.stringify(status, null, 2)}\n`);
        io.out(`round-budget: entered ${kind} ${r.next} of ${r.budget} (cost_class ${r.costClass}${how}); ${COUNTER[kind]} is now ${r.next}\n`);
      } else {
        io.out(`round-budget: ${kind} ${r.next} of ${r.budget} is allowed (cost_class ${r.costClass}${how})\n`);
      }
      return 0;
    }
    io.err(USAGE);
    return 1;
  } catch (e) {
    io.err(`round-budget: ${e.message}; nothing was allowed\n`);
    return 1;
  }
}

if (isMain("round-budget.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
