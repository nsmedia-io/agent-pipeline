#!/usr/bin/env node
/**
 * Stage 2 of the PreToolUse tracked-write gate: WHOSE RUN does this call belong to, and is that
 * run at a Phase 4 phase.
 *
 * The cheap stage (hooks/pre-tool-use.sh) has already decided the only thing that needs the
 * caller's command: whether it stages paths the caller did not name. This stage never sees that
 * command. It is handed the payload's cwd, the agent_type and the payload's active-issue marker,
 * and nothing else -- the argument vector and environment of a child process are readable by
 * other local users on an adopting host, and a hook that put a developer's commit message there
 * would be logging user-controlled text (agents/secops.md's "never log ... user-controlled text"
 * rule, applied to a sink that is not a log).
 *
 * IT LIVES IN hooks/ AND NOT scripts/ on purpose: it is this hook's own second stage, not a
 * shared utility, and scripts/ carries a checked module-graph invariant that a hook-private file
 * has no business joining. Everything it needs from the shared seams it IMPORTS -- run-candidate
 * resolution, the issue-dir vocabulary, root resolution and the agent_type namespace strip all
 * come from scripts/validate-pipeline-artifact.mjs rather than being restated here.
 *
 * Usage: node pre-tool-use-resolve.mjs <cwd> <agent_type> <active_issue>
 * Output: the PreToolUse deny object on stdout, or nothing; one attribution line on stderr when
 * the gate does not act. Exit 0 in every case: this is a ratchet, and a hook that wedged a tool
 * call over its own tooling gap would be a worse failure than the blanket commit it exists to
 * refuse.
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  bareRole,
  pipelineDirs,
  resolveRunOwner,
} from "../scripts/validate-pipeline-artifact.mjs";

const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// WHY THE VOCABULARY IS READ RATHER THAN DECLARED. commands/pipeline.md is the file that WRITES
// current_phase, and tests/test-status-schema-contract.sh already holds it to a both-directions
// set comparison. A third private copy here is the drift this repo has already paid for once.
// The extraction is the same one that suite performs.
function phase4Literals() {
  let src;
  try {
    src = readFileSync(path.join(PLUGIN_ROOT, "commands", "pipeline.md"), "utf8");
  } catch {
    return null;
  }
  const found = new Set();
  for (const m of src.matchAll(/"?current_phase"?: *"([^"]*)"/g)) {
    if (m[1] === "<phase>-error") continue;
    if (m[1].startsWith("4-")) found.add(m[1]);
  }
  return found;
}

const NOTE = {
  "no-pipeline-root": "no .pipeline record store under any resolved root",
  "unreadable-record": "a status.json under a resolved root would not parse",
  "no-in-flight-run": "no in-flight run in the record store",
  "undatable-sole-candidate":
    "the one in-flight run carries no parseable updated_at, so its recency is unknowable and it cannot own a refusal",
  "ambiguous-owner":
    "two or more in-flight runs and no honoured active-issue marker, so which run this call belongs to is undecidable",
  "record-has-no-phase": "the owning run records no current_phase",
  "phase-not-guarded": "the owning run is not at a Phase 4 phase",
  "no-phase-vocabulary": "commands/pipeline.md could not be read, so the Phase 4 vocabulary is unknown",
};

function abstain(reason) {
  process.stderr.write(`agent-pipeline PreToolUse: ${NOTE[reason] || reason}; nothing enforced.\n`);
  process.exit(0);
}

function main() {
  const [, , cwdArg = "", agentTypeArg = "", activeIssueArg = ""] = process.argv;
  const input = {};
  if (cwdArg) input.cwd = cwdArg;
  if (activeIssueArg) input.active_issue = activeIssueArg;

  const roots = pipelineDirs(input);
  if (!roots.length) abstain("no-pipeline-root");

  const owner = resolveRunOwner(roots, input);
  if (!owner.dir) abstain(owner.reason);
  if (!owner.phase) abstain("record-has-no-phase");

  const phase4 = phase4Literals();
  if (phase4 === null) abstain("no-phase-vocabulary");
  if (!phase4.has(owner.phase)) abstain("phase-not-guarded");

  const role = bareRole(agentTypeArg) || "-";
  // The subject's PROVENANCE travels with the refusal. A deny resolved from an explicit marker
  // and one resolved by inference are the same refusal to the agent and a different diagnosis to
  // an operator reading back an over-refusal.
  process.stderr.write(
    `agent-pipeline PreToolUse: refused blanket staging (role=${role}, subject=${
      owner.provenance === "marker" ? "marker" : "inferred"
    }).\n`,
  );
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          "Phase 4 tracked-write isolation: a subagent may not stage paths it did not name while a Phase 4 run is in flight. " +
          "Read `git status --porcelain`, then stage explicit paths only (`git add <path>`) and commit those. " +
          "A blanket stage in a fix round ships a change nobody reviewed, and in a shared dispatch worktree it also sweeps up another panelist's working tree.",
      },
    }),
  );
  process.exit(0);
}

try {
  main();
} catch {
  // Fail open, and say so: an unattributable non-action is the failure mode this gate's own
  // requirements call out by name.
  process.stderr.write("agent-pipeline PreToolUse: the resolver threw; nothing enforced.\n");
  process.exit(0);
}
