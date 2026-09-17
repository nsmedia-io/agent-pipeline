## Phase 2.5: Design Bake-off (architectural tier only)

**Checkpoint first:** `checkpoint.mjs enter 2.5-design --exit-verdict <verdict> --commit` (`status-record.md`; it writes `current_phase: "2.5-design"`) BEFORE dispatching the design sketches.

This phase runs ONLY when `spec.risk_tier === "architectural"`. For trivial and standard tiers it is SKIPPED; proceed straight to Phase 3.

For an architectural-tier spec, dispatch a competitive design bake-off rather than letting Phase 3 improvise an approach:

1. **Two design sketches with OPPOSING ASSIGNED STANCES, in parallel.** Send a single message with two Agent calls, each asked to sketch an end-to-end approach (data model, contract changes, control flow, failure modes, migration shape) against `spec.json`, `review.json`, and `map.json`. They do not see each other's sketch. **Separate contexts alone do not make them independent:** two samples of one model against one identical prompt correlate, and a bake-off between two versions of the same idea is a bake-off in name only. Assign each sketch a named stance and put it in the prompt verbatim, for exactly the reason the Phase 4 panel assigns non-overlapping lenses:
   - **Sketch A, smallest blast radius.** The least change that satisfies every acceptance criterion. Maximum reuse of existing contracts; additive, backward-compatible shapes preferred; a migration only when nothing else works. Accept coupling you would rather not have. Optimize for: this is cheap to revert.
   - **Sketch B, cleanest seam.** The right abstraction for the next three changes in this area, even when it costs a wider migration or a contract change. Accept a larger diff and a longer review. Optimize for: the next person to change this does not have to fight it.

   Two poles, not three. The pragmatic middle is what the JUDGE produces by grafting, so pre-generating it as a third sketch spends a context to pre-empt the step whose whole job is to make that call. Give BOTH sketch dispatches an explicit `subagent_type: "dev"` (the architectural-approach reasoning role) and resolve their model from the routing table: `node "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-model.mjs" dev <risk_tier> 2.5 --site design-sketch` (sonnet today). The `--site` argument is not decoration: the sketches and the judge below are BOTH `dev` in phase 2.5 and carry DIFFERENT models, so the site is the only thing that tells the two dispatches apart. The explicit `subagent_type` is what stops these dispatches from inheriting the session model (which can be a non-opus/non-sonnet session default); they must never inherit the session default.
2. **One judge, after both return.** Dispatch a judge that reads both sketches, synthesizes the WINNER, and grafts the best of the runner-up where it strengthens the winner. Give the judge an explicit `subagent_type: "dev"` and resolve its model with `node "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-model.mjs" dev <risk_tier> 2.5 --site bakeoff-judge` (opus today: the synthesis is the high-reasoning step). Like the sketches, its `subagent_type` is explicit so it never inherits the session model.

   The judge ALSO rules on whether the two stances produced a **material divergence**: a difference the OWNER would plausibly answer differently from the way the judge did, on cost, timeline, reversibility, or product direction. It records that ruling as the `owner_decision` block in `design.json`. Two sketches that converged on substantially the same approach carry `required: false`: there is no call to surface, and manufacturing one trains the owner to rubber-stamp the block that matters.

The judge writes a `design.json` artifact at `ARTIFACT_DIR` with the chosen approach, the rationale, the rejected alternatives (and why), the residual risks, and the `owner_decision` block. Phase 3 Dev then implements `design.json`, not just the spec, so the implementation follows a vetted design rather than the first approach that compiles.

### Design-lock: the owner's call when the stances materially diverged

The one happy-path decision the pipeline does not make for itself: the approach constrains every later phase, and roadmap and urgency are inputs the judge cannot read from the repo. Run `node "${CLAUDE_PLUGIN_ROOT}/scripts/owner-gate.mjs" design-lock --design "$ARTIFACT_DIR/design.json" --status "$PIPELINE_BASE/<issue>/status.json"` every time, including on a resumed or seeded `design.json`:

- **Exit 0**: proceed to Phase 3.
- **Exit 3**: re-dispatch the judge with what the script printed. Do not fill in the block yourself: you did not read the sketches.
- **Any other exit**: halt and show the owner the output.
- **Exit 2**:
  1. Update `status.json` with `current_phase: "2.5-design-owner-decision"` and commit.
  2. Return to the owner in **full voice mode**, ending with the decision block from `${CLAUDE_PLUGIN_ROOT}/voice.md`. Options A and B are the two sketches as rendered, in plain language, never the stance labels: what each buys, costs and forecloses. The judge's winner is **My recommendation**. Fill Reversibility from the migration and contract shape of each option, and say this is the last cheap moment to change the answer.
  3. HALT and await the owner. Do NOT dispatch Phase 3 on the recommendation while the question is open: a decision block the pipeline answers for itself is a progress tick wearing a costume.
  4. On the answer, write `owner_decision.resolution` (`chosen`, the owner's `reasoning`, `resolved_at`). If they picked the other option or a variant, re-dispatch the JUDGE (not the sketches) to re-materialize `design.json` around it. Then run the gate again.

After `design.json` is written (and resolved, when a decision was required), update `status.json` with `current_phase: "2.5-design-complete"` and proceed to Phase 3.

---
