## Phase 0: Setup

0. **Before anything else, confirm this checkout is configured for the plugin.** Run `test -f "$(git rev-parse --show-toplevel)/pipeline.config.json"`. If the file is ABSENT, **HALT the pipeline** and say so to the owner in **reduced voice** (see "Human-facing responses"): this checkout either predates the plugin's adoption or was never configured, and running from it would use stale or missing tooling. Do not create the file yourself and do not proceed on defaults; the owner decides whether this is the right tree. The remedy is one of two things and the owner picks: copy `${CLAUDE_PLUGIN_ROOT}/pipeline.config.example.json` to the checkout root and edit it, or move to the checkout that already has one.
   The incident that made this a halt rather than a warning is recorded in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Phase 0 step 0").
   `hooks/session-start.sh` reports the same condition at session start, loudly and without refusing anything; a hook must never wedge a session. This step is where the refusal lives.
1. Verify worktree state. Run `git status --short && git log -1 --oneline`. If not on a feature/fix/chore branch and this is a fresh ask, continue (BA will create the branch post-spec). If dirty, surface to the owner before proceeding, in **full voice mode** with a decision block (see "Human-facing responses"): uncommitted work you did not write is not yours to stash, commit, or discard, and the owner is the only one who knows whether it matters.
   **That halt is deliberately outside `voice-lint.mjs`'s reach, and that is a ruling (#80), not an oversight.** The lint derives whether a message is owner-facing from `status.json`, and step 5 below is what first writes one, so at this halt there is no record to derive from and the check is silent (measured: an em dash in a step-1-shaped halt exits 0 with zero bytes; the identical message at `5-archived` exits 2 with five named failures). Every way of making the moment resolvable this early is worse than the gap: writing a record first makes this very worktree check report the pipeline's own untracked artifact as dirty work, and letting the orchestrator declare its own moment hands the trigger to the party being graded, so forgetting to set it buys silence. **So the shape of this message is on you, not on a hook.** Read `${CLAUDE_PLUGIN_ROOT}/voice.md` and compose it as a full-voice decision block anyway. **If you reorder Phase 0, or put an owner-facing full-voice decision block anywhere between the `0-setup` write below and the next phase's own checkpoint write, this ruling is void** and `NON_VOICE_PHASES`'s `0-setup` entry has to move; `tests/test-voice-lint.sh`'s #80 suite reddens on exactly that edit.

2. **Resolve the absolute pipeline base.** Run `PIPELINE_BASE="$(git rev-parse --show-toplevel)/.pipeline"`. This anchors every artifact to *your* checkout (the orchestrator's), not to whatever cwd a subagent inherits. Once `ISSUE` is known, `ARTIFACT_DIR="$PIPELINE_BASE/<ISSUE>"`. You pass `ARTIFACT_DIR` (fully expanded to its absolute value) into every subagent prompt. Phases 1 and 2 read and write artifacts here. Phase 3 runs inside the implementation worktree, so its `ARTIFACT_DIR` is `<WORKTREE_PATH>/.pipeline/<ISSUE>` (the worktree is the artifact home there); the Phase 4 sync step copies those back into `$PIPELINE_BASE/<ISSUE>` before archival.
3. **Fetch fresh integration branch.** Run `git fetch origin main` now (# CUSTOMIZE: your integration branch, default `main`) so Phase 2 reviewers read config, workflows, and migrations against `origin/main` rather than a possibly-stale local checkout. The base checkout can sit far behind origin (this is the source of false "this gate/file does not exist" drift claims). Re-fetch at the top of any re-run that re-enters Phase 2.
4. If `ISSUE` is known: ensure `$ARTIFACT_DIR/` exists; read `status.json` if present to determine resume point.
5. Write initial `status.json`:

```json
{
  "issue_number": <number or null>,
  "current_phase": "0-setup",
  "started_at": "<iso-now>",
  "updated_at": "<iso-now>",
  "branch": "<current branch>",
  "ask_text": "<truncated ask>",
  "events": [],
  "flags": []
}
```

