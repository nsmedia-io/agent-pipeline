#!/usr/bin/env node
/**
 * The dispatch EFFORT routing table, and the ONE resolver every dispatch site calls.
 *
 *   node dispatch-effort.mjs <role> <risk_tier> <phase> [--site <label>] [--surface <agent|workflow>]
 *
 * Sibling of dispatch-model.mjs and deliberately shaped like it: same argv conventions, same
 * fail-open-to-frontmatter direction, same "print at most one allowlisted token" contract.
 * Read that file's header first; only the differences are argued here.
 *
 * ## THE DIFFERENCE THAT GOVERNS THIS FILE: EFFORT HAS NO PER-DISPATCH SURFACE ON THE AGENT TOOL
 *
 * `model` is a parameter of the Agent tool, so dispatch-model.mjs can resolve a value and the
 * dispatch site emits `model: <token>` into the call. THERE IS NO `effort` PARAMETER ON THE
 * AGENT TOOL. Its parameters are description, isolation, model, prompt, run_in_background and
 * subagent_type, and that is the whole list. Effort is settable per SESSION (`/effort`,
 * `--effort`, CLAUDE_CODE_EFFORT_LEVEL, settings `effortLevel`, `modelSettings.<model>`) and
 * per ROLE (`effort:` in agents/<role>.md frontmatter, which DOES work: anthropics/claude-code
 * #64706 closed COMPLETED after a maintainer re-test showed pinned low vs xhigh agents emitting
 * 0 vs 332 thinking tokens on an identical task; the "frontmatter is ignored" reports earlier in
 * that thread were a status-bar/transcript DISPLAY defect fixed in 2.1.149 and 2.1.222). It is
 * NOT settable per DISPATCH. There is no CLAUDE_CODE_SUBAGENT_EFFORT to match
 * CLAUDE_CODE_SUBAGENT_MODEL.
 *
 * The only per-dispatch effort surface in Claude Code today is the Workflow tool's
 * `agent(prompt, { effort })`. anthropics/claude-code#64033 is the vendor-side request to widen
 * that; it is closed, not shipped for the Agent tool.
 *
 * SO THIS RESOLVER IS SURFACE-AWARE, AND THAT IS THE POINT, NOT A WART. `--surface agent` (the
 * default, because it is what the pipeline dispatches through today) prints NOTHING and reports
 * that frontmatter governs. It does not print the table's value and let a caller pretend it was
 * applied. A table that silently claimed a standard-tier SecOps ran at `high` while the Agent
 * tool actually ran it at frontmatter `xhigh` would be a routing table that lies about the
 * routing, which is worse than no table: every reader downstream, including a cost model and an
 * incident review, would be reasoning off a value nothing ever sent.
 *
 * ## WHAT CONSUMES THIS TODAY
 *
 * Two things, one of them live now:
 *
 *   1. LIVE: the frontmatter conformance check. `agentSurfaceBaseline(role)` is the effort each
 *      role's frontmatter MUST declare, and tests/test-dispatch-effort-resolver.sh asserts the
 *      two agree file by file. That makes this table the single written-down source for "what
 *      effort does each role run at", and makes silent drift in an agents/*.md frontmatter a
 *      red test rather than a discovery months later.
 *   2. PENDING: `--surface workflow`, for a Phase 4 panel dispatched through the Workflow tool.
 *      That migration is NOT proposed here and is blocked on #101 q4/q6 (whether a
 *      Workflow-dispatched SecOps VETO stays fail-CLOSED). This file does not decide that and
 *      must not be read as having decided it.
 *
 * ## THE WORKFLOW SURFACE ALWAYS EMITS, BECAUSE OMISSION'S MEANING IS CONTESTED (#101 q3)
 *
 * A sparse table is only safe if "no row" has a known fallback. Here it does not. The Workflow
 * tool's documentation says omitting `opts.effort` inherits the SESSION effort; #98's live spike
 * observed it inheriting the AGENT'S OWN FRONTMATTER effort instead, and recorded the
 * contradiction. Those two readings differ in the direction that matters: a session running at
 * `low` would, under the documented reading, silently dispatch every unrowed role at `low`.
 *
 * So on the workflow surface this resolver ALWAYS emits a concrete token, including for a role
 * with no table row, where it emits that role's frontmatter value explicitly. Nothing here rests
 * on omission meaning what #98 observed rather than what the vendor documents. That answers q3
 * without needing the contradiction resolved first: emit, and the question stops mattering.
 *
 * ## PINS RETIRED IN 0.40.0 (the section below is kept as the record of why they existed)
 *
 * SecOps and QA are no longer pinned for effort. The Phase 4 rows are TIERED instead (SecOps
 * xhigh/high/medium, QA high/medium/medium by risk tier; DBA, DevOps and Design medium below
 * architectural) and `dispatchEfforts` can reach every role in both directions. The risk the pin
 * carried -- a mis-tiered change looks benign -- now sits in the materiality rule
 * (materiality.mjs) and the concrete security triggers in agents/ba.md duty 6, and the archive's
 * Phase 4 time was what the pin cost. The model pins in dispatch-model.mjs are unchanged. What
 * survives from the ruling below is the shape: rows are LOOKED UP, never clamped, and there is
 * still no rank comparison in this file.
 *
 * ## PINS, NOT FLOORS (SecOps ruled on this; see #101 q2; superseded above)
 *
 * An earlier draft of this file gave secops and qa a per-tier FLOOR that config could raise but
 * never lower. SecOps reviewed it and REFUSED that shape, and the argument is kept here because
 * it is the reason the simpler code is the safer code: a one-way clamp needs a rank order over
 * five levels, and a rank order is CODE INSIDE THE VETO TRUST PATH. Its most likely defect
 * lowers silently -- an accidental string comparison mis-ranks, since "max" < "medium"
 * lexicographically -- and dispatch-model.mjs's own backstop reasoning applies unchanged: an
 * omit-on-failure fallback only helps when the key is ABSENT, so a clamp that emits a WRONG
 * ALLOWLISTED level overrides frontmatter and the run returns APPROVE with a shallower lens than
 * anyone asked for. The clamp also bought nothing unreachable: a project that wants SecOps at
 * `max` edits agents/secops.md, which is the same single lowering path the model pin already
 * leaves. One pattern to audit, not two. So secops and qa are PINNED exactly as they are in
 * dispatch-model.mjs, there is no rank comparison anywhere in this file, and `dispatchEfforts`
 * cannot reach either role at any tier, phase or surface.
 *
 * SecOps also ruled the TIER argument the other way round from the original ask, which proposed
 * xhigh "only where it is earned" at architectural tier. Detection redundancy is LOWEST at the
 * low tiers, not highest: at architectural tier SecOps reviews twice (Phase 2 spec, Phase 4
 * diff), while at trivial and standard there is no Phase 2 SecOps review at all and the Phase 4
 * panel is the ONLY security look at the diff. And the tier is BA's ESTIMATE of the stakes,
 * which is the one input SecOps is specifically tasked to distrust; a mis-tiered change is by
 * construction one that LOOKS benign, so a shallow pass over a diff labelled harmless is exactly
 * the case where depth pays. SecOps therefore holds xhigh at every tier. The one measurement
 * that could move it is recorded in #101, not asserted here: same diff at high vs xhigh, n>1,
 * counting turns and distinct Bash invocations, since effort and maxTurns spend the same budget.
 *
 * # CUSTOMIZE: set `dispatchEfforts` in pipeline.config.json for a NON-pinned role, e.g.
 * { "dispatchEfforts": { "librarian": "high" } }. Values are allowlisted below.
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { isMain } from "./lib.mjs";

/** The vendor's effort vocabulary. Anything else is a value that never reaches inference. */
export const ALLOWED_EFFORTS = ["low", "medium", "high", "xhigh", "max"];

