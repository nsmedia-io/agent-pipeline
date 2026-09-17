#!/usr/bin/env node
/**
 * deferral.mjs -- the deferral ledger, and it is TRACKER-AGNOSTIC on purpose.
 *
 * WHY. evidence.md rule 10 says deferring is an action: an item routed to a follow-up is not
 * deferred until it is WRITTEN somewhere durable. The pipeline has always said that and has
 * always spelled the "somewhere" as `gh issue create`, which quietly assumes every adopting
 * project has GitHub and a working `gh`. A project on GitLab, on a private Jira, or on nothing
 * at all had no legal way to satisfy a rule the panel enforces, so the rule degraded into
 * prose the moment it left this repo.
 *
 * So the ledger is a CONFIGURED destination, not a hardcoded command:
 *
 *   deferralTracker: "github"    (default) -> `gh issue create`, the URL is the ref
 *                    "gitlab"              -> `glab issue create`, the URL is the ref
 *                    "directory"           -> a committed markdown file, its path is the ref
 *   deferralDir:     "knowledge/deferred"  (default; read only in "directory" mode)
 *
 * The directory mode is the one that needs defending: a file in the repository is a worse
 * tracker than a tracker (no assignee, no state machine, no notification) and a far better one
 * than a sentence in a review artifact nobody opens again. It is also the only mode that works
 * with no network, no credentials and no vendor.
 *
 * FOUR COMMANDS:
 *   record  -- write the deferral where the config says, print the ref
 *   checklist -- write ALL of one issue's Phase 4 notes as ONE checklist entry, and a separate
 *              entry only for a note with a merge_class other than none or one the owner marked
 *              (--own). Before this, every note without a suggested_patch became its own tracker
 *              issue: measured on one consumer, one tooling change produced 35 of them.
 *   verify  -- is this string a resolvable deferral ref in this configuration? (the gate's
 *              question; imported by scripts/gate-pre-phase4.mjs rather than shelled out to)
 *   list    -- what is in the ledger (directory mode; remote trackers say so and stop)
 *
 * FAIL DIRECTIONS, each chosen rather than inherited:
 *   - `record` with the configured CLI ABSENT fails LOUDLY (exit 1) and names the remedy. It
 *     does NOT silently fall back to writing a file: a deferral the author believes is in the
 *     tracker and is actually in an untracked temp path is worse than a refusal, because the
 *     refusal is visible in the turn that caused it.
 *   - `verify` with the configured CLI ABSENT accepts a well-formed ref and prints a WARNING
 *     that existence was not checked. It is a GATE input, and a gate that halts a panel over
 *     a missing CLI on the machine the gate happens to run on is a gate that gets deleted.
 *   - `verify` on a ref the tracker's own CLI reports as NOT FOUND exits 2. Any OTHER CLI
 *     failure (auth, network, rate limit) warns and accepts, for the same reason as above:
 *     "I could not ask" is a different state from "I asked and it is not there".
 *
 * Zero dependencies, node only. Artifact and config values are never eval'd and never
 * interpolated into a shell string: every CLI call goes through spawnSync with an argv array.
 */

