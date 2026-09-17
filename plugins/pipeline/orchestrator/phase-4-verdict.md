Then:

- Read `$ARTIFACT_DIR/peer-review.json` (the merged file you just wrote in the worktree).
- Compute `final_verdict` using the rubric below. Precedence is from most-blocking to least; the first rule that matches wins. The orchestrator's own `status.json` writes always target `$PIPELINE_BASE/<issue>/status.json` (the canonical, committed copy), regardless of where the worktree artifacts live.

### Final verdict rubric (strict precedence, first match wins)

**The rubric reads `materiality.blocks_merge`, not the verdict word.** A role's block refuses the merge exactly when its `blocks_merge` is `true`, which is exactly when its `open_blocker_ids` is non-empty; the recorded verdict only says which loop a refusal takes. `finalVerdict(peerReview, panelRoles)` in `${CLAUDE_PLUGIN_ROOT}/scripts/materiality.mjs` is the code form of the five rows below, and a hand reading that disagrees with it is the defect.

1. **`SECOPS_VETO`**: a block whose verdict is `VETO` has `blocks_merge: true`. After the merge that can only be SecOps, on a valid `veto_ground`, carrying at least one blocking concern; any other `VETO` was already recorded as `REQUEST_CHANGES` (or `APPROVE_WITH_NOTES` when nothing blocks) with `verdict_as_returned` beside it, and does not return the spec to BA. Sending the spec back to BA is a spec revision: run `round-budget.mjs enter spec-revision` first (see Phase 2's gate). Pipeline halts. The PR must not merge. Update `status.json` with `current_phase: "4-veto-rework-required"`, `veto_reason`. Return to the owner in **full voice mode** (see "Human-facing responses"); the line below is the factual spine, not the whole message:
   ```
   **[Orchestrator]:** PEER REVIEW VETO. SecOps blocked merge: <one-line reason>. Spec returns to BA for redesign. Resume with /pipeline --resume <issue>.
   ```
2. **`REQUEST_REFACTOR`**: a block whose verdict is `REQUEST_REFACTOR` has `blocks_merge: true` (QA, testability blocked by code structure, carrying a blocking concern; a REQUEST_REFACTOR with none was recorded as `APPROVE_WITH_NOTES`). It is a fix round, counted exactly like row 3: run `round-budget.mjs enter fix-round` before dispatching Dev, and on exit 2 bring the owner the decision instead. Pipeline returns to the Dev implementation step (3b at the architectural tier, the single Dev thread otherwise); the existing behavioral test contract stands (QA-authored at architectural, Dev-authored at standard), so this re-runs Dev only and then re-runs Phase 4 as a **delta re-review** (QA, which objected, plus any role whose surface the refactor touched; see "Delta re-review" above), not a fresh full panel. `final_verdict: "REQUEST_REFACTOR"`. Do NOT merge.
3. **`REQUEST_CHANGES`**: any block has `blocks_merge: true` (after `merge-peer-review.mjs` its verdict is `REQUEST_CHANGES` and it carries at least one BLOCKING concern under the materiality rule in `${CLAUDE_PLUGIN_ROOT}/evidence.md`, at most two, listed in `open_blocker_ids`). (A returned `REQUEST_CHANGES` with no blocking concern was recorded as `APPROVE_WITH_NOTES` with `verdict_as_returned` beside it; say so in the summary, because the reviewer's finding is still real, it just ships as a note.) `final_verdict: "REQUEST_CHANGES"`. Collect the blocking concerns into the owner-facing summary. Do NOT merge. **Before dispatching Dev, count the round:** `node "${CLAUDE_PLUGIN_ROOT}/scripts/round-budget.mjs" enter fix-round --status "$PIPELINE_BASE/<issue>/status.json"`. Exit 0 records it in `fix_rounds` (budget: tooling 1, product 2, product-money 2); dispatch Dev, then a **delta re-review** (the roles holding open blocker ids, plus any role whose merge-class surface the fix commits touched, per "Delta re-review" above) via `/phase peer-review --issue <n>`, additively merged so the standing approvals hold. Exit 2 means the next round is past the budget and no `owner_overrides` entry covers it: do NOT dispatch Dev. Bring the owner the decision block the command printed (ship with deferrals, split, or stop) in full voice mode; only when the owner chooses to keep going, record `{"kind": "fix-round", "up_to": <n>, "at": "<iso>", "reason": "<their reason>"}` in `owner_overrides` and run the command again.
4. **`APPROVE_WITH_NOTES`**: any agent returned `APPROVE_WITH_NOTES` (or the legacy alias `APPROVE_WITH_NITS`), no blockers above. `final_verdict: "APPROVE_WITH_NOTES"`. Notes SHIP. In this same turn, yourself, with no Dev dispatch and no panel re-run: apply every concern that carries a `suggested_patch` (explicit-path staging, one commit `chore: apply Phase 4 panel notes for #<issue>`, then run the check command and confirm it is green), and write every other note onto ONE deferral checklist for the issue: `node "${CLAUDE_PLUGIN_ROOT}/scripts/deferral.mjs" checklist --issue <issue> --peer-review "$ARTIFACT_DIR/peer-review.json" [--own <id>,<id>] [--unapplied <id>,<id>]`. It records one checklist entry holding every note with its role, id, ratings and location, and a SEPARATE entry only for a note whose `merge_class` is not `none` or whose id the owner named in `--own`; notes that carry a `suggested_patch` are left out as applied unless you name them in `--unapplied` because the patch did not apply. It routes by `deferralTracker` (`gh issue create`, `glab issue create`, or a committed file under `deferralDir`) and prints each ref. Record the refs in `status.json` `flags`. If the configured CLI is missing the script REFUSES rather than inventing a destination; set `"deferralTracker": "directory"` and re-run, so the note lands in the repository instead of nowhere. Neither path delays the merge. A note that turns out not to be local or obviously correct when you try to apply it is filed, not forced.
5. **`APPROVE`**: every dispatched panel role's verdict is `APPROVE`. `final_verdict: "APPROVE"`. Ready for human merge to the integration branch.

Rows 2 and 3 send the run back to Dev. Before the status.json write that loops back, read `${CLAUDE_PLUGIN_ROOT}/orchestrator/phase-4-delta.md` now: that same write clears the verdict, and the rule is stated there.

Verdict-name normalization: `APPROVE_WITH_NOTES` is the canonical term (matches the DBA, DevOps, SecOps agent contracts). The alias `APPROVE_WITH_NITS` is accepted for backward compatibility but should be rewritten to `APPROVE_WITH_NOTES` when observed.

### After computing `final_verdict`

- Update `status.json` with `current_phase: "4-review-complete"`, `final_verdict`, and a `peer_review_verdict_counts` object: `{approve, approve_with_notes, request_changes, request_refactor, veto}`.
- Append a markdown summary comment to the PR (one row per dispatched role; for a trimmed standard-tier panel, list undispatched lenses on a single line as `Not on panel (standard tier): DBA, DevOps` so the trim is visible, never ambiguous):
  ```
  ## Phase 4 Peer Review (<tier> tier panel)
  | Agent | Verdict | Blockers |
  |---|---|---|
  | BA | ... | ... |
  | SecOps | ... | ... |
  | Dev | ... | ... |
  | QA | ... | ... |

  Not on panel (standard tier): DBA, DevOps
  **Final verdict:** <FINAL_VERDICT>
  ```

### Sync Phase 3 artifacts to the orchestrator pipeline directory

Before any worktree cleanup, run `node "${CLAUDE_PLUGIN_ROOT}/scripts/sync-artifacts.mjs" --from "$ARTIFACT_DIR" --to "$PIPELINE_BASE/<issue>"`. It copies by ownership, the list in `scripts/artifact-ownership.mjs` that the archive's staleness check also reads: seeded files no-clobber, files produced in the worktree forced. Classify any `UNCLASSIFIED` line it prints in that module. Exit 1 is a failed copy: resolve it before cleanup, because the Phase 5 archive has no fallback to the worktree.

**Run it twice: here, and again immediately before the Phase 5 Librarian dispatch.** An `APPROVE_WITH_NOTES` round keeps writing `impl-report.json`, `map.json` and `peer-review.json` after this point. The measurement behind the ownership split and the archive-time backstop are in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Artifact sync").

Do NOT merge. The owner merges to the integration branch. Presenting a PR as ready to merge is a **full voice mode** moment (see "Human-facing responses"): the owner is being asked to accept the change and owns what happens next, so give them the report, the scales, and the decision block if a call is open. Merges to the integration branch follow your project's review policy; production/release promotion needs the owner's explicit go. Before presenting it, run `node "${CLAUDE_PLUGIN_ROOT}/scripts/merge-ready.mjs" --issue <issue> --worktree "$WORKTREE_PATH" --impl-report "$ARTIFACT_DIR/impl-report.json"`, adding `--ref <ref>` for each deferral ref recorded in `status.json` `flags`. It checks that the PR head is the reviewed commit, that CI on that head is green (the panel entered without waiting on CI), and that every deferral ref verifies. Exit 2: not ready; act on the reasons it prints.

**Merge guard (data-migration / security-sensitive changes):** if the diff adds or alters a migration touching access controls or a security-sensitive table, do not present it as ready to merge on CI-green alone when the live-verification suite only skipped. A recorded local pass (run against a real backing service; see the live-verification gate above) is required first; "CI green with the integration suite skipped" is NOT done for such a change. This mirrors the Phase 3 to 4 live-verification gate above.

**Merge guard (the deferral ledger):** every item a panel shard or remediation round marked deferred, routed, out-of-scope or "follow-up" is written in the ledger `deferralTracker` names (a tracker issue, or a committed file under `deferralDir` in `directory` mode) with its evidence and its reasoning: `node "${CLAUDE_PLUGIN_ROOT}/scripts/deferral.mjs" record --issue <issue> --title "<t>" --body-file <path> --evidence "<file:line>" --reason "<why>"`. Pass the ref it prints to `merge-ready.mjs` as `--ref`. A deferral that lives only in a shard, a test comment or a PR body is buried the moment the PR merges, and the reason is usually the part that stops the next person reaching the opposite conclusion.

**Verify, do not relay.** An agent's report that a gate passed is a claim; that gate's output on your own run is evidence. Before merging, re-run the project's full check set yourself with the cache forced off, and confirm the counts match what the agents reported. Two failure modes this catches, both observed: a reported pass from a task-runner invocation that silently ran nothing (an unknown task name errors out and executes zero work while looking like a gate ran), and a reported pass replayed from a warm cache. Report `Cached:` counts alongside pass counts so the difference is visible. When the panel's central finding is a defect a specific control now catches, plant that defect yourself once and watch the control fire before you merge on it.

---

