#!/usr/bin/env node
/**
 * panel-roles.mjs -- who sits on the Phase 4 panel, as code rather than prose (#164 rows 1 and 3).
 *
 *   node panel-roles.mjs full  --status <status.json> --worktree <path> --artifact-dir <dir>
 *                              [--base origin/main] [--cost-class <c>] [--write]
 *   node panel-roles.mjs delta --status <status.json> --worktree <path> --first-round-head <sha>
 *                              --peer-review <peer-review.json> [--cost-class <c>] [--write]
 *
 * OUTPUT. The resolved roles on stdout, ONE PER LINE, in dispatch order. `PANEL-NOTE:` lines and
 * `SURFACE-INDETERMINATE:` diagnostics on stderr.
 *
 * EXIT CODES.
 *   0   roles resolved, every seat earned by the tier, a match, an open blocker or the tooling rule.
 *   21  roles resolved, and at least one role printed was SEATED ON AN UNEVALUABLE PROBE (git diff
 *       failed, the path list was empty, a predicate threw, or peer-review.json was unreadable).
 *       Dispatch the printed roles; the PANEL-NOTE lines say which seat is which, and belong in
 *       status.json flags (--write records them) and in the PR summary.
 *   1   bad input: a missing or unknown argument, an unreadable status.json, a risk_tier that is
 *       absent or unknown (full), panel_roles absent or empty (delta), an unknown --cost-class.
 *   2   an unexpected internal error.
 *   Any other code (node's own 1-14 band, 127 for a missing node) is a failure to run. The
 *   caller halts on everything that is not 0 or 21 and never reads stdout from it.
 *
 * WHY 21. Node reserves 1 through 14 for itself and the shell owns 126, 127 and 128+n, so a code
 * the caller acts on as "roles are good" must sit outside both bands. The old shell probe used 20
 * for "no match"; 21 is a different meaning and deliberately a different number.
 *
 * THE FAIL DIRECTION. An unevaluable surface check cannot know the diff misses the surface, so it
 * SEATS the role and says so; over-seating costs one reviewer's context, under-seating removes the
 * lens the diff needed. A missing sibling module is a load failure of this script and halts.
 *
 * WHAT THIS REPLACES. Two copies of a `surface_probe` shell function in orchestrator prose, whose
 * `$1` was exposed to slash-command template substitution, and role lists held in unquoted shell
 * strings that zsh does not word-split. Here git runs without a shell, the paths never pass
 * through a variable, and the roles leave as lines.
 *
 * SEATING RULES.
 *   full:  architectural  ba dba devops secops dev qa
 *          standard       ba dev qa secops, plus dba on the data layer, devops on infra
 *          trivial        qa secops
 *          every tier     plus design_review on a frontend surface, plus art_director when
 *                         <artifact-dir>/visual-contract.json exists
 *          cost_class tooling, any tier: qa secops plus ONE specialist, the first of devops (infra),
 *                         dba (data layer), design_review (frontend) whose probe seats it, else
 *                         dev. That replaces the tier panel, art_director included.
 *   delta: seed with openBlockerRoles(peer-review.json) (the FULL panel_roles when that file is
 *          unreadable), then dba on the data layer, secops on a security path and (except at
 *          tooling) on the data layer, qa on a test file, devops on infra except at tooling.
 *          Design re-sits only while it holds an open blocker. panel_roles is never changed.
 *
 * --write. full: sets status.json panel_roles to the printed roles. Both: appends each PANEL-NOTE
 * as a flags[] entry ({phase: "4-review", agent: "panel-roles", summary, at}) unless an identical
 * summary is already there. No absolute path reaches status.json; diagnostics stay on stderr.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { isMain, nativePath } from "./lib.mjs";
import { COST_CLASSES, normCostClass, openBlockerRoles } from "./materiality.mjs";
import { diffTouchesDataLayer, diffTouchesInfra } from "./data-layer-surface.mjs";
import { diffTouchesSecuritySurface, diffTouchesTests } from "./security-surface.mjs";
import { diffTouchesFrontend } from "./frontend-surface.mjs";

export const EXIT_OK = 0;
export const EXIT_BAD_INPUT = 1;
export const EXIT_SEATED_ON_INDETERMINATE = 21;

export const TIER_PANELS = {
  architectural: ["ba", "dba", "devops", "secops", "dev", "qa"],
  standard: ["ba", "dev", "qa", "secops"],
  trivial: ["qa", "secops"],
};

/** Order the tooling rule takes its one specialist in. */
export const TOOLING_SPECIALIST_ORDER = ["devops", "dba", "design_review"];

