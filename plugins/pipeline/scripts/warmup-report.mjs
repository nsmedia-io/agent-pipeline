#!/usr/bin/env node
/**
 * warmup-report.mjs -- the facts /warmup reports, computed rather than typed (#164 row 26).
 *
 * WHY. warmup.md step 1 and step 3 were shell recipes hardcoding `origin/main` although
 * `integrationBranch` is a config key, and the role-domain table was restated in seven agent
 * contracts. This prints the git state against the CONFIGURED integration branch, the worktrees
 * and which of them hold a branch already merged, the open PRs and issues, and the knowledge-store
 * domains a role's warmup reads.
 *
 *   node warmup-report.mjs [--role <role>] [--spec <spec.json>] [--root <dir>] [--no-fetch] [--no-gh]
 *
 * OUTPUT, one fact per line: INTEGRATION-BRANCH, BRANCH, HEAD, IN-WORKTREE, DIRTY, DRIFT,
 * WORKTREES, MERGED-WORKTREE (one per candidate), GONE-WORKTREE, PR, ISSUE, IN-FLIGHT, DOMAINS.
 * A fact that could not be computed says so on its own line; it never disappears.
 *
 * MERGED means the worktree's branch head is an ancestor of <remote>/<base> and NOT on its
 * first-parent line (it arrived through a merge), the rule check-merged.mjs uses: a branch with no
 * commits of its own sits on that line too and proves nothing. A squash merge does not read as
 * merged here. Candidates are reported, never removed.
 *
 * EXIT CODES. 0 reported (including facts it could not compute). 1 usage: an unknown flag or role,
 * or a root that is not a git checkout.
 */

import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { isMain, nativePath } from "./lib.mjs";
import { run } from "./check-merged.mjs";

export const DOMAINS = ["data", "api", "frontend", "infrastructure", "security", "compliance", "architecture", "testing"];

/** Role -> warmup domains. "all" is every domain; "spec" is the spec's impacted_domains. */
export const ROLE_DOMAINS = {
  ba: "all",
  dba: ["data"],
  secops: ["security", "compliance"],
  devops: ["infrastructure"],
  qa: ["testing"],
  dev: "spec",
  design: ["frontend"],
  librarian: "all",
};

const ROLE_ALIASES = { design_review: "design", designreview: "design" };

export function normalizeRole(raw) {
  if (typeof raw !== "string") return null;
  const key = raw.toLowerCase().replace(/^pipeline:/, "").replace(/[^a-z_]/g, "");
  const role = ROLE_ALIASES[key] || key;
  return Object.hasOwn(ROLE_DOMAINS, role) ? role : null;
}

/** @returns {{domains: string[], why: string}} */
export function domainsFor(role, spec) {
  const rule = ROLE_DOMAINS[role];
  if (rule === "all") return { domains: DOMAINS, why: "all domains" };
  if (rule === "spec") {
    const d = spec && Array.isArray(spec.impacted_domains) ? spec.impacted_domains.filter((x) => typeof x === "string") : [];
    return d.length ? { domains: d, why: "spec impacted_domains" } : { domains: DOMAINS, why: "all domains (no spec impacted_domains resolved)" };
  }
  return { domains: rule, why: `the ${role} domains` };
}

export function integrationBranch(root) {
  const file = path.join(root, "pipeline.config.json");
  try {
    if (!existsSync(file)) return { branch: "main", source: "default" };
    const cfg = JSON.parse(readFileSync(file, "utf8"));
    const v = cfg && typeof cfg === "object" ? cfg.integrationBranch : undefined;
    if (typeof v === "string" && v.trim() !== "") return { branch: v.trim(), source: "pipeline.config.json integrationBranch" };
    return { branch: "main", source: "default" };
  } catch {
    return { branch: "main", source: "default (pipeline.config.json does not parse)" };
  }
}

