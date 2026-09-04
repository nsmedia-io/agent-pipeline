# agent-pipeline

A Claude Code plugin (and its one-plugin marketplace) that runs a risk-tiered multi-agent
development pipeline. This repo IS the plugin source; it also runs the pipeline on itself.

## Commands

```
bash plugins/pipeline/tests/run.sh        # the whole suite; also the Stop-hook checkCommand
bash plugins/pipeline/tests/test-<name>.sh # one suite
bash plugins/pipeline/tests/run-linux.sh [test-<name>.sh ...]  # the Linux answer, in a container, on demand
node scripts/sync-manifests.mjs --check    # marketplace.json matches plugin.json (the one remaining workflow)
```

Healthy output ends with every suite listed and `failed=0`. Do not run the suite while a
`plugins/pipeline/scripts/*.mjs` edit is mid-write: the tests read the live tree, and a partial
file reads as a one-off SyntaxError (see `tests/run.sh` header).

## Layout

- `plugins/pipeline/commands/` the `/pipeline` orchestrator, `/phase`, `/warmup`. Prose the
  model executes; the deterministic parts live in `scripts/` and the prose calls them.
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

- **Tests pin prose.** Many suites grep `commands/pipeline.md` and `agents/*.md` for exact
  strings, extract bash blocks and RUN them. Editing prose can redden a test; that is the test
  working. Read the failing assertion's label before changing either side.
- **The replicated block.** `## The property, not the fix` is byte-identical in the nine agent
  files plus `pipeline.md`, with a sha1 digest on the line after the span. Edit all ten
  together and update the digest line in all ten.
- **Config keys are a closed set.** A new `pipeline.config.json` key needs a row in
  `scripts/config-doctor.mjs`, the README table, and `pipeline.config.example.json`.
- **Versioning.** Bump `plugins/pipeline/.claude-plugin/plugin.json`, run
  `node scripts/sync-manifests.mjs`, commit as `<version>: <one-line what changed>`.
- **Numbers carry their population.** A figure in prose names what it was measured on.
- **Pipeline changes are judged on throughput.** Measure phase time before adding a gate.
