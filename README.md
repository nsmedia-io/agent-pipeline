# agent-pipeline

A **Claude Code plugin** (and single-plugin marketplace) that runs a risk-tiered, multi-agent development pipeline: it takes an ask, has a BA spec and tier it, a single Dev thread implement it with tests, and an adversarial panel review the finished diff, with typed artifacts and a plain file-based knowledge store. No external services, no vector database, no vendor lock-in.

Generalized from a pipeline used on a production SaaS codebase, with every project/vendor/person specific stripped out.

## Install

```
/plugin marketplace add nsmedia-io/agent-pipeline
/plugin install pipeline@agent-pipeline
```

Then run `/pipeline <your ask>` in any project. Full usage, agents, tiers, gates, and customization are in **[plugins/pipeline/README.md](plugins/pipeline/README.md)**.

## What's inside

```
.claude-plugin/marketplace.json     # marketplace listing (this repo)
plugins/pipeline/
  .claude-plugin/plugin.json         # plugin manifest
  commands/                          # /pipeline, /phase, /warmup
  agents/                            # ba, dba, devops, secops, dev, qa, design, art-director, librarian
  hooks/                             # session-start, stop, subagent-stop, pre-tool-use (all fail-open, opt-in)
  scripts/                           # gates, surface predicates, dispatch routing, telemetry, config doctor, artifact validator, knowledge store
  schemas/                           # typed artifact JSON schemas
  knowledge/                         # empty template for the file-based knowledge store
  pipeline.config.example.json       # the CUSTOMIZE knobs
  README.md                          # start here
  tests/                             # the suite CI runs on every push and pull request
```

## Customize

Copy `plugins/pipeline/pipeline.config.example.json` to `pipeline.config.json` at your project root and edit. The session-start warmup checks that file every session and tells you if a key is misspelled, wrongly typed, or missing in a way that silently disables a gate; it stays quiet when the config is sound. Grep the plugin for `CUSTOMIZE` to find every knob. The config keys are `integrationBranch`, `checkCommand`, `knowledgeDir`, `frontendSurface`, `migrationGlobs`, `extraMigrationGlobs`, `dataLayerGlobs`, `infraGlobs`, `dispatchModels`, `dispatchEfforts`, `securitySurfaceGlobs`, `migrationDownMarker`, and `architecturalTriggers`. The path globs ship per-framework defaults (Rails, Django, Alembic, Prisma, Drizzle, Supabase, Flyway, EF Core, Laravel, Liquibase), so most projects need not set them at all, and the warmup tells you when a glob you did set matches nothing in your repo. Edit the `STANDARD-TIER CONSTRAINTS` blocks in the DBA/DevOps/SecOps agents to match your stack.

## License

MIT. See [LICENSE](LICENSE).
