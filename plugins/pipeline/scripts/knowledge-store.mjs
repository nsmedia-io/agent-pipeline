#!/usr/bin/env node
// knowledge-store.mjs — dependency-free CLI over a project's `knowledge/` folder.
// Search, write, list living-context docs, and archive finished pipeline runs. No network, no embeddings.

import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from "node:fs";
import { isMain as isMainScript, assertPathSegment } from "./lib.mjs";
import { join, resolve, relative, basename, isAbsolute, sep } from "node:path";

const COLLECTIONS = ["living-context", "issue-archive", "decisions"];
// Pipeline artifacts folded into an issue archive, in phase order; each read only if present.
const ARCHIVE_ARTIFACTS = ["spec", "map", "review", "tasks", "impl-report", "peer-review", "status"];
// The subset PRODUCED IN the Phase 3 worktree rather than seeded into it. This list MIRRORS the
// ownership split in the Phase 4 sync step of commands/pipeline.md and has to: the staleness
// check below is what proves that sync actually ran. `status` is deliberately absent -- the
// orchestrator owns it, and the canonical copy being AHEAD of the worktree's is the correct
// state, not a divergence.
const WORKTREE_PRODUCED = ["map", "tasks", "impl-report", "peer-review"];
// The escape hatch is an ENV VAR and not a flag, so it reaches archiveIssue identically through
// both entry points; archive-pipeline.mjs is documented as a thin re-dispatch and a flag only
// one of the two parsed would make that false.
const ALLOW_STALE_ENV = "PIPELINE_ARCHIVE_ALLOW_STALE";

const HELP = `knowledge-store.mjs — file-based knowledge store (no deps, no network)

Usage:
  knowledge-store.mjs --search "<terms>" [--domain <d>] [--collection <c>] [--root <dir>]
  knowledge-store.mjs --write --file <path.json> [--collection <c>] [--supersede <slug>] [--root <dir>]
  knowledge-store.mjs --archive-issue <n> --from <artifact-dir> [--root <dir>]
  knowledge-store.mjs --list [--collection <c>] [--root <dir>]

Collections: ${COLLECTIONS.join(" | ")}  (default: living-context)
--archive-issue always writes to issue-archive and takes no --collection.
Knowledge dir defaults to <root>/knowledge; <root> defaults to the current directory.`;

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const eq = a.indexOf("=");
    if (eq !== -1) { out[a.slice(2, eq)] = a.slice(eq + 1); continue; }
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next !== undefined && !next.startsWith("--")) { out[key] = next; i++; }
    else out[key] = true;
  }
  return out;
}

function fail(msg) {
  console.error(`Error: ${msg}\n`);
  console.error(HELP);
  process.exit(1);
}

const rootDir = (args) => (typeof args.root === "string" ? resolve(args.root) : resolve(process.cwd()));
const collectionDir = (args, name) => join(rootDir(args), "knowledge", name);
const readJson = (p) => { try { return JSON.parse(readFileSync(p, "utf8")); } catch { return null; } };
const listJsonFiles = (dir) =>
  existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".json")).map((f) => join(dir, f)) : [];

// Shape-tolerant display + search across living-context docs, issue archives, and decisions.
const isArchive = (doc) => doc && typeof doc === "object" && "archived_at" in doc;

const str = (v) => (typeof v === "string" ? v : "");
function displayFields(doc, path) {
  const fb = basename(path, ".json");
  if (isArchive(doc))
    return { title: doc.spec?.title ?? `Issue #${doc.issue_number ?? fb}`, status: "archived", updated: doc.archived_at ?? "-" };
  return { title: str(doc?.title) || fb, status: str(doc?.status) || "-", updated: doc?.last_updated ?? "-" };
}
function haystack(doc) {
  if (isArchive(doc)) return JSON.stringify(doc);
  const tags = Array.isArray(doc?.tags) ? doc.tags.join(" ") : "";
  return `${str(doc?.title)}\n${tags}\n${str(doc?.content)}`.trim() || JSON.stringify(doc);
}

