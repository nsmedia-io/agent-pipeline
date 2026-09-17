#!/usr/bin/env node
/**
 * worktree.mjs -- find or create an issue's Phase 3 worktree and seed its artifact dir (#164 row 10).
 *
 *   node worktree.mjs resolve --issue <n> [--seed-from <dir>] [--pipeline-base <dir>] [--repo <dir>]
 *   node worktree.mjs create  --issue <n> [--type fix|feat|chore --slug <s>] [--seed-from <dir>]
 *                             [--base-ref <ref>] [--pipeline-base <dir>] [--repo <dir>]
 *
 * WHY. The lookup was prose in four places (phase-3-impl.md, qa.md, dev.md, phase.md), each a
 * slightly different recipe: read tasks.json, else grep `git worktree list --porcelain` for the
 * branch, else `git worktree add` with a hand-built timestamp, then `cd && pwd` and a `cp ... ||
 * true` loop. A miss in any copy writes artifacts into the root checkout or into a stale tree, and
 * the ambiguous case ("if multiple match, halt") was stated in one of the four.
 *
 * RESOLVE, in order:
 *   1. `<pipeline-base>/<n>/tasks.json` worktree_path, when it names a registered, non-root worktree
 *      that is LIVE; any other path is reported and the lookup falls through;
 *   2. `git worktree list --porcelain`, the non-root worktrees whose branch matches the naming rule
 *      `refs/heads/(fix|feat|chore)/<n>-*`. Exactly one is the answer; two or more are AMBIGUOUS.
 *   The root checkout never qualifies: a branch checked out there is named and refused.
 *   LIVE means git does not mark the entry prunable AND `git -C <path> rev-parse --show-toplevel` is
 *   that path. A matching registration whose directory was deleted is STALE: exit 2, naming the
 *   entry and `git worktree prune`. Before this a deleted tree resolved, and recreating its artifact
 *   dir made a plain folder under the root checkout, so every git command there ran against the
 *   root. Nothing here creates a worktree path except `git worktree add`.
 *
 * CREATE resolves first and reuses what it finds. Otherwise it adds
 * `<root>/.claude/worktrees/<n>-phase3-<YYYYmmdd-HHMMSS>`: on the one existing local branch that
 * matches the rule, else on a new `<type>/<n>-<slug>` from `--base-ref` (default
 * `origin/<integrationBranch>` from pipeline.config.json, else origin/main). Two matching local
 * branches are AMBIGUOUS. `<root>` is the main worktree, so a caller inside a worktree never nests.
 *
 * SEEDING (both commands, only with --seed-from): spec.json, review.json, constraints.md, map.json
 * and design.json are copied into `<worktree>/.pipeline/<n>`. A file artifact-ownership.mjs calls
 * SEEDED is overwritten (the canonical copy is authoritative, e.g. a spec BA revised); any other is
 * copied only when absent, so a map or design the worktree already holds is kept.
 *
 * OUTPUT on stdout, absolute native paths: WORKTREE_PATH=, ARTIFACT_DIR=, BRANCH=, SOURCE=
 * (tasks.json | worktree-list | created | created-on-existing-branch), then one SEEDED=/KEPT=/
 * MISSING= line each when seeding ran. Notes (a stale tasks.json path, a missing seed) go to stderr.
 *
 * EXIT CODES. 0 resolved or created. 2 NONE (resolve found nothing), AMBIGUOUS (the candidates are
 * listed) or STALE (a matching registration is prunable or not a worktree root); nothing was created. 1 usage, not a git repository, or a git command failed.
 */

import { copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { isMain, nativePath, assertPathSegment } from "./lib.mjs";
import { ownershipOf } from "./artifact-ownership.mjs";

export const SEED_FILES = Object.freeze(["spec.json", "review.json", "constraints.md", "map.json", "design.json"]);
export const BRANCH_TYPES = Object.freeze(["fix", "feat", "chore"]);

export class WorktreeError extends Error {
  constructor(message, code = 1) {
    super(message);
    this.code = code;
  }
}

function git(args, cwd) {
  const r = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (r.error) throw new WorktreeError(`git ${args[0]} could not run: ${r.error.message}`);
  return { status: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

/** A path as an absolute, native, symlink-resolved key for comparison. */
export function pathKey(p, platform = process.platform) {
  let abs = path.resolve(nativePath(p, platform));
  try {
    abs = realpathSync.native(abs);
  } catch {
    // not on disk: compare the resolved spelling
  }
  return platform === "win32" ? abs.toLowerCase() : abs;
}

/** Parse `git worktree list --porcelain`. The first entry is the main worktree. */
export function parseWorktreeList(text) {
  const out = [];
  let cur = null;
  for (const line of String(text).split(/\r?\n/)) {
    if (line.startsWith("worktree ")) {
      cur = { path: line.slice(9), branch: null, head: null, bare: false, prunable: false };
      out.push(cur);
    } else if (cur && line.startsWith("branch ")) cur.branch = line.slice(7);
    else if (cur && line.startsWith("HEAD ")) cur.head = line.slice(5);
    else if (cur && line === "bare") cur.bare = true;
    else if (cur && (line === "prunable" || line.startsWith("prunable "))) cur.prunable = true;
  }
  return out.map((w, i) => ({ ...w, main: i === 0 }));
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** The naming rule: refs/heads/(fix|feat|chore)/<issue>-*. */
export function branchMatches(ref, issue) {
  return new RegExp(`^refs/heads/(${BRANCH_TYPES.join("|")})/${escapeRe(String(issue))}-`).test(String(ref || ""));
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

/** True when <p> exists and git reports it as its own worktree top level. */
export function isWorktreeRoot(p) {
  const abs = path.resolve(nativePath(p));
  if (!existsSync(abs)) return false;
  const r = spawnSync("git", ["-C", abs, "rev-parse", "--show-toplevel"], { encoding: "utf8" });
  return !r.error && r.status === 0 && pathKey(r.stdout.trim()) === pathKey(abs);
}

function listWorktrees(repo) {
  const r = git(["worktree", "list", "--porcelain"], repo);
  if (r.status !== 0) throw new WorktreeError(`not a git repository, or git worktree list failed: ${r.stderr.trim()}`);
  return parseWorktreeList(r.stdout);
}

/**
 * Pure over its inputs. Returns {code, worktree?, source?, candidates, notes}.
 * code 0 found, 2 none or ambiguous.
 */
export function resolveFrom({ issue, worktrees, tasksWorktreePath = null, rootOf = (p) => p, isRoot = isWorktreeRoot }) {
  const notes = [];
  const byKey = new Map(worktrees.map((w) => [pathKey(w.path), w]));
  const live = (w) => !w.prunable && isRoot(w.path);
  if (tasksWorktreePath) {
    const w = byKey.get(pathKey(rootOf(tasksWorktreePath)));
    if (w && !w.main && live(w)) return { code: 0, worktree: w, source: "tasks.json", candidates: [w], notes };
    if (w && w.main) notes.push(`tasks.json worktree_path names the root checkout (${w.path}), which never qualifies`);
    else if (w) notes.push(`tasks.json worktree_path ${w.path} is registered but STALE (prunable, or not a worktree root); falling back to the branch rule`);
    else notes.push(`tasks.json worktree_path ${tasksWorktreePath} is not a registered worktree (stale); falling back to the branch rule`);
  }
  const matching = worktrees.filter((w) => branchMatches(w.branch, issue));
  for (const w of matching.filter((x) => x.main)) {
    notes.push(`${w.branch.replace("refs/heads/", "")} is checked out in the root checkout ${w.path}, which never qualifies`);
  }
  const stale = matching.filter((w) => !w.main && !live(w));
  if (stale.length) {
    const names = stale.map((w) => `${w.path} [${w.branch}]`).join(", ");
    notes.push(`STALE: ${names} is registered but its directory is gone or is not a worktree root; run \`git worktree prune\` (or restore the directory), then run this again`);
    return { code: 2, candidates: stale, notes, stale: true };
  }
  const candidates = matching.filter((w) => !w.main);
  if (candidates.length === 1) return { code: 0, worktree: candidates[0], source: "worktree-list", candidates, notes };
  if (candidates.length > 1) {
    notes.push(`AMBIGUOUS: ${candidates.length} worktrees match refs/heads/(${BRANCH_TYPES.join("|")})/${issue}-*: ${candidates.map((w) => `${w.path} [${w.branch}]`).join(", ")}`);
    return { code: 2, candidates, notes, ambiguous: true };
  }
  notes.push(`NONE: no worktree for #${issue} (no usable tasks.json worktree_path, no non-root worktree on refs/heads/(${BRANCH_TYPES.join("|")})/${issue}-*)`);
  return { code: 2, candidates, notes, ambiguous: false };
}

/** Copy the seed files. Returns {seeded, kept, missing}. */
export function seedArtifacts(from, to) {
  const res = { seeded: [], kept: [], missing: [] };
  const src = path.resolve(nativePath(from));
  const dst = path.resolve(nativePath(to));
  if (pathKey(src) === pathKey(dst)) return res;
  mkdirSync(dst, { recursive: true });
  for (const name of SEED_FILES) {
    const f = path.join(src, name);
    if (!existsSync(f) || !statSync(f).isFile()) {
      res.missing.push(name);
      continue;
    }
    const target = path.join(dst, name);
    if (ownershipOf(name) !== "seeded" && existsSync(target)) {
      res.kept.push(name);
      continue;
    }
    copyFileSync(f, target);
    res.seeded.push(name);
  }
  return res;
}

function stamp(d = new Date()) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function integrationBranch(root) {
  const cfg = readJson(path.join(root, "pipeline.config.json"));
  const b = cfg && typeof cfg.integrationBranch === "string" && cfg.integrationBranch.trim();
  return b || "main";
}

const USAGE =
  "usage:\n" +
  "  node worktree.mjs resolve --issue <n> [--seed-from <dir>] [--pipeline-base <dir>] [--repo <dir>]\n" +
  "  node worktree.mjs create --issue <n> [--type fix|feat|chore --slug <s>] [--seed-from <dir>] [--base-ref <ref>] [--pipeline-base <dir>] [--repo <dir>]\n";

const VALUE_FLAGS = new Set(["--issue", "--type", "--slug", "--seed-from", "--base-ref", "--pipeline-base", "--repo"]);

export function main(argv, io = { out: (s) => process.stdout.write(s), err: (s) => process.stderr.write(s) }) {
  try {
    const [cmd, ...rest] = argv;
    const o = {};
    for (let i = 0; i < rest.length; i++) {
      if (!VALUE_FLAGS.has(rest[i])) throw new WorktreeError(`unknown argument ${rest[i]}\n${USAGE}`);
      if (i + 1 >= rest.length) throw new WorktreeError(`${rest[i]} needs a value\n${USAGE}`);
      o[rest[i].slice(2)] = rest[++i];
    }
    if (cmd !== "resolve" && cmd !== "create") throw new WorktreeError(USAGE);
    if (!o.issue) throw new WorktreeError(`--issue is required\n${USAGE}`);
    const issue = assertPathSegment(o.issue, "--issue");
    const repo = path.resolve(nativePath(o.repo || process.cwd()));
    const top = git(["rev-parse", "--show-toplevel"], repo);
    if (top.status !== 0) throw new WorktreeError(`${repo} is not inside a git repository`);
    const worktrees = listWorktrees(repo);
    const root = path.resolve(nativePath(worktrees[0].path));
    const base = path.resolve(nativePath(o["pipeline-base"] || path.join(top.stdout.trim(), ".pipeline")));
    const tasks = readJson(path.join(base, issue, "tasks.json"));
    const tasksPath = tasks && typeof tasks.worktree_path === "string" && tasks.worktree_path.trim() ? tasks.worktree_path.trim() : null;

    const r = resolveFrom({ issue, worktrees, tasksWorktreePath: tasksPath, rootOf: (p) => path.resolve(root, nativePath(p)) });
    let wt = r.worktree;
    let source = r.source;
    let branch = wt && wt.branch ? wt.branch.replace(/^refs\/heads\//, "") : null;

    if (r.code !== 0 && (cmd === "resolve" || r.ambiguous || r.stale)) {
      for (const n of r.notes) io.err(`worktree: ${n}\n`);
      io.out(`${r.stale ? "STALE" : r.ambiguous ? "AMBIGUOUS" : "NONE"}\n`);
      return 2;
    }
    if (r.code !== 0) {
      // CREATE. A branch already named by the rule, with no worktree, is reused rather than forked.
      for (const n of r.notes.filter((x) => !x.startsWith("NONE"))) io.err(`worktree: ${n}\n`);
      const refs = git(["for-each-ref", "--format=%(refname)", "refs/heads/"], repo);
      if (refs.status !== 0) throw new WorktreeError(`git for-each-ref failed: ${refs.stderr.trim()}`);
      const existing = refs.stdout.split(/\r?\n/).filter((ref) => branchMatches(ref, issue));
      const busy = new Set(worktrees.map((w) => w.branch).filter(Boolean));
      const free = existing.filter((ref) => !busy.has(ref));
      if (existing.length > 1) {
        io.err(`worktree: AMBIGUOUS: ${existing.length} local branches match refs/heads/(${BRANCH_TYPES.join("|")})/${issue}-*: ${existing.join(", ")}; nothing was created\n`);
        io.out("AMBIGUOUS\n");
        return 2;
      }
      if (existing.length === 1 && free.length === 0) {
        io.err(`worktree: ${existing[0]} is checked out in the root checkout; move it off there first. Nothing was created\n`);
        io.out("NONE\n");
        return 2;
      }
      const target = path.join(root, ".claude", "worktrees", `${issue}-phase3-${stamp()}`);
      let add;
      if (existing.length === 1) {
        branch = existing[0].replace(/^refs\/heads\//, "");
        add = git(["worktree", "add", "--quiet", target, branch], repo);
        source = "created-on-existing-branch";
      } else {
        if (!o.type || !o.slug) throw new WorktreeError(`no worktree or branch exists for #${issue}; create needs --type and --slug\n${USAGE}`);
        if (!BRANCH_TYPES.includes(o.type)) throw new WorktreeError(`--type must be one of ${BRANCH_TYPES.join(", ")}, got ${JSON.stringify(o.type)}`);
        if (!/^[a-z0-9][a-z0-9-]*$/.test(o.slug)) throw new WorktreeError(`--slug must be lowercase letters, digits and hyphens, got ${JSON.stringify(o.slug)}`);
        branch = `${o.type}/${issue}-${o.slug}`;
        const baseRef = o["base-ref"] || `origin/${integrationBranch(root)}`;
        add = git(["worktree", "add", "--quiet", "-b", branch, target, baseRef], repo);
        source = "created";
      }
      if (add.status !== 0) throw new WorktreeError(`git worktree add failed: ${add.stderr.trim()}`);
      wt = { path: target };
    } else {
      for (const n of r.notes) io.err(`worktree: ${n}\n`);
    }

    const abs = path.resolve(nativePath(wt.path));
    // Never write under a path that is not a live worktree root: creating it would put a plain
    // folder in the root checkout and send every later git command there.
    if (!isWorktreeRoot(abs)) {
      io.err(`worktree: STALE: ${abs} is not a worktree root; run \`git worktree prune\`, then run this again. Nothing was written\n`);
      io.out("STALE\n");
      return 2;
    }
    const artifactDir = path.join(abs, ".pipeline", issue);
    const lines = [`WORKTREE_PATH=${abs}`, `ARTIFACT_DIR=${artifactDir}`, `BRANCH=${branch || "(detached)"}`, `SOURCE=${source}`];
    if (o["seed-from"]) {
      const from = path.resolve(nativePath(o["seed-from"]));
      if (!existsSync(from)) io.err(`worktree: --seed-from ${from} does not exist; nothing was seeded\n`);
      const s = seedArtifacts(from, artifactDir);
      lines.push(`SEEDED=${s.seeded.join(",")}`, `KEPT=${s.kept.join(",")}`, `MISSING=${s.missing.join(",")}`);
      if (s.missing.includes("spec.json")) io.err(`worktree: spec.json is not in ${from}; Phase 3 has no spec to read\n`);
    } else {
      mkdirSync(artifactDir, { recursive: true });
    }
    io.out(`${lines.join("\n")}\n`);
    return 0;
  } catch (e) {
    io.err(`worktree: ${e.message}\n`);
    return e instanceof WorktreeError ? e.code : 1;
  }
}

if (isMain("worktree.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
