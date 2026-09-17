## Phase 2: Technical Review (architectural tier, parallel)

**Checkpoint first:** set `current_phase: "2-review"` and commit `status.json` BEFORE dispatching the parallel reviewers, so an interruption mid-review resumes into Phase 2.

This phase runs ONLY when `spec.risk_tier === "architectural"`. DBA, DevOps, and SecOps review **independent dimensions** of the same spec: schema/migration safety, infrastructure/deploy impact, and security/compliance. None needs another's output to do its job, so they run concurrently. This is the read-heavy, low-coupling work where fan-out is a pure win, and at this tier the spec-level review earns its cost: migrations, access controls, and security postures are cheaper to fix before code exists.

**Conditional fourth reviewer: Design (frontend-scoped specs only).** When the spec is frontend-scoped (`spec.impacted_domains` includes `frontend`), add a fourth parallel Agent call to the `design` reviewer in the SAME message as the three above. It reviews the design-system reach, token coverage, accessibility surface, and copy tone, and writes a bare `review.design_review.json` shard. Do NOT dispatch Design when the spec is not frontend-scoped; it is a conditional lens, not a standing reviewer. The shard key is `design_review` (never `design`, which is the Phase 2.5 bake-off artifact `design.json`).

**Send a single message with three parallel Agent tool calls.** Each reviewer writes a **shard file** (`review.<agent>.json`), never `review.json` directly. Concurrent writes to one shared file would clobber each other; shards plus a post-fan-out merge keep the speedup without lost updates.

Two constraints go into every Phase 2 prompt verbatim:
- **Absolute `ARTIFACT_DIR`.** Substitute the fully expanded absolute path (`$PIPELINE_BASE/<issue>`). Reviewers read and write only there.
- **Read against fresh `origin/main`.** You fetched it in Phase 0. Config, workflows, and migrations must be read at the `origin/main` ref (`git show origin/main:<path>`), not the local working tree. The base checkout can be many commits behind; reviewing stale config produces false "this gate/file does not exist" findings.

```
Agent({
  subagent_type: "dba",
  description: "DBA Phase 2 review for #<issue>",
  prompt: """
You are invoked by the /pipeline orchestrator for Phase 2 review (running in parallel with DevOps and SecOps).

Artifact directory (absolute): <ARTIFACT_DIR>. Read and write artifacts only at this absolute path; do not resolve .pipeline from your own cwd.
Review against fresh origin/main: read schema/migration/config files at the origin/main ref (e.g. `git show origin/main:migrations/...`  # CUSTOMIZE: your migrations dir), not the local working tree, which may be stale. Confirm the highest migration number against origin/main before claiming a collision or gap.

Read: <ARTIFACT_DIR>/spec.json

Do your review per your agent definition. Write your block to <ARTIFACT_DIR>/review.dba.json as a BARE object matching the agentBlock shape (verdict, reviewed_at, concerns, notes at the top level). Do NOT wrap it under a "dba" key, do NOT add sibling keys, and do NOT write to review.json; the orchestrator merges shards. Return a one-line verdict plus blocker list if any.
  """
})
Agent({
  subagent_type: "devops",
  description: "DevOps Phase 2 review for #<issue>",
  prompt: """
You are invoked by the /pipeline orchestrator for Phase 2 review (running in parallel with DBA and SecOps).

Artifact directory (absolute): <ARTIFACT_DIR>. Read and write artifacts only at this absolute path; do not resolve .pipeline from your own cwd.
Review against fresh origin/main: read your infrastructure/deploy config, CI workflows, and deploy scripts at the origin/main ref (e.g. `git show origin/main:.github/workflows/ci.yml`), not the local working tree, which may be stale. A gate or file you cannot find locally may exist on the integration branch.

Read: <ARTIFACT_DIR>/spec.json

Do your review per your agent definition. Write your block to <ARTIFACT_DIR>/review.devops.json as a BARE agentBlock object (verdict at top level). Do NOT wrap it under a "devops" key, do NOT add sibling keys, and do NOT write to review.json; the orchestrator merges shards. Return a one-line verdict plus blocker list if any.
  """
})
Agent({
  subagent_type: "secops",
  description: "SecOps Phase 2 review for #<issue>",
  prompt: """
You are invoked by the /pipeline orchestrator for Phase 2 review (running in parallel with DBA and DevOps).

Artifact directory (absolute): <ARTIFACT_DIR>. Read and write artifacts only at this absolute path; do not resolve .pipeline from your own cwd.
Review against fresh origin/main: read auth/config/workflow files at the origin/main ref, not the local working tree, which may be stale.

Read: <ARTIFACT_DIR>/spec.json

Do your review per your agent definition, including compliance_flags and vulnerabilities. Write your block to <ARTIFACT_DIR>/review.secops.json as a BARE object (verdict at top level, alongside concerns, vulnerabilities, compliance_flags, notes). Do NOT wrap it under a "secops" key, do NOT add sibling keys, and do NOT write to review.json; the orchestrator merges shards. Your verdict may be APPROVE, APPROVE_WITH_NOTES, REQUEST_CHANGES, or VETO; a VETO carries veto_ground (one of the enumerated security surfaces in your contract) or it reads as REQUEST_CHANGES. Rate every concern (likelihood, reversibility, harm) per the materiality rule in ${CLAUDE_PLUGIN_ROOT}/evidence.md. Return a one-line verdict plus blocker list if any.
  """
})
```

