/**
 * A CJS preload for the two #56 cells that need to observe or perturb voice-lint's own fs calls:
 * AC18 (the transcript is opened ONCE per invocation) and the judge's statSync-guard cell (a stat
 * failure must read fresh-and-loud, never silent).
 *
 * WHY A CJS PRELOAD AND NOT AN IN-PROCESS PATCH. Measured, on node v24.19.0, before this file
 * existed, because the wrong one of these is a silent green nothing:
 *
 *   node -r ./preload.cjs driver.mjs           -> the patch IS visible to a module that does
 *                                                 `import { statSync } from "node:fs"`
 *   in-process `fs.statSync = ...; await import(...)` -> the patch is NOT visible; the module
 *                                                 keeps the original binding and the probe
 *                                                 reports a happy zero
 *
 * The second form is the one an author reaches for first. It runs, it exits 0, and it reports
 * exactly the numbers a working instrument would report on a run where nothing happened. A
 * counter that is never incremented reports 1 for a run that never opened the file at all, which
 * is why AC18's cell asserts a DELIBERATE 2 from a two-read probe before it trusts a 1.
 *
 * It perturbs NOTHING unless its env var is set, and each perturbation is scoped to paths
 * matching a caller-supplied substring, so node's own module loader is untouched.
 *
 *   VL56_COUNT_PATH   count readFileSync calls whose path CONTAINS this substring
 *   VL56_COUNT_OUT    write "<count>\n" there on exit (the process under test owns stdout)
 *   VL56_STAT_FAIL    statSync on a path CONTAINING this substring throws EACCES
 */

const fs = require("fs");

const countPath = process.env.VL56_COUNT_PATH || "";
const countOut = process.env.VL56_COUNT_OUT || "";
const statFail = process.env.VL56_STAT_FAIL || "";

let reads = 0;

if (countPath) {
  const orig = fs.readFileSync;
  fs.readFileSync = function (p, ...rest) {
    if (typeof p === "string" && p.includes(countPath)) reads++;
    return orig.call(this, p, ...rest);
  };
}

if (statFail) {
  const orig = fs.statSync;
  fs.statSync = function (p, ...rest) {
    if (typeof p === "string" && p.includes(statFail)) {
      const err = new Error(`VL56 forced stat failure on ${p}`);
      err.code = "EACCES";
      throw err;
    }
    return orig.call(this, p, ...rest);
  };
}

if (countOut) {
  // `exit` and not `beforeExit`: voice-lint calls process.exit() explicitly on both of its two
  // legal exit paths, and beforeExit does not fire for an explicit exit. A handler that never
  // ran would leave the count file absent, which the suite reports as <no-count> rather than
  // reading as a zero.
  process.on("exit", () => {
    try {
      fs.writeFileSync(countOut, String(reads) + "\n");
    } catch {
      /* the suite reports an absent count file by name */
    }
  });
}
