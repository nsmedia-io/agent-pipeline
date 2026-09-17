**Falsifiability gate (architectural tier, before any Phase 3 dispatch).** Run `node "${CLAUDE_PLUGIN_ROOT}/scripts/validate-pipeline-artifact.mjs" --file "$ARTIFACT_DIR/spec.json" --tier architectural`. Exit 0: proceed. Exit 2: loop back to BA with the failures it printed (a criterion with no mutation or `unmutable` row, no `falsifiability_pass`, no `measured_state`, criteria without `AC<n>` labels); any other exit: halt. It checks coverage and presence, not whether a mutation would really redden a test or whether every number the spec asserts is in `measured_state`: read those yourself. A criterion that cannot fail is one Dev implements to and QA writes a test for, and neither finds out.

**Hard sequencing gate (architectural tier, do not violate):** QA's failing-test commit MUST be fully committed and its SHA recorded in `status.json` BEFORE the Dev Agent call is dispatched. Do NOT dispatch QA and Dev in the same message (this is NOT a Phase-2-style fan-out). Dispatch QA, wait for it to return, record the SHA, THEN dispatch Dev. If QA's commit is not present, halt and re-run QA; never start Dev against an unwritten or partial test tree.

- **architectural + `spec.ab_build: true` (the rare dual-build A/B)**: instead of one Dev thread, run TWO independent implementations of the SAME fixed surface, each in its own worktree off the same base, then judge them BLIND (heterogeneous reviewers, arms labeled neutrally, scored on a fixed rubric) and materialize the winner with best-of-both grafts. Hold the implementation surface identical across both arms so the comparison isolates the approach, not the file set. This is the only shape that builds twice; reserve it for genuinely contested architectures (see the A/B economics note below) and prefer it as a periodic calibration over a per-task default. The winner still runs the standard Phase 4 panel.

**A/B and review economics (when to build twice).** The default is build ONCE, the single-writer Phase 3, then spend the multi-agent budget on independent ADVERSARIAL review of that one artifact (Phase 4). Building an artifact TWICE is the `ab_build` escalation only: when BA sets `spec.ab_build: true` (architectural, and only when two or more materially different approaches are genuinely viable and a wrong one is expensive), Phase 3 runs as TWO independent implementations of the SAME fixed surface, each worktree-isolated, judged BLIND by a heterogeneous panel, then the winner is materialized with best-of-both grafts. That path costs roughly an order of magnitude more, so it is rare and deliberate; run a full dual-build A/B at most as a periodic calibration, not per task. Two free, always-on rules carry most of what a full A/B would otherwise re-discover, the grounding gate and the gate-bites proof, so each A/B you do run banks rules and retires.

### Phase 3a (architectural tier): QA authors the failing behavioral tests (dispatch FIRST, alone)

```
Agent({
  subagent_type: "qa",
  description: "QA Phase 3a author failing tests for #<issue>",
  prompt: """
Active worktree path: <WORKTREE_PATH>
Artifact directory (absolute): <ARTIFACT_DIR>

First, cd to that worktree. Every subsequent read, write, and bash call MUST use absolute paths rooted at that worktree. Do not operate from the root checkout. Read and write ALL pipeline artifacts at the absolute <ARTIFACT_DIR>; never resolve .pipeline relative to cwd.

Read <ARTIFACT_DIR>/spec.json (especially acceptance_criteria) and <ARTIFACT_DIR>/review.json. Author DETERMINISTIC FAILING behavioral tests per your agent definition: one per acceptance criterion minimum, derived from BEHAVIOR not implementation shape, worked against the edge-case checklist, no mocked backing service. Do NOT implement the feature; tests must fail now because the implementation does not exist yet.

If tasks.json is absent, write <ARTIFACT_DIR>/tasks.json first including "worktree_path": "<WORKTREE_PATH>".

Commit ONLY the test files with a test: conventional commit referencing #<issue>. Run `<your test command>` (# CUSTOMIZE: e.g. `npm test`) to confirm the new tests fail for the right reason (missing implementation, not a typo).

Return a short summary with the test commit SHA, the test files authored, and the acceptance criteria each covers.
  """
})
```

