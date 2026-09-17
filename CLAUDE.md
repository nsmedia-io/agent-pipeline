# agent-pipeline

A Claude Code plugin (and its one-plugin marketplace) that runs a risk-tiered multi-agent
development pipeline. This repo IS the plugin source; it also runs the pipeline on itself.

## Commands

```
bash tests/run.sh        # the whole suite, routine mode, 4 suites at a time; also the Stop-hook checkCommand
PIPELINE_TESTS_FULL=1 bash tests/run.sh   # full mode: adds the release-only cells (nested fresh-checkout run, oversized timeout and sweep cells)
PIPELINE_TESTS_JOBS=1 bash tests/run.sh   # one suite at a time (default 4)
bash tests/test-<name>.sh # one suite (routine mode unless PIPELINE_TESTS_FULL=1)
bash tests/run-linux.sh [test-<name>.sh ...]  # the Linux answer, in a container built from tests/Dockerfile, on demand
node scripts/sync-manifests.mjs --check    # marketplace.json matches plugin.json (the one remaining workflow)
```

Healthy output ends with a slowest-first wall-time list and `All test suites passed.`; each suite
reports `failed=0`. A suite ending in `# pipeline-tests: serial` runs alone after the parallel pool
(wall-time budgets, or it acts on the shared checkout). Do not run the suite while a
`plugins/pipeline/scripts/*.mjs` edit is mid-write: the tests read the live tree, and a partial
file reads as a one-off SyntaxError (see `tests/run.sh` header).

## Layout

- `plugins/pipeline/commands/` the `/pipeline` orchestrator, `/phase`, `/warmup`. Prose the
  model executes; the deterministic parts live in `scripts/` and the prose calls them.
  `pipeline.md` is the always-loaded core; the core's loading map says when to read each phase.
- `plugins/pipeline/orchestrator/` one file per `/pipeline` phase, gate and handoff, read when
  that phase starts. Kept out of `commands/` on purpose: markdown in a subdirectory there can be
  exposed as a namespaced slash command.
- `plugins/pipeline/shared/` blocks the agent contracts read by reference (evidence discipline,
  tracked-write isolation). `docs/rationale.md` holds incident histories no prompt loads.
- `plugins/pipeline/agents/` nine role contracts (frontmatter sets model, effort, maxTurns).
- `plugins/pipeline/scripts/` gates, surface predicates, dispatch routing, the merge, telemetry.
- `plugins/pipeline/hooks/` SessionStart, Stop, SubagentStop, PreToolUse. All fail open.
- `plugins/pipeline/schemas/` the typed artifacts under `.pipeline/<issue>/`.
- `plugins/pipeline/evidence.md` what counts as having checked something, and the materiality
  rule for what a finding may block on. `evidence-controls.md` is the extra discipline for
  control surfaces (hooks, gates, auth, migrations, CI).
- `knowledge/` the file-based knowledge store. The Librarian is its writer during runs.
- `pipeline.config.json` this repo's own config. `config-doctor.mjs` validates keys at warmup.

## Conventions that bite

- **Tests pin prose.** Many suites grep the orchestrator prose and `agents/*.md` for exact
  strings, extract bash blocks and RUN them. They read the core plus every phase file through
  `pipeline_md_concat` in `tests/harness.sh`; a new phase file goes in its `PIPELINE_MD_PARTS`. Editing prose can redden a test; that is the test
  working. Read the failing assertion's label before changing either side.
- **The replicated block.** `## The property, not the fix` is byte-identical in the nine agent
  files plus `orchestrator/phase-4-panel-preamble.md`, with a sha1 digest on the line after the span. Edit all ten
  together and update the digest line in all ten.
- **Config keys are a closed set.** A new `pipeline.config.json` key needs a row in
  `scripts/config-doctor.mjs`, the README table, and `pipeline.config.example.json`.
- **Versioning.** Run `PIPELINE_TESTS_FULL=1 bash tests/run-linux.sh` on the release commit and cut
  nothing unless it passes (routine mode skips cells a release needs). Bump
  `plugins/pipeline/.claude-plugin/plugin.json`, run `node scripts/sync-manifests.mjs`, commit as
  `<version>: <one-line what changed>`.
- **Numbers carry their population.** A figure in prose names what it was measured on.
- **Pipeline changes are judged on throughput.** Measure phase time before adding a gate.