// Hide superseded docs. For the living-context current|superseded vocabulary this is exactly
// status === "current"; it also keeps decisions (which may use other status words) searchable.
const passesStatusFilter = (doc) => isArchive(doc) || doc?.status !== "superseded";

function snippet(text, words) {
  const flat = text.replace(/\s+/g, " ").trim();
  const lower = flat.toLowerCase();
  let idx = -1;
  for (const w of words) {
    const i = lower.indexOf(w);
    if (i !== -1 && (idx === -1 || i < idx)) idx = i;
  }
  const start = idx <= 40 ? 0 : idx - 40;
  return (start > 0 ? "..." : "") + flat.slice(start, start + 160) + (start + 160 < flat.length ? "..." : "");
}

function cmdSearch(args) {
  if (typeof args.search !== "string" || !args.search.trim()) fail("--search requires quoted terms");
  const collection = typeof args.collection === "string" ? args.collection : "living-context";
  if (!COLLECTIONS.includes(collection)) fail(`unknown --collection '${collection}'`);
  const domain = typeof args.domain === "string" ? args.domain.toLowerCase() : null;
  const words = args.search.toLowerCase().split(/\s+/).filter(Boolean);
  const results = [];
  for (const path of listJsonFiles(collectionDir(args, collection))) {
    const doc = readJson(path);
    if (!doc || !passesStatusFilter(doc)) continue;
    if (domain && typeof doc.domain === "string" && doc.domain.toLowerCase() !== domain) continue;
    const hay = haystack(doc).toLowerCase();
    const title = displayFields(doc, path).title.toLowerCase();
    let score = 0;
    for (const w of words) score += (hay.split(w).length - 1) + (title.includes(w) ? 5 : 0);
    if (score > 0) results.push({ path, doc, score });
  }
  results.sort((a, b) => b.score - a.score);
  if (results.length === 0) return void console.log(`No matches for "${args.search}" in ${collection}.`);
  for (const r of results) {
    const { title, status } = displayFields(r.doc, r.path);
    console.log(`* ${title}  [${status}]\n  ${snippet(haystack(r.doc), words)}\n  ${r.path}\n`);
  }
}

function cmdWrite(args) {
  if (typeof args.file !== "string") fail("--write requires --file <path.json>");
  const src = resolve(args.file);
  const doc = readJson(src);
  if (!doc) fail(`could not read or parse JSON at ${src}`);
  if (typeof doc.title !== "string" || !doc.title.trim()) fail('document is missing a "title"');
  if (typeof doc.status !== "string" || !doc.status.trim()) fail('document is missing a "status"');
  // Validated against the same allowlist the read paths use, and not only for symmetry: this is
  // the one path that CREATES a directory from the value, so an unchecked `../..` run would
  // write outside knowledge/ entirely.
  const collection = typeof args.collection === "string" ? args.collection : "living-context";
  if (!COLLECTIONS.includes(collection)) fail(`unknown --collection '${collection}'`);
  const dir = collectionDir(args, collection);
  mkdirSync(dir, { recursive: true });
  if (typeof args.supersede === "string") {
    const slug = args.supersede.endsWith(".json") ? args.supersede : `${args.supersede}.json`;
    const old = readJson(join(dir, slug));
    if (!old) fail(`--supersede: no ${collection} file '${args.supersede}'`);
    old.status = "superseded";
    old.last_updated = new Date().toISOString();
    writeFileSync(join(dir, slug), JSON.stringify(old, null, 2) + "\n");
    console.log(`Superseded ${join(dir, slug)}`);
  }
  if (!doc.last_updated) doc.last_updated = new Date().toISOString();
  const dest = join(dir, basename(src));
  writeFileSync(dest, JSON.stringify(doc, null, 2) + "\n");
  console.log(`Wrote ${dest} [${doc.status}]`);
}