/** `git worktree list --porcelain` -> [{ path, head, branch, prunable }]. */
export function parseWorktrees(text) {
  const out = [];
  let cur = null;
  for (const line of String(text || "").split("\n")) {
    if (line.startsWith("worktree ")) {
      cur = { path: line.slice(9), head: null, branch: null, prunable: false };
      out.push(cur);
    } else if (cur && line.startsWith("HEAD ")) cur.head = line.slice(5);
    else if (cur && line.startsWith("branch ")) cur.branch = line.slice(7).replace(/^refs\/heads\//, "");
    else if (cur && line.startsWith("prunable")) cur.prunable = true;
  }
  return out;
}

const firstLine = (s) => String(s || "").trim().split("\n")[0];

export function report({ root, role, spec, fetch = true, gh = true, remote = "origin", exec = run }) {
  const lines = [];
  const git = (...args) => exec("git", ["-C", root, ...args]);
  const { branch: base, source } = integrationBranch(root);
  const target = `${remote}/${base}`;
  lines.push(`INTEGRATION-BRANCH: ${base} (${source})`);

  const br = git("rev-parse", "--abbrev-ref", "HEAD");
  lines.push(`BRANCH: ${br.ran && br.status === 0 ? br.stdout.trim() : "unknown"}`);
  const head = git("log", "-1", "--format=%h %s");
  lines.push(`HEAD: ${head.ran && head.status === 0 ? head.stdout.trim() : "unknown (no commit)"}`);
  const gd = git("rev-parse", "--git-dir");
  const cd = git("rev-parse", "--git-common-dir");
  if (gd.ran && gd.status === 0 && cd.ran && cd.status === 0) {
    const inWt = path.resolve(root, gd.stdout.trim()) !== path.resolve(root, cd.stdout.trim());
    lines.push(`IN-WORKTREE: ${inWt ? "yes" : "no"}`);
  }
  const dirty = git("status", "--porcelain");
  if (dirty.ran && dirty.status === 0) {
    lines.push(`DIRTY: ${dirty.stdout.split("\n").filter((l) => l.trim()).length} path(s)`);
  }

  if (fetch) {
    const f = git("fetch", "--quiet", remote, base);
    if (!(f.ran && f.status === 0)) lines.push(`FETCH: failed (${firstLine(f.stderr) || "no output"}); ${target} may be stale`);
  }
  const t = git("rev-parse", "--verify", "--quiet", `refs/remotes/${target}^{commit}`);
  const targetOk = t.ran && t.status === 0;
  if (targetOk) {
    const d = git("rev-list", "--left-right", "--count", `HEAD...refs/remotes/${target}`);
    const m = d.ran && d.status === 0 ? /^(\d+)\s+(\d+)/.exec(d.stdout.trim()) : null;
    lines.push(m ? `DRIFT: ahead ${m[1]}, behind ${m[2]} vs ${target}` : `DRIFT: unknown (${firstLine(d.stderr) || "rev-list failed"})`);
  } else {
    lines.push(`DRIFT: unknown (${target} does not resolve)`);
  }

  const wl = git("worktree", "list", "--porcelain");
  if (wl.ran && wl.status === 0) {
    const trees = parseWorktrees(wl.stdout);
    lines.push(`WORKTREES: ${trees.length} registered`);
    const fp = targetOk ? git("rev-list", "--first-parent", `refs/remotes/${target}`) : null;
    const firstParent = new Set(fp && fp.ran && fp.status === 0 ? fp.stdout.split("\n").filter(Boolean) : []);
    const self = path.resolve(root);
    for (const w of trees) {
      if (w.prunable) {
        lines.push(`GONE-WORKTREE: ${w.path} (its directory is missing; git worktree prune drops the record)`);
        continue;
      }
      if (!targetOk || !w.branch || !w.head || path.resolve(w.path) === self || w.branch === base) continue;
      const anc = git("merge-base", "--is-ancestor", w.head, `refs/remotes/${target}`);
      if (anc.ran && anc.status === 0 && fp && fp.status === 0 && !firstParent.has(w.head)) {
        lines.push(`MERGED-WORKTREE: ${w.path} (${w.branch} was merged into ${target})`);
      }
    }
  } else {
    lines.push(`WORKTREES: unknown (${firstLine(wl.stderr) || "git worktree list failed"})`);
  }

  if (gh) {
    const prs = exec("gh", ["pr", "list", "--state", "open", "--limit", "15", "--json", "number,title,isDraft,headRefName,updatedAt"], root);
    const issues = exec("gh", ["issue", "list", "--state", "open", "--limit", "12", "--json", "number,title,updatedAt"], root);
    const parse = (r) => {
      if (!(r.ran && r.status === 0)) return null;
      try {
        const v = JSON.parse(r.stdout);
        return Array.isArray(v) ? v.sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt))) : null;
      } catch {
        return null;
      }
    };
    const p = parse(prs);
    const i = parse(issues);
    if (p === null && i === null) {
      lines.push(`IN-FLIGHT: unknown (gh: ${firstLine(prs.stderr) || "not available"})`);
    } else {
      for (const x of p || []) lines.push(`PR: #${x.number} ${x.isDraft ? "draft" : "open"} ${x.title} (${x.headRefName})`);
      for (const x of i || []) lines.push(`ISSUE: #${x.number} ${x.title}`);
      lines.push(`IN-FLIGHT: ${p ? p.length : "unknown"} open PR(s), ${i ? i.length : "unknown"} open issue(s)`);
    }
  }

  const r = role ? domainsFor(role, spec) : { domains: DOMAINS, why: "all domains (no role)" };
  lines.push(`DOMAINS: ${r.domains.join(" ")} (${r.why})`);
  return lines;
}

const USAGE =
  "usage: node warmup-report.mjs [--role <ba|dba|secops|devops|qa|dev|design|librarian>] [--spec <spec.json>] [--root <dir>] [--no-fetch] [--no-gh]\n";

export function main(argv, { exec = run, cwd = process.cwd(), out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s) } = {}) {
  const a = { fetch: true, gh: true };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--role" || k === "--spec" || k === "--root") a[k.slice(2)] = argv[++i];
    else if (k === "--no-fetch") a.fetch = false;
    else if (k === "--no-gh") a.gh = false;
    else {
      err(`warmup-report: unknown argument ${k}\n${USAGE}`);
      return 1;
    }
  }
  let role = null;
  if (a.role !== undefined) {
    role = normalizeRole(a.role);
    if (!role) {
      err(`warmup-report: unknown role "${a.role}"\n${USAGE}`);
      return 1;
    }
  }
  const top = exec("git", ["-C", a.root ? nativePath(a.root) : cwd, "rev-parse", "--show-toplevel"]);
  if (!(top.ran && top.status === 0)) {
    err(`warmup-report: not a git checkout (${firstLine(top.stderr) || "git unavailable"})\n`);
    return 1;
  }
  const root = nativePath(top.stdout.trim());
  let spec = null;
  if (a.spec) {
    try {
      spec = JSON.parse(readFileSync(nativePath(a.spec), "utf8"));
    } catch (e) {
      err(`warmup-report: ${a.spec} is not readable JSON (${e.message}); Dev falls back to all domains\n`);
    }
  }
  out(`${report({ root, role, spec, fetch: a.fetch, gh: a.gh, exec }).join("\n")}\n`);
  return 0;
}

if (isMain("warmup-report.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
