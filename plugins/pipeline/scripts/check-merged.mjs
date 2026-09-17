#!/usr/bin/env node
/**
 * check-merged.mjs -- did issue N's change reach the integration branch? (Phase 5 entry, #164 row 30)
 *
 * WHY. The Phase 5 prose ran `git log origin/main --oneline | grep -q "#<issue>"`. Two defects,
 * both in the direction that matters:
 *   - `#12` matches inside `#123`, so issue 12 read as merged the moment 123 landed.
 *   - a squash merge whose subject carries the PR number and not the issue number never matches,
 *     so a merged change read as not merged and Phase 5 halted.
 *
 * THE ORDER OF EVIDENCE, strongest first:
 *   1. The PR, when one is known (--pr-url, else status.json pr_url): `gh pr view --json
 *      mergedAt,state`. mergedAt set is MERGED. A readable PR that is OPEN or CLOSED unmerged is
 *      NOT MERGED, and it is the only source that can say so.
 *   2. The branch head (--branch, else status.json branch), remote ref first then local: an
 *      ancestor of <remote>/<base> that is NOT on its first-parent line is MERGED (it arrived through
 *      a merge). A head on the first-parent line proves nothing: a branch with no commits of its own
 *      sits there, and so does a fast-forward. Not an ancestor proves nothing either (squash merge).
 *   3. A word-boundary match for `#N` in the subjects of <remote>/<base>: `#N` not followed by a
 *      digit. A hit is MERGED. No hit proves nothing, for the squash reason above.
 * Anything else is CANNOT TELL, never a guess.
 *
 *   node check-merged.mjs --issue <n> [--pr-url <url>] [--branch <b>] [--status <status.json>]
 *                         [--base main] [--remote origin] [--no-fetch]
 *
 * EXIT CODES. 0 merged. 2 not merged (the PR says so). 3 cannot tell. 1 usage.
 * status.json defaults to .pipeline/<issue>/status.json under the cwd and is optional.
 */

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { isMain, nativePath } from "./lib.mjs";

const USAGE =
  "usage: node check-merged.mjs --issue <n> [--pr-url <url>] [--branch <b>] [--status <status.json>] [--base main] [--remote origin] [--no-fetch]\n";

