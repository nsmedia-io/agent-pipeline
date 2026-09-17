## Phase 2-lite: Constraint injection (standard tier, no subagents)

**Checkpoint first:** set `current_phase: "2-constraints"` and commit `status.json`.

At the standard tier the spec has, by definition, no schema/access-control/security/compliance dimension, so a pre-code reviewer fan-out mostly re-states standing rules at the cost of three context spin-ups and a lossy notes handoff. Instead, the orchestrator extracts each specialist's **standing constraint checklist** from its agent definition and hands the full text to the Phase 3 Dev thread. The checklists live in the agent files (single source of truth, marker-delimited); this step copies, never paraphrases: `node "${CLAUDE_PLUGIN_ROOT}/scripts/extract-constraints.mjs" --out "$ARTIFACT_DIR/constraints.md"`.

`constraints.md` is a pipeline artifact: Dev treats it as Phase-2-equivalent hard constraints, and the Phase 4 panel reads it to verify the diff honored them. Exit 2 names every role whose markers are missing: HALT and surface that to the owner; do not dispatch Phase 3. Any other exit but 0: halt and show the owner the output. There is no verdict gate here, nothing to approve yet; the gate that used to live in Phase 2 moves to Phase 4, where SecOps reviews the actual diff with veto power.

Update `status.json` with `current_phase: "2-constraints-complete"` and proceed to Phase 3.

---
