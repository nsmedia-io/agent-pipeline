## Phase 1: BA Validation & Spec

**Checkpoint first:** `checkpoint.mjs enter 1-ba --exit-verdict <verdict> --commit` (`status-record.md`; it writes `current_phase: "1-ba"`) BEFORE dispatching BA.

**BA's tier is not in the record at this checkpoint, by construction.** `risk_tier` is BA's OUTPUT, and the checkpoint above is committed before BA is dispatched: the 1-ba checkpoint is written before BA runs, so the risk_tier at 1-ba is whatever an EARLIER write left there, never the output of the BA dispatch this checkpoint precedes. That earlier write is usually Phase 0.5: map depth is gated by tier and the map dispatch interpolates it, so a record whose 0.5-map has run reaches its FIRST `1-ba` checkpoint with a tier already in the field. A rework re-entry is a second and rarer route to the same shape, since this checkpoint is re-written before each BA dispatch. And when nothing earlier set it, the field is simply absent. All three shapes are on disk: read the earliest `1-ba` state of each committed record under `.pipeline/` and `34` arrives with no tier and an empty `events[]`, while `exp-airlock` and `exp-claims` arrive carrying `architectural` with `0.5-map` already recorded. A tier that IS present here is read normally. What nothing downstream may do is infer a tier from its ABSENCE at this phase, or treat an absent tier here as a determined one. The phase-entry guard honors that ordering rather than guessing: a row restricted to a tier does not apply when the record carries no determined tier, so a tier-restricted prerequisite is OFF here rather than resolved to the strictest row. Re-derive with `git grep -n 'tiers: \[' plugins/pipeline/scripts/gate-phase-entry.mjs`, which returns exactly one hit — the `1-ba` row this rule governs. (Cited by behaviour and by the row's own shape, not by the guard's private parameter name: renaming a module-private identifier is a refactor no test pins, and it would silently empty a command published here.)

**Skip if:** `--issue <n>` argument provided AND `.pipeline/<n>/spec.json` already exists with `ba_approved_at`.

Invoke BA via the Agent tool:

```
Agent({
  subagent_type: "ba",
  description: "BA intake for <ask>",
  prompt: """
You are invoked by the /pipeline orchestrator.

Ask from the owner: <full ask text>

Experiment mode: <EXPERIMENT_MODE>. If true, do NOT create a tracker issue; use a local exp-<slug> placeholder id and write spec.json under it, so this run does not pollute the production tracker. If true, ALSO set blocking: false on every open_questions entry and record your recommendation as the answer: an experiment or A/B harness runs unattended, and a blocking question would hang it waiting for a human who is not watching.

Pipeline base (absolute): <PIPELINE_BASE>
Once you create the issue, your artifact directory is <PIPELINE_BASE>/<new-issue-number>. Write spec.json to that absolute path. Do NOT resolve .pipeline relative to your own cwd; it may differ from mine.

Your job:
1. Research the ask (read code, grep, check logs, read the knowledge store).
2. Search existing tracker issues for duplicates.
3. Challenge the ask. Where it is genuinely ambiguous, record the ambiguity in spec.open_questions with your recommendation rather than inventing an answer to keep the artifact valid. blocking: true requires BOTH tests in your agent definition: two different acceptance criteria following from two different answers, AND a difference only the owner can settle (cost, timeline, reversibility, product direction). Otherwise recommend a default, set blocking: false, and proceed. Do not stall the run on a preference or on an engineering call.
4. Triage severity. Set trivial: true only for typos, one-line logic fixes, no data/infra/security impact. Set cost_class (product-money | product | tooling) per duty 6 of your agent definition; a tooling spec over 12 acceptance criteria needs size_justification or it is refused.
5. Create the tracker issue (skip this if Experiment mode is true; use a local exp-<slug> placeholder instead).
6. Write the full spec to <PIPELINE_BASE>/<issue-or-placeholder>/spec.json per the contract in your agent definition.
7. Return a short summary with the issue number, domains, trivial flag, and any concerns.

Do not implement. Do not review schema/infra/security. Hand back to the orchestrator.
  """
})
```

After BA returns:
- Read `$PIPELINE_BASE/<issue>/spec.json` (the absolute path BA wrote to; your own checkout, so a cwd-relative `.pipeline/<issue>/spec.json` resolves to the same file, but read it absolutely to avoid the exact divergence this hardening fixes).
- **Record the cost class and refuse an oversized tooling spec.** Copy `spec.cost_class` into `status.json` (absent reads as `product`, and say so in `flags`); the schema version and the round counters are initialised by `checkpoint.mjs` on the run's first checkpoint. Then run `node "${CLAUDE_PLUGIN_ROOT}/scripts/round-budget.mjs" spec-size --spec "$PIPELINE_BASE/<issue>/spec.json" --status "$PIPELINE_BASE/<issue>/status.json"`. Exit 2 is a REFUSAL, not a warning: a `tooling` spec with more than 12 acceptance criteria and no `size_justification` goes back to BA to split, cut, or justify, and does not proceed.
- **Run the open-questions gate (below) before anything else.** It comes before tier routing, because a blocking question can change the tier.
- Update `status.json` with `current_phase: "1-ba-complete"`, `issue_number: <n>`, append event.

### Open-questions gate

Run `node "${CLAUDE_PLUGIN_ROOT}/scripts/owner-gate.mjs" open-questions --spec "$PIPELINE_BASE/<issue>/spec.json" --status "$PIPELINE_BASE/<issue>/status.json"`, adding `--experiment` when `EXPERIMENT_MODE` is true. It checks the spec's required fields and records a `ba_default` resolution on every non-blocking question (on every question in experiment mode: an unattended run cannot answer one, so a question with no recommendation prints `UNRESOLVED` and the run proceeds). Exit 0: proceed to tier routing. Exit 2 printing `INVALID`: report it to the owner and halt. Any exit other than 0 or 2: halt and show the owner the output. Exit 2 printing `ASK`, the first unresolved blocking question:

1. Update `status.json` with `current_phase: "1-ba-open-questions"` and commit.
2. **Ask that ONE question in full voice mode** with the decision block from `${CLAUDE_PLUGIN_ROOT}/voice.md`: `question` is **What I'm asking**, `why_it_matters` is **Why I'm asking**, `options` (plus "do nothing for now") are **Options**, `ba_recommendation` is **My recommendation**. Serial, not batched: an early answer often dissolves a later question.
3. HALT. Do not answer on the owner's behalf; "your call" is their cheap path, not yours.
4. On the answer, write that entry's `resolution` (`answer`, `answered_by: "owner"`, or `"ba_default"` if they deferred to the recommendation, and `at`) and run the gate again.
5. Once it exits 0 after any owner answer, **re-dispatch BA** to fold the resolutions into `requirements`, `acceptance_criteria`, `out_of_scope` and the tier, keeping `open_questions` intact. Do NOT edit the spec yourself: BA owns scope.

Route by tier:
- `risk_tier: "trivial"` (or legacy `trivial: true`): skip Phase 2-lite and Phase 2, go directly to Phase 3.
- `risk_tier: "standard"`: run **Phase 2-lite** (constraint injection, below), then Phase 3.
- `risk_tier: "architectural"`: run **Phase 2** (the reviewer fan-out), then Phase 2.5, then Phase 3.

---
