Then compute and record the verdict. The orchestrator's own `status.json` writes always target `$PIPELINE_BASE/<issue>/status.json` (the canonical, committed copy), regardless of where the worktree artifacts live.

### Final verdict: `scripts/record-verdict.mjs`

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/record-verdict.mjs" --status "$PIPELINE_BASE/<issue>/status.json" --peer-review "$ARTIFACT_DIR/peer-review.json" --pr-body "$ARTIFACT_DIR/pr-summary.md" --commit
```

It applies the rubric (`finalVerdict` in `scripts/materiality.mjs`, which reads `materiality.blocks_merge` and not the verdict word) and the tally (`countVerdicts`) over the FULL `panel_roles`, and writes `final_verdict`, `peer_review_verdict_counts` and the `4-review` exit event in the same write as `current_phase: "4-review-complete"`, or `current_phase: "4-veto-rework-required"` on a veto (pass `--veto-reason "<one line>"`). It prints `final_verdict=`, `next=` (and `then=`) and the budget line, and writes the PR summary table to `--pr-body`: post that file as the PR comment. A hand reading that disagrees with the script is the defect. On a delta round add `--note "delta re-review: <ROLES_TO_MERGE>"`.

- **Exit 1**: a panel role has no recoverable verdict, or `panel_roles` is empty. Nothing was written; halt and re-dispatch the missing reviewer.
- **Exit 4 (`SECOPS_VETO`)**: the pipeline halts and the PR must not merge. Return to the owner in **full voice mode** (see "Human-facing responses"); the line below is the factual spine, not the whole message, then loop back per `next=` (`loop-backs.md`):
  ```
  **[Orchestrator]:** PEER REVIEW VETO. SecOps blocked merge: <one-line reason>. Spec returns to BA for redesign. Resume with /pipeline --resume <issue>.
  ```
- **Exit 3 (`REQUEST_CHANGES` or `REQUEST_REFACTOR`)**: do NOT merge. Collect the blocking concerns into the owner-facing summary; where a returned `REQUEST_CHANGES` was recorded as `APPROVE_WITH_NOTES` (`verdict_as_returned` beside it), say so, because the finding is still real and ships as a note. Read `${CLAUDE_PLUGIN_ROOT}/orchestrator/phase-4-delta.md` now, then loop back per `next=` with `checkpoint.mjs enter 3-impl --loopback` (`loop-backs.md`); `allowed=no` on the budget line means that command will refuse and the owner decides.
- **Exit 0, `APPROVE_WITH_NOTES`**: notes SHIP. In this same turn, yourself, with no Dev dispatch and no panel re-run: apply every concern that carries a `suggested_patch` (explicit-path staging, one commit `chore: apply Phase 4 panel notes for #<issue>`, then run the check command and confirm it is green), and write every other note onto ONE deferral checklist: `node "${CLAUDE_PLUGIN_ROOT}/scripts/deferral.mjs" checklist --issue <issue> --peer-review "$ARTIFACT_DIR/peer-review.json" [--own <id>,<id>] [--unapplied <id>,<id>]`. It files a separate entry only for a note whose `merge_class` is not `none` or whose id the owner named in `--own`, leaves out applied patches unless named in `--unapplied`, routes by `deferralTracker`, and prints each ref; record the refs with `checkpoint.mjs flag`. If the configured CLI is missing it REFUSES rather than inventing a destination; set `"deferralTracker": "directory"` and re-run. A note that turns out not to be local or obviously correct when you try to apply it is filed, not forced.
- **Exit 0, `APPROVE`**: ready for human merge to the integration branch.

### Sync Phase 3 artifacts to the orchestrator pipeline directory

Before any worktree cleanup, copy the Phase 3 and Phase 4 artifacts that QA, Dev, and the panel wrote into the worktree's `ARTIFACT_DIR` back to the canonical `$PIPELINE_BASE/<issue>/`. Phase 3 worktrees are removed by the post-merge cleanup mechanism, which would otherwise delete `tasks.json`, `impl-report.json`, and `peer-review.json` before Phase 5 archival reads them.

**RUN THIS STEP TWICE: here, and AGAIN immediately before the Phase 5 Librarian dispatch.** Under the final-verdict rubric an `APPROVE_WITH_NOTES` panel means nits are fixed in place with no panel re-run, so Dev legitimately keeps writing to `impl-report.json`, `map.json` and `peer-review.json` *after* this point. A sync that runs only at the Phase 3 to 4 transition cannot capture work that happens after it, however the copy is flagged. This is not a belt-and-braces suggestion; a single sync is half a fix.

