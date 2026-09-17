#!/usr/bin/env node
/**
 * AC12's hygiene scan over the #56 suite and its fixture helpers.
 *
 *   node hygiene-scan.mjs <file...>  -> a " ;; "-joined LIST of violations, or the empty string
 *
 * THREE THINGS NO TEST CELL MAY DO, and each is a defect this repo has already paid for:
 *   - name the default remote branch ref, or resolve any range against it. A test whose range
 *     reads a moving ref breaks the moment it merges, by any strategy, and it makes the
 *     POPULATION under test depend on where the branch happens to be sitting.
 *   - resolve a range with any other porcelain command, which is the same defect wearing a
 *     different spelling.
 *   - read the repository's own pipeline state directory. run.sh is this project's checkCommand
 *     and the Stop hook executes it at every dirty-tree turn end, i.e. DURING live pipeline runs,
 *     so a cell that touched the real state dir would corrupt the run executing it.
 *
 * THE ASSERTION OVER THIS IS THE HIT LIST, NEVER A COUNT: a cell added and another removed
 * cannot cancel. Comments are exempt from the state-dir rule and ONLY from that one, because a
 * comment cannot read anything; the range rules apply to comments too, so a commented-out range
 * cannot be uncommented without a cell noticing.
 *
 * THE PATTERNS ARE COMPOSED RATHER THAN WRITTEN AS LITERALS so that this file is CLEAN UNDER ITS
 * OWN RULES and can therefore be included in its own input list. A scanner excluded from its own
 * population is a scanner nobody checks.
 */

import { readFileSync } from "node:fs";
import path from "node:path";

const MOVING_REF = new RegExp("origin" + "/" + "main");
const RANGE_CMD = new RegExp("\\bgit\\s+(diff|log|rev-list|merge-base|rev-parse|describe|show)\\b");
const STATE_DIR = new RegExp("\\." + "pipeline");
// A state-dir path is acceptable exactly when the line roots it at a per-case temp dir.
const ROOTED = /(TEMP_PROJECT|TEMP_ISSUE_DIR|VL56_PROJECT|projectDir|pipelineDir)/;

const out = [];
for (const file of process.argv.slice(1)) {
  const lines = readFileSync(file, "utf8").split("\n");
  lines.forEach((line, i) => {
    const t = line.trim();
    const isComment = t.startsWith("#") || t.startsWith("//") || t.startsWith("*");
    const at = `${path.basename(file)}:${i + 1}`;
    if (MOVING_REF.test(line)) out.push(`${at}:names-a-moving-ref`);
    if (RANGE_CMD.test(line)) out.push(`${at}:resolves-a-range`);
    if (!isComment && STATE_DIR.test(line) && !ROOTED.test(line)) {
      out.push(`${at}:reads-an-unrooted-state-dir`);
    }
  });
}
process.stdout.write(out.join(" ;; "));
