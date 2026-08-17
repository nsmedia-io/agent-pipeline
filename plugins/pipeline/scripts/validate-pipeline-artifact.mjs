#!/usr/bin/env node
/**
 * SubagentStop validator for the agent pipeline.
 *
 * Reads the SubagentStop hook payload on stdin, maps the stopping agent to the artifact it
 * owns, and validates that artifact against its JSON Schema in ../schemas/ (shipped with the
 * plugin). On a schema violation it emits a top-level `decision:block` so the subagent keeps
 * working and fixes the artifact; otherwise it stays silent.
 *
 * Design choices (deliberate):
 *   - Validate ONLY when the artifact exists and was written in this run (recent mtime). A
 *     missing artifact is NOT a failure: agents are invokable ad-hoc outside the pipeline,
 *     and a Phase 2 reviewer's peer-review block does not exist yet in Phase 4. We catch
 *     malformed-present, never absent.
 *   - Scope to ONE active issue, never a sibling. Within a resolved .pipeline root the sweep
 *     validates only the single issue dir the session owns, derived by precedence (see
 *     activeIssueDir): a forward-compatible orchestrator marker/env seam, then the newest
 *     status.json mtime (the only path exercised in normal use), then fail-open (validate
 *     nothing). A freshly synced or checked-out sibling issue's artifacts carry a recent
 *     mtime too, so without this the recent-mtime narrowing could not tell the session's own
 *     just-written artifact from an unrelated sibling, and a defect in another issue dir
 *     would block a stop the session had nothing to do with.
 *   - Fail open. Any internal error exits 0 with no decision, so a validator bug can never
 *     wedge a legitimate stop. Each agent's turn cap bounds the fix-loop a block could
 *     otherwise create.
 *
 * Dependency-free. Supports the draft-07 subset our schemas use: type, required, properties,
 * items, enum, minItems, local $ref, and allOf (merged, enums unioned so a SecOps VETO
 * validates against the base agentBlock enum). It does not implement if/then, format,
 * pattern, maxLength, oneOf/anyOf: those are advisory here, and the contract that matters
 * (required fields, types, verdict enums) is fully covered.
 *
 * Beyond shape, we GROUND a few impl-report.json claims against cheap, read-only evidence
 * already on disk (no subprocess, ever):
 *   - files listed in commits[].files_changed must exist in the worktree.
 *   - an acceptance_criteria_met entry marked met must map to a named test, via the
 *     qa_signoff.acceptance_mapping. A "met" claim with no mapped test is a block.
 *   - checks_passed.test === true is corroborated against a PRE-EXISTING test-runner JSON
 *     reporter file if one is present. If absent, the check fails OPEN (we never spawn the
 *     test runner): the absence of evidence is not evidence of a lie.
 * Every grounding check is fail-open: any missing input or read error skips that check, so a
 * grounding gap can never wedge a legitimate stop.
 *
 * Exit / output contract:
 *   - Hook mode (default, stdin payload): silent exit 0 on pass; a `{decision:"block",...}`
 *     JSON object on stdout on failure (still exit 0 -- the block is advisory to the agent);
 *     any crash exits 0 (fail open).
 *   - `--self-test`: runs the built-in checks and exits 0 (all pass) or 1 (any fail).
 */

