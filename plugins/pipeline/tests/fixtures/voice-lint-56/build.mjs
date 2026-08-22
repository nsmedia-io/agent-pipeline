#!/usr/bin/env node
/**
 * Fixture builder for #56's turn-scope cells in tests/test-voice-lint.sh.
 *
 * WHY A FILE RATHER THAN INLINE `node -e`. This suite's existing idiom is a single-quoted inline
 * program (vl_account, tripart), and that idiom is fine at 30 lines. At this size it is a hazard
 * the file already documents against itself: bash 3.2 scans a command substitution for its
 * closing paren without honouring quoted-heredoc rules, and a truncated backtick or a stray
 * single quote takes the whole suite un-parseable. Every cell below builds the SAME two things
 * (a .pipeline tree with stamped mtimes, and a JSONL transcript), so one builder driven by a
 * spec is also the thing that makes AC1 and AC2 "differ ONLY in the mtime, built from one shared
 * fixture builder" a structural fact rather than a promise.
 *
 * IT WRITES NOTHING OUTSIDE THE PROJECT DIR IT IS HANDED, which is always a registered temp dir
 * from harness.sh's new_tmpdir. It reads exactly one path in the checkout: the captured-records
 * file beside it.
 *
 * USAGE
 *   node build.mjs <projectDir> <specJson>   -> builds, prints one STAMP line per stamped file
 *   node build.mjs --facts                   -> prints the pinned present-tense facts of every
 *                                               captured record class, as KEY=value lines
 *
 * MTIME STAMPING IS utimesSync, PER R8, NEVER `touch -t`. BSD touch on macOS has no `-d @<epoch>`
 * form and GNU touch on ubuntu-latest does, so the obvious bash idiom is a fixture that passes in
 * CI and fails on the author's machine; and `touch -t` takes a LOCAL-clock value while transcript
 * timestamps are UTC ISO, so a fixture mixing the two measures the runner's timezone. Every stamp
 * is READ BACK and its drift printed, so a stamp that silently no-ops is named where it happened
 * instead of reddening a distant cell for the wrong reason.
 */

