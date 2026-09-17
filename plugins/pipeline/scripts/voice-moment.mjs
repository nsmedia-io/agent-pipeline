#!/usr/bin/env node
/**
 * voice-moment.mjs -- which register the owner-facing message at this checkpoint takes, what it
 * must carry, and the facts it must state (#164 row 21).
 *
 *   node voice-moment.mjs --status <status.json> [--worktree <dir>] [--spec <spec.json>]
 *                         [--base <ref>] [--json]
 *
 * orchestrator/owner-handoff.md listed the full-voice moments and told the orchestrator how to
 * derive two facts by hand: whether the diff carries a migration (which makes Reversibility a
 * "one way door" said in the first three lines) and which open questions a BA default answered
 * (which the report must name). Both are computable, and the moment table was already code in
 * voice-lint.mjs. So the table lives HERE, once, and voice-lint.mjs imports it: the lint that
 * grades the message and the call that says what the message needs read one table.
 *
 * OUTPUT (text; --json prints the same record as JSON):
 *   PHASE, REGISTER (full | reduced | progress), SECTIONS (the headings and labels voice-lint
 *   checks at this phase), FACT migration (yes | no | unknown, with the paths), FACT ba_default
 *   (the defaulted question ids, or unknown), and the phase-independent full-voice moments.
 *
 * A FACT THAT CANNOT BE READ IS "unknown", NEVER "no". An unreadable diff is not a diff without a
 * migration, and a missing spec is not a spec without defaults; voice.md says a scale you cannot
 * fill is stated as unknown.
 *
 * EXIT. 0 printed. 1 usage, or a status record with no readable current_phase.
 *
 * LIGHT ON IMPORT. voice-lint.mjs runs on every Stop and imports this module for the table, so
 * the surface module and child_process are loaded only when the CLI runs.
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { isMain, nativePath } from "./lib.mjs";

// current_phase -> what voice.md requires of the message that accompanies it.
//
// Keys are matched EXACTLY against status.current_phase and every one is a string pipeline.md
// actually writes. That is not a stylistic note: the first version of this table invented four
// keys ("5-complete", "5-pr-ready", "4-request-changes", "3-live-verification-required") that
// no phase ever writes, so those checks could never fire, while the real completion report
// ("5-archived") and the real live-verification halt ("3-impl-live-verify-unverified") went
// uncovered. A table asserted from memory rather than derived from the source is the exact
// defect this plugin keeps re-learning. tests/test-voice-lint.sh parses every
// `current_phase: "..."` out of pipeline.md and fails when one is neither listed here nor
// explicitly declared non-voice in voice-lint.mjs, so the table cannot drift from the
// orchestrator again. EXPORTED (and re-exported by voice-lint.mjs) so that suite can assert SET
// MEMBERSHIP over the table itself rather than grep a source a comment could satisfy.
//
// NEITHER THIS TABLE NOR voice-lint.mjs's NON_VOICE_PHASES IS FROZEN, and that is a ruling
// rather than an omission. Measured: `Object.freeze(new Set(["a"]))` reports
// `Object.isFrozen === true` and then accepts `.add("b")` with size going 1 -> 2, because a Set's
// members are not own properties. Freezing the Set would report a protection it does not
// provide, and freezing only the object half would leave a reader assuming both were covered.
export const VOICE_MOMENTS = {
  "1-ba-open-questions": { decision: true, label: "a blocking open question" },
  "1-ba-rework-required": { scales: true, label: "a veto rework halt" },
  "2.5-design-owner-decision": { decision: true, label: "the design-lock" },
  "3-impl-live-verify-unverified": { scales: true, label: "the live-verification halt" },
  "4-veto-rework-required": { scales: true, label: "a SecOps veto" },
  "4-review-complete": { scales: true, label: "the panel result handed to the owner" },
  "5-archived": { scales: true, replication: true, label: "the completion report" },
};

/**
 * Mechanical halts the pipeline loops back from on its own: reduced voice (plain language, blast
 * radius and reversibility when known, the resume command; no analogy, no decision block).
 */
export const REDUCED_PHASES = [
  "3-impl-gate-failed",
  "3-impl-frontend-gate-failed",
  "3-impl-tripwire",
  "3-impl-tripwire-indeterminate",
];

/**
 * Full voice at exactly these moments and no others. Some have a phase above; the rest (a PR
 * presented as ready, a call the pipeline cannot make) happen inside a phase, so they are listed
 * here rather than keyed, and printed at every checkpoint.
 */
export const FULL_VOICE_MOMENTS = [
  "A SecOps `VETO`, at Phase 2 or Phase 4.",
  "A Phase 1 **blocking open question** (`spec.open_questions[].blocking === true`): one question per block, first one first, `ba_recommendation` as the recommendation.",
  "The Phase 2.5 **design-lock**, when `design.owner_decision.required` is true: present the two sketches as rendered, recommend the judge's winner, and wait.",
  "Any `REQUEST_CHANGES` summary returned to the owner.",
  "The live-verification halt (the owner has to go run something against a real backing service).",
  "Presenting a PR as ready for human merge.",
  "The Phase 5 completion report (the feature complete report template, verbatim).",
  "Any call the pipeline cannot make for itself: a dirty worktree at Phase 0, an unresolvable scope-drift ruling, or a cost/product-direction question BA escalated through you.",
];

