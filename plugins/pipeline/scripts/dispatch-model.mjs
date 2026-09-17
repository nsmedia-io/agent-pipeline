#!/usr/bin/env node
/**
 * The dispatch model routing table, and the ONE resolver every dispatch site calls.
 *
 *   node dispatch-model.mjs <role> <risk_tier> <phase> [--site <label>] [--emit]
 *   node dispatch-model.mjs --table
 *
 * Prints AT MOST one allowlisted token on stdout. The dispatch site emits `model:` ONLY IF
 * this exited 0 AND printed exactly one token; anything else means OMIT the key entirely and
 * let the agent's own frontmatter govern. `--emit` applies that rule here: it prints
 * `model: <token>` or nothing and always exits 0, so a dispatch site pastes its stdout.
 * `--table` prints the table as it resolves under this project's config.
 *
 * IT FAILS OPEN TO FRONTMATTER, which is the OPPOSITE of the mis-tier tripwire's direction,
 * and both are deliberate. An unevaluable tripwire cannot know the diff was clean, so it
 * halts. An unevaluable model resolver has a correct answer already sitting in frontmatter,
 * so it stays out of the way. Never an empty `model:` literal, and never a fall-through to
 * the session model, which can be below opus.
 *
 * TWO ROLES ARE PINNED IN CODE AND UNREACHABLE FROM CONFIG. `secops` and `qa` emit NO model
 * key at all: the resolver prints nothing, reports the pin on stderr, and exits 0. The
 * reason is failure SHAPE, not seniority. A cheap detection lens that misses returns APPROVE
 * and nothing escalates, so those two are the roles whose model is a security control, and a
 * resolver that RESOLVED them would sit inside that trust path (any defect returning a
 * different allowlisted token would override frontmatter, and the omit-on-failure backstop
 * only helps when the key is ABSENT). Emitting nothing collapses the class and leaves exactly
 * one way to lower them: editing agents/secops.md or agents/qa.md.
 *
 * A `dispatchModels` key names a ROLE and therefore carries ONE value, so it cannot address a
 * (role, phase) that carries two sites with different models. It is REFUSED there and
 * reported, never applied to both: flattening (dev, 2.5) would lower the opus-pinned bake-off
 * judge from a config edit that reads as tuning. Move a specific site by editing the table.
 *
 * # CUSTOMIZE: set `dispatchModels` in pipeline.config.json to override a NON-pinned role,
 * e.g. { "dispatchModels": { "design_review": "opus" } }. Values are allowlisted to the
 * floating aliases below; a full model ID is rejected and reported.
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * The allowlist is over the RESOLVED value, not a rank table over three spellings: the
 * harness resolves these aliases itself, so anything else is a value that gets transformed
 * before it acts, and a full pinned model ID is exactly that.
 */
export const ALLOWED_MODELS = ["opus", "sonnet", "haiku"];

/** Config cannot reach these. Not a ceiling and not a floor: a pin, on two roles. */
export const PINNED_ROLES = { secops: "opus", qa: "opus" };

export const KNOWN_ROLES = [
  "ba",
  "dba",
  "devops",
  "secops",
  "dev",
  "qa",
  "design_review",
  "art_director",
  "librarian",
];

const ROLE_ALIASES = {
  designreview: "design_review",
  design: "design_review",
  artdirector: "art_director",
};

export const KNOWN_TIERS = ["trivial", "standard", "architectural"];
export const KNOWN_PHASES = ["0", "0.5", "1", "2", "2.5", "3", "3a", "3b", "4", "5"];

/**
 * The DEFAULT table reproduces today's assignment at every pin site, so adding the table is
 * behavior-neutral. Haiku appears nowhere here; it is reachable only through config.
 *
 * `site` is a fourth dimension, and it exists because (dev, 2.5) is TWO dispatches with
 * DIFFERENT models: the two design sketches (sonnet) and the bake-off judge (opus) are both
 * `subagent_type: "dev"` in Phase 2.5. A resolver keyed on (role, tier, phase) alone cannot
 * return two values for one key, and changing either site's model to dissolve the collision
 * would break the behaviour-neutrality this table exists to preserve.
 */
