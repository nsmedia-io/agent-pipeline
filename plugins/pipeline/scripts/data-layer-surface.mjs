#!/usr/bin/env node
/**
 * SINGLE source of truth for which changed paths count as a DATA-LAYER surface, and which
 * count as an INFRA surface. The parallel of frontend-surface.mjs, for the other two
 * surface-conditional lenses (DBA, DevOps) and for the mis-tier tripwire.
 *
 * THREE GLOB RESOLVERS, AND THEIR NAMES CARRY THE DIFFERENCE ON PURPOSE.
 *
 *   migrationGlobsForGate(cfg)      REPLACE. `migrationGlobs` REPLACES the built-in preset
 *                                   union, and an explicit [] replaces it with nothing. This
 *                                   is the shipped, tested contract of the pre-Phase-4
 *                                   down-section gate: a project may narrow what the gate
 *                                   DISCOVERS from the impl-report (a path named explicitly
 *                                   via --migrations-added is still checked either way).
 *
 *   migrationGlobsForTripwire(cfg)  UNION. The built-in presets are always present; config
 *                                   may only ever WIDEN the halt. A four-character edit to
 *                                   `migrationGlobs` must not be able to disarm a halting
 *                                   control while the config still reports healthy.
 *
 *   dataLayerGlobs(cfg)             BROAD. Panel composition (who reviews), not a halt.
 *
 * Same key, opposite directions, which is why the two resolvers are two exported names
 * rather than one shared helper with a flag: a later refactor cannot collapse them without
 * deleting a name that says what it does.
 *
 * `extraMigrationGlobs` is the ADDITIVE key. It unions into all three resolvers and can
 * never replace, so an adopter with a custom declarative layout can widen discovery without
 * narrowing anything.
 *
 * # CUSTOMIZE: set `migrationGlobs` (narrow, gate discovery), `extraMigrationGlobs`
 * (additive, all three), `dataLayerGlobs` (broad, the DBA panel seat) and `infraGlobs` (the
 * DevOps panel seat) in pipeline.config.json at your project root.
 */

import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { globToRegExp } from "./frontend-surface.mjs";

/**
 * NARROW set: "this path is a schema/migration artifact". Drives the mis-tier tripwire (a
 * HALT) and the gate's migration discovery. Every row is justified by at least one path no
 * other row matches; redundant rows were deliberately left out, because a row that can never
 * be the only match is a maintenance lie.
 */
export const DEFAULT_MIGRATION_GLOBS = [
  "**/migrations/**", // generic, Django, Laravel, Supabase, Prisma
  "**/Migrations/**", // EF Core; globToRegExp is case-SENSITIVE, so this is its own row
  "**/db/migrate/**", // Rails
  "**/db/migration/**", // Flyway (singular)
  "**/db/changelog/**", // Liquibase
  "**/alembic/versions/**", // Alembic outside a migrations/ dir
  "**/schema.prisma", // Prisma single-file
  "**/prisma/schema/**", // Prisma prismaSchemaFolder layout
  "**/drizzle/**", // Drizzle output dir
  "**/db/schema.ts", // Drizzle schema
  "**/db/schema/**", // Drizzle multi-file schema
  "**/supabase/schemas/**", // Supabase declarative schemas
  "**/policies/**.sql", // SQL data-access policy sources
  "**/supabase/policies/**", // RLS policy sources under supabase/, regardless of extension
  "**/schema.sql", // generic declarative dump
];

/**
 * BROAD-only rows, unioned on top of the narrow set. Panel composition is cheap and
 * reversible, so this set is deliberately over-inclusive where the narrow set is not.
 */
export const DEFAULT_BROAD_EXTRAS = [
  "**/db/**",
  "**/queries/**",
  "**/policies/**",
  "**/repositories/**",
  "**/prisma/**",
  "**/supabase/**",
  "**/alembic/**",
  "**/schema.ts",
  "**/database.types.ts",
  "**/*.generated.types.ts",
];

