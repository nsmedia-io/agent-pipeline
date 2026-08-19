# pipeline

A risk-tiered multi-agent development pipeline for Claude Code. It turns a one-line ask into a validated spec, a single-writer implementation with tests, and an adversarial review panel on the finished diff, with typed artifacts at every step and a plain file-based knowledge store (no external services).

## The idea

Multi-agent spend goes where independence actually pays:

- **The write path is single-threaded and carries full context.** One Dev thread receives the spec, the blast-radius map, and the specialists' constraint checklists, then writes code and its tests together. Fragmenting planning, review, and implementation across contexts loses more than it gains.
- **Independent review of a finished artifact fans out.** A panel of agents reviews the finished diff concurrently, each through a distinct lens (spec fidelity, security, testing, code quality, data, infra), while remote CI runs in parallel: local checks are the implementation done gate, and remote CI-green is a merge precondition verified at merge, not a panel-entry gate. Fresh eyes on a fixed diff catch what the author cannot. When the panel requests changes, the re-run is a delta re-review: QA and SecOps re-review unconditionally, plus the objecting and surface-touched roles, additively merged so standing approvals hold and the final verdict is computed over the full panel.
- **Phases are quality gates with loop-backs, not a waterfall.** A later phase that invalidates an earlier assumption loops back to the owning phase.

## Install

```
/plugin marketplace add nsmedia-io/agent-pipeline
/plugin install pipeline@agent-pipeline
```

Then, in any project:

```
/pipeline <your ask>            # run the full pipeline
/pipeline --resume <id>         # resume a halted run
/pipeline --issue <n>           # start from an existing tracker issue
/phase <name> --issue <n>       # run a single phase (retry / targeted re-review)
/warmup                         # git status + knowledge highlights, then stand by
```

The orchestrator dispatches these subagents (they never call each other; only the main session orchestrates):

