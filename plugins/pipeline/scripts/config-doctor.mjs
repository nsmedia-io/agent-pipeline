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
    reader: "scripts/gate-pre-phase4.mjs",
    fallback: "a built-in guess at migration paths",
    degrades:
      "the pre-Phase-4 gate looks for migrations in the wrong place, so the down-migration check passes by finding nothing.",
  },
  migrationDownMarker: {
    type: "string",
    reader: "scripts/gate-pre-phase4.mjs",
    fallback: "the built-in rollback marker",
  },
};

/** Keys consumed by AGENT JUDGMENT rather than by code. Valid, but no script enforces them. */
const PROSE_KEYS = {
  architecturalTriggers: {
    type: "object",
    reader: "BA's tiering decision (prose, not code)",
  },
};

const ALL_KEYS = { ...CODE_KEYS, ...PROSE_KEYS };

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
  if (status === "ok") {
    console.log(lines[0]);
    return;
  }
  console.log(status === "absent" ? "Config: not configured" : "Config: needs attention");
  for (const l of lines) console.log(l);
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
