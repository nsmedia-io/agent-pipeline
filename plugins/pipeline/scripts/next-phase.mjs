#!/usr/bin/env node
/**
 * next-phase.mjs -- from the run record and the tier, which phase runs now, which orchestrator
 * files to Read before it, and which phase follows (#164 row 20).
 *
 * WHY. The routing sat in three prose copies: the core's loading table, phase-1-ba.md's "Route by
 * tier" and "Skip if", and phase-0.5-map.md's tier gate. A file not loaded is a gate not run, and
 * a phase routed from memory is a phase skipped. This file holds the one map; the core's loading
 * table is `--table`'s output, and tests/test-next-phase.sh holds the two equal.
 *
 *   node next-phase.mjs --status <status.json> [--spec <spec.json>] [--existing-issue]
 *   node next-phase.mjs --table
 *
 * A missing status.json is a run not yet set up: RUN is 0-setup. `current_phase` is an ENTRY
 * marker, so `<phase>` and a parked `<phase>-<state>` re-run that phase, `<phase>-complete` runs
 * the next one, and a rework state returns to 1-ba. The tier comes from spec.json when given (BA's
 * output), else status.json. `--existing-issue` is the `--issue <n>` start: a spec.json that
 * already carries `ba_approved_at` skips 1-ba.
 *
 * OUTPUT, one fact per line: CURRENT, TIER, RUN, READ (one per file, with its condition), MAP (at
 * 0.5-map), SKIP, THEN.
 *
 * EXIT CODES. 0 routed (or DONE). 1 usage, or a status.json that will not parse. 2 routing cannot
 * be computed: no tier where one decides the next phase, a phase that does not run at the recorded
 * tier, or an unrecognised current_phase. 3 the run is halted on an error state: surface it.
 */

import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { isMain, nativePath } from "./lib.mjs";

export const TIERS = ["trivial", "standard", "architectural"];

/**
 * The phases in order. `tiers` restricts where a phase runs; `read` entries carry `tier` (only at
 * that tier) or `when` (read when that condition holds, printed beside the file).
 */
export const PHASES = [
  {
    phase: "0-setup",
    label: "`0-setup`, every run",
    read: [{ file: "phase-0-setup.md" }, { file: "status-record.md", when: "before the record is first read or written" }],
  },
  {
    phase: "0.5-map",
    read: [{ file: "phase-0.5-map.md" }, { file: "dispatch-routing.md", tier: "architectural" }],
  },
  { phase: "1-ba", label: "`1-ba`, and every later BA dispatch", read: [{ file: "phase-1-ba.md" }] },
  { phase: "2-constraints", tiers: ["standard"], read: [{ file: "phase-2-lite.md" }] },
  { phase: "2-review", tiers: ["architectural"], read: [{ file: "phase-2-review.md" }] },
  {
    phase: "2.5-design",
    tiers: ["architectural"],
    read: [{ file: "phase-2.5-design.md" }, { file: "dispatch-routing.md" }],
  },
  {
    phase: "3-impl",
    read: [
      { file: "phase-3-impl.md" },
      { file: "phase-3-architectural.md", tier: "architectural", when: "before any dispatch" },
      { file: "phase-3-4-gate.md", when: "Phase 3 returned" },
      { file: "live-verification.md", when: "the gate says so" },
    ],
  },
  {
    phase: "4-review",
    read: [{ file: "phase-4-panel.md" }, { file: "phase-4-verdict.md", when: "after the merge" }],
  },
  { phase: "5-archive", read: [{ file: "phase-5-archive.md" }] },
];

/** Files a condition, not a phase, brings in. route() evaluates the first three from the record. */
export const CONDITIONS = [
  {
    when: "Frontend-scoped spec at routing, or `visual-contract.json` at Phase 4",
    file: "art-director-contract.md",
  },
  { when: "A fix round or delta re-review", file: "phase-4-delta.md" },
  {
    when: "Before ANY loop back, spec revision or fix round, or on `checkpoint.mjs --loopback` exit 2",
    file: "loop-backs.md",
  },
  { when: "Any model or effort routing question", file: "dispatch-routing.md" },
  {
    when: "Before the first owner-facing message that is not a progress tick, and the first parallel fan-out",
    file: "owner-handoff.md",
  },
];