After QA returns:
- Record QA's contract: `node "${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.mjs" qa-contract --sha <sha> --tasks "<ARTIFACT_DIR>/tasks.json" --status "$PIPELINE_BASE/<issue>/status.json" --worktree <WORKTREE_PATH> --commit`. It confirms the sha names a commit, checks `tasks.json` `satisfiability_proof` with the SubagentStop validator's own `groundSatisfiability` (#158: QA's contract must be known SATISFIABLE, not only red), and only then records `phase3_qa_test_commit` with a `flags` entry. Exit 2: halt and re-dispatch QA with the printed reason (test-discipline rule 12 quoted); do NOT dispatch Dev. Origin: 129 cases handed to Dev with no satisfiability proof; three were unsatisfiable by any implementation and Dev spent its turn cap repairing them.
- If QA reports no commit, or tests that do not fail for the right reason, halt and re-run QA. Do NOT proceed to Dev.

### Phase 3b (architectural tier): Dev implements to green (dispatch SECOND, only after the SHA is recorded)

```
Agent({
  subagent_type: "dev",
  description: "Dev Phase 3b implementation for #<issue>",
  prompt: """
Active worktree path: <WORKTREE_PATH>
Artifact directory (absolute): <ARTIFACT_DIR>

First, cd to that worktree. Every subsequent read, write, and bash call MUST use absolute paths rooted at that worktree. Do not operate from the root checkout. Read and write ALL pipeline artifacts at the absolute <ARTIFACT_DIR>; never resolve .pipeline relative to cwd.

QA has already authored and committed the failing behavioral test contract at commit <QA_TEST_SHA>. Read those test files first and run `<your test command>` (# CUSTOMIZE: e.g. `npm test`) to see them fail; they are your target. Read <ARTIFACT_DIR>/spec.json and <ARTIFACT_DIR>/review.json. If <ARTIFACT_DIR>/design.json exists (architectural tier, written in Phase 2.5), implement the chosen approach it specifies, not just the spec.

Implement per your agent definition until QA's tests pass. Do NOT weaken, skip, or delete QA's tests to force a pass. You MAY add tests for internal units QA could not see, held to the QA test-discipline (no mocked backing service, integration-style, behavioral assertions). If a QA test looks wrong, raise it to me rather than editing it.

Keep <ARTIFACT_DIR>/tasks.json updated as you go. Run `<your checks>` (# CUSTOMIZE: e.g. `npm run typecheck && npm test && npm run lint`) before declaring done; LOCAL green is the Phase-3 done gate. There is no PENDING_CI hand-off: the tree is complete when you hand off. Open the PR and return WITHOUT waiting for remote CI; the panel reviews the finished diff while remote CI runs concurrently, and remote CI-green is a merge precondition, verified at merge.

Write <ARTIFACT_DIR>/impl-report.json at completion, including the requirement_checks array AND the qa_signoff block (coverage record of QA-authored tests plus any internal-unit tests you added: test files, edge cases covered, acceptance mapping, verdict APPROVE). Record anything you observed and did not fix in deferred[], with a tracker_ref obtained from `node "${CLAUDE_PLUGIN_ROOT}/scripts/deferral.mjs" record ...` (it routes by deferralTracker); the gate refuses a deferral with no resolvable ref. Open a PR against the integration branch with Closes #<issue>.

Before you return, run the Phase 3 exit against your own artifacts (no --status: the record is mine) and PASTE its output in your reply:
  node "${CLAUDE_PLUGIN_ROOT}/scripts/phase3-exit.mjs" --issue <issue> --worktree "<WORKTREE_PATH>" --artifact-dir "<ARTIFACT_DIR>"
Exit 2 is YOURS to fix before you hand off, exit 3 is a tripwire to report, and exit 4 or any other exit is not yours to fix: stop and report it to me. I run it again at the transition.

Return a short summary with branch name, commit count, check status, acceptance mapping status, PR URL.
  """
})
```

