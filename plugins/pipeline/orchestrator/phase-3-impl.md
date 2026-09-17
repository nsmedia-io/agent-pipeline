## Phase 3: Implementation (one thread; shape set by tier)

**Checkpoint first:** set `current_phase: "3-impl"` and commit `status.json` BEFORE dispatching anything in Phase 3, so an interruption anywhere inside Phase 3 resumes into Phase 3 rather than re-running Phase 2.

Phase 3 is coupled write-work and always runs as **a single coherent thread on one tree, one actor at a time**. The tier sets the shape:

- **trivial / standard**: ONE Dev dispatch. Dev writes the code AND its behavioral tests together in the same context, deriving tests from `spec.acceptance_criteria` and holding them to QA's test-discipline standard. This is the A/B-validated monolith write path: no pre-code handoff, full reasoning carried end to end. The independent adversary arrives in Phase 4, where QA audits the finished diff with fresh eyes and renders the binding test verdict.
- **architectural**: TWO sequential dispatches, QA-first. (3a) QA authors the failing behavioral test contract and commits it, then (3b) Dev reads those tests and implements until they pass. The stakes (migrations, access controls, contract changes) justify the extra ceremony of an external behavioral target Dev cannot grade its own homework against.
- **architectural + `spec.ab_build: true`**: the rare dual-build A/B, stated in `phase-3-architectural.md`.

All of these shapes preserve the property that killed the old `PENDING_CI` race: no agent ever builds against or reviews a half-built tree owned by a concurrent agent.

**Architectural tier: read `${CLAUDE_PLUGIN_ROOT}/orchestrator/phase-3-architectural.md` now, before any Phase 3 dispatch.** It holds the falsifiability gate and the hard sequencing gate, which run before the worktree steps below, the dual-build shape, and the Phase 3a (QA) and 3b (Dev) dispatches that replace the single Dev dispatch at that tier.

Before dispatching, the orchestrator resolves the active worktree path:
1. If a Phase-3 worktree for this issue already exists, read its path from `$PIPELINE_BASE/<issue>/tasks.json` `worktree_path`, or from `git worktree list --porcelain` matching the issue branch.
2. If none exists, pre-create one: `WORKTREE_PATH=".claude/worktrees/<issue>-phase3-$(date +%Y%m%d-%H%M%S)"; git worktree add "$WORKTREE_PATH" -b <branch-type>/<issue>-<slug> origin/main`. Expand to the absolute path before substituting into the prompts.