const REDACTED_ABSOLUTE = "<redacted-absolute-path>";
// The absolute shapes a value may OPEN with: a POSIX root, and a Windows drive root in either
// slash. The same two the AC34 walk in test-pipeline-telemetry.sh reddens on, so what this
// rewrites and what that refuses are one predicate rather than two that can drift apart.
// The trailing run is the SPAN, not the whole value -- see LEADING_SPAN's comment below.
const LEADING_SPAN = /^(?:\/|[A-Za-z]:[\\/])[^\s"']*/;
const DRIVE_VALUE = /^[A-Za-z]:[\\/]/;
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// A path under the repo root becomes repo-relative; anything else absolute becomes the marker.
// Never dropped: the reader can still see that a path was there and where it pointed.
function redactPath(value, rootAbs) {
  if (DRIVE_VALUE.test(value) && sep === "/") return REDACTED_ABSOLUTE; // foreign-platform absolute
  const rel = relative(rootAbs, value);
  if (rel === "") return ".";
  if (rel === ".." || rel.startsWith(".." + sep) || isAbsolute(rel)) return REDACTED_ABSOLUTE;
  return rel.split(sep).join("/");
}

// Redaction is BY VALUE SHAPE over the whole document, never by key name: `worktree_path` is
// the key that leaked once, and the next one will be a key nobody thought to list. It happens
// HERE because knowledge/issue-archive/<n>.json is committed, and on a contributor's machine
// an absolute path is that contributor's home directory. status.schema.json's writer
// prohibition covers status.json alone, while tasks.json and impl-report.json carry
// worktree_path too and cross this same boundary; a rule stated on the writers has to be
// restated for every future artifact, and a rule stated here does not.
//
// THE SPAN, NOT THE VALUE (#59). A value that opens with an absolute path has only that PATH
// rewritten; whatever followed it survives, so `/tmp/qa-34-mutate (detached HEAD at abc123)`
// archives as `<redacted-absolute-path> (detached HEAD at abc123)` rather than losing the
// prose too. The earlier rule replaced the whole value and destroyed two pieces of environment
// evidence in #34's archive that were never leaks -- a mutation worktree under /tmp and
// `/bin/bash (system bash 3.2)`. A predicate that cannot tell a home directory from a system
// binary is refusing correct work, and this repo's test for a guardrail is whether you can
// name the correct work it refuses. The leak guard itself is UNCHANGED and deliberately so:
// the span is still redacted by SHAPE, not by key name, and no root was added to a blocklist.
//
// DELIBERATELY NOT COVERED. An absolute path embedded mid-string is rewritten only where the
// run starts at the repo root or at a POSIX home prefix, so `cd /Users/x/repo && ...` is
// caught and `/opt/vendor/bin` inside a sentence is not; UNC paths (\\server\share); `~/x`,
// which is not absolute until a shell expands it; and a value spelled in different case than
// the repo root on a case-insensitive filesystem, which redacts rather than relativizes.
// Object KEYS are redacted on the same predicate, and two keys that redact to the same marker
// collapse into one -- accepted, because losing a duplicate key beats shipping a home
// directory, and no pipeline artifact schema keys on a path.
function redactAbsolutePaths(value, rootAbs, counter) {
  // A run starting at the repo root or at a home directory, stopping at whitespace or a quote.
  const embedded = new RegExp(`(?:${escapeRe(rootAbs)}|/(?:Users|home)/[^/\\s"']+)[^\\s"']*`, "g");
  const redactString = (s) => {
    // Leading span first, then the mid-string pass over what is left. Both stop at the same
    // whitespace-or-quote boundary, so a value that IS a bare path is still rewritten whole --
    // the span simply happens to be the entire string in that case.
    let out = s;
    const lead = LEADING_SPAN.exec(out);
    if (lead) out = redactPath(lead[0], rootAbs) + out.slice(lead[0].length);
    out = out.replace(embedded, (m) => redactPath(m, rootAbs));
    if (out !== s) counter.count++;
    return out;
  };
  const walk = (v) => {
    if (typeof v === "string") return redactString(v);
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [redactString(k), walk(x)]));
    return v;
  };
  return walk(value);
}

