---
description: Run a single pipeline phase for resume, retry, or targeted re-review. Wraps the Agent tool dispatch with artifact validation. Accepts a phase name and issue number.
argument-hint: <phase: ba|dba|devops|secops|design-review|dev|qa|peer-review|librarian> --issue <number> [extra context]
allowed-tools: Read, Grep, Glob, Bash, Write, Edit, Agent
---

# /phase

Run a single phase of the pipeline without running the full orchestrator. Useful for:
- Resuming a halted pipeline after a SecOps veto rework.
- Re-running a single agent's review after the spec was revised.
- Ad-hoc librarian consistency checks.

**Argument:** `$ARGUMENTS`

Parse the argument:
- First token: phase name. One of `ba`, `dba`, `devops`, `secops`, `design-review`, `dev`, `qa`, `peer-review`, `librarian`.
- `--issue <number>` (required except for `ba` on a fresh ask).
- Remaining tokens: extra context to pass into the subagent prompt.

Example invocations:
- `/phase dba --issue 847`
- `/phase secops --issue 847 focus on the new webhook endpoint`
- `/phase design-review --issue 847`
- `/phase peer-review --issue 847`
- `/phase librarian --issue 847`

---

## Preflight

1. **Resolve the absolute artifact dir.** Run `PIPELINE_BASE="$(git rev-parse --show-toplevel)/.pipeline"`, `ARTIFACT_DIR="$PIPELINE_BASE/<issue>"`. Pass `ARTIFACT_DIR` (fully expanded) into the subagent prompt, exactly as `/pipeline` does, so the subagent reads and writes artifacts at an absolute path and never resolves `.pipeline/...` from its own cwd. For a phase that runs inside the implementation worktree (`dev`, `qa`, `peer-review`), `ARTIFACT_DIR` is `<WORKTREE_PATH>/.pipeline/<issue>` instead, matching `/pipeline` Phases 3-4.
2. If `--issue` provided: verify `$ARTIFACT_DIR/` exists. If not, halt and tell the owner.
3. Read `$ARTIFACT_DIR/status.json` (if present) to understand the pipeline's current state.
4. Verify the phase is a valid next step or a re-run. Do not block on order; the owner may be intentionally re-running.

---

## Dispatch

Based on the phase name, invoke the corresponding subagent with a targeted prompt. The subagent reads the same artifacts as in `/pipeline` and writes its output to the same files.

### ba

Invoke with either:
- A fresh ask (no `--issue` yet): BA creates the issue.
- Rework after a SecOps veto: pass the veto reason in extra context. BA addresses it in the spec revision.

### dba, devops, secops

Targeted Phase 2 re-review. Prompt includes:
- "Re-review after <change reason>. Read `<ARTIFACT_DIR>/spec.json` and any existing `<ARTIFACT_DIR>/review.json`. Write your fresh BARE block to `<ARTIFACT_DIR>/review.<agent>.json` (top-level `verdict`, no role wrapper), exactly as in the parallel fan-out. Return a fresh verdict."

The agent contract is identical in every case: agents always emit a bare shard. A single re-run is not concurrent, so the orchestrator (not the agent) merges that one new shard into `review.json` under its key, with the same defensive unwrap `/pipeline` uses so a wrapped shard cannot null the verdict:

```bash
ISSUE=<issue>; AGENT=<dba|devops|secops>
FILE="$ARTIFACT_DIR/review.json"; SHARD="$ARTIFACT_DIR/review.$AGENT.json"
[ -f "$FILE" ] || echo '{}' > "$FILE"
tmp=$(mktemp) && jq \
  --slurpfile s "$SHARD" --arg k "$AGENT" '
  def unwrap($k): if type=="object" and has("verdict") then .
                  elif type=="object" then (.[$k] // .)
                  else . end;
  .[$k] = ($s[0] | unwrap($k))' "$FILE" > "$tmp" && mv "$tmp" "$FILE"
rm -f "$SHARD"
```

### design-review

Targeted re-run of the Design reviewer (the frontend/UX lens), for re-reviewing after a token or accessibility change, or for re-recording the `design_review` evidence the frontend gate checks. Invoke the `design` subagent. Prompt includes:
- "Re-review the frontend surface after <change reason>. Read `<ARTIFACT_DIR>/spec.json` and the diff. Per your agent definition, run the token-conformance, accessibility (axe + the human-residual caveat), and advisory critique/copy lenses. Write your fresh BARE block to `<ARTIFACT_DIR>/review.design_review.json` for a Phase 2 re-run, or `<ARTIFACT_DIR>/peer-review.design_review.json` for a Phase 4 re-run (top-level `verdict`, no role wrapper). A REQUEST_CHANGES is valid ONLY when a concerns[] blocker/major cites a token_lint or axe failure; you hold no veto. Return a fresh verdict."

Merge the single new shard under the `design_review` key with the same defensive `unwrap` as the dba/devops/secops re-run above (set `AGENT=design_review` and point `FILE` at `review.json` or `peer-review.json` to match the phase being re-run).

### dev

Re-run the implementation thread. Usually because scope changed, the panel requested changes, or a coverage gap surfaced. **Read `spec.risk_tier` from `<ARTIFACT_DIR>/spec.json` first; it sets the mode.**

- **Trivial/standard tier:** Dev authors code and tests together. If `<ARTIFACT_DIR>/constraints.md` is missing, extract it first exactly as `/pipeline` Phase 2-lite does (the `sed` over the marker-delimited "Standard-tier constraints" blocks in the three specialist agent files under `${CLAUDE_PLUGIN_ROOT}/agents/{dba,devops,secops}.md`), then prompt:
  - "Risk tier: standard. You author the code AND the behavioral tests together per your agent definition. Read spec.json (acceptance_criteria are your test contract) and constraints.md (every line is a hard constraint). Honor the tripwire: migration, auth/crypto, access-control, or shared-contract-shape work halts back to the orchestrator. Update impl-report.json, including requirement_checks and the qa_signoff coverage record."