| Agent | Role |
|---|---|
| **BA** | Gatekeeper. Validates the ask, maps blast radius, writes the spec, sets the risk tier. |
| **Dev** | Single Phase 3 implementation thread. Writes code and tests together (or implements QA's failing test contract at the architectural tier). |
| **QA** | Owns the test-discipline standard; renders the binding independent test verdict on the finished diff. |
| **SecOps** | Security and compliance review. Holds the veto. On every panel. |
| **DBA** | Data model, migrations, query safety. Conditional. |
| **DevOps** | Infra, CI/CD, deploy safety. Conditional. |
| **Design** | Frontend/UX/accessibility/copy. Conditional (frontend diffs only). |
| **Art Director** | Owns the RESULT of a visual surface, not its conformance. Authors a binding visual contract before implementation, rules on the gap after. Conditional (only when a contract exists). Its `REQUEST_CHANGES` binds solely on a cited clause plus its own rendered evidence; preference stays advisory. |
| **Librarian** | Post-merge knowledge persistence. Writes the file-based knowledge store. |

## Risk tiers (set by BA, they change the pipeline's shape)

- **trivial**: typo / one-line fix. Straight to a single Dev thread, then a trimmed panel of QA plus SecOps (plus Design on frontend diffs).
- **standard**: a normal feature or bugfix. The specialists' standing constraint checklists are injected into one Dev thread (no pre-code review, and the blast-radius map is folded into the BA intake rather than a separate dispatch); a trimmed panel reviews the diff, with a hard tripwire if migration/auth/contract-shape work appears.
- **architectural**: schema/data-migration, a cross-cutting contract change, or any security/compliance dimension. Adds the parallel pre-code review, a design bake-off (two sketches with opposing assigned stances, one judge), the design-lock owner gate, a QA-first failing-test contract, the full panel, and the live-verification gate.

## The knowledge store (file-based, replaces a vector DB)

Durable project knowledge lives as plain JSON in your project's `knowledge/` folder, versioned in git, no embeddings, no network. The Librarian writes it at Phase 5; warmup and the agents read it. See [`knowledge/README.md`](knowledge/README.md).

## Customize (grep the plugin for `CUSTOMIZE`)

Copy `pipeline.config.example.json` to `pipeline.config.json` at your project root. Keys:

| Key | What it does | Default |
|---|---|---|
| `integrationBranch` | Base branch for worktrees and diffs | `main` |
| `checkCommand` | The command Dev and the Stop hook run to prove green | `npm run typecheck && npm test && npm run lint` |
| `knowledgeDir` | Where the knowledge store lives | `knowledge` |
| `frontendSurface` | Globs that mark a diff as frontend-touching (drives the Design lens + visual gate) | a generic component/style set |
| `migrationGlobs` | Globs the pre-Phase-4 gate uses to DISCOVER migrations in the impl-report. REPLACES the built-in preset union, so setting it NARROWS gate discovery. It does NOT narrow the mis-tier tripwire, which unions the same key with the presets; widen both with `extraMigrationGlobs` instead | the fifteen-row framework-preset union in `scripts/data-layer-surface.mjs` |
| `extraMigrationGlobs` | Additive globs that union into gate discovery, the mis-tier tripwire, and the DBA panel seat. Never replaces anything | `[]` |
| `dataLayerGlobs` | Broad globs that seat DBA on the Phase 4 panel (schema, queries, policies, generated DB types). Empty or invalid means defaults | the tripwire union plus the broad extras in `scripts/data-layer-surface.mjs` |
| `infraGlobs` | Globs that seat DevOps on the Phase 4 panel (CI, deploy scripts, infra config). Empty or invalid means defaults | the infra set in `scripts/data-layer-surface.mjs` |
| `migrationDownMarker` | The line that marks a migration's down section for the reversibility gate | `-- DOWN` |
| `dispatchModels` | Per-role model overrides for the orchestrator's dispatches, allowlisted to `opus`/`sonnet`/`haiku`. `secops` and `qa` are pinned in code and ignore this key | the built-in table in `scripts/dispatch-model.mjs` |
| `architecturalTriggers` | Domains/keywords that force the architectural tier | data/security/compliance |

Four more customization points:

- **The handoff voice.** [`voice.md`](voice.md) is the standard for orchestrator-to-human text: the report shape, the analogy rules, the Blast radius / Reversibility / Confidence scales, the decision block, and the feature complete report. It is wired into `/pipeline` and `/phase` only, deliberately. The subagents write typed JSON shards for the orchestrator to merge, and they each see one lens, so none of them can compute a blast radius or a confidence level; pushing voice mode down into them would trade away the precision (table names, CVE severity, line numbers) that makes their shards reviewable. Edit `voice.md` to change how the pipeline talks to you.
- **Model aliases.** The `model:` values in the agent frontmatter and the `/pipeline` dispatch overrides (`opus` for the QA verdict, the SecOps veto, and the bake-off judge; `sonnet` for the map, the sketches, and the BA/Dev Phase 4 lenses) are deliberate floating aliases, resolved by the harness to the latest model of each tier; they are not pinned full model IDs, so the pipeline rides model upgrades without a rename pass. Re-pin only on a specific regression.
- **Agent constraint checklists.** `agents/dba.md`, `agents/devops.md`, and `agents/secops.md` each carry a marker-delimited `STANDARD-TIER CONSTRAINTS` block that the orchestrator injects into the Dev thread. Edit the checklist inside the markers to match your stack. Keep the marker comments intact.
- **MCP tools.** Each agent's `tools:` frontmatter lists only the universal tools. Add your project's MCP tools (database, docs, browser) to the agents that need them.

## The gates (portable disciplines, kept from the original)

- **Blast-radius map** — before the spec locks, enumerate the contracts/types a change touches and their readers, so Phase 4 verifies unchanged consumers instead of discovering the regression later.
- **Grounding gate** — any directive about how a field is handled must first cite the field's real persisted shape (nullable? default? omitted on the common path?). A fail-direction call made without that grounding is invalid.
- **Gate-bites proof** — when a change adds a build-failing control (a lint rule, a CI check, a gate), it is not done until you have recorded the control failing on a planted violation and passing on the fix. A control no one has watched fail is indistinguishable from a no-op.
- **Config doctor** — every knob here fails soft: a missing key takes a default, a misspelled key is ignored, a wrong-typed value falls back. Correct at runtime, and exactly why a broken config is invisible. The session-start warmup now reports what is missing, what is misspelled (with the nearest real key and the script that would have read it), what is the wrong type, and what silently stops working as a result. It stays quiet when the config is fine. This plugin's own shipped example carried the bug it catches: `migrationsGlob` where the code reads `migrationGlobs`, and a string where it requires an array, so anyone who copied and edited it kept the default forever.
- **Voice lint** — `voice.md` was referenced twelve times in `pipeline.md` and four in `phase.md`, and until now nothing read it, which is rule 19 of `evidence.md` about its own author: a written expectation no code reads is a comment. The Stop hook now derives whether this is a full-voice moment from `status.json`'s `current_phase` rather than asking the orchestrator to remember, and checks the message's shape (decision block, rating scales, the replication block, no em dashes, no "as discussed"). It is silent on every stop that is not a pipeline voice moment, deliberately: a lint that enforced the em-dash rule on ordinary conversation would be switched off within a day. It checks shape, never quality. And it stops at the owner boundary: it runs on Stop, never SubagentStop, because `voice.md` is a handoff protocol for the one moment a human has to decide something, not a house style. Agents talk to each other in their own dense, technical register, and that traffic is never linted.
- **Open-questions gate** — BA records genuine ambiguity in `spec.open_questions` with a recommendation instead of inventing an answer, and a `blocking` entry halts Phase 1 until the owner answers. It is a typed field and not an instruction because `requirements` and `acceptance_criteria` are schema-required: before it existed, a spec with a blank failed validation while a spec with a plausible guess passed, so the contract paid BA to guess. `blocking: true` has to clear two bars, not one: name two acceptance criteria that follow from two answers, AND the difference between them must be one only the owner can settle (cost, timeline, reversibility, product direction). Falsifiability alone lets engineering-internal questions through, and a gate that fires on those is a gate that gets switched off.
- **Design-lock** — the bake-off's two sketches get opposing assigned stances (smallest blast radius vs. cleanest seam), because separate contexts alone do not make two samples of one model independent. When the judge rules that they materially diverged, the choice goes to the owner as a decision block before Phase 3 starts. This is the only standing owner gate on the happy path, placed at the moment with the lowest reversibility and the highest owner-only content (roadmap, urgency, what else is landing here).
- **Mis-tier tripwire** — a migration/auth/contract-shape change appearing in a standard-tier diff halts and re-tiers to architectural. The deep gates cannot be skipped by mis-classifying an ask.
- **Live-verification gate** — for data-migration or security-sensitive changes, a self-skipping integration suite that skips when its env is absent does not count as verification; a recorded local pass is required.
- **Frontend visual-verification gate** — a frontend-touching diff needs recorded design evidence (a design review verdict + lint + accessibility pass) before the panel.

## Artifacts

Every phase writes typed JSON under `.pipeline/<id>/` in your project (add it to your `.gitignore`; keep `status.json` if you want cross-machine resume). Schemas are in [`schemas/`](schemas/). The validator is a SubagentStop hook, not a general-purpose CLI: it reads the hook payload on stdin and validates the stopping agent's artifact, so it takes no `<type> <file>` arguments. Its only flag is `node "${CLAUDE_PLUGIN_ROOT}/scripts/validate-pipeline-artifact.mjs" --self-test`, which runs its built-in checks.

## Tests

The three hooks have a dependency-free bash suite (no framework, no `node_modules`):

```
bash plugins/pipeline/tests/run.sh
```

It builds throwaway git repos and drives each hook end to end: that the Stop hook blocks a turn (exit 2) on a failing check and stays out of the way otherwise, that the SessionStart report degrades quietly outside a repo or with a broken config, and that the SubagentStop hook passes a `decision: block` through while fail-opening on every tooling gap.

Each config-parsing case was recorded FAILING against the pre-fix hooks before it was recorded passing, per the gate-bites rule below. A control nobody has watched fail is indistinguishable from a no-op, and that is not hypothetical here: both hooks previously read `pipeline.config.json` with a regex that silently returned the default on a reformatted config, so the Stop hook's check gate could stop firing with nothing to indicate it had.

This repo's own [`pipeline.config.json`](../../pipeline.config.json) wires that suite as `checkCommand`, so the Stop hook gates development of the plugin with the plugin's own machinery.

## Requirements

- Claude Code with plugin support.
- Node (for the bundled scripts) and git.
- Optional: the GitHub CLI (`gh`) if you want the pipeline to open issues/PRs. Without it, the tracker steps degrade to local notes.