/** Run a command with an argv array. Never throws. */
export function run(cmd, args, cwd) {
  let r;
  try {
    r = spawnSync(cmd, args, { encoding: "utf8", ...(cwd ? { cwd } : {}) });
  } catch (e) {
    return { ran: false, status: null, stdout: "", stderr: String(e && e.message) };
  }
  if (r.error) return { ran: false, status: null, stdout: "", stderr: String(r.error.message) };
  return { ran: true, status: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

/** True when `subjects` (one per line) names issue `issue` as a whole reference. */
export function mentionsIssue(subjects, issue) {
  const n = String(issue).replace(/^#/, "");
  if (!/^\d+$/.test(n)) return false;
  const re = new RegExp(`#${n}(?![0-9])`);
  return re.test(String(subjects || ""));
}

function readStatus(file) {
  if (!file || !existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

/**
 * The decision, with every external call injected through `exec(cmd, args)`.
 * @returns {{code: 0|2|3, how: string, notes: string[]}}
 */
export function checkMerged({ issue, prUrl, branch, base = "main", remote = "origin", fetch = true, exec }) {
  const notes = [];
  const target = `${remote}/${base}`;

  if (prUrl) {
    const r = exec("gh", ["pr", "view", prUrl, "--json", "mergedAt,state"]);
    if (r.ran && r.status === 0) {
      let pr = null;
      try {
        pr = JSON.parse(r.stdout);
      } catch {
        notes.push(`gh pr view returned unparseable output for ${prUrl}`);
      }
      if (pr && (pr.mergedAt || pr.state === "MERGED")) {
        return { code: 0, how: `PR ${prUrl} merged at ${pr.mergedAt || "(state MERGED)"}`, notes };
      }
      if (pr && typeof pr.state === "string") {
        return { code: 2, how: `PR ${prUrl} is ${pr.state} and not merged`, notes };
      }
    } else {
      notes.push(`gh could not read ${prUrl}: ${(r.stderr || r.stdout || "no output").trim().split("\n")[0]}`);
    }
  }

  if (fetch) {
    const f = exec("git", ["fetch", "--quiet", remote, base]);
    if (!(f.ran && f.status === 0)) notes.push(`git fetch ${remote} ${base} failed; using the local ${target}`);
  }
  const t = exec("git", ["rev-parse", "--verify", "--quiet", `refs/remotes/${target}^{commit}`]);
  if (!(t.ran && t.status === 0)) {
    notes.push(`${target} does not resolve`);
    return { code: 3, how: "cannot tell", notes };
  }

  if (branch) {
    let head = null;
    for (const ref of [`refs/remotes/${remote}/${branch}`, `refs/heads/${branch}`]) {
      const h = exec("git", ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
      if (h.ran && h.status === 0 && h.stdout.trim()) {
        head = h.stdout.trim();
        break;
      }
    }
    if (head) {
      const a = exec("git", ["merge-base", "--is-ancestor", head, `refs/remotes/${target}`]);
      // An ancestor head proves a merge only when the head arrived through a merge. A head that is
      // on the target's own first-parent line is where the branch FORKED (a branch with no commits
      // of its own), or a fast-forward: the two are indistinguishable, so neither counts.
      const fp = exec("git", ["rev-list", "--first-parent", `refs/remotes/${target}`]);
      const onFirstParent = fp.ran && fp.status === 0 && fp.stdout.split("\n").includes(head);
      if (a.ran && a.status === 0 && fp.ran && fp.status === 0 && !onFirstParent) {
        return { code: 0, how: `branch ${branch} head ${head.slice(0, 12)} was merged into ${target}`, notes };
      }
      if (a.ran && a.status === 0) {
        notes.push(`branch ${branch} head ${head.slice(0, 12)} is on ${target}'s own first-parent line: a branch with no commits of its own and a fast-forward read the same, so it proves nothing`);
      } else {
        notes.push(`branch ${branch} head ${head.slice(0, 12)} is not an ancestor of ${target} (a squash merge also reads this way)`);
      }
    } else {
      notes.push(`branch ${branch} resolves neither on ${remote} nor locally`);
    }
  }

  const log = exec("git", ["log", "--format=%s", `refs/remotes/${target}`]);
  if (log.ran && log.status === 0) {
    if (mentionsIssue(log.stdout, issue)) return { code: 0, how: `a commit subject on ${target} references #${issue}`, notes };
    notes.push(`no commit subject on ${target} references #${issue}`);
  } else {
    notes.push(`git log ${target} failed`);
  }
  return { code: 3, how: "cannot tell", notes };
}

function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--issue") a.issue = argv[++i];
    else if (k === "--pr-url") a.prUrl = argv[++i];
    else if (k === "--branch") a.branch = argv[++i];
    else if (k === "--status") a.status = argv[++i];
    else if (k === "--base") a.base = argv[++i];
    else if (k === "--remote") a.remote = argv[++i];
    else if (k === "--no-fetch") a.noFetch = true;
    else a.unknown = k;
  }
  return a;
}

export function main(argv, { exec = run, cwd = process.cwd(), out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s) } = {}) {
  const a = parseArgs(argv);
  if (a.unknown || !a.issue || !/^[A-Za-z0-9-]+$/.test(String(a.issue))) {
    err(a.unknown ? `check-merged: unknown argument ${a.unknown}\n${USAGE}` : USAGE);
    return 1;
  }
  const statusFile = a.status ? nativePath(a.status) : join(cwd, ".pipeline", String(a.issue), "status.json");
  const status = readStatus(statusFile);
  const prUrl = a.prUrl || (status && typeof status.pr_url === "string" && status.pr_url) || "";
  const branch = a.branch || (status && typeof status.branch === "string" && status.branch) || "";
  const r = checkMerged({
    issue: a.issue,
    prUrl,
    branch,
    base: a.base || "main",
    remote: a.remote || "origin",
    fetch: !a.noFetch,
    exec: (cmd, args) => exec(cmd, args, cwd),
  });
  for (const n of r.notes) err(`check-merged: ${n}\n`);
  const word = r.code === 0 ? "MERGED" : r.code === 2 ? "NOT MERGED" : "CANNOT TELL";
  out(`${word}: #${a.issue}: ${r.how}\n`);
  return r.code;
}

if (isMain("check-merged.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
