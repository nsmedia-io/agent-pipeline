#!/usr/bin/env node
/**
 * The WRITE-TIME honorer for status.json's verdict cap (#117).
 *
 * Run it before a checkpoint commit, from the project root, with nothing to remember:
 *
 *   node "${CLAUDE_PLUGIN_ROOT}/scripts/check-status-record.mjs"
 *
 * It walks `.pipeline/<n>/status.json`, refuses any `events[].verdict` or `flags[].verdict`
 * longer than the cap it READS OUT OF schemas/status.schema.json, and names the file, the
 * json path, the value and both lengths. Silent and exit 0 when clean.
 *
 * WHY IT EXISTS. The cap was declared in the schema and restated as prose in
 * commands/pipeline.md, and nothing ran. status.json is in no AGENT_RULES entry in
 * validate-pipeline-artifact.mjs (and that walker implements no maxLength at all), so the only
 * reader was tests/test-status-schema-contract.sh, walking the COMMITTED corpus in CI -- after
 * the violating record is already in history. During #106 the orchestrator's own writes broke
 * the cap twice in one run: seven labels up to 44 chars accumulated unnoticed across phases,
 * and then a 33-char label was fixed by Dev in a worktree (6eefeb6) and silently reintroduced
 * when a routine `cp` from a stale checkout overwrote the fixed copy (adce70c). Two Phase 4
 * panelists spent review budget rediscovering it.
 *
 * That second incident is why this reads the FILE and not a diff, and why it takes no argument
 * naming what changed. A checker keyed to "the value you just typed" sees a typo and misses a
 * clobber; a checker over the file's whole content cannot tell the two apart, and does not need
 * to. Whatever put the string there -- a keystroke, a `cp`, a merge -- it is in the record about
 * to be committed, and that is the condition being refused.
 *
 * THE CAP IS READ, NEVER COPIED. Nothing in this file holds the literal 32. Each field is
 * checked against its OWN `maxLength` in the schema, so events[] and flags[] can never be
 * conflated and a schema that stops capping one of them is a hard error here rather than a
 * silent pass -- an unenforceable constraint must announce itself, not degrade to a no-op. This
 * is the drift class #74 filed over a different constant, and a second hardcoded 32 would be it
 * again.
 *
 * ONE READER, NOT TWO. tests/test-status-schema-contract.sh used to carry its own inline
 * walker. It now shells out to `--report` below, so the CI corpus walk and this write-time
 * check are the same code reading the same schema. The suite still owns its population (the
 * tracked/on-disk union), its vacuity controls and its fixture matrix; what it no longer owns
 * is a second opinion about what a violation is.
 *
 * SCOPE: the verdict TOKEN fields only. `events[].note`, `flags[].summary`, `veto_reason` and
 * `error` are free text and #52 ruled explicitly that the instrument for those is CONTENT, not
 * length -- a 600-char note recording a live reproduction is correct work. This script must
 * never grow a length opinion about them. The credential-shaped scan over that free text lives
 * in tests/test-status-schema-contract.sh and is a different control.
 *
 * Usage:
 *   node check-status-record.mjs [<status.json> ...]
 *     [--root <dir>] [--schema <path>] [--cap <n>] [--report]
 *
 *   <no paths>      discover .pipeline/<*>/status.json under --root (default: cwd)
 *   --cap <n>       check against a TIGHTER cap than the schema's. Refused when it would
 *                   loosen one, so this flag can only ever make the check refuse more. It
 *                   exists for the non-zero controls in the contract suite, which lower the
 *                   cap to watch the walk go red on the real corpus.
 *   --report        machine-readable KEY=VALUE measurement on stdout, printed whatever the
 *                   verdict. Without it a clean run prints nothing at all.
 *
 * Exit: 0 clean, 1 a verdict exceeds its cap, 2 nothing could be checked (unreadable or
 * mis-shaped record, no records found, bad usage, unusable schema). 2 is never a pass: a walk
 * that found nothing has no zero to report.
 */

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMain } from "./lib.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_SCHEMA = path.join(SCRIPT_DIR, "..", "schemas", "status.schema.json");

// The two capped fields, and the json path to each field's own maxLength. Adding a third
// capped verdict field is one row here; nothing else in this file enumerates them.
const CAPPED = [
  { field: "events", at: (s) => s?.properties?.events?.items?.properties?.verdict },
  { field: "flags", at: (s) => s?.properties?.flags?.items?.properties?.verdict },
];

/**
 * Per-field caps read out of the schema document.
 *
 * Throws when a field has no usable positive-integer maxLength. Deliberately loud: the whole
 * point of this script is that a cap nobody reads can be absent as easily as it can be wrong,
 * and falling back to a built-in number would reinstate exactly the copy this avoids.
 */
export function capsFromSchema(schema) {
  const caps = {};
  for (const { field, at } of CAPPED) {
    const node = at(schema);
    const max = node?.maxLength;
    if (!Number.isInteger(max) || max <= 0) {
      throw new Error(
        `schema declares no usable maxLength for ${field}[].verdict (got ${JSON.stringify(max)}); ` +
          `refusing to check against a cap this script would have to invent`,
      );
    }
    caps[field] = max;
  }
  return caps;
}

