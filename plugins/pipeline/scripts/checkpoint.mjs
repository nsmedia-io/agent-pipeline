#!/usr/bin/env node
/**
 * checkpoint.mjs -- the status.json checkpoint as one command, not a paragraph of rules (#164).
 *
 * WHY. The durable-checkpoint convention was prose: append the exit event and set the entry phase
 * in ONE write, clear final_verdict on the write that enters 4-review or loops back (#110),
 * increment review_rounds on a panel round, refresh telemetry, keep verdicts under the schema cap
 * and the phase inside the schema pattern, then commit only status.json. Each rule was right and
 * each was hand-applied, and the records show the cost: review_rounds disagreed with the events on
 * 5 of 7 committed records, and a stale final_verdict at a guarded phase disarms the phase-entry
 * guard for the rest of the run. Every step above is fully determined by the record and the
 * arguments, so it runs here.
 *
 *   node checkpoint.mjs enter <phase> --status <status.json> [--exit-verdict V] [--exit-phase L]
 *                                     [--note N] [--loopback] [--commit] [--config <file>]
 *   node checkpoint.mjs flag --status <status.json> --phase P --agent A [--verdict V] [--summary S]
 *   node checkpoint.mjs rerun <role> [--panel] [--status <status.json> --verdict V [--note N]]
 *   node checkpoint.mjs qa-contract --sha <sha> --tasks <tasks.json> --status <status.json>
 *                                   [--worktree <dir>] [--commit]
 *
 * ENTER, in one atomic write (temp file plus rename), all or nothing:
 *   - refuses a <phase> that fails status.schema.json's current_phase pattern, and a verdict over
 *     the schema's events[].verdict maxLength, before anything is written;
 *   - with --exit-verdict, appends the EXIT event {phase, verdict, at, note} for the phase being
 *     closed: --exit-phase, else the record's current_phase with any `-complete` suffix removed;
 *   - sets current_phase (the ENTRY marker) and updated_at;
 *   - on the first write of a run sets schema_version 2 and fix_rounds / spec_revisions to 0;
 *   - entering 4-review, or any --loopback, sets final_verdict and peer_review_verdict_counts to
 *     null (#110), because a run under remediation has not concluded;
 *   - entering 4-review from any other phase increments review_rounds (a re-checkpoint of the
 *     same 4-review after an interruption is not a new round);
 *   - --loopback into 3-* is a Phase 4 fix round and into 1-ba* a spec revision: the budget in
 *     round-budget.mjs is checked first, a refusal exits 2 with the owner decision block on
 *     stdout and writes nothing, and an allowed round increments fix_rounds or spec_revisions;
 *     a --loopback anywhere else (the Phase 2.5 judge) counts nothing;
 *   - refreshes telemetry and effective_config (pipeline-telemetry.mjs);
 *   - runs check-status-record.mjs's checkRecords over the whole new record;
 *   - with --commit, stages and commits ONLY that status.json.
 *
 * FLAG appends a flags[] digest entry: a verdict over its cap is refused, a summary over its cap is
 * cut to the cap with an ellipsis. Both caps are read from the schema, never copied here.
 *
 * RERUN prints the `<phase-token>-rerun` event label for a /phase role, and with --status and
 * --verdict appends that event. The token prefix is what lets the phase-entry guard resolve it.
 *
 * QA-CONTRACT is the architectural tier's "after QA returns": the sha must name a commit in the
 * worktree, tasks.json satisfiability_proof must pass validate-pipeline-artifact.mjs's
 * groundSatisfiability, and only then is phase3_qa_test_commit recorded with a flags entry.
 *
 * EXIT CODES. 0 written (or printed). 2 REFUSED: a cap, the phase pattern, a round budget, or an
 * unmet QA contract; nothing was written. 1 usage, an unreadable input, or a failed commit after a
 * successful write (the message says which).
 */

import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { isMain, nativePath } from "./lib.mjs";
import { capsFromSchema, phasePatternFromSchema, checkRecords } from "./check-status-record.mjs";
import { telemetry, effectiveConfig } from "./pipeline-telemetry.mjs";
import { checkRoundBudget, STATUS_SCHEMA_VERSION } from "./round-budget.mjs";
import { groundSatisfiability } from "./validate-pipeline-artifact.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
export const SCHEMA_PATH = path.join(SCRIPT_DIR, "..", "schemas", "status.schema.json");

