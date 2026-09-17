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
 * json path, the value and both lengths. It also refuses a `current_phase` that fails the
 * schema's own pattern (see phasePatternFromSchema). Silent and exit 0 when clean.
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
 *     [--root <dir>] [--schema <path>] [--cap <n>] [--all] [--issue <n>] [--report]
 *
 *   <no paths>      discover the LIVE .pipeline/<*>/status.json records under --root (default:
 *                   cwd): updated in the last 30 days, OR parked at a non-terminal phase. See
 *                   discover() for why the default is scoped and what stays in scope.
 *   --all           every record under .pipeline/, history included. The pre-scoping default.
 *   --issue <n>     just .pipeline/<n>/status.json, whatever its age or phase.
 *   --cap <n>       check against a TIGHTER cap than the schema's. Refused when it would
 *                   loosen one, so this flag can only ever make the check refuse more. It
 *                   exists for the non-zero controls in the contract suite, which lower the
 *                   cap to watch the walk go red on the real corpus.
 *   --report        machine-readable KEY=VALUE measurement on stdout, printed whatever the
 *                   verdict. Without it a clean run prints nothing at all.
 *
 * Exit: 0 clean, 1 a verdict exceeds its cap or a current_phase is not phase-shaped, 2 nothing could be checked (unreadable or
 * mis-shaped record, no records found, bad usage, unusable schema). 2 is never a pass: a walk
 * that found nothing has no zero to report.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
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
 * THE PHASE SHAPE, read out of the schema the same way the caps are (0.42.x, B2).
 *
 * WHY THIS CHECKER OWNS IT. A malformed `current_phase` used to reach a checkpoint commit with
 * nothing saying so, and every reader downstream treated it as a phase it had never heard of:
 * gate-phase-entry.mjs returned not-applicable (the phase-entry guard went quiet for the whole
 * run), voice-lint.mjs matched no voice moment, and validate-pipeline-artifact.mjs stopped
 * recognising an unnamed run dir. This script already runs before EVERY checkpoint commit
 * (commands/pipeline.md's durable-checkpoint recipe), so it is the one write-time place that can
 * refuse the shape before it is committed.
 *
 * Throws when the schema carries no usable pattern, for the reason capsFromSchema throws: a check
 * that silently has nothing to check against is the defect, not a fallback.
 */
export function phasePatternFromSchema(schema) {
  const pattern = schema?.properties?.current_phase?.pattern;
  if (typeof pattern !== "string" || pattern.length === 0) {
    throw new Error(
      `schema declares no usable pattern for current_phase (got ${JSON.stringify(pattern)}); ` +
        `refusing to check against a phase shape this script would have to invent`,
    );
  }
  try {
    return new RegExp(pattern);
  } catch (e) {
    throw new Error(`schema's current_phase pattern does not compile: ${e.message}`);
  }
}

/**
 * Is this value a schema-shaped phase? Returns true / false, or null when the schema cannot be
 * read (the caller decides what a tooling gap means for it; gate-phase-entry.mjs fails open).
 */
let _phaseReCache;
export function phaseShapeOk(phase, schemaPath = DEFAULT_SCHEMA) {
  let re;
  if (schemaPath === DEFAULT_SCHEMA && _phaseReCache !== undefined) {
    re = _phaseReCache;
  } else {
    try {
      re = phasePatternFromSchema(JSON.parse(readFileSync(schemaPath, "utf8")));
    } catch {
      re = null;
    }
    if (schemaPath === DEFAULT_SCHEMA) _phaseReCache = re;
  }
  if (!re) return null;
  return typeof phase === "string" && re.test(phase);
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
 * the schema's own `required` keys are PRESENT and whether `current_phase` is a non-empty string.
 * It checks no type beyond that, reports no violation, blocks nothing and tells no one their record
 * is wrong. The phase SHAPE is deliberately not part of recognition any more (0.42.x, B2): a run
 * whose orchestrator mistyped its phase is still a run, and dropping it from recognition made the
 * artifact validator go quiet on exactly the record that most needed a look. The shape is refused
 * at write time by main() below and by gate-phase-entry.mjs, which is where a refusal belongs.
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
    if (required.length > 0 && required.includes("current_phase")) {
      shape = { required };
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
  return typeof status.current_phase === "string" && status.current_phase.length > 0;
}

/**
 * Walk parsed records. Pure: takes { file, text } pairs, returns the measurement.
 *
 * Every record that could not be read or is mis-shaped is ACCOUNTED FOR in its own list rather
 * than skipped, and `read` is reported beside `files`, so an empty `violations` can be told
 * apart from a walk that never inspected anything.
 */
export function checkRecords(records, caps, phaseRe = null) {
  const out = {
    files: records.length,
    read: 0,
    verdicts: 0,
    longest: 0,
    longestvalue: "",
    unreadable: [],
    badevents: [],
    badflags: [],
    badphases: [],
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
    // THE PHASE SHAPE. Absent and non-string count too: a record with no readable phase is the
    // same silence downstream as a mistyped one. The value is quoted TRUNCATED, because it is a
    // field of a committed record and this line lands in a transcript.
    if (phaseRe && !(typeof s?.current_phase === "string" && phaseRe.test(s.current_phase))) {
      const shown =
        s?.current_phase === undefined ? "absent" : JSON.stringify(s.current_phase).slice(0, 48);
      out.badphases.push(`${file} current_phase=${shown} does not match ${phaseRe.source}`);
    }
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

// THE DEFAULT SCAN IS SCOPED TO LIVE RECORDS, and that is an observability fix rather than a
// weakening (0.41.0).
//
// The bare invocation used to return EVERY `.pipeline/<n>/status.json` in the tree, history
// included. `.pipeline/` accumulates one record per run forever, and records written before
// #34 capped the verdict field carry pre-cap values that nobody may edit -- they are the
// archive. So every checkpoint commit, on every run, printed the same six violations about six
// finished runs, none of which the writer could act on. A refusal that fires identically
// whatever you just wrote is one people learn to scroll past, and a control nobody reads is
// indistinguishable from one that was never wired up.
//
// LIVE means one of two things, either sufficient: updated in the last 30 days, or parked at a
// phase that is not terminal. The second disjunct is what keeps an abandoned run in scope: a
// pipeline halted three months ago at `3-impl-gate-failed` is exactly the record a resume will
// read, so its age is no reason to stop checking it.
//
// TERMINALITY IS READ FROM THE RECORD, not from a phase table copied in here: any `5-` prefix
// counts, which is the same rule hooks/session-start.sh uses for "this run is finished", so a
// new phase-5 label cannot silently fall out of the terminal set.
//
// FAIL DIRECTION. An unreadable, undatable or mis-shaped record is IN scope, never filtered
// out: a record this function cannot date is one checkRecords must still be given the chance to
// refuse, and dropping it here would turn a torn write into a silent pass. `--all` restores the
// full historical walk and `--issue <n>` narrows to one record; an explicitly named file
// argument never comes through here at all.
const LIVE_WINDOW_MS = 30 * 24 * 60 * 60 * 1000;

/** Is this parsed record live (recent, or not at a terminal phase)? Unparseable is live. */
export function isLiveRecord(text, now = Date.now(), windowMs = LIVE_WINDOW_MS) {
  let s;
  try {
    s = JSON.parse(text);
  } catch {
    return true; // undatable: keep it in scope so checkRecords can report it
  }
  if (!s || typeof s !== "object" || Array.isArray(s)) return true;
  const phase = String(s.current_phase ?? "");
  if (!/^5-/.test(phase)) return true; // not terminal: live whatever its age
  const updated = Date.parse(String(s.updated_at ?? ""));
  if (!Number.isFinite(updated)) return true; // undatable: in scope
  return now - updated <= windowMs;
}

/**
 * Repo-relative `.pipeline/<*>/status.json` paths under root, sorted.
 *
 * @param {object} opts {all: boolean} to keep every historical record, {issue: string} for one.
 */
export function discover(root, opts = {}) {
  const base = path.join(root, ".pipeline");
  let entries;
  try {
    entries = readdirSync(base, { withFileTypes: true });
  } catch {
    return [];
  }
  const now = typeof opts.now === "number" ? opts.now : Date.now();
  const found = [];
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (opts.issue !== undefined && e.name !== String(opts.issue)) continue;
    const rel = path.join(".pipeline", e.name, "status.json");
    const abs = path.join(root, rel);
    try {
      if (!statSync(abs).isFile()) continue;
    } catch {
      continue; // not a record dir
    }
    if (!opts.all && opts.issue === undefined) {
      let text;
      try {
        text = readFileSync(abs, "utf8");
      } catch {
        found.push(rel); // unreadable: in scope, so the read error is reported not swallowed
        continue;
      }
      if (!isLiveRecord(text, now)) continue;
    }
    found.push(rel);
  }
  return found.sort();
}

function flatten(v) {
  return (Array.isArray(v) ? v.join(" ;; ") : String(v)).replace(/[\r\n]+/g, " ");
}

function usage(msg) {
  process.stderr.write(`check-status-record: ${msg}\n`);
  process.stderr.write(
    "usage: node check-status-record.mjs [<status.json> ...] [--root <dir>] [--schema <path>] [--cap <n>] [--all] [--issue <n>] [--report]\n",
  );
  return 2;
}

export function main(argv) {
  const files = [];
  let root = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  let schemaPath = DEFAULT_SCHEMA;
  let capOverride = null;
  let report = false;
  let all = false;
  let issue;
  // Seen-ness is tracked separately from the value: `--issue` as the last word on the line
  // takes `undefined`, which is indistinguishable from "the flag was never given" unless the
  // flag records that it fired. A selection flag that silently no-ops back to the full scan is
  // how a writer comes to believe they checked one record when they walked all of them.
  let issueSeen = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const eq = a.indexOf("=");
    const flag = a.startsWith("--") && eq > 0 ? a.slice(0, eq) : a;
    const inline = a.startsWith("--") && eq > 0 ? a.slice(eq + 1) : null;
    const take = () => (inline !== null ? inline : argv[++i]);
    if (flag === "--report") report = true;
    else if (flag === "--all") all = true;
    else if (flag === "--issue") { issueSeen = true; issue = take(); }
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
  if (issueSeen && (issue === undefined || issue === "" || issue.startsWith("--"))) {
    return usage("--issue needs a run id");
  }
  if (files.length > 0 && (all || issueSeen)) {
    return usage("--all and --issue select what to DISCOVER; they do not combine with named files");
  }

  let caps;
  let phaseRe;
  try {
    const schemaDoc = JSON.parse(readFileSync(schemaPath, "utf8"));
    caps = capsFromSchema(schemaDoc);
    phaseRe = phasePatternFromSchema(schemaDoc);
  } catch (e) {
    return usage(`cannot read the cap or the phase pattern from ${schemaPath}: ${e.message}`);
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
  const list = discovered ? discover(root, { all, issue }) : files;

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
  const result = checkRecords(readable, caps, phaseRe);
  result.files = records.length;
  for (const r of records) {
    if (r.text === null) result.unreadable.push(`${r.file} (${r.ioError})`);
  }

  if (report) {
    let text = "";
    for (const k of ["files", "read", "verdicts", "longest", "longestvalue", "unreadable", "badevents", "badflags", "badphases", "violations"]) {
      text += `${k}=${flatten(result[k])}\n`;
    }
    process.stdout.write(text);
  }

  if (result.files === 0) {
    // The scope is NAMED in the refusal. Under the live-record default an empty walk can mean
    // "this project has no runs" or "every run here is archived", and those want different
    // next moves: only the second is answered by --all.
    const scope =
      issue !== undefined
        ? `.pipeline/${issue}/status.json`
        : all
          ? "no .pipeline/<n>/status.json"
          : "no LIVE .pipeline/<n>/status.json (updated in the last 30 days, or parked at a non-terminal phase; --all walks the archive too)";
    process.stderr.write(
      discovered
        ? `check-status-record: ${issue !== undefined ? `no ${scope}` : scope} found under ${root}. Nothing was checked, so this is not a pass.\n`
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
  if (result.badphases.length) {
    process.stderr.write(
      `check-status-record: ${result.badphases.length} record(s) carry a current_phase that is not phase-shaped.\n`,
    );
    for (const line of result.badphases) process.stderr.write(`  ${line}\n`);
    process.stderr.write(
      "Write the phase literal commands/pipeline.md names for the checkpoint (e.g. 3-impl, 4-review-complete, halted-error).\n" +
        "A malformed phase is not a harmless label: the phase-entry guard refuses a turn at one, and before it did, every\n" +
        "reader of this record treated it as a phase it had never heard of and checked nothing.\n",
    );
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
  return result.badphases.length ? 1 : 0;
}

if (isMain("check-status-record.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
