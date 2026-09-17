#!/usr/bin/env node
// The Phase 3 to 4 exit, in one call (#164 row 6).
//
// orchestrator/phase-3-4-gate.md carried a bash block the orchestrator copied and ran for the
// mis-tier tripwire (git diff, a NUL-delimited hand-off, an inline `node -e` program, and three
// exit-status branches), then two gate commands and four halt states written by hand. Every
// failure that block was rewritten for was a lost exit status: a pipe, an unsplit zsh variable,
// git's own status discarded. Here the statuses never cross a shell.
//
//   node phase3-exit.mjs --worktree <dir> --artifact-dir <dir> [--issue <n>] [--tier <tier>]
//                        [--status <status.json>] [--base <ref>]
//
// 1. The mis-tier tripwire, at trivial and standard tier (the tier is --tier, else spec.risk_tier;
//    an unknown tier runs the tripwire, since skipping it is the unsafe reading). The changed
//    paths are `git -C <worktree> diff --name-only -z <base>...HEAD`. A HIT is a data-layer path
//    (tripwireReport in data-layer-surface.mjs) or a path matching an architectural path trigger,
//    pipeline.config.json and whatever the config adds (tierFloor in tier-floor.mjs; #76).
//    INDETERMINATE is a git failure, an empty path list, or a surface module that cannot be
//    evaluated: the run cannot know the diff was clean, so it is never read as clean.
// 2. Both pre-Phase-4 gates, run as their own processes, whatever step 1 found.
// 3. On a halt, --status gets current_phase and a flags entry; a NOTE gets a flags entry too.
//
// Exit, most severe first: 3 mis-tier (3-impl-tripwire), 4 indeterminate
// (3-impl-tripwire-indeterminate), 2 a gate refused (3-impl-gate-failed, or
// 3-impl-frontend-gate-failed when only the frontend gate refused), 0 clean. 1 is a usage error.
// Any other exit (a stale plugin root with no such script, a module that exits at import) is
// the caller's to read as indeterminate.

import { readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isMain as isMainScript } from "./lib.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TIERS = ["trivial", "standard", "architectural"];

export const STATES = {
  3: "3-impl-tripwire",
  4: "3-impl-tripwire-indeterminate",
  gate: "3-impl-gate-failed",
  frontend: "3-impl-frontend-gate-failed",
};

function parseArgs(argv) {
  const a = { base: "origin/main" };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = argv[i + 1];
    if (k === "--worktree") a.worktree = v;
    else if (k === "--artifact-dir") a.artifactDir = v;
    else if (k === "--issue") a.issue = v;
    else if (k === "--tier") a.tier = v;
    else if (k === "--status") a.status = v;
    else if (k === "--base") a.base = v;
    else return { error: `unknown argument: ${k}` };
    i++;
  }
  if (!a.worktree || !a.artifactDir) return { error: "--worktree and --artifact-dir are required" };
  return a;
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

/** The tier the tripwire runs under: --tier, else the spec's, else null (which runs it). */
export function effectiveTier(tierArg, spec) {
  if (TIERS.includes(tierArg)) return tierArg;
  if (spec && TIERS.includes(spec.risk_tier)) return spec.risk_tier;
  if (spec && spec.trivial === true) return "trivial";
  return null;
}

/** git's changed-path list, or { error } naming git's exit status. Never an empty list on failure. */
export function changedPaths(worktree, base) {
  const r = spawnSync("git", ["-C", worktree, "diff", "--name-only", "-z", `${base}...HEAD`], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error || r.status !== 0) {
    const code = r.error ? r.error.code || "spawn-error" : r.status;
    return { error: `git diff --name-only -z exited ${code}, so the changed-path list is UNKNOWN rather than empty` };
  }
  const paths = r.stdout.split("\0").filter(Boolean);
  if (paths.length === 0) return { error: "empty path list: an unread diff is not a clean diff, and an empty diff has nothing to review" };
  return { paths };
}

/**
 * The tripwire over a path list. Modules are imported DYNAMICALLY from `scriptsDir` so an absent
 * or throwing surface module is an INDETERMINATE answer rather than a crash that reads as nothing.
 * Returns { hits: [string], notes: [string], indeterminate: string|null }.
 */
export async function runTripwire(paths, tier, projectDir, scriptsDir = HERE) {
  const out = { hits: [], notes: [], indeterminate: null };
  let dl;
  let tf;
  try {
    dl = await import(pathToFileURL(path.join(scriptsDir, "data-layer-surface.mjs")).href);
    tf = await import(pathToFileURL(path.join(scriptsDir, "tier-floor.mjs")).href);
    const r = dl.tripwireReport(paths, projectDir);
    if (r.hits.length) out.hits.push(`MIS-TIER: data-layer path in a ${tier ?? "untiered"} diff: ${r.hits.join(" ")}`);
    if (r.note) out.notes.push(r.note);
    const floor = tf.tierFloor({}, dl.readPipelineConfig(projectDir), paths);
    if (floor.reasons.length) out.hits.push(`MIS-TIER: architectural path trigger in a ${tier ?? "untiered"} diff: ${floor.reasons.join("; ")}`);
  } catch (e) {
    out.hits = [];
    out.notes = [];
    out.indeterminate = `the data-layer surface module under ${path.basename(scriptsDir)}/ could not be evaluated: ${e && e.message ? e.message.split("\n")[0].replace(/(?:[A-Za-z]:)?[\\/][^\s'"]*[\\/]/g, "") : e}`;
  }
  return out;
}

