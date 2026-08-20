#!/usr/bin/env node
/**
 * The phase-entry guard: decides whether the run recorded in `.pipeline/<issue>/status.json`
 * is allowed to be where it says it is.
 *
 *   node gate-phase-entry.mjs [--root <project-root>]
 *
 * Prints ONE line of JSON on a decision -- {"decision","reason","issue_dir"} -- and exits 2 on
 * `refused`, 0 on `granted` and `not-applicable`. A tooling failure prints NOTHING and exits 0.
 *
 * WHAT IT IS. A turn-boundary consistency gate, wired into hooks/stop.sh. It prevents a turn
 * from ENDING in a state whose prerequisites are absent, and forces the orchestrator to either
 * do the missed work or say in writing that it skipped it.
 *
 * WHAT IT IS NOT (verbatim from the spec's guarantee_and_threat_model, because a stated limit
 * that gets paraphrased is how a limit becomes a guarantee):
 * A pre-dispatch airlock. It CANNOT prevent a phase being skipped mid-turn; the phase's absence is detected when the turn tries to end. The cost of a skip is therefore the wasted work in that turn, not zero. Work already done in this turn is not undone.
 *
 * WHOSE RUN IT JUDGES, AND THE LIMITATION IT INHERITS. The active issue is resolved through
 * validate-pipeline-artifact.mjs's activeIssueDir seam. That seam's top-priority `active_issue`
 * marker is populated from a SubagentStop payload, NOT the Stop payload, so from this hook the
 * active issue will almost always resolve through the mtime fallback: the newest status.json
 * among the issue dirs. Two consequences are load-bearing and neither is hypothetical:
 *   - The Stop hook is PROJECT-scoped, not run-scoped, so without a recency ceiling an
 *     abandoned run parked at a guarded phase would refuse every turn in that project forever.
 *     Hence the in-flight predicate below (R6), reusing pipeline-status.mjs's own 24h /
 *     no-final-verdict definition rather than inventing a second one.
 *   - An explicit signal (CLAUDE_PIPELINE_ACTIVE_ISSUE / PIPELINE_ACTIVE_ISSUE) must not be
 *     able to NARROW the subject: pointing it at a satisfied dir would be the env-var opt-out
 *     the design rejected, and it would leave no trace in the archived record. So both the
 *     signal-named dir and the mtime-derived dir are evaluated, and EITHER may refuse (R6b).
 *
 * FAIL-DIRECTION SPLIT (R11), which is a contract change to a hook that declares itself
 * fail-open, so it is stated in both places. The DECISION is fail-CLOSED: a recognised phase
 * whose prerequisite is absent refuses. The TOOLING is fail-OPEN: node absent, this file
 * absent, status.json absent or unparseable, no resolvable active issue, or any thrown error
 * exits 0 in silence. The events are in different environments, which is the whole reason the
 * split is legitimate: a skipped phase happens inside the agent session and is discretion; a
 * missing Node install happens in the operator's environment and is not. Because that
 * fail-open is permanently invisible, hooks/session-start.sh reports it once per session.
 *
 * VOCABULARY. This module declares NO phase list and NO phase-shape regex of its own. Event
 * labels resolve through the shared phaseKey/KNOWN_PHASES resolver, and every token in every
 * satisfying set below is asserted by the drift suite to be a member of the imported
 * KNOWN_PHASES. Prefix / startsWith comparison is forbidden by name: `"2.5"` shares a leading
 * character with `"2"`, so a prefix rule lets a recorded 2.5-design skip clear the Phase 2
 * review gate it never ran.
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

import { isMain } from "./lib.mjs";
import { KNOWN_TIERS } from "./dispatch-model.mjs";
import { phaseKey } from "./pipeline-telemetry.mjs";
import { activeIssueDir } from "./validate-pipeline-artifact.mjs";

/**
 * The 15 guarded rows: the 8 phases pipeline.md checkpoints into ("Checkpoint first:") and the
 * 7 `<phase>-complete` literals it parks at. Each row carries its own prerequisite file and its
 * own SATISFYING TOKEN SET -- the tokens that, seen in events[], stand in for that file.
 *
 * TWO EXCLUSIONS ARE LOAD-BEARING, and each closes a hole traced on real records.
 *   - `2.5-design` satisfies on {2}, NOT {2, 2.5}. Its own token must not appear, or the
 *     recorded 2.5-design SKIPPED entry in .pipeline/17 would self-grant the phase it skipped.
 *   - `4-review` and `3-impl-complete` satisfy on {3, 3b} and EXCLUDE 3a. An events[] carrying
 *     only 3a-qa-tests means QA authored the contract and Dev was never dispatched; granting
 *     there would declare a run panel-ready when the implementation step never ran.
 *
 * `content` marks a row whose prerequisite is not satisfied by mere presence. Such a row is
 * strictly weaker through events[] than through the file, because an event attests DISPATCH,
 * never APPROVAL, and that asymmetry is stated rather than defended against.
 */