/**
 * EMPTY since 0.40.0. SecOps and QA were pinned here (xhigh / high at every tier) on the #101
 * q2 ruling that a mis-tiered change looks benign. The materiality rule (materiality.mjs) and
 * the concrete security triggers in agents/ba.md duty 6 now carry that risk at the verdict and
 * at intake, and the archive's Phase 4 time was the cost of carrying it as effort instead. The
 * two roles now have TIERED rows below, and config can reach them like any other role. The
 * constant stays exported, empty, so a downstream reader keyed on it sees the change rather
 * than a missing export; and there is still deliberately NO rank table and no comparison
 * anywhere in this file (see the header): rows are looked up, never clamped.
 */
export const PINNED_ROLES = {};

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
 * The dispatch surfaces this resolver knows, and what each can actually carry.
 * `agent` is the default because it is what commands/pipeline.md dispatches through today.
 */
export const KNOWN_SURFACES = ["agent", "workflow"];

/**
 * What each role's agents/<role>.md frontmatter declares. This is the AGENT-SURFACE TRUTH: on
 * the Agent tool these are the values that actually reach inference, whatever any table says.
 * tests/test-dispatch-effort-resolver.sh reads the frontmatter and asserts it matches, so this
 * map cannot drift from the files without a red test.
 */
export const FRONTMATTER_EFFORT = {
  ba: "high",
  dba: "high",
  devops: "high",
  secops: "xhigh",
  dev: "high",
  qa: "high",
  design_review: "high",
  art_director: "high",
  librarian: "medium",
};