/** INFRA set: CI config, deploy scripts, service/infra config. */
export const DEFAULT_INFRA_GLOBS = [
  "**/.github/workflows/**",
  ".github/**",
  "**/infra/**",
  "**/terraform/**",
  "**/k8s/**",
  "**/helm/**",
  "**/deploy/**",
  "**/deploy.sh",
  "**/deploy.config",
  "**/*.tf",
  "**/*.tfvars",
  "**/Dockerfile",
  "**/docker-compose.yml",
  "**/docker-compose.yaml",
];

/**
 * Code-resident (config-unreachable, therefore not an off-switch) exclusion on the NARROW
 * set only: a migration artifact is never markdown. Without it a documentation typo under
 * any docs/migrations/ directory eats a permanent, un-narrowable re-tier halt.
 */
const NARROW_EXCLUDED_EXTENSIONS = [".md", ".mdx"];

function projectRoot() {
  return process.env.CLAUDE_PROJECT_DIR || process.cwd();
}

/** Project config. A missing or malformed file is not an error: it means {}. */
export function readPipelineConfig(dir) {
  const file = path.join(dir || projectRoot(), "pipeline.config.json");
  try {
    if (!existsSync(file)) return {};
    const cfg = JSON.parse(readFileSync(file, "utf8"));
    if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) return {};
    return cfg;
  } catch {
    return {};
  }
}

/**
 * Non-string elements are DROPPED, never compiled: globToRegExp(null) throws TypeError, and
 * a resolver that throws takes the halt down with it (the tripwire's shell shape then reads
 * a failure as "no hit"). 123/{}/[] compile harmlessly, but they are dropped too, so
 * "the config is healthy" is never said about a value that was partly discarded.
 */
function stringsOnly(v) {
  return Array.isArray(v) ? v.filter((g) => typeof g === "string") : [];
}

function union(...lists) {
  const out = [];
  for (const list of lists) {
    for (const g of list) if (!out.includes(g)) out.push(g);
  }
  return out;
}

/** The additive key, guarded. Unions into every resolver; can never replace. */
function extraGlobs(cfg) {
  return stringsOnly(cfg && cfg.extraMigrationGlobs);
}

/**
 * REPLACE semantics, unchanged from the shipped gate: a valid all-string array (including an
 * explicit []) replaces the defaults; anything else falls back to them. extraMigrationGlobs
 * unions on top, so widening is available without touching the narrowing affordance.
 */
export function migrationGlobsForGate(cfg) {
  const raw = cfg && cfg.migrationGlobs;
  const base =
    Array.isArray(raw) && raw.every((g) => typeof g === "string") ? raw : DEFAULT_MIGRATION_GLOBS;
  return union(stringsOnly(base), extraGlobs(cfg));
}

/**
 * UNION semantics. The invariant this buys, stated with its mechanism rather than asserted:
 * the tripwire set is literally defaults-UNION-config and the gate set is config-OR-defaults
 * plus the same extra union, so the tripwire set is ALWAYS a superset of the gate's. The
 * union is what makes the superset relation hold; it is not a property of any one corpus.
 */
export function migrationGlobsForTripwire(cfg) {
  return union(DEFAULT_MIGRATION_GLOBS, stringsOnly(cfg && cfg.migrationGlobs), extraGlobs(cfg));
}

/**
 * BROAD set. Its DEFAULT is defined over migrationGlobsForTripwire (never over the gate's
 * set), so an adopter who configured only `migrationGlobs` still seats DBA for the paths
 * they named, and the broad set stays a superset of the halting set. An explicit [] means
 * DEFAULTS: "seat nobody" is never what an empty array should buy.
 */
export function dataLayerGlobs(cfg) {
  const configured = stringsOnly(cfg && cfg.dataLayerGlobs);
  if (configured.length > 0) return union(configured, extraGlobs(cfg));
  return union(migrationGlobsForTripwire(cfg), DEFAULT_BROAD_EXTRAS);
}

/** INFRA set. Same empty-means-defaults rule as the broad set. */
export function infraGlobs(cfg) {
  const configured = stringsOnly(cfg && cfg.infraGlobs);
  return configured.length > 0 ? configured : DEFAULT_INFRA_GLOBS;
}

