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
  agents/                            # ba, dba, devops, secops, dev, qa, design, librarian
  hooks/                             # session-start, stop, subagent-stop (all fail-open, opt-in)
  scripts/                           # gates, artifact validator, file-based knowledge store
  schemas/                           # typed artifact JSON schemas
  knowledge/                         # empty template for the file-based knowledge store
  pipeline.config.example.json       # the CUSTOMIZE knobs
  README.md                          # start here
```

## Customize

Copy `plugins/pipeline/pipeline.config.example.json` to `pipeline.config.json` at your project root and edit. Grep the plugin for `CUSTOMIZE` to find every knob (build command, integration branch, frontend globs, migration glob, tier triggers). Edit the `STANDARD-TIER CONSTRAINTS` blocks in the DBA/DevOps/SecOps agents to match your stack.

## License

MIT. See [LICENSE](LICENSE).