function runGate(script, args) {
  const r = spawnSync(process.execPath, [path.join(HERE, script), ...args], { encoding: "utf8" });
  if (r.stdout) process.stderr.write(r.stdout);
  if (r.stderr) process.stderr.write(r.stderr);
  const skipped = r.status === 0 && /^SKIP\b/m.test(r.stdout || "");
  return { ok: r.status === 0, skipped, status: r.error ? r.error.code : r.status };
}

/** The verdict from the three findings. Pure. */
export function decide({ hit, indeterminate, gateFailed, frontendFailed }) {
  if (hit) return { code: 3, state: STATES[3] };
  if (indeterminate) return { code: 4, state: STATES[4] };
  if (gateFailed) return { code: 2, state: STATES.gate };
  if (frontendFailed) return { code: 2, state: STATES.frontend };
  return { code: 0, state: null };
}

function writeStatus(file, state, flags) {
  const st = readJson(file);
  if (!st || typeof st !== "object" || Array.isArray(st)) {
    console.error(`STATUS NOT WRITTEN: ${path.basename(file)} is absent or unparseable; record ${state ?? "the flags"} by hand`);
    return;
  }
  const at = new Date().toISOString();
  if (state) {
    st.current_phase = state;
    st.updated_at = at;
  }
  if (flags.length) {
    st.flags = Array.isArray(st.flags) ? st.flags : [];
    for (const summary of flags) st.flags.push({ phase: state ?? "3-impl", agent: "phase3-exit", at, summary: summary.slice(0, 140) });
  }
  writeFileSync(file, `${JSON.stringify(st, null, 2)}\n`);
}

async function main(argv) {
  const a = parseArgs(argv);
  if (a.error) {
    console.error(`${a.error}\nusage: phase3-exit.mjs --worktree <dir> --artifact-dir <dir> [--issue <n>] [--tier <tier>] [--status <status.json>] [--base <ref>]`);
    process.exit(1);
  }
  const implReport = path.join(a.artifactDir, "impl-report.json");
  const specFile = path.join(a.artifactDir, "spec.json");
  const tier = effectiveTier(a.tier, readJson(specFile));
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();

  let trip = { hits: [], notes: [], indeterminate: null };
  if (tier === "architectural") {
    console.log("SKIP: tripwire (architectural tier: nothing to mis-tier)");
  } else {
    const diff = changedPaths(a.worktree, a.base);
    if (diff.error) trip.indeterminate = diff.error;
    else trip = await runTripwire(diff.paths, tier, projectDir);
  }
  for (const h of trip.hits) console.log(`HIT: ${h}`);
  for (const n of trip.notes) console.log(`NOTE: TRIPWIRE-NOTE: ${n}`);
  if (trip.indeterminate) console.log(`INDETERMINATE: ${STATES[4]}: ${trip.indeterminate}`);

  const issueArgs = a.issue ? ["--issue", a.issue] : [];
  const g1 = runGate("gate-pre-phase4.mjs", [...issueArgs, "--impl-report", implReport, "--spec", specFile]);
  console.log(g1.ok ? "PASS: gate-pre-phase4" : `FAIL: gate-pre-phase4 (exit ${g1.status})`);
  const g2 = runGate("gate-pre-phase4-frontend.mjs", [...issueArgs, "--impl-report", implReport]);
  console.log(g2.ok ? (g2.skipped ? "SKIP: gate-pre-phase4-frontend (no frontend surface)" : "PASS: gate-pre-phase4-frontend") : `FAIL: gate-pre-phase4-frontend (exit ${g2.status})`);

  const v = decide({ hit: trip.hits.length > 0, indeterminate: !!trip.indeterminate, gateFailed: !g1.ok, frontendFailed: !g2.ok });
  if (a.status) {
    const flags = [];
    for (const n of trip.notes) flags.push(`tripwire NOTE: ${n}`);
    if (v.state) {
      const failed = [!g1.ok && "gate-pre-phase4", !g2.ok && "gate-pre-phase4-frontend"].filter(Boolean);
      flags.push(`${v.state}: ${[trip.hits.length && "tripwire hit", trip.indeterminate && "tripwire indeterminate", failed.length && `refused by ${failed.join(", ")}`].filter(Boolean).join("; ")}`);
    }
    if (flags.length || v.state) writeStatus(a.status, v.state, flags);
  }
  console.log(`RESULT: ${v.state ?? "clean"} (exit ${v.code})`);
  process.exit(v.code);
}

const isMain = isMainScript("phase3-exit.mjs");

if (isMain) {
  main(process.argv.slice(2)).catch((e) => {
    console.log(`INDETERMINATE: ${STATES[4]}: phase3-exit.mjs failed: ${e && e.message}`);
    process.exit(4);
  });
}