const PREREQUISITES = {
  "0.5-map": { file: null, tokens: [] },
  "1-ba": { file: "map.json", tokens: ["0.5"], tiers: ["architectural"] },
  "2-constraints": { file: "spec.json", tokens: ["1"], content: "ba-approved" },
  "2-review": { file: "spec.json", tokens: ["1"], content: "ba-approved" },
  "2.5-design": { file: "review.json", tokens: ["2"] },
  "3-impl": {
    byTier: {
      trivial: { file: "spec.json", tokens: ["1"] },
      standard: { file: "constraints.md", tokens: ["2"], content: "non-empty" },
      architectural: { file: "design.json", tokens: ["2.5"] },
    },
  },
  "4-review": { file: "impl-report.json", tokens: ["3", "3b"] },
  "5-archive": { file: "peer-review.json", tokens: ["4"] },
  "0.5-map-complete": { file: "map.json", tokens: ["0.5"] },
  "1-ba-complete": { file: "spec.json", tokens: ["1"] },
  "2-constraints-complete": { file: "constraints.md", tokens: ["2"] },
  "2-review-complete": { file: "review.json", tokens: ["2"] },
  "2.5-design-complete": { file: "design.json", tokens: ["2.5"] },
  "3-impl-complete": { file: "impl-report.json", tokens: ["3", "3b"] },
  "4-review-complete": { file: "peer-review.json", tokens: ["4"] },
};

const GUARDED = Object.keys(PREREQUISITES);

/** The entry/exit split is DERIVED from the one table, so the two cannot drift apart. */
export const ENTRY = GUARDED.filter((p) => !p.endsWith("-complete"));
export const EXIT = GUARDED.filter((p) => p.endsWith("-complete"));

/**
 * Phases that are explicitly NOT guarded: a run parked in a halt, a tripwire, an open-questions
 * pause or a rework state has already stopped, and refusing its turn would trap the owner in
 * the state the halt exists to surface.
 */
export const UNGUARDED = [
  "1-ba-open-questions",
  "1-ba-rework-required",
  "2.5-design-owner-decision",
  "3-impl-frontend-gate-failed",
  "3-impl-gate-failed",
  "3-impl-live-verify-unverified",
  "3-impl-tripwire",
  "3-impl-tripwire-indeterminate",
  "4-veto-rework-required",
];

/**
 * The terminal literal pipeline.md writes. The runtime terminal check below is wider than this
 * set on purpose (it also covers `halted-error`, any `<phase>-error` instantiation, and any
 * record carrying `completed_at`), but only the pipeline.md literal belongs in the set the
 * drift suite partitions.
 */
export const TERMINAL = ["5-archived"];

const IN_FLIGHT_MS = 24 * 60 * 60 * 1000;

/** An unusable risk_tier resolves to the STRICTEST row, never the loosest. */
function normalizeTier(tier) {
  return KNOWN_TIERS.includes(tier) ? tier : "architectural";
}

function rowFor(phase, tier) {
  const raw = PREREQUISITES[phase];
  if (!raw) return null;
  if (raw.byTier) return raw.byTier[tier] || raw.byTier.architectural;
  return raw;
}