/**
 * IS THIS PARSED OBJECT A RUN RECORD? Answered from the schema, for callers that must decide
 * whether a `.pipeline/` subdirectory holds a run AT ALL (#115).
 *
 * WHY IT LIVES HERE and not in its one caller. validate-pipeline-artifact.mjs needs this to
 * recognise a run directory whose name ISSUE_DIR_RE cannot match, and it must not grow a second
 * copy of the vocabulary -- a hardcoded twin of `required` or of the phase pattern would silently
 * stop recognising the newest runs the day either grows, which fails INERT and is the exact defect
 * #115 is about. This file already owns "read a fact out of schemas/status.schema.json and refuse
 * to invent it", so the read belongs here, the way run-candidates.mjs owns the in-flight predicate.
 * Siting it here also keeps validate-pipeline-artifact.mjs from naming status.schema.json, which
 * matters: tests/test-status-schema-contract.sh's EXPIRY assertion reads that module for exactly
 * that string, to notice the day status.json becomes a validated artifact. It has not.
 *
 * THIS IS RECOGNITION, NOT VALIDATION, and the difference is the whole point. It asks only whether
 * the schema's own `required` keys are PRESENT and whether `current_phase` matches the schema's own
 * pattern. It checks no type, reports no violation, blocks nothing and tells no one their record is
 * wrong. Nothing anywhere validates status.json against this schema, and the schema's prose saying
 * so stays true.
 *
 * FAIL DIRECTION: an unreadable or unusable schema returns false, so recognition simply does not
 * happen and the caller stays as inert as it was before this existed. A record missing a required
 * key is likewise not recognised. Both are silences, never false blocks -- the right direction for
 * a predicate whose only power is to make a fail-open path do MORE work.
 */
let _runShapeCache;
export function runRecordShape(schemaPath = DEFAULT_SCHEMA) {
  if (_runShapeCache !== undefined && schemaPath === DEFAULT_SCHEMA) return _runShapeCache;
  let shape = null;
  try {
    const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
    const required = Array.isArray(schema?.required)
      ? schema.required.filter((k) => typeof k === "string")
      : [];
    const pattern = schema?.properties?.current_phase?.pattern;
    if (required.length > 0 && typeof pattern === "string" && pattern.length > 0) {
      shape = { required, phasePattern: new RegExp(pattern) };
    }
  } catch {
    // unusable schema: recognise nothing (see FAIL DIRECTION above)
  }
  if (schemaPath === DEFAULT_SCHEMA) _runShapeCache = shape;
  return shape;
}

export function isRunRecord(status, schemaPath = DEFAULT_SCHEMA) {
  if (!status || typeof status !== "object" || Array.isArray(status)) return false;
  const shape = runRecordShape(schemaPath);
  if (!shape) return false;
  for (const key of shape.required) {
    if (!Object.prototype.hasOwnProperty.call(status, key)) return false;
  }
  return shape.phasePattern.test(String(status.current_phase ?? ""));
}

/**
 * Walk parsed records. Pure: takes { file, text } pairs, returns the measurement.
 *
 * Every record that could not be read or is mis-shaped is ACCOUNTED FOR in its own list rather
 * than skipped, and `read` is reported beside `files`, so an empty `violations` can be told
 * apart from a walk that never inspected anything.
 */
export function checkRecords(records, caps) {
  const out = {
    files: records.length,
    read: 0,
    verdicts: 0,
    longest: 0,
    longestvalue: "",
    unreadable: [],
    badevents: [],
    badflags: [],
    violations: [],
  };
  for (const { file, text } of records) {
    let s;
    try {
      s = JSON.parse(text);
    } catch (e) {
      out.unreadable.push(`${file} (${String(e.message).slice(0, 40)})`);
      continue;
    }
    out.read++;
    if (!Array.isArray(s.events)) {
      out.badevents.push(`${file} (events is ${s.events === undefined ? "absent" : typeof s.events})`);
    }
    if (s.flags !== undefined && !Array.isArray(s.flags)) {
      out.badflags.push(`${file} (flags is ${typeof s.flags})`);
    }
    for (const { field } of CAPPED) {
      const arr = s[field];
      if (!Array.isArray(arr)) continue;
      const cap = caps[field];
      arr.forEach((entry, i) => {
        const v = entry && entry.verdict;
        // An ABSENT verdict is schema-valid and stays valid; the cap must not become a
        // requirement. A non-string one is a type defect, not a length defect, and belongs to
        // whatever validates types -- counting it here would report a length verdict about a
        // value that has no length.
        if (typeof v !== "string") return;
        out.verdicts++;
        if (v.length > out.longest) {
          out.longest = v.length;
          out.longestvalue = v;
        }
        // STRICTLY GREATER. maxLength is inclusive: a value of exactly `cap` characters
        // conforms. The committed corpus sits at exactly 32 today
        // (SKIPPED_OWNER_DECISION_CONFIRMED), so a `>=` here would refuse a record the schema
        // permits and this repo has already shipped.
        if (v.length > cap) {
          out.violations.push(
            `${file} ${field}[${i}].verdict=${JSON.stringify(v)} len=${v.length} cap=${cap}`,
          );
        }
      });
    }
  }
  return out;
}

