#!/usr/bin/env node
/**
 * config-doctor.mjs — does this project's pipeline.config.json actually do anything?
 *
 * WHY. Every knob in this plugin fails SOFT. A missing key takes a default, a misspelled key is
 * ignored, a wrong-typed value falls back. That is the right runtime behavior (a config typo
 * must never wedge a run) and it is exactly why the failure is invisible: the owner edits a
 * value, the plugin keeps using the default, and nothing anywhere says so.
 *
 * The bug that motivated this was in the plugin's OWN example config, shipped and unnoticed:
 * `pipeline.config.example.json` declared "migrationsGlob": "migrations/**" while
 * gate-pre-phase4.mjs reads `cfg.migrationGlobs` and requires an ARRAY. Wrong name and wrong
 * type. Anyone who copied the example, edited the path to match their repo, and moved on got
 * the built-in default forever, with the migration/down-marker gate looking somewhere else
 * entirely. Nothing was broken enough to notice.
 *
 * So this reports at session start: what is missing, what is misspelled (with the nearest real
 * key), what is the wrong type, and specifically what SILENTLY DEGRADES as a result.
 *
 * It is advisory. It never blocks, never exits non-zero on a bad config, and never writes.
 */

import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMain as isMainScript } from "./lib.mjs";
import { globToRegExp } from "./frontend-surface.mjs";
// diffTripsTripwire rather than the tripwire's glob resolver by name, and that is not a
// style choice: the tripwire's own test suite DISCOVERS the surface module by grepping
// scripts/*.mjs for that resolver's exported name, and this file sorts before it, so naming
// it here makes the suite mistake this script for the module under test.
import {
  dataLayerGlobs,
  diffTripsTripwire,
  infraGlobs,
  migrationGlobsForGate,
  trackedPaths,
} from "./data-layer-surface.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

/**
 * Keys read by CODE. `degrades` says what silently stops working when the key is absent or
 * unusable, which is the only part of this worth an owner's attention.
 */
const CODE_KEYS = {
  integrationBranch: {
    type: "string",
    reader: "hooks/session-start.sh, the agents' diff base",
    fallback: '"main"',
  },
  checkCommand: {
    type: "string",
    reader: "hooks/stop.sh",
    fallback: "npm run typecheck if package.json declares it, otherwise NOTHING",
    degrades:
      "the Stop hook stops verifying anything. Uncommitted work can end a turn with no typecheck, test or lint run.",
  },
  knowledgeDir: { type: "string", reader: "hooks/session-start.sh, Librarian", fallback: '"knowledge"' },
  frontendSurface: {
    type: "string[]",
    reader: "scripts/frontend-surface.mjs",
    fallback: "a built-in guess (*.tsx, *.jsx, components/, ui/, styles/)",
    degrades:
      "the Design reviewer joins (or skips) the panel based on a guess about your layout rather than your actual one.",
  },
  migrationGlobs: {
    type: "string[]",
    reader: "scripts/data-layer-surface.mjs, read by TWO consumers with DIFFERENT semantics: scripts/gate-pre-phase4.mjs (replace) and the mis-tier tripwire (union)",
    fallback: "the built-in fifteen-row framework-preset union",
    degrades:
      "TWO consumers read this key and they do not read it the same way. migrationGlobsForGate REPLACES the preset union, so narrowing it narrows what the pre-Phase-4 gate DISCOVERS in the impl-report and the down-migration check passes by finding nothing. the mis-tier tripwire's own resolver UNIONS it with the presets, so narrowing it does NOT narrow the mis-tier tripwire, which config can only ever widen. To widen BOTH without narrowing either, set extraMigrationGlobs instead.",
  },
  extraMigrationGlobs: {
    type: "string[]",
    reader: "scripts/data-layer-surface.mjs (all three resolvers)",
    fallback: "[] (nothing extra)",
    degrades:
      "a custom migration layout the built-in presets do not name is invisible to the gate, the mis-tier tripwire and the DBA panel seat. This key only ever WIDENS; it can never replace or disarm anything.",
  },
  dataLayerGlobs: {
    type: "string[]",
    reader: "scripts/data-layer-surface.mjs (diffTouchesDataLayer)",
    fallback: "the tripwire's union plus the built-in broad extras",
    degrades:
      "DBA joins (or skips) the Phase 4 panel based on a guess about your layout rather than your actual one. Empty or invalid means DEFAULTS: an explicit [] never means seat nobody.",
  },
  infraGlobs: {
    type: "string[]",
    reader: "scripts/data-layer-surface.mjs (diffTouchesInfra)",
    fallback: "the built-in CI/deploy/infra set",
    degrades:
      "DevOps joins (or skips) the Phase 4 panel based on a guess about your layout. Empty or invalid means DEFAULTS.",
  },
  dispatchModels: {
    type: "object",
    reader: "scripts/dispatch-model.mjs",
    fallback: "the built-in default routing table",
    degrades:
      "per-role model overrides are ignored and every dispatch runs the built-in assignment. secops and qa are pinned in code and ignore this key entirely.",
  },
  dispatchEfforts: {
    type: "object",
    reader: "scripts/dispatch-effort.mjs",
    fallback: "the built-in default effort table",
    degrades:
      "per-role effort overrides are ignored and every dispatch runs the built-in assignment. secops and qa are pinned in code and ignore this key entirely. NOTE this key only reaches the Workflow dispatch surface: the Agent tool carries no effort parameter, so on today's Agent-tool dispatches agents/<role>.md frontmatter governs whatever this says.",
  },
  migrationDownMarker: {
    type: "string",
    reader: "scripts/gate-pre-phase4.mjs",
    fallback: 'the built-in "-- DOWN" line-comment marker',
  },
};