export const DEFAULT_TABLE = [
  { role: "ba", phase: "0.5", site: "map", model: "sonnet", siteDefault: true },
  { role: "ba", phase: "4", site: "panel-lens", model: "sonnet", siteDefault: true },
  { role: "dev", phase: "4", site: "panel-lens", model: "sonnet", siteDefault: true },
  { role: "dev", phase: "2.5", site: "design-sketch", model: "sonnet", siteDefault: true },
  { role: "dev", phase: "2.5", site: "bakeoff-judge", model: "opus" },
  // TIERED rows (0.40.0): a `tier` key matches only that tier; the frontmatter opus applies at
  // architectural, where DBA has already reviewed the spec and the diff is the one that can
  // carry a migration. On a standard or trivial panel the data-layer re-read is a sonnet job.
  { role: "dba", phase: "4", tier: "standard", site: "panel-lens", model: "sonnet", siteDefault: true },
  { role: "dba", phase: "4", tier: "trivial", site: "panel-lens", model: "sonnet", siteDefault: true },
];

/** One normalizer, one call path. 'SecOps', 'sec-ops' and 'sec_ops' are the same role. */
export function normalizeRole(raw) {
  if (typeof raw !== "string") return null;
  const key = raw.toLowerCase().replace(/[^a-z0-9]/g, "");
  const canonical = ROLE_ALIASES[key] || KNOWN_ROLES.find((r) => r.replace(/_/g, "") === key);
  return canonical || null;
}

function projectRoot() {
  return process.env.CLAUDE_PROJECT_DIR || process.cwd();
}

function readConfig() {
  const file = path.join(projectRoot(), "pipeline.config.json");
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
 * Config role->model, normalized and allowlisted, with every rejection reported.
 * `reports` is an out-parameter: a fail-soft that says nothing is how a config typo becomes
 * permanent.
 */
export function configModels(cfg, reports) {
  const raw = cfg && cfg.dispatchModels;
  const out = {};
  if (raw === undefined) return out;
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    reports.push("dispatchModels is not an object; the built-in default table applies.");
    return out;
  }
  for (const [key, value] of Object.entries(raw)) {
    const role = normalizeRole(key);
    if (!role) {
      reports.push(`dispatchModels: "${key}" is not a role this pipeline dispatches; ignored.`);
      continue;
    }
    if (PINNED_ROLES[role]) {
      reports.push(
        `dispatchModels: "${key}" resolves to the pinned role ${role}; IGNORED. ${role} carries no model override at any tier, so its frontmatter governs.`,
      );
      continue;
    }
    if (typeof value !== "string" || !ALLOWED_MODELS.includes(value)) {
      reports.push(
        `dispatchModels.${key}: ${JSON.stringify(value)} is not one of ${ALLOWED_MODELS.join("/")}; REJECTED, the built-in default applies.`,
      );
      continue;
    }
    out[role] = value;
  }
  return out;
}

// A row with a `tier` matches only that tier; a row without one matches every tier. Tiered rows
// win outright when both exist, so neither kind can shadow the other by accident.
function rowsFor(role, phase, tier) {
  const all = DEFAULT_TABLE.filter((r) => r.role === role && r.phase === phase);
  const tiered = all.filter((r) => r.tier !== undefined && r.tier === tier);
  return tiered.length > 0 ? tiered : all.filter((r) => r.tier === undefined);
}

/** The dispatch-log label for a table row, or for no row at all. */
export function rowRule(row) {
  if (!row) return "no-row:frontmatter";
  return `table:${row.role}/${row.phase}${row.tier ? `/${row.tier}` : ""}/${row.site}`;
}

