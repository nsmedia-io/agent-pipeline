#!/usr/bin/env node
// The mechanical tier floor (#164 row 7, and the diff half of #76).
//
// agents/ba.md duty 6 and the post-BA validation in commands/pipeline.md both told a model to
// UNION architecturalTriggers.{paths,domains,keywords} onto a built-in floor, to treat an absent
// or malformed config as {}, and to promote when a trigger matched. Every step of that is
// determined by the spec and the config, so it is computed here instead, and the prose calls it.
//
//   node tier-floor.mjs --spec <spec.json> [--changed <path>]... [--project-dir <dir>]
//
// What forces the floor to architectural:
//   - a spec.impacted_domains entry in the built-in domain floor (compliance) UNION
//     architecturalTriggers.domains;
//   - a path trigger (the built-in pipeline.config.json UNION architecturalTriggers.paths)
//     matched by a spec.impacted_packages entry or a path-shaped word in the spec's title,
//     problem, requirements or acceptance_criteria;
//   - a path trigger matched by a --changed path (the diff a Phase 3 run produced; #76).
// Keywords are an ADVISORY signal: a match is printed as an ADVISORY line and never moves the
// floor, because a keyword is a hint to BA's judgement, not a trigger.
// The judgement triggers in ba.md (a migration, an access-policy change, a contract shape, a
// new auth flow, crypto, webhook verification, a new intake, a new retained data type) are not
// here: deciding whether a spec names one is reading, not matching.
//
// A config the surface module cannot read (absent, unparseable, not an object) is {}; a
// non-object architecturalTriggers is {}; a non-array sub-key is []; non-string elements are
// dropped. Config can only ADD triggers.
//
// Exit 0: the spec's tier is at or above the floor. Exit 2: under-tiered (promote). Exit 1: the
// spec could not be read, which is not a pass.

import { readFileSync } from "node:fs";
import { isMain as isMainScript } from "./lib.mjs";
import { globToRegExp } from "./frontend-surface.mjs";
import { readPipelineConfig } from "./data-layer-surface.mjs";

export const TIERS = ["trivial", "standard", "architectural"];
export const BUILTIN_PATHS = ["pipeline.config.json"];
export const BUILTIN_DOMAINS = ["compliance"];

function strings(v) {
  return Array.isArray(v) ? v.filter((x) => typeof x === "string" && x.trim() !== "").map((x) => x.trim()) : [];
}

function union(...lists) {
  const out = [];
  for (const l of lists) for (const x of l) if (!out.includes(x)) out.push(x);
  return out;
}

/** The effective trigger sets: built-in floor UNION config, never narrower than the floor. */
export function resolveTriggers(cfg) {
  const raw = cfg && typeof cfg === "object" && !Array.isArray(cfg) ? cfg.architecturalTriggers : undefined;
  const t = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  return {
    paths: union(BUILTIN_PATHS, strings(t.paths)),
    domains: union(BUILTIN_DOMAINS, strings(t.domains).map((d) => d.toLowerCase())),
    keywords: strings(t.keywords),
  };
}

function normPath(p) {
  return p.replace(/\\/g, "/").replace(/^\.\//, "");
}

/** The first path trigger a path matches, or null. */
export function matchPathTrigger(p, paths) {
  if (typeof p !== "string" || p.trim() === "") return null;
  const norm = normPath(p.trim());
  return paths.find((g) => globToRegExp(g).test(norm)) ?? null;
}

function specText(spec) {
  const parts = [spec.title, spec.problem, ...strings(spec.requirements), ...strings(spec.acceptance_criteria)];
  return parts.filter((x) => typeof x === "string").join("\n");
}

/** Path-shaped words in free text: split on whitespace and quoting, trailing punctuation dropped. */
export function pathWords(text) {
  return text
    .split(/[\s`'"()[\]{}<>,]+/)
    .map((w) => w.replace(/[.:;!?]+$/, ""))
    .filter((w) => w !== "");
}

function specTier(spec) {
  if (TIERS.includes(spec.risk_tier)) return spec.risk_tier;
  if (spec.trivial === true) return "trivial";
  return null;
}

/**
 * The floor for a spec (and optionally a changed-path list) under a config. Pure.
 * Returns { floor, specTier, underTiered, reasons: [string], advisories: [string] }.
 */
export function tierFloor(spec, cfg, changedPaths = []) {
  const t = resolveTriggers(cfg);
  const reasons = [];
  const s = spec && typeof spec === "object" ? spec : {};
  for (const d of strings(s.impacted_domains)) {
    if (t.domains.includes(d.toLowerCase())) reasons.push(`domain ${d} is an architectural trigger`);
  }
  for (const p of strings(s.impacted_packages)) {
    const g = matchPathTrigger(p, t.paths);
    if (g) reasons.push(`impacted package ${p} matches path trigger ${g}`);
  }
  const text = specText(s);
  const seen = new Set();
  for (const w of pathWords(text)) {
    const g = matchPathTrigger(w, t.paths);
    if (g && !seen.has(w)) {
      seen.add(w);
      reasons.push(`the spec names ${w}, which matches path trigger ${g}`);
    }
  }
  for (const p of changedPaths || []) {
    const g = matchPathTrigger(p, t.paths);
    if (g) reasons.push(`the diff touches ${normPath(p)}, which matches path trigger ${g}`);
  }
  const advisories = [];
  const lowerText = text.toLowerCase();
  for (const k of t.keywords) {
    if (lowerText.includes(k.toLowerCase())) advisories.push(`keyword "${k}" appears in the spec (a hint for judgement, not a trigger)`);
  }
  const floor = reasons.length > 0 ? "architectural" : "trivial";
  const tier = specTier(s);
  const underTiered = floor === "architectural" && tier !== "architectural";
  return { floor, specTier: tier, underTiered, reasons, advisories };
}

function main(argv) {
  let specFile = null;
  let projectDir = null;
  const changed = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--spec") specFile = argv[++i];
    else if (argv[i] === "--changed") changed.push(argv[++i]);
    else if (argv[i] === "--project-dir") projectDir = argv[++i];
    else {
      console.error(`unknown argument: ${argv[i]}`);
      process.exit(1);
    }
  }
  if (!specFile) {
    console.error("usage: tier-floor.mjs --spec <spec.json> [--changed <path>]... [--project-dir <dir>]");
    process.exit(1);
  }
  let spec;
  try {
    spec = JSON.parse(readFileSync(specFile, "utf8"));
  } catch (e) {
    console.error(`UNREADABLE SPEC: ${e.message}; an unread spec has no floor, so this is not a pass`);
    process.exit(1);
  }
  const r = tierFloor(spec, readPipelineConfig(projectDir || undefined), changed);
  console.log(`TIER-FLOOR: ${r.floor}`);
  console.log(`SPEC-TIER: ${r.specTier ?? "absent"}`);
  for (const reason of r.reasons) console.log(`REASON: ${reason}`);
  for (const a of r.advisories) console.log(`ADVISORY: ${a}`);
  if (r.underTiered) {
    console.log(`UNDER-TIERED: the spec says ${r.specTier ?? "no tier"}; promote to architectural and log the miss`);
    process.exit(2);
  }
}

const isMain = isMainScript("tier-floor.mjs");

if (isMain) {
  main(process.argv.slice(2));
}
