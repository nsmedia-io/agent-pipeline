#!/usr/bin/env node
/**
 * migrate-records.mjs: which of this project's pipeline records do the CURRENT schemas reject,
 * and which of those can be normalised without inventing anything?
 *
 * WHY. A project that adopted the plugin at 0.24.0 carries .pipeline/<issue>/ records written
 * against that release's contracts. Later releases tightened them: a `current_phase` must be
 * `<phase>-<slug>` (records in the wild say "phase3_complete_rev21"), review concerns carry
 * materiality ratings and a merge class, vulnerabilities carry a remediation. Nothing told an
 * upgrading project which of its records now fail, so the first signal was a gate or a stop
 * hook refusing mid-run over a file written months earlier.
 *
 * WHAT IT READS. Every `.pipeline/<dir>/status.json` and every review shard
 * (`review*.json`, `peer-review*.json`) beside it. `_`-prefixed dirs (`_archived`) are skipped.
 *
 * WHAT IT REPORTS, per file:
 *   status.json: unparseable JSON; the live status schema's required fields and types
 *     (schemas/status.schema.json, read at run time so a schema change is picked up without a
 *     code change); a `current_phase` the schema's own pattern rejects; a timestamp that is not
 *     ISO-8601; `schema_version`, `cost_class`, `fix_rounds`, `spec_revisions` and
 *     `owner_overrides` with the wrong type; a missing `schema_version`.
 *   review shards: every `concerns[]` entry missing `severity`, `likelihood`, `harm`,
 *     `merge_class` or `must_satisfy`, or carrying a value outside that field's enum; every
 *     `vulnerabilities[]` entry missing `remediation`. Found at any depth, so a merged
 *     `review.json`, a per-role shard and a role-wrapped shard all read the same way.
 *
 * WHAT --write CHANGES, and nothing else:
 *   1. `current_phase` becomes "5-archive" when the run is concluded AND records a merge
 *      (`merged_at`, `merge_commit`, or an `events[]` entry whose verdict is "merged"). A
 *      concluded run with no merge record is REPORTED for an owner decision: a run that ended
 *      without merging is not archived by inference.
 *   2. `schema_version` is stamped, but only on a status record that has no remaining problem
 *      after step 1. The stamp is a conformance claim; a record that still fails does not get it.
 *   3. Only with --write --map-legacy-counters: a record written before the counters were named
 *      carries `fix_round` / `spec_revision` (the CURRENT round and revision numbers). Each is
 *      reported with its suggested mapping (fix_rounds = fix_round, spec_revisions =
 *      spec_revision); the flag sets the new field and leaves the legacy key in place. Without the
 *      flag the mapping is an owner decision, because only the owner knows the old number meant
 *      the same thing.
 *   Review shards are never written. A missing likelihood, harm or merge class is a judgement
 *   the reviewer did not record, and a migration that filled it in would be inventing a rating.
 *
 * Dry run by default. Exit 0 unless --check is passed, in which case exit 1 when any record
 * still needs attention. Exit 2 on a usage error.
 *
 * Usage: node migrate-records.mjs [--root <project>] [--write [--map-legacy-counters]] [--check] [--json]
 */

import { readFileSync, readdirSync, renameSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMain, nativePath } from "./lib.mjs";
import { validate } from "./validate-pipeline-artifact.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const SCHEMA_DIR = path.resolve(SCRIPT_DIR, "..", "schemas");

/** The schema_version this release stamps. Read from the live schema when it declares one. */
export const DEFAULT_STATUS_SCHEMA_VERSION = 1;

export const CONCERN_REQUIRED = ["severity", "likelihood", "harm", "merge_class", "must_satisfy"];
export const MERGE_CLASSES = ["wrong-pass", "money", "data-loss", "security-exposure", "none"];
export const VULNERABILITY_REQUIRED = ["remediation"];

const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
const SHARD_RE = /^(peer-)?review(\.[a-z0-9_-]+)?\.json$/;

function readJson(file) {
  try {
    return { value: JSON.parse(readFileSync(file, "utf8")) };
  } catch (e) {
    return { error: e.code === "ENOENT" ? "absent" : e.message };
  }
}

