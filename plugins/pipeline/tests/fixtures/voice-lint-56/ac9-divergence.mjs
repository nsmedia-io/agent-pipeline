#!/usr/bin/env node
/**
 * AC9's asserted DIVERGENCE TABLE between voice-lint.mjs's resolveStatus and
 * validate-pipeline-artifact.mjs's activeIssueDir.
 *
 *   node ac9-divergence.mjs <projectDir> <lintPath> <validatorPath>
 *   -> VL=<selected dir basename | NULL | a named failure>
 *      VAL=<selected dir basename | NULL | a named failure>
 *
 * WHAT IS COMPARED, AND WHY NOT THE RETURN VALUES. The two derivations return DIFFERENT TYPES --
 * a parsed record versus a path -- so comparing them directly is vacuous, and AC9 says so in its
 * own text. What both derivations actually decide is the same question, "which issue dir does
 * this session own", so the SELECTED DIRECTORY is the comparable outcome and it is what this
 * prints.
 *
 * voice-lint's selection is defined here as: the dir whose status RECORD it resolved. A named
 * dir whose record will not parse is NOT a selection -- run() reads `resolved?.status
 * ?.current_phase` off it and gets nothing either way -- which is why AC9's (c1) cell measures
 * NULL. That definition is behavioural and survives the return-shape widening design.json
 * commits to; it does not depend on how the wrapper is spelled.
 *
 * NO BEHAVIOUR CHANGE IS ASKED FOR HERE. R4 freezes voice-lint's resolution and this table pins
 * today's behaviour on both sides, including the four cells where the two disagree. Each
 * divergence carries its cause in the suite's assertion label, so a future change that closes or
 * widens one reddens a cell whose label explains why it existed.
 */

import path from "node:path";

const [projectDir, lintPath, validatorPath] = process.argv.slice(2);

let vlSel;
try {
  const { resolveStatus } = await import(lintPath);
  if (typeof resolveStatus !== "function") {
    vlSel = "<voice-lint.mjs does not export resolveStatus>";
  } else {
    // run() passes ONLY the CLAUDE_ spelling. That asymmetry against activeIssueName (which
    // reads input.active_issue, then CLAUDE_PIPELINE_ACTIVE_ISSUE, then PIPELINE_ACTIVE_ISSUE)
    // is the labelled cause of cell (d1), so the driver must reproduce it exactly rather than
    // reading whichever spelling happens to be set.
    const r = resolveStatus(projectDir, process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE);
    if (r === null || r === undefined) {
      vlSel = "NULL";
    } else if (typeof r !== "object") {
      vlSel = `<resolveStatus returned a ${typeof r}>`;
    } else if (!("status" in r)) {
      vlSel =
        "<UNWIDENED RETURN: resolveStatus still returns a bare status record, so the dir it selected is not observable and neither is its mtime>";
    } else if (!r.status) {
      vlSel = "NULL";
    } else if (typeof r.dir !== "string") {
      vlSel = "<resolveStatus returned a status but no `dir` string>";
    } else {
      vlSel = path.basename(r.dir);
    }
  }
} catch (e) {
  vlSel = `<resolveStatus threw ${e.constructor?.name || "Error"}: ${e.message}>`;
}

let valSel;
try {
  const { activeIssueDir } = await import(validatorPath);
  if (typeof activeIssueDir !== "function") {
    valSel = "<validate-pipeline-artifact.mjs does not export activeIssueDir>";
  } else {
    const d = activeIssueDir(path.join(projectDir, ".pipeline"), null);
    valSel = d ? path.basename(d) : "NULL";
  }
} catch (e) {
  valSel = `<activeIssueDir threw ${e.constructor?.name || "Error"}: ${e.message}>`;
}

process.stdout.write(`VL=${vlSel}\nVAL=${valSel}\n`);
