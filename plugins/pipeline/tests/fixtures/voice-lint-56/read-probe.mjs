/**
 * The NON-ZERO CONTROL on AC18's instrument, and nothing else.
 *
 * It reads its argv[2] path exactly N times through the SAME import idiom voice-lint.mjs uses
 * (`import { readFileSync } from "node:fs"`), so a count of N here is evidence the counter in
 * preload.cjs observes reads made by an ES module rather than only reads made by its own caller.
 * Without it, AC18's "exactly 1" is indistinguishable from a counter that never incremented.
 */
import { readFileSync } from "node:fs";
const [, , file, times] = process.argv;
for (let i = 0; i < Number(times); i++) readFileSync(file, "utf8");