/** Repo-relative `.pipeline/<*>/status.json` paths under root, sorted. */
export function discover(root) {
  const base = path.join(root, ".pipeline");
  let entries;
  try {
    entries = readdirSync(base, { withFileTypes: true });
  } catch {
    return [];
  }
  const found = [];
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    const rel = path.join(".pipeline", e.name, "status.json");
    try {
      if (statSync(path.join(root, rel)).isFile()) found.push(rel);
    } catch {
      /* not a record dir */
    }
  }
  return found.sort();
}

function flatten(v) {
  return (Array.isArray(v) ? v.join(" ;; ") : String(v)).replace(/[\r\n]+/g, " ");
}

function usage(msg) {
  process.stderr.write(`check-status-record: ${msg}\n`);
  process.stderr.write(
    "usage: node check-status-record.mjs [<status.json> ...] [--root <dir>] [--schema <path>] [--cap <n>] [--report]\n",
  );
  return 2;
}

export function main(argv) {
  const files = [];
  let root = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  let schemaPath = DEFAULT_SCHEMA;
  let capOverride = null;
  let report = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const eq = a.indexOf("=");
    const flag = a.startsWith("--") && eq > 0 ? a.slice(0, eq) : a;
    const inline = a.startsWith("--") && eq > 0 ? a.slice(eq + 1) : null;
    const take = () => (inline !== null ? inline : argv[++i]);
    if (flag === "--report") report = true;
    else if (flag === "--root") root = take();
    else if (flag === "--schema") schemaPath = take();
    else if (flag === "--cap") capOverride = take();
    else if (a === "--") {
      files.push(...argv.slice(i + 1));
      i = argv.length;
    } else if (a.startsWith("--")) return usage(`unknown flag ${a}`);
    else files.push(a);
  }
  if (!root || !schemaPath) return usage("a flag was given with no value");

  let caps;
  try {
    caps = capsFromSchema(JSON.parse(readFileSync(schemaPath, "utf8")));
  } catch (e) {
    return usage(`cannot read the cap from ${schemaPath}: ${e.message}`);
  }

  if (capOverride !== null) {
    const n = Number(capOverride);
    if (!Number.isInteger(n) || n <= 0) return usage(`--cap must be a positive integer, got ${JSON.stringify(capOverride)}`);
    // TIGHTEN ONLY. A flag that could raise the cap is a flag that can silence this check,
    // and the one thing a write-time refusal must not have is an argument that turns it off.
    for (const { field } of CAPPED) {
      if (n > caps[field]) {
        return usage(
          `--cap ${n} would LOOSEN ${field}[].verdict past the schema's ${caps[field]}; this flag may only tighten`,
        );
      }
      caps[field] = n;
    }
  }

  const discovered = files.length === 0;
  const list = discovered ? discover(root) : files;

  const records = [];
  for (const f of list) {
    const abs = path.isAbsolute(f) ? f : path.join(root, f);
    try {
      records.push({ file: f, text: readFileSync(abs, "utf8") });
    } catch (e) {
      records.push({ file: f, text: null, ioError: String(e.message).slice(0, 60) });
    }
  }
  const readable = records.filter((r) => r.text !== null);
  const result = checkRecords(readable, caps);
  result.files = records.length;
  for (const r of records) {
    if (r.text === null) result.unreadable.push(`${r.file} (${r.ioError})`);
  }

  if (report) {
    let text = "";
    for (const k of ["files", "read", "verdicts", "longest", "longestvalue", "unreadable", "badevents", "badflags", "violations"]) {
      text += `${k}=${flatten(result[k])}\n`;
    }
    process.stdout.write(text);
  }

  if (result.files === 0) {
    process.stderr.write(
      discovered
        ? `check-status-record: no .pipeline/<n>/status.json found under ${root}. Nothing was checked, so this is not a pass.\n`
        : "check-status-record: no files given.\n",
    );
    return 2;
  }
  if (result.unreadable.length || result.badevents.length || result.badflags.length) {
    process.stderr.write("check-status-record: a record could not be checked.\n");
    for (const line of [...result.unreadable, ...result.badevents, ...result.badflags]) {
      process.stderr.write(`  ${line}\n`);
    }
    return 2;
  }
  if (result.violations.length) {
    const capList = CAPPED.map(({ field }) => `${field}[].verdict <= ${caps[field]}`).join(", ");
    process.stderr.write(
      `check-status-record: ${result.violations.length} verdict value(s) over the cap (${capList}).\n`,
    );
    for (const line of result.violations) process.stderr.write(`  ${line}\n`);
    process.stderr.write(
      "A verdict is a TOKEN, not prose: write the verdict word and put the reasoning in the note/summary.\n" +
        `The cap is read from ${schemaPath === DEFAULT_SCHEMA ? "schemas/status.schema.json" : schemaPath};` +
        " do not raise it to fit a sentence.\n",
    );
    return 1;
  }
  return 0;
}

if (isMain("check-status-record.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
