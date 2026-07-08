#!/usr/bin/env node
/**
 * Fail-CLOSED pre-Phase-4 gate for the agent pipeline.
 *
 * Run by the orchestrator AFTER Phase 3 and BEFORE the peer-review panel (the Phase 3 to 4
 * transition). It is the deterministic, fail-CLOSED counterpart to the deliberately
 * fail-OPEN SubagentStop validator (validate-pipeline-artifact.mjs): a malformed or
 * incomplete Phase 3 artifact must HALT the panel, not slip through.
 *
 * What it checks:
 *   (a) impl-report.json validates against ../schemas/impl-report.schema.json.
 *   (b) every acceptance_criteria entry in spec.json is covered by at least one
 *       requirement_checks entry in impl-report.json.
 *   (c) any migration file ADDED in the diff has BOTH an up section and a down section.
 *       # CUSTOMIZE: migration detection is OPT-IN and configurable. Added files are
 *       matched against `migrationGlobs` in pipeline.config.json (default
 *       ["**\/migrations/**"]). A project with no migrations directory matches nothing, so
 *       the check is a no-op. Set `migrationGlobs: []` to disable it entirely. The
 *       down-section marker defaults to a SQL line comment (`-- DOWN`); override it with
 *       `migrationDownMarker` if your rollback convention differs.
 *
 * What it does NOT check (by design, so reviewers do not assume coverage exists):
 *   - Syntactic validity of migrations: that is your migration linter's job (CI).
 *   - This gate verifies structural reversibility (an up section AND a down section) ONLY.
 *
 * Fail-closed contract (inverse of validate-pipeline-artifact.mjs):
 *   - An absent or unparseable impl-report.json exits non-zero and halts.
 *   - Any internal error exits non-zero and halts.
 *   - Artifacts are parsed with JSON.parse only. Field values are NEVER eval'd, passed to a
 *     shell, or interpolated into a command line (impl-report.json and spec.json are
 *     agent-influenceable inputs).
 *
 * Usage:
 *   node gate-pre-phase4.mjs --issue <n> \
 *     [--impl-report <path>] [--spec <path>] \
 *     [--migrations-root <path>] [--migrations-added <path> ...]
 *
 * Paths default to <project>/.pipeline/<issue>/impl-report.json and .../spec.json.
 */

import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { validate, tokens, acLabels } from "./validate-pipeline-artifact.mjs";
import { globToRegExp } from "./frontend-surface.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
// Schemas ship WITH the plugin (../schemas), independent of the user's project.
const SCHEMA_DIR = path.resolve(SCRIPT_DIR, "..", "schemas");
// Runtime artifacts live in the USER project's .pipeline/<issue>/ (gitignored).
const PROJECT_ROOT = process.env.CLAUDE_PROJECT_DIR || process.cwd();

// # CUSTOMIZE: which added files count as migrations, and the down-section marker.
const DEFAULT_MIGRATION_GLOBS = ["**/migrations/**"];
const DEFAULT_DOWN_MARKER = "-- DOWN";