/** Keys consumed by AGENT JUDGMENT rather than by code. Valid, but no script enforces them. */
const PROSE_KEYS = {
  architecturalTriggers: {
    type: "object",
    reader:
      "prose: agents/ba.md Phase 1 duty 6 (floor + config union) and commands/pipeline.md ### Risk-tiered orchestration depth (post-BA validation clause)",
  },
};

// Exported so a test can assert that every key the README table and commands/pipeline.md
// name in backticks actually resolves to a key some script reads. A documented key that
// resolves to nothing is the same defect as a configured key that is read by nothing.
export const ALL_KEYS = { ...CODE_KEYS, ...PROSE_KEYS };

function typeOf(v) {
  if (Array.isArray(v)) return v.every((x) => typeof x === "string") ? "string[]" : "array";
  if (v === null) return "null";
  return typeof v;
}

function levenshtein(a, b) {
  const m = a.length;
  const n = b.length;
  let prev = Array.from({ length: n + 1 }, (_, j) => j);
  for (let i = 1; i <= m; i++) {
    const cur = [i];
    for (let j = 1; j <= n; j++) {
      cur[j] = Math.min(
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
    }
    prev = cur;
  }
  return prev[n];
}

/** Nearest known key within a small edit distance, or null. Catches migrationsGlob. */
export function nearestKey(unknown) {
  let best = null;
  let bestD = Infinity;
  for (const k of Object.keys(ALL_KEYS)) {
    const d = levenshtein(unknown.toLowerCase(), k.toLowerCase());
    if (d < bestD) {
      bestD = d;
      best = k;
    }
  }
  return bestD <= 3 ? best : null;
}

/**
 * @returns {{status: string, lines: string[]}} status: ok | absent | unreadable | issues
 */
export function diagnose(projectDir, opts = {}) {
  const file = path.join(projectDir, "pipeline.config.json");
  const lines = [];

  if (!existsSync(file)) {
    lines.push("  No pipeline.config.json at the project root. Defaults apply to everything.");
    if (!opts.hasTypecheckScript) {
      lines.push(
        "  Without checkCommand the Stop hook verifies NOTHING: a turn can end on uncommitted work with no typecheck, test or lint run.",
      );
    } else {
      lines.push(
        '  Without checkCommand the Stop hook falls back to "npm run typecheck" only: no tests, no lint.',
      );
    }
    lines.push("  Start with: cp \"$CLAUDE_PLUGIN_ROOT/pipeline.config.example.json\" pipeline.config.json");
    return { status: "absent", lines };
  }

  let cfg;
  try {
    cfg = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    lines.push(`  pipeline.config.json is not valid JSON (${e.message}).`);
    lines.push("  Every key falls back to its default until this parses. Nothing else will warn you.");
    return { status: "unreadable", lines };
  }
  if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) {
    lines.push("  pipeline.config.json does not hold a JSON object at its top level; all keys ignored.");
    return { status: "unreadable", lines };
  }

  const problems = [];

  for (const [key, value] of Object.entries(cfg)) {
    if (key.startsWith("_")) continue; // _comment and friends are conventional
    const spec = ALL_KEYS[key];
    if (!spec) {
      const near = nearestKey(key);
      problems.push(
        near
          ? `"${key}" is read by nothing. Did you mean "${near}"? (${ALL_KEYS[near].type}, used by ${ALL_KEYS[near].reader})`
          : `"${key}" is read by nothing in this plugin.`,
      );
      continue;
    }
    const actual = typeOf(value);
    if (actual !== spec.type) {
      problems.push(
        `"${key}" should be ${spec.type} but is ${actual}; it is IGNORED and ${spec.fallback || "the default"} applies.`,
      );
    }
  }

  // checkCommand is called out on its own because it is the one key whose absence turns a
  // whole gate into a no-op rather than into a different default.
  const hasCheck = typeof cfg.checkCommand === "string" && cfg.checkCommand.trim() !== "";
  if (!hasCheck) {
    problems.push(
      opts.hasTypecheckScript
        ? 'no checkCommand: the Stop hook falls back to "npm run typecheck" only (no tests, no lint).'
        : "no checkCommand: the Stop hook verifies NOTHING before a turn ends.",
    );
  }

  if (problems.length === 0) {
    return { status: "ok", lines: ["  pipeline.config.json: all keys recognized, checkCommand set."] };
  }
  for (const p of problems) lines.push(`  ${p}`);
  return { status: "issues", lines };
}