/** A row that only exists at some tiers (the deep map is architectural-only). */
function appliesAtTier(phase, tier) {
  const raw = PREREQUISITES[phase];
  return !raw || !raw.tiers || raw.tiers.includes(tier);
}

/**
 * The row's satisfying token set. Empty for a phase with no prerequisite and for any phase that
 * is not a guarded row, so a caller cannot read "no tokens" as "any token will do".
 */
export function satisfyingTokens(phase, tier) {
  const row = rowFor(phase, normalizeTier(tier));
  return row && Array.isArray(row.tokens) ? [...row.tokens] : [];
}

function contentSatisfies(artifactPath, row) {
  if (row.content === "ba-approved") {
    try {
      const doc = JSON.parse(readFileSync(artifactPath, "utf8"));
      return typeof doc.ba_approved_at === "string" && doc.ba_approved_at.trim() !== "";
    } catch {
      return false;
    }
  }
  if (row.content === "non-empty") {
    try {
      return readFileSync(artifactPath, "utf8").trim() !== "";
    } catch {
      return false;
    }
  }
  return true;
}

/**
 * Path (b): an events[] entry whose RESOLVED token is a member of the row's set.
 *
 * No verdict is required. events[].verdict is optional in the schema and a committed record
 * carries six verdict-less events, so a verdict-keyed rule would reject a schema-valid record;
 * and the artifact an event stands in for exists whatever the verdict said, because a review
 * that demanded changes still ran. The ONE exception is a recorded SKIP, which is the deviation
 * hatch and costs a written reason -- without the note the hatch is free, and a free hatch is
 * not a hatch. A noteless skip only disqualifies THAT entry; another entry may still satisfy.
 */
function eventsSatisfy(events, tokens) {
  if (!Array.isArray(events) || tokens.length === 0) return false;
  for (const event of events) {
    if (!event || typeof event !== "object") continue;
    const token = phaseKey(event.phase);
    if (token === null || !tokens.includes(token)) continue;
    if (event.verdict === "SKIPPED") {
      const note = typeof event.note === "string" ? event.note.trim() : "";
      if (note === "") continue;
    }
    return true;
  }
  return false;
}

/**
 * Two sources, in priority order: the artifact, then the record.
 *
 * A PRESENT artifact decides the row by itself, including when its CONTENT fails the row's
 * condition -- events[] are not consulted to rescue it. Otherwise the `content` column would be
 * dead on any real run: a dispatch event for the phase is always present by the time its
 * artifact is, so an unapproved spec.json would be waved through by the event that recorded the
 * BA dispatch. The events path exists for the fresh checkout, where the artifact is absent
 * because everything except status.json is gitignored, and there it is knowingly weaker.
 *
 * Returns WHICH SOURCE decided as well as the outcome, because the two refusals need different
 * messages: telling an operator that a file they are looking at is not present, and telling them
 * to re-run the phase that already produced it, are both false on a content failure.
 */
function prerequisiteSatisfied(issueDir, row, events) {
  if (!row.file) return { ok: true, artifact: "none" };
  const artifactPath = path.join(issueDir, row.file);
  if (existsSync(artifactPath)) {
    return { ok: contentSatisfies(artifactPath, row), artifact: "present" };
  }
  return { ok: eventsSatisfy(events, row.tokens), artifact: "absent" };
}

/**
 * A run is IN FLIGHT when it was updated under 24h ago and carries no final verdict -- the
 * predicate pipeline-status.mjs already uses to call a run "possibly stuck", inverted. A record
 * with no readable `updated_at` is not in flight: the guard cannot date it, and a control that
 * cannot date a record must not hold a project's turns open on it.
 */
function inFlight(status, now) {
  if (status.final_verdict) return false;
  const updated = Date.parse(status.updated_at);
  if (!Number.isFinite(updated)) return false;
  return now - updated <= IN_FLIGHT_MS;
}

function isTerminal(phase, status) {
  if (status.completed_at) return true;
  if (TERMINAL.includes(phase)) return true;
  if (phase === "halted-error") return true;
  return /-error$/.test(phase);
}

