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
 *       matched by migrationGlobsForGate in data-layer-surface.mjs: `migrationGlobs` from
 *       pipeline.config.json REPLACES the built-in framework-preset union (Rails, Django,
 *       Alembic, Prisma, Drizzle, Supabase, Flyway, Liquibase, EF Core, Laravel), and
 *       `extraMigrationGlobs` unions on top of whichever set applies. A project with no
 *       migrations matches nothing, so the check is a no-op. `migrationGlobs: []` disables
 *       only the DISCOVERY of migrations from the impl-report; a path passed explicitly via
 *       --migrations-added is still checked, so the config cannot be used to disarm this
 *       gate for a named migration, and it does NOT disable the mis-tier tripwire, which
 *       reads the same key through a UNION resolver. The
 *       down-section marker defaults to a SQL line comment (`-- DOWN`); override it with
 *       `migrationDownMarker` if your rollback convention differs. A configured marker is
 *       ADDITIVE, not exclusive: the builtin `-- DOWN` keeps working alongside it.
 *
 *   (d) the down REGION of such a migration is COMMENTED-OUT DOCUMENTATION, not live SQL.
 *       The region begins at the first newline at or after the marker's line, so the marker
 *       text itself is never classified (a project configuring a non-comment marker such as
 *       `# DOWN` would otherwise fail every migration it ever writes). The region is then
 *       classified `clean`, `executable` or `indeterminate`; the latter two both halt, with
 *       DIFFERENT messages, so the fail-closed direction is pinned by what the gate SAYS and
 *       not by an accident of remainder length.
 *
 *       THE SCAN IS ONE LEFT-TO-RIGHT PASS AND THE FIRST-ENCOUNTERED TOKEN WINS. Inside a
 *       `--` line comment a `/*` is inert; inside a block comment a `--` is inert. Two-pass
 *       regex stripping is forbidden in either order: on the comment-toggle shape (a `-- /*`
 *       line, a bare `drop table foo;` line, and a `--` close-toggle line) stripping block
 *       comments first reads all three as commented and hands a database a live DROP.
 *
 *       A `--` COMMENT ENDS AT THE FIRST CR **OR** LF, not at LF alone. PostgreSQL's lexer
 *       defines the comment body as `[^\n\r]`, so on a lone CR (0x0D) the server resumes
 *       parsing SQL mid-line while MySQL/MariaDB and SQLite read on to the LF. That is a
 *       divergence, so it resolves the strict way per the rule below: `-- note<CR>drop table
 *       users;` is EXECUTABLE. Scanning to LF alone made those bytes classify `clean` and the
 *       gate accept a live DROP, one byte away from the same text with an LF, which it refused.
 *       CRLF is unaffected -- the CR ends the comment and the LF is skipped as whitespace.
 *
 *       Block comments do not nest here: the first close delimiter closes, whatever the depth.
 *       That is not a PostgreSQL emulation, it is the >= strict reading. PostgreSQL and SQL
 *       Server (T-SQL) count nesting; MySQL/MariaDB, SQLite and Oracle do not, so where an
 *       outer block encloses an inner `/*`, those servers end the comment at the INNER close
 *       delimiter and execute whatever follows it. Strip only what every target dialect agrees
 *       is a comment and classify executable on divergence. Because the non-nesting close is
 *       never later than the depth-matching one, divergence can only ADD residue: it can HALT
 *       a migration a nesting dialect would have run, never pass one it would have refused.
 *
 *       A BLOCK OPENER IMMEDIATELY FOLLOWED BY `!` OR `M!` IS NOT STRIPPED. `/*!`, `/*!NNNNN`
 *       and MariaDB's `/*M!` are MySQL/MariaDB conditional-execution comments whose bodies the
 *       server RUNS, so both candidate scans above would call them clean. `/*!40101 SET NAMES
 *       utf8` is ordinary mysqldump output, so an author pasting dump text in as documentation
 *       reaches this with no adversarial intent. The clause does NOT extend to a `/*+ hint`
 *       opener: an optimizer hint cannot be a standalone destructive statement, and refusing
 *       it would false-halt legitimate documentation.
 *
 *       DIALECT BOUNDARIES, DOCUMENTED AND DELIBERATELY NOT FIXED, each with its own cost:
 *         - MySQL `#` line comments are NOT stripped (`#` is not a comment in PostgreSQL,
 *           SQLite, Oracle or T-SQL, so stripping it would violate the rule above). A
 *           `#`-convention down BODY therefore has EVERY line refused, and the remedy is a
 *           per-line substitution to `--` across the migrations this pipeline touches, not a
 *           one-line edit. The marker fix in (d) does not rescue it: that lifts the marker
 *           LINE out of the region, never a `#`-written body.
 *         - `--x` with no following whitespace IS stripped although MySQL/MariaDB require the
 *           space. This is not a halt: the region passes. On a line that carries nothing else
 *           the cost lands as a syntax error at apply time on MySQL. ON A LINE THAT CARRIES A
 *           SECOND STATEMENT IT IS WORSE THAN THAT, and this is the boundary's real edge:
 *           `--x; drop table users;` reaches a `;`-splitting runner as a failing first
 *           statement followed by a live `drop table users`, so a runner that continues past
 *           an error (`mysql --force`, or any runner that does not abort) executes it. The
 *           earlier wording here ruled destruction out unconditionally, which was true only of
 *           the single-statement line it had in mind.
 *           DO NOT close this by requiring whitespace after `--`: that refuses `-----` section
 *           dividers and `--drop the index`, which are ordinary and legitimate, and would
 *           false-halt a large share of real down regions to catch a shape that needs BOTH a
 *           MySQL-family target AND a continue-past-error runner. The cost is stated here and
 *           fixtured in test-gate-down-classifier.sh instead, so it is a known boundary rather
 *           than a sentence promising more than the code does.
 *         - A genuinely-commented region containing a NESTED block comment false-halts on
 *           PostgreSQL and T-SQL. Cost: a one-to-two-line mechanical delimiter edit.
 *         - SQLite accepts an unterminated `/*` to EOF as a comment, so `indeterminate` is a
 *           false-halt there. Do NOT "fix" that by consuming to EOF: on PostgreSQL and MySQL
 *           that flips a `/*` followed by a DROP from a halt to a pass.
 *       THREE OF THE FOUR fail in the safe direction. The `--x` boundary is the exception, in
 *       the narrow shape named above, and it is the first thing to re-weigh if this project
 *       ever targets MySQL/MariaDB. Gate-green means "a down section is present and reads as
 *       documentation", never "rollback is known to work"; a human still reviews it.
 *
 * What it does NOT check (by design, so reviewers do not assume coverage exists):
 *   - Syntactic validity of migrations: that is your migration linter's job (CI).
 *   - Whether the documented rollback would actually restore the data.
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
import { isMain as isMainScript } from "./lib.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { validate, tokens, acLabels } from "./validate-pipeline-artifact.mjs";
import {
  DEFAULT_MIGRATION_GLOBS,
  isMigrationPath,
  migrationGlobsForGate,
} from "./data-layer-surface.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
// Schemas ship WITH the plugin (../schemas), independent of the user's project.
const SCHEMA_DIR = path.resolve(SCRIPT_DIR, "..", "schemas");
// Runtime artifacts live in the USER project's .pipeline/<issue>/ (gitignored).
const PROJECT_ROOT = process.env.CLAUDE_PROJECT_DIR || process.cwd();