/** The /phase role to its rerun label. `--panel` moves a reviewer role to its Phase 4 label. */
export const RERUN_TOKENS = {
  ba: "1-ba-rerun",
  dba: "2-review-rerun",
  devops: "2-review-rerun",
  secops: "2-review-rerun",
  "design-review": "2-review-rerun",
  qa: "3a-qa-rerun",
  dev: "3b-dev-rerun",
  "peer-review": "4-review-rerun",
  librarian: "5-archive-rerun",
};
const PANEL_CAPABLE = new Set(["dba", "devops", "secops", "design-review", "qa"]);

export function rerunToken(role, { panel = false } = {}) {
  if (!Object.prototype.hasOwnProperty.call(RERUN_TOKENS, role)) {
    throw new RefusalError(`unknown /phase role ${JSON.stringify(role)}; expected one of ${Object.keys(RERUN_TOKENS).join(", ")}`, 1);
  }
  if (panel && PANEL_CAPABLE.has(role)) return "4-review-rerun";
  return RERUN_TOKENS[role];
}

export class RefusalError extends Error {
  constructor(message, code = 2, stdout = "") {
    super(message);
    this.code = code;
    this.stdout = stdout;
  }
}

let _schema;
function schemaFacts() {
  if (!_schema) {
    const doc = JSON.parse(readFileSync(SCHEMA_PATH, "utf8"));
    const caps = capsFromSchema(doc);
    const summaryCap = doc?.properties?.flags?.items?.properties?.summary?.maxLength;
    if (!Number.isInteger(summaryCap) || summaryCap <= 1) throw new Error("schema declares no usable maxLength for flags[].summary");
    _schema = { caps, summaryCap, phaseRe: phasePatternFromSchema(doc) };
  }
  return _schema;
}

/** Which round budget a loop-back into `phase` spends, or null. */
export function loopbackKind(phase) {
  if (/^3(a|b)?-/.test(phase) || phase === "3a" || phase === "3b") return "fix-round";
  if (/^1-ba/.test(phase)) return "spec-revision";
  return null;
}

function checkVerdict(v, field, caps) {
  if (v === undefined || v === null) return;
  if (typeof v !== "string" || v === "") throw new RefusalError(`${field}[].verdict must be a non-empty token`);
  if (v.length > caps[field]) {
    throw new RefusalError(
      `${field}[].verdict ${JSON.stringify(v)} is ${v.length} chars, over the schema cap of ${caps[field]}. A verdict is a TOKEN: write the verdict word and put the reasoning in the note.`,
    );
  }
}

/**
 * The ENTER transition, pure: returns the new record and what happened. Throws RefusalError.
 * `now` is injectable so a test can pin the timestamps.
 */