const ORDER = PHASES.map((p) => p.phase);
const phaseOf = (name) => PHASES.find((p) => p.phase === name);

/** The phase after `name` at `tier`, or null when the tier decides it and is unknown. */
export function nextPhase(name, tier) {
  if (name === "1-ba") {
    if (!TIERS.includes(tier)) return null;
    return { trivial: "3-impl", standard: "2-constraints", architectural: "2-review" }[tier];
  }
  const i = ORDER.indexOf(name);
  for (let j = i + 1; j < ORDER.length; j++) {
    const p = PHASES[j];
    if (!p.tiers || p.tiers.includes(tier)) return p.phase;
  }
  return "done";
}

/** current_phase -> { base, state } with state entered | complete | parked | rework | done | halted | unknown. */
export function classify(current) {
  if (typeof current !== "string" || current === "") return { base: null, state: "none" };
  if (current === "halted-error" || current.endsWith("-error")) return { base: null, state: "halted" };
  if (current === "5-archived") return { base: "5-archive", state: "done" };
  if (current.endsWith("-rework-required")) return { base: "1-ba", state: "rework" };
  const base = [...ORDER].sort((a, b) => b.length - a.length).find((p) => current === p || current.startsWith(`${p}-`));
  if (!base) return { base: null, state: "unknown" };
  if (current === base) return { base, state: "entered" };
  if (current === `${base}-complete`) return { base, state: "complete" };
  return { base, state: "parked" };
}

function readJson(file) {
  if (!file || !existsSync(file)) return { absent: true, data: null };
  try {
    return { absent: false, data: JSON.parse(readFileSync(file, "utf8")) };
  } catch (e) {
    return { absent: false, data: null, error: e.message };
  }
}

export function tierOf(status, spec) {
  const fromSpec = spec && (TIERS.includes(spec.risk_tier) ? spec.risk_tier : spec.trivial === true ? "trivial" : null);
  if (fromSpec) return { tier: fromSpec, source: "spec.json" };
  if (status && TIERS.includes(status.risk_tier)) return { tier: status.risk_tier, source: "status.json" };
  return { tier: null, source: "undetermined" };
}

/**
 * The routing decision, no I/O. `ctx`: { status, spec, existingIssue, visualContract }.
 * @returns {{code: number, lines: string[]}}
 */