const FLAG_SUMMARY_MAX = 140;

export class BadInput extends Error {}

/** One probe: "match" | "no-match" | "indeterminate". Never throws. */
export function probe(predicate, paths, label, diag) {
  if (paths === null) return "indeterminate";
  if (paths.length === 0) {
    diag(`SURFACE-INDETERMINATE: ${label}: empty path list: an unread diff is not a clean diff`);
    return "indeterminate";
  }
  try {
    return predicate(paths) ? "match" : "no-match";
  } catch (e) {
    diag(`SURFACE-INDETERMINATE: ${label}: ${e && e.message}`);
    return "indeterminate";
  }
}

/** The changed paths of `range` in `worktree`, or null when git could not say (never []-as-unknown). */
export function changedPaths(worktree, range, diag) {
  try {
    const out = execFileSync("git", ["-C", worktree, "diff", "--name-only", "-z", range], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 64 * 1024 * 1024,
    });
    return out.split("\0").filter(Boolean);
  } catch (e) {
    const rc = e && typeof e.status === "number" ? e.status : "unknown";
    diag(`SURFACE-INDETERMINATE: git diff --name-only -z exited ${rc}; the changed-path list is UNKNOWN, not empty.`);
    return null;
  }
}

const SURFACE_NAMES = { dataLayer: "data-layer", infra: "infra", frontend: "frontend", security: "security-surface", tests: "test-surface" };

function indeterminateNote(role, surface) {
  return `${role} SEATED on an INDETERMINATE ${SURFACE_NAMES[surface]} probe, not on a match.`;
}

/**
 * Compose the full panel. `probes` maps dataLayer, infra, frontend to a probe outcome. Pure.
 * Returns { roles, notes, indeterminate } where notes are PANEL-NOTE bodies.
 */
export function composeFull({ tier, costClass, probes, visualContract }) {
  if (!TIER_PANELS[tier]) throw new BadInput(`risk_tier ${JSON.stringify(tier)} is not one of ${Object.keys(TIER_PANELS).join(", ")}`);
  const seats = (o) => o !== "no-match";
  const notes = [];
  let indeterminate = false;
  const seatedBy = (role, surface) => {
    if (probes[surface] === "indeterminate") {
      notes.push(indeterminateNote(role, surface));
      indeterminate = true;
    }
  };

  if (normCostClass(costClass) === "tooling") {
    const bySurface = { devops: "infra", dba: "dataLayer", design_review: "frontend" };
    let specialist = "dev";
    for (const r of TOOLING_SPECIALIST_ORDER) {
      if (seats(probes[bySurface[r]])) {
        specialist = r;
        seatedBy(r, bySurface[r]);
        break;
      }
    }
    const roles = ["qa", "secops", specialist];
    notes.push(`cost_class tooling panel: ${roles.join(" ")} (one round).`);
    return { roles, notes, indeterminate };
  }

  const roles = [...TIER_PANELS[tier]];
  if (tier === "standard") {
    if (seats(probes.dataLayer)) { roles.push("dba"); seatedBy("dba", "dataLayer"); }
    if (seats(probes.infra)) { roles.push("devops"); seatedBy("devops", "infra"); }
  }
  if (seats(probes.frontend)) { roles.push("design_review"); seatedBy("design_review", "frontend"); }
  if (visualContract) roles.push("art_director");
  return { roles, notes, indeterminate };
}

