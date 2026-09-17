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
- **architectural**: schema/data-migration, a cross-cutting contract change, a compliance dimension, or a change to the security posture (a new auth flow or authorization check, crypto, webhook verification, a new external data intake, a new retained data type). Reading or writing user data under existing auth is standard. Adds the parallel pre-code review, a design bake-off (two sketches with opposing assigned stances, one judge), the design-lock owner gate, a QA-first failing-test contract, the full panel, and the live-verification gate.

## The knowledge store (file-based, replaces a vector DB)

Durable project knowledge lives as plain JSON in your project's `knowledge/` folder, versioned in git, no embeddings, no network. The Librarian writes it at Phase 5; warmup and the agents read it. See [`knowledge/README.md`](knowledge/README.md).

## Customize (grep the plugin for `CUSTOMIZE`)

Copy `pipeline.config.example.json` to `pipeline.config.json` at your project root. Keys:

| Key | What it does | Default |
|---|---|---|
| `integrationBranch` | Base branch for worktrees and diffs | `main` |
| `checkCommand` | The command Dev and the Stop hook run to prove green. Set it: the fallback is much weaker than it looks | `npm run typecheck`, and only if your package.json declares that script; otherwise the Stop hook verifies nothing at all |
| `knowledgeDir` | Where the knowledge store lives | `knowledge` |
| `frontendSurface` | Globs that mark a diff as frontend-touching (drives the Design lens + visual gate) | a generic component/style set |
| `migrationGlobs` | Globs the pre-Phase-4 gate uses to DISCOVER migrations in the impl-report. REPLACES the built-in preset union, so setting it NARROWS gate discovery. It does NOT narrow the mis-tier tripwire, which unions the same key with the presets; widen both with `extraMigrationGlobs` instead | the fifteen-row framework-preset union in `scripts/data-layer-surface.mjs` |
| `extraMigrationGlobs` | Additive globs that union into gate discovery, the mis-tier tripwire, and the DBA panel seat. Never replaces anything | `[]` |
| `dataLayerGlobs` | Broad globs that seat DBA on the Phase 4 panel (schema, queries, policies, generated DB types). Empty or invalid means defaults | the tripwire union plus the broad extras in `scripts/data-layer-surface.mjs` |
| `infraGlobs` | Globs that seat DevOps on the Phase 4 panel (CI, deploy scripts, infra config). Empty or invalid means defaults | the infra set in `scripts/data-layer-surface.mjs` |
| `migrationDownMarker` | The line that marks a migration's down section for the reversibility gate | `-- DOWN` |
| `deferralTracker` | Where a deferred item is written so it stops being a sentence in an artifact: `github` (`gh issue create`), `gitlab` (`glab issue create`), or `directory` (a committed markdown file, for a project with no tracker CLI) | `github` |
| `deferralDir` | The committed ledger directory, read only when `deferralTracker` is `directory` | `knowledge/deferred` |
| `dispatchModels` | Per-role model overrides for the orchestrator's dispatches, allowlisted to `opus`/`sonnet`/`haiku`. `secops` and `qa` are pinned to opus in code and ignore this key | the built-in table in `scripts/dispatch-model.mjs` (DBA drops to sonnet on a standard or trivial panel) |
| `dispatchEfforts` | Per-role effort overrides (`low`..`max`) for the Phase 4 panel, which dispatches through the Workflow tool. Every role is reachable, both directions | the tiered table in `scripts/dispatch-effort.mjs` (SecOps xhigh/high/medium and QA high/medium/medium by tier) |
| `securitySurfaceGlobs` | Additive globs that re-seat SecOps on a Phase 4 DELTA round when a fix commit touches them (auth, session, crypto, secrets, webhooks, policies). Widen-only | the built-in set in `scripts/security-surface.mjs` |
| `architecturalTriggers` | Paths/domains/keywords that force the architectural tier. ADVISORY: no script reads this key; the BA agent reads it as prose at intake (agents/ba.md duty 6), and `architecturalTriggers.keywords` in particular is a hint to that judgment, never a mechanical trigger | pipeline.config.json, the compliance domain, and the concrete security/data triggers in agents/ba.md duty 6 |
| `x` | The PROJECT-OWNED namespace: an object for your own settings (a wrapper script's knobs, team notes). The plugin never reads inside it and the config doctor never flags it. A top-level key starting with `_` is exempt too. Any other unknown key is reported as read by nothing | absent |

### Upgrading

Behaviour changes that reach an existing project at its next plugin update are listed per release, newest first, in [CHANGELOG.md](CHANGELOG.md). Read every entry between your installed version and the new one before updating. SessionStart warns when the running copy is older than one already on disk (`scripts/version-check.mjs`), and `scripts/migrate-records.mjs` reports which `.pipeline/` records the current schemas reject and normalises the mechanical part with `--write`.

Four more customization points:

- **The handoff voice.** [`voice.md`](voice.md) is the standard for orchestrator-to-human text: the report shape, the analogy rules, the Blast radius / Reversibility / Confidence scales, the decision block, and the feature complete report. It is wired into `/pipeline` and `/phase` only, deliberately. The subagents write typed JSON shards for the orchestrator to merge, and they each see one lens, so none of them can compute a blast radius or a confidence level; pushing voice mode down into them would trade away the precision (table names, CVE severity, line numbers) that makes their shards reviewable. Edit `voice.md` to change how the pipeline talks to you.
- **Model aliases and the dispatch routing table.** Every per-invocation `model:` override comes from ONE table, `scripts/dispatch-model.mjs`, which the orchestrator asks as `node dispatch-model.mjs <role> <risk_tier> <phase> [--site <label>]`; the dispatch emits `model:` only when that call exits 0 and prints exactly one token, and otherwise omits the key so the agent's frontmatter governs. Override a role with `dispatchModels` in `pipeline.config.json` (allowlisted to `opus`/`sonnet`/`haiku`). SecOps and QA are pinned in code, emit no override at any tier, and ignore that key: they hold the veto and the binding test verdict, and a cheap lens that misses returns APPROVE while nothing escalates. The values themselves are deliberate floating aliases, resolved by the harness to the latest model of each tier, not pinned full model IDs, so the pipeline rides model upgrades without a rename pass. Re-pin only on a specific regression.
- **Agent constraint checklists.** `agents/dba.md`, `agents/devops.md`, and `agents/secops.md` each carry a marker-delimited `STANDARD-TIER CONSTRAINTS` block that the orchestrator injects into the Dev thread. Edit the checklist inside the markers to match your stack. Keep the marker comments intact.
- **MCP tools.** Each agent's `tools:` frontmatter lists only the universal tools. Add your project's MCP tools (database, docs, browser) to the agents that need them.

## The gates (portable disciplines, kept from the original)

- **Blast-radius map** — before the spec locks, enumerate the contracts/types a change touches and their readers, so Phase 4 verifies unchanged consumers instead of discovering the regression later.
- **Grounding gate** — any directive about how a field is handled must first cite the field's real persisted shape (nullable? default? omitted on the common path?). A fail-direction call made without that grounding is invalid.
- **Gate-bites proof** — when a change adds a build-failing control (a lint rule, a CI check, a gate), it is not done until you have recorded the control failing on a planted violation and passing on the fix. A control no one has watched fail is indistinguishable from a no-op.
- **Config doctor** — every knob here fails soft: a missing key takes a default, a misspelled key is ignored, a wrong-typed value falls back. Correct at runtime, and exactly why a broken config is invisible. The session-start warmup now reports what is missing, what is misspelled (with the nearest real key and the script that would have read it), what is the wrong type, and what silently stops working as a result. It stays quiet when the config is fine. This plugin's own shipped example carried the bug it catches: `migrationsGlob` where the code reads `migrationGlobs`, and a string where it requires an array, so anyone who copied and edited it kept the default forever.
- **Voice lint** — `voice.md` was referenced twelve times in `pipeline.md` and four in `phase.md`, and until now nothing read it, which is rule 19 of `evidence-controls.md` about its own author: a written expectation no code reads is a comment. The Stop hook now derives whether this is a full-voice moment from `status.json`'s `current_phase` rather than asking the orchestrator to remember, and checks the message's shape (decision block, rating scales, the replication block, no em dashes, no "as discussed"). It is silent on every stop that is not a pipeline voice moment, deliberately: a lint that enforced the em-dash rule on ordinary conversation would be switched off within a day. It checks shape, never quality. And it stops at the owner boundary: it runs on Stop, never SubagentStop, because `voice.md` is a handoff protocol for the one moment a human has to decide something, not a house style. Agents talk to each other in their own dense, technical register, and that traffic is never linted.
- **Open-questions gate** — BA records genuine ambiguity in `spec.open_questions` with a recommendation instead of inventing an answer, and a `blocking` entry halts Phase 1 until the owner answers. It is a typed field and not an instruction because `requirements` and `acceptance_criteria` are schema-required: before it existed, a spec with a blank failed validation while a spec with a plausible guess passed, so the contract paid BA to guess. `blocking: true` has to clear two bars, not one: name two acceptance criteria that follow from two answers, AND the difference between them must be one only the owner can settle (cost, timeline, reversibility, product direction). Falsifiability alone lets engineering-internal questions through, and a gate that fires on those is a gate that gets switched off.
- **Design-lock** — the bake-off's two sketches get opposing assigned stances (smallest blast radius vs. cleanest seam), because separate contexts alone do not make two samples of one model independent. When the judge rules that they materially diverged, the choice goes to the owner as a decision block before Phase 3 starts. This is the only standing owner gate on the happy path, placed at the moment with the lowest reversibility and the highest owner-only content (roadmap, urgency, what else is landing here).
- **Phase-entry guard** — phase sequencing used to be a norm: the orchestrator decided what ran next, so an orchestrator that skipped a phase was caught by nothing. The Stop hook now refuses to END a turn whose `current_phase` names a phase with an absent prerequisite. Completion is never written and never claimed, it is DERIVED: `spec.json`, `review.json`, `design.json`, `impl-report.json` and `peer-review.json` exist only because a subagent was dispatched and returned, so they cannot be produced by omission. Everything but `status.json` is gitignored, so a resumed run on another machine has no artifacts at all; a committed `events[]` entry closing the phase satisfies the guard too, and writing a false one is an affirmative act in a committed, archived file rather than an omission. That is the threat model: omission, not forgery. It fires at the turn boundary, not before a dispatch, so it does not make skipping impossible — it makes an unrecorded skip become a blocked turn or a recorded one. It caught its own author: the run that built it had skipped the design bake-off without recording it, and refused itself until the deviation was written down.
- **Phase 4 tracked-write gate** — a `PreToolUse(Bash)` hook refuses a SUBAGENT's blanket staging (`git commit -a`, `git add -A`, `git add .`, `git add -u`, `git stage -A`, and every bundled spelling of them: `git commit -aqm 'm'` and `git add -Av` stage exactly as much and are refused too) while an in-flight run sits at a Phase 4 phase, so the commit-hygiene rule the agent contracts carry is enforced at the tool call instead of argued at the reader. It is scoped by ORIGIN and not by role: only a call carrying Claude Code's `agent_id` field is in scope, so the orchestrator's own status-only checkpoint is exempt by design, and there is no role allowlist — which makes it deliberately WIDER than the panel, and a subagent that is not a pipeline panelist at all (a general-purpose Task worker, an adopting project's own agent) is refused too whenever a Phase 4 run is the resolved owner. Explicit-path staging is never refused, whatever the path, including `git add -u <path>` and a panelist's own `.pipeline/<issue>/peer-review.<role>.json` shard; a forbidden spelling quoted inside a commit MESSAGE is not an invocation and is not refused. It fails OPEN on every tooling gap, and it abstains whenever it cannot tell whose run a call belongs to, writing one line to stderr that names which gap or abstention it was. `CLAUDE_HOOK_PRETOOLUSE_SKIP=1`, set in the environment the hook itself runs in, disarms it for a session — and unlike the phase-entry guard above that is allowed, because the carve-out refusing an opt-out knob covers HALTING controls and this is a ratchet that already fails open by construction, but operating it still leaves its own distinct line on stderr, since the carve-out's reason (a suppression that leaves no trace in the archived record) binds on either side of it.
- **Materiality**: every review concern carries `severity`, `likelihood`, `harm` and `merge_class` (`wrong-pass`, `money`, `data-loss`, `security-exposure`, `none`), and a concern blocks a merge only when it is blocker/critical/high, has a merge class, and is reachable in normal use (edge cases too when BA set `cost_class: product-money`; at `tooling` only a false green or a security exposure blocks). `scripts/materiality.mjs` is the rule in code and `merge-peer-review.mjs` applies it to every shard it folds; the rubric reads `materiality.blocks_merge`. At most two blockers per reviewer, enforced by demotion. A `VETO` stands only on a named `veto_ground` carrying a blocking concern. Notes ship: a note with a `suggested_patch` is applied in the same turn, the rest go onto one deferral checklist per issue. Measured reason: on one consumer, a single tooling issue ran 21 spec revisions and 8 panel rounds under the previous rule.
- **Round budgets in code**: `scripts/round-budget.mjs` counts Phase 4 fix rounds (tooling 1, product 2, product-money 2) and spec revisions after Phase 2 (2) in `status.json`, and past either budget it refuses and puts ship with deferrals / split / stop to the owner. A delta round seats the roles holding open blocker ids plus whoever's merge-class surface the fix touched: DBA on the data layer, SecOps on security paths (and the data layer outside tooling), QA on test files, DevOps on infra outside tooling. SecOps always sits on a full round.
- **Mis-tier tripwire** — a migration/auth/contract-shape change appearing in a standard-tier diff halts and re-tiers to architectural. The deep gates cannot be skipped by mis-classifying an ask.
- **Live-verification gate** — for data-migration or security-sensitive changes, a self-skipping integration suite that skips when its env is absent does not count as verification; a recorded local pass is required.
- **Frontend visual-verification gate** — a frontend-touching diff needs recorded design evidence (a design review verdict + lint + accessibility pass) before the panel.
- **Deferral ledger** — an item a review round marks deferred is not deferred until it is WRITTEN somewhere durable, so the pre-Phase-4 gate refuses a `deferred[]` entry (or a `scope_drift.observations_reported_not_fixed[]` entry) whose `tracker_ref` does not resolve. `scripts/deferral.mjs record` is the writer and it routes by `deferralTracker`: `gh issue create`, `glab issue create`, or a committed markdown file under `deferralDir` for a project with no tracker CLI at all. A missing CLI never halts the gate, only a missing or unresolvable ref does; but `record` REFUSES rather than silently choosing a different destination, because a deferral you believe is filed and is not is worse than one that refused loudly. It exists because "routed to #N" was claimed in an artifact across three consecutive rounds on one pull request and had been written nowhere.