/**
 * Deviations from frontmatter, for the WORKFLOW surface only.
 *
 * Disambiguated by `site` exactly as dispatch-model.mjs is, for the same reason: (dev, 2.5) is
 * TWO dispatches (the sketches and the bake-off judge) that must not collapse to one value. Rows
 * here name the MECHANICAL sites, the ones already routed to sonnet in dispatch-model.mjs on the
 * same "not deep reasoning" argument. No row names a pinned role.
 *
 * A role/phase with no row falls back to that role's frontmatter value, which the workflow
 * surface then emits EXPLICITLY rather than omitting; see the omission note in the header.
 */
export const DEFAULT_TABLE = [
  { role: "ba", phase: "0.5", site: "map", effort: "medium", siteDefault: true },
  { role: "ba", phase: "4", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "dev", phase: "4", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "dev", phase: "2.5", site: "design-sketch", effort: "medium", siteDefault: true },
  { role: "dev", phase: "2.5", site: "bakeoff-judge", effort: "high" },
  // TIERED Phase 4 panel rows (0.40.0). A row with a `tier` matches only that tier; a role's
  // frontmatter still applies at any tier with no row (architectural, for these). The depth a
  // reviewer spends on a diff now follows the tier BA set, which the materiality rule and the
  // concrete security triggers make trustworthy enough to spend against.
  { role: "secops", phase: "4", tier: "architectural", site: "panel-lens", effort: "xhigh", siteDefault: true },
  { role: "secops", phase: "4", tier: "standard", site: "panel-lens", effort: "high", siteDefault: true },
  { role: "secops", phase: "4", tier: "trivial", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "qa", phase: "4", tier: "standard", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "qa", phase: "4", tier: "trivial", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "dba", phase: "4", tier: "standard", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "dba", phase: "4", tier: "trivial", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "devops", phase: "4", tier: "standard", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "devops", phase: "4", tier: "trivial", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "design_review", phase: "4", tier: "standard", site: "panel-lens", effort: "medium", siteDefault: true },
  { role: "design_review", phase: "4", tier: "trivial", site: "panel-lens", effort: "medium", siteDefault: true },
];

