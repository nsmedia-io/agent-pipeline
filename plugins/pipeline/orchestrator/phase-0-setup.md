## Phase 0: Setup

Run Phase 0 as one command, the `/pipeline` argument verbatim inside the quoted heredoc (never as shell words):

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/pipeline-init.mjs" --argument-stdin <<'PIPELINE_ASK_EOF_7f3a'
<the argument>
PIPELINE_ASK_EOF_7f3a
```

It prints one JSON object (config check, dirty tree, base, fetch, record, resume point), stopping at the first halt:

0. **Exit 2: no `pipeline.config.json` at the checkout root. HALT the pipeline** and say so to the owner in **reduced voice** (see "Human-facing responses"): this checkout either predates the plugin's adoption or was never configured. Do not create the file yourself and do not proceed on defaults; the owner picks the remedy the JSON `error` names (copy the example config, or move to the checkout that has one).
   The incident that made this a halt rather than a warning is recorded in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Phase 0 step 0").
   `hooks/session-start.sh` reports the same condition at session start, loudly and without refusing anything; a hook must never wedge a session. This step is where the refusal lives.
1. **Exit 3: the tree is dirty** (`dirty` holds the `git status --short` lines, `branch` and `head` the state). Surface to the owner before proceeding, in **full voice mode** with a decision block (see "Human-facing responses"): uncommitted work you did not write is not yours to stash, commit, or discard, and the owner is the only one who knows whether it matters.
   **That halt is deliberately outside `voice-lint.mjs`'s reach, and that is a ruling (#80), not an oversight.** The lint derives whether a message is owner-facing from `status.json`, and the `0-setup` record write below is what first writes one, so at this halt there is no record to derive from and the check is silent (measured: an em dash in a step-1-shaped halt exits 0 with zero bytes; the identical message at `5-archived` exits 2 with five named failures). Every way of making the moment resolvable this early is worse than the gap: writing a record first makes this very worktree check report the pipeline's own untracked artifact as dirty work, and letting the orchestrator declare its own moment hands the trigger to the party being graded, so forgetting to set it buys silence. **So the shape of this message is on you, not on a hook.** Read `${CLAUDE_PLUGIN_ROOT}/voice.md` and compose it as a full-voice decision block anyway. **If you reorder Phase 0, or put an owner-facing full-voice decision block anywhere between the `0-setup` write below and the next phase's own checkpoint write, this ruling is void** and `NON_VOICE_PHASES`'s `0-setup` entry has to move; `tests/test-voice-lint.sh`'s #80 suite reddens on exactly that edit.

Exit 1 halts with the JSON `error`. On exit 0 set `PIPELINE_BASE` and `ARTIFACT_DIR` from `pipeline_base` and `artifact_dir` (absolute; pass `ARTIFACT_DIR` verbatim into every subagent prompt, and in Phases 3-4 use the one `worktree.mjs` prints). `resume_phase` is the phase to re-enter from the top. Report any `warnings` before Phase 2 (a failed fetch of the integration branch, or an ask whose credential shape kept it out of `ask_text`), and re-fetch at the top of any re-run that re-enters Phase 2. `record: "written"` is the initial `status.json` (`"current_phase": "0-setup"`), written through `checkpoint.mjs`; a fresh ask has no issue yet, so its skeleton is in `status`, to write at `$PIPELINE_BASE/<issue>/status.json` once BA names the issue.