## Artifacts

Every phase writes typed JSON under `.pipeline/<id>/` in your project (add it to your `.gitignore`; keep `status.json` if you want cross-machine resume). Schemas are in [`schemas/`](schemas/). The validator is a SubagentStop hook, not a general-purpose CLI: it reads the hook payload on stdin and validates the stopping agent's artifact, so it takes no `<type> <file>` arguments. Its only flag is `node "${CLAUDE_PLUGIN_ROOT}/scripts/validate-pipeline-artifact.mjs" --self-test`, which runs its built-in checks.

**Naming a run directory, and how to tell the gate is alive.** The validator only recognises a run directory named `<issue-number>` or `exp-<slug>`, because those are the two names `ba.md` sanctions. A run named any other way — which is what you get when `gh issue create` fails outside experiment mode — used to opt out of every artifact check in silence. It no longer does: such a directory is still validated when it is the only run in the project, and the validator says so. More generally the validator now writes **one line to stderr on every stop**, naming the agent, the verdict (`checked`, `no-rules`, `no-active-issue`, `unnamed-run`, `unnamed-run-ambiguous`), the run directory and the violation count, so "I checked and it was fine" and "I never checked" are no longer the same observation. `decision:block` on stdout is unchanged. The one case that stays completely silent is a project with no `.pipeline/` directory at all — an ad-hoc, non-pipeline session must not be taxed a line per subagent stop.

