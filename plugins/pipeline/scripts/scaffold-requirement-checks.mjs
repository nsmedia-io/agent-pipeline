#!/usr/bin/env node
/**
 * scaffold-requirement-checks.mjs -- the impl-report coverage skeleton, built from spec.json
 * (#164 row 24).
 *
 *   node scaffold-requirement-checks.mjs --spec <spec.json>
 *
 * Prints JSON: `requirement_checks`, one entry per spec.requirements item (requirement_index,
 * the first 80 characters as requirement_text, and an ac_id when the requirement carries its
 * own AC label), and `acceptance_criteria_met`, one entry per acceptance criterion with ac_id
 * set whenever the criterion has its own label.
 *
 * THE LABEL IS THE GATE'S OWN RULE, IMPORTED. criterionLabel in gate-pre-phase4.mjs decides
 * which label a criterion carries (its leading label, or the one AC label its text carries
 * anywhere; two labels and no leading one is unlabelled). The pre-Phase-4 gate counts a
 * labelled criterion covered only by an entry whose own leading label or ac_id names it, so a
 * skeleton labelled by the same function cannot be refused for coverage it was scaffolded to
 * give. Before this, a Dev who wrote the arrays by hand learned about a missed label only when
 * the gate halted, a full round trip later.
 *
 * WHAT STAYS DEV'S. `status` is null and `met` is null, and `notes` and `evidence` are empty:
 * the schema refuses null, so an unfilled skeleton cannot pass as a filled one. Fill every
 * entry, and write a `justification` for any PARTIAL or SKIP.
 *
 * EXIT. 0 printed. 1 usage, or an unreadable spec or one with no requirements array.
 */

import { readFileSync } from "node:fs";
import { isMain, nativePath } from "./lib.mjs";
import { criterionLabel } from "./gate-pre-phase4.mjs";

export const TEXT_CHARS = 80;

/** "ac3" -> "AC3", the schema's ^AC[0-9]+$ spelling. */
const acId = (label) => (label ? `AC${label.slice(2)}` : null);

export function scaffold(spec) {
  const reqs = Array.isArray(spec.requirements) ? spec.requirements : [];
  const acs = Array.isArray(spec.acceptance_criteria) ? spec.acceptance_criteria : [];
  const requirement_checks = reqs.map((r, i) => {
    const text = String(r ?? "").replace(/\s+/g, " ").trim();
    const entry = { requirement_index: i, requirement_text: text.slice(0, TEXT_CHARS), status: null, notes: "" };
    const id = acId(criterionLabel(text));
    if (id) entry.ac_id = id;
    return entry;
  });
  const acceptance_criteria_met = acs.map((c) => {
    const text = String(c ?? "").replace(/\s+/g, " ").trim();
    const entry = { criterion: text, met: null, evidence: "" };
    const id = acId(criterionLabel(text));
    if (id) entry.ac_id = id;
    return entry;
  });
  const unlabelled = acceptance_criteria_met.filter((e) => !e.ac_id).length;
  return { requirement_checks, acceptance_criteria_met, unlabelled_criteria: unlabelled };
}

const USAGE = "usage: node scaffold-requirement-checks.mjs --spec <spec.json>\n";

export function main(argv, { out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s) } = {}) {
  if (argv.length !== 2 || argv[0] !== "--spec") {
    err(USAGE);
    return 1;
  }
  let spec;
  try {
    spec = JSON.parse(readFileSync(nativePath(argv[1]), "utf8"));
  } catch (e) {
    err(`cannot read --spec ${argv[1]}: ${e.message}\n`);
    return 1;
  }
  if (!spec || typeof spec !== "object" || !Array.isArray(spec.requirements)) {
    err(`--spec ${argv[1]} has no requirements array\n`);
    return 1;
  }
  out(`${JSON.stringify(scaffold(spec), null, 2)}\n`);
  return 0;
}

// Self-run only as a real CLI entry: an eval that imports this module with its own path in argv[1]
// must not run the CLI (the hazard voice-lint.mjs documents at its foot).
const evalEntry = process.execArgv.some((x) => x === "-e" || x === "--eval" || x === "--input-type=module" || /^--eval=/.test(x));
if (isMain("scaffold-requirement-checks.mjs") && !evalEntry) process.exit(main(process.argv.slice(2)));