function normalizePath(p) {
  return p.replace(/\\/g, "/").replace(/^\.\//, "");
}

function matchesAny(p, globs) {
  const norm = normalizePath(p);
  return (globs || []).some((g) => typeof g === "string" && globToRegExp(g).test(norm));
}

/**
 * The NARROW predicate. Pure: the caller supplies the glob list, so the tripwire's union and
 * the gate's replace-set run through the same matcher and no consumer compiles a regex of
 * its own.
 */
export function isMigrationPath(p, globs = DEFAULT_MIGRATION_GLOBS) {
  if (typeof p !== "string") return false;
  const norm = normalizePath(p);
  const dot = norm.lastIndexOf(".");
  const ext = dot === -1 ? "" : norm.slice(dot).toLowerCase();
  if (NARROW_EXCLUDED_EXTENSIONS.includes(ext)) return false;
  return matchesAny(norm, globs);
}

/** The BROAD predicate: does this path seat DBA on the panel? */
export function isDataLayerPath(p, cfg) {
  if (typeof p !== "string") return false;
  return matchesAny(p, dataLayerGlobs(cfg || readPipelineConfig()));
}

export function diffTouchesDataLayer(changedPaths, cfg) {
  const globs = dataLayerGlobs(cfg || readPipelineConfig());
  return (changedPaths || []).some((p) => typeof p === "string" && matchesAny(p, globs));
}

/** The INFRA predicate: does this path seat DevOps on the panel? */
export function isInfraPath(p, cfg) {
  if (typeof p !== "string") return false;
  return matchesAny(p, infraGlobs(cfg || readPipelineConfig()));
}

export function diffTouchesInfra(changedPaths, cfg) {
  const globs = infraGlobs(cfg || readPipelineConfig());
  return (changedPaths || []).some((p) => typeof p === "string" && matchesAny(p, globs));
}

/** True when ANY changed path is a migration under the TRIPWIRE's (union) set. */
export function diffTripsTripwire(changedPaths, cfg) {
  const globs = migrationGlobsForTripwire(cfg || readPipelineConfig());
  return (changedPaths || []).some((p) => isMigrationPath(p, globs));
}

const TRACKED_PATH_BUDGET = 20000;

/**
 * Tracked paths, or null when this is not a git repository (or git is absent, or the repo is
 * larger than the budget). Callers must treat null as "no information", never as "zero
 * matches": a crash or a wrong zero here is invisible, because every caller discards stderr.
 */
export function trackedPaths(dir) {
  try {
    const out = execFileSync("git", ["-C", dir || projectRoot(), "ls-files"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      maxBuffer: 32 * 1024 * 1024,
    });
    const paths = out.split("\n").filter(Boolean);
    return paths.length > TRACKED_PATH_BUDGET ? null : paths;
  } catch {
    return null;
  }
}

/**
 * What the tripwire needs, in one call, so its shell site is a single unpiped invocation:
 * the hits, plus the zero-match note R19b puts at the POINT OF USE (the session-start banner
 * that reports the same fact may have scrolled past days earlier).
 */
export function tripwireReport(changedPaths, dir) {
  const root = dir || projectRoot();
  const cfg = readPipelineConfig(root);
  const globs = migrationGlobsForTripwire(cfg);
  const hits = (changedPaths || []).filter((p) => isMigrationPath(p, globs));
  let note = null;
  // The note is SUPPRESSED whenever there are hits, because pipeline.md tells the orchestrator
  // to file it in status.json (`flags`): a run that halted ON a tripwire hit would otherwise
  // record a flag saying the tripwire cannot fire here. The two statements were computed over
  // different populations (the changed paths, and the tracked tree), so they could both be
  // emitted and contradict each other in the same object.
  if (hits.length === 0) {
    const tracked = trackedPaths(root);
    if (tracked && !tracked.some((p) => isMigrationPath(p, globs))) {
      note =
        "the mis-tier tripwire's effective glob set matches zero tracked files in this repository, so it cannot fire here";
    }
  }
  return { hits, note };
}
