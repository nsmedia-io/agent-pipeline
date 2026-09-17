## Phase 4: Peer Review Panel (parallel)

**Checkpoint first:** after the pre-Phase-4 gate passes, set `current_phase: "4-review"` and commit `status.json` BEFORE dispatching the panel.

**In that SAME write, clear `final_verdict` and `peer_review_verdict_counts` (#110).** Set both to `null`; do not leave the previous round's values attached and do not split this across two commits. The rule is keyed on the WRITE that enters `4-review`, not on which round it is, so it costs nothing on round one (there is nothing to clear) and is the whole fix on a delta round. Without it, a `REQUEST_CHANGES` or `REQUEST_REFACTOR` re-entry sits at a guarded phase for the entire remediation window while still carrying the verdict of the round it is remediating, and `final_verdict` degrades from "this run concluded" to "this run concluded at some point in its history". (The committed record that showed this state is cited in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md`, "Phase 4 checkpoint: the stale verdict".) Every control that reads `final_verdict` as a conclusion -- `scripts/run-candidates.mjs`'s `concluded` term, and therefore the Stop-hook phase-entry guard and the PreToolUse commit-hygiene gate -- is blind for exactly that window, which per this repo's own telemetry is where Phase 4 spends the plurality of its active time. `peer_review_verdict_counts` is cleared with it because it is derived from the same panel result; a count left behind describes a panel that has been superseded.

Committed records written before this rule are NOT migrated: `.pipeline/*/status.json` history is the audit trail of what the orchestrator actually wrote, and the record above is the evidence this defect existed. Nothing reads those historical blobs under the new convention.

The panel reviews the finished diff, each agent through a distinct lens, while remote CI runs concurrently (CI-green is verified at merge, not required to enter the panel). This is the read-heavy, independent-perspective work where fan-out is a pure win, and where QA's adversarial test scrutiny lives: QA reviews the finished implementation with fresh eyes and renders the **binding independent test verdict**.

**Panel composition by tier.** Resolve `PANEL_ROLES` before dispatching:

- **architectural**: the six standing roles. `PANEL_ROLES="ba dba devops secops dev qa"`.
- **trivial**: `PANEL_ROLES="qa secops"` (QA's binding test verdict plus SecOps, which is never trimmed at any tier). A trivial change is a typo or one-line fix, so DBA/DevOps/BA/Dev add no independent lens worth a context spin-up; two different tripwires still catch a diff that turns out to be bigger than the tier: the MECHANICAL path tripwire above, which is a data-layer PATH predicate and covers migrations, declarative schema and SQL data-access policy sources but NOT auth and NOT authorization code, and Dev's self-reported CONSTRAINT tripwire in the agents' STANDARD-TIER CONSTRAINTS blocks, which is what covers a new auth surface, crypto or webhook verification. Either one re-tiers, at which point the full gates apply. Add the surface-conditional Design lens exactly as below when the diff touches a frontend surface.
- **cost_class `tooling`, at any tier**: `qa secops` plus ONE surface specialist (the first of `devops`, `dba`, `design_review` the probes below seat, else `dev`), for one round. The block after the Design probe applies it; SecOps keeps its seat, as it does on every full round.
- **standard**: four always, `ba dev qa secops` (SecOps is never trimmed; it holds the veto and security drift is exactly what a pre-code triage can miss). Add the surface-conditional specialists from the diff, mechanically:

```bash
PANEL_ROLES="ba dev qa secops"
# NUL-delimited into a FILE, read by the probe on stdin. Not an unquoted shell variable: see
# the mis-tier tripwire above for the zsh word-splitting defect that shape carries, and for
# why git's exit status is captured rather than discarded.
CHANGED_PATHS="$(mktemp)"
git -C "$WORKTREE_PATH" diff --name-only -z origin/main...HEAD > "$CHANGED_PATHS"
GIT_RC=$?
if [ "$GIT_RC" -ne 0 ]; then
  : > "$CHANGED_PATHS"
  echo "SURFACE-INDETERMINATE: git diff --name-only -z exited $GIT_RC; the changed-path list is UNKNOWN, not empty." >&2
fi
# The data-layer and infra surfaces are read from ${CLAUDE_PLUGIN_ROOT}/scripts/data-layer-surface.mjs,
# the same module the mis-tier tripwire uses, so detection and dispatch never diverge.
# (# CUSTOMIZE: `dataLayerGlobs` and `infraGlobs` in pipeline.config.json describe YOUR layout.)
# The panel predicate is the BROAD one deliberately: a panel seat is cheap and reversible,
# where the tripwire's narrow halt is not.
#
# The MODULE is an argument, not a constant, so the frontend probe further down this phase runs
# the same three-outcome shape instead of a second spelling of it. One function, one fail
# direction, one place to get it wrong.
surface_probe() {  # $1 = module basename under scripts/, $2 = predicate export; NUL path list on STDIN
  # THE BRACES ARE LOAD-BEARING, and nothing else in the tree says so. Plain bash treats
  # "$1" and "${1}" identically, so reverting both copies to the bare form is a no-op to a
  # shell, to the test suite, and to any diff review: it reads as a stray-brace cleanup. The
  # risk sits UPSTREAM of any shell. This file is a slash-command template, and the loader
  # substitutes bare $N tokens in the TEXT before a shell ever runs it; a rendered copy with
  # $1 substituted away exits 1 (INDETERMINATE) on every call, which the caller reads as a
  # broken probe rather than a broken template. Keep the braces, and keep both copies
  # byte-identical to each other.
  node -e 'const fs=require("node:fs");new Promise(r=>r(fs.readFileSync(0,"utf8").split("\0").filter(Boolean))).then(paths=>import(process.env.CLAUDE_PLUGIN_ROOT + "/scripts/" + process.argv[1]).then(m=>{const f=m[process.argv[2]];if(typeof f!=="function")throw new Error("missing export "+process.argv[2]+" in "+process.argv[1]);if(paths.length===0)throw new Error("empty path list: an unread diff is not a clean diff");process.exit(f(paths)?0:20)})).catch(e=>{console.error("SURFACE-INDETERMINATE: "+process.argv[2]+": "+(e&&e.message));process.exit(1)})' "${1}" "${2}"
}
surface_probe data-layer-surface.mjs diffTouchesDataLayer < "$CHANGED_PATHS"; RC=$?
if [ "$RC" -ne 20 ]; then
  PANEL_ROLES="$PANEL_ROLES dba"
  if [ "$RC" -ne 0 ]; then
    echo "PANEL-NOTE: dba SEATED on an INDETERMINATE data-layer probe (exit $RC; see SURFACE-INDETERMINATE on stderr), not on a match."
  fi
fi
surface_probe data-layer-surface.mjs diffTouchesInfra < "$CHANGED_PATHS"; RC=$?
if [ "$RC" -ne 20 ]; then
  PANEL_ROLES="$PANEL_ROLES devops"
  if [ "$RC" -ne 0 ]; then
    echo "PANEL-NOTE: devops SEATED on an INDETERMINATE infra probe (exit $RC; see SURFACE-INDETERMINATE on stderr), not on a match."
  fi
fi
```

**Three outcomes, never two, and the third one SEATS.** `surface_probe` exits 0 on a MATCH, **20** on a NO-MATCH, and anything else means INDETERMINATE: the module was absent, it threw, an export was renamed, the path list could not be read, or `node` itself was missing. The seat is therefore withheld only on the ONE code that means "the predicate ran and said no", so every unforeseen failure (node's own exit 1 on an uncaught throw or a syntax error, 127 for a missing binary) lands in the indeterminate branch instead of impersonating a clean diff.

**20 is the no-match code because node RESERVES 1 through 14 for itself** (`doc/api/process.md`, "Exit codes": 9 Invalid Argument, **10 Internal JavaScript Run-Time Failure**, 13 Unsettled Top-Level Await, 14 Snapshot Failure), and 126/127/128+n belong to the shell and to signals. The sentinel was 10, which collides with a code node emits on its own: a runtime failure inside node's bootstrap would have been read as "the predicate ran and said no", the exact impersonation the three-outcome shape exists to prevent. 20 sits above node's reserved band and below the shell's, so nothing but this block can produce it. `${CLAUDE_PLUGIN_ROOT}` resolving to a stale installed plugin cache that predates the module is a live condition, not a hypothetical, and a bare `process.exit(pred?0:1)` returns rc=1 with zero bytes on both streams in exactly that case: byte-identical to "the diff is clean", which silently drops the specialist the change exists to seat.

**Never write this as `surface_probe ... | grep -q ...`.** A pipe discards the exit status, which is the entire mechanism here.

The direction is the same rule the mis-tier tripwire states, applied to a third consumer: *an unevaluable check cannot know the answer is negative.* The tripwire halts because it cannot know the diff was clean; panel composition seats because it cannot know the diff misses the surface. Over-seating costs one reviewer's context and refuses no correct work; under-seating removes the exact lens the diff needed while `status.json` records a panel and the PR summary claims it reviewed the diff.

If any probe prints a `PANEL-NOTE:` line (data-layer, infra, or the frontend one in the Design block below), record that sentence in `status.json` (`flags`) alongside `panel_roles`, and say it in the PR summary: the recorded panel then contains a role seated by indeterminacy rather than by a match, and an auditor reading `panel_roles` later cannot tell those apart from the array alone. Fixing the stale `${CLAUDE_PLUGIN_ROOT}` is the real remedy; the seat is the safe default while it is broken.

Art Director seating: when `<ARTIFACT_DIR>/visual-contract.json` exists, read `${CLAUDE_PLUGIN_ROOT}/commands/pipeline/art-director-contract.md` now (Duty B is its panel seat); the frontend block below seats it on that same condition.

**Design is surface-conditional at EVERY tier.** Add `design_review` to `PANEL_ROLES` (on top of the architectural/trivial six or the standard four-plus) when, and only when, the diff touches a frontend surface. Use the SAME allowlist the gate uses, so detection and dispatch never diverge:

```bash
# $CHANGED_PATHS is the NUL-delimited diff path list, and `surface_probe` is the function
# defined in the panel-composition block above: this block runs in the SAME shell, immediately
# after it (produce both the same way for architectural/trivial). diffTouchesFrontend in
# ${CLAUDE_PLUGIN_ROOT}/scripts/frontend-surface.mjs is the single source of truth; the probe
# reuses it so the panel and the gate agree.
surface_probe frontend-surface.mjs diffTouchesFrontend < "$CHANGED_PATHS"; RC=$?
if [ "$RC" -ne 20 ]; then
  PANEL_ROLES="$PANEL_ROLES design_review"
  if [ "$RC" -ne 0 ]; then
    echo "PANEL-NOTE: design_review SEATED on an INDETERMINATE frontend probe (exit $RC; see SURFACE-INDETERMINATE on stderr), not on a match."
  fi
fi

# Art Director sits only when it authored a contract for this issue (Duty A above).
[ -f "$ARTIFACT_DIR/visual-contract.json" ] && PANEL_ROLES="$PANEL_ROLES art_director"

# cost_class tooling, at ANY tier: qa + secops + ONE surface specialist, one round. SecOps keeps
# its seat (a full round always seats it). The specialist is the first role the probes above
# seated, in the order devops, dba, design_review; when none was seated it is dev.
COST_CLASS="${COST_CLASS-$(jq -r '.cost_class // empty' "$PIPELINE_BASE/<issue>/status.json" 2>/dev/null)}"
if [ "$COST_CLASS" = "tooling" ]; then
  SPECIALIST="dev"
  for r in devops dba design_review; do
    case " $PANEL_ROLES " in *" $r "*) SPECIALIST="$r"; break ;; esac
  done
  PANEL_ROLES="qa secops $SPECIALIST"
  echo "PANEL-NOTE: cost_class tooling panel: qa secops $SPECIALIST (one round)."
fi
rm -f "$CHANGED_PATHS"
```

The frontend probe's late arrival on this three-outcome shape (#20) is recorded in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Frontend probe").

Record the resolved `PANEL_ROLES` in `status.json` so the merge, the rubric, and a `--resume` all agree on who was on the panel. At the same checkpoint, increment `review_rounds` (1 on the first full panel, +1 per delta round) and refresh the derived telemetry and the effective-config audit record:

```bash
node -e 'Promise.all([import(process.env.CLAUDE_PLUGIN_ROOT+"/scripts/pipeline-telemetry.mjs"),import("node:fs")]).then(([t,fs])=>{const f=process.argv[1];const st=JSON.parse(fs.readFileSync(f,"utf8"));st.telemetry=t.telemetry(st);let cfg={};try{cfg=JSON.parse(fs.readFileSync(process.argv[2],"utf8"))}catch{};st.effective_config=t.effectiveConfig(cfg);fs.writeFileSync(f,JSON.stringify(st,null,2))})' "$PIPELINE_BASE/<issue>/status.json" "$CLAUDE_PROJECT_DIR/pipeline.config.json"
```

**`review_rounds` IS CROSS-CHECKED NOW, so a mis-maintained counter is visible instead of silent.** `telemetry()` also reports `review_rounds_observed` (the panel rounds it can see in `events[]`: entries labelled `4-review` whose verdict is one a panel returns) and `review_rounds_recorded_delta`, which is `review_rounds` minus that observation. **After refreshing telemetry, read the delta. Non-zero means you got the counter wrong** -- fix `review_rounds` and re-run the refresh rather than leaving the disagreement in an archived record. Note that not every `4-review` event is a round: a delta dispatch writes an ENTRY marker (`delta-dispatched`, `DELTA`) and the merge writes a `merged` TERMINUS under the same phase label, and neither is a panel returning a verdict.

Both records are NUMBERS and glob strings only, and that is a rule rather than a habit: `status.json` is committed AND archived verbatim by the Librarian, so it must never carry an absolute filesystem path, a command string, or a credential. An absolute glob in a project config is recorded as the literal token `<absolute-glob-rejected>` rather than written through. The two migration sets are recorded separately (`migration_globs_tripwire`, `migration_globs_gate`) because they genuinely differ and an auditor who cannot tell which set was live for which control has learned nothing. When `design_review` is in the panel, dispatch the `design` reviewer with the shared Phase 4 preamble plus its lens line (it writes a bare `peer-review.design_review.json` shard), and fold that shard into `peer-review.json` under the `design_review` key in the merge loop with the same `unwrap` defense the other roles use. A standard-tier panel reviewer additionally verifies the diff against `<ARTIFACT_DIR>/constraints.md` (the injected constraints Dev was held to).

Phase 4 runs inside the implementation worktree (the reviewers need the issue branch checked out to diff it), so `ARTIFACT_DIR` is the same worktree path used in Phase 3: `<WORKTREE_PATH>/.pipeline/<issue>`. Before dispatching, refresh the flags digest into it so reviewers read it from the one absolute artifact dir:

```bash
cp "$PIPELINE_BASE/<issue>/status.json" "$ARTIFACT_DIR/status.json" 2>/dev/null || true
```

Dispatch via the **Workflow tool**, one `agent()` call per role in `PANEL_ROLES`, run inside a single `parallel([...])`. This is the one fan-out in this file that dispatches this way rather than through a single message of parallel Agent tool calls; see "Dispatch via Workflow" below for why this phase specifically, and only this phase, migrated. Each reviewer still writes a **shard file** (`peer-review.<agent>.json`), never `peer-review.json` directly, for the same lost-update reason as Phase 2, and the merge step below reads those files exactly as it always has -- the dispatch mechanism changed, the verdict contract did not. Every Phase 4 prompt includes this **shared preamble** (substitute the absolute values), followed by its lens-specific line (dispatch only the resolved panel). The preamble is the marked block in the appendix of `${CLAUDE_PLUGIN_ROOT}/commands/pipeline.md`, where the renderer reads it.


**Render the Workflow script; do not hand-write it (#157).** Every value in the panel script is computed by `scripts/render-panel.mjs`: the reviewed sha is `git rev-parse HEAD` of the worktree, the preamble is the marked block in `commands/pipeline.md`'s appendix (sliced between `<!-- BEGIN PHASE4-PREAMBLE -->` and `<!-- END PHASE4-PREAMBLE -->`, placeholders substituted), the lens per role comes from `scripts/panel-lenses.json` (the ONE lens table; there is no second copy in this file), and model and effort come from the two dispatch resolvers for `(role, <risk_tier>, 4, panel-lens, workflow)`: for the two lenses that carry a model row the renderer resolves exactly what a hand-written dispatch was told to, `dispatch-model.mjs ba <risk_tier> 4 --site panel-lens` and `dispatch-model.mjs dev <risk_tier> 4 --site panel-lens` (sonnet today), emitting `model:` only when the resolver printed one token, and it resolves `effort` for every role with `--surface workflow`. Every string is emitted through `JSON.stringify`, so no quoting class can break the script.

```bash
# Full round. PANEL_ROLES was recorded in status.json above; the renderer reads it from there.
node "${CLAUDE_PLUGIN_ROOT}/scripts/render-panel.mjs" \
  --status "$PIPELINE_BASE/<issue>/status.json" --worktree "<WORKTREE_PATH>" --check \
  --out "$ARTIFACT_DIR/panel.workflow.mjs"
```

Then pass the file's contents verbatim as the Workflow tool's `script`. `--check` parses the rendered script with `node --check` under the runtime's async wrapper and exits non-zero on a parse error, so the failure surfaces here and not as a Workflow tool rejection. The rendered file is a per-issue artifact (gitignored with the rest); the sha it carries in its header comment is the sha the panel reviewed, and the merge step below reads shards from disk exactly as before, so the dispatch mechanism changed and the verdict contract did not. The shape the renderer emits, for readers of this file (one `agent()` per role, the lens appended to the shared preamble, `agentType` namespaced, `model` present only when the resolver printed one token, `effort` always present on the workflow surface, `label` per role):

```
export const meta = { name: 'phase4-panel-<issue>', description: '...', phases: [{ title: 'Panel' }] }
phase('Panel')
const PREAMBLE = "<the marked block, substituted>"
const results = await parallel([
  () => agent(PREAMBLE + "<lens for ba>", { agentType: 'pipeline:ba', model: 'sonnet', effort: 'medium', label: 'ba-panel' }),
  () => agent(PREAMBLE + "<lens for secops>", { agentType: 'pipeline:secops', effort: 'high', label: 'secops-panel' }),
  // ... one per role in panel_roles (design_review and art_director only when seated)
])
return { returns: results }
```

**The Workflow return value is a convenience, never the verdict source.** `results` above is discarded by the orchestrator once the call returns; nothing reads a verdict out of it. The merge step below reads `peer-review.<role>.json` off disk exactly as it did before this migration, because that file, not an in-memory return value, is what `merge-peer-review.mjs` validates and what the `SubagentStop` hook gates on. `agent()` returns `null` when a subagent dies or is skipped, and a `null` entry in `results` is not itself a failure signal to act on: the missing shard IS the signal, and the merge step below already halts on it (`MISSING SHARD`, exit 2), the identical path a stalled or refused Agent-tool dispatch takes today. Do not add a second check that reads `results` for a verdict; that would be a second derivation of a decision the shard-file gate already makes, and the two could disagree.

**Prompt assembly: static first, run data last (C2).** This supersedes "placeholders substituted" above and the `<the marked block, substituted>` line in the shape. The renderer no longer substitutes `<issue>`, `<WORKTREE_PATH>`, `<HEAD_SHA>`, `<REVIEWED_SHA>`, `<ARTIFACT_DIR>`, `<FIRST_ROUND_HEAD>` or `${CLAUDE_PLUGIN_ROOT}` into the preamble or the lens. Each prompt is the static preamble (plus the delta paragraph on a delta round), then the role's lens, then a `RUN DATA` block that binds those names for this dispatch, the delta roles, the path of `peer-review.json` and the role's open blockers as one TOON table. The static part carries no issue number, sha or path, so it is byte-identical for every role of a panel and across issues on one plugin version, and a prompt cache can reuse it; `test-render-panel.sh` pins that. Do not put a per-run value back into the preamble or a lens. TOON (the encoder is `toon.mjs`, beside the renderer) is used for prompt text only: agents still read and write JSON artifacts, and no schema changed. `prompt-weight.mjs` reports the bytes and estimated tokens of the command files, the agent definitions and a rendered panel for a fixture issue.

### Dispatch via Workflow (why THIS phase, and why only this phase, today)

Phase 4 is the one fan-out in this file dispatched through the `Workflow` tool rather than a single message of parallel Agent tool calls, for a reason specific to this phase, not a general preference: it is the one place `dispatch-effort.mjs`'s `--surface workflow` table has a live consumer (below), and Phase 4 is purely mechanical fan-out-then-merge with no mid-run owner input, which is exactly the shape the `Workflow` tool supports. The Phase 2 reviewer fan-out, the Phase 2.5 sketch pair, and the Phase 0.5 architectural map stay on the Agent tool: nothing about them changes here, and this section is not an invitation to migrate them on the same reasoning. Do that only with its own evaluation; effort has no table row worth spending at those sites today (see "Dispatch effort routing" below), so there is no equivalent payoff, and each would need its own review of whatever mid-run interaction, if any, it carries.

Invoking `Workflow` here is authorized under its own gating rule ("the user invoked a skill or slash command whose instructions tell you to call Workflow"): running `/pipeline` on an architectural-tier ask IS that invocation, so no additional per-run opt-in is needed for this one call.

Both questions this migration was gated on are resolved (#101): q4, the SecOps veto stays fail-closed, by construction; q6, the runtime honors a `SubagentStop` block on a Workflow-dispatched agent, confirmed empirically. The record is in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Dispatch via Workflow").

The Design row appears in the PR summary table and the merge loop only when `design_review` is in `PANEL_ROLES` (frontend-touching diffs); otherwise it is listed among the not-on-panel lenses, exactly like the surface-trimmed DBA/DevOps.

After all dispatched reviewers return, **merge the shards into `peer-review.json`** via `${CLAUDE_PLUGIN_ROOT}/scripts/merge-peer-review.mjs`, which folds each named role's bare shard into the target file with the same `unwrap` defense as Phase 2 (a wrapped or sibling-buried shard recovers its verdict instead of nulling out). The merge is ADDITIVE: it overwrites only the roles named on THIS invocation and preserves every other role already in the file. That is what makes a delta re-review round (below) safe, and it is the SAME script the manual `/phase peer-review` re-run calls, so the auto and manual paths cannot diverge. On a FULL round, start from a clean file so no stale shard survives; on a delta round, do NOT reset it (that is the whole point). Orchestrator note: run the loop that builds the argument list via `bash -c '...'`; the session shell may be zsh, which does not word-split an unquoted `$PANEL_ROLES` (the whole string becomes one word and the loop iterates zero roles), and `bash -c` guarantees POSIX word-splitting. Avoid `status` and `path` as shell variable names here (zsh treats them specially).

```bash
# Full round: reset, then fold every dispatched role. ROLES_TO_MERGE=$PANEL_ROLES here.
rm -f "$ARTIFACT_DIR/peer-review.json"
ARGS=()
for role in $ROLES_TO_MERGE; do
  SHARD="$ARTIFACT_DIR/peer-review.$role.json"
  # The recovery path a reviewer whose primary write was refused is told to use. Read HERE,
  # before the merge decides anything: a fallback nobody reads is a lost review.
  [ -f "$SHARD" ] || SHARD="$ARTIFACT_DIR/fallback-shards/peer-review.$role.json"
  if [ ! -f "$SHARD" ]; then echo "MISSING SHARD: $role" >&2; fi   # missing shard = halt (script exits 2)
  ARGS+=("$role=$SHARD")
done
node "${CLAUDE_PLUGIN_ROOT}/scripts/merge-peer-review.mjs" --status "$PIPELINE_BASE/<issue>/status.json" "$ARTIFACT_DIR/peer-review.json" "${ARGS[@]}"
for role in $ROLES_TO_MERGE; do rm -f "$ARTIFACT_DIR/peer-review.$role.json"; done
```

Recoverability is bought by making the fallback a path the merge actually READS, never by making a missing shard non-fatal: a lost VETO must never become a silent APPROVE. A dispatched role whose block is absent or survives as `null` (an agent that never wrote, or wrote unrecoverable garbage) carries no verdict, so the rubric below cannot read it as `APPROVE`; the script exits non-zero on a missing shard, and a recovered-but-null block (a shard present on disk that yields no verdict after unwrap) is treated as a missing review and HALTs without writing a partial merge. A role that was never on the panel (trimmed at standard/trivial tier) is simply absent from `peer-review.json`; that is not a missing review.

