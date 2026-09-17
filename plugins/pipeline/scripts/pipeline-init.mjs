#!/usr/bin/env node
/**
 * pipeline-init.mjs -- /pipeline Phase 0 as one command (#164 row 16).
 *
 *   node pipeline-init.mjs [--resume <n> | --issue <n>] [--dry-run | --experiment] [--no-fetch] [ask text...]
 *   node pipeline-init.mjs --argument-stdin [--no-fetch] <<'ARG'
 *   <the /pipeline argument, verbatim>
 *   ARG
 *
 * --argument-stdin reads the whole /pipeline argument from stdin and parses it exactly like argv,
 * split on whitespace. It is the form the prose uses: a pasted ask carrying quotes, `$` or
 * backticks never becomes a shell word, and a quoted heredoc expands nothing.
 *
 * WHY. Phase 0 was six prose steps plus the argument parse in the core: test for
 * pipeline.config.json, read `git status --short`, compute PIPELINE_BASE, fetch the integration
 * branch, ensure the artifact dir, write a status.json skeleton by hand and read the resume phase.
 * Each is fully determined by the checkout and the argument, and a wrong base or resume point
 * sends a whole run to the wrong tree or the wrong phase.
 *
 * IN ORDER, stopping at the first halt:
 *   1. `<toplevel>/pipeline.config.json` must exist, else HALT exit 2 (nothing else runs).
 *   2. `git status --short` must be empty, else HALT exit 3 with the lines in `dirty`. This runs
 *      BEFORE any record is written, so the pipeline's own record is never read as dirty work.
 *   3. pipeline_base is `<toplevel>/.pipeline`, absolute and native; artifact_dir is
 *      `<pipeline_base>/<n>` when the issue is known (the directory is created).
 *   4. `git fetch origin <integrationBranch>` (config key, default main) unless --no-fetch. A failed
 *      fetch does not halt; it is in `fetch.ok` and `warnings`, because a stale base is how false
 *      "this file does not exist" drift claims start.
 *   5. --resume: the record must exist (exit 1 otherwise) and resume_phase is its current_phase,
 *      the ENTRY marker, so that phase re-runs from the top. --issue: an existing record is left
 *      untouched and its current_phase reported; an absent one is written as the 0-setup skeleton
 *      through checkpoint.mjs's applyEnter (schema_version, round counters, telemetry, and the
 *      check-status-record pass). A fresh ask has no issue yet: nothing is written and the skeleton
 *      is returned in `status`.
 *   --dry-run and --experiment set experiment_mode and are stripped from the ask text. ask_text is
 *   cut to 200 characters and OMITTED, with a warning, when it carries a credential shape
 *   (knowledge-store.mjs's class table): the record is committed and archived verbatim.
 *
 * OUTPUT: one JSON object on stdout, always, including on a halt.
 *
 * EXIT CODES. 0 ready. 2 HALT: no pipeline.config.json. 3 HALT: the tree is dirty. 1 usage, not a git
 * repository, a --resume with no readable record, or a record the checkpoint refused.
 */

import { existsSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { isMain, nativePath, assertPathSegment } from "./lib.mjs";
import { applyEnter, writeAtomic } from "./checkpoint.mjs";
import { findCredentialMaterial } from "./knowledge-store.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
export const ASK_TEXT_MAX = 200;
const EXPERIMENT_FLAGS = new Set(["--dry-run", "--experiment"]);

function git(args, cwd) {
  const r = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (r.error) return { status: null, stdout: "", stderr: r.error.message };
  return { status: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

/** The argument parse, pure. Throws on usage. */
export function parseInitArgs(argv) {
  const a = { mode: "fresh", issue: null, experiment: false, fetch: true, ask: [] };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === "--resume" || t === "--issue") {
      if (a.mode !== "fresh") throw new Error("--resume and --issue are exclusive, and each is given once");
      if (i + 1 >= argv.length) throw new Error(`${t} needs an issue`);
      a.mode = t.slice(2);
      a.issue = assertPathSegment(argv[++i], t);
    } else if (EXPERIMENT_FLAGS.has(t)) a.experiment = true;
    else if (t === "--no-fetch") a.fetch = false;
    else if (t.startsWith("--")) throw new Error(`unknown flag ${t}`);
    else a.ask.push(t);
  }
  return a;
}

/** ask_text for the record: whitespace collapsed, capped, never credential-shaped. */
export function askText(words) {
  const s = words.join(" ").replace(/\s+/g, " ").trim();
  if (!s) return { text: null, warning: null };
  const hits = findCredentialMaterial(s).hits;
  if (hits.length) return { text: null, warning: `ask_text omitted: the ask carries a credential shape (${[...new Set(hits.map((h) => h.class))].join(", ")}); write a redacted summary by hand` };
  return { text: s.length > ASK_TEXT_MAX ? `${s.slice(0, ASK_TEXT_MAX - 1)}…` : s, warning: null };
}

function readConfig(root) {
  try {
    return JSON.parse(readFileSync(path.join(root, "pipeline.config.json"), "utf8"));
  } catch {
    return {};
  }
}

export function init(argv, { cwd = process.cwd(), now = new Date().toISOString(), stdin = () => readFileSync(0, "utf8") } = {}) {
  let tokens = argv;
  if (argv.includes("--argument-stdin")) {
    tokens = [...argv.filter((t) => t !== "--argument-stdin"), ...String(stdin()).split(/\s+/).filter(Boolean)];
  }
  const args = parseInitArgs(tokens);
  const r = {
    ok: false, halt: null, mode: args.mode, issue: args.issue, experiment_mode: args.experiment,
    ask_text: null, repo_root: null, pipeline_base: null, artifact_dir: null, integration_branch: null,
    branch: null, head: null, dirty: [], fetch: { ran: false, ok: null, ref: null, error: null },
    status_file: null, record: "none", resume_phase: null, status: null, warnings: [],
  };
  const top = git(["rev-parse", "--show-toplevel"], cwd);
  if (top.status !== 0) {
    r.error = `${cwd} is not inside a git repository`;
    return { code: 1, result: r };
  }
  const root = path.resolve(nativePath(top.stdout.trim()));
  r.repo_root = root;

  if (!existsSync(path.join(root, "pipeline.config.json"))) {
    r.halt = "no-config";
    r.error = `${path.join(root, "pipeline.config.json")} is absent: copy ${path.join(SCRIPT_DIR, "..", "pipeline.config.example.json")} to the checkout root and edit it, or move to the checkout that has one`;
    return { code: 2, result: r };
  }

  const st = git(["status", "--short"], root);
  const b = git(["rev-parse", "--abbrev-ref", "HEAD"], root);
  const h = git(["log", "-1", "--oneline"], root);
  r.branch = b.status === 0 ? b.stdout.trim() : null;
  r.head = h.status === 0 ? h.stdout.trim() : null;
  if (st.status !== 0) {
    r.error = `git status failed: ${st.stderr.trim()}`;
    return { code: 1, result: r };
  }
  r.dirty = st.stdout.split(/\r?\n/).filter((l) => l.trim() !== "");
  if (r.dirty.length) {
    r.halt = "dirty";
    return { code: 3, result: r };
  }

  const config = readConfig(root);
  const integration = typeof config.integrationBranch === "string" && config.integrationBranch.trim() ? config.integrationBranch.trim() : "main";
  r.integration_branch = integration;
  r.pipeline_base = path.join(root, ".pipeline");
  const ask = askText(args.ask);
  r.ask_text = ask.text;
  if (ask.warning) r.warnings.push(ask.warning);

  if (args.fetch) {
    r.fetch.ran = true;
    r.fetch.ref = `origin/${integration}`;
    const f = git(["fetch", "--quiet", "origin", integration], root);
    r.fetch.ok = f.status === 0;
    if (!r.fetch.ok) {
      r.fetch.error = f.stderr.trim().split("\n").slice(-1)[0] || `exit ${f.status}`;
      r.warnings.push(`git fetch origin ${integration} failed; Phase 2 would read a possibly stale origin/${integration}`);
    }
  }

  const skeleton = () => {
    const base = { issue_number: /^\d+$/.test(String(args.issue)) ? Number(args.issue) : null, started_at: now, branch: r.branch || "", events: [], flags: [] };
    if (r.ask_text) base.ask_text = r.ask_text;
    return applyEnter(base, "0-setup", { now, config }).status;
  };

  if (args.mode === "fresh") {
    r.status = skeleton();
    r.ok = true;
    return { code: 0, result: r };
  }

  r.artifact_dir = path.join(r.pipeline_base, args.issue);
  r.status_file = path.join(r.artifact_dir, "status.json");
  if (existsSync(r.status_file)) {
    let rec;
    try {
      rec = JSON.parse(readFileSync(r.status_file, "utf8"));
    } catch (e) {
      r.error = `${r.status_file} is not readable JSON: ${e.message}`;
      return { code: 1, result: r };
    }
    r.record = "existing";
    r.resume_phase = typeof rec.current_phase === "string" ? rec.current_phase : null;
    if (!r.resume_phase) {
      r.error = `${r.status_file} names no current_phase to resume`;
      return { code: 1, result: r };
    }
    r.ok = true;
    return { code: 0, result: r };
  }
  if (args.mode === "resume") {
    r.error = `--resume ${args.issue}: no record at ${r.status_file}`;
    return { code: 1, result: r };
  }
  mkdirSync(r.artifact_dir, { recursive: true });
  writeAtomic(r.status_file, skeleton());
  r.record = "written";
  r.resume_phase = "0-setup";
  r.ok = true;
  return { code: 0, result: r };
}

export function main(argv, io = { out: (s) => process.stdout.write(s), err: (s) => process.stderr.write(s) }) {
  try {
    const { code, result } = init(argv);
    io.out(`${JSON.stringify(result, null, 2)}\n`);
    return code;
  } catch (e) {
    io.err(`pipeline-init: ${e.message}\nusage: node pipeline-init.mjs [--argument-stdin] [--resume <n> | --issue <n>] [--dry-run | --experiment] [--no-fetch] [ask text...]\n`);
    return 1;
  }
}

if (isMain("pipeline-init.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
