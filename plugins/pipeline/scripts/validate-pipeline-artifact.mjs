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
 *   - Hook mode (default, stdin payload): exit 0 on pass; a `{decision:"block",...}` JSON object
 *     on STDOUT on failure (still exit 0 -- the block is advisory to the agent); any crash exits
 *     0 (fail open).
 *   - STDERR carries one attribution line per run saying what the gate DID -- which agent, which
 *     verdict, which run dir, how many violations -- including on a clean pass and on every
 *     fail-open path. It is silent only where there is no .pipeline directory at all. See
 *     announceLine() for why the success case speaks and why that one silence stays. stdout is
 *     unaffected: the decision channel is still pure JSON or nothing.
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
import { inFlightObservations } from "./run-candidates.mjs";
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

// Shipped pipeline agents that own NO schema-validated artifact, so an AGENT_RULES miss at their
// stop is the CORRECT outcome and not a gap. Declaring them is what lets the announcement below
// grade a miss instead of reporting every miss identically: "design stopped and owns nothing" and
// "a name nobody registered stopped" are different events, and only the second is a finding.
//
// THIS LIST IS CONFIGURATION, NOT HISTORY, and that distinction is #66's property 3. Inferring
// which agents should be validated from which agents HAVE been validated makes an inert gate look
// like a smaller working one -- the exact reading that let this validator sit silent from its
// first release commit until a 353,907-line transcript census went looking. So the union
// `Object.keys(AGENT_RULES) + ARTIFACTLESS_AGENTS` is asserted set-equal to the `name:` frontmatter
// of every agents/*.md the plugin ships, by tests/test-validate-pipeline-artifact.sh. Adding an
// agent file without deciding which side it belongs on reddens that case; so does deleting one.
export const ARTIFACTLESS_AGENTS = new Set(["design", "art-director"]);

// The roles AGENT_RULES actually validates. Exported as a copy so the completeness check above can
// compare it against the shipped agent manifest without handing anyone a mutable rules table.
export function registeredAgents() {
  return Object.keys(AGENT_RULES);
}

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
export function pipelineDirs(input, rootsOverride) {
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

// A .pipeline issue dir is named by its numeric issue number, OR by the `exp-<slug>` placeholder
// an experiment run uses in place of a tracker issue (/pipeline --dry-run, EXPERIMENT_MODE, an
// ab_build harness). Constraining both derivation paths to this convention (rather than just
// excluding "schemas") means a non-issue sibling like "schemas" or a hypothetical "_archived"
// can never be selected as the active issue: the marker path rejects such a name (fail-open,
// falls back to mtime) and the mtime scan never enumerates it.
//
// The exp- half was missing until now, and its absence was worse than it looks. An experiment
// run had NO artifact validation at all: the pattern did not match, so the mtime scan skipped
// the dir entirely and every schema check silently passed. Paired with pipeline.md's deliberate
// "experiment runs never block" carve-out for the open-questions gate, that meant BOTH halves
// of a gate went inert on exactly the runs nobody is watching. The alternation stays anchored
// and separator-free, so `..`, `a/b`, `schemas` and `_archived` are all still rejected.
// EXPORTED so the other consumers of this vocabulary import it rather than restate it.
// voice-lint.mjs used to carry its own /^\d+$/ copy, which is how `exp-` runs ended up
// invisible to the voice check long after this alternation was widened to admit them: the
// second copy could not be widened by widening the first. A shared constant makes that drift
// structurally impossible rather than merely tested for.
export const ISSUE_DIR_RE = /^(\d+|exp-[a-z0-9]+(-[a-z0-9]+)*)$/;

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
//       issue is active" mechanism, and the path exercised in normal use. It must be a STRICT
//       winner: if two dirs share the newest mtime the scan has not identified an issue, it has
//       only proved it cannot, so a tie resolves to (c) rather than to either candidate.
//   (c) neither resolves: return null. The caller then validates nothing in this root
//       (fail-open): an ad-hoc or non-pipeline session owns no issue dir and must never be
//       blocked by artifacts it did not write. A tie under (b) lands here for the same reason
//       -- the cost of guessing wrong is blocking a stop for an issue this session never
//       touched, and there is no evidence available to guess from.
export function activeIssueName(input) {
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
  let tiedAtNewest = false;
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
      tiedAtNewest = false;
    } else if (st.mtimeMs === newestMtime) {
      tiedAtNewest = true;
    }
  }
  // A TIE at the newest mtime is the ABSENCE of a signal, not a weaker one, so it resolves the
  // same way absence does: null. Both are order-independent -- a strict max does not depend on
  // enumeration order, and a tie is detected whichever order it arrives in -- which is the
  // point. Previously the winner of a tie was decided by readdirSync order: hash order on ext4,
  // roughly insertion order on APFS. That made "which issue is active" a property of the
  // filesystem, and it is reachable in production, not just in theory: a fresh `git clone`
  // writes every tracked .pipeline/<issue>/status.json within a few milliseconds, and Linux
  // stamps file times from a clock that ticks coarser than that, so they land on the identical
  // mtime and RECENT_MS (30min) does not filter them out. Picking one would be inventing
  // evidence the scan does not have -- and picking the wrong one blocks a stop, or refuses a
  // phase entry, for work this session never touched, which is the exact harm the scoping in
  // this function exists to prevent. Precedence (a) is unaffected: an explicit signal still
  // resolves, ties or no ties.
  return tiedAtNewest ? null : newest;
}

function loadJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

// The status schema's OWN `current_phase` pattern, read from the shipped schema rather than
// restated here. A second copy of a vocabulary is how `exp-` runs stayed invisible to voice-lint
// for months (see ISSUE_DIR_RE above), and this one would rot the same way: the phase list grows
// whenever commands/pipeline.md writes a new checkpoint, and a hardcoded twin would silently stop
// recognising the newest runs -- failing in the INERT direction, which is the direction this whole
// change exists to close. Cached because unnamedRunDirs runs once per root per stop.
// `undefined` = not yet read, `null` = schema unreadable (see the caller's fallback).
let _phasePatternCache;
function runPhasePattern() {
  if (_phasePatternCache !== undefined) return _phasePatternCache;
  _phasePatternCache = null;
  try {
    const schema = loadJson(path.join(SCHEMA_DIR, "status.schema.json"));
    const p = schema?.properties?.current_phase?.pattern;
    if (typeof p === "string" && p.length > 0) _phasePatternCache = new RegExp(p);
  } catch {
    // Unreadable schema: the caller falls back to "current_phase is a non-empty string".
  }
  return _phasePatternCache;
}