import { readFileSync, writeFileSync, mkdirSync, utimesSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CAPTURED = JSON.parse(readFileSync(path.join(HERE, "captured-records.json"), "utf8"));

/** A deep clone of a captured record. Never a reference: cells mutate their own copy. */
export function captured(name) {
  const entry = CAPTURED.records[name];
  if (!entry) {
    throw new Error(
      `no captured record class "${name}". The classes are: ${Object.keys(CAPTURED.records).join(", ")}`,
    );
  }
  return JSON.parse(JSON.stringify(entry.record));
}

// ---- path ops over a record ------------------------------------------------
// Deliberately generic, because every AC8/AC14 mutation is one of three shapes: move a key,
// delete a key, or set a value. A per-mutation helper would be a second place to state the
// same fixture and would drift from the table in the suite.

function parentOf(obj, dotted) {
  const parts = dotted.split(".");
  const leaf = parts.pop();
  let cur = obj;
  for (const p of parts) {
    if (cur[p] === undefined || cur[p] === null || typeof cur[p] !== "object") cur[p] = {};
    cur = cur[p];
  }
  return [cur, leaf];
}

function getPath(obj, dotted) {
  let cur = obj;
  for (const p of dotted.split(".")) {
    if (cur === null || cur === undefined || typeof cur !== "object") return undefined;
    cur = cur[p];
  }
  return cur;
}

export function applyOps(record, ops) {
  for (const op of ops || []) {
    const [kind, a, b] = op;
    if (kind === "set") {
      const [parent, leaf] = parentOf(record, a);
      parent[leaf] = b;
    } else if (kind === "del") {
      const [parent, leaf] = parentOf(record, a);
      delete parent[leaf];
    } else if (kind === "mv") {
      const value = getPath(record, a);
      const [fromParent, fromLeaf] = parentOf(record, a);
      delete fromParent[fromLeaf];
      if (value !== undefined) {
        const [toParent, toLeaf] = parentOf(record, b);
        toParent[toLeaf] = value;
      }
    } else if (kind === "replace") {
      // Wholesale replacement of the record with a literal. Used only by the hand-built
      // isSidechain cell, which is hand-built BECAUSE no capture of that shape exists.
      for (const k of Object.keys(record)) delete record[k];
      Object.assign(record, JSON.parse(JSON.stringify(a)));
    } else {
      throw new Error(`unknown op ${kind}`);
    }
  }
  return record;
}

function isoOf(ms) {
  return new Date(ms).toISOString();
}

// ---- the builder -----------------------------------------------------------

export function buildRecord(spec, globalOps) {
  let record;
  if (spec.k === "assistant") {
    record = {
      type: "assistant",
      timestamp: spec.ts === undefined ? undefined : isoOf(spec.ts),
      message: { role: "assistant", content: [{ type: "text", text: spec.text ?? "" }] },
    };
    if (record.timestamp === undefined) delete record.timestamp;
    // The assistant record is the MESSAGE UNDER TEST and is not a provenance fixture, so the
    // global drift ops (which model a vendor renaming a field the predicate reads on USER
    // records) are not applied to it. lastAssistantText's own accept condition is untouched by
    // this change and AC6 is what holds it.
    return applyOps(record, spec.ops);
  }
  if (spec.k === "literal") {
    return spec.value;
  }
  record = captured(spec.k);
  if (spec.ts !== undefined) record.timestamp = isoOf(spec.ts);
  applyOps(record, globalOps);
  return applyOps(record, spec.ops);
}

function writeTranscript(file, records, globalOps) {
  const lines = records.map((r) => {
    if (r.k === "raw") return r.line;
    return JSON.stringify(buildRecord(r, globalOps));
  });
  writeFileSync(file, lines.join("\n") + "\n");
}

function stampAndReport(file, ms, label, out) {
  utimesSync(file, ms / 1000, ms / 1000);
  const actual = statSync(file).mtimeMs;
  out.push(`STAMP ${label} intended=${ms} actual=${actual} deltaMs=${Math.abs(actual - ms)}`);
}

function build(projectDir, spec) {
  const out = [];
  const pipelineDir = path.join(projectDir, ".pipeline");
  for (const dir of spec.dirs || []) {
    const dirPath = path.join(pipelineDir, dir.name);
    mkdirSync(dirPath, { recursive: true });
    if (dir.status === "absent") continue;
    const file = path.join(dirPath, "status.json");
    if (dir.status === "unparseable") {
      writeFileSync(file, "{ this is not json\n");
    } else {
      const record = { current_phase: dir.phase };
      if (Object.prototype.hasOwnProperty.call(dir, "updated_at") && dir.updated_at !== null) {
        record.updated_at =
          typeof dir.updated_at === "number" && dir.updated_at > 1e11
            ? isoOf(dir.updated_at)
            : dir.updated_at;
      }
      writeFileSync(file, JSON.stringify(record));
    }
    if (dir.mtimeMs !== undefined) stampAndReport(file, dir.mtimeMs, `status:${dir.name}`, out);
  }
  if (spec.transcript) {
    writeTranscript(spec.transcript, spec.records || [], spec.globalOps);
  }
  out.push("BUILT");
  process.stdout.write(out.join("\n") + "\n");
}

// ---- the pinned-facts report ----------------------------------------------
// A captured fixture beats a hand-written one and STILL ROTS. Every fact the cells below lean on
// is emitted here so the suite can assert it as a present-tense property of the capture: if the
// vendor changes a record shape, the pin reddens loudly instead of the fixture quietly satisfying
// whatever cell it sits in.

function facts() {
  const out = [];
  out.push(`CAPTURED_AT=${CAPTURED.captured_at}`);
  out.push(`CLASSES=${Object.keys(CAPTURED.records).sort().join(",")}`);
  for (const [name, entry] of Object.entries(CAPTURED.records)) {
    const r = entry.record;
    const content = r?.message?.content;
    const shape = Array.isArray(content)
      ? `array[${content.map((b) => (b && b.type) || "?").join("+")}]`
      : typeof content;
    out.push(
      [
        `${name}.type=${r?.type}`,
        `${name}.role=${r?.message?.role}`,
        `${name}.isSidechain=${JSON.stringify(r?.isSidechain)}`,
        `${name}.isMeta=${JSON.stringify(r?.isMeta)}`,
        // THE ONE THAT MATTERS MOST. R5: origin is a RECORD-level object, a sibling of type /
        // isSidechain / isMeta / timestamp / message, and NEVER message.origin. An implementation
        // reading record.message?.origin?.kind finds zero human turns on every transcript ever
        // written and ships as a permanent silent no-op that looks exactly like the control
        // working. These two lines are what make a fixture unable to cancel that misreading.
        `${name}.recordLevelOriginKind=${JSON.stringify(r?.origin?.kind)}`,
        `${name}.messageLevelOrigin=${JSON.stringify(r?.message?.origin)}`,
        `${name}.contentShape=${shape}`,
        `${name}.clientVersion=${entry.captured_from_client_version}`,
      ].join("\n"),
    );
  }
  process.stdout.write(out.join("\n") + "\n");
}

// ENTRY GUARD, and it is not decoration. classify.mjs imports this module for `captured` and
// `applyOps`; without the guard that import would run the CLI branch, exit 64 on a missing
// argument, and the importing program's body would never execute -- rc non-zero with no
// explanation, or worse, rc 0 with a green nothing. voice-lint.mjs's own header records the
// same hazard in its own words, having been bitten by it.
const isCli =
  process.argv[1] !== undefined &&
  pathToFileURL(process.argv[1]).href === import.meta.url;

if (isCli) {
  const argv = process.argv.slice(2);
  if (argv[0] === "--facts") {
    facts();
  } else {
    const [projectDir, specJson] = argv;
    if (!projectDir || !specJson) {
      process.stderr.write("usage: build.mjs <projectDir> <specJson> | build.mjs --facts\n");
      process.exit(64);
    }
    build(projectDir, JSON.parse(specJson));
  }
}
