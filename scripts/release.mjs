#!/usr/bin/env node
// Tags a release and publishes its GitHub release, from facts already in the repo.
//
// Why it exists: releases 0.1.0 to 0.46.0 shipped with no tag and no GitHub release, because the
// checklist ended at the version bump and nothing did the rest. They were backfilled by hand on
// 2026-09-17. Every input is already decided by then (the version in plugin.json, the merge commit
// that carries it, that version's CHANGELOG section, the previous tag), so this is a script and a
// workflow, not a step anyone has to remember.
//
//   node scripts/release.mjs             # tag v<version>, push the tag, create the release
//   node scripts/release.mjs --dry-run   # print the plan and the notes; change nothing
//
// Runs from the repo root on main (the release workflow runs it on every push to main). Safe to run
// again: an existing tag is reused, an existing release is left alone.
//
// Exit codes: 0 released, already released, or dry run; 1 refused (manifests disagree, no
// CHANGELOG section, the version never landed on HEAD's first-parent history, or the existing tag
// points at a different commit); 2 a git or gh command failed.
//
// RELEASE_GH names the gh binary (tests point it at a stub; a path ending in .mjs runs under node).

import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

const DRY_RUN = process.argv.includes("--dry-run");
const PLUGIN = "plugins/pipeline/.claude-plugin/plugin.json";
const MARKET = ".claude-plugin/marketplace.json";
const CHANGELOG = "plugins/pipeline/CHANGELOG.md";

function refuse(msg) {
  console.error(`release: REFUSED: ${msg}`);
  process.exit(1);
}

function run(cmd, args, { allowFail = false, env } = {}) {
  let bin = cmd;
  let argv = args;
  if (cmd === "gh") {
    bin = process.env.RELEASE_GH || "gh";
    if (bin.endsWith(".mjs")) {
      argv = [bin, ...args];
      bin = process.execPath;
    }
  }
  const r = spawnSync(bin, argv, { encoding: "utf8", env: { ...process.env, ...env } });
  if (r.error || (r.status !== 0 && !allowFail)) {
    console.error(`release: FAILED: ${cmd} ${args.join(" ")}`);
    console.error((r.error?.message ?? r.stderr ?? "").trim());
    process.exit(2);
  }
  return { status: r.status, out: (r.stdout ?? "").trim() };
}
const git = (...args) => run("git", args).out;

function readJson(p) {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch (err) {
    refuse(`cannot read ${p} (${err.message})`);
  }
}

// Numeric x.y.z comparison; tags that are not plain semver are ignored.
const SEMVER = /^v(\d+)\.(\d+)\.(\d+)$/;
function cmp(a, b) {
  const x = a.match(SEMVER).slice(1).map(Number);
  const y = b.match(SEMVER).slice(1).map(Number);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}

// ── The version, and that both manifests say it ─────────────────────────────────────────────────
const plugin = readJson(PLUGIN);
const market = readJson(MARKET);
const version = plugin.version;
if (!/^\d+\.\d+\.\d+$/.test(version ?? "")) refuse(`${PLUGIN} version "${version}" is not x.y.z`);
const entry = (market.plugins ?? []).find((p) => p.name === plugin.name);
if (market.metadata?.version !== version || entry?.version !== version) {
  refuse(`${MARKET} does not advertise ${version}; run node scripts/sync-manifests.mjs`);
}
const tag = `v${version}`;

// ── Its CHANGELOG section ───────────────────────────────────────────────────────────────────────
const lines = readFileSync(CHANGELOG, "utf8").split(/\r?\n/);
const start = lines.findIndex((l) => /^## /.test(l) && l.split(/\s+/)[1] === version);
if (start < 0) refuse(`${CHANGELOG} has no "## ${version}" section`);
let end = lines.findIndex((l, i) => i > start && /^## /.test(l));
if (end < 0) end = lines.length;
const section = lines.slice(start + 1, end).join("\n").trim();
if (!section) refuse(`${CHANGELOG} section "## ${version}" is empty`);

// ── The commit: the first commit on HEAD's first-parent line that carries this version ──────────
// Walks the commits that touched plugin.json newest first and keeps the oldest of the unbroken run
// that carries this version, so a later commit that edits plugin.json without bumping it does not
// move the tag. Same rule the 2026-09-17 backfill used.
let commit = null;
for (const c of git("log", "--first-parent", "--format=%H", "HEAD", "--", PLUGIN).split("\n").filter(Boolean)) {
  const shown = run("git", ["show", `${c}:${PLUGIN}`], { allowFail: true });
  let v = null;
  try {
    v = JSON.parse(shown.out).version;
  } catch {
    // unreadable at that commit: treat as a different version
  }
  if (v !== version) break;
  commit = c;
}
if (!commit) refuse(`HEAD's first-parent history never committed ${PLUGIN} at ${version}`);

// ── Tags: does this one exist, which is the previous, is this the latest ────────────────────────
const tags = git("tag", "--list", "v*").split("\n").filter((t) => SEMVER.test(t));
const existing = tags.includes(tag) ? git("rev-list", "-n", "1", tag) : null;
if (existing && existing !== commit) {
  refuse(`${tag} already points at ${existing.slice(0, 7)}, not ${commit.slice(0, 7)}; resolve it by hand`);
}
const others = tags.filter((t) => t !== tag);
const previous = others.filter((t) => cmp(t, tag) < 0).sort(cmp).pop() ?? null;
const latest = others.every((t) => cmp(t, tag) < 0);

const originUrl = git("remote", "get-url", "origin");
const repo =
  process.env.GITHUB_REPOSITORY || (originUrl.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?$/) ?? [])[1];
const compare = previous && repo ? `\n\n**Full diff:** https://github.com/${repo}/compare/${previous}...${tag}` : "";
const notes = `${section}${compare}`;
const title = `agent-pipeline ${version}`;

console.log(`release: ${tag} at ${commit.slice(0, 7)} (previous ${previous ?? "none"}, latest ${latest})`);

if (DRY_RUN) {
  console.log(`release: dry run; tag ${existing ? "exists" : "would be created"}; notes follow\n`);
  console.log(notes);
  process.exit(0);
}

// ── Tag, push, release ──────────────────────────────────────────────────────────────────────────
if (!existing) {
  const date = git("log", "-1", "--format=%cI", commit);
  run("git", ["tag", "-a", tag, commit, "-m", title], { env: { GIT_COMMITTER_DATE: date } });
  console.log(`release: tagged ${tag}`);
}
run("git", ["push", "origin", `refs/tags/${tag}`]);

if (run("gh", ["release", "view", tag], { allowFail: true }).status === 0) {
  console.log(`release: ${tag} release already exists; nothing to do`);
  process.exit(0);
}
const notesFile = join(mkdtempSync(join(tmpdir(), "release-")), "notes.md");
writeFileSync(notesFile, notes);
run("gh", [
  "release", "create", tag, "--verify-tag", "--title", title, "--notes-file", notesFile, `--latest=${latest}`,
]);
console.log(`release: published ${title}`);