**Do not write `worktree_path` into `status.json`. OMIT the field.** The worktree path lives in `tasks.json`, which is where Dev writes it and where every consumer (this step, QA's landing step, `validate-pipeline-artifact.mjs`) reads it; nothing reads it back out of `status.json`, and it is not in the schema's `required` list. `status.json` is committed AND archived verbatim, so the field is a standing leak surface with no reader. If you write it anyway, it must be a REPO-RELATIVE path (`.claude/worktrees/<issue>-phase3-<stamp>`) and nothing else: not an absolute path, and not an English sentence explaining where the path went, which is a free-text note in a field the schema types as a path.
3. **Seed the worktree's artifact dir and set its `ARTIFACT_DIR`.** The fresh worktree is checked out from `origin/main`, where the gitignored per-issue artifacts do not exist, so QA's and Dev's inputs must be copied in. The worktree is the artifact home for Phase 3 and Phase 4 (the Phase 4 sync step copies the outputs back to `$PIPELINE_BASE/<issue>` before archival):
   ```bash
   ABS_WT="$(cd "$WORKTREE_PATH" && pwd)"
   ARTIFACT_DIR="$ABS_WT/.pipeline/<issue>"
   mkdir -p "$ARTIFACT_DIR"
   for f in spec.json review.json constraints.md map.json design.json; do
     cp "$PIPELINE_BASE/<issue>/$f" "$ARTIFACT_DIR/" 2>/dev/null || true
   done
   ```
4. Substitute the absolute `WORKTREE_PATH` and the absolute `ARTIFACT_DIR` into the prompt(s) below (at the architectural tier, QA in 3a and Dev in 3b share the same worktree and the same `ARTIFACT_DIR`).

### Phase 3 dispatch, trivial/standard tier: single Dev thread (code and tests together)

```
Agent({
  subagent_type: "dev",
  description: "Dev Phase 3 implementation for #<issue> (standard tier)",
  prompt: """
Active worktree path: <WORKTREE_PATH>
Artifact directory (absolute): <ARTIFACT_DIR>
Risk tier: <trivial|standard>. You are the SINGLE implementation thread: you author the code AND its behavioral tests together in this one context (standard-tier mode in your agent definition).

First, cd to that worktree. Every subsequent read, write, and bash call MUST use absolute paths rooted at that worktree. Do not operate from the root checkout. Read and write ALL pipeline artifacts at the absolute <ARTIFACT_DIR>; never resolve .pipeline relative to cwd.

Read, in order:
1. <ARTIFACT_DIR>/spec.json. The acceptance_criteria are your test contract: derive the behavioral tests from them per your agent definition, held to QA's test-discipline standard.
2. <ARTIFACT_DIR>/constraints.md (standard tier). The DBA/DevOps/SecOps standing constraints. Treat every line as a Phase-2-equivalent HARD constraint; the Phase 4 panel verifies the diff against this exact file.
3. <ARTIFACT_DIR>/map.json if present. The blast radius: consumers your change must not break.

TRIPWIRE (hard rule): if implementation turns out to require a migration, an access-control change, a new auth surface, crypto, webhook verification, or a change to a shared contract's shape, STOP. Commit nothing further, write your partial state to tasks.json, and return to me with tripwire_reason. That work is architectural-tier and must not ship through the standard lane.

Implement per your agent definition. Keep <ARTIFACT_DIR>/tasks.json updated. Run `<your checks>` (# CUSTOMIZE: e.g. `npm run typecheck && npm test && npm run lint`) before declaring done; LOCAL green is the Phase-3 done gate. Open the PR and return WITHOUT waiting for remote CI: the panel reviews your finished diff while remote CI runs concurrently, and remote CI-green is verified at merge, not before the panel.

Write <ARTIFACT_DIR>/impl-report.json at completion, including requirement_checks AND the qa_signoff coverage record of the tests you authored. Record anything you observed and did not fix in deferred[], with a tracker_ref obtained from `node "${CLAUDE_PLUGIN_ROOT}/scripts/deferral.mjs" record ...` (it routes by deferralTracker); the gate refuses a deferral with no resolvable ref. Open a PR against the integration branch with Closes #<issue>.

Before you return: run BOTH pre-Phase-4 gates against your own artifacts and PASTE their output in your reply.
  node "${CLAUDE_PLUGIN_ROOT}/scripts/gate-pre-phase4.mjs" --issue <issue> --impl-report "<ARTIFACT_DIR>/impl-report.json" --spec "<ARTIFACT_DIR>/spec.json"
  node "${CLAUDE_PLUGIN_ROOT}/scripts/gate-pre-phase4-frontend.mjs" --issue <issue> --impl-report "<ARTIFACT_DIR>/impl-report.json"
A gate that refuses is YOURS to fix before you hand off; I run both again at the transition and a refusal discovered there costs a full round trip. SKIP from the frontend gate is a pass.

Return a short summary with branch name, commit count, check status, acceptance mapping status, PR URL.
  """
})
```

After Dev returns: if Dev reported a tripwire, update `status.json` with `current_phase: "3-impl-tripwire"`, loop back to BA to re-tier the spec to `architectural`, and on resume re-enter at Phase 2 (the reviewer fan-out) carrying the partial worktree. Otherwise validate `impl-report.json` and proceed to the Phase 3 to 4 gate. Skip the 3a/3b sections in `phase-3-architectural.md`; they are the architectural-tier shape.

Do NOT inject a per-requirement `PASS/PARTIAL/SKIP` enumeration rule, or the edge-case checklist, into any Phase 3 prompt. Those duties live in `${CLAUDE_PLUGIN_ROOT}/agents/dev.md` (Phase 3 steps) and `${CLAUDE_PLUGIN_ROOT}/agents/qa.md` (the behavioral-test authoring duty and the test-discipline standard). Duplicating them here re-introduces two-sources-of-truth drift. The same rule is why Phase 2-lite COPIES the constraint checklists out of the agent files with `sed` instead of restating them.

If Dev returns with `scope_drift.detected === true` (or discovers the spec rests on a wrong assumption, not just added scope):
- Loop back to BA for a ruling:
  ```
  Agent({subagent_type: "ba", description: "BA scope-drift ruling for #<issue>", prompt: "Dev flagged scope drift or a wrong spec assumption: <details>. Artifact directory (absolute): <ARTIFACT_DIR>. Read <ARTIFACT_DIR>/spec.json and <ARTIFACT_DIR>/impl-report.json. If you revise the spec, write it back to <ARTIFACT_DIR>/spec.json. Rule: extend spec, roll back drift, correct the assumption, or escalate to the owner."})
  ```
- Execute BA's ruling before continuing. If the ruling rewrites requirements or acceptance criteria materially: at the architectural tier, re-run the affected Phase 2 reviewer(s), then re-run Phase 3 from 3a so QA re-authors tests for the changed criteria before Dev resumes; at the standard tier, re-extract constraints if domains changed, then re-dispatch the single Dev thread against the revised spec.

If Dev completes with no drift, `qa_signoff.verdict === "APPROVE"`, and green LOCAL checks:
- Update `status.json` with `current_phase: "3-impl-complete"`, `pr_url: <url>`.
- Proceed to Phase 4, where QA renders the binding adversarial test verdict.

**Overlap the panel with remote CI (do not serialize the CI wait).** Dev opens the PR and returns on LOCAL green (the project checks), which stays the Phase-3 done gate; Dev does NOT wait for remote CI. The pre-Phase-4 gates below and the Phase 4 panel dispatch IMMEDIATELY, concurrently with remote CI. Remote CI-green is no longer a panel-entry precondition; it is a MERGE precondition, verified at merge time (the PR head SHA matches the reviewed HEAD, and the CI conclusion on that head is green). This drops a serialized multi-minute remote-CI wait from every run without reintroducing the `PENDING_CI` half-built-tree race: the tree is COMPLETE at hand-off, only the remote-CI WAIT is dropped.

---
