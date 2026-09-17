**Every loop back to BA after Phase 2 has returned is a spec revision, and it is counted before BA is dispatched.** That covers a Phase 2 `VETO` or `REQUEST_CHANGES` below, a scope ruling that changes requirements, and a Phase 4 `VETO` sent back to BA. Run `node "${CLAUDE_PLUGIN_ROOT}/scripts/round-budget.mjs" enter spec-revision --status "$PIPELINE_BASE/<issue>/status.json"` first. Exit 0 records the revision in `spec_revisions`; commit the checkpoint and loop back. Exit 2 means this would be revision 3 or later with no `owner_overrides` entry covering it: do NOT dispatch BA. Bring the owner the decision block the command printed (ship with deferrals, split, or stop), in full voice mode, and only if the owner chooses to keep going record their answer as an `owner_overrides` entry (`{"kind": "spec-revision", "up_to": <n>, "at": "<iso>", "reason": "<their reason>"}`) and run the command again.

### Convergence budget (the pipeline's own failure mode)

**This pipeline is much better at finding defects than at converging on a fix, and nothing in it
notices when that is happening.** Every gate here loops back on a finding, and every loop-back is
individually justified, so a spec can round-trip indefinitely while each round looks like the gate
working. Measured on one issue: three Phase 2 rounds, four spec revisions, an 86KB spec that grew to
95KB while its substance HALVED, two connection failures mid-write that each lost a full round's
reasoning, and zero lines of code. Every blocker in every round was real. That is the point — real
findings are not evidence that continuing is correct.

Two budgets, both COUNTED IN CODE, both fail-loud. They were prose for several releases and nothing
counted: measured on one consumer, a single tooling issue then ran 21 spec revisions and 8 Phase 4
panel rounds. `scripts/round-budget.mjs` reads the counters in `status.json`, refuses (exit 2) a
round past the budget, and prints a plain-language owner decision block. Its `checkRoundBudget`
function is exported so a phase-entry gate can call it too.