function loadSchemas() {
  const status = readJson(path.join(SCHEMA_DIR, "status.schema.json")).value || null;
  const review = readJson(path.join(SCHEMA_DIR, "review.schema.json")).value || null;
  const concernProps = review?.definitions?.agentBlock?.properties?.concerns?.items?.properties || {};
  const enums = {};
  for (const f of ["severity", "likelihood", "harm", "reversibility"]) {
    if (Array.isArray(concernProps[f]?.enum)) enums[f] = concernProps[f].enum;
  }
  // B1's merge_class enum, when the live schema declares it; otherwise the agreed list.
  enums.merge_class = Array.isArray(concernProps.merge_class?.enum) ? concernProps.merge_class.enum : MERGE_CLASSES;
  return { status, enums };
}

/** The version to stamp: the schema's const/enum max/default, else DEFAULT_STATUS_SCHEMA_VERSION. */
export function targetSchemaVersion(statusSchema) {
  const p = statusSchema?.properties?.schema_version;
  if (Number.isInteger(p?.const)) return p.const;
  if (Array.isArray(p?.enum) && p.enum.every(Number.isInteger) && p.enum.length) return Math.max(...p.enum);
  if (Number.isInteger(p?.default)) return p.default;
  return DEFAULT_STATUS_SCHEMA_VERSION;
}

/** Structured merge evidence only. A merge mentioned in free text is not a record of one. */
export function recordsMerge(status) {
  if (!status || typeof status !== "object") return false;
  if (typeof status.merged_at === "string" && status.merged_at.trim() !== "") return true;
  if (typeof status.merge_commit === "string" && status.merge_commit.trim() !== "") return true;
  return Array.isArray(status.events) && status.events.some((e) => typeof e?.verdict === "string" && e.verdict.trim().toLowerCase() === "merged");
}

/** Legacy counter -> the field the round budget reads. Both old keys held the CURRENT number. */
export const LEGACY_COUNTERS = { fix_round: "fix_rounds", spec_revision: "spec_revisions" };

/**
 * The legacy counters a status record carries, each with its suggested mapping. Pure.
 * @returns {{legacy, field, value, action: "map"|"same"|"conflict"|"unreadable"}[]}
 */
export function legacyCounterMappings(status) {
  const out = [];
  if (!status || typeof status !== "object" || Array.isArray(status)) return out;
  for (const [legacy, field] of Object.entries(LEGACY_COUNTERS)) {
    if (status[legacy] === undefined) continue;
    const value = status[legacy];
    let action;
    if (!Number.isInteger(value) || value < 0) action = "unreadable";
    else if (status[field] === undefined) action = "map";
    else action = status[field] === value ? "same" : "conflict";
    out.push({ legacy, field, value, action });
  }
  return out;
}

/** A run that says it is over, by any of the spellings records actually use. */
export function isConcluded(status) {
  if (!status || typeof status !== "object") return false;
  if (status.completed_at !== undefined && status.completed_at !== null && status.completed_at !== "") return true;
  if (typeof status.final_verdict === "string" && status.final_verdict !== "") return true;
  const phase = typeof status.current_phase === "string" ? status.current_phase : "";
  return /^5-/.test(phase) || /(complete|archiv|merged|done|closed)/i.test(phase) || recordsMerge(status);
}

function statusProblems(status, schemas) {
  const problems = [];
  if (status === null || typeof status !== "object" || Array.isArray(status)) {
    return ["the top level is not a JSON object"];
  }
  if (schemas.status) {
    for (const e of validate(status, schemas.status, schemas.status)) problems.push(e);
    const pattern = schemas.status.properties?.current_phase?.pattern;
    if (pattern && typeof status.current_phase === "string" && !new RegExp(pattern).test(status.current_phase)) {
      problems.push(`/current_phase: ${JSON.stringify(status.current_phase)} does not match ${pattern}`);
    }
  }
  for (const f of ["started_at", "updated_at", "completed_at"]) {
    if (typeof status[f] === "string" && !ISO_RE.test(status[f])) {
      problems.push(`/${f}: ${JSON.stringify(status[f].slice(0, 60))} is not an ISO-8601 date-time`);
    }
  }
  const intField = (f, min) => {
    if (status[f] === undefined) return;
    if (!Number.isInteger(status[f]) || status[f] < min) problems.push(`/${f}: expected an integer >= ${min}, got ${JSON.stringify(status[f])}`);
  };
  intField("schema_version", 1);
  intField("fix_rounds", 0);
  intField("spec_revisions", 0);
  if (status.cost_class !== undefined && typeof status.cost_class !== "string") {
    problems.push(`/cost_class: expected a string, got ${JSON.stringify(status.cost_class)}`);
  }
  if (status.owner_overrides !== undefined && !Array.isArray(status.owner_overrides)) {
    problems.push(`/owner_overrides: expected an array, got ${typeof status.owner_overrides}`);
  }
  return problems;
}