/**
 * The .pipeline subdirectories that HOLD A RUN RECORD but that ISSUE_DIR_RE will not name (#115).
 *
 * THE DEFECT. issueDirs() filters on the DIRECTORY NAME and nothing else, so a run whose dir BA
 * could name neither `<number>` (the tracker was unreachable, auth had expired, the host was
 * offline) nor `exp-<slug>` (it is not an experiment -- ba.md duty 8 sanctions no third branch)
 * is dropped with no record that it was dropped. Measured on the shipped hook: one fixture with
 * 14 schema violations emits a 1180-byte decision:block from `.pipeline/9001` and 0 bytes from
 * `.pipeline/tracker-unreachable-20260902`. The name is the only difference, and the whole run
 * silently opts out of every check issueDirs() feeds.
 *
 * WHY THIS IS A SEPARATE FUNCTION AND NOT A WIDER ISSUE_DIR_RE. Widening the regex would change
 * three OTHER consumers at once, two of which REFUSE work: voice-lint.mjs's sweep,
 * gate-phase-entry.mjs (which can refuse a phase entry) and -- through issueDirs() ->
 * resolveRunOwner() -- #106's PreToolUse gate, which DENIES tool calls. Admitting a new directory
 * shape there could manufacture a refusal against correct work, which is the harm the scoping in
 * activeIssueDir exists to prevent. So the vocabulary those consumers share is untouched, and the
 * recovery lives ONLY in checkArtifacts, whose worst case is an advisory decision:block telling an
 * agent to fix an artifact it just wrote.
 *
 * THE PREDICATE, and what each clause refuses. A directory qualifies when its name is NOT an issue
 * name, it holds a parseable `status.json` OBJECT, and that object's `current_phase` is a string
 * matching the status schema's own pattern. The last clause is what keeps a non-run sibling out:
 * `.pipeline/schemas` and `.pipeline/_archived` are the two names this repo's own tree and
 * self-test fixture put next to real runs, and neither carries a phase-shaped `current_phase`.
 * `current_phase` is `required` in status.schema.json and present in all 13 committed records in
 * this repo (`node -e` over every `.pipeline/<issue>/status.json`, 2026-09-02), so the clause costs
 * a real run nothing. THE CORRECT WORK THIS COULD REFUSE, stated because a guardrail owes that: a directory
 * that is not a run, carries a phase-shaped status.json anyway, AND holds a recent artifact this
 * agent owns that fails its schema. Nothing writes that shape; a run record is written by the
 * orchestrator and by nothing else.
 */
export function unnamedRunDirs(pipelineDir) {
  const out = [];
  let entries;
  try {
    entries = readdirSync(pipelineDir, { withFileTypes: true });
  } catch {
    return out;
  }
  const phasePattern = runPhasePattern();
  for (const d of entries) {
    if (!d.isDirectory() || ISSUE_DIR_RE.test(d.name)) continue;
    const dir = path.join(pipelineDir, d.name);
    let status;
    try {
      status = loadJson(path.join(dir, "status.json"));
    } catch {
      continue; // no record, or an unreadable one: not evidence of a run
    }
    if (!status || typeof status !== "object" || Array.isArray(status)) continue;
    const phase = status.current_phase;
    if (typeof phase !== "string" || phase.length === 0) continue;
    if (phasePattern && !phasePattern.test(phase)) continue;
    out.push(dir);
  }
  return out;
}

/**
 * An installed-plugin dispatch carries a NAMESPACED agent_type ("pipeline:secops",
 * "plugin:pipeline:secops"), a local-file dispatch carries the bare role. Take the segment after
 * the LAST colon so the two resolve identically. Exported because #106's PreToolUse gate needs
 * the same reading for its role attribution, and a second copy is exactly how `exp-` runs stayed
 * invisible to voice-lint.mjs for months (see ISSUE_DIR_RE's comment above).
 */
export function bareRole(agentType) {
  return String(agentType || "")
    .split(":")
    .pop()
    .trim()
    .toLowerCase();
}

/**
 * RUN OWNERSHIP: which recorded run does a call belong to, and how do we know.
 *
 * activeIssueDir answers "which dir is active" from directory names, status.json mtime and the
 * explicit marker, and it is IN-FLIGHT BLIND on both paths -- it never reads `final_verdict` or
 * `updated_at`. That is right for the SubagentStop sweep, whose question is "which artifact did
 * this stop just write", and wrong for a caller that must decide whose RUN a tool call belongs
 * to: after a fresh `git clone` every tracked status.json carries a new mtime, and the raw
 * answer on a clone of this repository is a record whose own `final_verdict` says its run ended.
 *
 * So this is a second QUESTION over the same records, not a second derivation of the first:
 *
 *   (1) Narrow to the CANDIDATE set: no `final_verdict`, and either datable-and-recent or not
 *       datable at all (run-candidates.mjs holds that predicate; an undatable record counts, so
 *       it can never shrink a set to one).
 *   (2) ZERO candidates -> no owner. The caller abstains.
 *   (3) An explicit marker naming a record that is itself IN FLIGHT resolves the owner, and the
 *       answer is labelled `marker` so an over-refusal is diagnosable in one look. A marker
 *       naming a record the narrowing excludes is not honoured and falls through, which is what
 *       stops a stale signal manufacturing denies forever.
 *   (4) EXACTLY ONE candidate -> that record is the owner, labelled `inference`. If it cannot be
 *       dated it is NOT the owner: its recency is unknowable by construction, so treating it as
 *       one would let an arbitrarily old abandoned run author a refusal.
 *   (5) TWO OR MORE -> no owner. Not a tie-break, not newest-wins: mtime is not consulted in
 *       this branch at all, because the answer it would give is the one that refuses correct
 *       work in the clone case above.
 *
 * `pipelineDirs` may be a single .pipeline path or a list of them; the candidate set is the
 * UNION across every root, so a second root's record cannot override the first root's answer.
 *
 * Returns { provenance, dir, issue, phase, reason } where provenance is "marker" | "inference" |
 * "none" and `reason` names the non-action for a caller that has to attribute it. Nothing here
 * counts candidates OUT loud: two callers looking at different roots with the same shape must be
 * able to attribute the same way.
 */