/**
 * SURFACE REPORT: the second half of this tool's job, and it is reported at PATTERN
 * granularity per CONSUMER rather than per key.
 *
 * Why not per key: every surface key's effective set is now a UNION that always contains the
 * built-in defaults, so in any repo where the defaults match something the union matches
 * something, and no misconfiguration of the CONFIGURED patterns could ever produce a report.
 * That is the CODEOWNERS failure mode (a stale pattern that silently owns nothing) wearing
 * this tool's clothes. And in the other direction, a repo with no data layer at all would
 * have emitted a permanent every-session warning, which is how a report gets learned-ignored.
 *
 * Contract, unchanged by any of this: these are REPORT LINES. The exit code stays 0, nothing
 * is written, and a project that is not a git repository (or has nothing tracked yet) gets
 * NO zero-match output at all, because a zero over a population that does not exist is not a
 * finding. hooks/session-start.sh discards this script's exit code and its stderr, so a crash
 * here would be silent and the whole report would simply vanish.
 */
const SURFACE_KEYS = {
  migrationGlobs: "the pre-Phase-4 gate discovers no migration under it (it REPLACES the preset union, so the down-section check passes by finding nothing)",
  extraMigrationGlobs: "it widens nothing: no file is added to gate discovery, the mis-tier tripwire, or the DBA panel seat",
  dataLayerGlobs: "DBA is never seated by it",
  infraGlobs: "DevOps is never seated by it",
  frontendSurface: "the Design lens and the visual gate are never triggered by it",
};

// SEC-4 / SEC-14: globToRegExp escapes braces and brackets as regex LITERALS and anchors with
// '^', so each of these compiles to a pattern that silently matches nothing (or matches a
// literal path nobody has), while the key still reports as present, correctly typed and read
// by a real script -- i.e. healthy. Warning only, never an error: a directory name may
// legitimately contain a bracket, and a gate that refuses correct config gets switched off.
function globSyntaxProblem(glob) {
  if (/[{}[\]]/.test(glob)) return "brace/bracket expansion is NOT supported (it compiles to a literal, matching nothing)";
  if (glob.startsWith("!")) return "a leading '!' is not a negation here (it compiles to a literal '!')";
  if (glob.startsWith("../")) return "a leading '../' cannot match a repo-relative diff path";
  if (glob.startsWith("/")) return "a leading '/' cannot match a repo-relative diff path (they never start with '/')";
  return null;
}

/** Every string glob in a surface key, with its key and index, for the reports below. */
function configuredPatterns(cfg) {
  const out = [];
  for (const key of Object.keys(SURFACE_KEYS)) {
    const v = cfg[key];
    if (!Array.isArray(v)) continue;
    v.forEach((g, i) => out.push({ key, index: i, glob: g }));
  }
  return out;
}