When the spec is frontend-scoped, ALSO include this fourth call in the same message:

```
Agent({
  subagent_type: "design",
  description: "Design Phase 2 review for #<issue>",
  prompt: """
You are invoked by the /pipeline orchestrator for Phase 2 review (running in parallel with DBA, DevOps, and SecOps). You were dispatched because spec.impacted_domains includes frontend.

Artifact directory (absolute): <ARTIFACT_DIR>. Read and write artifacts only at this absolute path; do not resolve .pipeline from your own cwd.
Review against fresh origin/main: read your design-token source and components at the origin/main ref (e.g. `git show origin/main:<your design-token source>`  # CUSTOMIZE), not the local working tree, which may be stale.

Read: <ARTIFACT_DIR>/spec.json

Do your review per your agent definition. Write your block to <ARTIFACT_DIR>/review.design_review.json as a BARE object (verdict at top level, alongside concerns, advisory_notes, token_lint, axe, notes). Do NOT wrap it under a "design_review" key, do NOT add sibling keys, and do NOT write to review.json; the orchestrator merges shards. Your verdict may be APPROVE, APPROVE_WITH_NOTES, or REQUEST_CHANGES (never VETO; only a token_lint or axe failure may back a REQUEST_CHANGES, taste-only feedback is advisory). Return a one-line verdict plus blocker list if any.
  """
})
```

After all reviewers return, **merge the shards into `review.json`**. The merge **defensively unwraps**: the contract is a bare shard (`verdict` at top level), but if an agent still wraps its block under its role key (`{"dba": {...}}`) or buries it under a stray sibling, the `unwrap` function recovers the inner block so a verdict can never silently read as null and pass a gate it should have failed. A correctly-bare shard passes through untouched.

Orchestrator note: run this and the Phase 4 shard-merge loop via `bash -c '...'`. The session shell may be zsh, which does not word-split an unquoted `$PANEL_ROLES` (the whole string becomes one word and the loop iterates zero roles); `bash -c` guarantees POSIX word-splitting. Avoid `status` and `path` as shell variable names in these snippets (zsh treats them specially).

```bash
jq -n \
  --slurpfile dba "$ARTIFACT_DIR/review.dba.json" \
  --slurpfile dvo "$ARTIFACT_DIR/review.devops.json" \
  --slurpfile sec "$ARTIFACT_DIR/review.secops.json" \
  '
  def unwrap($k): if type=="object" and has("verdict") then .
                  elif type=="object" then (.[$k] // .)
                  else . end;
  {
    dba:    ($dba[0] | unwrap("dba")),
    devops: ($dvo[0] | unwrap("devops")),
    secops: ($sec[0] | unwrap("secops"))
  }' \
  > "$ARTIFACT_DIR/review.json"
rm -f "$ARTIFACT_DIR"/review.dba.json "$ARTIFACT_DIR"/review.devops.json "$ARTIFACT_DIR"/review.secops.json
```

When the Design reviewer was dispatched (frontend-scoped spec), fold its shard into the same `review.json` under the `design_review` key after the merge above, with the same `unwrap` defense:

```bash
if [ -f "$ARTIFACT_DIR/review.design_review.json" ]; then
  tmp=$(mktemp) && jq \
    --slurpfile dsg "$ARTIFACT_DIR/review.design_review.json" '
    def unwrap($k): if type=="object" and has("verdict") then .
                    elif type=="object" then (.[$k] // .)
                    else . end;
    .design_review = ($dsg[0] | unwrap("design_review"))' \
    "$ARTIFACT_DIR/review.json" > "$tmp" && mv "$tmp" "$ARTIFACT_DIR/review.json"
  rm -f "$ARTIFACT_DIR/review.design_review.json"
fi
```