export function applyEnter(status, phase, opts = {}) {
  const { exitVerdict, exitPhase, note, loopback = false, now = new Date().toISOString(), config = {}, extra = {} } = opts;
  if (!status || typeof status !== "object" || Array.isArray(status)) throw new RefusalError("status.json is not an object", 1);
  const { caps, phaseRe } = schemaFacts();
  if (typeof phase !== "string" || !phaseRe.test(phase)) {
    throw new RefusalError(`phase ${JSON.stringify(phase)} does not match the schema's current_phase pattern ${phaseRe.source}`);
  }
  checkVerdict(exitVerdict, "events", caps);
  const st = structuredClone(status);
  const prior = typeof st.current_phase === "string" ? st.current_phase : null;
  const report = { phase, prior, exitEvent: null, cleared: false, reviewRounds: null, counter: null };

  let budget = null;
  const kind = loopback ? loopbackKind(phase) : null;
  if (kind) {
    budget = checkRoundBudget(st, kind);
    if (!budget.allowed) {
      const why =
        budget.next === null
          ? `the ${kind} counter is unreadable, so the round cannot be counted against the budget of ${budget.budget}`
          : `${kind} ${budget.next} is past the budget of ${budget.budget} at cost_class ${budget.costClass} and no owner_overrides entry covers it`;
      throw new RefusalError(`REFUSED loop-back into ${phase}: ${why}. Bring the owner the decision below; nothing was written.`, 2, `${budget.decision}\n`);
    }
  }

  if (st.schema_version === undefined || (Number.isInteger(st.schema_version) && st.schema_version < STATUS_SCHEMA_VERSION)) {
    st.schema_version = STATUS_SCHEMA_VERSION;
  }
  if (st.fix_rounds === undefined) st.fix_rounds = 0;
  if (st.spec_revisions === undefined) st.spec_revisions = 0;
  if (!Array.isArray(st.events)) {
    if (st.events !== undefined) throw new RefusalError(`status.json events is ${typeof st.events}, not an array`, 1);
    st.events = [];
  }

  if (exitVerdict !== undefined) {
    const label = exitPhase || (prior ? prior.replace(/-complete$/, "") : null);
    if (!label) throw new RefusalError("--exit-verdict needs --exit-phase: the record names no current_phase to close", 1);
    const ev = { phase: label, verdict: exitVerdict, at: now };
    if (note !== undefined) ev.note = note;
    st.events.push(ev);
    report.exitEvent = ev;
  }

  if (phase === "4-review" || loopback) {
    st.final_verdict = null;
    st.peer_review_verdict_counts = null;
    report.cleared = true;
  }
  if (phase === "4-review" && prior !== "4-review") {
    st.review_rounds = (Number.isInteger(st.review_rounds) && st.review_rounds >= 0 ? st.review_rounds : 0) + 1;
    report.reviewRounds = st.review_rounds;
  }
  if (kind) {
    const field = kind === "fix-round" ? "fix_rounds" : "spec_revisions";
    st[field] = budget.next;
    report.counter = { kind, field, value: budget.next, budget: budget.budget, override: Boolean(budget.override) };
  }
  Object.assign(st, extra);
  st.current_phase = phase;
  st.updated_at = now;
  refreshDerived(st, config);
  assertRecordClean(st);
  return { status: st, report };
}

function refreshDerived(st, config) {
  st.telemetry = telemetry(st);
  st.effective_config = effectiveConfig(config);
}

/** The whole record through the same checker the corpus walk uses; any finding refuses. */
function assertRecordClean(st) {
  const { caps, phaseRe } = schemaFacts();
  const r = checkRecords([{ file: "status.json", text: JSON.stringify(st) }], caps, phaseRe);
  const problems = [...r.unreadable, ...r.badevents, ...r.badflags, ...r.badphases, ...r.violations];
  if (problems.length) throw new RefusalError(`the record would not pass check-status-record: ${problems.join("; ")}`);
}

/** Append a flags[] digest entry, pure. */
export function applyFlag(status, { phase, agent, verdict, summary = "", now = new Date().toISOString() }) {
  const { caps, summaryCap } = schemaFacts();
  if (!phase || !agent) throw new RefusalError("flag needs --phase and --agent", 1);
  checkVerdict(verdict, "flags", caps);
  const st = structuredClone(status);
  if (st.flags === undefined) st.flags = [];
  if (!Array.isArray(st.flags)) throw new RefusalError(`status.json flags is ${typeof st.flags}, not an array`, 1);
  let s = String(summary);
  const truncated = s.length > summaryCap;
  if (truncated) s = `${s.slice(0, summaryCap - 1)}…`;
  const entry = { phase, agent };
  if (verdict !== undefined) entry.verdict = verdict;
  entry.summary = s;
  entry.at = now;
  st.flags.push(entry);
  assertRecordClean(st);
  return { status: st, entry, truncated };
}

/** Append a rerun event, pure. */
export function applyRerun(status, role, { verdict, note, panel = false, now = new Date().toISOString() }) {
  const { caps } = schemaFacts();
  const token = rerunToken(role, { panel });
  checkVerdict(verdict, "events", caps);
  const st = structuredClone(status);
  if (!Array.isArray(st.events)) st.events = [];
  const ev = { phase: token, verdict, at: now };
  if (note !== undefined) ev.note = note;
  st.events.push(ev);
  st.updated_at = now;
  st.telemetry = telemetry(st);
  assertRecordClean(st);
  return { status: st, token };
}