/** One normalizer, one call path. Shared shape with dispatch-model.mjs on purpose. */
export function normalizeRole(raw) {
  if (typeof raw !== "string") return null;
  const key = raw.toLowerCase().replace(/[^a-z0-9]/g, "");
  const canonical = ROLE_ALIASES[key] || KNOWN_ROLES.find((r) => r.replace(/_/g, "") === key);
  return canonical || null;
}

/** The effort a role's frontmatter must declare. The live consumer named in the header. */
export function agentSurfaceBaseline(role) {
  const canonical = normalizeRole(role);
  return canonical ? (FRONTMATTER_EFFORT[canonical] ?? null) : null;
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
 * Config role->effort, normalized and allowlisted, with every rejection reported.
 * `reports` is an out-parameter: a fail-soft that says nothing is how a config typo becomes
 * permanent. Floors are NOT applied here; this returns what config ASKED for, and resolve()
 * decides whether the ask is honoured, so the refusal can name both values.
 */
export function configEfforts(cfg, reports) {
  const raw = cfg && cfg.dispatchEfforts;
  const out = {};
  if (raw === undefined) return out;
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    reports.push("dispatchEfforts is not an object; the built-in default table applies.");
    return out;
  }
  for (const [key, value] of Object.entries(raw)) {
    const role = normalizeRole(key);
    if (!role) {
      reports.push(`dispatchEfforts: "${key}" is not a role this pipeline dispatches; ignored.`);
      continue;
    }
    if (PINNED_ROLES[role]) {
      reports.push(
        `dispatchEfforts: "${key}" resolves to the pinned role ${role}; IGNORED. ${role} carries no effort override at any tier, phase or surface, so its frontmatter governs.`,
      );
      continue;
    }
    if (typeof value !== "string" || !ALLOWED_EFFORTS.includes(value)) {
      reports.push(
        `dispatchEfforts.${key}: ${JSON.stringify(value)} is not one of ${ALLOWED_EFFORTS.join("/")}; REJECTED, the built-in default applies.`,
      );
      continue;
    }
    out[role] = value;
  }
  return out;
}

// A row with a `tier` matches only that tier; a row without one matches every tier. When both
// kinds exist for a (role, phase), the tier-specific rows win outright, so a generic row can
// never shadow a tiered one and a tiered one never leaks into another tier.
function rowsFor(role, phase, tier) {
  const all = DEFAULT_TABLE.filter((r) => r.role === role && r.phase === phase);
  const tiered = all.filter((r) => r.tier !== undefined && r.tier === tier);
  return tiered.length > 0 ? tiered : all.filter((r) => r.tier === undefined);
}

/**
 * @returns {{effort: string|null, reports: string[], error: string|null, surface?: string}}
 * `effort: null` with no error means "emit no effort for this dispatch": frontmatter governs.
 */