/**
 * @returns {{model: string|null, reports: string[], error: string|null, rule: string}}
 * `model: null` with no error means "no override for this dispatch": omit the key.
 * `rule` names WHICH rule chose the outcome, for the dispatch log (#163): `pinned:<role>`,
 * `config:dispatchModels.<role>`, `table:<role>/<phase>[/<tier>]/<site>`, `no-row:frontmatter`,
 * or `error`. It is a label over the decision already made, never an input to it.
 */
export function resolve({ role: rawRole, tier, phase, site, cfg }) {
  const reports = [];
  const role = normalizeRole(rawRole);
  if (!role) {
    return { model: null, reports, error: `unknown role "${rawRole}"`, rule: "error" };
  }
  // PINNED is consulted here, before any config is read, so no config value can influence the
  // outcome. The config is read AFTERWARDS for REPORTING only.
  if (PINNED_ROLES[role]) {
    const config = cfg || readConfig();
    const pinReports = [];
    configModels(config, pinReports);
    return {
      model: null,
      pinned: role,
      reports: [
        `pinned: frontmatter governs for ${role} (no model key is emitted at any tier or phase)`,
        ...pinReports.filter((r) => r.includes(role)),
      ],
      error: null,
      rule: `pinned:${role}`,
    };
  }
  if (!KNOWN_TIERS.includes(tier)) {
    return { model: null, reports, error: `malformed risk_tier "${tier}"`, rule: "error" };
  }
  if (!KNOWN_PHASES.includes(phase)) {
    return { model: null, reports, error: `malformed phase "${phase}"`, rule: "error" };
  }

  const config = cfg || readConfig();
  const overrides = configModels(config, reports);

  const rows = rowsFor(role, phase, tier);
  let row = null;
  if (site) {
    row = rows.find((r) => r.site === site) || null;
    if (!row && rows.length > 0) {
      reports.push(`no table row for site "${site}"; using the default row for ${role}/${phase}.`);
    }
  }
  if (!row) {
    if (rows.length > 1) {
      reports.push(
        `${role}/${phase} carries ${rows.length} dispatch sites (${rows.map((r) => r.site).join(", ")}); no --site was passed, so the default row applies.`,
      );
    }
    row = rows.find((r) => r.siteDefault) || rows[0] || null;
  }

  // A `dispatchModels` key names a ROLE, so it carries one value, but a (role, phase) can be
  // TWO dispatches whose models differ on purpose: (dev, 2.5) is the two design sketches
  // (sonnet) and the bake-off judge (opus). Applied after row selection, a role-level override
  // returns the same token for both and silently flattens the distinction this table's `site`
  // dimension exists to hold -- on the opus-pinned synthesis step, quietly, from a config edit
  // that reads as tuning. It is REFUSED there and reported, rather than honoured for a site it
  // cannot name. Everywhere the (role, phase) is unambiguous the override applies as before.
  if (overrides[role]) {
    const distinctModels = new Set(rows.map((r) => r.model));
    if (rows.length > 1 && distinctModels.size > 1) {
      reports.push(
        `dispatchModels.${role}: ${role}/${phase} carries ${rows.length} dispatch sites with DIFFERENT models (${rows.map((r) => `${r.site}=${r.model}`).join(", ")}); a role-level key cannot name one of them, so the override is IGNORED for this phase and the table applies. Change the table in this file to move a specific site.`,
      );
    } else {
      return { model: overrides[role], reports, error: null, rule: `config:dispatchModels.${role}` };
    }
  }
  return { model: row ? row.model : null, reports, error: null, rule: rowRule(row) };
}

/** A role's frontmatter `model:`, read from the shipped agents/ file, or "?" when unreadable. */
export function frontmatterModel(role) {
  const file = { design_review: "design.md", art_director: "art-director.md" }[role] || `${role}.md`;
  try {
    const text = readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "agents", file), "utf8");
    const m = /^model:\s*(\S+)\s*$/m.exec(text.split(/^---\s*$/m)[1] || "");
    return m ? m[1] : "?";
  } catch {
    return "?";
  }
}