// Key order is not a difference. Both copies are written by JSON.stringify from the same
// authors, but a re-serialized artifact can legitimately reorder keys, and a staleness check
// that HALTS archival must not halt on that.
const stable = (v) =>
  v === null || typeof v !== "object"
    ? JSON.stringify(v)
    : Array.isArray(v)
      ? "[" + v.map(stable).join(",") + "]"
      : "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + stable(v[k])).join(",") + "}";

// #58: THE CANONICAL DIRECTORY CAN BE STALE, and archiving it faithfully records a state that
// never merged. On #34 the archive carried an impl-report predating two rounds of fixes and a
// map.json token count the run had already corrected, because the Phase 4 sync runs once, at the
// 3-to-4 transition, and the APPROVE_WITH_NOTES rubric permits a nit round AFTER it. Nothing
// noticed: the Librarian archived faithfully from a directory that was wrong.
//
// So the check is HERE, at the choke point, rather than resting on the orchestrator remembering
// to re-sync. The knowledge store is the durable half -- an archive that silently records a
// pre-fix state is a wrong answer with a long shelf life.
//
// WHAT IT DOES NOT DO, stated plainly rather than left for someone to discover: it ABSTAINS
// whenever the worktree is already gone, which post-merge cleanup makes common. It is a backstop
// that catches the state #34 actually shipped, not a guarantee that no stale archive can be
// written. The re-sync rule in commands/pipeline.md is still the primary control.
function staleArtifacts({ fromDir, rootAbs, issue, docs }) {
  const wt = [docs.tasks, docs["impl-report"]]
    .map((d) => (d && typeof d.worktree_path === "string" ? d.worktree_path : null))
    .find(Boolean);
  if (!wt) return { checked: false, stale: [], worktreeDir: null };
  const wtAbs = isAbsolute(wt) ? wt : join(rootAbs, wt);
  const worktreeDir = join(wtAbs, ".pipeline", String(issue));
  // Same directory, or no worktree left to compare against: nothing to say.
  if (resolve(worktreeDir) === fromDir) return { checked: false, stale: [], worktreeDir: null };
  if (!existsSync(worktreeDir) || !statSync(worktreeDir).isDirectory())
    return { checked: false, stale: [], worktreeDir: null };
  const stale = [];
  for (const name of WORKTREE_PRODUCED) {
    const mine = readJson(join(worktreeDir, `${name}.json`));
    if (mine === null) continue; // absent in the worktree: it produced nothing to sync
    const canon = docs[name] ?? null;
    if (canon === null) { stale.push(`${name} (absent from the canonical dir)`); continue; }
    if (stable(canon) !== stable(mine)) stale.push(name);
  }
  return { checked: true, stale, worktreeDir };
}