/** Walk any shard shape; report concerns[] and vulnerabilities[] entries by JSON pointer. */
export function shardProblems(shard, enums = { merge_class: MERGE_CLASSES }) {
  const problems = [];
  const walk = (node, ptr) => {
    if (Array.isArray(node)) {
      node.forEach((v, i) => walk(v, `${ptr}/${i}`));
      return;
    }
    if (node === null || typeof node !== "object") return;
    for (const [k, v] of Object.entries(node)) {
      const here = `${ptr}/${k}`;
      if (k === "concerns" && Array.isArray(v)) {
        v.forEach((c, i) => {
          if (c === null || typeof c !== "object" || Array.isArray(c)) {
            problems.push(`${here}/${i}: a concern that is not an object`);
            return;
          }
          const missing = CONCERN_REQUIRED.filter((f) => c[f] === undefined || c[f] === null || c[f] === "");
          if (missing.length) problems.push(`${here}/${i}: missing ${missing.join(", ")}`);
          for (const [f, allowed] of Object.entries(enums)) {
            if (c[f] !== undefined && c[f] !== null && c[f] !== "" && !allowed.includes(c[f])) {
              problems.push(`${here}/${i}/${f}: ${JSON.stringify(c[f])} is not one of ${allowed.join("|")}`);
            }
          }
        });
      } else if (k === "vulnerabilities" && Array.isArray(v)) {
        v.forEach((x, i) => {
          if (x === null || typeof x !== "object" || Array.isArray(x)) return;
          const missing = VULNERABILITY_REQUIRED.filter((f) => typeof x[f] !== "string" || x[f].trim() === "");
          if (missing.length) problems.push(`${here}/${i}: missing ${missing.join(", ")}`);
        });
      } else {
        walk(v, here);
      }
    }
  };
  walk(shard, "");
  return problems;
}

function runDirs(root) {
  const base = path.join(root, ".pipeline");
  let names = [];
  try {
    names = readdirSync(base);
  } catch {
    return [];
  }
  return names
    .filter((n) => !n.startsWith("_") && !n.startsWith("."))
    .map((n) => path.join(base, n))
    .filter((d) => {
      try {
        return statSync(d).isDirectory();
      } catch {
        return false;
      }
    })
    .sort();
}