/**
 * Compose the delta set. `seed` is the open-blocker role list, or null when peer-review.json was
 * unreadable (then `fullPanel` seeds). `probes` maps dataLayer, security, tests, infra. Pure.
 */
export function composeDelta({ fullPanel, seed, costClass, probes }) {
  const tooling = normCostClass(costClass) === "tooling";
  const roles = [];
  const notes = [];
  let indeterminate = false;
  const add = (r) => { if (!roles.includes(r)) roles.push(r); };
  if (seed === null) {
    notes.push(`open blocker ids UNREADABLE from peer-review.json; the delta seeds the FULL panel (${fullPanel.join(" ")}).`);
    indeterminate = true;
    fullPanel.forEach(add);
  } else {
    seed.forEach(add);
  }
  // A role's surfaces, in order. It is seated when any surface does not say no-match, and the seat
  // is noted as indeterminate only when no surface MATCHED and the seed did not already hold it.
  const surfaces = [
    ["dba", ["dataLayer"]],
    ["secops", tooling ? ["security"] : ["dataLayer", "security"]],
    ["qa", ["tests"]],
    ["devops", tooling ? [] : ["infra"]],
  ];
  for (const [role, list] of surfaces) {
    const seating = list.filter((s) => probes[s] !== "no-match");
    if (seating.length === 0) continue;
    const already = roles.includes(role);
    add(role);
    if (!already && !seating.some((s) => probes[s] === "match")) {
      notes.push(indeterminateNote(role, seating[0]));
      indeterminate = true;
    }
  }
  return { roles, notes, indeterminate };
}

export function parseArgs(argv) {
  const [mode, ...rest] = argv;
  if (mode !== "full" && mode !== "delta") throw new BadInput(`first argument must be full or delta, got ${JSON.stringify(mode)}`);
  const args = { mode, base: "origin/main", write: false };
  const valued = { "--status": "status", "--worktree": "worktree", "--artifact-dir": "artifactDir", "--base": "base", "--first-round-head": "firstRoundHead", "--peer-review": "peerReview", "--cost-class": "costClass" };
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--write") { args.write = true; continue; }
    const key = valued[a];
    if (!key) throw new BadInput(`unknown argument ${JSON.stringify(a)}`);
    const v = rest[i + 1];
    if (v === undefined || v === "") throw new BadInput(`${a} needs a value`);
    args[key] = v;
    i++;
  }
  const need = mode === "full" ? ["status", "worktree", "artifactDir"] : ["status", "worktree", "firstRoundHead", "peerReview"];
  const flagOf = Object.fromEntries(Object.entries(valued).map(([f, k]) => [k, f]));
  for (const k of need) if (!args[k]) throw new BadInput(`${mode} needs ${flagOf[k]}`);
  for (const k of ["base", "firstRoundHead"]) {
    if (args[k] !== undefined && (args[k].startsWith("-") || /[\s<>]/.test(args[k]))) {
      throw new BadInput(`${flagOf[k]} ${JSON.stringify(args[k])} is not a git revision; substitute the real ref`);
    }
  }
  if (args.costClass !== undefined && !COST_CLASSES.includes(args.costClass)) {
    throw new BadInput(`--cost-class ${JSON.stringify(args.costClass)} is not one of ${COST_CLASSES.join(", ")}`);
  }
  for (const k of ["status", "worktree", "artifactDir", "peerReview"]) if (args[k]) args[k] = nativePath(args[k]);
  return args;
}

function readStatus(file) {
  try {
    const st = JSON.parse(readFileSync(file, "utf8"));
    if (!st || typeof st !== "object" || Array.isArray(st)) throw new Error("not a JSON object");
    return st;
  } catch (e) {
    throw new BadInput(`cannot read status.json ${file}: ${e.message}`);
  }
}