export function resolve({ role: rawRole, tier, phase, site, surface, cfg }) {
  const reports = [];
  const role = normalizeRole(rawRole);
  if (!role) {
    return { effort: null, reports, error: `unknown role "${rawRole}"` };
  }
  if (!KNOWN_TIERS.includes(tier)) {
    return { effort: null, reports, error: `malformed risk_tier "${tier}"` };
  }
  if (!KNOWN_PHASES.includes(phase)) {
    return { effort: null, reports, error: `malformed phase "${phase}"` };
  }
  const surf = surface === undefined || surface === null ? "agent" : surface;
  if (!KNOWN_SURFACES.includes(surf)) {
    return { effort: null, reports, error: `unknown surface "${surface}"` };
  }

  const config = cfg || readConfig();
  const overrides = configEfforts(config, reports);

  // PINNED is consulted before the table, and the pinned CONSTANT is what a pinned role emits:
  // the table is never indexed for it, so no table edit can move it either. configEfforts has
  // already dropped any config entry naming it, so `overrides` cannot contain it; the config was
  // read above only so that dropping can be REPORTED. On the workflow surface the pin is emitted
  // EXPLICITLY rather than omitted, for the reason in the header: omitting would fall back to a
  // value the vendor doc and #98 disagree about, and one of those two readings is the session's
  // effort, which can be below the pin. That is the silent-downgrade this pin exists to prevent.
  if (PINNED_ROLES[role]) {
    const pin = PINNED_ROLES[role];
    return {
      effort: surf === "agent" ? null : pin,
      surface: surf,
      pinned: role,
      reports: [
        surf === "agent"
          ? `pinned: frontmatter governs for ${role} (the Agent tool carries no effort parameter, and agents/${role}.md declares ${FRONTMATTER_EFFORT[role]})`
          : `pinned: ${role} emits its pinned ${pin} explicitly at every tier and phase; no table row and no config entry can move it`,
        ...reports.filter((r) => r.includes(role)),
      ],
      error: null,
    };
  }

  // THE AGENT SURFACE CARRIES NO EFFORT, SO NOTHING IS EMITTED FOR IT. Checked before the table
  // is consulted, so no table row and no config value can produce a token a caller might emit
  // into a call that has nowhere to put it. Reported, not silent, because "why did my
  // dispatchEfforts entry do nothing" must be answerable from the dispatch's own stderr.
  if (surf === "agent") {
    const baseline = FRONTMATTER_EFFORT[role] ?? "(none declared)";
    return {
      effort: null,
      surface: surf,
      reports: [
        `the Agent tool exposes no effort parameter, so no effort is emitted for ${role}; agents/${role}.md frontmatter governs and declares ${baseline}`,
        ...reports,
      ],
      error: null,
    };
  }

  // --- workflow surface: a per-call effort genuinely exists, so resolve one. ---
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

  // No row is NOT an omission: the frontmatter value is emitted explicitly, because omission's
  // meaning is contested between the vendor doc (session effort) and #98's observation
  // (frontmatter effort). See the header. This is why `chosen` is never left null here.
  let chosen = row ? row.effort : (FRONTMATTER_EFFORT[role] ?? null);

  // A role-level key cannot name one of two sites whose efforts differ on purpose, so it is
  // refused there exactly as dispatchModels is, rather than flattening both. Pinned roles never
  // reach this line: configEfforts already dropped them.
  if (overrides[role]) {
    const distinct = new Set(rows.map((r) => r.effort));
    if (rows.length > 1 && distinct.size > 1) {
      reports.push(
        `dispatchEfforts.${role}: ${role}/${phase} carries ${rows.length} dispatch sites with DIFFERENT efforts (${rows.map((r) => `${r.site}=${r.effort}`).join(", ")}); a role-level key cannot name one of them, so the override is IGNORED for this phase and the table applies. Change the table in this file to move a specific site.`,
      );
    } else {
      chosen = overrides[role];
    }
  }

  return { effort: chosen, surface: surf, reports, error: null };
}

function main(argv) {
  const positional = [];
  let site = null;
  let surface = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--site") {
      site = argv[i + 1];
      i++;
    } else if (argv[i] === "--surface") {
      surface = argv[i + 1];
      i++;
    } else {
      positional.push(argv[i]);
    }
  }
  const [role, tier, phase] = positional;
  const { effort, reports, error } = resolve({ role, tier, phase, site, surface });
  for (const r of reports) process.stderr.write(`dispatch-effort: ${r}\n`);
  if (error) {
    process.stderr.write(
      `dispatch-effort: ${error}. This is a DISPATCH-SITE bug, not a project-config problem: no effort is emitted, and the row is NEVER silently resolved against a different one.\n`,
    );
    return 2;
  }
  if (effort) process.stdout.write(`${effort}\n`);
  else
    process.stderr.write("dispatch-effort: no effort emitted for this dispatch; frontmatter governs\n");
  return 0;
}

if (isMain("dispatch-effort.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