function writeJsonAtomic(file, value) {
  const tmp = `${file}.migrate-${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(tmp, file);
}

/**
 * @returns {{root: string, write: boolean, files: {file: string, kind: string, problems: string[],
 *            changes: string[], decisions: string[]}[]}}
 */
export function migrate({ root, write = false, mapLegacyCounters = false }) {
  const schemas = loadSchemas();
  const target = targetSchemaVersion(schemas.status);
  const report = { root, write, mapLegacyCounters, targetSchemaVersion: target, files: [] };

  for (const dir of runDirs(root)) {
    let entries = [];
    try {
      entries = readdirSync(dir).sort();
    } catch {
      continue;
    }
    if (entries.includes("status.json")) {
      const file = path.join(dir, "status.json");
      const entry = { file: path.relative(root, file).split(path.sep).join("/"), kind: "status", problems: [], changes: [], decisions: [] };
      report.files.push(entry);
      const read = readJson(file);
      if (read.error) {
        entry.problems.push(`not valid JSON (${read.error}); nothing can be normalised until it parses`);
      } else {
        const status = read.value;
        const next = status && typeof status === "object" && !Array.isArray(status) ? { ...status } : status;
        if (next && typeof next === "object" && !Array.isArray(next)) {
          const phase = next.current_phase;
          const pattern = schemas.status?.properties?.current_phase?.pattern;
          const phaseValid = typeof phase === "string" && (!pattern || new RegExp(pattern).test(phase));
          if (!(typeof phase === "string" && /^5-/.test(phase))) {
            if (recordsMerge(next)) {
              // A recorded merge is the one fact that makes the terminal phase mechanical.
              next.current_phase = "5-archive";
              entry.changes.push(`current_phase ${JSON.stringify(phase)} -> "5-archive" (the record carries a merge)`);
            } else if (!phaseValid) {
              // A VALID non-terminal phase with no merge is an ordinary in-flight or parked run
              // and is left alone. Only a phase the schema rejects needs someone to decide.
              entry.decisions.push(
                `current_phase ${JSON.stringify(phase)} is rejected and the record carries NO merge${isConcluded(next) ? " although the run reads as concluded" : ""}: set it by hand (5-archive if it merged, otherwise the <phase>-<slug> it stopped at); not inferred`,
              );
            }
          }
          for (const m of legacyCounterMappings(next)) {
            const was = `${m.legacy} ${JSON.stringify(m.value)}`;
            if (m.action === "map" && mapLegacyCounters) {
              next[m.field] = m.value;
              entry.changes.push(`${m.field} set to ${m.value} from the legacy ${was} (the legacy key is kept)`);
            } else if (m.action === "map") {
              entry.decisions.push(
                `legacy counter ${was}: suggested mapping ${m.field} = ${m.value} (${m.legacy} held the current number); apply it with --write --map-legacy-counters`,
              );
            } else if (m.action === "conflict") {
              entry.decisions.push(`legacy counter ${was} disagrees with ${m.field} ${JSON.stringify(next[m.field])}: set ${m.field} by hand; not mapped`);
            } else if (m.action === "unreadable") {
              entry.decisions.push(`legacy counter ${was} is not a non-negative integer: set ${m.field} by hand; not mapped`);
            }
          }
          const remaining = statusProblems(next, schemas).filter((p) => !/^\/schema_version: /.test(p));
          if (next.schema_version === undefined) {
            if (remaining.length === 0 && entry.decisions.length === 0) {
              next.schema_version = target;
              entry.changes.push(`schema_version stamped ${target}`);
            } else {
              entry.problems.push(`schema_version absent; not stamped while ${remaining.length + entry.decisions.length} problem(s) remain`);
            }
          }
          entry.problems.unshift(...statusProblems(next, schemas));
          if (write && entry.changes.length > 0) writeJsonAtomic(file, next);
        } else {
          entry.problems.push(...statusProblems(status, schemas));
        }
      }
    }
    for (const name of entries.filter((n) => SHARD_RE.test(n))) {
      const file = path.join(dir, name);
      const entry = { file: path.relative(root, file).split(path.sep).join("/"), kind: "review", problems: [], changes: [], decisions: [] };
      const read = readJson(file);
      if (read.error) entry.problems.push(`not valid JSON (${read.error})`);
      else {
        const found = shardProblems(read.value, schemas.enums);
        if (found.length) {
          entry.problems.push(...found);
          entry.decisions.push("ratings are the reviewer's judgement and are never filled in by migration: re-run that review or record them by hand");
        }
      }
      report.files.push(entry);
    }
  }
  return report;
}

export function formatReport(report) {
  const out = [];
  const needs = report.files.filter((f) => f.problems.length || f.decisions.length || f.changes.length);
  const mode = report.write ? "WRITE" : "DRY RUN (pass --write to apply the changes marked 'would change')";
  out.push(`migrate-records: ${report.files.length} record file(s) under ${path.join(report.root, ".pipeline")}; ${mode}`);
  if (needs.length === 0) {
    out.push("  every record the current schemas check is accepted; nothing to change.");
    return out.join("\n");
  }
  for (const f of needs) {
    out.push(`  ${f.file}`);
    for (const c of f.changes) out.push(`    ${report.write ? "changed" : "would change"}: ${c}`);
    for (const p of f.problems) out.push(`    rejected: ${p}`);
    for (const d of f.decisions) out.push(`    owner: ${d}`);
  }
  return out.join("\n");
}

export function needsAttention(report) {
  return report.files.some((f) => f.problems.length > 0 || f.decisions.length > 0 || (!report.write && f.changes.length > 0));
}

function main(argv) {
  let root = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const flags = new Set();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--root") {
      if (i + 1 >= argv.length) {
        process.stderr.write("migrate-records: --root needs a directory\n");
        return 2;
      }
      root = argv[++i];
    } else if (["--write", "--check", "--json", "--map-legacy-counters"].includes(a)) flags.add(a);
    else {
      process.stderr.write(`migrate-records: unknown argument ${a}\nusage: node migrate-records.mjs [--root <project>] [--write [--map-legacy-counters]] [--check] [--json]\n`);
      return 2;
    }
  }
  const report = migrate({ root: path.resolve(nativePath(root)), write: flags.has("--write"), mapLegacyCounters: flags.has("--map-legacy-counters") });
  process.stdout.write(`${flags.has("--json") ? JSON.stringify(report, null, 2) : formatReport(report)}\n`);
  return flags.has("--check") && needsAttention(report) ? 1 : 0;
}

if (isMain("migrate-records.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