// Exported so archive-pipeline.mjs is a thin re-dispatch of this exact logic.
export function archiveIssue({ root, issue, from }) {
  // The id lands in a filename below. Unchecked, `../../escaped` writes outside the archive
  // directory. Orchestrator-supplied today, so this crosses no trust boundary, but the cost
  // of being wrong about that later is a write anywhere the process can reach.
  assertPathSegment(issue, "issue");
  const fromDir = resolve(from);
  if (!existsSync(fromDir) || !statSync(fromDir).isDirectory()) throw new Error(`artifact dir not found: ${fromDir}`);
  const archive = { issue_number: Number(issue), archived_at: new Date().toISOString() };
  const found = [];
  for (const name of ARCHIVE_ARTIFACTS) {
    const doc = readJson(join(fromDir, `${name}.json`));
    if (doc !== null) { archive[name] = doc; found.push(name); }
  }
  if (found.length === 0) throw new Error(`no pipeline artifacts found in ${fromDir}`);
  const rootAbs = resolve(root ?? process.cwd());

  // REFUSE A STALE INPUT before writing anything. A half-written archive is worse than none.
  const { checked, stale, worktreeDir } = staleArtifacts({ fromDir, rootAbs, issue, docs: archive });
  if (stale.length > 0) {
    const detail =
      `canonical: ${fromDir}\n  worktree:  ${worktreeDir}\n  diverged:  ${stale.join(", ")}`;
    if (!process.env[ALLOW_STALE_ENV]) {
      throw new Error(
        `archive refused: the canonical artifacts are STALE against the Phase 3 worktree.\n  ${detail}\n` +
        `  Re-run the artifact sync from commands/pipeline.md ("Sync Phase 3 artifacts to the ` +
        `orchestrator pipeline directory") and archive again. To archive the canonical copies ` +
        `anyway, set ${ALLOW_STALE_ENV}=1 -- and say in the run record that you did.`,
      );
    }
    // Overridden, never silent: the whole defect was an archive that recorded the wrong state
    // and said nothing. stderr rather than stdout so the wrapper stays a byte-identical
    // re-dispatch of this function.
    console.error(`Warning: archiving STALE canonical artifacts (${ALLOW_STALE_ENV} is set).\n  ${detail}`);
  }

  const counter = { count: 0 };
  const redacted = redactAbsolutePaths(archive, rootAbs, counter);
  const outDir = join(rootAbs, "knowledge", "issue-archive");
  mkdirSync(outDir, { recursive: true });
  const outPath = join(outDir, `${issue}.json`);
  writeFileSync(outPath, JSON.stringify(redacted, null, 2) + "\n"); // idempotent overwrite
  return { outPath, found, redactions: counter.count, stalenessChecked: checked, stale };
}

function cmdArchive(args) {
  const issue = args["archive-issue"];
  if (issue === true || issue === undefined) fail("--archive-issue requires an issue number");
  if (typeof args.from !== "string") fail("--archive-issue requires --from <artifact-dir>");
  try {
    const { outPath, found, redactions } = archiveIssue({ root: rootDir(args), issue, from: args.from });
    console.log(`Archived issue #${issue} -> ${outPath}\n  artifacts: ${found.join(", ")}\n  absolute paths redacted: ${redactions}`);
  } catch (e) { fail(e.message); }
}

function cmdList(args) {
  const collections = typeof args.collection === "string" ? [args.collection] : COLLECTIONS;
  for (const c of collections) if (!COLLECTIONS.includes(c)) fail(`unknown --collection '${c}'`);
  let any = false;
  for (const c of collections) {
    const files = listJsonFiles(collectionDir(args, c)).sort();
    if (files.length === 0) continue;
    any = true;
    console.log(`# ${c} (${files.length})`);
    for (const path of files) {
      const doc = readJson(path);
      if (!doc) { console.log(`  ${basename(path)}  [unparseable]`); continue; }
      const { title, status, updated } = displayFields(doc, path);
      console.log(`  ${title}  [${status}]  ${updated}  (${basename(path)})`);
    }
    console.log("");
  }
  if (!any) console.log("Knowledge store is empty.");
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || args.h) return void console.log(HELP);
  if ("search" in args) return cmdSearch(args);
  if ("write" in args) return cmdWrite(args);
  if ("archive-issue" in args) return cmdArchive(args);
  if ("list" in args) return cmdList(args);
  fail("no command given. Use --search, --write, --archive-issue, or --list.");
}

// Match the script NAME, the idiom the gates and the validator already use. Every PATH-
// comparing form of this guard has the same silent-no-op failure mode -- main() never runs,
// nothing prints, exit 0 -- and each breaks on a different input: `file://${argv[1]}` on any
// percent-encoded character (a space), and fileURLToPath(import.meta.url) under a symlink,
// because it realpaths while argv[1] keeps the path as invoked. Plugin roots and macOS /tmp
// are routinely symlinks, so both are reachable in production.
const isMain = isMainScript("knowledge-store.mjs");

if (isMain) main();