/**
 * The decision for ONE issue dir. Returns null for a tooling failure (unreadable record), which
 * the caller renders as silence rather than as a decision.
 */
function decideForDir(issueDir, now) {
  const name = path.basename(issueDir);
  let status;
  try {
    status = JSON.parse(readFileSync(path.join(issueDir, "status.json"), "utf8"));
  } catch {
    return null;
  }
  if (!status || typeof status !== "object" || Array.isArray(status)) return null;

  const decided = (decision, reason) => ({ decision, reason, issue_dir: name });
  const phase = typeof status.current_phase === "string" ? status.current_phase : "";
  const at = `.pipeline/${name} at \`${phase}\``;

  if (isTerminal(phase, status)) return decided("not-applicable", `${at} is finished.`);
  if (UNGUARDED.includes(phase)) {
    return decided("not-applicable", `${at} is a halt or rework state, which is never guarded.`);
  }
  // Fail-OPEN on vocabulary, fail-CLOSED on sequence. An unrecognised phase is a gap in this
  // table's knowledge, not an orchestrator exercising discretion, and status.schema.json blesses
  // at least two phases pipeline.md never writes -- deny-by-default would refuse every turn in a
  // project holding one of those records.
  if (!GUARDED.includes(phase)) {
    return decided("not-applicable", `${at}, which is not a guarded phase.`);
  }
  if (!inFlight(status, now)) {
    return decided("not-applicable", `${at} is not in flight (stale or already concluded).`);
  }

  const tier = normalizeTier(status.risk_tier);
  if (!appliesAtTier(phase, tier)) {
    return decided("not-applicable", `${at} is not a guarded phase at the ${tier} tier.`);
  }

  const row = rowFor(phase, tier);
  const prereq = prerequisiteSatisfied(issueDir, row, status.events);
  if (prereq.ok) {
    return decided("granted", `${at}: its prerequisite is satisfied.`);
  }
  const reason =
    prereq.artifact === "present"
      ? `${at} (${tier}) has a \`${row.file}\` that does not satisfy this row, and a present artifact is not rescued by events[].`
      : `${at} (${tier}) has no \`${row.file}\` and no events[] entry recording that phase closing.`;
  return {
    ...decided("refused", reason),
    phase,
    file: row.file,
    tier,
    artifact: prereq.artifact,
    content: row.content || null,
  };
}

/**
 * The stderr message on a refusal. FIXED TEMPLATE, four bounded values, no passthrough: the
 * phase and the filename come from the table above, and the dir name matched the issue-dir
 * shape. status.json's free-text fields (ask_text, events[].note, error) are NEVER interpolated
 * -- the schema itself says ask_text "must never carry a secret" because the file is committed,
 * i.e. it treats that field as one that can receive a pasted token before anyone notices, and
 * stderr is fed straight back into the transcript.
 */
const CONTENT_DIAGNOSIS = {
  "ba-approved": "carries no `ba_approved_at`",
  "non-empty": "is empty",
};

const CONTENT_REPAIR = {
  "ba-approved": "Record BA's approval: set `ba_approved_at` in",
  "non-empty": "Write the content that phase produces into",
};