// Read pipeline.config.json (project root). A missing or malformed config is not an error:
// the gate falls back to the defaults above rather than crash.
function readPipelineConfig() {
  const file = path.join(PROJECT_ROOT, "pipeline.config.json");
  try {
    if (!existsSync(file)) return {};
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function migrationGlobsFromConfig(cfg) {
  const globs = cfg && cfg.migrationGlobs;
  // An explicit [] disables the migration check; anything invalid falls back to the default.
  if (Array.isArray(globs) && globs.every((g) => typeof g === "string")) return globs;
  return DEFAULT_MIGRATION_GLOBS;
}

function downMarkerFromConfig(cfg) {
  const m = cfg && cfg.migrationDownMarker;
  return typeof m === "string" && m.trim() !== "" ? m : DEFAULT_DOWN_MARKER;
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Built-in down-section shape: a line whose first non-whitespace content is a SQL comment
// introducing DOWN on a word boundary, so `-- DOWN`, `--DOWN`, `-- DOWN:`, and
// `-- DOWN MIGRATION` all qualify. We deliberately do NOT key on a loose heuristic like the
// presence of "DROP", which would false-pass a stub down block or false-fail a real one.
const BUILTIN_DOWN_RE = /^[ \t]*--[ \t]*DOWN\b/im;

// Index of the down marker in the SQL (or -1). A migration has a down section when the
// built-in `-- DOWN` comment form matches OR a line begins with the configured literal
// marker. Matching is on literal strings only (no eval, no shell).
export function downMarkerIndex(sql, marker = DEFAULT_DOWN_MARKER) {
  if (typeof sql !== "string") return -1;
  let idx = -1;
  const m = BUILTIN_DOWN_RE.exec(sql);
  if (m) idx = m.index;
  if (typeof marker === "string" && marker.trim() !== "") {
    const litRe = new RegExp("^[ \\t]*" + escapeRegExp(marker), "im");
    const lm = litRe.exec(sql);
    if (lm && (idx === -1 || lm.index < idx)) idx = lm.index;
  }
  return idx;
}

export function hasDownSection(sql, marker = DEFAULT_DOWN_MARKER) {
  return downMarkerIndex(sql, marker) !== -1;
}

// A migration has an up section when it carries any non-comment, non-blank SQL line that
// appears BEFORE the down marker. Intentionally minimal: the gate proves reversibility (up
// AND down both present), not SQL correctness (CI's job).
export function hasUpSection(sql, marker = DEFAULT_DOWN_MARKER) {
  if (typeof sql !== "string") return false;
  const downIdx = downMarkerIndex(sql, marker);
  const head = downIdx === -1 ? sql : sql.slice(0, downIdx);
  return head.split(/\r?\n/).some((line) => {
    const t = line.trim();
    return t.length > 0 && !t.startsWith("--");
  });
}

// The tokenizer and AC-label matcher are single-sourced from validate-pipeline-artifact.mjs
// (imported above), so the fail-OPEN SubagentStop validator and this fail-CLOSED gate score
// fuzzy criterion matching identically. Acceptance criteria and requirement_text are written
// by different roles (BA vs Dev) and routinely differ in wording while describing the same
// item, so exact-string matching would false-fail; AC labels (AC1, AC2, ...) are the
// strongest signal when both sides carry them.

// A criterion is covered when some requirement_checks entry shares its AC label, OR shares
// enough distinctive tokens. Threshold is lenient (the smaller of 3 tokens or half the
// criterion's tokens): we are catching the missing-coverage shape (a criterion with NO
// corresponding check at all), not policing wording.
export function criterionCovered(criterion, checks) {
  const critLabels = acLabels(criterion);
  if (critLabels.size > 0) {
    for (const c of checks) {
      const haystack = `${c.requirement_text || ""} ${c.notes || ""}`;
      const checkLabels = acLabels(haystack);
      for (const lbl of critLabels) if (checkLabels.has(lbl)) return true;
    }
  }
  const critTokens = tokens(criterion);
  if (critTokens.size === 0) return true; // nothing distinctive to match: do not block
  const need = Math.min(3, Math.ceil(critTokens.size / 2));
  for (const c of checks) {
    const cand = tokens(`${c.requirement_text || ""} ${c.notes || ""}`);
    let hit = 0;
    for (const t of critTokens) if (cand.has(t)) hit++;
    if (hit >= need) return true;
  }
  return false;
}

function loadSchema() {
  const file = path.join(SCHEMA_DIR, "impl-report.schema.json");
  return JSON.parse(readFileSync(file, "utf8"));
}

// Discover migration files added in the diff. Production callers pass explicit paths
// (--migrations-added); when none are passed we infer from the impl-report's
// commits[].files_changed, matching each path against the configured migration globs.
// Both inputs are optional: an issue with no migration in scope has nothing to check here.
//
// A path the report also records as removed (top-level files_removed or the commit's own
// files_removed) is excluded from inference: a truthfully-recorded migration deletion
// legitimately leaves no file behind, so requiring it on disk (the fail-closed existsSync
// in collectMigrationSources) would falsely HALT the gate. This mirrors the exemption
// groundFilesChanged() applies in validate-pipeline-artifact.mjs.
export function migrationFilesFromReport(report, rootDir, globs = DEFAULT_MIGRATION_GLOBS) {
  const regexes = (globs || []).map(globToRegExp);
  if (regexes.length === 0) return []; // migrations disabled: nothing to infer
  const isMig = (f) => {
    const norm = f.replace(/\\/g, "/").replace(/^\.\//, "");
    return regexes.some((re) => re.test(norm));
  };
  const out = new Set();
  const topRemoved = new Set((report.files_removed || []).filter((f) => typeof f === "string"));
  for (const commit of report.commits || []) {
    const removed = new Set(topRemoved);
    for (const r of commit.files_removed || []) {
      if (typeof r === "string") removed.add(r);
    }
    for (const f of commit.files_changed || []) {
      if (typeof f !== "string") continue;
      if (removed.has(f)) continue; // recorded deletion: not on disk, do not infer
      if (isMig(f)) out.add(f);
    }
  }
  return [...out].map((rel) => ({ rel, abs: path.resolve(rootDir, rel) }));
}

// Pure check core. Returns { failures: string[] }. `migrationSources` and the parsed
// artifacts are injected so tests drive the logic without touching the real filesystem.
export function runGate({ report, spec, schema, migrationSources, downMarker = DEFAULT_DOWN_MARKER }) {
  const failures = [];

  // (a) schema validation of impl-report.json
  const schemaErrs = validate(report, schema, schema, "");
  for (const e of schemaErrs) failures.push(`impl-report schema: ${e}`);

  // (b) every acceptance criterion covered by a requirement_check
  const criteria = (spec && spec.acceptance_criteria) || [];
  const checks = (report && report.requirement_checks) || [];
  for (const crit of criteria) {
    if (typeof crit !== "string") continue;
    if (!criterionCovered(crit, checks)) {
      failures.push(
        `acceptance criterion not covered by any requirement_check: "${crit.slice(0, 120)}"`,
      );
    }
  }

  // (c) each added migration has both an up and a down section
  for (const mig of migrationSources || []) {
    const sql = mig.sql;
    if (!hasUpSection(sql, downMarker)) {
      failures.push(`migration "${mig.rel}" has no up section`);
    }
    if (!hasDownSection(sql, downMarker)) {
      failures.push(`migration "${mig.rel}" has no down section (expected a "${downMarker}" marker)`);
    }
  }

  return { failures };
}

// ---- argv + I/O (production path) -------------------------------------------

function parseArgs(argv) {
  const args = { migrationsAdded: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--issue") args.issue = argv[++i];
    else if (a === "--impl-report") args.implReport = argv[++i];
    else if (a === "--spec") args.spec = argv[++i];
    else if (a === "--migrations-root") args.migrationsRoot = argv[++i];
    else if (a === "--migrations-added") args.migrationsAdded.push(argv[++i]);
  }
  return args;
}

function resolvePaths(args) {
  const issueDir = args.issue ? path.join(PROJECT_ROOT, ".pipeline", String(args.issue)) : null;
  const implReport = args.implReport || (issueDir && path.join(issueDir, "impl-report.json"));
  const spec = args.spec || (issueDir && path.join(issueDir, "spec.json"));
  return { implReport, spec };
}

// Read + JSON.parse, failing CLOSED. A missing file or a parse error is a hard halt (not
// the fail-open swallow the SubagentStop hook uses). Never eval; JSON.parse only.
function loadJsonOrThrow(file, label) {
  if (!file || !existsSync(file)) {
    throw new Error(`${label} not found at ${file || "(no path resolved)"}`);
  }
  let raw;
  try {
    raw = readFileSync(file, "utf8");
  } catch (e) {
    throw new Error(`${label} could not be read: ${e.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new Error(`${label} is not valid JSON: ${e.message}`);
  }
}

// Migration files live in the implementation WORKTREE, not necessarily the orchestrator's
// checkout that runs this gate. Resolve them against migrationRoot: an explicit
// --migrations-root, else the worktree inferred from --impl-report (which sits at
// <worktree>/.pipeline/<issue>/impl-report.json), else PROJECT_ROOT.
function resolveMigrationRoot(args) {
  if (args.migrationsRoot) return path.resolve(args.migrationsRoot);
  if (args.implReport) {
    // <worktree>/.pipeline/<issue>/impl-report.json -> up three to <worktree>
    return path.resolve(path.dirname(args.implReport), "..", "..");
  }
  return PROJECT_ROOT;
}

function collectMigrationSources(args, report, globs) {
  const migrationRoot = resolveMigrationRoot(args);
  const sources = [];
  for (const rel of args.migrationsAdded) {
    const abs = path.resolve(migrationRoot, rel);
    if (!existsSync(abs)) throw new Error(`migration file not found: ${rel} (under ${migrationRoot})`);
    sources.push({ rel, sql: readFileSync(abs, "utf8") });
  }
  if (sources.length === 0) {
    for (const { rel, abs } of migrationFilesFromReport(report, migrationRoot, globs)) {
      if (!existsSync(abs)) {
        throw new Error(
          `impl-report references migration "${rel}" not present under ${migrationRoot} (pass --migrations-root <worktree> if the gate runs outside the implementation worktree)`,
        );
      }
      sources.push({ rel, sql: readFileSync(abs, "utf8") });
    }
  }
  return sources;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { implReport, spec } = resolvePaths(args);

  const report = loadJsonOrThrow(implReport, "impl-report.json");
  const specData = loadJsonOrThrow(spec, "spec.json");
  const schema = loadSchema();
  const cfg = readPipelineConfig();
  const globs = migrationGlobsFromConfig(cfg);
  const downMarker = downMarkerFromConfig(cfg);
  const migrationSources = collectMigrationSources(args, report, globs);

  const { failures } = runGate({ report, spec: specData, schema, migrationSources, downMarker });

  if (failures.length === 0) {
    process.stdout.write("OK: pre-Phase-4 gate passed.\n");
    return;
  }
  process.stderr.write("FAIL: pre-Phase-4 gate blocked the panel.\n");
  for (const f of failures) process.stderr.write(`  - ${f}\n`);
  process.exit(1);
}

const isMain = (() => {
  if (!process.argv[1]) return false;
  return process.argv[1].endsWith("gate-pre-phase4.mjs");
})();

if (isMain) {
  main().catch((err) => {
    // FAIL CLOSED: any error (missing/unparseable artifact, internal fault) halts.
    process.stderr.write(`FAIL: pre-Phase-4 gate halted: ${err.message}\n`);
    process.exit(1);
  });
}