export function resolveRunOwner(pipelineDirsIn, input, now = Date.now(), ceilingMs) {
  const roots = Array.isArray(pipelineDirsIn) ? pipelineDirsIn : [pipelineDirsIn];
  const marker = activeIssueName(input);
  const candidates = [];
  const seen = new Set();
  let unreadable = false;
  let sawRoot = false;

  for (const root of roots) {
    if (!root) continue;
    sawRoot = true;
    for (const dir of issueDirs(root)) {
      const file = path.join(dir, "status.json");
      let status;
      try {
        status = loadJson(file);
      } catch {
        // A status.json that exists and will not parse is a tooling gap of its own: the caller
        // must be able to tell it from "this root holds no runs".
        if (existsSync(file)) unreadable = true;
        continue;
      }
      const obs =
        ceilingMs === undefined
          ? inFlightObservations(status, now)
          : inFlightObservations(status, now, ceilingMs);
      if (!obs.candidate) continue;
      // DE-DUPLICATED BY ISSUE NAME, AND ONLY ONCE A RECORD HAS BEEN READ. Two roots can be the
      // SAME directory reached by different spellings -- on macOS $TMPDIR is /var/... through a
      // symlink and /private/var/... resolved -- and they can also be genuinely distinct copies
      // of one run: `.pipeline/*/status.json` is git-tracked in this repository, so a `git
      // worktree add` (how every dispatch tree is made) checks out a SECOND physical copy of
      // every issue's record, and a call resolving with the worktree as cwd and the main checkout
      // as CLAUDE_PROJECT_DIR then meets issue 106 twice. A resolved-path key collapses the first
      // case and not the second, so one run read as two and the gate abstained on a run nobody
      // was ambiguous about. The name collapses both, and two roots naming DIFFERENT issues are
      // still two candidates, which is what leaves R4(3)'s abstention on real ambiguity intact.
      //
      // The key is claimed HERE and not at the top of the loop, because a directory that holds no
      // readable record must not claim it: an empty or unparseable `.pipeline/106` in the first
      // root would otherwise mask a live `.pipeline/106` in the second, and an empty directory is
      // exactly what a checkout with a gitignored .pipeline leaves behind. That sentence used to
      // be an assertion and nothing else -- the entry-claim ordering survived the whole suite --
      // so it is earned now by AC25 CLAIM SITE in tests/test-pretooluse-gate-ownership.sh, which
      // reddens under it.
      //
      // WHICH COPY WINS when two same-named copies DISAGREE is pipelineDirs' order, and that is
      // its documented "most-specific root first": the payload cwd is the tree the calling agent
      // is working in, so its record describes the run the call belongs to. AC25 ORDER and its
      // swap twin assert both directions, on copies with different content, so a reversal of that
      // root list reddens instead of passing.
      const key = path.basename(dir);
      if (seen.has(key)) continue;
      seen.add(key);
      candidates.push({
        dir,
        issue: key,
        phase: typeof status.current_phase === "string" ? status.current_phase : null,
        datable: obs.datable,
      });
    }
  }

  const none = (reason) => ({ provenance: "none", dir: null, issue: null, phase: null, reason });

  if (!sawRoot) return none("no-pipeline-root");
  if (candidates.length === 0) return none(unreadable ? "unreadable-record" : "no-in-flight-run");

  if (marker) {
    const named = candidates.find((c) => c.issue === marker && c.datable);
    if (named) {
      return { provenance: "marker", dir: named.dir, issue: named.issue, phase: named.phase, reason: "resolved" };
    }
  }

  if (candidates.length === 1) {
    const only = candidates[0];
    if (!only.datable) return none("undatable-sole-candidate");
    return { provenance: "inference", dir: only.dir, issue: only.issue, phase: only.phase, reason: "resolved" };
  }

  return none("ambiguous-owner");
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

// spec.falsifiability_pass is the can-this-redden audit, and commands/pipeline.md has claimed
// for its whole life that "the table is machine-checked against the criterion list so the two
// cannot drift". NOTHING CHECKED IT. `falsifiability_pass` appeared in zero scripts, and it is
// absent from spec.schema.json's top-level `required`, so a spec could omit the block entirely
// and still validate. This is that claim, made true.
//
// WHAT IS ENFORCED IS COVERAGE, AND ONLY COVERAGE: every acceptance criterion carries at least
// one row, in `one_mutation_per_criterion` or in `unmutable`. That is exactly the property
// pipeline.md states, and the reason it matters is that a criterion with no row is one Dev will
// implement to and QA will write a test for while nobody has asked whether it can fail.
//
// THREE THINGS ARE DELIBERATELY NOT FAILURES, because the nine archived specs show each one
// being used as considered work rather than as drift:
//
//   - EXTRA rows naming something that is not an acceptance criterion. Four archived specs
//     carry these and they are the good kind: #56 records four "R7/R12 residual limit" rows,
//     #61 records a premise annotated "deliberately not an acceptance criterion", #63 records
//     one half of AC12 whose other half is covered above. Refusing them would refuse the BA for
//     doing MORE than the contract asks.
//   - DUPLICATE labels across the two lists. #19's AC4 sits in both, on purpose and with the
//     reason written down: one half of the criterion has a real mutation (collapse two harms
//     into one sentence), the other half is a reading judgement with no mechanical failure
//     state. A criterion that is partially unmutable is a true thing to record, not a
//     contradiction to reject.
//   - The block being ABSENT below the architectural tier, where pipeline.md does not require
//     it. (#34 carries one at standard tier voluntarily; that is welcome, not mandatory.)
//
// So this gate is a RATCHET, not a retrofit: run against all nine archived specs it reports
// nothing, because their coverage is already complete. It exists for the case the corpus cannot
// show, since every archived spec is a FINAL state -- a spec REVISION that adds AC17 and no row
// for it. Specs revise often (eight times on one recorded run), the criterion list and the
// table are edited separately, and the revision is exactly when the two drift apart.
//
// IT ABSTAINS RATHER THAN GUESSING when it cannot read labels. Criteria are matched by their
// leading `AC<n>` label, which is the convention every archived spec follows on both sides. If
// no criterion carries a parseable label the matcher has nothing to match on, so it says so and
// enforces nothing, instead of reporting every criterion as uncovered. A gate that cannot
// measure must not return the answer that looks like measurement.
const AC_LABEL = /^\s*(AC\d+)\b/;

/** The leading AC label of a criterion string, or null. Applied to BOTH sides so a row that
 *  spells out the full criterion text normalizes the same way a bare "AC4" does. */
export function acLabel(value) {
  if (typeof value !== "string") return null;
  const m = AC_LABEL.exec(value);
  return m ? m[1] : null;
}

export function groundFalsifiability(data, failures = []) {
  if (!data || typeof data !== "object") return failures;
  const fp = data.falsifiability_pass;
  const architectural = data.risk_tier === "architectural";

  if (fp === undefined || fp === null) {
    // Required at the architectural tier by commands/pipeline.md and by the schema's own
    // description; below it, absent is the normal case and this fails open.
    if (architectural) {
      failures.push(
        "spec.json falsifiability_pass is absent at the architectural tier; every acceptance criterion needs a named mutation that reddens it or an `unmutable` entry with its reason, and a criterion that cannot fail is one Dev implements to and QA tests for while nobody has asked whether it can fail",
      );
    }
    return failures;
  }
  if (typeof fp !== "object" || Array.isArray(fp)) {
    failures.push("spec.json falsifiability_pass is present but is not an object");
    return failures;
  }

  const criteria = Array.isArray(data.acceptance_criteria) ? data.acceptance_criteria : [];
  if (criteria.length === 0) return failures; // nothing to cover; the schema's minItems owns this

  const labels = criteria.map(acLabel);
  if (labels.every((l) => l === null)) {
    // ABSTAIN. Reported, never silent: a reader who sees no failures here would otherwise
    // conclude the table was checked.
    failures.push(
      `spec.json falsifiability_pass could not be checked: none of the ${criteria.length} acceptance criteria carry a leading AC<n> label, so criteria and mutation rows cannot be matched. Label them (\"AC1. ...\") or check the table by hand -- this gate enforced NOTHING on this spec`,
    );
    return failures;
  }

  const rowsOf = (key) => (Array.isArray(fp[key]) ? fp[key] : []);
  const covered = new Set();
  for (const key of ["one_mutation_per_criterion", "unmutable"]) {
    for (const row of rowsOf(key)) {
      if (!row || typeof row !== "object") continue;
      const label = acLabel(row.criterion);
      if (label) covered.add(label);
    }
  }

  criteria.forEach((text, i) => {
    const label = labels[i];
    if (label === null) {
      // A single unlabeled criterion among labeled ones cannot be matched, and silently
      // skipping it is how a criterion goes uncovered without anyone being told.
      failures.push(
        `spec.json acceptance_criteria[${i}] carries no leading AC<n> label, so falsifiability_pass cannot be checked against it: ${JSON.stringify(String(text).slice(0, 80))}`,
      );
      return;
    }
    if (!covered.has(label)) {
      failures.push(
        `spec.json falsifiability_pass covers no mutation for ${label}; every acceptance criterion needs a named mutation that reddens it or an \`unmutable\` entry with its reason`,
      );
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

// Returns { failures, verdict, detail, agent, issue, roots }.
//
// `failures` is unchanged: a string[] of human-readable violations, and `const { failures } = ...`
// still destructures exactly as it did. The rest is #66's PROPERTY 2, the half that issue calls
// load-bearing: an empty `failures` used to mean three unrelated things at once -- "no rules
// matched this agent", "no run was found to check", and "this agent's artifacts are valid" -- and
// they produced byte-identical output. Measured on the shipped hook at 856a5d0 (2026-09-02):
// agent_type `pipeline:art-director` against a fixture with 14 known violations, and
// `pipeline:secops` against a genuinely clean root, both returned 0 bytes on stdout and exit 0.
// A FAIL-OPEN PATH MUST SAY THAT IT FAILED OPEN, so the reason is now carried out of here and
// announced (see announce() below, which decides WHICH of these is worth a line).
//
//   checked                -- rules matched, a run dir resolved, its artifacts were examined
//   no-rules               -- bareRole() matched no AGENT_RULES entry; `detail` grades it against
//                             ARTIFACTLESS_AGENTS, so a shipped artifact-less agent reads
//                             differently from a name nobody registered
//   no-pipeline-root       -- no .pipeline anywhere: a genuinely non-pipeline session
//   no-active-issue        -- .pipeline exists, but no run dir resolves (no status.json, or an
//                             mtime tie, which activeIssueDir treats as absence of a signal)
//   unnamed-run            -- #115: the ONLY resolvable run is one ISSUE_DIR_RE cannot name, so it
//                             was validated through the fallback below and the name is reported
//   unnamed-run-ambiguous  -- two or more such dirs: which run this stop belongs to is unknowable,
//                             so nothing was validated and the abstention is named
//
// `rootsOverride` is a test-only seam (see pipelineDirs): when passed it pins root resolution
// to exactly those roots so a self-test can never escape to the real .pipeline of the checkout
// running it. Production callers never pass it.
export function checkArtifacts(agentType, input, now = Date.now(), rootsOverride) {
  // A dispatch from the installed-plugin path (the shipping default) carries a NAMESPACED
  // agent_type ("pipeline:secops"), not the bare role name AGENT_RULES is keyed on. Take the
  // segment after the LAST colon before lowercasing, so "pipeline:secops" and "secops" resolve
  // identically. Without this, every namespaced dispatch missed AGENT_RULES entirely and this
  // validator silently checked nothing -- see #66 and #98's Phase 4 panel, which proved it live.
  const agent = bareRole(agentType);
  const rules = AGENT_RULES[agent];
  const failures = [];
  const roots = pipelineDirs(input, rootsOverride);

  if (!rules) {
    return {
      failures,
      verdict: "no-rules",
      agent,
      issue: null,
      roots: roots.length,
      detail: ARTIFACTLESS_AGENTS.has(agent)
        ? `"${agent}" is a shipped pipeline agent that owns no schema-validated artifact, so nothing was checked`
        : `"${agent}" matches no AGENT_RULES entry and is not a shipped pipeline agent, so nothing was checked`,
    };
  }
  if (roots.length === 0) {
    return { failures, verdict: "no-pipeline-root", agent, issue: null, roots: 0, detail: "no .pipeline directory in any candidate root" };
  }

  let verdict = "no-active-issue";
  let detail = `no run dir resolves under ${roots.length} .pipeline root(s)`;
  let issue = null;

  const schemaCache = new Map();
  for (const dir of roots) {
    const projectRoot = path.dirname(dir); // <root> for a <root>/.pipeline dir
    let sawRecent = false; // any recent artifact for this agent in this root
    // Scope to the single active issue dir, not every sibling in this root. A null means no
    // active issue is derivable here (no signal, no status.json), so this session owns nothing
    // to validate: skip the root entirely (fail-open).
    let issueDir = activeIssueDir(dir, input);
    let viaUnnamed = false;

    // #115 RECOVERY, and it is deliberately the LAST resort. A named dir always wins: this runs
    // only where activeIssueDir found nothing, so it can never redirect a stop away from a run
    // that resolved the ordinary way. It requires a UNIQUE candidate for the same reason
    // activeIssueDir refuses an mtime tie -- two orphaned runs are an absence of a signal, not a
    // weaker one, and guessing would block a stop for work this session never touched.
    if (!issueDir) {
      const orphans = unnamedRunDirs(dir);
      if (orphans.length === 1) {
        issueDir = orphans[0];
        viaUnnamed = true;
      } else if (orphans.length > 1 && verdict === "no-active-issue") {
        verdict = "unnamed-run-ambiguous";
        detail =
          `${orphans.length} dirs under ${dir} hold a run record but match neither <number> nor ` +
          `exp-<slug> (${orphans.map((o) => path.basename(o)).join(", ")}); which run this stop ` +
          `belongs to is not derivable, so nothing was validated`;
      }
    }

    if (issueDir) {
      if (verdict === "no-active-issue" || verdict === "unnamed-run-ambiguous") {
        verdict = viaUnnamed ? "unnamed-run" : "checked";
        issue = path.basename(issueDir);
        detail = viaUnnamed
          ? `.pipeline/${issue} holds a run record but matches neither <number> nor exp-<slug>; ` +
            `its artifacts were validated here, but every OTHER consumer of the issue-dir name ` +
            `still skips it -- rename it or record why it could not be named (#115)`
          : "";
      }
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
            groundFalsifiability(data, failures);
          } catch {
            // same contract as groundImplReport: never wedge a stop
          }
        }
      }
      if (!sawRecent && !detail) {
        detail = `no artifact owned by "${agent}" was written under .pipeline/${issue} in the last ${RECENT_MS / 60000} minutes`;
      }
    }
    // The most-specific root that holds this agent's recent artifacts is the session's own; do
    // not scan further roots, where another session's recent artifacts would produce
    // cross-worktree false blocks.
    if (sawRecent) break;
  }
  return { failures, verdict, detail, agent, issue, roots: roots.length };
}

/**
 * ONE LINE ON STDERR SAYING WHAT THE GATE DID. #66 properties 2 and 3.
 *
 * WHY STDERR. stdout is the hook's decision channel and must stay parseable JSON; stderr is not,
 * so nothing written here can wedge a stop or corrupt a decision. This is the same shape
 * hooks/pre-tool-use.sh already ships for the same reason ("every tooling gap and every abstention
 * ... writes one attribution line to stderr saying which gap it was, so a non-action is
 * diagnosable afterwards without re-running the session").
 *
 * WHY IT ALSO SPEAKS ON SUCCESS, which looks like noise and is the point. A line that appears only
 * when something is wrong cannot answer "is this gate alive?" -- and that question went unanswered
 * from this validator's first release commit until a 353,907-line cross-machine transcript census
 * asked it. A judge that has never spoken is indistinguishable from a judge that has never had
 * anything to say, unless it says the second one out loud.
 *
 * THE ONE SILENCE THAT SURVIVES, and it is load-bearing rather than an oversight: a root set with
 * NO .pipeline directory says nothing at all. That is the genuinely ad-hoc, non-pipeline session --
 * a general-purpose subagent in a project that has never run the pipeline -- and it must not be
 * taxed a line per stop for a fail-open that is simply correct. pre-tool-use.sh draws the same
 * boundary in the same words ("nothing is written on the non-acting fast path"). Everything above
 * that floor is scoped to projects that DO run the pipeline, which is where a silent gate is a
 * defect rather than a courtesy.
 */
export function announceLine(result) {
  if (!result || !result.roots) return null; // non-pipeline session: the silent fast path
  const bits = [`agent=${result.agent || "-"}`, `verdict=${result.verdict}`];
  if (result.issue) bits.push(`issue=${result.issue}`);
  bits.push(`violations=${result.failures.length}`);
  return `agent-pipeline SubagentStop: ${bits.join(" ")}${result.detail ? `; ${result.detail}` : ""}`;
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
  // ---- falsifiability coverage. The gate pipeline.md always claimed existed. ----
  // The fixture is the shape every archived spec uses: criteria carrying a leading AC<n>
  // label, rows naming the bare label.
  const fpSpec = (acs, fp, tier = "architectural") => ({
    risk_tier: tier,
    acceptance_criteria: acs,
    ...(fp === undefined ? {} : { falsifiability_pass: fp }),
  });
  const twoACs = ["AC1. the first criterion.", "AC2. the second criterion."];
  const bothCovered = {
    one_mutation_per_criterion: [{ criterion: "AC1", mutation: "break it" }],
    unmutable: [{ criterion: "AC2", why: "no mechanical failure state", discharged_by: "a human read" }],
  };
  check("falsifiability: every criterion carries a row (pass)",
    groundFalsifiability(fpSpec(twoACs, bothCovered), []), false);
  // THE CASE THE ARCHIVE CANNOT SHOW, because every archived spec is a FINAL state: a spec
  // revision adds a criterion and nobody adds a row for it.
  check("falsifiability: a revision-added criterion with no row (fail)",
    groundFalsifiability(fpSpec([...twoACs, "AC3. added by a later revision."], bothCovered), []), true);
  check("falsifiability: the block absent at the architectural tier (fail)",
    groundFalsifiability(fpSpec(twoACs, undefined), []), true);
  // FAIL OPEN below architectural, where pipeline.md does not require the block.
  check("falsifiability: the block absent at the standard tier (pass, fails open)",
    groundFalsifiability(fpSpec(twoACs, undefined, "standard"), []), false);
  // NOT failures, and each is a real shape from the archive: #56/#61/#63 record rows naming a
  // residual or a premise rather than an AC, and #19's AC4 sits in BOTH lists on purpose
  // because one half of it has a mutation and the other half is a reading judgement.
  check("falsifiability: an extra row naming a residual is not a failure (pass)",
    groundFalsifiability(fpSpec(twoACs, {
      ...bothCovered,
      unmutable: [...bothCovered.unmutable, { criterion: "R7 residual limit (i)", why: "recorded on purpose", discharged_by: "a human read" }],
    }), []), false);
  check("falsifiability: a criterion in BOTH lists is not a failure (pass)",
    groundFalsifiability(fpSpec(twoACs, {
      one_mutation_per_criterion: [{ criterion: "AC1", mutation: "break it" }, { criterion: "AC2", mutation: "break its first half" }],
      unmutable: [{ criterion: "AC2", why: "its second half is a reading judgement", discharged_by: "a human read" }],
    }), []), false);
  // ABSTAIN, LOUDLY. With nothing to match on it must SAY it enforced nothing rather than
  // report every criterion as uncovered -- or, worse, report clean.
  check("falsifiability: unlabeled criteria abstain rather than pass silently (fail)",
    groundFalsifiability(fpSpec(["no label", "nor here"], bothCovered), []), true);
  check("falsifiability: one unlabeled criterion among labeled ones is named (fail)",
    groundFalsifiability(fpSpec([...twoACs, "a third, unlabeled"], bothCovered), []), true);
  // CONTROL ON THE MATCHER ITSELF: a row that spells the criterion out in full normalizes to
  // the same label as a bare "AC1", so the gate is not merely string-equality in disguise.
  check("falsifiability: CONTROL a row spelling out the full criterion text still matches (pass)",
    groundFalsifiability(fpSpec(twoACs, {
      one_mutation_per_criterion: [{ criterion: "AC1. the first criterion.", mutation: "break it" }],
      unmutable: [{ criterion: "AC2. the second criterion.", why: "w", discharged_by: "d" }],
    }), []), false);

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

      // NAMESPACED agent_type resolution (#98, #66). Every installed-plugin dispatch (the
      // shipping default) carries agent_type "pipeline:<role>", not the bare role name
      // AGENT_RULES is keyed on. Reuse the active-issue defect fixture above.
      writeFileSync(path.join(active, "peer-review.secops.json"), JSON.stringify(brokenPanel));
      const rBare = checkArtifacts("secops", { cwd: root, active_issue: "1965" }, Date.now(), pin);
      check("namespacing: bare 'secops' catches the active-issue defect (control)", rBare.failures, true);
      const rNamespaced = checkArtifacts("pipeline:secops", { cwd: root, active_issue: "1965" }, Date.now(), pin);
      check("namespacing: 'pipeline:secops' catches the SAME defect the bare name catches", rNamespaced.failures, true);
      const rMixedCase = checkArtifacts("Pipeline:SecOps", { cwd: root, active_issue: "1965" }, Date.now(), pin);
      check("namespacing: mixed-case 'Pipeline:SecOps' still resolves", rMixedCase.failures, true);
      writeFileSync(path.join(active, "peer-review.secops.json"), JSON.stringify(validPanel));
      const rNamespacedValid = checkArtifacts("pipeline:secops", { cwd: root, active_issue: "1965" }, Date.now(), pin);
      check("namespacing: 'pipeline:secops' does not false-positive on a VALID artifact", rNamespacedValid.failures, false);
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
      writeFileSync(path.join(schemasDir, "status.json"), JSON.stringify({ x: 1 }));
      writeFileSync(path.join(archived, "status.json"), JSON.stringify({ x: 1 }));

      // EVERY mtime this block's expectations depend on is stamped explicitly, with seconds of
      // margin, because two files written microseconds apart do NOT reliably differ in mtime:
      // Linux stamps from a coarse clock that ticks every few milliseconds, so both writes can
      // land on the IDENTICAL timestamp, while APFS resolves them apart. activeIssueDir breaks a
      // tie by readdir order, so leaving the ordering to the host meant the exp- rejection cases
      // below resolved by whatever readdir returned first -- green on macOS, red as a group on
      // ubuntu-latest, at a fixed commit. That is issue #27. Ordering is a property of this
      // fixture now, not of the machine it runs on.
      const now = Date.now();
      const stamp = (file, ms) => utimesSync(file, ms / 1000, ms / 1000);
      // The NON-issue dirs are the NEWEST, so absent the numeric guard the mtime scan would
      // wrongly select them over the real issue dir.
      stamp(path.join(schemasDir, "status.json"), now + 5000);
      stamp(path.join(archived, "status.json"), now + 5000);
      // The numeric issue dir is deliberately the OLDEST dir the guard admits, so that once
      // exp-two-owner-gates exists below, the fallback target is unambiguous.
      stamp(path.join(issue, "status.json"), now - 10_000);

      delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      delete process.env.PIPELINE_ACTIVE_ISSUE;

      check("active-issue: mtime scan ignores non-issue dirs and picks the numeric issue",
        activeIssueDir(pipe, {}) === issue ? [] : ["expected numeric issue dir by mtime"], false);
      check("active-issue: marker 'schemas' rejected (not an issue-dir name), falls back to mtime",
        activeIssueDir(pipe, { active_issue: "schemas" }) === issue ? [] : ["expected mtime fallback for non-issue marker"], false);
      check("active-issue: marker '_archived' rejected (not an issue-dir name), falls back to mtime",
        activeIssueDir(pipe, { active_issue: "_archived" }) === issue ? [] : ["expected mtime fallback for _archived marker"], false);
      check("active-issue: numeric marker still resolves its issue dir",
        activeIssueDir(pipe, { active_issue: "1965" }) === issue ? [] : ["expected numeric marker to resolve"], false);

      // exp-<slug>: an experiment run's placeholder dir. Until this was added to ISSUE_DIR_RE
      // an experiment run had NO artifact validation whatsoever, on exactly the runs nobody is
      // watching. The rejection cases above are the control: widening the pattern must not
      // start admitting "schemas" or "_archived".
      const expDir = path.join(pipe, "exp-two-owner-gates");
      mkdirSync(expDir, { recursive: true });
      writeFileSync(path.join(expDir, "status.json"), JSON.stringify({ current_phase: "1-ba" }));
      stamp(path.join(expDir, "status.json"), now);
      check("active-issue: an exp-<slug> marker resolves its dir",
        activeIssueDir(pipe, { active_issue: "exp-two-owner-gates" }) === expDir ? [] : ["expected exp- marker to resolve"], false);

      // A malformed marker must be rejected on BOTH paths, so plant a real directory for each
      // one that can be a literal name (and, for the traversal case, at the path the marker
      // would reach if honored: "exp-a/../b" joins to "<pipe>/b"). Each is stamped NEWEST of
      // all, so a regex widened to admit any of these shapes fails loudly twice over -- the
      // marker path would resolve to it, and the mtime scan would start selecting it. Without
      // these, a rejected marker and an honored-but-absent one are indistinguishable: both
      // fall through to the same mtime result, so the cases could not fail on what they name.
      for (const planted of ["exp-", "exp-Two-Owner", "exp--bad", "b"]) {
        const dir = path.join(pipe, planted);
        mkdirSync(dir, { recursive: true });
        writeFileSync(path.join(dir, "status.json"), JSON.stringify({ x: 1 }));
        stamp(path.join(dir, "status.json"), now + 8000);
      }

      // The fixture's mtime ordering, asserted ONCE and on its own. Every rejection case below
      // needs the fallback to land somewhere predictable, but not one of them is a claim about
      // WHICH dir that is -- so that claim lives here, where breaking it reddens a single case
      // saying exactly that. Previously it was welded into all four: the message read
      // "expected exp- to be rejected ... got <dir>/1965" when 1965 WAS the mtime fallback and
      // the marker HAD been rejected correctly, so a tiebreak flake read as a rejection bug.
      check("active-issue: with no marker, the newest admitted dir wins the mtime scan",
        activeIssueDir(pipe, {}) === expDir
          ? []
          : [`expected the mtime fallback to pick ${expDir}, got ${activeIssueDir(pipe, {})}`], false);

      // Stated against the no-marker result rather than against expDir by name, so this claim
      // holds whatever the mtime scan picks. That independence is the point: this is the half
      // that was never flaky, and it can no longer be reddened by the half that was.
      const rejects = (marker) => {
        const got = activeIssueDir(pipe, { active_issue: marker });
        const bare = activeIssueDir(pipe, {});
        if (got !== bare) {
          return [`marker "${marker}" was HONORED: it steered resolution to ${got}, but with no marker at all resolution is ${bare}`];
        }
        if (path.basename(String(got)) === marker) {
          return [`marker "${marker}" resolved to a directory of its own name: ${got}`];
        }
        return [];
      };
      check("active-issue: a bare 'exp-' with no slug is rejected", rejects("exp-"), false);
      check("active-issue: an exp- marker with a separator is rejected (traversal guard)", rejects("exp-a/../b"), false);
      check("active-issue: an uppercase exp- marker is rejected (convention is kebab)", rejects("exp-Two-Owner"), false);
      check("active-issue: a double-hyphen exp- marker is rejected", rejects("exp--bad"), false);
    } finally {
      rmSync(root, { recursive: true, force: true });
      if (prevEnv.a === undefined) delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      else process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE = prevEnv.a;
      if (prevEnv.b === undefined) delete process.env.PIPELINE_ACTIVE_ISSUE;
      else process.env.PIPELINE_ACTIVE_ISSUE = prevEnv.b;
    }
  }

  // ---- #66 property 2 + #115: a fail-open path must say WHICH fail-open path it took ----
  //
  // The defect these pin is that `failures: []` meant three unrelated things and said none of
  // them. Every case here asserts the VERDICT, not the emptiness, because emptiness is exactly
  // what could not tell them apart. Hermetic via rootsOverride, like the scoping block above.
  {
    const root = mkdtempSync(path.join(tmpdir(), "vpa-verdict-"));
    const prevEnv = { a: process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE, b: process.env.PIPELINE_ACTIVE_ISSUE };
    try {
      delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      delete process.env.PIPELINE_ACTIVE_ISSUE;
      const pipe = path.join(root, ".pipeline");
      const named = path.join(pipe, "1965");
      mkdirSync(named, { recursive: true });
      const pin = [root];
      const runRecord = JSON.stringify({
        current_phase: "2-review", started_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z", branch: "b", events: [],
      });
      const validPanel = { verdict: "APPROVE", reviewed_at: "2026-01-01T00:00:00Z", concerns: [], notes: "n" };
      const brokenPanel = { verdict: "NOT_A_VERDICT" };
      const verdictOf = (r, want) => (r.verdict === want ? [] : [`verdict was "${r.verdict}", wanted "${want}"`]);

      writeFileSync(path.join(named, "status.json"), runRecord);
      writeFileSync(path.join(named, "peer-review.secops.json"), JSON.stringify(validPanel));

      // THE PAIR. Both return zero failures; before this change both returned nothing else.
      const rClean = checkArtifacts("pipeline:secops", { cwd: root }, Date.now(), pin);
      const rNoRules = checkArtifacts("pipeline:art-director", { cwd: root }, Date.now(), pin);
      check("verdict: a clean artifact reports 'checked'", verdictOf(rClean, "checked"), false);
      check("verdict: an unregistered agent reports 'no-rules', NOT 'checked'", verdictOf(rNoRules, "no-rules"), false);
      check("verdict: the two zero-failure cases are distinguishable (#66 property 2)",
        rClean.verdict !== rNoRules.verdict ? [] : ["a lookup miss is still indistinguishable from a clean artifact"], false);
      // The grading half: a shipped artifact-less agent is not the same event as an unknown name.
      check("verdict: a shipped artifact-less agent says so in its detail",
        /owns no schema-validated artifact/.test(rNoRules.detail) ? [] : [rNoRules.detail], false);
      check("verdict: an unregistered NON-agent says so instead",
        /is not a shipped pipeline agent/.test(
          checkArtifacts("pipeline:wizard", { cwd: root }, Date.now(), pin).detail) ? [] : ["ungraded miss"], false);
      // Failures must still ride along; the verdict is additive, not a replacement.
      writeFileSync(path.join(named, "peer-review.secops.json"), JSON.stringify(brokenPanel));
      const rDirty = checkArtifacts("pipeline:secops", { cwd: root }, Date.now(), pin);
      check("verdict: 'checked' still carries the failures it found (control)", rDirty.failures, true);
      check("verdict: a defect is reported as 'checked', not as a fail-open", verdictOf(rDirty, "checked"), false);
      // No .pipeline at all: the ad-hoc session. Its verdict is nameable but announceLine() stays
      // quiet on it, which is what keeps a non-pipeline session from paying a line per stop.
      const bare = mkdtempSync(path.join(tmpdir(), "vpa-adhoc-"));
      try {
        const rAdhoc = checkArtifacts("pipeline:secops", { cwd: bare }, Date.now(), [bare]);
        check("verdict: no .pipeline anywhere reports 'no-pipeline-root'", verdictOf(rAdhoc, "no-pipeline-root"), false);
        check("announce: the ad-hoc session gets NO line at all (the silence that must survive)",
          announceLine(rAdhoc) === null ? [] : [`announced: ${announceLine(rAdhoc)}`], false);
        check("announce: an unregistered agent in an ad-hoc session gets NO line either",
          announceLine(checkArtifacts("pipeline:wizard", { cwd: bare }, Date.now(), [bare])) === null
            ? [] : ["announced on the non-pipeline fast path"], false);
      } finally {
        rmSync(bare, { recursive: true, force: true });
      }
      check("announce: a pipeline project DOES get a line on a clean pass (liveness, #66 property 3)",
        (announceLine(rClean) || "").includes("verdict=checked") ? [] : ["no liveness line on a clean pass"], false);

      // ---- #115: the run dir ISSUE_DIR_RE cannot name ----
      const orphan = path.join(pipe, "tracker-unreachable-20260902");
      mkdirSync(orphan, { recursive: true });
      writeFileSync(path.join(orphan, "status.json"), runRecord);
      writeFileSync(path.join(orphan, "peer-review.secops.json"), JSON.stringify(brokenPanel));

      // A NAMED dir still wins. This is the case that proves the recovery is a last resort and
      // cannot redirect a stop away from a run that resolved the ordinary way.
      const rBothPresent = checkArtifacts("pipeline:secops", { cwd: root }, Date.now(), pin);
      check("unnamed-run: a named issue dir still wins over an unnamed one",
        rBothPresent.issue === "1965" ? [] : [`resolved to ${rBothPresent.issue}`], false);

      // Remove the named dir's record: now the orphan is the only run in the root.
      rmSync(path.join(named, "status.json"), { force: true });
      const rOrphan = checkArtifacts("pipeline:secops", { cwd: root }, Date.now(), pin);
      check("unnamed-run: an unnamable run dir is now VALIDATED, not skipped (#115)", rOrphan.failures, true);
      check("unnamed-run: and it is reported as 'unnamed-run', not as an ordinary check",
        verdictOf(rOrphan, "unnamed-run"), false);
      check("unnamed-run: the announcement NAMES the offending directory",
        (announceLine(rOrphan) || "").includes("tracker-unreachable-20260902") ? [] : ["dir not named"], false);
      // NON-ZERO CONTROL in the other direction: the same dir with a VALID artifact must not block.
      writeFileSync(path.join(orphan, "peer-review.secops.json"), JSON.stringify(validPanel));
      check("unnamed-run: a VALID artifact in an unnamed dir does NOT block (control)",
        checkArtifacts("pipeline:secops", { cwd: root }, Date.now(), pin).failures, false);
      writeFileSync(path.join(orphan, "peer-review.secops.json"), JSON.stringify(brokenPanel));

      // A NON-RUN sibling must not be adopted. `_archived` and `schemas` are the two names this
      // repo actually puts beside real runs; neither carries a phase-shaped current_phase.
      for (const junk of ["_archived", "schemas"]) {
        const j = path.join(pipe, junk);
        mkdirSync(j, { recursive: true });
        writeFileSync(path.join(j, "status.json"), JSON.stringify({ x: 1 }));
      }
      check("unnamed-run: a status.json with no phase is NOT a run candidate",
        unnamedRunDirs(pipe).length === 1 ? [] : [`candidates: ${unnamedRunDirs(pipe).map((d) => path.basename(d)).join(",")}`], false);
      check("unnamed-run: a defect in the real orphan still blocks with the junk siblings present",
        checkArtifacts("pipeline:secops", { cwd: root }, Date.now(), pin).failures, true);
      // A phase-shaped record in a junk dir WOULD be adopted -- assert the discriminator is the
      // phase and not the name, so a reader knows exactly which clause is doing the work.
      writeFileSync(path.join(pipe, "schemas", "status.json"), runRecord);
      check("unnamed-run: TWO unnamable runs abstain rather than guess",
        verdictOf(checkArtifacts("pipeline:secops", { cwd: root }, Date.now(), pin), "unnamed-run-ambiguous"), false);
      check("unnamed-run: the ambiguous abstention blocks nothing",
        checkArtifacts("pipeline:secops", { cwd: root }, Date.now(), pin).failures, false);
      check("unnamed-run: the ambiguous abstention NAMES both candidates",
        ["schemas", "tracker-unreachable-20260902"].every((n) =>
          (announceLine(checkArtifacts("pipeline:secops", { cwd: root }, Date.now(), pin)) || "").includes(n))
          ? [] : ["candidates not named"], false);
    } finally {
      rmSync(root, { recursive: true, force: true });
      if (prevEnv.a === undefined) delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      else process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE = prevEnv.a;
      if (prevEnv.b === undefined) delete process.env.PIPELINE_ACTIVE_ISSUE;
      else process.env.PIPELINE_ACTIVE_ISSUE = prevEnv.b;
    }
  }

  // ---- active-issue scoping: an mtime TIE is not a signal ----
  // The tie rule is a deliberate semantic, so it is pinned here rather than left to emerge from
  // enumeration order. Every mtime below is stamped explicitly: a fixture that wrote these files
  // and hoped they landed on different timestamps would be testing the host's clock granularity,
  // which is the bug this rule exists to answer (#27).
  {
    const root = mkdtempSync(path.join(tmpdir(), "vpa-tie-"));
    const prevEnv = { a: process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE, b: process.env.PIPELINE_ACTIVE_ISSUE };
    try {
      delete process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE;
      delete process.env.PIPELINE_ACTIVE_ISSUE;
      const now = Date.now();
      const stamp = (file, ms) => utimesSync(file, ms / 1000, ms / 1000);
      // Build a root of issue dirs and stamp each status.json to an exact millisecond.
      const build = (name, spec) => {
        const pipe = path.join(root, name, ".pipeline");
        const dirs = {};
        for (const [issue, offsetMs] of Object.entries(spec)) {
          const dir = path.join(pipe, issue);
          mkdirSync(dir, { recursive: true });
          writeFileSync(path.join(dir, "status.json"), JSON.stringify({ issue_number: Number(issue) }));
          stamp(path.join(dir, "status.json"), now + offsetMs);
          dirs[issue] = dir;
        }
        return { pipe, dirs };
      };

      // The production shape: a fresh clone writes every tracked status.json in one go, so on a
      // host whose timestamps are coarser than the write burst they all land on one mtime.
      const tie = build("tie", { 1965: 0, 1964: 0 });
      check("active-issue: two dirs tied at the newest mtime resolve to null (a tie is not a signal)",
        activeIssueDir(tie.pipe, {}) === null
          ? []
          : [`expected null for a tie, got ${activeIssueDir(tie.pipe, {})}`], false);

      // CONTROL for the case above: the same fixture, one dir bumped a single millisecond clear,
      // must resolve. Without this, a resolver that returned null unconditionally would pass.
      const strict = build("strict", { 1965: 1, 1964: 0 });
      check("active-issue: CONTROL a one-millisecond strict winner still resolves",
        activeIssueDir(strict.pipe, {}) === strict.dirs[1965]
          ? []
          : [`expected ${strict.dirs[1965]}, got ${activeIssueDir(strict.pipe, {})}`], false);

      // Only a tie AT THE TOP is ambiguous. Two stale dirs sharing an mtime say nothing about
      // the one dir that is strictly newer than both.
      const below = build("below", { 1965: 5000, 1964: 0, 1963: 0 });
      check("active-issue: a tie BELOW the newest does not suppress a strict winner",
        activeIssueDir(below.pipe, {}) === below.dirs[1965]
          ? []
          : [`expected ${below.dirs[1965]}, got ${activeIssueDir(below.pipe, {})}`], false);

      const three = build("three", { 1965: 0, 1964: 0, 1963: 0 });
      check("active-issue: a three-way tie at the newest resolves to null",
        activeIssueDir(three.pipe, {}) === null
          ? []
          : [`expected null for a three-way tie, got ${activeIssueDir(three.pipe, {})}`], false);

      // Precedence (a) is untouched by the tie rule: an explicit signal is evidence the scan
      // does not have, so it resolves through an ambiguity that would otherwise abstain. This is
      // what keeps the rule from weakening a run that names its issue.
      check("active-issue: an explicit marker still resolves through an ambiguous mtime scan",
        activeIssueDir(tie.pipe, { active_issue: "1965" }) === tie.dirs[1965]
          ? []
          : [`expected the marker to win, got ${activeIssueDir(tie.pipe, { active_issue: "1965" })}`], false);

      // ...but a marker naming a dir that is not here is not evidence either: it falls through
      // to the scan, which is still tied, so the answer is still null.
      check("active-issue: a marker for an absent dir does NOT rescue a tie",
        activeIssueDir(tie.pipe, { active_issue: "9999" }) === null
          ? []
          : [`expected null, got ${activeIssueDir(tie.pipe, { active_issue: "9999" })}`], false);
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

  const result = checkArtifacts(input.agent_type, input);
  const line = announceLine(result);
  if (line) process.stderr.write(`${line}\n`);

  const { failures } = result;
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