import {
  readFileSync,
  readdirSync,
  statSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  utimesSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { isMain as isMainScript } from "./lib.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
// Schemas ship WITH the plugin (../schemas), independent of the user's project. Runtime
// artifacts live in the user project's .pipeline/<issue>/ (resolved via pipelineDirs).
const SCHEMA_DIR = path.resolve(SCRIPT_DIR, "..", "schemas");
const RECENT_MS = 30 * 60 * 1000; // only validate artifacts touched in this run

// agent_type (subagent frontmatter `name`) -> artifacts it owns and where to look. schemaPtr
// selects the sub-schema to validate against; dataPtr selects the slice of the artifact to
// validate ("" = whole file). A peer-review panel block is validated against panelVerdict
// only, never the whole file, because the orchestrator (not the agent) writes final_verdict.
//
// Agents in the parallel phases write BARE SHARD files (review.<role>.json /
// peer-review.<role>.json) that the orchestrator later merges and deletes, so at SubagentStop
// time the shard is what exists; validate it as a whole-file bare block. The merged-file
// slice rules stay as well: they cover single re-runs where the orchestrator merges while the
// dir is still recent, and Dev's non-concurrent nit-fix edit of the merged peer-review.json.
function reviewerRules(role) {
  const reviewPtr = role === "secops" ? "#/properties/secops" : "#/definitions/agentBlock";
  return [
    { artifact: `review.${role}.json`, schema: "review.schema.json", schemaPtr: reviewPtr, dataPtr: "" },
    { artifact: `peer-review.${role}.json`, schema: "peer-review.schema.json", schemaPtr: "#/definitions/panelVerdict", dataPtr: "" },
    { artifact: "review.json", schema: "review.schema.json", schemaPtr: reviewPtr, dataPtr: `/${role}` },
    { artifact: "peer-review.json", schema: "peer-review.schema.json", schemaPtr: "#/definitions/panelVerdict", dataPtr: `/${role}` },
  ];
}

const AGENT_RULES = {
  ba: [
    { artifact: "spec.json", schema: "spec.schema.json", schemaPtr: "#", dataPtr: "" },
    { artifact: "peer-review.ba.json", schema: "peer-review.schema.json", schemaPtr: "#/definitions/panelVerdict", dataPtr: "" },
    { artifact: "peer-review.json", schema: "peer-review.schema.json", schemaPtr: "#/definitions/panelVerdict", dataPtr: "/ba" },
  ],
  dba: reviewerRules("dba"),
  devops: reviewerRules("devops"),
  secops: reviewerRules("secops"),
  dev: [
    // The Phase 2.5 bake-off judge is dispatched as subagent_type "dev", so design.json is
    // validated at ITS stop. There is no way to check it at the judge's stop but NOT at Dev's:
    // they are the same agent_type, and seeding the worktree refreshes design.json's mtime into
    // RECENT_MS anyway. That constraint is why `owner_decision` is NOT in the schema's required
    // list. Making it required here blocks at the DEV stop, telling the one role that does not
    // own this artifact to "fix the artifact before finishing" — with no recovery path, since
    // the judge wrote it. The orchestrator enforces that field's presence instead, right after
    // the judge returns. What stays enforced here is the shape every reader depends on
    // (chosen_approach, rationale, rejected_alternatives), which Dev CAN act on by halting.
    { artifact: "design.json", schema: "design.schema.json", schemaPtr: "#", dataPtr: "" },
    { artifact: "tasks.json", schema: "tasks.schema.json", schemaPtr: "#", dataPtr: "" },
    { artifact: "impl-report.json", schema: "impl-report.schema.json", schemaPtr: "#", dataPtr: "" },
    { artifact: "peer-review.dev.json", schema: "peer-review.schema.json", schemaPtr: "#/definitions/panelVerdict", dataPtr: "" },
    { artifact: "peer-review.json", schema: "peer-review.schema.json", schemaPtr: "#/definitions/panelVerdict", dataPtr: "/dev" },
  ],
  qa: [
    { artifact: "impl-report.json", schema: "impl-report.schema.json", schemaPtr: "#/properties/qa_signoff", dataPtr: "/qa_signoff" },
    { artifact: "peer-review.qa.json", schema: "peer-review.schema.json", schemaPtr: "#/definitions/panelVerdict", dataPtr: "" },
    { artifact: "peer-review.json", schema: "peer-review.schema.json", schemaPtr: "#/definitions/panelVerdict", dataPtr: "/qa" },
  ],
  librarian: [
    { artifact: "librarian-report.json", schema: "librarian-report.schema.json", schemaPtr: "#", dataPtr: "" },
  ],
};

// ---- pointer + schema helpers ----------------------------------------------

function schemaAt(root, ptr) {
  if (!ptr || ptr === "#") return root;
  const parts = ptr.replace(/^#\//, "").split("/");
  let cur = root;
  for (const p of parts) cur = cur == null ? undefined : cur[p];
  return cur;
}

function dataAt(data, ptr) {
  if (!ptr) return data;
  const parts = ptr.replace(/^\//, "").split("/");
  let cur = data;
  for (const p of parts) cur = cur == null ? undefined : cur[p];
  return cur;
}

function deref(schema, root) {
  let guard = 0;
  while (schema && schema.$ref && guard++ < 20) schema = schemaAt(root, schema.$ref);
  return schema;
}

// Flatten allOf into one schema: concat required, merge properties, union enums on any
// property defined in more than one branch (so VETO is accepted by SecOps).
function mergeAllOf(schema, root) {
  if (!schema || !schema.allOf) return schema;
  const merged = {
    type: schema.type,
    required: [...(schema.required || [])],
    properties: { ...(schema.properties || {}) },
  };
  for (const branch of schema.allOf) {
    const b = deref(branch, root);
    if (!b) continue;
    if (b.type && !merged.type) merged.type = b.type;
    if (b.required) merged.required.push(...b.required);
    for (const [k, v] of Object.entries(b.properties || {})) {
      const prev = merged.properties[k];
      if (prev && prev.enum && v.enum) {
        merged.properties[k] = { ...prev, ...v, enum: [...new Set([...prev.enum, ...v.enum])] };
      } else {
        merged.properties[k] = prev ? { ...prev, ...v } : v;
      }
    }
  }
  merged.required = [...new Set(merged.required)];
  return merged;
}

function typeOk(value, type) {
  const types = Array.isArray(type) ? type : [type];
  return types.some((t) => {
    switch (t) {
      case "object": return value !== null && typeof value === "object" && !Array.isArray(value);
      case "array": return Array.isArray(value);
      case "string": return typeof value === "string";
      case "integer": return typeof value === "number" && Number.isInteger(value);
      case "number": return typeof value === "number";
      case "boolean": return typeof value === "boolean";
      case "null": return value === null;
      default: return true;
    }
  });
}

function describe(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

export function validate(value, schema, root, pathStr = "", errors = []) {
  schema = deref(schema, root);
  if (!schema) return errors;
  schema = mergeAllOf(schema, root);

  const label = pathStr || "(root)";

  if (schema.type && value !== undefined && !typeOk(value, schema.type)) {
    errors.push(`${label}: expected type ${JSON.stringify(schema.type)}, got ${describe(value)}`);
    return errors; // type is wrong; deeper checks would be noise
  }
  if (schema.enum && value !== undefined && !schema.enum.includes(value)) {
    errors.push(`${label}: ${JSON.stringify(value)} is not one of ${JSON.stringify(schema.enum)}`);
  }
  if (typeOk(value, "object") && (schema.properties || schema.required)) {
    for (const req of schema.required || []) {
      if (value[req] === undefined) errors.push(`${label}: missing required field "${req}"`);
    }
    for (const [k, sub] of Object.entries(schema.properties || {})) {
      if (value[k] !== undefined) validate(value[k], sub, root, `${pathStr}/${k}`, errors);
    }
  }
  if (Array.isArray(value)) {
    if (typeof schema.minItems === "number" && value.length < schema.minItems) {
      errors.push(`${label}: expected at least ${schema.minItems} item(s), got ${value.length}`);
    }
    if (schema.items) value.forEach((item, i) => validate(item, schema.items, root, `${pathStr}[${i}]`, errors));
  }
  return errors;
}

// ---- artifact discovery + validation ---------------------------------------

// Most-specific root first: the stopping agent's own cwd is where ITS artifacts live.
// checkArtifacts stops at the first root that yields a recent artifact for this agent, so a
// recent artifact in a DIFFERENT session's checkout (project root vs worktree) can no longer
// block this agent's stop. Falling through when the agent's own root has nothing recent is
// deliberate: it still catches the wrote-to-the-wrong-checkout bug.
// `rootsOverride`, when passed, REPLACES the default root list entirely (it is not appended
// to). It exists so the self-test can pin root resolution to a temp tree and never fall
// through to the checkout's own .pipeline.
function pipelineDirs(input, rootsOverride) {
  const roots = rootsOverride || [
    input && input.cwd,
    process.env.CLAUDE_PROJECT_DIR,
    process.cwd(),
  ];
  const seen = new Set();
  const dirs = [];
  for (const r of roots) {
    if (!r) continue;
    const p = path.join(r, ".pipeline");
    if (!seen.has(p) && existsSync(p)) {
      seen.add(p);
      dirs.push(p);
    }
  }
  return dirs;
}

// A .pipeline issue dir is named by its numeric issue number. Constraining both derivation
// paths to this convention (rather than just excluding "schemas") means a non-issue sibling
// like "schemas" or a hypothetical "_archived" can never be selected as the active issue: the
// marker path rejects such a name (fail-open, falls back to mtime) and the mtime scan never
// enumerates it.
const ISSUE_DIR_RE = /^\d+$/;

function issueDirs(pipelineDir) {
  try {
    return readdirSync(pipelineDir, { withFileTypes: true })
      .filter((d) => d.isDirectory() && ISSUE_DIR_RE.test(d.name))
      .map((d) => path.join(pipelineDir, d.name));
  } catch {
    return [];
  }
}

// Resolve the ONE issue whose artifacts this session owns, within a single .pipeline root. A
// session owns exactly one active issue; scanning every sibling issue dir let a freshly-synced
// or checked-out sibling artifact (which carries a recent mtime) block a stop for work the
// session never touched.
//
// Precedence, first match wins:
//   (a) FORWARD-COMPATIBLE SEAM: an explicit active-issue signal the orchestrator MAY set --
//       the stdin payload's active_issue field, or CLAUDE_PIPELINE_ACTIVE_ISSUE /
//       PIPELINE_ACTIVE_ISSUE in the env. The named dir must be a numeric issue dir that
//       exists in this root; a signal that is non-numeric or names an absent dir is ignored,
//       so a stale or malformed env var cannot misdirect the sweep (it falls back to (b)).
//   (b) the newest status.json mtime among the numeric issue dirs in this root -- the "which
//       issue is active" mechanism, and the path exercised in normal use.
//   (c) neither resolves: return null. The caller then validates nothing in this root
//       (fail-open): an ad-hoc or non-pipeline session owns no issue dir and must never be
//       blocked by artifacts it did not write.
function activeIssueName(input) {
  const raw =
    (input && input.active_issue) ||
    process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE ||
    process.env.PIPELINE_ACTIVE_ISSUE ||
    "";
  const name = String(raw).trim();
  // The signal names a bare numeric issue dir. Reject separators/traversal AND any non-issue
  // name (e.g. "schemas", "_archived") so the marker path enforces the same convention as the
  // mtime scan; a rejected name fails open to path (b).
  if (!ISSUE_DIR_RE.test(name)) {
    return null;
  }
  return name;
}

export function activeIssueDir(pipelineDir, input) {
  const named = activeIssueName(input);
  if (named) {
    const candidate = path.join(pipelineDir, named);
    try {
      if (statSync(candidate).isDirectory()) return candidate;
    } catch {
      // named dir absent in this root: fall through to mtime derivation
    }
  }
  let newest = null;
  let newestMtime = -Infinity;
  for (const dir of issueDirs(pipelineDir)) {
    let st;
    try {
      st = statSync(path.join(dir, "status.json"));
    } catch {
      continue; // no status.json: not a resolvable active issue via (b)
    }
    if (st.mtimeMs > newestMtime) {
      newestMtime = st.mtimeMs;
      newest = dir;
    }
  }
  return newest; // null when no signal and no status.json anywhere: fail-open
}

function loadJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

// ---- grounding: impl-report claims vs cheap read-only evidence ---------------
//
// All grounding is pure-ish over an injectable evidence surface so the self-test can exercise
// it without touching the real filesystem. `ev` exposes:
//   fileExists(relPath) -> boolean       (does a claimed-changed file exist)
//   testResults()       -> object|null   (parsed test-runner JSON reporter output, or null)
// In production these are backed by statSync / readFileSync rooted at the repo; when either
// input is absent the relevant check is skipped (fail-open).

// A claimed-changed file that does not exist on disk is a grounding failure: the report claims
// a touch that the tree does not corroborate. Paths we cannot resolve (no evidence surface) are
// skipped. A path the report also records as removed (top-level files_removed or the commit's
// own files_removed) is exempt from the existence check: a truthfully-recorded deletion
// legitimately leaves no file behind.
function groundFilesChanged(data, ev, failures) {
  if (!ev || typeof ev.fileExists !== "function") return;
  const topRemoved = new Set((data.files_removed || []).filter((f) => typeof f === "string"));
  for (const commit of data.commits || []) {
    const removed = new Set(topRemoved);
    for (const r of commit.files_removed || []) {
      if (typeof r === "string") removed.add(r);
    }
    for (const f of commit.files_changed || []) {
      if (typeof f !== "string" || f.length === 0) continue;
      if (removed.has(f)) continue; // recorded deletion: do not require it on disk
      if (ev.fileExists(f) === false) {
        failures.push(`impl-report claims commit touched "${f}" but it is not present in the tree`);
      }
    }
  }
}

// Tokenize a criterion string into a set of lowercased word stems for fuzzy match. Drops
// punctuation and very short noise words so light text drift between the BA's
// acceptance_criteria_met[].criterion and QA's qa_signoff restatement does not break the
// match. Exact-string matching is deliberately NOT used: the two arrays are written by
// different roles and routinely diverge in wording while describing the same criterion.
export function tokens(str) {
  return new Set(
    String(str || "")
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, " ")
      .split(/\s+/)
      .filter((w) => w.length >= 4),
  );
}

// Extract AC labels (AC1, AC2, ...) from a string. A short label like "AC2" carries no 4+ char
// tokens, so token overlap alone false-flags a met full-sentence criterion mapped to a short
// label as ungrounded. The label is the strongest signal when both sides use it. This is the
// SINGLE SOURCE of the AC-label matcher: gate-pre-phase4.mjs imports it so the fail-open and
// fail-closed gates stay consistent.
export function acLabels(str) {
  const out = new Set();
  const re = /\bac\s*([0-9]+)\b/gi;
  let m;
  while ((m = re.exec(String(str || ""))) !== null) out.add(`ac${m[1]}`);
  return out;
}

// A met criterion is grounded if some mapping entry (with a named test) shares enough
// distinctive tokens with it. Threshold is intentionally lenient: we are catching the
// reward-hacking shape (a met criterion with NO corresponding mapping entry at all), not
// policing wording. Returns true if at least half the criterion's tokens, or 3 tokens,
// overlap a candidate, whichever is smaller.
function overlapsSome(critTokens, candidates) {
  if (critTokens.size === 0) return true; // nothing distinctive to match on: do not block
  const need = Math.min(3, Math.ceil(critTokens.size / 2));
  for (const cand of candidates) {
    let hit = 0;
    for (const t of critTokens) if (cand.has(t)) hit++;
    if (hit >= need) return true;
  }
  return false;
}

// Once a report declares a test-mapping (qa_signoff.acceptance_mapping is present and
// non-empty), every acceptance_criteria_met entry marked met must correspond to a mapping
// entry that names a test. A "met: true" criterion with no corresponding mapping entry is the
// reward-hacking shape this check catches: claimed-met behavior with no test behind it.
// Correspondence is fuzzy (token overlap), not exact-string, to tolerate the normal wording
// drift between the two arrays.
//
// Fail open when no mapping is declared at all: a doc-only or runbook issue legitimately has
// met criteria that are not test-mappable, and absence of a mapping is not a lie. We only
// assert the mapping the report itself claims to maintain.
function groundAcceptanceMapping(data, failures) {
  const met = (data.acceptance_criteria_met || []).filter((e) => e && e.met === true);
  if (met.length === 0) return;
  const rawMapping = (data.qa_signoff && data.qa_signoff.acceptance_mapping) || [];
  if (rawMapping.length === 0) return; // report makes no test-mapping claim: fail open

  // Candidate match surfaces come from each mapping entry that names a non-blank test. Each
  // carries a token set (from BOTH its criterion text and its test name) and an AC-label set
  // (from its criterion). A "shortLabelWildcard" candidate is one whose criterion is a bare AC
  // label (e.g. "AC2") carrying no distinctive tokens of its own: it names a real test but
  // cannot be token-matched to a full-sentence met criterion, so it must not, on its own, make
  // that criterion look ungrounded.
  const candidates = [];
  let hasShortLabelWildcard = false;
  for (const m of rawMapping) {
    if (m && typeof m.test === "string" && m.test.trim() !== "") {
      const critTok = tokens(m.criterion);
      const labels = acLabels(m.criterion);
      const t = new Set(critTok);
      for (const w of tokens(m.test)) t.add(w);
      candidates.push({ tokens: t, labels });
      if (critTok.size === 0 && labels.size > 0) hasShortLabelWildcard = true;
    }
  }
  if (candidates.length === 0) {
    // mapping exists but no entry names a test: every met criterion is ungrounded
    for (const entry of met) {
      if (typeof entry.criterion !== "string") continue;
      failures.push(
        `impl-report acceptance_criteria_met "${entry.criterion}" is marked met but no qa_signoff.acceptance_mapping entry names a test`,
      );
    }
    return;
  }

  const candidateTokenSets = candidates.map((c) => c.tokens);
  for (const entry of met) {
    if (typeof entry.criterion !== "string") continue;
    const critLabels = acLabels(entry.criterion);
    // AC-label match is the strongest signal and is symmetric: it grounds a met criterion
    // whenever it shares a label with a mapping candidate.
    if (critLabels.size > 0 && candidates.some((c) => shareLabel(critLabels, c.labels))) {
      continue;
    }
    // A met criterion mapped to a bare short-label entry ("AC2") carries a real test it just
    // cannot be token-matched to. That is not a lie: fail open on it rather than emit a
    // spurious block.
    if (hasShortLabelWildcard) continue;
    const critTokens = tokens(entry.criterion);
    if (critTokens.size === 0) continue; // nothing distinctive to match on
    if (!overlapsSome(critTokens, candidateTokenSets)) {
      failures.push(
        `impl-report acceptance_criteria_met "${entry.criterion}" is marked met but maps to no named test in qa_signoff.acceptance_mapping`,
      );
    }
  }
}

function shareLabel(a, b) {
  for (const l of a) if (b.has(l)) return true;
  return false;
}

// checks_passed.test === true is corroborated against a pre-existing test-runner JSON reporter
// file, if one is present. We NEVER spawn the test runner: when no results file exists the
// check fails open (returns without a failure). A present file that records a non-passing run
// contradicts the claim and IS a failure.
function groundTestSignal(data, ev, failures) {
  if (!data.checks_passed || data.checks_passed.test !== true) return;
  if (!ev || typeof ev.testResults !== "function") return;
  let results;
  try {
    results = ev.testResults();
  } catch {
    return; // unreadable evidence: fail open
  }
  if (!results || typeof results !== "object") return; // no signal: fail open

  // Jest/Vitest-style JSON reporter shape:
  //   { success: bool, numFailedTests, numFailedTestSuites }.
  // # CUSTOMIZE: if your test runner emits a different reporter shape, adjust these fields.
  const claimsFailure =
    results.success === false ||
    (typeof results.numFailedTests === "number" && results.numFailedTests > 0) ||
    (typeof results.numFailedTestSuites === "number" && results.numFailedTestSuites > 0);
  if (claimsFailure) {
    failures.push(
      `impl-report claims checks_passed.test === true but the test-results artifact records a failing run`,
    );
  }
}

// spec.open_questions carries the one field whose whole purpose is to stop BA handing the
// judgement back: ba_recommendation. The schema walker implements `required` and `type`, so a
// key present with the empty string satisfies both — and "" is then the CHEAPEST valid value on
// the field the feature rests on, in a change whose entire point was removing a gradient where
// a blank failed and a plausible guess passed. That is the same defect one level up, and it is
// worse than a blank, because the artifact still CLAIMS a recommendation exists.
//
// minLength is not implemented by the walker (see the header) and adding it there would change
// every schema at once, so this is a bespoke check, in the same spirit as groundImplReport's
// blank-test-name rule. Only non-blank-ness is enforced; whether the recommendation is any
// GOOD is not machine-checkable and is not attempted.
export function groundOpenQuestions(data, failures = []) {
  const questions = data && data.open_questions;
  if (!Array.isArray(questions)) return failures; // absent is the normal case: fail open
  questions.forEach((q, i) => {
    if (!q || typeof q !== "object") return;
    for (const field of ["question", "why_it_matters", "ba_recommendation"]) {
      if (typeof q[field] === "string" && q[field].trim() === "") {
        failures.push(
          `spec.json open_questions[${i}].${field} is present but empty; a blank ${field} claims an answer exists where none does`,
        );
      }
    }
    // A resolution's answer carries the same weight once written: Phase 4 checks the build
    // against it and Phase 5 grades confidence on answered_by.
    if (q.resolution && typeof q.resolution === "object") {
      if (typeof q.resolution.answer === "string" && q.resolution.answer.trim() === "") {
        failures.push(
          `spec.json open_questions[${i}].resolution.answer is present but empty; an empty answer records a decision nobody made`,
        );
      }
    }
  });
  return failures;
}

export function groundImplReport(data, ev, failures = []) {
  if (!data || typeof data !== "object") return failures;
  groundFilesChanged(data, ev, failures);
  groundAcceptanceMapping(data, failures);
  groundTestSignal(data, ev, failures);
  return failures;
}

// Build the production evidence surface rooted at the worktree the artifact lives in. issueDir
// is .../<root>/.pipeline/<issue>; the worktree root is two levels up.
//
// Cross-worktree artifacts: a judge phase may gather a sibling arm's impl-report whose
// committed files live in a different tree than the one that holds the artifact. Honoring a
// verified data.worktree_path lets the grounding check corroborate against the tree the report
// actually describes, not the dir-derived tree it merely sits in. A bogus path cannot skip the
// check: it must statSync to a real directory or we fall back to the dir-derived root.
function evidenceFor(issueDir, now, data) {
  let worktreeRoot = path.resolve(issueDir, "..", "..");
  if (data && typeof data.worktree_path === "string") {
    try {
      if (statSync(data.worktree_path).isDirectory()) {
        worktreeRoot = path.resolve(data.worktree_path);
      }
    } catch {
      // unreadable worktree_path: keep the dir-derived root
    }
  }
  return {
    fileExists(relPath) {
      try {
        return existsSync(path.resolve(worktreeRoot, relPath));
      } catch {
        return true; // resolution error: skip this file (fail open)
      }
    },
    testResults() {
      // # CUSTOMIZE: candidate paths for your test runner's JSON reporter output.
      const candidates = [
        path.join(worktreeRoot, "test-results.json"),
        path.join(worktreeRoot, "coverage", "test-results.json"),
      ];
      for (const c of candidates) {
        let st;
        try {
          st = statSync(c);
        } catch {
          continue; // absent
        }
        if (now - st.mtimeMs > RECENT_MS) continue; // stale, not this run
        try {
          return loadJson(c);
        } catch {
          return null; // malformed: treat as no signal (fail open)
        }
      }
      return null; // no results file: fail open
    },
  };
}

// Returns { failures: string[] } where each entry is a human-readable violation.
// `rootsOverride` is a test-only seam (see pipelineDirs): when passed it pins root resolution
// to exactly those roots so a self-test can never escape to the real .pipeline of the checkout
// running it. Production callers never pass it.
export function checkArtifacts(agentType, input, now = Date.now(), rootsOverride) {
  const rules = AGENT_RULES[String(agentType || "").toLowerCase()];
  const failures = [];
  if (!rules) return { failures };

  const schemaCache = new Map();
  for (const dir of pipelineDirs(input, rootsOverride)) {
    const projectRoot = path.dirname(dir); // <root> for a <root>/.pipeline dir
    let sawRecent = false; // any recent artifact for this agent in this root
    // Scope to the single active issue dir, not every sibling in this root. A null means no
    // active issue is derivable here (no signal, no status.json), so this session owns nothing
    // to validate: skip the root entirely (fail-open).
    const issueDir = activeIssueDir(dir, input);
    if (issueDir) {
      for (const rule of rules) {
        const artifactPath = path.join(issueDir, rule.artifact);
        let st;
        try {
          st = statSync(artifactPath);
        } catch {
          continue; // artifact absent: not a failure
        }
        if (now - st.mtimeMs > RECENT_MS) continue; // stale dir, not this run
        sawRecent = true;

        let data;
        try {
          data = loadJson(artifactPath);
        } catch (e) {
          failures.push(`${path.relative(projectRoot, artifactPath)}: not valid JSON (${e.message})`);
          continue;
        }

        const slice = dataAt(data, rule.dataPtr);
        if (slice === undefined) continue; // this agent's block not written yet

        const schemaFile = path.join(SCHEMA_DIR, rule.schema);
        if (!existsSync(schemaFile)) continue; // no schema to check against
        let root = schemaCache.get(schemaFile);
        if (!root) {
          try {
            root = loadJson(schemaFile);
          } catch {
            continue;
          }
          schemaCache.set(schemaFile, root);
        }
        const subSchema = schemaAt(root, rule.schemaPtr);
        if (!subSchema) continue;

        const errs = validate(slice, subSchema, root, "");
        for (const e of errs) {
          const where = rule.dataPtr ? `${rule.artifact}${rule.dataPtr}` : rule.artifact;
          failures.push(`${where} ${e}`);
        }

        // Ground the full impl-report (not the qa_signoff slice) against cheap, read-only
        // evidence. Only the dev rule validates the whole file (dataPtr ""); the qa rule's
        // qa_signoff slice is shape-only.
        if (rule.artifact === "impl-report.json" && rule.dataPtr === "") {
          try {
            groundImplReport(data, evidenceFor(issueDir, now, data), failures);
          } catch {
            // grounding must never wedge a stop; swallow and continue
          }
        }

        if (rule.artifact === "spec.json" && rule.dataPtr === "") {
          try {
            groundOpenQuestions(data, failures);
          } catch {
            // same contract as groundImplReport: never wedge a stop
          }
        }
      }
    }
    // The most-specific root that holds this agent's recent artifacts is the session's own; do
    // not scan further roots, where another session's recent artifacts would produce
    // cross-worktree false blocks.
    if (sawRecent) break;
  }
  return { failures };
}

// ---- self-test (no external fixtures needed beyond the shipped ../schemas) ---

function selfTest() {
  const required = ["spec.schema.json", "review.schema.json", "peer-review.schema.json"];
  for (const s of required) {
    if (!existsSync(path.join(SCHEMA_DIR, s))) {
      console.error(
        `self-test: schema ${s} not found in ${SCHEMA_DIR}. The plugin ships schemas in ` +
          `../schemas/; the self-test cannot run without them.`,
      );
      process.exit(1);
    }
  }

  const specSchema = loadJson(path.join(SCHEMA_DIR, "spec.schema.json"));
  const reviewSchema = loadJson(path.join(SCHEMA_DIR, "review.schema.json"));
  const peerSchema = loadJson(path.join(SCHEMA_DIR, "peer-review.schema.json"));
  let pass = 0;
  let fail = 0;
  const check = (name, got, wantErrors) => {
    const ok = wantErrors ? got.length > 0 : got.length === 0;
    if (ok) {
      pass++;
      console.error(`  ok   ${name}`);
    } else {
      fail++;
      console.error(`  FAIL ${name} -> ${JSON.stringify(got)}`);
    }
  };

  // ---- spec shape ----
  const goodSpec = {
    issue_number: 1, title: "x", problem: "p", requirements: ["r"],
    acceptance_criteria: ["a"], impacted_domains: ["api"], trivial: false,
    ba_approved_at: "2026-01-01T00:00:00Z",
  };
  check("valid spec", validate(goodSpec, specSchema, specSchema), false);
  check("spec missing requirements", validate({ ...goodSpec, requirements: undefined }, specSchema, specSchema), true);
  check("spec bad domain enum", validate({ ...goodSpec, impacted_domains: ["nope"] }, specSchema, specSchema), true);
  check("spec empty requirements (minItems)", validate({ ...goodSpec, requirements: [] }, specSchema, specSchema), true);
  check("spec wrong type for trivial", validate({ ...goodSpec, trivial: "false" }, specSchema, specSchema), true);

  // ---- review agentBlock + SecOps VETO union ----
  const agentBlock = schemaAt(reviewSchema, "#/definitions/agentBlock");
  const goodBlock = { verdict: "APPROVE", reviewed_at: "2026-01-01T00:00:00Z", concerns: [], notes: "n" };
  check("valid dba block", validate(goodBlock, agentBlock, reviewSchema), false);
  check("dba block bad verdict", validate({ ...goodBlock, verdict: "MAYBE" }, agentBlock, reviewSchema), true);
  const secopsSchema = schemaAt(reviewSchema, "#/properties/secops");
  check("secops VETO accepted (allOf enum union)", validate({ ...goodBlock, verdict: "VETO" }, secopsSchema, reviewSchema), false);
  check("review agentBlock notes-as-array accepted", validate({ ...goodBlock, notes: ["n1", "n2"] }, agentBlock, reviewSchema), false);

  // ---- peer-review verdict vocabulary ----
  const panelVerdict = schemaAt(peerSchema, "#/definitions/panelVerdict");
  check("panel APPROVE_WITH_NOTES accepted (canonical)", validate({ verdict: "APPROVE_WITH_NOTES" }, panelVerdict, peerSchema), false);
  check("panel APPROVE_WITH_NITS accepted (legacy alias)", validate({ verdict: "APPROVE_WITH_NITS" }, panelVerdict, peerSchema), false);
  check("panel REQUEST_REFACTOR accepted (QA)", validate({ verdict: "REQUEST_REFACTOR" }, panelVerdict, peerSchema), false);
  check("panel VETO accepted (SecOps)", validate({ verdict: "VETO" }, panelVerdict, peerSchema), false);
  check("panel notes-as-array accepted", validate({ verdict: "APPROVE", notes: ["a", "b"] }, panelVerdict, peerSchema), false);
  check("panel major severity accepted", validate({ verdict: "APPROVE", concerns: [{ severity: "major", description: "d" }] }, panelVerdict, peerSchema), false);
  check("panel bad verdict rejected", validate({ verdict: "LGTM" }, panelVerdict, peerSchema), true);
  check("final_verdict SECOPS_VETO accepted", validate({ final_verdict: "SECOPS_VETO", reviewed_at: "2026-01-01T00:00:00Z" }, peerSchema, peerSchema), false);
  check("final_verdict APPROVE_WITH_NOTES accepted", validate({ final_verdict: "APPROVE_WITH_NOTES", reviewed_at: "2026-01-01T00:00:00Z" }, peerSchema, peerSchema), false);
  // A security reviewer's CVE-style concern severity validates cleanly alongside the canonical
  // blocker|major|nit vocabulary; a garbage severity still rejects.
  check("panel concern severity 'low' accepted (CVE-style)", validate({ verdict: "APPROVE", concerns: [{ severity: "low", description: "d" }] }, panelVerdict, peerSchema), false);
  check("panel concern severity 'critical' accepted (CVE-style)", validate({ verdict: "REQUEST_CHANGES", concerns: [{ severity: "critical", description: "d" }] }, panelVerdict, peerSchema), false);
  check("panel concern severity rejects a garbage value", validate({ verdict: "APPROVE", concerns: [{ severity: "spicy", description: "d" }] }, panelVerdict, peerSchema), true);

  // ---- grounding: impl-report claims vs evidence ----
  const evAllExist = { fileExists: () => true, testResults: () => null };
  const evNothingExists = { fileExists: () => false, testResults: () => null };
  const evTestPassed = { fileExists: () => true, testResults: () => ({ success: true, numFailedTests: 0 }) };
  const evTestFailed = { fileExists: () => true, testResults: () => ({ success: false, numFailedTests: 3 }) };
  const evNoSurface = undefined;

  const groundedReport = {
    commits: [{ sha: "abc", message: "feat: x", files_changed: ["scripts/x.mjs", "scripts/y.mjs"] }],
    acceptance_criteria_met: [{ criterion: "user can fetch", met: true, evidence: "test" }],
    checks_passed: { typecheck: true, test: true, lint: true },
    qa_signoff: { acceptance_mapping: [{ criterion: "user can fetch", test: "fetches own records" }] },
  };

  // files_changed grounding
  check("grounding: all claimed files exist (pass)", groundImplReport(groundedReport, evAllExist), false);
  check("grounding: claimed file missing (fail)", groundImplReport(groundedReport, evNothingExists), true);
  check("grounding: no evidence surface skips file check (pass)", groundImplReport(groundedReport, evNoSurface), false);

  // files_removed: a changed file recorded as removed is exempt from the existence check, but
  // a changed-and-absent file NOT recorded as removed still fails.
  const removedTopLevel = {
    ...groundedReport,
    commits: [{ sha: "abc", message: "chore: drop x", files_changed: ["scripts/gone.mjs"] }],
    files_removed: ["scripts/gone.mjs"],
  };
  check("grounding: removed file in top-level files_removed exempt (pass)", groundImplReport(removedTopLevel, evNothingExists), false);

  const removedPerCommit = {
    ...groundedReport,
    commits: [{ sha: "abc", message: "chore: drop x", files_changed: ["scripts/gone.mjs"], files_removed: ["scripts/gone.mjs"] }],
  };
  check("grounding: removed file in commit files_removed exempt (pass)", groundImplReport(removedPerCommit, evNothingExists), false);

  const changedAbsentNotRemoved = {
    ...groundedReport,
    commits: [{ sha: "abc", message: "chore: x", files_changed: ["scripts/present.mjs", "scripts/missing.mjs"], files_removed: ["scripts/gone.mjs"] }],
    files_removed: ["scripts/other-gone.mjs"],
  };
  check("grounding: changed-and-absent file not in files_removed still fails (fail)", groundImplReport(changedAbsentNotRemoved, evNothingExists), true);

  // Per-commit files_removed must NOT leak across commits.
  const perCommitRemovedDoesNotLeak = {
    ...groundedReport,
    commits: [
      { sha: "c1", message: "chore: drop gone", files_changed: ["scripts/gone.mjs"], files_removed: ["scripts/gone.mjs"] },
      { sha: "c2", message: "chore: touch gone again", files_changed: ["scripts/gone.mjs"] },
    ],
  };
  check("grounding: commit files_removed does not leak to a later commit (fail)", groundImplReport(perCommitRemovedDoesNotLeak, evNothingExists), true);

  // Top-level files_removed reaches every commit, not just the first.
  const topLevelRemovedReachesLaterCommit = {
    ...groundedReport,
    commits: [
      { sha: "c1", message: "feat: real change", files_changed: [] },
      { sha: "c2", message: "chore: drop gone", files_changed: ["scripts/gone.mjs"] },
    ],
    files_removed: ["scripts/gone.mjs"],
  };
  check("grounding: top-level files_removed exempts a later commit (pass)", groundImplReport(topLevelRemovedReachesLaterCommit, evNothingExists), false);

  // acceptance_criteria_met -> mapping grounding
  const unmappedMet = {
    ...groundedReport,
    qa_signoff: { acceptance_mapping: [{ criterion: "some other thing", test: "t" }] },
  };
  check("grounding: met criterion absent from non-empty mapping (fail)", groundImplReport(unmappedMet, evAllExist), true);

  const docOnlyMet = { ...groundedReport, qa_signoff: { acceptance_mapping: [] } };
  check("grounding: met criteria with no mapping declared fails open (pass)", groundImplReport(docOnlyMet, evAllExist), false);

  const noQaSignoffMet = {
    commits: groundedReport.commits,
    acceptance_criteria_met: groundedReport.acceptance_criteria_met,
    checks_passed: groundedReport.checks_passed,
  };
  check("grounding: met criteria with no qa_signoff block fails open (pass)", groundImplReport(noQaSignoffMet, evAllExist), false);

  const mappedButBlankTest = {
    ...groundedReport,
    qa_signoff: { acceptance_mapping: [{ criterion: "user can fetch", test: "  " }] },
  };
  check("grounding: met criterion mapped to blank test name (fail)", groundImplReport(mappedButBlankTest, evAllExist), true);

  const notMet = {
    ...groundedReport,
    acceptance_criteria_met: [{ criterion: "user can fetch", met: false }],
    qa_signoff: { acceptance_mapping: [] },
  };
  check("grounding: criterion not marked met needs no mapping (pass)", groundImplReport(notMet, evAllExist), false);

  // Short-label mapping must not spuriously block; a genuinely unmapped met criterion still does.
  const shortLabelMapping = {
    ...groundedReport,
    acceptance_criteria_met: [
      { criterion: "a planted schema defect in a sibling issue dir does not block the active session", met: true, evidence: "self-test" },
    ],
    qa_signoff: { acceptance_mapping: [{ criterion: "AC1", test: "sibling-issue isolation self-test case" }] },
  };
  check("grounding: full-sentence met criterion mapped to short label 'AC1' does not block (pass)", groundImplReport(shortLabelMapping, evAllExist), false);

  const labelBothSides = {
    ...groundedReport,
    acceptance_criteria_met: [{ criterion: "AC2 continued active-issue strictness", met: true, evidence: "self-test" }],
    qa_signoff: { acceptance_mapping: [{ criterion: "AC2", test: "active-issue strictness self-test case" }] },
  };
  check("grounding: met criterion and mapping share AC label matches (pass)", groundImplReport(labelBothSides, evAllExist), false);

  const stillBlocks = {
    ...groundedReport,
    acceptance_criteria_met: [{ criterion: "webhook signature verification is timing safe", met: true, evidence: "x" }],
    qa_signoff: { acceptance_mapping: [{ criterion: "some entirely different subject matter here", test: "unrelated coverage" }] },
  };
  check("grounding: an unmapped met criterion with no short-label wildcard still blocks (fail)", groundImplReport(stillBlocks, evAllExist), true);

  // test-signal grounding
  check("grounding: test claimed true + results record pass (pass)", groundImplReport(groundedReport, evTestPassed), false);
  check("grounding: test claimed true + results record failure (fail)", groundImplReport(groundedReport, evTestFailed), true);
  check("grounding: test claimed true + no results file fails open (pass)", groundImplReport(groundedReport, evAllExist), false);
  const testClaimedFalse = { ...groundedReport, checks_passed: { typecheck: true, test: false, lint: true } };
  check("grounding: test not claimed true skips signal check (pass)", groundImplReport(testClaimedFalse, evTestFailed), false);

  // ---- active-issue scoping: pure activeIssueDir derivation ----
  {
    const root = mkdtempSync(path.join(tmpdir(), "vpa-active-"));
    const prevEnv = { a: process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE, b: process.env.PIPELINE_ACTIVE_ISSUE };
    try {
      const pipe = path.join(root, ".pipeline");
      const active = path.join(pipe, "1965");
      const sibling = path.join(pipe, "1964");
      mkdirSync(active, { recursive: true });
      mkdirSync(sibling, { recursive: true });
      writeFileSync(path.join(active, "status.json"), JSON.stringify({ issue_number: 1965 }));
      writeFileSync(path.join(sibling, "status.json"), JSON.stringify({ issue_number: 1964 }));
      // Force the sibling's status.json newer, so mtime derivation alone would pick it.
      const later = (Date.now() + 5000) / 1000;
      utimesSync(path.join(sibling, "status.json"), later, later);

      delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      delete process.env.PIPELINE_ACTIVE_ISSUE;
      check("active-issue: newest status.json mtime wins with no marker",
        activeIssueDir(pipe, {}) === sibling ? [] : ["expected sibling by mtime"], false);
      check("active-issue: stdin active_issue marker beats mtime",
        activeIssueDir(pipe, { active_issue: "1965" }) === active ? [] : ["expected active by marker"], false);
      process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE = "1965";
      check("active-issue: env CLAUDE_PIPELINE_ACTIVE_ISSUE beats mtime",
        activeIssueDir(pipe, {}) === active ? [] : ["expected active by env"], false);
      delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      check("active-issue: marker for an absent dir falls back to mtime",
        activeIssueDir(pipe, { active_issue: "9999" }) === sibling ? [] : ["expected mtime fallback"], false);
      check("active-issue: marker with a slash is rejected (traversal guard)",
        activeIssueDir(pipe, { active_issue: "../schemas" }) === sibling ? [] : ["expected traversal reject"], false);

      // no status.json anywhere and no marker: null -> validate nothing (fail-open).
      const emptyRoot = mkdtempSync(path.join(tmpdir(), "vpa-empty-"));
      try {
        const emptyPipe = path.join(emptyRoot, ".pipeline");
        mkdirSync(path.join(emptyPipe, "1200"), { recursive: true }); // dir, but no status.json
        check("active-issue: no status.json + no marker resolves to null (fail-open)",
          activeIssueDir(emptyPipe, {}) === null ? [] : ["expected null"], false);
      } finally {
        rmSync(emptyRoot, { recursive: true, force: true });
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
      if (prevEnv.a === undefined) delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      else process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE = prevEnv.a;
      if (prevEnv.b === undefined) delete process.env.PIPELINE_ACTIVE_ISSUE;
      else process.env.PIPELINE_ACTIVE_ISSUE = prevEnv.b;
    }
  }

  // ---- active-issue scoping: end-to-end checkArtifacts, hermetic via rootsOverride ----
  //
  // Every case pins root resolution to the temp tree via the rootsOverride seam, so no case can
  // fall through to the real .pipeline of the checkout running the self-test. A separate decoy
  // checkout holds a DEFECT and is pointed at by the ambient roots to PROVE the override keeps
  // the real-root defect out.
  {
    const root = mkdtempSync(path.join(tmpdir(), "vpa-scope-"));
    const decoyCheckout = mkdtempSync(path.join(tmpdir(), "vpa-decoy-"));
    const prevProject = process.env.CLAUDE_PROJECT_DIR;
    const prevEnvA = process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
    const prevEnvB = process.env.PIPELINE_ACTIVE_ISSUE;
    const prevCwd = process.cwd();
    try {
      const pipe = path.join(root, ".pipeline");
      const active = path.join(pipe, "1965");
      const sibling = path.join(pipe, "1964");
      mkdirSync(active, { recursive: true });
      mkdirSync(sibling, { recursive: true });

      const validPanel = { verdict: "APPROVE", reviewed_at: "2026-01-01T00:00:00Z", concerns: [], notes: "n" };
      const brokenPanel = { verdict: "NOT_A_VERDICT" };

      const decoyPipe = path.join(decoyCheckout, ".pipeline");
      const decoyIssue = path.join(decoyPipe, "9001");
      mkdirSync(decoyIssue, { recursive: true });
      writeFileSync(path.join(decoyIssue, "status.json"), JSON.stringify({ issue_number: 9001 }));
      writeFileSync(path.join(decoyIssue, "peer-review.secops.json"), JSON.stringify(brokenPanel));

      process.env.CLAUDE_PROJECT_DIR = decoyCheckout;
      process.chdir(decoyCheckout);
      delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      delete process.env.PIPELINE_ACTIVE_ISSUE;
      const pin = [root];

      // Case 1: sibling holds a DEFECT, active holds a VALID artifact. No block.
      writeFileSync(path.join(active, "status.json"), JSON.stringify({ issue_number: 1965 }));
      writeFileSync(path.join(active, "peer-review.secops.json"), JSON.stringify(validPanel));
      writeFileSync(path.join(sibling, "status.json"), JSON.stringify({ issue_number: 1964 }));
      writeFileSync(path.join(sibling, "peer-review.secops.json"), JSON.stringify(brokenPanel));
      const r1 = checkArtifacts("secops", { cwd: root, active_issue: "1965" }, Date.now(), pin);
      check("scoping: sibling defect does NOT block the active session (pass)", r1.failures, false);

      // Case 2: the ACTIVE issue's own artifact is broken. Block fires.
      writeFileSync(path.join(active, "peer-review.secops.json"), JSON.stringify(brokenPanel));
      const r2 = checkArtifacts("secops", { cwd: root, active_issue: "1965" }, Date.now(), pin);
      check("scoping: active-issue defect DOES block (fail)", r2.failures, true);

      // Case 3: no derivable active issue -> block nothing even though the sibling holds a defect.
      rmSync(path.join(active, "status.json"), { force: true });
      rmSync(path.join(sibling, "status.json"), { force: true });
      const r3 = checkArtifacts("secops", { cwd: root }, Date.now(), pin);
      check("scoping: no active issue derivable blocks nothing despite a sibling defect (pass)", r3.failures, false);
      check("scoping: ambient .pipeline defect can NOT perturb a temp-scoped case (isolation)", r3.failures, false);

      // Control: WITHOUT the override, the same ambient decoy DOES surface its block, proving the
      // decoy is genuinely defective (so the isolation case is meaningful).
      const rDecoy = checkArtifacts("secops", { cwd: decoyCheckout });
      check("scoping: the decoy ambient defect is genuinely detectable without the override (control)", rDecoy.failures, true);
    } finally {
      process.chdir(prevCwd);
      rmSync(root, { recursive: true, force: true });
      rmSync(decoyCheckout, { recursive: true, force: true });
      if (prevProject === undefined) delete process.env.CLAUDE_PROJECT_DIR;
      else process.env.CLAUDE_PROJECT_DIR = prevProject;
      if (prevEnvA === undefined) delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      else process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE = prevEnvA;
      if (prevEnvB === undefined) delete process.env.PIPELINE_ACTIVE_ISSUE;
      else process.env.PIPELINE_ACTIVE_ISSUE = prevEnvB;
    }
  }

  // ---- active-issue scoping: numeric-name convention on both paths ----
  {
    const root = mkdtempSync(path.join(tmpdir(), "vpa-numeric-"));
    const prevEnv = { a: process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE, b: process.env.PIPELINE_ACTIVE_ISSUE };
    try {
      const pipe = path.join(root, ".pipeline");
      const issue = path.join(pipe, "1965");
      const schemasDir = path.join(pipe, "schemas");
      const archived = path.join(pipe, "_archived");
      mkdirSync(issue, { recursive: true });
      mkdirSync(schemasDir, { recursive: true });
      mkdirSync(archived, { recursive: true });
      writeFileSync(path.join(issue, "status.json"), JSON.stringify({ issue_number: 1965 }));
      // Give the NON-issue dirs a NEWER status.json so, absent the numeric guard, the mtime scan
      // would wrongly select them over the real issue dir.
      writeFileSync(path.join(schemasDir, "status.json"), JSON.stringify({ x: 1 }));
      writeFileSync(path.join(archived, "status.json"), JSON.stringify({ x: 1 }));
      const later = (Date.now() + 5000) / 1000;
      utimesSync(path.join(schemasDir, "status.json"), later, later);
      utimesSync(path.join(archived, "status.json"), later, later);

      delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      delete process.env.PIPELINE_ACTIVE_ISSUE;

      check("active-issue: mtime scan ignores non-issue dirs and picks the numeric issue",
        activeIssueDir(pipe, {}) === issue ? [] : ["expected numeric issue dir by mtime"], false);
      check("active-issue: marker 'schemas' rejected (non-numeric), falls back to mtime",
        activeIssueDir(pipe, { active_issue: "schemas" }) === issue ? [] : ["expected mtime fallback for non-numeric marker"], false);
      check("active-issue: marker '_archived' rejected (non-numeric), falls back to mtime",
        activeIssueDir(pipe, { active_issue: "_archived" }) === issue ? [] : ["expected mtime fallback for _archived marker"], false);
      check("active-issue: numeric marker still resolves its issue dir",
        activeIssueDir(pipe, { active_issue: "1965" }) === issue ? [] : ["expected numeric marker to resolve"], false);
    } finally {
      rmSync(root, { recursive: true, force: true });
      if (prevEnv.a === undefined) delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      else process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE = prevEnv.a;
      if (prevEnv.b === undefined) delete process.env.PIPELINE_ACTIVE_ISSUE;
      else process.env.PIPELINE_ACTIVE_ISSUE = prevEnv.b;
    }
  }

  console.error(`\nself-test: ${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
}

// ---- main -------------------------------------------------------------------

async function main() {
  let raw = "";
  for await (const chunk of process.stdin) raw += chunk;

  let input = {};
  try {
    input = JSON.parse(raw || "{}");
  } catch {
    return; // no/garbled payload: fail open
  }

  const { failures } = checkArtifacts(input.agent_type, input);
  if (failures.length === 0) return; // allow stop

  const reason =
    `Pipeline artifact failed schema validation (../schemas). ` +
    `Fix the artifact before finishing:\n- ${failures.join("\n- ")}`;
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
}

const isMain = isMainScript("validate-pipeline-artifact.mjs");

if (isMain) {
  if (process.argv.includes("--self-test")) {
    // Self-test surfaces failures loudly (exit 1); it is NOT under the fail-open catch.
    selfTest();
  } else {
    main().catch(() => {
      // fail open: a validator crash must never block a legitimate stop
      process.exit(0);
    });
  }
}