export function surfaceReport(projectDir, cfg) {
  const lines = [];
  if (!cfg || typeof cfg !== "object") return lines;
  const patterns = configuredPatterns(cfg);

  // Pure string checks: they need no repository, so they run everywhere.
  for (const { key, index, glob } of patterns) {
    if (typeof glob !== "string") {
      lines.push(
        `  WARNING: ${key}[${index}] is ${JSON.stringify(glob)}, not a string. It is DROPPED before compilation, so the value you set is only PARTLY in effect.`,
      );
      continue;
    }
    const problem = globSyntaxProblem(glob);
    if (problem) {
      lines.push(
        `  WARNING: ${key} pattern "${glob}": ${problem}. Consequence: ${SURFACE_KEYS[key]}.`,
      );
    }
  }

  // Zero-match reporting needs a population. `git ls-files` (tracked only, so it never walks
  // node_modules or a gitignored tree); no repo, no git, nothing tracked yet, or a repo over
  // the path budget all mean NO INFORMATION, and no information is not a zero.
  const tracked = trackedPaths(projectDir);
  if (!tracked || tracked.length === 0) return lines;

  // Compile each pattern ONCE and stop at its first hit: this runs inside a 10-second
  // SessionStart budget that already contains a git fetch and a knowledge-store search.
  const matchesAnything = (glob) => {
    let re;
    try {
      re = globToRegExp(glob);
    } catch {
      return true; // uncompilable: already reported above, do not also call it a zero match
    }
    return tracked.some((p) => re.test(p));
  };

  // (a) The CODEOWNERS class: an individually CONFIGURED pattern that owns nothing. This fires
  // only for something the project actually wrote, never for a project that configured nothing.
  for (const { key, glob } of patterns) {
    if (typeof glob !== "string") continue;
    if (globSyntaxProblem(glob)) continue;
    if (!matchesAnything(glob)) {
      lines.push(
        `  WARNING: ${key} pattern "${glob}" matches NONE of the ${tracked.length} tracked files in this project, so ${SURFACE_KEYS[key]}.`,
      );
    }
  }

  // (b) The GATE's effective set, reported SEPARATELY from the TRIPWIRE's union and in its own
  // consumer's consequence terms, because only the gate's set can go dead: the tripwire's is a
  // union with the built-in presets, so config can never empty it.
  const gateGlobs = migrationGlobsForGate(cfg);
  const gateDead = !gateGlobs.some(matchesAnything);
  const tripDead = !diffTripsTripwire(tracked, cfg);
  const configuredNarrow = Array.isArray(cfg.migrationGlobs) || Array.isArray(cfg.extraMigrationGlobs);
  if (gateDead && configuredNarrow) {
    lines.push(
      `  WARNING: with your migrationGlobs, the pre-Phase-4 down-section gate discovers NOTHING in this project: its effective set (${gateGlobs.map((g) => `"${g}"`).join(", ") || "empty"}) matches no tracked file. The reversibility check will pass by checking zero files.`,
    );
    if (!tripDead) {
      lines.push(
        "  INFO: the mis-tier tripwire is unaffected by that. It reads the same key through a UNION with the built-in presets, so it still fires; only the gate's discovery went dead.",
      );
    }
  }

  // (c) A defaults-only zero match is a FACT about a project with no data layer, not a
  // standing warning. Demoted deliberately: a warning that fires every session in a repo that
  // will never have a migration is one people learn to scroll past.
  if (!configuredNarrow && tripDead) {
    lines.push(
      "  INFO: no tracked file matches the built-in data-layer globs, so this project has no data layer the pipeline can see: the mis-tier tripwire cannot fire here and DBA is never seated by a path predicate. That is a fact, not a problem, unless you expected otherwise.",
    );
  }
  if (!Array.isArray(cfg.dataLayerGlobs) && !dataLayerGlobs(cfg).some(matchesAnything)) {
    lines.push(
      "  INFO: and no tracked file matches the broad data-layer set either (the DBA panel seat is path-driven and will not open).",
    );
  }
  if (!Array.isArray(cfg.infraGlobs) && !infraGlobs(cfg).some(matchesAnything)) {
    lines.push("  INFO: no tracked file matches the built-in infra globs (the DevOps panel seat will not open).");
  }
  return lines;
}

function main() {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  let hasTypecheckScript = false;
  try {
    const pkg = JSON.parse(readFileSync(path.join(projectDir, "package.json"), "utf8"));
    hasTypecheckScript = Boolean(pkg?.scripts?.typecheck);
  } catch {
    /* no package.json: leave false */
  }
  const { status, lines } = diagnose(projectDir, { hasTypecheckScript });
  let cfg = {};
  try {
    cfg = JSON.parse(readFileSync(path.join(projectDir, "pipeline.config.json"), "utf8"));
  } catch {
    /* absent or unparseable: diagnose() already said so, and the surface report needs a config */
  }
  // Report lines only. The status (and therefore the banner) is deliberately NOT influenced by
  // them: a surface that owns nothing is worth saying out loud and is never a reason to tell an
  // owner their config "needs attention".
  const surface = cfg && typeof cfg === "object" && !Array.isArray(cfg) ? surfaceReport(projectDir, cfg) : [];
  if (status === "ok") {
    console.log(lines[0]);
    for (const l of surface) console.log(l);
    return;
  }
  console.log(status === "absent" ? "Config: not configured" : "Config: needs attention");
  for (const l of lines) console.log(l);
  for (const l of surface) console.log(l);
}