- **Architectural tier:** Dev implements against QA's pre-authored behavioral tests and must not weaken or delete them. Prompt:
  - "QA authored the failing behavioral test contract first (see the test commit recorded in status.json, or the existing test files). Read those tests; they are your target. Re-implement or extend per the updated spec until they pass, keeping existing commits and adding new ones. Do NOT edit QA's tests to force a pass; you MAY add tests for internal units QA could not see, held to the QA test-discipline. Update impl-report.json, including requirement_checks and the qa_signoff coverage record."

### qa

Two distinct modes depending on where the pipeline is.

- **Phase 3a (author the failing test contract first; ARCHITECTURAL TIER ONLY):** QA authors deterministic FAILING behavioral tests from `spec.acceptance_criteria` BEFORE Dev implements, commits them, and the commit SHA is recorded in status.json. At trivial/standard tier this mode does not exist (Dev authors its own tests); dispatching it anyway re-introduces the pre-code handoff the standard tier removed. Prompt:
  - "Read spec.json (especially acceptance_criteria) and review.json. Author deterministic FAILING behavioral tests per your agent definition: one per acceptance criterion minimum, derived from BEHAVIOR not implementation shape, worked against the edge-case checklist, no mocked data layer. Do NOT implement the feature. Commit only the test files with a test: commit referencing the issue, confirm they fail for the right reason, and report the commit SHA and the files authored."
- **Phase 4 (binding adversarial verdict):** independent coverage audit on the finished diff (remote CI runs concurrently; CI-green is verified at merge, not required to enter the panel). This is QA's binding test verdict. It is an ADVERSARIAL gap-check, not an auto-pass on green. Prompt:
  - "Audit test coverage against the current diff, impl-report.json, spec.json, and your own Phase-3 behavioral tests with fresh eyes. Green proves only that existing tests pass; hunt for the tests that should exist and do not. Verify every changed path is tested, webhooks cover idempotency/replay, integration tests hit a real data layer, failure modes are covered, and behavior outside your Phase-3 tests is not left untested (overfitting). Return a binding verdict APPROVE | APPROVE_WITH_NOTES | REQUEST_CHANGES | REQUEST_REFACTOR. If you find a gap, name the missing test; do not write it yourself (that loops back to Dev)."

### peer-review

Re-runs the Phase 4 panel in parallel, writing per-agent shards that the orchestrator merges. Same prompt shape, panel-composition rule, and shard-merge step as `/pipeline` Phase 4. This command mirrors `/pipeline` Phase 4 exactly, including the **delta re-review** semantics, so a manual re-run and the auto re-review never diverge.

- **First (full) run of a panel:** resolve `PANEL_ROLES` by tier (all six at architectural; `qa secops` at trivial; `ba dev qa secops` plus surface-conditional `dba`/`devops` at standard; plus the surface-conditional `design_review` lens at EVERY tier when the diff touches a frontend surface), record it in status.json `panel_roles`, dispatch all of them, and merge via `node "${CLAUDE_PLUGIN_ROOT}/scripts/merge-peer-review.mjs" <peer-review.json> <role>=<shard> ...` against a freshly reset `peer-review.json`.
- **Delta re-run (the panel already ran and Dev pushed fixes):** the original `panel_roles` in status.json is the authoritative FULL panel; do NOT shrink it. Seed the delta set with `DELTA="qa secops"` UNCONDITIONALLY (both re-review the fix commits on every delta round; SecOps is never-trimmed, so its round-1 APPROVE never stands in on a delta round, exactly like QA's), THEN add the objecting role(s), THEN add any role whose SURFACE the fix commits touched (reuse the same greps `/pipeline` Phase 4 uses: the data-layer glob for DBA, the infra/CI glob for DevOps, `${CLAUDE_PLUGIN_ROOT}/scripts/frontend-surface.mjs` for Design). SecOps's VETO semantics are unchanged. Merge the delta shards INTO the existing `peer-review.json` with the same `merge-peer-review.mjs` invocation (do NOT reset the file), so the standing approvals of the NON-delta roles are preserved while QA and SecOps are always freshly re-reviewed. Compute `peer_review_verdict_counts` and the final verdict over the FULL `panel_roles`, list every panel role in the PR summary, and record the re-dispatched subset in the phase event note (`panel_roles` stays the original full panel for audit).

### librarian

Runs Librarian's post-merge or ad-hoc duties. Prompt includes:
- If post-merge: "Archive issue #<n> to the knowledge store, and update the affected `knowledge/living-context/*.json` files (create or supersede via `${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-store.mjs`)."
- If ad-hoc (no issue): "Weekly consistency check across the knowledge store and the code; flag drift."

In the full `/pipeline` run the Librarian is dispatched NON-BLOCKING at Phase 5 (the orchestrator returns to the owner without awaiting the result; see `/pipeline` Phase 5). A manual `/phase librarian` invocation is a foreground run by nature (the owner is waiting on it on purpose), so it blocks normally; the detached semantics are a property of the auto Phase 5 dispatch, not of this manual command.

---

## Post-dispatch

After the subagent returns:
1. Validate the expected artifact was written or updated.
2. Update `.pipeline/<issue>/status.json` to append a `"phase-rerun"` event with timestamp.
3. Return to the owner with the subagent's verdict.

---

## Hard rules

- Do not skip artifact validation. A phase that did not write its artifact did not complete.
- Do not mutate artifacts directly. Only the subagent for that phase writes its own block.
- If the phase is blocked (missing upstream artifact), halt and tell the owner which artifact is missing.
