## Phase 5: Knowledge Persistence (post-merge)

**Checkpoint first:** `checkpoint.mjs enter 5-archive --exit-verdict <verdict> --commit` (`status-record.md`; it writes `current_phase: "5-archive"`) BEFORE dispatching the Librarian.

Trigger: after the owner confirms the PR merged. The owner can invoke `/pipeline --resume <issue>` to kick Phase 5 off.

Verify merge: `node "${CLAUDE_PLUGIN_ROOT}/scripts/check-merged.mjs" --issue <issue> --status "$PIPELINE_BASE/<issue>/status.json"`. Any exit but 0: halt and tell the owner what it printed.

**Dispatch the Librarian NON-BLOCKING; do not hold the session on Phase 5.** Post-merge archival can run long while the owner waits on a step whose result is not a gate. `run_in_background` is a Bash-tool primitive and does NOT apply to an Agent dispatch, so the concrete non-blocking mechanism is: **checkpoint `5-archive`, dispatch the Librarian as the LAST action of the run, and return the completion summary to the owner in the SAME turn WITHOUT awaiting or reading the Librarian's result.** The archival is not a merge gate and its outcome does not change the pipeline verdict, so control returns to the owner immediately; the Librarian's knowledge-store and archive work completes out of band. If only the mechanical archival is wanted detached (not the Librarian's knowledge-store judgment), the fallback is to run `${CLAUDE_PLUGIN_ROOT}/scripts/archive-pipeline.mjs --issue <issue>` via a backgrounded Bash call (`run_in_background`) and skip the Agent dispatch. Either way the orchestrator session does not block on Phase 5.

Invoke Librarian (dispatch, then return to the owner without awaiting the result):
```
Agent({
  subagent_type: "librarian",
  description: "Phase 5 archival for #<issue>",
  prompt: """
Issue #<issue> merged to the integration branch (main).

Artifact directory (absolute): <PIPELINE_BASE>/<issue>. This is the canonical post-sync copy; the Phase 3/4 worktree may already be gone. Read and write artifacts only at this absolute path.

Run post-merge duties per your agent definition:
1. Update impacted knowledge-store files under knowledge/living-context/ (one topic per file; to supersede a topic, set the old file's status to "superseded" and write the new one status "current").
2. If this change touched a load-bearing contract with a contract-consumer catalog, refresh the relevant knowledge/living-context/<domain>--<contract>-consumers.json catalog under the contract's owning domain (readers across all layers: code call sites, data-layer function/view bodies, and independent re-derivations). These catalogs seed the Phase 0.5 map.
3. Persist the updated knowledge-store files via ${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-store.mjs (the knowledge/living-context/*.json files are the canonical source of truth).
4. Archive the pipeline run via ${CLAUDE_PLUGIN_ROOT}/scripts/archive-pipeline.mjs --issue <issue>.
5. Record standalone decisions if any under knowledge/decisions/.
6. Clean up <PIPELINE_BASE>/<issue>/ after archival verification.

Write <PIPELINE_BASE>/<issue>/librarian-report.json. Return a short summary.
  """
})
```

`${CLAUDE_PLUGIN_ROOT}/scripts/archive-pipeline.mjs` reads the artifact directory it is given and archives whatever it finds there. **The Phase 4 sync step above is the ONLY mechanism that preserves worktree artifacts; there is no fallback behind it.** Earlier revisions of this file described the script also falling back to `<status.worktree_path>/.pipeline/<issue>/`, which it has never implemented. Do not skip the sync step on the assumption that archival will recover the files afterwards: once the Phase 3 worktree is removed, anything not synced is gone.

Because the Librarian is dispatched non-blocking, mark the run terminal at DISPATCH time, not on the Librarian's return:
- Update `status.json` with `current_phase: "5-archived"`, `completed_at: <iso>` as part of the same turn that dispatches the Librarian, then return the completion summary to the owner. The Librarian finishes out of band.
- **The completion summary is the feature complete report** from `${CLAUDE_PLUGIN_ROOT}/voice.md`, used verbatim as the template: what it does now that it did not do before (from a user's point of view), the analogy and where it breaks, what changed grouped by what a person would notice rather than by file, what it means for the owner, what you deliberately did not do, and what to watch for over the next two weeks. This is the report the owner actually reads, and for most runs it is the only part of the pipeline they see. It replaces the changelog dump; do not substitute a verdict line for it.
- Optional: the Librarian itself (or a later session) removes `.pipeline/<issue>/status.json` or moves the whole dir to `.pipeline/_archived/<issue>/` for audit after it verifies archival.

