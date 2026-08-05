#!/usr/bin/env node
// knowledge-store.mjs — dependency-free CLI over a project's `knowledge/` folder.
// Search, write, list living-context docs, and archive finished pipeline runs. No network, no embeddings.

import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from "node:fs";
import { isMain as isMainScript, assertPathSegment } from "./lib.mjs";
import { join, resolve, basename } from "node:path";

const COLLECTIONS = ["living-context", "issue-archive", "decisions"];
// Pipeline artifacts folded into an issue archive, in phase order; each read only if present.
const ARCHIVE_ARTIFACTS = ["spec", "map", "review", "tasks", "impl-report", "peer-review", "status"];

const HELP = `knowledge-store.mjs — file-based knowledge store (no deps, no network)

Usage:
  knowledge-store.mjs --search "<terms>" [--domain <d>] [--collection <c>] [--root <dir>]
  knowledge-store.mjs --write --file <path.json> [--supersede <slug>] [--root <dir>]
  knowledge-store.mjs --archive-issue <n> --from <artifact-dir> [--root <dir>]
  knowledge-store.mjs --list [--collection <c>] [--root <dir>]

Collections: ${COLLECTIONS.join(" | ")}  (default for search/list: living-context)
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
  const dir = collectionDir(args, "living-context");
  mkdirSync(dir, { recursive: true });
  if (typeof args.supersede === "string") {
    const slug = args.supersede.endsWith(".json") ? args.supersede : `${args.supersede}.json`;
    const old = readJson(join(dir, slug));
    if (!old) fail(`--supersede: no living-context file '${args.supersede}'`);
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
  const outDir = join(resolve(root ?? process.cwd()), "knowledge", "issue-archive");
  mkdirSync(outDir, { recursive: true });
  const outPath = join(outDir, `${issue}.json`);
  writeFileSync(outPath, JSON.stringify(archive, null, 2) + "\n"); // idempotent overwrite
  return { outPath, found };
}

function cmdArchive(args) {
  const issue = args["archive-issue"];
  if (issue === true || issue === undefined) fail("--archive-issue requires an issue number");
  if (typeof args.from !== "string") fail("--archive-issue requires --from <artifact-dir>");
  try {
    const { outPath, found } = archiveIssue({ root: rootDir(args), issue, from: args.from });
    console.log(`Archived issue #${issue} -> ${outPath}\n  artifacts: ${found.join(", ")}`);
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
