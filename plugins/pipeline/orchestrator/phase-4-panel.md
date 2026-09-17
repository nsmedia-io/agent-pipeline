## Phase 4: Peer Review Panel (parallel)

**Checkpoint first:** after the pre-Phase-4 gate passes, `checkpoint.mjs enter 4-review --exit-verdict <gate verdict> --commit` (`status-record.md`; it writes `current_phase: "4-review"`) BEFORE dispatching the panel.
In that SAME write the script clears `final_verdict` and `peer_review_verdict_counts` (#110), and counts the panel round in `review_rounds` (a re-checkpoint of the same round after an interruption is not a new one). Do not hand-edit either; `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Phase 4 checkpoint: the stale verdict") says why.

The panel reviews the finished diff, each agent through a distinct lens, while remote CI runs concurrently (CI-green is verified at merge, not required to enter the panel). This is the read-heavy, independent-perspective work where fan-out is a pure win, and where QA's adversarial test scrutiny lives: QA reviews the finished implementation with fresh eyes and renders the **binding independent test verdict**.

**Panel composition.** Resolve and record the panel with one call before dispatching (#164). The script runs git without a shell and prints one role per line, so no role list or path list passes through a shell variable:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/panel-roles.mjs" full --status "$PIPELINE_BASE/<issue>/status.json" \
  --worktree "<WORKTREE_PATH>" --artifact-dir "$ARTIFACT_DIR" --write > "$ARTIFACT_DIR/roles-to-merge.txt"
```

Read its exit status directly; never pipe the call, because a pipe discards it.

- **0**: status.json `panel_roles` holds the panel, and `roles-to-merge.txt` holds the same roles for the merge below.
- **21**: the same, and at least one role was seated because its surface probe could not be evaluated (git diff failed, the diff was empty, a predicate threw). The `PANEL-NOTE:` lines on stderr name each such seat and `--write` has already recorded them in status.json `flags`. Say them in the PR summary too: `panel_roles` alone cannot tell a seat earned by a match from one earned by indeterminacy. Dispatch the panel; fix the cause (usually a stale `${CLAUDE_PLUGIN_ROOT}` or a missing `origin/main`) separately.
- **1**: bad input (status.json unreadable, `risk_tier` absent or unknown, a missing argument). Halt, fix the record, run it again. **Any other exit** is a failure to run: halt, and do not dispatch from the file.

What it computes (the rules are in the script header and pinned by `tests/test-panel-roles.sh`): architectural seats `ba dba devops secops dev qa`; standard seats `ba dev qa secops` plus `dba` on a data-layer diff and `devops` on an infra diff; trivial seats `qa secops`; every tier adds `design_review` on a frontend diff and `art_director` when `visual-contract.json` exists. At cost_class `tooling`, whatever the tier, the panel is `qa secops` plus ONE specialist (the first of `devops`, `dba`, `design_review` a probe seats, else `dev`) for one round. SecOps sits on every full round. A trivial panel stays small because two tripwires re-tier a diff bigger than its tier: the MECHANICAL path tripwire above, which is a data-layer PATH predicate and covers migrations, declarative schema and SQL data-access policy sources but NOT auth and NOT authorization code, and Dev's self-reported CONSTRAINT tripwire, which is what covers a new auth surface, crypto or webhook verification. The predicates are the gates' own (`data-layer-surface.mjs`, `frontend-surface.mjs`; # CUSTOMIZE: `dataLayerGlobs`, `infraGlobs`, `frontendSurface` in pipeline.config.json), so detection and dispatch never diverge. An unevaluable probe seats because it cannot know the diff misses the surface: over-seating costs one reviewer's context, under-seating removes the lens the diff needed. The frontend probe's late arrival on that rule (#20) is in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Frontend probe").

Art Director seating: when `<ARTIFACT_DIR>/visual-contract.json` exists, read `${CLAUDE_PLUGIN_ROOT}/orchestrator/art-director-contract.md` now (Duty B is its panel seat, which the call above already resolved).

The call above (`--write`) has already recorded the panel in status.json `panel_roles`, so the merge, the rubric, and a `--resume` all agree on who was on the panel. The round counter, telemetry and the effective-config audit record were refreshed by the `enter 4-review` checkpoint above.

Both records are NUMBERS and glob strings only, and that is a rule rather than a habit: `status.json` is committed AND archived verbatim by the Librarian, so it must never carry an absolute filesystem path, a command string, or a credential. An absolute glob in a project config is recorded as the literal token `<absolute-glob-rejected>` rather than written through. The two migration sets are recorded separately (`migration_globs_tripwire`, `migration_globs_gate`) because they genuinely differ and an auditor who cannot tell which set was live for which control has learned nothing. When `design_review` is in the panel, dispatch the `design` reviewer with the shared Phase 4 preamble plus its lens line (it writes a bare `peer-review.design_review.json` shard), and fold that shard into `peer-review.json` under the `design_review` key in the merge loop with the same `unwrap` defense the other roles use. A standard-tier panel reviewer additionally verifies the diff against `<ARTIFACT_DIR>/constraints.md` (the injected constraints Dev was held to).

Phase 4 runs inside the implementation worktree (the reviewers need the issue branch checked out to diff it), so `ARTIFACT_DIR` is the same worktree path used in Phase 3: `<WORKTREE_PATH>/.pipeline/<issue>`. Before dispatching, refresh the flags digest into it so reviewers read it from the one absolute artifact dir:

```bash
cp "$PIPELINE_BASE/<issue>/status.json" "$ARTIFACT_DIR/status.json" 2>/dev/null || true
```

Dispatch via the **Workflow tool**, one `agent()` call per role in `panel_roles`, run inside a single `parallel([...])`. This is the one fan-out in this file that dispatches this way rather than through a single message of parallel Agent tool calls; see "Dispatch via Workflow" below for why this phase specifically, and only this phase, migrated. Each reviewer still writes a **shard file** (`peer-review.<agent>.json`), never `peer-review.json` directly, for the same lost-update reason as Phase 2, and the merge step below reads those files exactly as it always has -- the dispatch mechanism changed, the verdict contract did not. Every Phase 4 prompt is this **shared preamble**, then its lens-specific line (dispatch only the resolved panel), then a `RUN DATA` block that carries the absolute values; nothing is substituted into the preamble or the lens (see "Prompt assembly" below). The preamble is the marked block in `${CLAUDE_PLUGIN_ROOT}/orchestrator/phase-4-panel-preamble.md`, where the renderer reads it; you do not need to Read it to dispatch.


**Render the Workflow script; do not hand-write it (#157).** Every value in the panel script is computed by `scripts/render-panel.mjs`: the reviewed sha is `git rev-parse HEAD` of the worktree, the preamble is the marked block in `orchestrator/phase-4-panel-preamble.md` (sliced between `<!-- BEGIN PHASE4-PREAMBLE -->` and `<!-- END PHASE4-PREAMBLE -->`, placeholders left as written; their values come from each prompt's RUN DATA block), the lens per role comes from `scripts/panel-lenses.json` (the ONE lens table; there is no second copy in this file), and model and effort come from the two dispatch resolvers for `(role, <risk_tier>, 4, panel-lens, workflow)`: for the two lenses that carry a model row the renderer resolves exactly what a hand-written dispatch was told to, `dispatch-model.mjs ba <risk_tier> 4 --site panel-lens` and `dispatch-model.mjs dev <risk_tier> 4 --site panel-lens` (sonnet today), emitting `model:` only when the resolver printed one token, and it resolves `effort` for every role with `--surface workflow`. Every string is emitted through `JSON.stringify`, so no quoting class can break the script.

```bash
# Full round. panel-roles.mjs recorded panel_roles in status.json above; the renderer reads it from there.
node "${CLAUDE_PLUGIN_ROOT}/scripts/render-panel.mjs" \
  --status "$PIPELINE_BASE/<issue>/status.json" --worktree "<WORKTREE_PATH>" --check \
  --out "$ARTIFACT_DIR/panel.workflow.mjs"
```

Then pass the file's contents verbatim as the Workflow tool's `script`. `--check` parses the rendered script with `node --check` under the runtime's async wrapper and exits non-zero on a parse error, so the failure surfaces here and not as a Workflow tool rejection. The rendered file is a per-issue artifact (gitignored with the rest); the sha it carries in its header comment is the sha the panel reviewed, and the merge step below reads shards from disk exactly as before, so the dispatch mechanism changed and the verdict contract did not. The shape the renderer emits, for readers of this file (one `agent()` per role, the lens and that role's RUN DATA appended to the shared preamble, `agentType` namespaced, `model` present only when the resolver printed one token, `effort` always present on the workflow surface, `label` per role):

```
export const meta = { name: 'phase4-panel-<issue>', description: '...', phases: [{ title: 'Panel' }] }
phase('Panel')
const PREAMBLE = "<the marked block, placeholders intact>"
const results = await parallel([
  () => agent(PREAMBLE + "<lens for ba>RUN DATA ...", { agentType: 'pipeline:ba', model: 'sonnet', effort: 'medium', label: 'ba-panel' }),
  () => agent(PREAMBLE + "<lens for secops>RUN DATA ...", { agentType: 'pipeline:secops', effort: 'high', label: 'secops-panel' }),
  // ... one per role in panel_roles (design_review and art_director only when seated)
])
return { returns: results }
```

**The Workflow return value is a convenience, never the verdict source.** `results` above is discarded by the orchestrator once the call returns; nothing reads a verdict out of it. The merge step below reads `peer-review.<role>.json` off disk exactly as it did before this migration, because that file, not an in-memory return value, is what `merge-peer-review.mjs` validates and what the `SubagentStop` hook gates on. `agent()` returns `null` when a subagent dies or is skipped, and a `null` entry in `results` is not itself a failure signal to act on: the missing shard IS the signal, and the merge step below already halts on it (`MISSING SHARD`, exit 2), the identical path a stalled or refused Agent-tool dispatch takes today. Do not add a second check that reads `results` for a verdict; that would be a second derivation of a decision the shard-file gate already makes, and the two could disagree.

**Prompt assembly: static first, run data last (C2).** The renderer does not substitute `<issue>`, `<WORKTREE_PATH>`, `<HEAD_SHA>`, `<REVIEWED_SHA>`, `<ARTIFACT_DIR>`, `<FIRST_ROUND_HEAD>` or `${CLAUDE_PLUGIN_ROOT}` into the preamble or the lens. Each prompt is the static preamble (plus the delta paragraph on a delta round), then the role's lens, then a `RUN DATA` block that binds those names for this dispatch, the delta roles, the path of `peer-review.json` and the role's open blockers as one TOON table. The static part carries no issue number, sha or path, so it is byte-identical for every role of a panel and across issues on one plugin version, and a prompt cache can reuse it; `test-render-panel.sh` pins that. Do not put a per-run value back into the preamble or a lens. TOON (the encoder is `toon.mjs`, beside the renderer) is used for prompt text only: agents still read and write JSON artifacts, and no schema changed. `prompt-weight.mjs` reports the bytes and estimated tokens of the command files, the orchestrator phase files, what a typical, an architectural and a worst-case run loads, the agent definitions, and a rendered panel for a fixture issue.

### Dispatch via Workflow (why THIS phase, and why only this phase, today)

Phase 4 is the one fan-out in this file dispatched through the `Workflow` tool rather than a single message of parallel Agent tool calls, for a reason specific to this phase, not a general preference: it is the one place `dispatch-effort.mjs`'s `--surface workflow` table has a live consumer (below), and Phase 4 is purely mechanical fan-out-then-merge with no mid-run owner input, which is exactly the shape the `Workflow` tool supports. The Phase 2 reviewer fan-out, the Phase 2.5 sketch pair, and the Phase 0.5 architectural map stay on the Agent tool: nothing about them changes here, and this section is not an invitation to migrate them on the same reasoning. Do that only with its own evaluation; effort has no table row worth spending at those sites today (see "Dispatch effort routing" below), so there is no equivalent payoff, and each would need its own review of whatever mid-run interaction, if any, it carries.

Invoking `Workflow` here is authorized under its own gating rule ("the user invoked a skill or slash command whose instructions tell you to call Workflow"): running `/pipeline` on an architectural-tier ask IS that invocation, so no additional per-run opt-in is needed for this one call.

Both questions this migration was gated on are resolved (#101): q4, the SecOps veto stays fail-closed, by construction; q6, the runtime honors a `SubagentStop` block on a Workflow-dispatched agent, confirmed empirically. The record is in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Dispatch via Workflow").

The Design row appears in the PR summary table and the merge loop only when `design_review` is in `panel_roles` (frontend-touching diffs); otherwise it is listed among the not-on-panel lenses, exactly like the surface-trimmed DBA/DevOps.

After all dispatched reviewers return, **merge the shards into `peer-review.json`** via `${CLAUDE_PLUGIN_ROOT}/scripts/merge-peer-review.mjs`, which folds each named role's bare shard into the target file with the same `unwrap` defense as Phase 2 (a wrapped or sibling-buried shard recovers its verdict instead of nulling out). The merge is ADDITIVE: it overwrites only the roles named on THIS invocation and preserves every other role already in the file. That is what makes a delta re-review round (below) safe, and it is the SAME script the manual `/phase peer-review` re-run calls, so the auto and manual paths cannot diverge. On a FULL round, start from a clean file so no stale shard survives; on a delta round, do NOT reset it (that is the whole point). The loops read `roles-to-merge.txt` one line at a time, which bash and zsh do alike; avoid `status` and `path` as shell variable names here (zsh treats them specially).

```bash
# Full round: reset, then fold every dispatched role. roles-to-merge.txt is panel-roles.mjs stdout.
rm -f "$ARTIFACT_DIR/peer-review.json"
ARGS=()
while IFS= read -r role; do
  [ -n "$role" ] || continue
  SHARD="$ARTIFACT_DIR/peer-review.$role.json"
  # The recovery path a reviewer whose primary write was refused is told to use. Read HERE,
  # before the merge decides anything: a fallback nobody reads is a lost review.
  [ -f "$SHARD" ] || SHARD="$ARTIFACT_DIR/fallback-shards/peer-review.$role.json"
  if [ ! -f "$SHARD" ]; then echo "MISSING SHARD: $role" >&2; fi   # missing shard = halt (script exits 2)
  ARGS+=("$role=$SHARD")
done < "$ARTIFACT_DIR/roles-to-merge.txt"
node "${CLAUDE_PLUGIN_ROOT}/scripts/merge-peer-review.mjs" --status "$PIPELINE_BASE/<issue>/status.json" "$ARTIFACT_DIR/peer-review.json" "${ARGS[@]}"
while IFS= read -r role; do rm -f "$ARTIFACT_DIR/peer-review.$role.json"; done < "$ARTIFACT_DIR/roles-to-merge.txt"
```

Recoverability is bought by making the fallback a path the merge actually READS, never by making a missing shard non-fatal: a lost VETO must never become a silent APPROVE. A dispatched role whose block is absent or survives as `null` (an agent that never wrote, or wrote unrecoverable garbage) carries no verdict, so the rubric below cannot read it as `APPROVE`; the script exits non-zero on a missing shard, and a recovered-but-null block (a shard present on disk that yields no verdict after unwrap) is treated as a missing review and HALTs without writing a partial merge. A role that was never on the panel (trimmed at standard/trivial tier) is simply absent from `peer-review.json`; that is not a missing review.

