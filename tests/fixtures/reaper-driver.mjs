#!/usr/bin/env node
// Drives scripts/reap-orphans.mjs `reap()` against PLANTED process tables, so a suite can ask
// "what would the reaper do to this table" without touching the host's real processes. Not a
// suite itself (fixtures/ is outside run.sh's `test-*.sh` glob).
//
//   node reaper-driver.mjs <scratch-dir>      (the scenarios are in reaper-scenarios.mjs)
//
// ONE node start runs every scenario: this host's node cold start is seconds under load, and the
// suite has dozens of cases. The output is flat `<scenario>.<run>.<field>=<value>` lines so the
// bash suite reads a result with a grep, not a node start per assertion.
//
// scenarios: [{ name, ...scenario, runs?: [ {...overrides}, ... ] }]; runs of one scenario share a
// state dir (the throttle and the already-reported memory live there).
// scenario: {
//   platform, now, selfPid, event, rootPid?, dryRun?,
//   config:     { ...orphanReaper }                           written as pipeline.config.json
//   env:        { NAME: value }                               the reaper's environment
//   procs:      [{ pid, ppid, name, cmd, ageMin, cpuSec }]    created = now - ageMin minutes
//   second:     [...]   optional second snapshot, the confirmation read (default: the first)
//   mtimes:     { "<path>": <age in minutes> }                a path absent from here is missing
//   bg:         { known, commands }                           the live background tasks
//   collectFailure: "<reason>"                                the process list cannot be read
//   payload:    {...}
// }
// fields: status reason killedPids killCalls reportedPids summary notes collects log

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { reap } from "../../plugins/pipeline/scripts/reap-orphans.mjs";
import { scenarios } from "./reaper-scenarios.mjs";

const scratch = process.argv[2];
const lines = [];

for (const base of scenarios) {
  const dir = path.join(scratch, base.name);
  const project = path.join(dir, "project");
  const state = path.join(dir, "state");
  mkdirSync(project, { recursive: true });
  const runs = base.runs ?? [{}];
  for (let i = 0; i < runs.length; i++) {
    const sc = { ...base, ...runs[i] };
    const now = sc.now ?? 1_790_000_000_000;
    writeFileSync(path.join(project, "pipeline.config.json"), JSON.stringify(sc.config ? { orphanReaper: sc.config } : {}));
    const toProcs = (rows) =>
      rows.map((r) => ({
        pid: r.pid,
        ppid: r.ppid,
        name: r.name,
        cmd: r.cmd ?? r.name,
        created: now - (r.ageMin ?? 0) * 60000,
        cpuSec: r.cpuSec ?? 0,
      }));
    let collects = 0;
    const first = toProcs(sc.procs ?? []);
    const second = sc.second ? toProcs(sc.second) : first;
    const killCalls = [];
    const dead = new Set();

    const res = await reap({
      event: sc.event ?? "SubagentStop",
      platform: sc.platform ?? "linux",
      now,
      selfPid: sc.selfPid,
      rootPid: sc.rootPid,
      projectDir: project,
      stateDir: state,
      payload: sc.payload ?? {},
      dryRun: !!sc.dryRun,
      env: sc.env ?? {},
      budgetMs: 60000,
      collect: () => {
        collects++;
        if (sc.collectFailure) return { ok: false, reason: sc.collectFailure };
        return { ok: true, procs: collects === 1 ? first : second };
      },
      kill: (pid, sig) => {
        killCalls.push(`${pid}:${sig}`);
        // `ignoreTerm` plants a process that shrugs off SIGTERM and only a SIGKILL ends
        if (!(sc.ignoreTerm && sig === "SIGTERM")) dead.add(pid);
        return true;
      },
      alive: (pid) => !dead.has(pid),
      sleep: async () => {},
      statMtime: (p) => (Object.prototype.hasOwnProperty.call(sc.mtimes ?? {}, p) ? now - sc.mtimes[p] * 60000 : null),
      toNative: (t) => t,
      readBackground: () => sc.bg ?? { known: false, commands: [] },
    });

    const log = path.join(state, "reaper.log");
    const out = {
      status: res.status,
      reason: res.reason ?? "",
      killedPids: res.killed.filter((c) => c.killed === true).map((c) => c.p.pid).join(","),
      killCalls: killCalls.join(","),
      reportedPids: res.reported.map((c) => c.p.pid).join(","),
      summary: res.summary.replace(/\n/g, " // "),
      notes: res.notes.join(" | "),
      collects: String(collects),
      log: existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").join(" // ") : "",
    };
    for (const [k, v] of Object.entries(out)) lines.push(`${base.name}.${i}.${k}=${v}`);
  }
}
process.stdout.write(lines.join("\n") + "\n");