/**
 * The routing table as it RESOLVES for this project (#164 row 25): every table row, config
 * applied, then one line per role for every phase no row names. Prose cites this instead of
 * restating a model, so no copy of a model assignment exists outside this file.
 */
export function renderTable(cfg) {
  const lines = [["role", "phase", "tier", "site", "emits", "frontmatter", "rule"]];
  const emits = (r) => (r.error ? "error" : r.model || "(no key)");
  for (const row of DEFAULT_TABLE) {
    const tiers = row.tier ? [row.tier] : KNOWN_TIERS;
    const results = tiers.map((tier) => resolve({ role: row.role, tier, phase: row.phase, site: row.site, cfg }));
    const same = results.every((r) => emits(r) === emits(results[0]) && r.rule === results[0].rule);
    const shown = same ? [[row.tier || "any", results[0]]] : tiers.map((t, i) => [t, results[i]]);
    for (const [tier, r] of shown) {
      lines.push([row.role, row.phase, tier, row.site, emits(r), frontmatterModel(row.role), r.rule]);
    }
    // A (role, phase) carried only by tiered rows falls to frontmatter at every other tier.
    const peers = DEFAULT_TABLE.filter((r) => r.role === row.role && r.phase === row.phase);
    if (row === peers[peers.length - 1] && peers.every((r) => r.tier)) {
      for (const tier of KNOWN_TIERS.filter((t) => !peers.some((r) => r.tier === t))) {
        const r = resolve({ role: row.role, tier, phase: row.phase, cfg });
        lines.push([row.role, row.phase, tier, "-", emits(r), frontmatterModel(row.role), r.rule]);
      }
    }
  }
  for (const role of KNOWN_ROLES) {
    const rowed = new Set(DEFAULT_TABLE.filter((r) => r.role === role).map((r) => r.phase));
    const phase = KNOWN_PHASES.find((p) => !rowed.has(p));
    const r = resolve({ role, tier: "standard", phase, cfg });
    lines.push([role, rowed.size ? "other" : "any", "any", "-", emits(r), frontmatterModel(role), r.rule]);
  }
  const widths = lines[0].map((_, i) => Math.max(...lines.map((l) => l[i].length)));
  return lines.map((l) => l.map((c, i) => c.padEnd(widths[i])).join("  ").trimEnd()).join("\n") + "\n";
}

function main(argv) {
  const positional = [];
  let site = null;
  let emit = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--site") {
      site = argv[i + 1];
      i++;
    } else if (argv[i] === "--emit") {
      emit = true;
    } else if (argv[i] === "--table") {
      process.stdout.write(renderTable(readConfig()));
      return 0;
    } else {
      positional.push(argv[i]);
    }
  }
  const [role, tier, phase] = positional;
  const { model, reports, error } = resolve({ role, tier, phase, site });
  for (const r of reports) process.stderr.write(`dispatch-model: ${r}\n`);
  if (error) {
    process.stderr.write(
      `dispatch-model: ${error}. This is a DISPATCH-SITE bug, not a project-config problem: no model key is emitted, and the row is NEVER silently resolved against a different one.\n`,
    );
    // --emit (#164 row 28) ALWAYS exits 0: its stdout is the whole contract, a `model: X` line
    // or nothing, so a dispatch site pastes what it prints and never evaluates an exit status.
    return emit ? 0 : 2;
  }
  if (emit) {
    if (model) process.stdout.write(`model: ${model}\n`);
    else process.stderr.write("dispatch-model: no override for this dispatch; frontmatter governs\n");
    return 0;
  }
  if (model) process.stdout.write(`${model}\n`);
  else process.stderr.write("dispatch-model: no override for this dispatch; frontmatter governs\n");
  return 0;
}

if (process.argv[1] && process.argv[1].endsWith("dispatch-model.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
