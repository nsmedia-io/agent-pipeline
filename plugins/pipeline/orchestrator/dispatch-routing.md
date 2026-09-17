### Dispatch model routing

**Every model override in this file comes from ONE table.** Ask the resolver, never a literal, and paste what it prints:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-model.mjs" <role> <risk_tier> <phase> [--site <label>] --emit
```

It prints a `model: <token>` line for the Agent call or nothing, and always exits 0. Nothing printed means no `model:` key: never an empty literal, and never a fall-through to the session model. **This is the OPPOSITE fail direction from the mis-tier tripwire, and both are deliberate:** an unevaluable tripwire cannot know the diff was clean, so it halts; an unevaluable resolver has a correct answer already sitting in agent frontmatter, so it stays out of the way. An absent resolver (a stale `${CLAUDE_PLUGIN_ROOT}` cache), an unparseable project config and a caller bug (unknown role, malformed tier or phase, named on stderr) all print nothing.

**SecOps and QA are PINNED IN CODE and emit no `model:` key at all**, so their frontmatter governs at every tier: QA holds the binding independent test verdict and SecOps holds the veto. `dispatchModels` cannot reach them; a config entry for either is ignored AND reported. The reason is failure shape, not seniority: a cheap detection lens that misses returns APPROVE and nothing escalates. Every other role stays configurable within the resolver's allowlist of floating aliases, in both directions; a full model ID is rejected and reported, so the pipeline rides model upgrades without a rename pass. What each role and site resolves to, config applied: `node "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-model.mjs" --table`. (# CUSTOMIZE: `dispatchModels` in pipeline.config.json.)

### Dispatch effort routing

**Effort has its own table, and unlike model it reaches NO Agent-tool dispatch.** Ask the resolver rather than reasoning about effort at a dispatch site:

```bash
EFFORT="$(node "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-effort.mjs" <role> <risk_tier> <phase> [--site <label>] [--surface agent|workflow])"
EFFORT_RC=$?
```

**Do not add an `effort:` key to an Agent call. There is no such parameter.** The Agent tool takes `description`, `isolation`, `model`, `prompt`, `run_in_background` and `subagent_type`. Effort is settable per SESSION and per ROLE (`effort:` in `agents/<role>.md` frontmatter), never per dispatch. So on `--surface agent` (the default) the resolver prints NOTHING and reports that frontmatter governs, rather than hand back a value a dispatch site has nowhere to put: a table claiming a level the Agent tool never sent would be a routing table lying about the routing.

`--surface workflow` exists for the Workflow tool's `agent(prompt, { effort })`, a genuine per-call override, and **the Phase 4 panel dispatches through it** (see "Dispatch via Workflow" in `phase-4-panel.md`). On that surface the resolver ALWAYS emits an explicit token, including for a role with no table row, because an omitted `effort` there inherits either the session effort (the Workflow docs) or the agent's frontmatter (#98's live spike), and a session sitting at `low` makes those two readings differ in the direction that matters.

**Effort is TIERED, and no role is pinned.** Phase 4 rows are tier-specific, and a `tooling` cost class has its own SecOps row; models stay pinned where `dispatch-model.mjs` pins them, and what moves by tier is how long a reviewer thinks. `dispatchEfforts` can reach every role, in both directions, allowlisted; a rejected value is reported. Rows are looked up, never clamped: there is no rank comparison in `dispatch-effort.mjs`. What each role resolves to on both surfaces, config applied: `node "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-effort.mjs" --table`. (# CUSTOMIZE: `dispatchEfforts` in pipeline.config.json.)

### Dispatch log (usage telemetry, #163)

**There is no step to take here.** When `usageTelemetry` is on (off by default), the PreToolUse hook `hooks/dispatch-log.sh` appends one line per Agent, Task or Workflow dispatch to the dispatch log: issue, phase, role, tier, cost class, the model and effort the dispatch ran at, and which rule above chose each (`table:<role>/<phase>/...`, `config:dispatchModels.<role>`, `pinned:<role>`, or the frontmatter file). It reads the run from `status.json`, so the checkpoint-first order every phase already follows is what makes the phase right; a dispatch made before its phase checkpoint is logged under the previous phase. The hook records no prompt, description or tool argument. A hook that cannot write says so in a systemMessage and never blocks the dispatch. The report is `dispatch-log.mjs`'s sibling `usage-report.mjs`; see the README section "Usage telemetry".