/** The register and required sections for a phase. Pure. */
export function momentFor(phase) {
  const m = typeof phase === "string" ? VOICE_MOMENTS[phase] : undefined;
  if (m) {
    const sections = [];
    if (m.scales) sections.push("**Blast radius:**", "**Reversibility:**", "**Confidence:**");
    if (m.replication) sections.push("### See it yourself");
    if (m.decision) sections.push("### I need a decision (last, one question)");
    return { register: "full", label: m.label, sections };
  }
  if (REDUCED_PHASES.includes(phase) || /-error$/.test(String(phase))) {
    return { register: "reduced", label: /-error$/.test(String(phase)) ? "a halted run" : "a mechanical halt", sections: [] };
  }
  return { register: "progress", label: "a progress tick", sections: [] };
}

/** Open questions a BA default answered, or null when the spec cannot be read. */
export function baDefaults(spec) {
  if (!spec || typeof spec !== "object") return null;
  const list = Array.isArray(spec.open_questions) ? spec.open_questions : [];
  return list
    .filter((q) => q && typeof q === "object" && q.resolution && q.resolution.answered_by === "ba_default")
    .map((q) => ({ id: q.id ?? null, question: q.question ?? "", answer: q.resolution.answer ?? "" }));
}

/** { value: "yes"|"no"|"unknown", paths, reason } for the worktree's diff against base. */
export async function migrationFact(worktree, base) {
  if (!worktree) return { value: "unknown", paths: [], reason: "no --worktree given" };
  const { spawnSync } = await import("node:child_process");
  const dls = await import("./data-layer-surface.mjs");
  const r = spawnSync("git", ["-C", worktree, "diff", "--name-only", "-z", `${base}...HEAD`], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error || r.status !== 0) {
    return { value: "unknown", paths: [], reason: `git diff ${base}...HEAD exited ${r.error ? r.error.code : r.status}` };
  }
  const changed = r.stdout.split("\0").filter(Boolean);
  // The TRIPWIRE's union set: built-in presets plus migrationGlobs plus extraMigrationGlobs, so
  // config can only widen what counts as a one-way door.
  const globs = dls.migrationGlobsForTripwire(dls.readPipelineConfig(worktree));
  const paths = changed.filter((p) => dls.isMigrationPath(p, globs));
  return { value: paths.length ? "yes" : "no", paths, reason: `${changed.length} changed path(s) against ${base}` };
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(nativePath(file), "utf8"));
  } catch {
    return null;
  }
}

export async function describe({ status, worktree, spec, base = "origin/main" }) {
  const record = readJson(status);
  const phase = record && typeof record.current_phase === "string" ? record.current_phase : null;
  if (!phase) return null;
  const specDoc = readJson(spec || path.join(path.dirname(nativePath(status)), "spec.json"));
  const defaults = baDefaults(specDoc);
  return {
    phase,
    ...momentFor(phase),
    migration: await migrationFact(worktree && nativePath(worktree), base),
    ba_default: defaults === null ? "unknown" : defaults,
    full_voice_moments: FULL_VOICE_MOMENTS,
  };
}

export function render(d) {
  const lines = [`PHASE: ${d.phase} (${d.label})`, `REGISTER: ${d.register}`];
  lines.push(`SECTIONS: ${d.sections.length ? d.sections.join(" | ") : "none required"}`);
  const m = d.migration;
  lines.push(`FACT migration: ${m.value}${m.paths.length ? ` (${m.paths.join(", ")})` : ""}; ${m.reason}`);
  if (m.value === "yes") lines.push('  Reversibility is a One way door: say "this is a one way door" in the first three lines.');
  if (m.value === "unknown") lines.push("  Reversibility cannot be read off the diff: state it as unknown, never as an Undo button.");
  if (d.ba_default === "unknown") lines.push("FACT ba_default: unknown (spec.json unreadable)");
  else if (d.ba_default.length === 0) lines.push("FACT ba_default: none");
  else {
    lines.push(`FACT ba_default: ${d.ba_default.map((q) => q.id).join(", ")}`);
    for (const q of d.ba_default) lines.push(`  ${q.id}: "${q.question}" answered by default: "${q.answer}". Name it wherever a criterion rests on it.`);
  }
  lines.push("FULL VOICE AT EXACTLY THESE MOMENTS:");
  for (const f of d.full_voice_moments) lines.push(`  - ${f}`);
  return lines.join("\n") + "\n";
}

const USAGE = "usage: node voice-moment.mjs --status <status.json> [--worktree <dir>] [--spec <spec.json>] [--base <ref>] [--json]\n";

export async function main(argv, { out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s) } = {}) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--json") a.json = true;
    else if (["--status", "--worktree", "--spec", "--base"].includes(k) && argv[i + 1] !== undefined && !argv[i + 1].startsWith("--")) a[k.slice(2)] = argv[++i];
    else {
      err(`unknown or incomplete argument: ${k}\n${USAGE}`);
      return 1;
    }
  }
  if (!a.status) {
    err(USAGE);
    return 1;
  }
  const d = await describe(a);
  if (!d) {
    err(`cannot read current_phase from ${a.status}\n`);
    return 1;
  }
  out(a.json ? `${JSON.stringify(d, null, 2)}\n` : render(d));
  return 0;
}

// Self-run only as a real CLI entry: a test that imports this module with its own path in argv[1]
// must not run main() (the hazard voice-lint.mjs documents at its foot).
const evalEntry = process.execArgv.some((x) => x === "-e" || x === "--eval" || x === "--input-type=module" || /^--eval=/.test(x));
if (isMain("voice-moment.mjs") && !evalEntry) {
  main(process.argv.slice(2)).then((code) => process.exit(code));
}
