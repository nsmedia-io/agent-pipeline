#!/usr/bin/env node
/**
 * isolated-tree.mjs -- does a Phase 4 panelist's own tree qualify as isolated (#164 row 11).
 *
 *   node isolated-tree.mjs check <tree> --dispatch <dispatch worktree> --sha <reviewed sha>
 *   node isolated-tree.mjs reach <path>
 *
 * WHY. shared/tracked-write-isolation.md carried these checks as prose a panelist ran by hand:
 * compare `rev-parse --absolute-git-dir` (and not --git-dir or --git-common-dir, each measured
 * wrong), count `ls-files`, confirm a clone was pinned, and walk every ancestor with an `ls -ld`
 * loop whose `&&` join was load-bearing (with `;` a missing path loops forever on `.`). Each clause
 * had a measured way to be misread. Every one is fully determined by the tree, so it runs here.
 *
 * CHECK qualifies the tree only when ALL hold:
 *   gitdir    `git -C <tree> rev-parse --absolute-git-dir` EXITS 0 and differs from the dispatch
 *             worktree's own. A git-less copy fails this outright; a copy of a linked worktree's
 *             `.git` FILE resolves to the dispatch gitdir and is refused; a tracked subdirectory of
 *             the dispatch tree is refused.
 *   tracked   `git -C <tree> ls-files` exits 0 with a non-zero count.
 *   sha       `git -C <tree> rev-parse HEAD` is the commit --sha names (resolved in the dispatch
 *             tree), so an unpinned clone that landed on a moved tip is refused.
 *   outside   the tree is not inside the dispatch worktree or the repository's main worktree.
 *   reach     the ancestor walk below reads SAFE.
 * It prints REGISTRY_NAME=<name> for a linked worktree: record that, never the path.
 *
 * REACH walks the realpath of <path> from the leaf to the filesystem root. SAFE when some component
 * denies other-execute, or the leaf denies both other-read and other-execute: reaching the tree
 * needs other-execute on EVERY component, so one denying component denies the chain. A path that
 * does not exist is refused by name (walk the parent you will create the tree under). POSIX modes
 * mean nothing on win32, so there the walk is UNMEASURED and refuses; a NOTE says so.
 *
 * EXIT CODES. 0 qualifies (check) or SAFE (reach). 2 does not qualify or UNSAFE, with one FAIL line
 * per reason. 1 usage.
 */

import { existsSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { isMain, nativePath } from "./lib.mjs";

function git(args, cwd) {
  const r = spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8" });
  if (r.error) return { status: null, stdout: "", stderr: r.error.message };
  return { status: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

function key(p, platform) {
  let abs = path.resolve(nativePath(p, platform));
  try {
    abs = realpathSync.native(abs);
  } catch {
    // compare the resolved spelling
  }
  return platform === "win32" ? abs.toLowerCase() : abs;
}

function inside(child, parent, platform) {
  const rel = path.relative(key(parent, platform), key(child, platform));
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

/**
 * The ancestor walk, pure over an injectable stat. Returns {safe, measured, chain, reason}.
 * chain entries are {path, mode} with mode as an octal string.
 */
export function walkReach(p, { platform = process.platform, stat = (x) => statSync(x), real = (x) => realpathSync.native(x) } = {}) {
  let leaf;
  try {
    leaf = real(path.resolve(nativePath(p, platform)));
  } catch {
    return { safe: false, measured: false, chain: [], reason: `${p} does not exist; walk the parent you will create it under` };
  }
  if (platform === "win32") {
    return { safe: false, measured: false, chain: [], reason: "POSIX modes are not meaningful on win32, so other-user reach is UNMEASURED here" };
  }
  const chain = [];
  let cur = leaf;
  for (;;) {
    const mode = stat(cur).mode & 0o7777;
    chain.push({ path: cur, mode: mode.toString(8).padStart(4, "0") });
    const up = path.dirname(cur);
    if (up === cur) break;
    cur = up;
  }
  const denying = chain.find((c) => (parseInt(c.mode, 8) & 0o001) === 0);
  const leafMode = parseInt(chain[0].mode, 8);
  if (denying) return { safe: true, measured: true, chain, reason: `${denying.path} (${denying.mode}) denies other-execute` };
  if ((leafMode & 0o005) === 0) return { safe: true, measured: true, chain, reason: `the leaf (${chain[0].mode}) denies other-read and other-execute` };
  return { safe: false, measured: true, chain, reason: "every component grants other-execute and the leaf grants other-read or other-execute" };
}

/** CHECK, over live git. Returns {qualifies, lines, registryName}. */
export function checkTree(tree, { dispatch, sha, platform = process.platform, walk = walkReach } = {}) {
  const lines = [];
  let ok = true;
  const pass = (s) => lines.push(`ok   ${s}`);
  const fail = (s) => {
    ok = false;
    lines.push(`FAIL ${s}`);
  };
  const t = path.resolve(nativePath(tree, platform));
  const d = path.resolve(nativePath(dispatch, platform));
  if (!existsSync(t)) {
    return { qualifies: false, lines: [`FAIL tree: ${t} does not exist`], registryName: null };
  }

  const tg = git(["rev-parse", "--absolute-git-dir"], t);
  const dg = git(["rev-parse", "--absolute-git-dir"], d);
  let registryName = null;
  if (tg.status !== 0) fail(`gitdir: git rev-parse --absolute-git-dir did not exit 0 in the tree (${tg.stderr.trim().split("\n")[0] || `exit ${tg.status}`}); a git-less copy is not isolated`);
  else if (dg.status !== 0) fail(`gitdir: the dispatch worktree ${d} has no readable gitdir, so nothing can be compared`);
  else if (key(tg.stdout.trim(), platform) === key(dg.stdout.trim(), platform)) fail(`gitdir: the tree resolves to the dispatch worktree's own gitdir ${dg.stdout.trim()} (a copy of a linked worktree, or a subdirectory of it)`);
  else {
    pass(`gitdir: ${tg.stdout.trim()} differs from the dispatch gitdir`);
    const m = /[\\/]worktrees[\\/]([^\\/]+)$/.exec(tg.stdout.trim());
    if (m) registryName = m[1];
  }

  const ls = git(["ls-files", "-z"], t);
  const count = ls.status === 0 ? ls.stdout.split("\0").filter(Boolean).length : 0;
  if (ls.status !== 0) fail(`tracked: git ls-files did not exit 0 in the tree`);
  else if (count === 0) fail("tracked: git ls-files lists 0 tracked files");
  else pass(`tracked: ${count} tracked files`);

  if (!sha || !/^[0-9a-fA-F]{7,40}$/.test(sha)) fail(`sha: --sha ${JSON.stringify(sha || "")} is not a hex commit id`);
  else {
    const want = git(["rev-parse", "--verify", "--quiet", `${sha}^{commit}`], d);
    const head = git(["rev-parse", "HEAD"], t);
    if (want.status !== 0) fail(`sha: ${sha} names no commit in the dispatch worktree`);
    else if (head.status !== 0) fail("sha: the tree's HEAD does not resolve");
    else if (head.stdout.trim() !== want.stdout.trim()) fail(`sha: the tree's HEAD is ${head.stdout.trim().slice(0, 12)}, not the reviewed ${want.stdout.trim().slice(0, 12)}; pin it with git -C <tree> checkout --detach ${sha}`);
    else pass(`sha: HEAD is the reviewed ${want.stdout.trim().slice(0, 12)}`);
  }

  const main = git(["worktree", "list", "--porcelain"], d);
  const mainPath = main.status === 0 ? (/^worktree (.+)$/m.exec(main.stdout) || [])[1] : null;
  const roots = [d, mainPath].filter(Boolean);
  const within = roots.find((r) => inside(t, r, platform));
  if (within) fail(`outside: the tree is inside ${within}; put it outside the repository root`);
  else pass("outside: the tree is outside the dispatch worktree and the main worktree");

  const w = walk(t, { platform });
  if (w.safe) pass(`reach: SAFE, ${w.reason}`);
  else fail(`reach: ${w.measured ? "UNSAFE" : "UNMEASURED"}, ${w.reason}`);
  for (const c of w.chain) lines.push(`     ${c.mode} ${c.path}`);

  return { qualifies: ok, lines, registryName };
}

const USAGE =
  "usage:\n" +
  "  node isolated-tree.mjs check <tree> --dispatch <dispatch worktree> --sha <reviewed sha>\n" +
  "  node isolated-tree.mjs reach <path>\n";

export function main(argv, io = { out: (s) => process.stdout.write(s), err: (s) => process.stderr.write(s) }) {
  const [cmd, ...rest] = argv;
  const pos = [];
  const o = {};
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "--dispatch" || rest[i] === "--sha") {
      if (i + 1 >= rest.length) {
        io.err(`isolated-tree: ${rest[i]} needs a value\n${USAGE}`);
        return 1;
      }
      o[rest[i].slice(2)] = rest[++i];
    } else if (rest[i].startsWith("--")) {
      io.err(`isolated-tree: unknown flag ${rest[i]}\n${USAGE}`);
      return 1;
    } else pos.push(rest[i]);
  }
  if (cmd === "reach" && pos.length === 1) {
    const w = walkReach(pos[0]);
    io.out(`${w.safe ? "SAFE" : w.measured ? "UNSAFE" : "UNMEASURED"}: ${w.reason}\n`);
    for (const c of w.chain) io.out(`  ${c.mode} ${c.path}\n`);
    return w.safe ? 0 : 2;
  }
  if (cmd === "check" && pos.length === 1 && o.dispatch && o.sha) {
    const r = checkTree(pos[0], { dispatch: o.dispatch, sha: o.sha });
    io.out(`QUALIFIES: ${r.qualifies ? "yes" : "no"}\n${r.lines.join("\n")}\n`);
    if (r.registryName) io.out(`REGISTRY_NAME=${r.registryName}\n`);
    return r.qualifies ? 0 : 2;
  }
  io.err(USAGE);
  return 1;
}

if (isMain("isolated-tree.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