import { readFileSync, existsSync, mkdirSync, writeFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { assertPathSegment, isMain as isMainScript } from "./lib.mjs";
import { concernId, MERGE_CLASSES } from "./materiality.mjs";

const PROJECT_ROOT = process.env.CLAUDE_PROJECT_DIR || process.cwd();

// # CUSTOMIZE: `deferralTracker` and `deferralDir` in pipeline.config.json.
export const DEFAULT_TRACKER = "github";
export const DEFAULT_DEFERRAL_DIR = "knowledge/deferred";

/** tracker -> the CLI it needs, or null when it needs none. */
export const TRACKER_CLI = { github: "gh", gitlab: "glab", directory: null };

export function readPipelineConfig(root = PROJECT_ROOT) {
  const file = path.join(root, "pipeline.config.json");
  try {
    if (!existsSync(file)) return {};
    const cfg = JSON.parse(readFileSync(file, "utf8"));
    return cfg && typeof cfg === "object" && !Array.isArray(cfg) ? cfg : {};
  } catch {
    return {};
  }
}

/**
 * The configured tracker, or the default.
 *
 * An unknown value falls back to the default rather than throwing, matching every other knob in
 * this plugin (config-doctor.mjs is what tells the owner their value is unread).
 */
export function trackerFromConfig(cfg) {
  const t = cfg && cfg.deferralTracker;
  return typeof t === "string" && Object.prototype.hasOwnProperty.call(TRACKER_CLI, t)
    ? t
    : DEFAULT_TRACKER;
}

/**
 * The configured ledger directory as a repo-relative path, or the default.
 *
 * Refuses an absolute path and any `..` segment: this value names a directory the pipeline
 * WRITES committed files into, so a config edit must not be able to place them outside the
 * repository. The refusal is a fall back to the default, not a throw, so a bad value cannot
 * wedge a run; config-doctor.mjs reports the key.
 */
export function deferralDirFromConfig(cfg) {
  const d = cfg && cfg.deferralDir;
  if (typeof d !== "string" || d.trim() === "") return DEFAULT_DEFERRAL_DIR;
  const norm = d.replace(/\\/g, "/").replace(/^\.\//, "").replace(/\/+$/, "");
  if (norm === "" || norm.startsWith("/") || norm.split("/").includes("..")) {
    return DEFAULT_DEFERRAL_DIR;
  }
  return norm;
}

/** A filename-safe slug. Never empty: a title of pure punctuation still gets a name. */
export function slugify(title) {
  const s = String(title || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60)
    .replace(/-+$/, "");
  return s || "deferral";
}

/** `#123`, or an issue URL on either tracker. Format only; existence is a separate question. */
const HASH_REF = /^#\d+$/;
const URL_REF = /^https?:\/\/[^\s]+\/(?:-\/)?issues\/\d+(?:[?#][^\s]*)?$/;

export function looksLikeIssueRef(ref) {
  return typeof ref === "string" && (HASH_REF.test(ref.trim()) || URL_REF.test(ref.trim()));
}

/** The issue NUMBER inside a `#n` or a URL ref, as a string, or null. */
export function issueNumberOf(ref) {
  const s = String(ref || "").trim();
  if (HASH_REF.test(s)) return s.slice(1);
  const m = /\/issues\/(\d+)/.exec(s);
  return m ? m[1] : null;
}

/**
 * Resolve a directory-mode ref to an absolute path INSIDE the ledger dir, or false.
 *
 * TWO SPELLINGS ARE LEGAL and both are what a writer actually types: the repo-relative path
 * `record` printed (`knowledge/deferred/42-x.md`) and the bare filename (`42-x.md`). The first
 * resolves against the repository root, the second against the ledger dir, and only a candidate
 * that lands strictly inside the ledger dir is returned. Resolution is path arithmetic and
 * never a filesystem walk, so this answers the same way in a checkout where the file is absent.
 */
function resolveLedgerRef(root, dir, rel) {
  const base = path.resolve(root, dir);
  const withSep = base.endsWith(path.sep) ? base : base + path.sep;
  const clean = rel.replace(/\\/g, "/").replace(/^\.\//, "");
  for (const target of [path.resolve(root, clean), path.resolve(base, clean)]) {
    if (target !== base && target.startsWith(withSep)) return target;
  }
  return false;
}

/** Run a CLI. Returns { ran, status, out } and never throws. */
// `cwd` is the PROJECT ROOT, never the caller's working directory: `gh issue view 412` resolves
// the repository from the git remote of the directory it runs in, and the gate that calls verify
// runs from the orchestrator's checkout, which can be a different repository altogether (measured:
// a real issue reported as "does not exist" because gh was asked from the plugin's own worktree).
function runCli(cmd, args, cwd) {
  let r;
  try {
    r = spawnSync(cmd, args, { encoding: "utf8", ...(cwd ? { cwd } : {}) });
  } catch (e) {
    return { ran: false, status: null, out: String(e && e.message) };
  }
  if (r.error) return { ran: false, status: null, out: String(r.error.message) };
  return { ran: true, status: r.status, out: `${r.stdout || ""}${r.stderr || ""}` };
}

// Presence is probed by RUNNING the tool, not by looking it up: `command -v` is a shell
// builtin (spawnSync would report ENOENT for it on every host, which is not an answer about
// `gh`), and a PATH walk would have to reimplement PATHEXT and the executable-bit rules.
// `--version` is the one subcommand both CLIs answer offline and unauthenticated.
function cliPresent(cmd) {
  if (!cmd) return true;
  const r = runCli(cmd, ["--version"]);
  return r.ran && r.status === 0;
}

const NOT_FOUND = /(could not resolve to an? issue|not found|404|does not exist|no issue)/i;

/**
 * THE GATE'S QUESTION, and the one function scripts/gate-pre-phase4.mjs imports.
 *
 * @returns {{ok: boolean, code: 0|2, message: string, warning: string|null}}
 *   code 0 -- this is a resolvable deferral ref in this configuration
 *   code 2 -- it cannot be one (empty, a bare sentence, a path outside the ledger, a file that
 *             is not there, an issue the tracker says does not exist)
 */
export function verifyDeferralRef(ref, opts = {}) {
  const tracker = opts.tracker || DEFAULT_TRACKER;
  const root = opts.root || PROJECT_ROOT;
  const dir = opts.dir || DEFAULT_DEFERRAL_DIR;
  const value = typeof ref === "string" ? ref.trim() : "";

  if (value === "") {
    return {
      ok: false,
      code: 2,
      message: "no tracker_ref recorded (empty or absent)",
      warning: null,
    };
  }

  if (tracker === "directory") {
    if (/^https?:\/\//i.test(value) || HASH_REF.test(value)) {
      return {
        ok: false,
        code: 2,
        message: `deferralTracker is "directory", so the ref must be a file under ${dir}/, not an issue reference: ${JSON.stringify(value)}`,
        warning: null,
      };
    }
    const abs = resolveLedgerRef(root, dir, value);
    if (!abs) {
      return {
        ok: false,
        code: 2,
        message: `deferral ref is not inside the configured deferralDir (${dir}/): ${JSON.stringify(value)}`,
        warning: null,
      };
    }
    if (!existsSync(abs)) {
      return {
        ok: false,
        code: 2,
        message: `deferral ref names no file under ${dir}/: ${JSON.stringify(value)}`,
        warning: null,
      };
    }
    return { ok: true, code: 0, message: `deferral ledger entry ${value}`, warning: null };
  }

  // github / gitlab: the format is the first question, existence the second.
  if (!looksLikeIssueRef(value)) {
    return {
      ok: false,
      code: 2,
      message: `not a ${tracker} issue reference (expected "#<n>" or an issue URL): ${JSON.stringify(value.slice(0, 120))}`,
      warning: null,
    };
  }

  const cli = TRACKER_CLI[tracker];
  if (opts.checkExistence === false) {
    return {
      ok: true,
      code: 0,
      message: `${value} is a well-formed ${tracker} issue reference`,
      warning: `existence was NOT checked: the caller asked for a format check only.`,
    };
  }
  if (!cliPresent(cli)) {
    return {
      ok: true,
      code: 0,
      message: `${value} is a well-formed ${tracker} issue reference`,
      warning: `existence was NOT checked: \`${cli}\` is not available here. The format is right; whether the issue exists is unverified.`,
    };
  }

  // A URL names its repository and goes to the CLI untouched; only a bare `#n` leans on the
  // project root's remote. Reducing a URL to its number would ask whatever repo the cwd's
  // remote points at, which is the false negative the cwd rule above also closes.
  const target = URL_REF.test(value) ? value : issueNumberOf(value) || value;
  const r = runCli(cli, ["issue", "view", target], root);
  if (r.ran && r.status === 0) {
    return { ok: true, code: 0, message: `${value} exists`, warning: null };
  }
  if (r.ran && NOT_FOUND.test(r.out)) {
    return {
      ok: false,
      code: 2,
      message: `${cli} reports that ${value} does not exist`,
      warning: null,
    };
  }
  // Asked and could not get an answer (auth, network, a non-issue repo). Not the same state as
  // "asked and it is not there", and it must not halt a panel.
  return {
    ok: true,
    code: 0,
    message: `${value} is a well-formed ${tracker} issue reference`,
    warning: `existence was NOT checked: \`${cli}\` could not answer (${(r.out || "no output").trim().split("\n")[0].slice(0, 120)}).`,
  };
}

// ---- record -----------------------------------------------------------------

function composeBody({ body, evidence, reason }) {
  let out = String(body || "").replace(/\s+$/, "");
  if (reason) out += `\n\n## Why it was deferred\n\n${reason}`;
  if (evidence) out += `\n\n## Evidence\n\n${evidence}`;
  return `${out}\n`;
}

/**
 * Write the ledger entry for "directory" mode. Returns the repo-relative path (the ref).
 *
 * The frontmatter is small on purpose: a human reads this file, and a five-key header is the
 * most a reader will keep in view while reading the body underneath it.
 */
export function recordToDirectory({ root, dir, issue, title, body, evidence, reason, now }) {
  const base = path.resolve(root, dir);
  mkdirSync(base, { recursive: true });
  const stamp = (now || new Date()).toISOString();
  // The issue id reaches this from argv and is interpolated into a FILENAME. slugify() sanitizes
  // the title; nothing sanitized this, so `--issue ../../etc/x` would have written outside the
  // ledger. assertPathSegment throws on a separator or a `..`, which is the loud direction: a
  // ledger entry written somewhere nobody will look for it is the defect this script exists to
  // prevent, wearing a path.
  const safeIssue = assertPathSegment(issue, "--issue");
  const name = `${safeIssue}-${slugify(title)}.md`;
  const rel = path.posix.join(dir, name);
  const front =
    `---\n` +
    `title: ${JSON.stringify(String(title))}\n` +
    `source_issue: ${JSON.stringify(safeIssue)}\n` +
    `created: ${stamp}\n` +
    `status: open\n` +
    `tracker: directory\n` +
    `---\n\n`;
  writeFileSync(path.join(base, name), front + composeBody({ body, evidence, reason }), "utf8");
  return rel;
}

function firstUrl(text) {
  const m = /(https?:\/\/\S+)/.exec(String(text || ""));
  return m ? m[1].trim() : null;
}

/** @returns {{ref: string, tracker: string}} @throws on a missing CLI or a failed create. */
export function recordDeferral({ tracker, root, dir, issue, title, body, evidence, reason, now }) {
  if (tracker === "directory") {
    return { ref: recordToDirectory({ root, dir, issue, title, body, evidence, reason, now }), tracker };
  }
  const cli = TRACKER_CLI[tracker];
  if (!cliPresent(cli)) {
    throw new Error(
      `deferralTracker is "${tracker}" but \`${cli}\` is not on PATH, so the deferral cannot be ` +
        `written and this is NOT recorded anywhere. Install ${cli} and re-run, or set ` +
        `"deferralTracker": "directory" in pipeline.config.json to keep the ledger in the repo ` +
        `(default ${DEFAULT_DEFERRAL_DIR}/). Refusing to invent a destination: a deferral you ` +
        `believe is filed and is not is worse than one that refused loudly.`,
    );
  }
  const text = composeBody({ body, evidence, reason });
  const args =
    tracker === "github"
      ? ["issue", "create", "--title", String(title), "--body", text]
      : ["issue", "create", "--title", String(title), "--description", text, "--yes"];
  // Created in the PROJECT ROOT's repository, never the caller's cwd: an orchestrator running
  // from its own checkout would otherwise file the deferral against the wrong remote.
  const r = runCli(cli, args, root);
  if (!r.ran || r.status !== 0) {
    throw new Error(`${cli} issue create failed (status ${r.status}): ${(r.out || "").trim().slice(0, 400)}`);
  }
  const url = firstUrl(r.out);
  if (!url) {
    throw new Error(
      `${cli} issue create reported success but printed no issue URL, so there is no ref to ` +
        `record. Output: ${(r.out || "").trim().slice(0, 200)}`,
    );
  }
  return { ref: url, tracker };
}

// ---- checklist --------------------------------------------------------------

const splitIds = (v) => (typeof v === "string" ? v.split(",").map((x) => x.trim()).filter(Boolean) : []);

/**
 * Every NOTE in a merged peer-review.json, as [{ role, id, concern }]. A note is a concern that is
 * not one of its block's open_blocker_ids. A concern carrying a suggested_patch is left out as
 * applied in the same turn, unless its id is in `unapplied` (the patch did not apply).
 */
export function collectNotes(peerReview, { unapplied = [] } = {}) {
  const out = [];
  if (!peerReview || typeof peerReview !== "object") return out;
  for (const [role, block] of Object.entries(peerReview)) {
    if (!block || typeof block !== "object" || Array.isArray(block) || typeof block.verdict !== "string") continue;
    const openIds = block.materiality && Array.isArray(block.materiality.open_blocker_ids) ? block.materiality.open_blocker_ids : [];
    const open = new Set(openIds);
    const concerns = Array.isArray(block.concerns) ? block.concerns : [];
    concerns.forEach((concern, index) => {
      if (!concern || typeof concern !== "object" || Array.isArray(concern)) return;
      const id = concernId(concern, role, index);
      if (open.has(id)) return;
      const patched = typeof concern.suggested_patch === "string" && concern.suggested_patch.trim() !== "";
      if (patched && !unapplied.includes(id)) return;
      out.push({ role, id, concern });
    });
  }
  return out;
}

/** Split notes into the one checklist and the ones that earn their own tracker entry. */
export function partitionNotes(notes, { own = [] } = {}) {
  const checklist = [];
  const ownEntries = [];
  for (const n of notes) {
    const mc = typeof n.concern.merge_class === "string" ? n.concern.merge_class.trim().toLowerCase() : "";
    const hasClass = MERGE_CLASSES.includes(mc) && mc !== "none";
    (hasClass || own.includes(n.id) ? ownEntries : checklist).push(n);
  }
  return { checklist, own: ownEntries };
}

function oneLine(v, max = 300) {
  const t = String(v ?? "").replace(/\s+/g, " ").trim();
  return t.length > max ? `${t.slice(0, max - 3)}...` : t;
}

function ratingOf(c) {
  return ["severity", "likelihood", "harm", "merge_class"].map((k) => `${k} ${c[k] ?? "unrated"}`).join(", ");
}

/** The checklist body: one unchecked box per note, with its role, id, ratings and location. */
export function renderChecklist(issue, notes) {
  const lines = [
    `Review notes from the Phase 4 panel on #${issue}. Each one shipped as a note: none blocked the merge under the materiality rule. Tick a box when the note is done or deliberately dropped.`,
    "",
  ];
  for (const n of notes) {
    const loc = n.concern.location ? ` (${oneLine(n.concern.location, 120)})` : "";
    const text = oneLine(n.concern.description || n.concern.must_satisfy || "(no description)");
    lines.push(`- [ ] **${n.role} ${n.id}**${loc}: ${text} [${ratingOf(n.concern)}]`);
  }
  return lines.join("\n");
}

/**
 * Record one issue's notes: ONE checklist entry, plus one entry per own-issue note.
 * `record` is injectable so a test can count calls without a tracker.
 * @returns {{checklist: string|null, own: Array<{id: string, ref: string}>, counts: object}}
 */
export function recordChecklist({ tracker, root, dir, issue, peerReview, own = [], unapplied = [], now, record = recordDeferral }) {
  const notes = collectNotes(peerReview, { unapplied });
  const parts = partitionNotes(notes, { own });
  const result = { checklist: null, own: [], counts: { notes: notes.length, checklist: parts.checklist.length, own: parts.own.length } };
  if (parts.checklist.length > 0) {
    result.checklist = record({
      tracker, root, dir, issue, now,
      title: `Deferred review notes for #${issue}`,
      body: renderChecklist(issue, parts.checklist),
      reason: "Phase 4 notes: real findings that did not block the merge under the materiality rule. One checklist per issue, not one issue per note.",
      evidence: `peer-review.json of #${issue}: ${parts.checklist.map((n) => n.id).join(", ")}`,
    }).ref;
  }
  for (const n of parts.own) {
    const ref = record({
      tracker, root, dir, issue, now,
      title: `#${issue} ${n.role} ${n.id}: ${oneLine(n.concern.description || n.id, 80)}`,
      body: `${n.concern.description || ""}\n\nMust satisfy: ${n.concern.must_satisfy || "(not stated)"}\n\nRatings: ${ratingOf(n.concern)}`,
      reason: own.includes(n.id)
        ? "The owner marked this note for its own issue."
        : `A note with merge_class ${n.concern.merge_class}: it did not block this merge, and what it could cost earns its own issue.`,
      evidence: n.concern.location || `peer-review.json of #${issue}, ${n.id}`,
    }).ref;
    result.own.push({ id: n.id, ref });
  }
  return result;
}

// ---- list -------------------------------------------------------------------

/** Ledger entries in directory mode: [{ path, title, status, created }]. */
export function listLedger(root, dir) {
  const base = path.resolve(root, dir);
  let names;
  try {
    names = readdirSync(base).filter((n) => n.endsWith(".md")).sort();
  } catch {
    return [];
  }
  const out = [];
  for (const name of names) {
    const abs = path.join(base, name);
    try {
      if (!statSync(abs).isFile()) continue;
    } catch {
      continue;
    }
    let text = "";
    try {
      text = readFileSync(abs, "utf8").slice(0, 2000);
    } catch {
      /* unreadable: still list it, with no metadata */
    }
    const field = (key) => {
      const m = new RegExp(`^${key}:\\s*(.*)$`, "m").exec(text);
      if (!m) return "";
      return m[1].trim().replace(/^"(.*)"$/, "$1");
    };
    out.push({
      path: path.posix.join(dir, name),
      title: field("title"),
      status: field("status"),
      created: field("created"),
    });
  }
  return out;
}

// ---- argv + I/O -------------------------------------------------------------

const USAGE =
  `usage:\n` +
  `  node deferral.mjs record --issue <n> --title "<t>" --body-file <path> [--evidence "<text>"] [--reason "<text>"]\n` +
  `  node deferral.mjs checklist --issue <n> --peer-review <peer-review.json> [--own <id,id>] [--unapplied <id,id>] [--dry-run]\n` +
  `  node deferral.mjs verify <ref> [--no-existence-check]\n` +
  `  node deferral.mjs list\n` +
  `\n` +
  `routing comes from pipeline.config.json: deferralTracker (github | gitlab | directory) and,\n` +
  `in directory mode, deferralDir (default ${DEFAULT_DEFERRAL_DIR}).\n`;

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--issue") args.issue = argv[++i];
    else if (a === "--title") args.title = argv[++i];
    else if (a === "--body-file") args.bodyFile = argv[++i];
    else if (a === "--body") args.body = argv[++i];
    else if (a === "--evidence") args.evidence = argv[++i];
    else if (a === "--reason") args.reason = argv[++i];
    else if (a === "--root") args.root = argv[++i];
    else if (a === "--no-existence-check") args.noExistence = true;
    else if (a === "--peer-review") args.peerReview = argv[++i];
    else if (a === "--own") args.own = argv[++i];
    else if (a === "--unapplied") args.unapplied = argv[++i];
    else if (a === "--dry-run") args.dryRun = true;
    else if (a.startsWith("--")) args.unknown = a;
    else args._.push(a);
  }
  return args;
}

export function main(argv) {
  const args = parseArgs(argv);
  if (args.unknown) {
    process.stderr.write(`deferral: unknown flag ${args.unknown}\n${USAGE}`);
    return 1;
  }
  const command = args._[0];
  const root = args.root ? path.resolve(args.root) : PROJECT_ROOT;
  const cfg = readPipelineConfig(root);
  const tracker = trackerFromConfig(cfg);
  const dir = deferralDirFromConfig(cfg);

  if (command === "record") {
    if (!args.issue || !args.title) {
      process.stderr.write(`deferral record: --issue and --title are required\n${USAGE}`);
      return 1;
    }
    let body = args.body || "";
    if (args.bodyFile) {
      try {
        body = readFileSync(path.resolve(root, args.bodyFile), "utf8");
      } catch (e) {
        process.stderr.write(`deferral record: cannot read --body-file: ${e.message}\n`);
        return 1;
      }
    }
    if (!args.bodyFile && !args.body) {
      process.stderr.write(`deferral record: --body-file (or --body) is required\n${USAGE}`);
      return 1;
    }
    try {
      const { ref } = recordDeferral({
        tracker,
        root,
        dir,
        issue: args.issue,
        title: args.title,
        body,
        evidence: args.evidence,
        reason: args.reason,
      });
      process.stdout.write(`${ref}\n`);
      return 0;
    } catch (e) {
      process.stderr.write(`deferral record: ${e.message}\n`);
      return 1;
    }
  }

  if (command === "checklist") {
    if (!args.issue || !args.peerReview) {
      process.stderr.write(`deferral checklist: --issue and --peer-review are required\n${USAGE}`);
      return 1;
    }
    let peerReview;
    try {
      peerReview = JSON.parse(readFileSync(path.resolve(root, args.peerReview), "utf8"));
    } catch (e) {
      process.stderr.write(`deferral checklist: cannot read --peer-review: ${e.message}\n`);
      return 1;
    }
    const own = splitIds(args.own);
    const unapplied = splitIds(args.unapplied);
    if (args.dryRun) {
      const parts = partitionNotes(collectNotes(peerReview, { unapplied }), { own });
      process.stdout.write(`${renderChecklist(args.issue, parts.checklist)}\n\nown issues: ${parts.own.map((n) => n.id).join(", ") || "none"}\n`);
      return 0;
    }
    try {
      const r = recordChecklist({ tracker, root, dir, issue: args.issue, peerReview, own, unapplied });
      if (r.counts.notes === 0) process.stdout.write("no notes to defer\n");
      if (r.checklist) process.stdout.write(`checklist\t${r.checklist}\n`);
      for (const o of r.own) process.stdout.write(`issue\t${o.id}\t${o.ref}\n`);
      return 0;
    } catch (e) {
      process.stderr.write(`deferral checklist: ${e.message}\n`);
      return 1;
    }
  }

  if (command === "verify") {
    const ref = args._[1];
    const v = verifyDeferralRef(ref, {
      tracker,
      root,
      dir,
      checkExistence: args.noExistence ? false : undefined,
    });
    if (v.warning) process.stdout.write(`WARNING: ${v.warning}\n`);
    if (v.ok) {
      process.stdout.write(`OK: ${v.message}\n`);
      return 0;
    }
    process.stderr.write(`NOT A DEFERRAL REF: ${v.message}\n`);
    return 2;
  }

  if (command === "list") {
    if (tracker !== "directory") {
      process.stdout.write(
        `deferralTracker is "${tracker}", so the ledger is REMOTE: list it with \`${TRACKER_CLI[tracker]} issue list\`.\n`,
      );
      return 0;
    }
    const entries = listLedger(root, dir);
    if (entries.length === 0) {
      process.stdout.write(`no deferrals recorded under ${dir}/\n`);
      return 0;
    }
    for (const e of entries) {
      process.stdout.write(`${e.path}\t[${e.status || "?"}]\t${e.title || "(untitled)"}\n`);
    }
    return 0;
  }

  process.stderr.write(USAGE);
  return 1;
}

if (isMainScript("deferral.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