/** The QA contract check, pure over the parsed tasks.json. Returns the failures. */
export function qaContractFailures(tasks) {
  if (!tasks || typeof tasks !== "object" || Array.isArray(tasks)) {
    return ["tasks.json is absent or unreadable, so no satisfiability_proof can be read"];
  }
  return groundSatisfiability({ risk_tier: "architectural" }, tasks, false, []);
}

export function readStatus(file) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (e) {
    throw new RefusalError(`cannot read status ${file}: ${e.message}`, 1);
  }
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new RefusalError(`status ${file} is not JSON: ${e.message}`, 1);
  }
}

export function writeAtomic(file, obj) {
  const tmp = `${file}.tmp-${process.pid}`;
  writeFileSync(tmp, `${JSON.stringify(obj, null, 2)}\n`);
  renameSync(tmp, file);
}

/** Stage and commit ONLY this status.json. Returns the new short sha. */
export function commitStatus(file, status, label) {
  const dir = path.dirname(path.resolve(file));
  const base = path.basename(file);
  const issue = Number.isInteger(status.issue_number) ? status.issue_number : path.basename(dir);
  const git = (...args) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  try {
    git("add", "--", base);
    git("commit", "-q", "-m", `chore(pipeline): ${label} for #${issue}`, "--only", "--", base);
    return git("rev-parse", "--short", "HEAD").trim();
  } catch (e) {
    const detail = String((e.stderr || e.message || "")).trim().split("\n").slice(-2).join(" ");
    throw new RefusalError(`the record was WRITTEN but NOT committed: ${detail}`, 1);
  }
}

function readConfig(file) {
  const f = file || path.join(process.env.CLAUDE_PROJECT_DIR || process.cwd(), "pipeline.config.json");
  try {
    return JSON.parse(readFileSync(nativePath(f), "utf8"));
  } catch {
    return {};
  }
}

const USAGE =
  "usage:\n" +
  "  node checkpoint.mjs enter <phase> --status <status.json> [--exit-verdict V] [--exit-phase L] [--note N] [--loopback] [--commit] [--config <file>]\n" +
  "  node checkpoint.mjs flag --status <status.json> --phase P --agent A [--verdict V] [--summary S]\n" +
  "  node checkpoint.mjs rerun <role> [--panel] [--status <status.json> --verdict V [--note N]]\n" +
  "  node checkpoint.mjs qa-contract --sha <sha> --tasks <tasks.json> --status <status.json> [--worktree <dir>] [--commit]\n";

const VALUE_FLAGS = new Set(["--status", "--exit-verdict", "--exit-phase", "--note", "--config", "--phase", "--agent", "--verdict", "--summary", "--sha", "--tasks", "--worktree"]);
const BOOL_FLAGS = new Set(["--loopback", "--commit", "--panel"]);

export function parseArgs(argv) {
  const pos = [];
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (VALUE_FLAGS.has(a)) {
      if (i + 1 >= argv.length) throw new RefusalError(`${a} needs a value\n${USAGE}`, 1);
      o[a.slice(2)] = argv[++i];
    } else if (BOOL_FLAGS.has(a)) o[a.slice(2)] = true;
    else if (a.startsWith("--")) throw new RefusalError(`unknown flag ${a}\n${USAGE}`, 1);
    else pos.push(a);
  }
  return { pos, o };
}