A Design `REQUEST_CHANGES` is gated exactly like DBA/DevOps (case 2 below); a Design `VETO` is impossible (only SecOps holds the veto), so the `design_review` verdict only ever reads as APPROVE, APPROVE_WITH_NOTES, or REQUEST_CHANGES.

Then validate `review.json` against `${CLAUDE_PLUGIN_ROOT}/schemas/review.schema.json` via `${CLAUDE_PLUGIN_ROOT}/scripts/validate-pipeline-artifact.mjs`. The merged shape (keys `dba`, `devops`, `secops`) is identical to the old sequential output, so every downstream reader is unaffected. A merged block that comes out `null` (a reviewer that never wrote, or wrote unrecoverable garbage) is a halt condition, not a pass: a `null` verdict matches neither `APPROVE` nor `APPROVE_WITH_NOTES`, so the gate below will not advance on it.

Before the verdict gate below loops back to BA, read `${CLAUDE_PLUGIN_ROOT}/orchestrator/loop-backs.md` now: the spec-revision count that runs before any BA dispatch, and what its exit 2 obliges, are stated there.
Apply the verdict gate, most-blocking first:

1. **SecOps `VETO`** (on a named `veto_ground`; a `VETO` without one is case 2, a blocking concern, not a redesign):
   1. Update `status.json` with `current_phase: "1-ba-rework-required"`, `veto_reason: <text>`, `veto_ground: <ground>`.
   2. Return to the owner in **full voice mode** (see "Human-facing responses"): a veto is an acceptance moment the owner has to understand and act on, so it gets the complete `voice.md` shape, not the one-liner. The line below is the factual spine to build that report around, not the whole message:
      ```
      **[Orchestrator]:** SecOps VETO. Spec returns to BA for rework. Reason: <text>. Remediation: <text>.
      ```
   3. **Re-open the design decision before authorising another implementation attempt.** A veto
      says the chosen approach failed a compliance or safety property under measurement, and
      every gate after Phase 2.5 asks "is this fix correct", never "is this the right fix". The
      runner-up sketch is sitting in `design.json` under `rejected_alternatives` with the reason
      it lost, and that reason was written BEFORE the evidence this run has now accumulated. So
      re-dispatch the bake-off JUDGE with the veto, the fix rounds so far, and the accumulated
      findings, and have it rule on whether the chosen approach still wins. This is the same
      re-materialization the owner-picks-the-runner-up loop-back already performs (keep the
      grafts that still apply; the sketches stand and are NOT re-run), reached by a different
      trigger. It is cheap, it happens once, and the alternative is what it was measured
      replacing: three consecutive rounds hardening an approach whose losing rival had already
      been called vindicated by the judge, with nowhere for that evidence to go.

      The SAME re-decision fires when the owner chooses a second fix round even without a veto
      -- see the fix-round budget in the convergence section. A second remediation round on
      one issue is the cheapest honest moment to ask whether the design, rather than the code,
      is what is wrong.
   4. Halt. Await `/pipeline --resume <issue>` after BA addresses the veto.
2. **Any `REQUEST_CHANGES`** (from any of the three): halt Phase 2, collect every blocker into one summary, return to the owner, and loop back to BA for spec rework. Do not advance to Phase 3. **On the re-run, Phase 2 is a DELTA, not a fresh fan-out:** re-dispatch the reviewer(s) that returned `REQUEST_CHANGES`, plus any reviewer whose lens the rework touched (a new data-layer requirement re-seats DBA, a new deploy or binding requirement re-seats DevOps, a new caregiver-facing string re-seats Design; SecOps is re-seated by any rework that adds a logging, retention, auth, or copy requirement). The standing `APPROVE` / `APPROVE_WITH_NOTES` blocks of the untouched reviewers carry forward into `review.json` unchanged, and the round is recorded in `status.json` (`phase2_round`, plus a `2-review` event whose note names the re-dispatched subset). Keep the prior round's merged file as `review.round1.json` beside it so the audit trail shows both. "Re-run Phase 2" read literally is four reviewer spin-ups for a rework one of them asked for, and that is what the round budget below is counting.
3. **All `APPROVE` or `APPROVE_WITH_NOTES`**: update `status.json` with `current_phase: "2-review-complete"` and proceed to Phase 2.5 (this phase only runs at the architectural tier, which always continues into the bake-off). Notes carry forward as constraints in `review.json` for Dev to honor.

---
