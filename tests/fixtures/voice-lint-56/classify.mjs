#!/usr/bin/env node
/**
 * Drives voice-lint.mjs's EXPORTED isHumanTurnRecord over one captured record class, optionally
 * mutated, and prints its verdict. One record in, one boolean out.
 *
 *   node classify.mjs <lintPath> <capturedClassName> [opsJson]
 *   -> CLASSIFY=true | CLASSIFY=false | CLASSIFY=<a named failure>
 *
 * WHY THIS EXISTS SEPARATELY FROM THE CLI CELLS. AC8(f)'s nesting pair is the only thing in this
 * spec that catches R5's fatal misreading (record.message?.origin?.kind instead of
 * record.origin?.kind), which ships as a permanent, total, silent no-op that looks exactly like
 * the control working. Both Phase-2 reviewers could only verify that cell by building their own
 * reference predicate, because a process exit code is moved by four other things. design.json
 * grafts the exported classifier from Sketch B for precisely this reason: it lets the shipped
 * predicate be driven directly against a captured owner record and its relocated twin.
 *
 * IT DRIVES THE SHIPPED PREDICATE, NEVER A REIMPLEMENTATION OF IT. If this file ever grows its
 * own copy of the six clauses, every cell below becomes a test of this file.
 */

import { captured, applyOps } from "./build.mjs";

const [lintPath, className, opsJson] = process.argv.slice(2);

let record;
try {
  record = className === "@literal" ? JSON.parse(opsJson) : captured(className);
  if (className !== "@literal") applyOps(record, opsJson ? JSON.parse(opsJson) : []);
} catch (e) {
  process.stdout.write(`CLASSIFY=<fixture could not be built: ${e.message}>\n`);
  process.exit(0);
}

let mod;
try {
  mod = await import(lintPath);
} catch (e) {
  process.stdout.write(`CLASSIFY=<voice-lint.mjs could not be imported: ${e.message}>\n`);
  process.exit(0);
}

if (typeof mod.isHumanTurnRecord !== "function") {
  // A NAMED failure, not a skip and not a throw. A `beforeAll` that throws on a missing
  // dependency turns N cells into N skips, and a run reporting skips at exit 0 is
  // indistinguishable from a run that checked nothing.
  process.stdout.write(
    "CLASSIFY=<voice-lint.mjs does not export isHumanTurnRecord: R5's positive-provenance predicate is not implemented>\n",
  );
  process.exit(0);
}

let verdict;
try {
  verdict = mod.isHumanTurnRecord(record);
} catch (e) {
  // R11: a malformed-but-parseable record must be classified as NOT a human turn, never thrown
  // on. A throw here lands in main()'s blanket catch in production and exits 0 silently, which
  // is R3's exact inversion.
  verdict = `<THREW ${e.constructor?.name || "Error"}: ${e.message}>`;
}

process.stdout.write(`CLASSIFY=${verdict === true ? "true" : verdict === false ? "false" : String(verdict)}\n`);