## Tests

The four hooks have a dependency-free bash suite (no framework, no `node_modules`):

```
bash tests/run.sh
```

The suite lives in this repository's root `tests/` directory, outside the published `plugins/pipeline` path, so installing the plugin does not download it. Run it from a clone of the repository.

There is no hosted CI for the suite (0.40.2 retired the Actions workflow: forty minutes per push, billed to a subscription). The Linux answer is taken on demand, in a pinned container, with the strict-capability flag set so an absent optional tool such as zsh counts as a failure rather than a silently narrower suite:

```
bash tests/run-linux.sh                 # the whole suite
bash tests/run-linux.sh test-x.sh ...   # named suites
```

It builds throwaway git repos and drives each hook end to end: that the Stop hook blocks a turn (exit 2) on a failing check and stays out of the way otherwise, that the SessionStart report degrades quietly outside a repo or with a broken config, that the SubagentStop hook passes a `decision: block` through while fail-opening on every tooling gap, and that the PreToolUse gate denies a Phase 4 subagent's blanket staging, allows explicit-path staging and the orchestrator's own checkpoint, and fails open on all eight of its tooling gaps.

Each config-parsing case was recorded FAILING against the pre-fix hooks before it was recorded passing, per the gate-bites rule below. A control nobody has watched fail is indistinguishable from a no-op, and that is not hypothetical here: both hooks previously read `pipeline.config.json` with a regex that silently returned the default on a reformatted config, so the Stop hook's check gate could stop firing with nothing to indicate it had.

This repo's own [`pipeline.config.json`](../../pipeline.config.json) wires that suite as `checkCommand`, so the Stop hook gates development of the plugin with the plugin's own machinery.

## Requirements

- Claude Code with plugin support.
- Node (for the bundled scripts) and git.
- Optional: the GitHub CLI (`gh`) if you want the pipeline to open issues/PRs. Without it, the tracker steps degrade to local notes.
- Optional, and only for frontend work: a **preview/browser MCP server** of your own choosing. This plugin ships none and declares none. The `design` and `art-director` agents list Claude Preview's tools in their frontmatter as one option (`# CUSTOMIZE`); swap in whatever your project uses. Without one, `design` can still run its token-lint lens through `Bash`, but it CANNOT run axe-core, so it records `a11y: { status: "unavailable" }` rather than a pass and `gate-pre-phase4-frontend.mjs` correctly halts a frontend-touching diff instead of passing one on evidence nobody gathered. `art-director` cannot render at all, so it holds no binding ground and degrades to advisory. Both are instructed to name the missing tool, so the halt is diagnosable; neither is permitted to record an unrun check as a pass.
