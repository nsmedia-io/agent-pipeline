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

import { readFileSync, readdirSync, existsSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
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
    fallback: "the built-in tiered effort table",
    degrades:
      "per-role effort overrides are ignored and every dispatch runs the built-in tiered assignment (SecOps xhigh/high/medium and QA high/medium/medium by tier on the Phase 4 panel). Every role is reachable, in both directions, allowlisted. NOTE this key only reaches the Workflow dispatch surface (the Phase 4 panel): the Agent tool carries no effort parameter, so on Agent-tool dispatches agents/<role>.md frontmatter governs whatever this says.",
  },
  usageTelemetry: {
    type: "object",
    reader: "scripts/dispatch-log.mjs (through hooks/dispatch-log.sh) and scripts/usage-report.mjs",
    fallback: "off: no dispatch log is written",
    degrades:
      'nothing breaks: this is off by default. When it is absent or not an object, no dispatch line is written, so scripts/usage-report.mjs can report tokens per model but cannot attribute them to an issue, phase or role. Set { "enabled": true } to log, and optionally "dir" (absolute, or relative to the project root) for where the log goes; the default is <git common dir>/agent-pipeline-telemetry. CLAUDE_PIPELINE_USAGE_TELEMETRY=1 or 0 overrides this key for one session.',
  },
  securitySurfaceGlobs: {
    type: "string[]",
    reader: "scripts/security-surface.mjs (diffTouchesSecuritySurface)",
    fallback: "the built-in auth/session/crypto/secrets/webhook/policy set",
    degrades:
      "SecOps is re-seated on a Phase 4 DELTA round only when the fix commits touch a security surface (or the data layer, or it objected). This key can only WIDEN that set; it never narrows or disarms it. A security path the built-in set does not name lets a fix round skip the SecOps re-read.",
  },
  migrationDownMarker: {
    type: "string",
    reader: "scripts/gate-pre-phase4.mjs",
    fallback: 'the built-in "-- DOWN" line-comment marker',
  },
  deferralTracker: {
    type: "string",
    reader: "scripts/deferral.mjs, read by scripts/gate-pre-phase4.mjs through it",
    fallback: '"github"',
    degrades:
      'the deferral ledger routes to `gh issue create` whatever your project uses. Legal values are "github", "gitlab" and "directory"; anything else is IGNORED and github applies, so a project on neither tracker records deferrals into a command it does not have and the pre-Phase-4 gate refuses every tracker_ref it writes. Set "directory" to keep the ledger in the repository instead.',
  },
  ciRequiredForMerge: {
    type: "boolean",
    reader: "scripts/merge-ready.mjs",
    fallback: "true",
    degrades:
      "a PR with no CI checks reported on its head is NOT ready to merge, because CI that has not registered yet looks the same as no CI. Set false only for a project with no remote CI; a failing or pending check refuses either way.",
  },
  deferralDir: {
    type: "string",
    reader: "scripts/deferral.mjs (directory mode only)",
    fallback: '"knowledge/deferred"',
    degrades:
      'nothing at all unless deferralTracker is "directory"; in that mode it is where the committed ledger files are written and the only place the pre-Phase-4 gate will accept a tracker_ref from. An absolute path or one containing a ".." segment is refused and the default applies, because this key names a directory the pipeline writes committed files into.',
  },
};

/** Keys consumed by AGENT JUDGMENT rather than by code. Valid, but no script enforces them. */
const PROSE_KEYS = {
  architecturalTriggers: {
    type: "object",
    reader:
      "prose: agents/ba.md Phase 1 duty 6 (floor + config union) and commands/pipeline.md ### Risk-tiered orchestration depth (post-BA validation clause). ADVISORY: no script reads it; architecturalTriggers.keywords in particular is read only by the BA agent's judgment, so a keyword never forces a tier mechanically",
  },
};

/**
 * THE CONSUMER-OWNED NAMESPACE. A project that keeps its own settings in pipeline.config.json
 * (a wrapper script's knobs, a team note) used to get a "read by nothing" warning every session,
 * and the only way out was a `_` prefix documented nowhere. Two spellings are exempt now, and
 * both are stated in the warning itself so the remedy travels with the complaint:
 *   - any top-level key starting with `_` (the `_comment` convention, kept as it was);
 *   - the `x` object, for structured project-owned settings. The doctor checks only that it
 *     is an object and never reads inside it, and no plugin script ever will.
 */
const CONSUMER_KEYS = {
  x: {
    type: "object",
    reader: "nothing in this plugin, by contract: the project-owned namespace, never read inside",
    fallback: "absent",
  },
};