```bash
SRC="$ARTIFACT_DIR"                       # = $WORKTREE_PATH/.pipeline/<issue>
DST="$PIPELINE_BASE/<issue>"
if [ -d "$SRC" ] && [ "$SRC" != "$DST" ]; then
  mkdir -p "$DST"
  for f in "$SRC"/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in
      # SEEDED IN. The orchestrator wrote these and copied them into the worktree, so the
      # canonical copy is authoritative and the worktree's is the stale seed.
      spec.json|review.json|review.*.json|constraints.md|status.json)
        cp -n "$f" "$DST/" 2>/dev/null || true ;;
      # PRODUCED THERE. Written IN the worktree by Dev, QA and the Phase 4 panel, so the
      # worktree copy is the newer one and no-clobber freezes the wrong side.
      map.json|tasks.json|impl-report.json|peer-review.json|peer-review.*.json)
        cp -f "$f" "$DST/" 2>/dev/null || true ;;
      # UNCLASSIFIED. Copy on the safe side and SAY SO, so a new artifact type surfaces as a
      # line to classify rather than being silently frozen or silently clobbered.
      *)
        cp -n "$f" "$DST/" 2>/dev/null || true
        printf 'sync: %s matches no ownership rule; copied no-clobber. Classify it above.\n' "$b" ;;
    esac
  done
fi
```

**The split is by OWNERSHIP, not by first arrival.** Do not collapse this back to one flag in either direction -- both directions are wrong for half the files. The measurement behind it (#34) is in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Artifact sync").

The `"$SRC" != "$DST"` guard is a no-op safety for the case where a future change runs Phases 3-4 in the same checkout as the orchestrator.

The archive-time backstop behind the run-it-twice rule, and the case where it abstains, are described in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Artifact sync: the archive-time backstop"); it is not a substitute for the second sync.

Do NOT merge. The owner merges to the integration branch. Presenting a PR as ready to merge is a **full voice mode** moment (see "Human-facing responses"): the owner is being asked to accept the change and owns what happens next, so give them the report, the scales, and the decision block if a call is open. Merges to the integration branch follow your project's review policy; production/release promotion needs the owner's explicit go. Remote CI-green is the MERGE precondition that ran concurrently with the panel: before presenting the PR as ready to merge, verify remote CI is green on the current head (the PR head SHA matches the reviewed HEAD, and the CI conclusion on that head is green), since the panel entered without waiting on it.

**Merge guard (data-migration / security-sensitive changes):** if the diff adds or alters a migration touching access controls or a security-sensitive table, do not present it as ready to merge on CI-green alone when the live-verification suite only skipped. A recorded local pass (run against a real backing service; see the live-verification gate above) is required first; "CI green with the integration suite skipped" is NOT done for such a change. This mirrors the Phase 3 to 4 live-verification gate above.

**Merge guard (the deferral ledger):** before presenting the PR as ready, collect every item any panel shard or remediation round marked deferred, routed, out-of-scope, or "follow-up", and confirm each one is **written in the ledger** with its evidence and its reasoning. THE LEDGER IS WHATEVER `deferralTracker` NAMES: a tracker issue under `github` or `gitlab`, and a committed markdown file under `deferralDir` (default `knowledge/deferred/`) under `directory`, which is the answer for a project with no tracker CLI. Record each with `node "${CLAUDE_PLUGIN_ROOT}/scripts/deferral.mjs" record --issue <issue> --title "<t>" --body-file <path> --evidence "<file:line>" --reason "<why>"` and keep the ref it prints; `node "${CLAUDE_PLUGIN_ROOT}/scripts/deferral.mjs" verify <ref>` answers whether a ref resolves, and it is the same function the pre-Phase-4 gate calls on every `deferred[]` entry, so the two can never disagree. A deferral that lives only in a shard, a test comment, or a PR body is buried the moment the PR merges. **Check the issue, not the claim.** Record the reasoning as well as the item, because the reason something was deferred is usually the part that stops the next person reaching the opposite conclusion.

**Verify, do not relay.** An agent's report that a gate passed is a claim; that gate's output on your own run is evidence. Before merging, re-run the project's full check set yourself with the cache forced off, and confirm the counts match what the agents reported. Two failure modes this catches, both observed: a reported pass from a task-runner invocation that silently ran nothing (an unknown task name errors out and executes zero work while looking like a gate ran), and a reported pass replayed from a warm cache. Report `Cached:` counts alongside pass counts so the difference is visible. When the panel's central finding is a defect a specific control now catches, plant that defect yourself once and watch the control fire before you merge on it.

---