/** openBlockerRoles over the file, or null when the file cannot be read as a JSON object. */
export function readSeed(file, diag) {
  try {
    const j = JSON.parse(readFileSync(file, "utf8"));
    if (!j || typeof j !== "object" || Array.isArray(j)) throw new Error("not a JSON object");
    return openBlockerRoles(j);
  } catch (e) {
    diag(`SEED-INDETERMINATE: ${e && e.message}`);
    return null;
  }
}

/** Append each note to flags[] once. Mutates and returns st. */
export function recordNotes(st, notes, at = new Date().toISOString()) {
  if (notes.length === 0) return st;
  if (!Array.isArray(st.flags)) st.flags = [];
  for (const n of notes) {
    const summary = `PANEL-NOTE: ${n}`.slice(0, FLAG_SUMMARY_MAX);
    if (st.flags.some((f) => f && f.agent === "panel-roles" && f.summary === summary)) continue;
    st.flags.push({ phase: "4-review", agent: "panel-roles", summary, at });
  }
  return st;
}

export function run(argv, { diag = (l) => process.stderr.write(`${l}\n`) } = {}) {
  const args = parseArgs(argv);
  const st = readStatus(args.status);
  const costClass = args.costClass || st.cost_class;
  let result;
  if (args.mode === "full") {
    if (!TIER_PANELS[st.risk_tier]) throw new BadInput(`status.json risk_tier ${JSON.stringify(st.risk_tier)} is not one of ${Object.keys(TIER_PANELS).join(", ")}; absence is not trivial`);
    const paths = changedPaths(args.worktree, `${args.base}...HEAD`, diag);
    const probes = {
      dataLayer: probe((p) => diffTouchesDataLayer(p), paths, "diffTouchesDataLayer", diag),
      infra: probe((p) => diffTouchesInfra(p), paths, "diffTouchesInfra", diag),
      frontend: probe((p) => diffTouchesFrontend(p), paths, "diffTouchesFrontend", diag),
    };
    const visualContract = existsSync(path.join(args.artifactDir, "visual-contract.json"));
    result = composeFull({ tier: st.risk_tier, costClass, probes, visualContract });
    if (args.write) st.panel_roles = result.roles;
  } else {
    const fullPanel = Array.isArray(st.panel_roles) ? st.panel_roles.filter((r) => typeof r === "string" && r !== "") : [];
    if (fullPanel.length === 0) throw new BadInput("status.json panel_roles is absent or empty; a delta round needs the first round's recorded panel");
    const seed = readSeed(args.peerReview, diag);
    const paths = changedPaths(args.worktree, `${args.firstRoundHead}...HEAD`, diag);
    const probes = {
      dataLayer: probe((p) => diffTouchesDataLayer(p), paths, "diffTouchesDataLayer", diag),
      security: probe((p) => diffTouchesSecuritySurface(p), paths, "diffTouchesSecuritySurface", diag),
      tests: probe((p) => diffTouchesTests(p), paths, "diffTouchesTests", diag),
      infra: probe((p) => diffTouchesInfra(p), paths, "diffTouchesInfra", diag),
    };
    result = composeDelta({ fullPanel, seed, costClass, probes });
  }
  for (const n of result.notes) diag(`PANEL-NOTE: ${n}`);
  if (args.write) {
    recordNotes(st, result.notes);
    writeFileSync(args.status, JSON.stringify(st, null, 2) + "\n");
  }
  return { roles: result.roles, code: result.indeterminate ? EXIT_SEATED_ON_INDETERMINATE : EXIT_OK };
}

if (isMain("panel-roles.mjs")) {
  try {
    const { roles, code } = run(process.argv.slice(2));
    process.stdout.write(roles.map((r) => `${r}\n`).join(""));
    process.exitCode = code;
  } catch (e) {
    process.stderr.write(`panel-roles: ${e && e.message}\n`);
    process.exitCode = e instanceof BadInput ? EXIT_BAD_INPUT : 2;
  }
}