export const CONSUMER_NAMESPACE_HINT =
  'Project-owned settings belong under the "x" object or in a key starting with "_"; the plugin never reads either.';

/** True for a top-level key the project owns and the plugin must never flag. */
export function isConsumerOwnedKey(key) {
  return key.startsWith("_") || Object.prototype.hasOwnProperty.call(CONSUMER_KEYS, key);
}

// Exported so a test can assert that every key the README table and commands/pipeline.md
// name in backticks actually resolves to a key some script reads. A documented key that
// resolves to nothing is the same defect as a configured key that is read by nothing.
export const ALL_KEYS = { ...CODE_KEYS, ...PROSE_KEYS, ...CONSUMER_KEYS };

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
    // Never suggest the one-letter namespace: every short typo is within 3 edits of "x".
    if (CONSUMER_KEYS[k]) continue;
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
    // _comment and friends are conventional; `x` is the documented project-owned object. Only
    // the `x` TYPE is checked below, never its contents.
    if (key.startsWith("_")) continue;
    const spec = ALL_KEYS[key];
    if (!spec) {
      const near = nearestKey(key);
      problems.push(
        near
          ? `"${key}" is read by nothing. Did you mean "${near}"? (${ALL_KEYS[near].type}, used by ${ALL_KEYS[near].reader}) If it is yours rather than a typo: ${CONSUMER_NAMESPACE_HINT}`
          : `"${key}" is read by nothing in this plugin. ${CONSUMER_NAMESPACE_HINT}`,
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

/**
 * AGENT FRONTMATTER LINT.
 *
 * WHY. Claude Code skips an agent file whose YAML frontmatter does not parse, and says nothing.
 * A consumer's repo-local agent carried an unquoted `: ` inside its description, which YAML
 * reads as a second mapping on the same line; the agent was simply absent from the session and
 * nothing anywhere named the file. Nothing in this plugin parsed agents/*.md either, so the
 * plugin's own nine contracts were one careless edit away from the same silence (c432ec9 fixed
 * exactly that by hand once).
 *
 * WHAT. A small, dependency-free parser for the YAML SUBSET agent frontmatter uses: top-level
 * `key: value` pairs whose values are plain, single-quoted, double-quoted, block (`|`, `>`) or
 * flow-sequence scalars, plus a one-level indented block list or map under a bare key.
 *
 * AN ERROR ONLY WHERE THE PARSER UNDERSTANDS THE WHOLE CONSTRUCT (0.43.0). A construct outside
 * that subset is valid YAML this parser does not model: a nested block deeper than one level
 * (`mcpServers:` / `gh:` / `args:` / `- run`, a `command: |` block under `hooks:`), a flow map
 * (`metadata: {a: 1}`), an anchor, alias or tag. Reporting those as "does not parse" told an owner
 * a loading agent was skipped, which is the opposite of the silence this lint exists to end and
 * just as wrong. They are recorded as NOT CHECKED instead: silent at session start, listed by
 * `config-doctor.mjs --verbose-agents`, and the key's value is not linted (a `description` the
 * parser did not read is not reported missing).
 *
 * It reports; it never edits a file and never changes the doctor's exit code.
 */
export const KNOWN_AGENT_MODELS = ["inherit", "opus", "sonnet", "haiku", "fable"];
const MODEL_ID_RE = /^claude-[a-z0-9][a-z0-9.-]*(\[1m\])?$/;
// A model alias may carry a context-window suffix, as in `opus[1m]`.
const MODEL_ALIAS_SUFFIX_RE = /^(opus|sonnet|haiku|fable)\[\d+[km]\]$/;
/** The value a key holds in parseAgentFrontmatter's data when the parser did not read it. */
export const NOT_CHECKED = Symbol.for("agent-pipeline.config-doctor.not-checked");
// Mirrors ALLOWED_EFFORTS in dispatch-effort.mjs. Restated rather than imported so this file
// does not pull a routing module into the SessionStart path; the agents suite pins the two
// lists equal, so a drift is a red row rather than a silent disagreement.
export const KNOWN_AGENT_EFFORTS = ["low", "medium", "high", "xhigh", "max"];

const DQ_ESCAPES = { "0": "\0", a: "\x07", b: "\b", t: "\t", "\t": "\t", n: "\n", v: "\v", f: "\f", r: "\r", e: "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", N: "\x85", _: "\xa0", L: " ", P: " " };

function parseDoubleQuoted(text) {
  // text starts at the opening quote. Returns {value, rest} or {error}.
  let out = "";
  for (let i = 1; i < text.length; i++) {
    const c = text[i];
    if (c === '"') return { value: out, rest: text.slice(i + 1) };
    if (c !== "\\") {
      out += c;
      continue;
    }
    const n = text[i + 1];
    if (n === undefined) return { error: "a double-quoted value ends in a lone backslash" };
    if (n === "\n") {
      i++;
      continue;
    }
    const hex = { x: 2, u: 4, U: 8 }[n];
    if (hex) {
      const digits = text.slice(i + 2, i + 2 + hex);
      if (!new RegExp(`^[0-9a-fA-F]{${hex}}$`).test(digits)) return { error: `invalid \\${n} escape in a double-quoted value` };
      out += String.fromCodePoint(parseInt(digits, 16));
      i += 1 + hex;
      continue;
    }
    if (!(n in DQ_ESCAPES)) {
      return { error: `invalid escape "\\${n}" in a double-quoted value (YAML allows only its own escapes; write "\\\\${n}" for a literal backslash)` };
    }
    out += DQ_ESCAPES[n];
    i++;
  }
  return { error: "a double-quoted value is never closed" };
}

function parseSingleQuoted(text) {
  let out = "";
  for (let i = 1; i < text.length; i++) {
    if (text[i] === "'") {
      if (text[i + 1] === "'") {
        out += "'";
        i++;
        continue;
      }
      return { value: out, rest: text.slice(i + 1) };
    }
    out += text[i];
  }
  return { error: "a single-quoted value is never closed" };
}

/** Fold a quoted scalar's physical lines the way YAML does: line breaks become spaces. */
function foldQuoted(lines) {
  return lines.map((l, i) => (i === 0 ? l.trimEnd() : l.trim())).join("\n");
}

function plainScalarProblem(value) {
  if (/^[@`]/.test(value)) return `starts with "${value[0]}", which YAML reserves; quote the value`;
  if (/^%/.test(value)) return 'starts with "%", which YAML reads as a directive; quote the value';
  if (/^[?-](\s|$)/.test(value)) return `starts with "${value[0]} ", which YAML reads as structure; quote the value`;
  if (/:(\s|$)/.test(value)) return 'contains an unquoted ": ", which YAML reads as a second key on the same line; wrap the whole value in double quotes';
  return null;
}

function typedPlain(value) {
  if (/^-?\d+$/.test(value)) return Number(value);
  if (/^(true|false)$/.test(value)) return value === "true";
  if (/^(null|~)$/.test(value)) return null;
  return value;
}

/**
 * Parse agent-file frontmatter. Never throws.
 * @returns {{present: boolean, data: object, errors: {line:number,key?:string,message:string}[],
 *            warnings: {line:number,key?:string,message:string}[]}}
 */
export function parseAgentFrontmatter(text) {
  const result = { present: false, data: {}, errors: [], warnings: [], unchecked: [] };
  const lines = String(text ?? "").replace(/^﻿/, "").replace(/\r\n?/g, "\n").split("\n");
  if (lines[0].trimEnd() !== "---") return result;
  result.present = true;
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if (/^(---|\.\.\.)\s*$/.test(lines[i])) {
      end = i;
      break;
    }
  }
  if (end < 0) {
    result.errors.push({ line: 1, message: "the frontmatter opens with --- and is never closed" });
    return result;
  }
  const body = lines.slice(1, end);
  const lineNo = (i) => i + 2;
  const err = (i, message, key) => result.errors.push({ line: lineNo(i), key, message });
  const warn = (i, message, key) => result.warnings.push({ line: lineNo(i), key, message });
  const notChecked = (i, message, key) => {
    result.unchecked.push({ line: lineNo(i), key, message });
    result.data[key] = NOT_CHECKED;
  };
  const isIndented = (l) => /^[ \t]/.test(l) && l.trim() !== "";

  for (let i = 0; i < body.length; i++) {
    const line = body[i];
    if (line.trim() === "" || /^\s*#/.test(line)) continue;
    if (/^\t/.test(line)) {
      err(i, "a tab indents this line; YAML forbids tabs for indentation");
      continue;
    }
    if (/^ /.test(line)) {
      err(i, "an indented line with no key above it to belong to");
      continue;
    }
    const m = /^([^\s:#"'][^:]*?)\s*:(?:([ \t]+)(.*)|)$/.exec(line);
    if (!m) {
      err(i, /^[^\s:]+:\S/.test(line)
        ? 'a "key:value" with no space after the colon is not a mapping in YAML; write "key: value"'
        : 'not a "key: value" line');
      continue;
    }
    const key = m[1];
    if (Object.prototype.hasOwnProperty.call(result.data, key)) err(i, `"${key}" is declared twice`, key);
    let raw = (m[3] ?? "").trim();

    // Collect the following indented (or blank-then-indented) lines as this key's continuation.
    const cont = [];
    let j = i + 1;
    while (j < body.length) {
      if (isIndented(body[j])) {
        cont.push(body[j]);
        j++;
        continue;
      }
      if (body[j].trim() === "" && j + 1 < body.length && isIndented(body[j + 1])) {
        cont.push("");
        j++;
        continue;
      }
      break;
    }
    const contStart = i + 1;
    const keyIdx = i;
    i = j - 1;

    if (raw === "" || raw.startsWith("#")) {
      if (cont.length === 0) {
        result.data[key] = null;
        continue;
      }
      const items = cont.filter((l) => l.trim() !== "" && !/^\s*#/.test(l));
      // More than one indentation under the key is a nested block (a map of maps, a list under a
      // nested key, a block scalar under a nested key). Valid YAML, outside this parser's subset.
      const indents = new Set(items.map((l) => /^[ \t]*/.exec(l)[0].length));
      if (indents.size > 1) {
        notChecked(keyIdx, `the block under "${key}" nests deeper than one level, which this lint does not parse`, key);
        continue;
      }
      const KEY_LINE = /^\s+([^\s:#][^:]*?)\s*:(?:\s+(.*)|)$/;
      if (items.every((l) => /^\s+-(\s|$)/.test(l))) {
        result.data[key] = items.map((l) => l.replace(/^\s+-\s*/, "").trim());
      } else if (items.every((l) => !KEY_LINE.test(l) && !/^\s+-(\s|$)/.test(l))) {
        // `key:` then an indented plain scalar on the next line(s): one value, checked as one.
        const bad = plainScalarProblem(items[0].trim()) || (items.some((l) => /:(\s|$)/.test(l)) ? plainScalarProblem("x: ") : null);
        if (bad) {
          err(i, `the value of "${key}" ${bad}`, key);
          continue;
        }
        result.data[key] = typedPlain(items.map((l) => l.trim()).join(" "));
      } else {
        const map = {};
        for (const l of items) {
          const mm = KEY_LINE.exec(l);
          if (!mm) {
            err(contStart + cont.indexOf(l), `a nested line under "${key}" mixes "key: value" and other lines at one indentation`, key);
            continue;
          }
          map[mm[1]] = mm[2] ?? null;
        }
        result.data[key] = map;
      }
      continue;
    }

    // A flow map, an anchor, an alias or a tag: valid YAML this parser does not model.
    if (raw.startsWith("{")) {
      notChecked(keyIdx, `the value of "${key}" is a flow mapping ({...}), which this lint does not parse`, key);
      continue;
    }
    if (/^[&*!]/.test(raw)) {
      notChecked(keyIdx, `the value of "${key}" starts with an anchor, alias or tag ("${raw[0]}"), which this lint does not parse`, key);
      continue;
    }

    if (/^[|>][+-]?[1-9]?\s*(#.*)?$/.test(raw)) {
      const folded = raw[0] === ">";
      const text = cont.map((l) => l.trim());
      result.data[key] = folded ? text.join(" ").replace(/\s+/g, " ").trim() : text.join("\n");
      continue;
    }

    if (raw.startsWith('"') || raw.startsWith("'")) {
      const whole = foldQuoted([raw, ...cont]);
      const parsed = raw.startsWith('"') ? parseDoubleQuoted(whole) : parseSingleQuoted(whole);
      if (parsed.error) {
        err(i, parsed.error, key);
        continue;
      }
      const rest = parsed.rest.trim();
      if (rest !== "" && !/^#/.test(rest) && !/^\s#/.test(parsed.rest)) {
        err(i, `text after the closing quote ("${rest.slice(0, 30)}"); quote the whole value, not part of it`, key);
        continue;
      }
      result.data[key] = parsed.value.replace(/\n/g, " ");
      continue;
    }

    if (raw.startsWith("[")) {
      const whole = [raw, ...cont.map((l) => l.trim())].join(" ");
      const close = whole.lastIndexOf("]");
      if (close < 0) {
        err(i, "a flow sequence ([...]) is never closed", key);
        continue;
      }
      result.data[key] = whole
        .slice(1, close)
        .split(",")
        .map((s) => s.trim().replace(/^["']|["']$/g, ""))
        .filter((s) => s !== "");
      continue;
    }

    // Plain scalar, possibly multi-line.
    const parts = [raw, ...cont.map((l) => l.trim()).filter((l) => l !== "")];
    // Leading-indicator rules apply to the first physical line only; ": " applies to every line.
    let bad = plainScalarProblem(raw);
    if (!bad && parts.slice(1).some((p) => /:(\s|$)/.test(p))) bad = plainScalarProblem("x: ");
    if (bad) {
      err(i, `the value of "${key}" ${bad}`, key);
      continue;
    }
    let value = parts.join(" ");
    const hash = value.search(/\s#/);
    if (hash >= 0) {
      warn(i, `the value of "${key}" contains " #", and YAML drops everything from there as a comment; quote the value to keep it`, key);
      value = value.slice(0, hash).trimEnd();
    }
    result.data[key] = typedPlain(value);
  }
  return result;
}

/** Lint one agent file's text. Returns human-readable problem strings (empty when clean). */
export function lintAgentText(text, { includeUnchecked = false } = {}) {
  const problems = [];
  const fm = parseAgentFrontmatter(text);
  if (!fm.present) {
    return ["has no frontmatter (the file must open with a --- line), so Claude Code does not load it as an agent"];
  }
  for (const e of fm.errors) {
    problems.push(`does not parse, and Claude Code skips it without a message: line ${e.line}: ${e.message}`);
  }
  for (const w of fm.warnings) problems.push(`line ${w.line}: ${w.message}`);
  if (includeUnchecked) {
    for (const u of fm.unchecked) problems.push(`not checked: line ${u.line}: ${u.message}`);
  }
  if (fm.errors.length > 0) return problems;
  const d = fm.data;
  if (d.name === NOT_CHECKED) {
    /* not read by this parser: not linted */
  } else if (typeof d.name !== "string" || d.name.trim() === "") problems.push('is missing "name", so it cannot be dispatched by name');
  else if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(d.name)) problems.push(`name "${d.name}" is not lowercase letters, digits and hyphens`);
  if (d.description !== NOT_CHECKED && (typeof d.description !== "string" || d.description.trim() === "")) {
    problems.push('is missing "description", which is what decides when the agent is chosen');
  }
  if (d.model !== undefined && d.model !== null && d.model !== NOT_CHECKED) {
    const model = String(d.model);
    if (!KNOWN_AGENT_MODELS.includes(model) && !MODEL_ALIAS_SUFFIX_RE.test(model) && !MODEL_ID_RE.test(model)) {
      problems.push(`model "${model}" is not a known value (${KNOWN_AGENT_MODELS.join(", ")}, an alias with a context suffix such as opus[1m], or a full claude-* model id)`);
    }
  }
  if (d.effort !== undefined && d.effort !== null && d.effort !== NOT_CHECKED) {
    const effort = String(d.effort);
    if (!KNOWN_AGENT_EFFORTS.includes(effort)) {
      problems.push(`effort "${effort}" is not a known value (${KNOWN_AGENT_EFFORTS.join(", ")})`);
    }
  }
  return problems;
}

function agentFiles(dir) {
  try {
    return readdirSync(dir)
      .filter((f) => f.toLowerCase().endsWith(".md") && f.toLowerCase() !== "readme.md")
      .sort()
      .map((f) => path.join(dir, f));
  } catch {
    return [];
  }
}

/**
 * Report lines for the plugin's own agents and the project's .claude/agents/*.md.
 * @param {string} projectDir
 * @param {string} [pluginRoot] defaults to this script's plugin.
 */
export function agentFrontmatterReport(projectDir, pluginRoot = path.resolve(SCRIPT_DIR, ".."), { includeUnchecked = false } = {}) {
  const lines = [];
  const sources = [
    { label: "plugin agents/", dir: path.join(pluginRoot, "agents") },
    { label: ".claude/agents/", dir: path.join(projectDir, ".claude", "agents") },
  ];
  for (const { label, dir } of sources) {
    for (const file of agentFiles(dir)) {
      let text;
      try {
        text = readFileSync(file, "utf8");
      } catch {
        continue;
      }
      for (const p of lintAgentText(text, { includeUnchecked })) lines.push(`  WARNING: agent ${label}${path.basename(file)} ${p}`);
    }
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
  // Agent frontmatter problems ride with the surface lines: reported, never a banner change.
  surface.push(...agentFrontmatterReport(projectDir, undefined, { includeUnchecked: process.argv.includes("--verbose-agents") }));
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
      const unknown = Object.keys(example).filter((k) => !isConsumerOwnedKey(k) && !ALL_KEYS[k]);
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
