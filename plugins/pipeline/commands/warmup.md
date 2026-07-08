---
description: Session-start warmup. Reports git state, reads the file-based knowledge store, notes in-flight work, lists any wired data sources, then stands by for the ask.
allowed-tools: Read, Grep, Glob, Bash
---

# /warmup

Session-start ritual. Run this before accepting any ask so the workspace is fresh and durable context is loaded.

Four jobs, in order:
1. Report git state: current branch, drift from the integration branch (`origin/main`), dirty files, stale worktrees.
2. Read the file-based knowledge store (`knowledge/living-context/*.json`) and surface current-status highlights.
3. Note any in-flight work (open PRs/issues) if the project uses GitHub.
4. List the external data sources the project has wired, so they can be reached on demand.

A lightweight version of steps 1 to 3 also runs automatically via the `SessionStart` hook; this command is the fuller, on-demand sweep (role-scoped knowledge, in-flight work, data-source inventory).

`# CUSTOMIZE:` the integration branch defaults to `main`. Set `integrationBranch` in `pipeline.config.json` if yours differs; substitute it wherever `main` appears below.

---

### Step 1: Fresh worktree pinned to the integration branch

Repo root: `$(git rev-parse --show-toplevel)`.

**If starting fresh (not already in a worktree):**

```bash
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
git fetch origin main
NAME="warmup-$(date +%Y%m%d-%H%M%S)"
git worktree add .claude/worktrees/"$NAME" origin/main
cd .claude/worktrees/"$NAME"
git log -1 --oneline
git status
```

**If already inside a worktree (session started there):**

Do not force-reset. Verify the tracking branch and report drift:

```bash
git fetch origin main
git log -1 --oneline
git rev-list --left-right --count HEAD...origin/main
```

If there is drift from `origin/main` that conflicts with the current branch's purpose, stop and surface it to the owner. Do not silently rebase or reset.

**Worktree hygiene.** Long sessions accumulate orphaned worktrees. Glance at the count and flag clearly-stale ones rather than letting the tree grow unbounded:

```bash
git worktree list | wc -l
git worktree prune   # drops administrative records for worktree dirs already deleted
# stale candidates = worktrees whose branch is already merged into origin/main or no longer exists
```

Report the count and any obviously-stale worktrees; offer to remove the merged ones, do not delete silently.

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

At a generic session start, and for the BA and Librarian roles, sweep **all domains**. When warmup runs on behalf of a specific pipeline agent, search ONLY that role's domains so the agent starts from a focused, low-noise context. Domain scoping is noise reduction, not a hard boundary: any role may still search any domain on demand when a blast-radius or cross-cutting check needs it.

| Role | Warmup domains |
|---|---|
| BA | all domains |
| DBA | `data` |
| SecOps | `security`, `compliance` |
| DevOps | `infrastructure` |
| QA | `testing` |
| Dev | the domains of the package(s) impacted by the current task (read the spec's `impacted_domains`); fall back to all domains if none resolve yet |
| Design | `frontend` |
| Librarian | all domains (it maintains the whole knowledge base) |

The generic domain set is: `data`, `api`, `frontend`, `infrastructure`, `security`, `compliance`, `architecture`, `testing`. To run a role-scoped sweep, iterate the role's domains, passing each as `--domain <d>`.

**Source precedence (apply on every conflict).** Two tiers, not equals:
1. The **code and the live system are present truth** and win on any disagreement.
2. `knowledge/*.json` is the durable **derived** truth: reviewable, branch-aware, the store of record for orientation and recall.

Read the knowledge store to orient, but treat every load-bearing claim as a lead to verify against the code before you act on it, especially anything months old (`last_updated`) or decisive for the next step. When the store and the code disagree, the code wins, and the Librarian should refresh the stale file at Phase 5.

---

### Step 3: In-flight work (open PRs/issues)

The archive in the knowledge store is merged history. The higher-risk context is what is OPEN right now, where duplicated or conflicting effort happens. If the project uses GitHub, query it directly:

```bash
gh pr list --state open --json number,title,isDraft,headRefName,updatedAt \
  -q 'sort_by(.updatedAt) | reverse | .[] | "[PR \(if .isDraft then "draft" else "open" end)] #\(.number) \(.title)  (\(.headRefName))"' | head -15
gh issue list --state open --limit 12 --json number,title,updatedAt \
  -q 'sort_by(.updatedAt) | reverse | .[] | "#\(.number) \(.title)"'
```

An open PR or issue touching the current branch's area is a near-certain conflict or duplication, and more actionable than anything in the merged archive. The BA "duplicate search must include open PRs" rule applies to warmup too.

`# CUSTOMIZE:` if the project does not use GitHub (or `gh` is not installed), skip this step or substitute your forge's CLI. Also glance at active local pipelines with `node ${CLAUDE_PLUGIN_ROOT}/scripts/pipeline-status.mjs`.

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

**1. Risk and delta summary (lead with this, 3 to 6 lines).** The handful of things that matter now: divergence from `origin/main`; in-flight PRs/issues that touch the current area (conflict or duplication risk); any load-bearing knowledge-store fact that is stale or contradicts the code; and, if wired, the monitoring/DB pulse (clean, or the one anomaly). If nothing is risky, say so plainly in one line.

**2. Detail (only what the summary references, plus brief orientation):**
- Active worktree path and head commit (short SHA + subject); worktree-hygiene note if stale ones exist.
- Knowledge-store highlights grouped by domain, one line each as `[domain] title: <snippet>`, with the `last_updated` date so staleness is visible.
- Most recently merged issues (from `knowledge/issue-archive/`) and open PRs/issues, flagging any that touch the current branch's area.
- Data-source pulse, if wired.
- Gaps: an empty knowledge store, stale docs, unexpected drift, a data-source tool not loaded.

Then wait. Do not start Phase 1 until the owner delivers an ask.