function refusalMessage(result) {
  const dir = `.pipeline/${result.issue_dir}`;
  // A refusal on a PRESENT artifact must not send the operator after a missing file. Both of the
  // absent-case lines are false there -- the file is in front of them, and re-running the phase
  // that produced it changes nothing -- and this is the text a blocked turn reads.
  const present = result.artifact === "present";
  const diagnosis = present
    ? `Its prerequisite \`${result.file}\` IS present in ${dir}, but it ${CONTENT_DIAGNOSIS[result.content] || "does not satisfy this row"}. A present artifact settles the row on its own; events[] are not consulted to rescue it, or the event that recorded the phase being DISPATCHED would stand in for its approval.`
    : `Its prerequisite \`${result.file}\` is not present in ${dir}, and no events[] entry records that phase closing.`;
  const route1 = present
    ? `  1. ${CONTENT_REPAIR[result.content] || "Supply the content this row requires in"} ${dir}/${result.file}, then commit it.`
    : `  1. Run the phase that produces \`${result.file}\`, then append its events[] entry and commit ${dir}/status.json.`;
  return [
    `Phase-entry guard: this turn cannot end with ${dir} recorded at \`${result.phase}\`.`,
    diagnosis,
    `Work already done in this turn is not undone; only the turn boundary is blocked.`,
    `Ways to clear it:`,
    route1,
    `  2. If the skip was deliberate, record it: append an events[] entry for the phase you skipped with "verdict": "SKIPPED" and a non-empty "note" saying why.`,
    // The guard only holds turns for a run it can still see in flight, so concluding an abandoned
    // one clears it and refuses nothing. Without this route the in-flight predicate's own escape
    // hatch was undocumented at the only moment anyone needs it.
    `  3. If this run is over, conclude it: give ${dir}/status.json a \`final_verdict\`, a \`completed_at\`, or \`"current_phase": "5-archived"\`. A run this guard cannot see in flight is never refused.`,
    `A /phase re-run that did the work records it the same way, as a \`<phase-token>-rerun\` event (e.g. \`1-ba-rerun\`); the bare \`phase-rerun\` label resolves to no phase and clears nothing.`,
  ].join("\n");
}

/**
 * A sentinel the issue-dir shape rejects, so activeIssueDir's signal branch fails over to its
 * mtime derivation. It is passed as the payload field rather than by unsetting the environment,
 * because the point is to ask ONE resolver two questions -- "who does the signal name" and "who
 * is newest" -- without a second scan that could answer differently.
 */
const MTIME_ONLY = "!";

function candidateDirs(pipelineDir) {
  const dirs = [];
  for (const dir of [
    activeIssueDir(pipelineDir, {}),
    activeIssueDir(pipelineDir, { active_issue: MTIME_ONLY }),
  ]) {
    if (dir && !dirs.includes(dir)) dirs.push(dir);
  }
  return dirs;
}

function parseRoot(argv) {
  const i = argv.indexOf("--root");
  if (i !== -1 && argv[i + 1]) return argv[i + 1];
  return process.env.CLAUDE_PROJECT_DIR || process.cwd();
}

function main() {
  const pipelineDir = path.join(parseRoot(process.argv.slice(2)), ".pipeline");
  if (!existsSync(pipelineDir)) return;

  const now = Date.now();
  const results = [];
  for (const dir of candidateDirs(pipelineDir)) {
    const result = decideForDir(dir, now);
    if (result) results.push(result);
  }
  if (results.length === 0) return; // no resolvable, readable active issue: silence

  // EITHER dir may refuse. That is what stops the explicit signal from being strictly more
  // permissive than leaving it unset, which is the env-var opt-out this design rejected.
  const chosen =
    results.find((r) => r.decision === "refused") ||
    results.find((r) => r.decision === "granted") ||
    results[0];

  process.stdout.write(
    `${JSON.stringify({
      decision: chosen.decision,
      reason: chosen.reason,
      issue_dir: chosen.issue_dir,
    })}\n`,
  );
  if (chosen.decision === "refused") {
    process.stderr.write(`${refusalMessage(chosen)}\n`);
    process.exitCode = 2;
  }
}

// Self-run ONLY as a real CLI entry. isMain compares the basename of argv[1], and the drift
// suite passes THIS module's path as argv[1] to an eval script that imports it -- self-running
// there would print a decision into the middle of that suite's own report and could exit(2)
// mid-import, turning a test of the exported sets into a test of the caller's .pipeline tree.
const evalEntry = process.execArgv.some(
  (a) => a === "-e" || a === "--eval" || a === "--input-type=module" || /^--eval=/.test(a),
);
if (isMain("gate-phase-entry.mjs") && !evalEntry) {
  try {
    main();
  } catch {
    // Fail-OPEN on tooling: a guard that crashes must never wedge a turn, and it must not
    // announce the crash either, because stderr here is read as a refusal.
    process.exitCode = 0;
  }
}