// ---- self-test -----------------------------------------------------------
function selfTest() {
  let pass = 0;
  let fail = 0;
  const check = (name, actual, expected) => {
    if (actual === expected) {
      pass++;
      console.log(`  ok   ${name}`);
    } else {
      fail++;
      console.log(`  FAIL ${name}\n       expected ${expected}, got ${actual}`);
    }
  };

  const dir = mkdtempSync(path.join(tmpdir(), "cfgdoctor-"));
  const write = (obj) =>
    writeFileSync(path.join(dir, "pipeline.config.json"), typeof obj === "string" ? obj : JSON.stringify(obj));
  const joined = (o = {}) => diagnose(dir, o).lines.join("\n");

  try {
    rmSync(path.join(dir, "pipeline.config.json"), { force: true });
    check("absent config reports absent", diagnose(dir).status, "absent");
    check("absent config names the Stop-hook consequence", /verifies NOTHING/.test(joined()), true);
    check(
      "absent config softens the claim when package.json has typecheck",
      /falls back to "npm run typecheck"/.test(joined({ hasTypecheckScript: true })),
      true,
    );

    write("{ not json");
    check("unparseable config is reported", diagnose(dir).status, "unreadable");
    write([1, 2]);
    check("a top-level array is reported", diagnose(dir).status, "unreadable");

    write({ checkCommand: "npm test" });
    check("a minimal valid config is ok", diagnose(dir).status, "ok");

    write({ checkCommand: "npm test", _comment: "ignored" });
    check("_-prefixed keys are not flagged", diagnose(dir).status, "ok");

    // THE LIVE DEFECT this tool was written for: the shipped example's own key.
    write({ checkCommand: "npm test", migrationsGlob: "migrations/**" });
    check("the real misspelling is caught", diagnose(dir).status, "issues");
    check("and the nearest key is suggested", /Did you mean "migrationGlobs"/.test(joined()), true);
    check("nearestKey maps migrationsGlob -> migrationGlobs", nearestKey("migrationsGlob"), "migrationGlobs");

    write({ checkCommand: "npm test", migrationGlobs: "migrations/**" });
    check("right name, wrong type is caught", /should be string\[\] but is string/.test(joined()), true);

    write({ checkCommand: "npm test", somethingEntirelyElse: 1 });
    check("an unrelated key is flagged without a bogus suggestion", /read by nothing in this plugin/.test(joined()), true);

    write({ integrationBranch: "trunk" });
    check("a config with no checkCommand is flagged", /verifies NOTHING/.test(joined()), true);
    check(
      "and softens when package.json has typecheck",
      /falls back to "npm run typecheck" only/.test(joined({ hasTypecheckScript: true })),
      true,
    );

    // Non-zero control on the instrument: a fully-populated valid config must be silent, or
    // every case above would just be proving the doctor complains about everything.
    write({
      integrationBranch: "main",
      checkCommand: "npm test",
      knowledgeDir: "knowledge",
      frontendSurface: ["**/*.tsx"],
      migrationGlobs: ["migrations/**"],
      migrationDownMarker: "-- down",
      architecturalTriggers: { domains: ["data"] },
    });
    check("INSTRUMENT: a fully-populated valid config is ok", diagnose(dir).status, "ok");

    // Every key the example ships must be one this table knows, or the example teaches a typo.
    // Derived from the shipped file, not from memory.
    const examplePath = path.resolve(SCRIPT_DIR, "..", "pipeline.config.example.json");
    try {
      const example = JSON.parse(readFileSync(examplePath, "utf8"));
      const unknown = Object.keys(example).filter((k) => !k.startsWith("_") && !ALL_KEYS[k]);
      check(`the shipped example declares only real keys (${unknown.join(", ") || "none unknown"})`, unknown.length, 0);
    } catch {
      check("the shipped example is readable", false, true);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  console.log(`\nself-test: ${pass} passed, ${fail} failed`);
  return fail === 0;
}

if (isMainScript("config-doctor.mjs")) {
  if (process.argv.includes("--self-test")) process.exit(selfTest() ? 0 : 1);
  main();
}
