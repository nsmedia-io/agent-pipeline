---
description: Session-start warmup. Reports git state, reads the file-based knowledge store, notes in-flight work, lists any wired data sources, then stands by for the ask.
allowed-tools: Read, Grep, Glob, Bash
---

# /warmup

Session-start ritual. Run this before accepting any ask so the workspace is fresh and durable context is loaded.

Four jobs, in order:
1. Report git state: current branch, drift from the integration branch, dirty files, stale worktrees.
2. Read the file-based knowledge store (`knowledge/living-context/*.json`) and surface current-status highlights.
3. Note any in-flight work (open PRs/issues) if the project uses GitHub.
4. List the external data sources the project has wired, so they can be reached on demand.

A lightweight version of steps 1 to 3 also runs automatically via the `SessionStart` hook; this command is the fuller, on-demand sweep (role-scoped knowledge, in-flight work, data-source inventory).

**Installed plugin version.** Hooks, gates and agent contracts load from the installed plugin cache, not from this checkout, so a stale install is invisible from inside a session. Run the local comparison first (no network; it reads the marketplace clone and the cache listing under `~/.claude/plugins/`):

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/version-check.mjs" --plugin-root "${CLAUDE_PLUGIN_ROOT}"
```

It prints nothing when the marketplace clone advertises no newer version (a newer copy in the cache alone does not warn, because the update command cannot change an orphaned cache directory), and one line naming both versions and the update command when there is. If it prints, put that line at the top of the Step 5 risk summary. Silence means nothing newer is cached locally, not that the install is current: the marketplace clone is only as fresh as its last update.

---

### Step 1: Git state against the integration branch

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/warmup-report.mjs" [--role <role>] [--spec <spec.json>]
```

It fetches and reports against `integrationBranch` from `pipeline.config.json` (`main` when unset): `BRANCH`, `HEAD`, `IN-WORKTREE`, `DIRTY`, `DRIFT`, `WORKTREES`, one `MERGED-WORKTREE` or `GONE-WORKTREE` line per stale candidate, the open PRs and issues (Step 3) and the `DOMAINS` to sweep (Step 2). If `IN-WORKTREE` is `no`, start fresh: `git worktree add .claude/worktrees/warmup-$(date +%Y%m%d-%H%M%S) origin/<integration branch>` and `cd` into it. Already inside one: do not force-reset; if the drift conflicts with the branch's purpose, stop and surface it. Offer to remove the merged worktrees; never delete silently.

---

### Step 2: Read the knowledge store (file-based, no network)

The durable, human-readable knowledge base lives in the project's repo under `knowledge/`, committed to git:

- `knowledge/living-context/<domain>--<slug>.json` : current project/architecture state, one topic per file.
- `knowledge/issue-archive/<issue>.json` : archived completed pipeline runs.
- `knowledge/decisions/<slug>.json` : optional decision records.

Living-context file shape:

```json
{ "title": "...", "domain": "api", "status": "current|superseded", "last_updated": "ISO-8601", "tags": ["..."], "content": "...", "see_also": ["other-slug"] }
```

**Read it with the helper** (no embeddings, no network; simple case-insensitive keyword match over `title + tags + content`, filtered to `status == "current"`):

```bash
ROOT="$(git rev-parse --show-toplevel)"
node ${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-store.mjs --search "current state overview" --root "$ROOT"
node ${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-store.mjs --search "auth token" --domain security --root "$ROOT"
node ${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-store.mjs --list  --collection living-context --root "$ROOT"
```

Each match prints as `* <title>  [<status>]`, a 160-char body snippet, and the file path so you can open the full doc. If node is unavailable, glob and read the JSON directly:

```bash
grep -l '"status": *"current"' "$(git rev-parse --show-toplevel)"/knowledge/living-context/*.json
```

#### Role-scoped sweep

At a generic session start sweep all domains. On behalf of a pipeline agent, sweep the `DOMAINS` line of `warmup-report.mjs --role <role>` (Dev also passes `--spec`), one `--domain <d>` per domain. Domain scoping is noise reduction, not a hard boundary: any role may search any domain on demand.

**Source precedence (apply on every conflict).** Two tiers, not equals:
1. The **code and the live system are present truth** and win on any disagreement.
2. `knowledge/*.json` is the durable **derived** truth: reviewable, branch-aware, the store of record for orientation and recall.

Read the knowledge store to orient, but treat every load-bearing claim as a lead to verify against the code before you act on it, especially anything months old (`last_updated`) or decisive for the next step. When the store and the code disagree, the code wins, and the Librarian should refresh the stale file at Phase 5.

---

### Step 3: In-flight work (open PRs/issues)

The archive in the knowledge store is merged history; what is OPEN now is where duplicated or conflicting effort happens. The report's `PR` and `ISSUE` lines are the open ones, newest first (`IN-FLIGHT: unknown` when `gh` is absent or the project is not on GitHub: substitute your forge's CLI, # CUSTOMIZE). An open PR or issue touching the current branch's area is a near-certain conflict or duplication; the BA "duplicate search must include open PRs" rule applies here too. Also glance at active local pipelines with `node ${CLAUDE_PLUGIN_ROOT}/scripts/pipeline-status.mjs`.

---

### Step 4: External data sources (query on demand)

`# CUSTOMIZE:` list the data sources this project has wired (via MCP or CLI) so the model knows to reach for them when validating live state rather than only reading the repo. For each, note how to reach it and any gotchas. Delete this block if the project has none. Examples of the shape to fill in:

- **Logs / observability** (e.g. a logging backend, an APM): which dataset/service, the query language, where the structured message actually lives, how to scope a time window.
- **Database** (e.g. via an MCP server or a read-only client): project/connection identifier, the safe read path, and any access-control caveats (a service-role connection may bypass row-level controls; treat with care).
- **Platform / framework docs** (a read-only docs MCP): reach for authoritative current docs instead of training recall when a task touches fast-moving platform behavior.

**Optional health glance.** If monitoring or a database is wired, take a 30-second look at error rates and any advisor/lint warnings before standing by, so you start knowing whether the system is degraded. A glance, not a deep dive. If nothing is wired, skip it.

**If a tool isn't loaded:** call `ToolSearch` with `select:<full_tool_name>` to load its schema before invoking, and proactively load the ones this project's tasks most often need.

---

### Step 5: Report and stand by

Summarize to the owner before waiting for the ask. **Lead with what changed and what is risky, then the detail.** A flat dump of everything you read is noise; the value is the synthesis.

**1. Risk and delta summary (lead with this, 3 to 6 lines).** The handful of things that matter now: divergence from the integration branch; in-flight PRs/issues that touch the current area (conflict or duplication risk); any load-bearing knowledge-store fact that is stale or contradicts the code; and, if wired, the monitoring/DB pulse (clean, or the one anomaly). If nothing is risky, say so plainly in one line.

**2. Detail (only what the summary references, plus brief orientation):**
- Active worktree path and head commit (short SHA + subject); worktree-hygiene note if stale ones exist.
- Knowledge-store highlights grouped by domain, one line each as `[domain] title: <snippet>`, with the `last_updated` date so staleness is visible.
- Most recently merged issues (from `knowledge/issue-archive/`) and open PRs/issues, flagging any that touch the current branch's area.
- Data-source pulse, if wired.
- Gaps: an empty knowledge store, stale docs, unexpected drift, a data-source tool not loaded.

Then wait. Do not start Phase 1 until the owner delivers an ask.