// # CUSTOMIZE: which added files count as migrations lives in data-layer-surface.mjs (the
// SINGLE source of truth for that predicate); only the down-section marker is local.
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

// Glob resolution is migrationGlobsForGate's, in data-layer-surface.mjs: REPLACE semantics,
// so an explicit [] disables DISCOVERY of migrations from the impl-report and a custom array
// matches only what it names. It does NOT disable the check for a path passed explicitly via
// --migrations-added, which is read before any glob test.
//
// TWO OTHER CONSUMERS READ THE SAME KEY WITH DIFFERENT SEMANTICS, so a narrowing here is not
// a narrowing everywhere: migrationGlobsForTripwire UNIONS `migrationGlobs` with the built-in
// presets (the mis-tier tripwire can only ever be WIDENED by config, never narrowed, and an
// explicit [] does not disable it), and `extraMigrationGlobs` unions additively into this
// resolver as well as that one.

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

// The down REGION starts at the first newline at or after the marker's index, i.e. after the
// end of the marker LINE. downMarkerIndex returns the index of the START of that line, so
// slicing from it would leave the marker text itself inside the classified region -- and a
// project configuring a non-comment marker (`# DOWN`, `DOWN:`) would then fail every migration
// it ever writes, permanently, from its first upgrade.
export function downRegionStart(sql, marker = DEFAULT_DOWN_MARKER) {
  const idx = downMarkerIndex(sql, marker);
  if (idx === -1) return -1;
  const nl = sql.indexOf("\n", idx);
  return nl === -1 ? sql.length : nl + 1;
}

function lineColAt(sql, index) {
  let line = 1;
  let lastNewline = -1;
  for (let i = 0; i < index; i++) {
    if (sql[i] === "\n") {
      line++;
      lastNewline = i;
    }
  }
  return { line, column: index - lastNewline };
}

function lineTextAt(sql, index) {
  const from = sql.lastIndexOf("\n", index) + 1;
  const to = sql.indexOf("\n", index);
  // A CR that TERMINATES the line is CRLF and carries no information. One in the MIDDLE is why
  // the line is being quoted at all, and printing it raw makes the terminal overwrite the text
  // before it -- the quoted line would render as the live SQL alone, hiding the `--` the author
  // thought commented it out.
  return sql
    .slice(from, to === -1 ? sql.length : to)
    .replace(/\r$/, "")
    .replace(/\r/g, "\\r");
}

/**
 * Classify a migration's down region as `clean`, `executable` or `indeterminate`.
 *
 * ONE left-to-right scan; the first-encountered token wins. See the module docstring for why
 * two-pass stripping, nesting, and stripping a `/*!` opener each pass a live DROP.
 *
 * @returns {null | {kind: "clean"} | {kind: "executable"|"indeterminate", ...}} null when the
 *          migration has no down marker at all (the missing-down rule reports that instead).
 */