export function route({ status, spec, existingIssue = false, visualContract = false }) {
  const lines = [];
  const current = status ? status.current_phase : undefined;
  const c = status ? classify(current) : { base: null, state: "none" };
  const { tier, source } = tierOf(status, spec);
  lines.push(`CURRENT: ${status ? current : "(no status.json)"}`);
  lines.push(`TIER: ${tier || "undetermined"} (${source})`);

  if (c.state === "halted") {
    lines.push(`HALTED: ${current} is an error state; surface it to the owner before re-entering a phase`);
    return { code: 3, lines };
  }
  if (c.state === "unknown") {
    lines.push(`ROUTE: cannot compute: "${current}" names no phase this map knows`);
    return { code: 2, lines };
  }
  if (c.state === "done") {
    lines.push("RUN: none (DONE: the run is archived)");
    return { code: 0, lines };
  }

  let run = c.state === "none" ? "0-setup" : c.base;
  if (c.state === "complete") {
    run = nextPhase(c.base, tier);
    if (run === null) {
      lines.push(`ROUTE: cannot compute the phase after ${c.base}: no risk_tier in spec.json or status.json`);
      return { code: 2, lines };
    }
  }
  if (run === "1-ba" && existingIssue && spec && spec.ba_approved_at) {
    lines.push("SKIP: 1-ba (--issue start and spec.json already carries ba_approved_at)");
    run = nextPhase("1-ba", tier);
    if (run === null) {
      lines.push("ROUTE: cannot compute the phase after 1-ba: no risk_tier in spec.json or status.json");
      return { code: 2, lines };
    }
  }
  if (run === "done") {
    lines.push("RUN: none (DONE)");
    return { code: 0, lines };
  }
  const p = phaseOf(run);
  if (p.tiers && tier && !p.tiers.includes(tier)) {
    lines.push(`ROUTE: ${run} does not run at the ${tier} tier; the record and the tier disagree, so loop back rather than guess`);
    return { code: 2, lines };
  }

  lines.push(`RUN: ${run}${c.state === "parked" ? ` (parked at ${current}: resume inside this phase)` : ""}`);
  const reads = [];
  for (const r of p.read) {
    if (r.tier && tier !== r.tier) continue;
    reads.push(r.when ? `${r.file} (${r.when})` : r.file);
  }
  const frontend = spec && Array.isArray(spec.impacted_domains) && spec.impacted_domains.includes("frontend");
  if (frontend && ["2-constraints", "2-review", "3-impl"].includes(run)) {
    reads.push("art-director-contract.md (spec is frontend-scoped)");
  } else if (visualContract && run === "4-review") {
    reads.push("art-director-contract.md (visual-contract.json exists)");
  }
  const rounds = status && Number.isInteger(status.review_rounds) ? status.review_rounds : 0;
  const panelsDone = current === "4-review" ? rounds - 1 : rounds;
  if (panelsDone >= 1 && (run === "3-impl" || run === "4-review")) {
    reads.push(`phase-4-delta.md (review_rounds ${rounds}: a fix round or delta re-review)`);
    reads.push("loop-backs.md (a fix round)");
  } else if (c.state === "rework") {
    reads.push(`loop-backs.md (${current})`);
  }
  for (const r of reads) lines.push(`READ: ${r}`);

  if (run === "0.5-map") {
    const depth = tier === "architectural" ? "separate" : tier === "trivial" ? "skip" : "folded";
    lines.push(`MAP: ${depth}`);
  }
  const then = nextPhase(run, tier);
  if (then === null) {
    lines.push("THEN: set by BA's tier: trivial 3-impl, standard 2-constraints, architectural 2-review");
  } else {
    lines.push(`THEN: ${then === "done" ? "none (the run ends)" : then}`);
  }
  return { code: 0, lines };
}

/** The core's loading table. commands/pipeline.md carries exactly this, and a test holds it. */
export function renderTable() {
  const out = ["| When | Read now |", "|---|---|"];
  const cell = (entries) =>
    entries
      .map((r) => {
        const q = [r.tier, r.when].filter(Boolean).join(", ");
        return `\`${r.file}\`${q ? ` (${q})` : ""}`;
      })
      .join("; ");
  for (const p of PHASES) {
    const label = p.label || `\`${p.phase}\`${p.tiers ? ` (${p.tiers.join(", ")})` : ""}`;
    out.push(`| ${label} | ${cell(p.read)} |`);
  }
  for (const c of CONDITIONS) out.push(`| ${c.when} | \`${c.file}\` |`);
  return `${out.join("\n")}\n`;
}

const USAGE = "usage: node next-phase.mjs --status <status.json> [--spec <spec.json>] [--existing-issue] | --table\n";

export function main(argv, { out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s) } = {}) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--status" || k === "--spec") a[k.slice(2)] = argv[++i];
    else if (k === "--existing-issue") a.existingIssue = true;
    else if (k === "--table") a.table = true;
    else {
      err(`next-phase: unknown argument ${k}\n${USAGE}`);
      return 1;
    }
  }
  if (a.table) {
    out(renderTable());
    return 0;
  }
  if (!a.status) {
    err(USAGE);
    return 1;
  }
  const statusFile = nativePath(a.status);
  const st = readJson(statusFile);
  if (st.error) {
    err(`next-phase: ${statusFile} is not valid JSON (${st.error}); the resume point cannot be read\n`);
    return 1;
  }
  const sp = a.spec ? readJson(nativePath(a.spec)) : { data: null };
  if (sp.error) err(`next-phase: ${a.spec} is not valid JSON (${sp.error}); the tier is read from status.json\n`);
  const r = route({
    status: st.data,
    spec: sp.data,
    existingIssue: Boolean(a.existingIssue),
    visualContract: existsSync(path.join(path.dirname(statusFile), "visual-contract.json")),
  });
  out(`${r.lines.join("\n")}\n`);
  return r.code;
}

if (isMain("next-phase.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