**1. Spec-revision budget.** Every loop back to BA after Phase 2 has returned is a spec revision
(Phase 2's gate says where it is counted). Two are allowed at every cost class. The third needs
the owner: `round-budget.mjs enter spec-revision` refuses it and prints **ship with deferrals /
split / stop**. The same evidence that justifies each revision justifies the split: if revision
two's findings are in a different part of the spec from revision one's, the spec is too big to
review as a unit.

**2. Fix-round budget (the one that binds where the cost actually is).** Every Phase 4
`REQUEST_CHANGES` or `REQUEST_REFACTOR` that loops back to Dev is a fix round, counted in
`fix_rounds` by `round-budget.mjs enter fix-round` before Dev is dispatched. Budget: `tooling` 1,
`product` 2, `product-money` 2. Measured on this repo's own records, phase 4 is the largest single
consumer of active pipeline time -- 29% across seven runs, against 24% for implementation -- and
every one of those rounds was individually justified by a real finding.

**Past either budget, the pipeline stops and asks; it does not decide.** Bring the owner the
decision block the command printed, in full voice mode, with your recommendation filled in. The
owner's "keep going" is recorded as an `owner_overrides` entry (`kind`, `up_to`, `at`, `reason`),
and only that entry lets the command say yes to the round it covers. Never write one on your own
judgement.

**Count introduced defects, not rounds, wherever you can.** A round that closes its target
cleanly is the gate working. A round whose fix CREATES a new merge_class defect is evidence that
the design shape is wrong rather than the code, and it is the fact to put in the owner's decision.

**Read `review_rounds_observed`, never `review_rounds` alone.** The hand-maintained counter
disagreed with the events on 5 of 7 committed records, in both directions, and was reliable only
on single-round runs -- exactly the runs no budget binds on. `telemetry()` reports the observed
count and a signed `review_rounds_recorded_delta`; a non-zero delta means the counter is wrong
and the budget would bind on a number nobody measured.

**3. Spec size tripwire.** When a spec crosses **10 requirements or 12 acceptance criteria**, BA must
either justify the size in `spec.json`'s **`size_justification`** field or propose a split. **At
cost_class `tooling` this is a refusal, not a warning:** `round-budget.mjs spec-size` exits 2 on a
tooling spec over 12 acceptance criteria with no `size_justification`, and the orchestrator returns
it to BA (Phase 1 above). The rest of this item describes the other cost classes. These are
not hard limits; they are the point at which "is this one issue?" stops being rhetorical. On the run
above, BA recommended a three-way split the first time it was asked directly, and was right, but
nothing had asked. **Something asks now:** `scripts/validate-pipeline-artifact.mjs` prints a WARNING
on stderr at SubagentStop when EITHER count is crossed and `size_justification` is absent or blank,
and it names BOTH counts whichever one crossed, so a reader is never left wondering whether the
other is fine or simply unmentioned. It never blocks, and that is deliberate: the counts are a smell rather than a
defect, the remedy is a decision only BA and the owner can take, and a refusal on a heuristic is the
shape that gets a control switched off. The tripwire's job is to be asked, not to refuse.

**Write the artifact before composing the reply.** The Phase 4 reviewer preamble already says this.
It applies to BA too, and for a sharper reason: BA's artifact is the largest single write in the
pipeline, and a connection drop between "I have concluded" and "I have written it down" costs the
entire round. When a spec exceeds ~30KB, write it as several smaller files (a delta against the
prior revision, not a rewrite) and let the orchestrator merge them.

### Match the mechanism to the reversibility, not to the tier table

The architectural tier is the right shape for a change whose failure is unrecoverable — data loss,
credential exposure, a wrong number reaching a customer. It is the wrong shape for most of a backlog.

Two habits carry most of the value at any tier and cost almost nothing: **a second independent reader
on anything customer-facing**, and **run the control before believing the zero**. Reach for the full
apparatus when the downside is permanent; reach for those two when it is not.

A corollary worth stating because it was learned the expensive way: when a review finds a one-file,
obviously-correct safety defect, **fix it immediately rather than routing it through the pipeline.**
The incident that taught it is in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Fix it immediately").

---

## Loop-back triggers

The flow is adaptive: a later phase can invalidate an earlier decision. When one of these fires, return to the owning phase and re-run forward from there. Do not carry a known-wrong assumption downstream.

| Trigger | Surfaced in | Loop back to | Then |
|---|---|---|---|
| SecOps `VETO` (valid `veto_ground` AND a blocking concern) | Phase 2 or Phase 4 | BA (spec redesign), after `round-budget.mjs enter spec-revision` exits 0 | Re-run Phase 2 (architectural) or Phase 2-lite (standard), then forward; on exit 2, the owner decides |
| Any `REQUEST_CHANGES` | Phase 2 | BA (spec rework), after `round-budget.mjs enter spec-revision` exits 0 | Re-run Phase 2; on exit 2, the owner decides |
| Mis-tier tripwire: the MECHANICAL data-layer path predicate (migration, declarative schema, SQL data-access policy source) at the gate, or Dev's self-reported constraint tripwire (auth, crypto, webhook verification, a shared contract's shape) in Phase 3 | Phase 3 (Dev self-halt) or the Phase 3 to 4 gate | BA (re-tier to architectural) | Run the skipped phases (Phase 2 fan-out, Phase 2.5 if design-shaped) against the existing worktree, then re-enter the gate |
| Owner answers a blocking open question | Phase 1 (gate) | Phase 1 (BA only) | Re-dispatch BA to fold every `resolution` into requirements, acceptance criteria, out-of-scope, and the tier. The orchestrator never edits the spec itself; `open_questions` and its resolutions stay in the artifact as the record |
| SecOps `VETO` (on a valid `veto_ground` carrying a blocking concern), or a fix round past the budget the owner chose | Phase 4 | Phase 2.5 (judge only) | Re-open the design decision: re-dispatch the JUDGE with the veto or the accumulated fix-round findings and have it rule on whether the chosen approach still wins over the runner-up in `rejected_alternatives`. Keep the grafts that still apply; the sketches stand and are NOT re-run. Runs BEFORE the next implementation attempt is authorised |
| Owner picks the runner-up (or a variant) at design-lock | Phase 2.5 (owner answer) | Phase 2.5 (judge only) | Re-dispatch the JUDGE to re-materialize `design.json` around the chosen approach, keeping the grafts that still apply; the sketches stand and are NOT re-run. Record `owner_decision.resolution`, then forward to Phase 3 |
| Scope drift / wrong spec assumption | Phase 3 | BA (ruling) | If requirements/acceptance criteria change materially: architectural re-runs affected Phase 2 reviewer(s) then Phase 3 from 3a (QA re-authors tests); standard re-extracts constraints then re-dispatches the single Dev thread |
| Live-verification suite skipped, not recorded (data-migration / security-sensitive change) | Phase 3 to 4 gate | Phase 3 (Dev/QA) | Produce a recorded local pass against a real backing service, then re-run the gate |
| `REQUEST_REFACTOR` with `blocks_merge` (testability) | Phase 4 (QA) | Dev implementation step (3b at architectural; the single thread at standard), after `round-budget.mjs enter fix-round` exits 0 | The existing test contract stands; Dev refactors to keep it green. Re-run Phase 4 as a delta re-review (roles holding open blocker ids, plus merge-class-surface-touched roles). On exit 2, the owner decides |
| Any `REQUEST_CHANGES` with `blocks_merge` (a BLOCKING concern under materiality) | Phase 4 | Dev implementation step, after `round-budget.mjs enter fix-round` exits 0 (budget: tooling 1, product 2, product-money 2) | Delta re-review: the roles holding open blocker ids plus any role whose merge-class surface the fix touched (SecOps on security paths, and on data-layer paths except at tooling; QA on test files); additively merge so standing approvals hold; `panel_roles` unchanged. On exit 2, the owner decides |
| `APPROVE_WITH_NOTES` (notes) | Phase 4 | Orchestrator, same turn | Apply the `suggested_patch` notes, write the rest onto the issue's one deferral checklist (`deferral.mjs checklist`), merge |

A loop-back is not a failure; it is the gate doing its job. Record each one as an event in `status.json` so the audit trail shows where the assumption broke. The compliance and safety gates (SecOps veto, DBA migration review, access-control rationale) are never bypassed to "save" a loop.

