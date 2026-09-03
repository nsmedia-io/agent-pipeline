#!/usr/bin/env node
// knowledge-store.mjs — dependency-free CLI over a project's `knowledge/` folder.
// Search, write, list living-context docs, and archive finished pipeline runs. No network, no embeddings.

import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from "node:fs";
import { isMain as isMainScript, assertPathSegment } from "./lib.mjs";
import { join, resolve, relative, basename, isAbsolute, dirname, sep } from "node:path";
import { fileURLToPath } from "node:url";

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

// ---------------------------------------------------------------------------
// CREDENTIAL MATERIAL (#71). Refused HERE, at the archive write, because this is the last
// moment before the string enters a committed tree.
//
// WHY HERE AND NOT ON THE WRITERS. #52 stated a no-secrets rule for status.json's five
// free-text fields and stated it on the WRITER, in commands/pipeline.md. That is the right
// document for the orchestrator, and it does not scale: review.json and peer-review.json are
// both in ARCHIVE_ARTIFACTS, their free-text fields (concerns[].description, concerns[]
// .location, notes, compliance_flags[].concern, vulnerabilities[].description) are written by
// five different subagents from five different contracts, and `advisory_notes` is archived
// while being declared in NO schema at all -- so no per-field annotation could ever have
// covered it. Same argument redactAbsolutePaths makes twenty lines up, for the same reason:
// a rule stated on the writers has to be restated for every future artifact, and a rule
// stated here does not.
//
// THE POPULATION IS DERIVED, NOT LISTED. The walk is over the assembled `archive` object,
// which archiveIssue builds from ARCHIVE_ARTIFACTS. Every field of every archived artifact is
// therefore in scope by construction -- including fields nobody has written yet -- so a new
// free-text field is covered the day it appears rather than the day somebody remembers it.
//
// THE SHARP CASES ARE THE ERROR-BEARING ONES, exactly as #52 named for status.json's `error`:
// the natural content of a `location` or of a reproduction-bearing `description` is COPIED
// MACHINE OUTPUT. A failed psql echoing a DSN, a curl echoing an Authorization header, an
// .env line quoted from a stack trace. Measured on origin/main before this guard existed:
// four planted credentials in one review.json archived VERBATIM at exit 0, and the run
// reported "absolute paths redacted: 1" while doing it -- the redactor rewrote the leading
// /etc/app.env path in a concerns[].location and left DATABASE_PASSWORD=s3cr3tvalue standing
// in the same string. Redaction counting a hit is not redaction covering it.
//
// WHAT THIS REFUSES, NAMED, because a guardrail whose refused-correct-work is unnamed has not
// been costed: knowledge/issue-archive/34.json. #34's SecOps shard quotes the planted
// `pg://u:p4ssw0rdlong@h/db` DSN it used as its OWN non-zero control while measuring this very
// exposure -- a fake, in a security report, hand-checked twice already (the same string is the
// single allowlisted hit in test-status-schema-contract.sh's AC-52c). Re-archiving #34 now
// throws. That is the correct direction: a hand-check, not a silent pass. ALLOW_CREDENTIALS_ENV
// is how you record having made it, and it is never silent.
//
// WHAT IT DOES NOT DO, stated rather than left to be discovered. It matches SHAPES from the
// class list below, so a secret that looks like prose ("the password is hunter2") passes it,
// and so does a provider token in a format nobody has enumerated. It is a floor under the
// writer's own judgement, not a replacement for it -- which is why the rule in
// commands/pipeline.md and the field notes on the review schemas stay, and say so.
//
// ONE TABLE, TWO CONSUMERS, SEAM ASSERTED. test-status-schema-contract.sh's AC-52c carries its
// own copy of this class list and drives it over the committed corpus. The two are kept in
// step by an assertion over the class NAMES in both sources (test-archive-credential-guard.sh),
// not by sharing an import: AC-52c re-derives the classifier independently, which is what makes
// it an oracle rather than a restatement, and a shared import would have both go quiet together.
const CREDENTIAL_CLASSES = [
  ["aws_akid",     /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
  ["github_pat",   /\bgh[pousr]_[A-Za-z0-9]{36,}\b/],
  ["slack_token",  /\bxox[abprs]-[A-Za-z0-9-]{10,}\b/],
  ["sk_key",       /\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}\b/],
  ["bearer",       /\bBearer\s+[A-Za-z0-9._~+/-]{16,}={0,2}/],
  ["jwt",          /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/],
  ["pem_private",  /-----BEGIN(?: [A-Z]+)* PRIVATE KEY-----/],
  ["db_url_creds", /\b(?:pg|postgres|postgresql|mysql|mongodb(?:\+srv)?|redis|amqp):\/\/[^\s:/@]+:[^\s@]+@/],
  ["env_line",     /\b[A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*=[^\s"']+/],
  ["assignment",   /\b(?:api[_-]?key|apikey|secret|password|passwd|access[_-]?key|auth[_-]?token)\b\s*[=:]\s*["']?[A-Za-z0-9._\-\/+]{12,}/i],
  // Mixed-case AND a digit are both required, which is what keeps this off the git SHAs this
  // corpus is largely made of: hex is single-case. Widen the character class and every
  // reviewed_commit / merge_base / qa_contract_sha in the archive becomes a refusal.
  ["high_entropy", /\b(?=[A-Za-z0-9+/]*[a-z])(?=[A-Za-z0-9+/]*[A-Z])(?=[A-Za-z0-9+/]*[0-9])[A-Za-z0-9+/]{40,}={0,2}\b/],
];
const ALLOW_CREDENTIALS_ENV = "PIPELINE_ARCHIVE_ALLOW_CREDENTIAL_SHAPES";

// Walks any JSON value and reports every credential-shaped string in it, by json path and
// class. KEYS ARE WALKED TOO: a credential pasted as an object key reaches the same tree.
// `scanned` is returned and PRINTED by the caller on the clean path, so "the walk found
// nothing" and "the walk never ran" are different outputs rather than the same silence.
export function findCredentialMaterial(value) {
  const hits = [];
  let scanned = 0;
  const walk = (v, p) => {
    if (typeof v === "string") {
      scanned++;
      for (const [name, re] of CREDENTIAL_CLASSES) if (re.test(v)) hits.push({ path: p || "<root>", class: name });
      return;
    }
    if (Array.isArray(v)) return v.forEach((x, i) => walk(x, `${p}[${i}]`));
    if (v && typeof v === "object")
      return Object.entries(v).forEach(([k, x]) => { walk(k, `${p}.<key>`); walk(x, `${p}.${k}`); });
  };
  walk(value, "");
  return { hits, scanned };
}

// A LINE-ORIENTED RAW-TEXT PASS over the same class table (#125). knowledge/issue-archive/ is a
// committed directory and archiveIssue writes only <n>.json into it, so the agent-authored
// *.md and *.sh sidecars beside those archives -- 403,389 bytes at 73ee2aa -- were reached by
// neither this guard nor test-status-schema-contract.sh's AC-52c, whose population is
// `ls -1 knowledge/issue-archive/*.json`. Both scopings are by CONSTRUCTION rather than by
// oversight, which is why widening either was the wrong instrument: AC-52c's vacuity assertion
// requires every file in its population to JSON.parse, so feeding it a .sh reddens it for the
// wrong reason.
//
// THE CLASS TABLE IS SHARED, NOT COPIED. This calls findCredentialMaterial once per LINE rather
// than re-deriving the regexes, so there is exactly one shipped predicate and a narrowing of it
// narrows both passes together. Per line and not per file because the operator needs a
// location: on a 137 KB verify battery, `[env_line]` with no line number is not actionable.
//
// THIS IS THE CALLER #71 ANTICIPATED. Its battery declared the `p || "<root>"` fallback in
// findCredentialMaterial an expected SURVIVOR -- a theorem, because archiveIssue always hands
// that function an OBJECT, so a string leaf is never at path "" -- and wrote down the condition
// that would end it: "If a caller is ever added that hands it a bare string, this stops being a
// theorem and needs a cell." This is that caller, and the cell is in
// tests/test-archive-sidecar-scan.sh.
export function findCredentialMaterialInText(text) {
  const hits = [];
  let scanned = 0;
  // String() is a coercion every current caller makes unnecessary (all of them read the file as
  // utf8 first). It is here for the caller that hands this a Buffer, and it is the documented
  // EXPECTED SURVIVOR of this change's mutation battery: removing it changes no verdict today,
  // which is a theorem about the callers rather than a coverage gap. It stops being one the day
  // a caller passes anything that is not already a string.
  const lines = String(text).split("\n");
  for (let i = 0; i < lines.length; i++) {
    scanned++;
    for (const h of findCredentialMaterial(lines[i]).hits)
      hits.push({ line: i + 1, class: h.class, text: lines[i].trim() });
  }
  return { hits, scanned };
}

// ---------------------------------------------------------------------------
// BLANK REQUIRED FREE-TEXT FIELDS (#122), which is #71's property 3: "whatever distinguishes a
// present-but-empty value from a meaningful one is applied at the moment of writing, by
// something that runs, and its failure to run is distinguishable in the output from a clean
// pass." A MISSING key is genuinely refused where the validator runs; a present-but-EMPTY one
// is not, and the walker in validate-pipeline-artifact.mjs implements no minLength. Same actor,
// same outcome, one keystroke cheaper.
//
// WHY HERE, AND NOT WHERE #122 SAID. #122 named validate-pipeline-artifact.mjs as the only
// write-time seat and recorded itself blocked on #66, which records that validator as inert
// under namespaced agent dispatch -- the shipping default. That framing was incomplete: THIS
// write runs unconditionally in every deployment mode, and #71 demonstrated it as a working
// write-time seat by putting the credential refusal here. So the check sits where its green is
// a fact about the RECORD rather than about the deployment mode, and #122 does not wait on #66.
//
// THE FAIL DIRECTION IS *WARN*, AND IT IS NOT A STYLE PREFERENCE. By the time this runs the run
// is FINISHED and this archive is its only durable copy. The credential guard four hundred
// lines up REFUSES because shipping the secret IS the harm; here refusing IS the harm -- it
// would destroy the record in order to punish a blank field. So this never throws, never skips
// the write, and reports instead, on stdout every time and on stderr when it finds something.
// Do NOT "fix" it into a refusal by analogy with the credential guard.
//
// WHAT IT REFUSES: nothing, ever. WHAT IT NOISES UP, named, because a guardrail whose cost is
// unnamed has not been costed -- and here a false positive is the whole risk, since the
// population is clean today (0 blanks over 31,520 committed strings at 73ee2aa):
//   - an `info` vulnerabilities[] row whose honest remediation is "none required" is NOT
//     reported. It is non-blank, and a check demanding a PROPERTY-shaped remediation would
//     refuse correct work. This is the case #122 names, and it has its own cell.
//   - an OPTIONAL free-text field left as "" is NOT reported. Where the schema does not require
//     the field, "" and absent say the same thing and neither is a defect. The asymmetry #122
//     is about exists only where the schema REQUIRES the field.
//   - a MISSING required key is NOT reported. That half is already refused wherever the
//     validator runs, and restating it here would be noise on the one path that cannot refuse.
//
// THE POPULATION IS DERIVED FROM THE SHIPPED SCHEMAS, never listed here -- the same argument
// the credential walk makes for ARCHIVE_ARTIFACTS. A field that becomes required tomorrow is
// covered the day the schema says so. Two consequences worth stating rather than leaving to be
// discovered:
//   - peer-review.json contributes almost NOTHING today, because its concerns[] subschema has
//     no required list at all (#38): #panelVerdict requires only `verdict`, which is an enum.
//     123 of the 230 concerns[] rows #122 measured live in that half. Closing #38 widens this
//     check automatically, with no edit here, which is what a derived population buys.
//   - free text is identified STRUCTURALLY -- a required property typed string (or
//     string-or-array) with no enum and no date-time format -- so `verdict` and `reviewed_at`
//     are out by construction rather than by an exemption list somebody has to maintain.
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
// Schemas ship WITH the plugin (../schemas), independent of the user's project -- the same
// resolution gate-pre-phase4.mjs, validate-pipeline-artifact.mjs and voice-lint.mjs use.
const SCHEMA_DIR = resolve(SCRIPT_DIR, "..", "schemas");

const isFreeTextSchema = (n) => {
  if (!n || typeof n !== "object") return false;
  const t = n.type;
  const isStr = t === "string" || (Array.isArray(t) && t.includes("string"));
  return isStr && !n.enum && n.format !== "date-time";
};

// GUARD WHERE IT LANDED, NOT HOW IT WAS SPELLED. "" and "   " are the same non-signal, and so
// is [] (and [""] ) for a field the schema types as string-OR-array, which `notes` is. Covering
// only the first spelling would leave the others as a one-keystroke bypass of the same check.
const isBlankValue = (v) =>
  typeof v === "string"
    ? v.trim() === ""
    : Array.isArray(v)
      ? v.every((x) => typeof x === "string" && x.trim() === "")
      : false;

// Applies one artifact schema to one artifact document and reports every REQUIRED free-text
// property that is present and blank. Draft-07 subset, matching what these schemas actually
// use: $ref (local), allOf, properties, items, required.
function blanksAgainstSchema(schema, doc, rootPath) {
  const blanks = [];
  let checked = 0;
  const deref = (n) => {
    for (let hops = 0; n && typeof n === "object" && typeof n.$ref === "string"; hops++) {
      // A $ref cycle is not a reason to hang the Phase 5 write. Bounded, and the bound being
      // hit yields "unresolvable" (no hits) rather than a throw, on this path's WARN posture.
      if (hops > 10 || !n.$ref.startsWith("#/")) return null;
      let cur = schema;
      for (const seg of n.$ref.slice(2).split("/")) cur = cur == null ? cur : cur[seg];
      n = cur;
    }
    return n;
  };
  const walk = (rawNode, value, path, depth) => {
    if (depth > 40) return;
    const node = deref(rawNode);
    if (!node || typeof node !== "object" || value === null || typeof value !== "object") return;
    if (Array.isArray(value)) {
      if (node.items) value.forEach((v, i) => walk(node.items, v, `${path}[${i}]`, depth + 1));
      return;
    }
    for (const sub of node.allOf || []) walk(sub, value, path, depth + 1);
    for (const name of Array.isArray(node.required) ? node.required : []) {
      const field = deref((node.properties || {})[name]);
      if (!isFreeTextSchema(field)) continue;
      // PRESENT-BUT-BLANK is the subject. An absent key is the validator's business, and a
      // value of the wrong type is a schema violation rather than a blank one.
      if (!Object.prototype.hasOwnProperty.call(value, name)) continue;
      const v = value[name];
      if (typeof v !== "string" && !Array.isArray(v)) continue;
      checked++;
      if (isBlankValue(v)) blanks.push(`${path}.${name}`);
    }
    for (const [k, sub] of Object.entries(node.properties || {}))
      if (Object.prototype.hasOwnProperty.call(value, k)) walk(sub, value[k], `${path}.${k}`, depth + 1);
  };
  walk(schema, doc, rootPath, 0);
  return { blanks, checked };
}

// Walks the assembled archive document against the shipped artifact schemas. `checked` is
// returned and PRINTED by the caller on the clean path, so "no blank required field" and "the
// walk never ran" are different outputs rather than the same silence -- the clause #122's
// property 3 asks for, in the shape #71's credential line already established.
export function findBlankRequiredFields(archive, schemaDir = SCHEMA_DIR) {
  const blanks = [];
  const unreadable = [];
  let checked = 0, schemasRead = 0, schemasExpected = 0;
  for (const name of ARCHIVE_ARTIFACTS) {
    if (!Object.prototype.hasOwnProperty.call(archive, name)) continue;
    schemasExpected++;
    const schema = readJson(join(schemaDir, `${name}.schema.json`));
    if (!schema) { unreadable.push(`${name}.schema.json`); continue; }
    schemasRead++;
    const r = blanksAgainstSchema(schema, archive[name], `.${name}`);
    checked += r.checked;
    for (const b of r.blanks) blanks.push(b);
  }
  return { blanks, checked, schemasRead, schemasExpected, unreadable, schemaDir };
}

// The one place the report line is spelled, because archive-pipeline.mjs is contractually a
// BYTE-IDENTICAL re-dispatch of the CLI (tests/test-archive-pipeline.sh pins the two stdouts
// against each other) and a second hand-written copy of a format string is a divergence waiting
// for its first edit.
//
// THE INCOMPLETE BRANCH IS THE POINT, not a defensive flourish. A walk that could read no
// schema reports `0 blank` truthfully and vacuously, and two suites already copy this script
// into a scratch dir WITHOUT its ../schemas sibling, so the degraded path is reachable rather
// than hypothetical. It says NOT CHECKED, names the directory it looked in, and is therefore
// distinguishable in the output from a clean pass.
export function blankFieldReportLine(r) {
  return r.schemasRead === r.schemasExpected
    ? `  blank required free-text fields: ${r.blanks.length} (of ${r.checked} present, from ` +
      `${r.schemasRead}/${r.schemasExpected} artifact schemas)`
    : `  blank required free-text fields: NOT CHECKED (${r.blanks.length} found in ${r.checked} ` +
      `present; only ${r.schemasRead}/${r.schemasExpected} artifact schemas readable under ${r.schemaDir})`;
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

  // REFUSE CREDENTIAL MATERIAL before writing anything, and scan the REDACTED document rather
  // than the raw one: redaction sits between the artifact and the file, so the redacted copy is
  // the bytes that actually land on disk. Scanning the raw copy would report on text the write
  // never contains, which is a refusal the operator cannot act on.
  //
  // No early return and no `continue` on this path: the scan runs on every archive, and its
  // result is reported on the clean path too (see cmdArchive), so a walk that inspected nothing
  // is distinguishable in the output from a walk that inspected 3000 strings and found nothing.
  const { hits, scanned } = findCredentialMaterial(redacted);
  if (hits.length > 0) {
    const detail = hits.map((h) => `${h.path} [${h.class}]`).join("\n    ");
    if (!process.env[ALLOW_CREDENTIALS_ENV]) {
      throw new Error(
        `archive refused: credential-shaped material in the artifacts for #${issue}.\n` +
        `  This file is COMMITTED. A fix-forward commit does not remove a secret from history,\n` +
        `  so redact it in the source artifact under ${fromDir} and archive again -- and if it\n` +
        `  already reached a commit, AMEND that commit rather than fixing forward.\n` +
        `    ${detail}\n` +
        `  If a hit is a FAKE you hand-checked (a planted DSN quoted in a security report is the\n` +
        `  case that exists), set ${ALLOW_CREDENTIALS_ENV}=1 -- and say in the run record that ` +
        `you did.`,
      );
    }
    // Overridden, never silent, on the same principle as the staleness override above: stderr,
    // and it names every hit, so the override cannot be exercised without the hits being read.
    console.error(
      `Warning: archiving CREDENTIAL-SHAPED material (${ALLOW_CREDENTIALS_ENV} is set).\n    ${detail}`,
    );
  }

  // REPORT -- NEVER REFUSE -- A BLANK REQUIRED FREE-TEXT FIELD (#122). Deliberately AFTER the
  // two refusals above and deliberately not one of them: the run is over by now and this
  // archive is its only durable copy, so refusing here would destroy the record to punish a
  // blank field. The scan runs on every archive and its denominator is reported on the clean
  // path too (see blankFieldReportLine), so a walk that inspected nothing is distinguishable
  // from one that inspected 47 required fields and found nothing.
  const blank = findBlankRequiredFields(redacted);
  if (blank.blanks.length > 0) {
    // Loud, and on stderr, on the same principle as the two overrides above -- and NOT on
    // stdout, which archive-pipeline.mjs must be able to reproduce byte for byte.
    console.error(
      `Warning: ${blank.blanks.length} REQUIRED free-text field(s) present but BLANK in the ` +
      `archive for #${issue}.\n  The archive WAS written: by this point the run is finished and ` +
      `the record is the thing of value,\n  so refusing would destroy it to punish a blank ` +
      `field (#122). A blank required field is a\n  QUALITY defect, not a safety one -- fill it ` +
      `in the source artifact under ${fromDir} and\n  archive again to correct the record.\n    ` +
      blank.blanks.join("\n    "),
    );
  }
  if (blank.schemasRead !== blank.schemasExpected) {
    // A zero over an unread schema set is not a result. Announced rather than refused, on this
    // path's WARN posture, and the stdout line says NOT CHECKED for the same reason.
    console.error(
      `Warning: the blank-required-field scan read only ${blank.schemasRead} of ` +
      `${blank.schemasExpected} artifact schemas under ${blank.schemaDir}` +
      `${blank.unreadable.length ? ` (missing: ${blank.unreadable.join(", ")})` : ""}.\n` +
      `  Its count is NOT a clean result; treat it as unchecked.`,
    );
  }

  const outDir = join(rootAbs, "knowledge", "issue-archive");
  mkdirSync(outDir, { recursive: true });
  const outPath = join(outDir, `${issue}.json`);
  writeFileSync(outPath, JSON.stringify(redacted, null, 2) + "\n"); // idempotent overwrite
  return {
    outPath, found, redactions: counter.count, stalenessChecked: checked, stale,
    stringsScanned: scanned, credentialHits: hits.length, blankFields: blank,
  };
}

function cmdArchive(args) {
  const issue = args["archive-issue"];
  if (issue === true || issue === undefined) fail("--archive-issue requires an issue number");
  if (typeof args.from !== "string") fail("--archive-issue requires --from <artifact-dir>");
  try {
    const { outPath, found, redactions, stringsScanned, credentialHits, blankFields } =
      archiveIssue({ root: rootDir(args), issue, from: args.from });
    // The credential line is printed on the CLEAN path too, with the denominator. "0 hits" over
    // 0 strings and "0 hits" over 3000 are different results, and a scan that has never reported
    // its population is indistinguishable from one that did not run. #122's blank-field line
    // carries its denominator for the same reason, from the same shared formatter.
    console.log(
      `Archived issue #${issue} -> ${outPath}\n  artifacts: ${found.join(", ")}\n` +
      `  absolute paths redacted: ${redactions}\n` +
      `  credential-shaped strings: ${credentialHits} (of ${stringsScanned} strings scanned)\n` +
      blankFieldReportLine(blankFields));
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