export function classifyDownRegion(sql, marker = DEFAULT_DOWN_MARKER) {
  if (typeof sql !== "string") return null;
  const start = downRegionStart(sql, marker);
  if (start === -1) return null;

  let closedBlock = null;
  let i = start;
  while (i < sql.length) {
    const ch = sql[i];
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
      i++;
      continue;
    }
    if (ch === "-" && sql[i + 1] === "-") {
      // PostgreSQL's lexer defines a line comment's body as `[^\n\r]`, so a LONE CR ends it
      // there and everything after the CR on that line is live SQL. Scanning to the next \n
      // only would strip that SQL as if it were commentary. Stop at whichever comes first and
      // leave the terminator itself to the whitespace skip, so CRLF is unaffected.
      let end = i + 2;
      while (end < sql.length && sql[end] !== "\n" && sql[end] !== "\r") end++;
      i = end;
      continue;
    }
    if (ch === "/" && sql[i + 1] === "*") {
      const opener = sql.slice(i + 2, i + 4);
      if (opener.startsWith("!") || opener.startsWith("M!")) {
        return {
          kind: "executable",
          reason: "conditional-execution",
          ...lineColAt(sql, i),
          lineText: lineTextAt(sql, i),
        };
      }
      const open = lineColAt(sql, i);
      const close = sql.indexOf("*/", i + 2);
      if (close === -1) {
        return { kind: "indeterminate", ...open, lineText: lineTextAt(sql, i) };
      }
      closedBlock = { open, close: lineColAt(sql, close) };
      i = close + 2;
      continue;
    }
    return {
      kind: "executable",
      reason: "residue",
      ...lineColAt(sql, i),
      lineText: lineTextAt(sql, i),
      closedBlock,
    };
  }
  return { kind: "clean" };
}

// A down region with no non-blank content at all. In this project a down region is
// DOCUMENTATION rather than executable SQL, so an empty one does not mean "nothing to roll
// back" -- it means nobody wrote the sentence saying what the operator does at 3am. There is
// deliberately NO sentinel token for this: free-text prose already satisfies it, and a sentinel
// would be a new term every adopting project has to learn, parse and keep from drifting.
export function downRegionIsEmpty(sql, marker = DEFAULT_DOWN_MARKER) {
  const start = downRegionStart(sql, marker);
  if (start === -1) return false;
  return sql.slice(start).trim() === "";
}

const REFLOW_REMEDY = "reflow the region to `--` line comments";

function classificationFailure(rel, result) {
  const where = `line ${result.line}, column ${result.column}`;
  if (result.kind === "indeterminate") {
    return (
      `migration "${rel}" down region is indeterminate: unterminated block comment opened at ` +
      `${where}: ${result.lineText}\n` +
      `    remedy: close the block, or ${REFLOW_REMEDY}.`
    );
  }
  if (result.reason === "conditional-execution") {
    return (
      `migration "${rel}" down region is executable: ${where} opens a MySQL/MariaDB ` +
      `conditional-execution comment, whose body the server RUNS rather than ignoring: ` +
      `${result.lineText}\n` +
      `    remedy: remove the \`!\`/\`M!\` from the opener so it is an ordinary block comment, ` +
      `or ${REFLOW_REMEDY}.`
    );
  }
  let msg =
    `migration "${rel}" down region contains executable SQL at ${where}: ${result.lineText}`;
  if (result.closedBlock) {
    msg +=
      `\n    the block comment opened at line ${result.closedBlock.open.line}, column ` +
      `${result.closedBlock.open.column} was ended by the first */ at line ` +
      `${result.closedBlock.close.line}, column ${result.closedBlock.close.column}; block ` +
      `comments do not nest in MySQL/MariaDB, SQLite or Oracle, so the first */ closes and ` +
      `everything after it is live SQL`;
  }
  msg += `\n    remedy: remove the inner \`/* */\` delimiters, or ${REFLOW_REMEDY}.`;
  return msg;
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
  const list = globs || [];
  if (list.length === 0) return []; // migrations disabled: nothing to infer
  const isMig = (f) => isMigrationPath(f, list);
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
      continue;
    }
    if (downRegionIsEmpty(sql, downMarker)) {
      failures.push(
        `migration "${mig.rel}" down region is empty: the marker is there, the rollback note ` +
          `is not. The gate requires at least one comment line saying what the operator does. ` +
          `A deliberately irreversible migration satisfies this by saying so in a comment, ` +
          `e.g. "-- irreversible: forward-only backfill, restore via PITR".`,
      );
      continue;
    }
    const classified = classifyDownRegion(sql, downMarker);
    if (classified.kind !== "clean") {
      failures.push(classificationFailure(mig.rel, classified));
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
  const globs = migrationGlobsForGate(cfg);
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

const isMain = isMainScript("gate-pre-phase4.mjs");

if (isMain) {
  main().catch((err) => {
    // FAIL CLOSED: any error (missing/unparseable artifact, internal fault) halts.
    process.stderr.write(`FAIL: pre-Phase-4 gate halted: ${err.message}\n`);
    process.exit(1);
  });
}