export function main(argv, io = { out: (s) => process.stdout.write(s), err: (s) => process.stderr.write(s) }) {
  try {
    const { pos, o } = parseArgs(argv);
    const [cmd, arg] = pos;
    const statusFile = o.status ? nativePath(o.status) : null;
    const needStatus = () => {
      if (!statusFile) throw new RefusalError(`--status <status.json> is required\n${USAGE}`, 1);
      return readStatus(statusFile);
    };

    if (cmd === "enter") {
      if (!arg) throw new RefusalError(`enter needs a <phase>\n${USAGE}`, 1);
      const before = needStatus();
      const { status, report } = applyEnter(before, arg, {
        exitVerdict: o["exit-verdict"],
        exitPhase: o["exit-phase"],
        note: o.note,
        loopback: Boolean(o.loopback),
        config: readConfig(o.config),
      });
      writeAtomic(statusFile, status);
      const parts = [`checkpoint: entered ${arg}`];
      if (report.exitEvent) parts.push(`closed ${report.exitEvent.phase} ${report.exitEvent.verdict}`);
      if (report.cleared) parts.push("final_verdict cleared");
      if (report.reviewRounds !== null) parts.push(`review_rounds ${report.reviewRounds}`);
      if (report.counter) parts.push(`${report.counter.field} ${report.counter.value} of ${report.counter.budget}${report.counter.override ? " (owner override)" : ""}`);
      if (o.commit) parts.push(`committed ${commitStatus(statusFile, status, `checkpoint phase ${arg}`)}`);
      io.out(`${parts.join("; ")}\n`);
      return 0;
    }

    if (cmd === "flag") {
      const { status, truncated } = applyFlag(needStatus(), { phase: o.phase, agent: o.agent, verdict: o.verdict, summary: o.summary });
      writeAtomic(statusFile, status);
      io.out(`checkpoint: flag ${o.phase}/${o.agent} recorded${truncated ? " (summary cut to the cap)" : ""}\n`);
      return 0;
    }

    if (cmd === "rerun") {
      if (!arg) throw new RefusalError(`rerun needs a <role>\n${USAGE}`, 1);
      const token = rerunToken(arg, { panel: Boolean(o.panel) });
      if (statusFile) {
        if (o.verdict === undefined) throw new RefusalError("rerun --status needs --verdict", 1);
        const { status } = applyRerun(readStatus(statusFile), arg, { verdict: o.verdict, note: o.note, panel: Boolean(o.panel) });
        writeAtomic(statusFile, status);
      }
      io.out(`${token}\n`);
      return 0;
    }

    if (cmd === "qa-contract") {
      if (!o.sha || !o.tasks) throw new RefusalError(`qa-contract needs --sha and --tasks\n${USAGE}`, 1);
      const before = needStatus();
      const wt = nativePath(o.worktree || process.cwd());
      let full;
      try {
        if (!/^[0-9a-fA-F]{7,40}$/.test(o.sha)) throw new Error("not a hex sha");
        full = execFileSync("git", ["-C", wt, "rev-parse", "--verify", "--quiet", `${o.sha}^{commit}`], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
      } catch {
        throw new RefusalError(`QA contract REFUSED: ${JSON.stringify(o.sha)} names no commit in ${wt}. Halt and re-dispatch QA; do NOT dispatch Dev.`);
      }
      let tasks = null;
      const tasksFile = nativePath(o.tasks);
      if (existsSync(tasksFile)) {
        try {
          tasks = JSON.parse(readFileSync(tasksFile, "utf8"));
        } catch {
          tasks = null;
        }
      }
      const failures = qaContractFailures(tasks);
      if (failures.length) {
        throw new RefusalError(
          `QA contract REFUSED (#158): ${failures.join("; ")}. Halt and re-dispatch QA with test-discipline rule 12 quoted; do NOT dispatch Dev.`,
        );
      }
      const sp = tasks.satisfiability_proof;
      const n = (a) => (Array.isArray(a) ? a.length : 0);
      const st = structuredClone(before);
      st.phase3_qa_test_commit = full;
      st.updated_at = new Date().toISOString();
      const { status } = applyFlag(st, {
        phase: "3a-qa",
        agent: "qa",
        verdict: "CONTRACT_AUTHORED",
        summary: `contract ${full.slice(0, 12)}; proven ${n(sp.criteria_proven)}, unproven ${n(sp.criteria_unproven)}, configs ${n(sp.configs_run)}`,
      });
      writeAtomic(statusFile, status);
      let tail = "";
      if (o.commit) tail = `; committed ${commitStatus(statusFile, status, "record QA contract")}`;
      io.out(`checkpoint: QA contract ${full.slice(0, 12)} recorded${tail}\n`);
      return 0;
    }

    io.err(USAGE);
    return 1;
  } catch (e) {
    if (e instanceof RefusalError) {
      if (e.stdout) io.out(e.stdout);
      io.err(`checkpoint: ${e.message}\n`);
      return e.code;
    }
    io.err(`checkpoint: ${e.message}; nothing was written\n`);
    return 1;
  }
}

if (isMain("checkpoint.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
