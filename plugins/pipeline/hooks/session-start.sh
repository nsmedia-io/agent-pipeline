#!/usr/bin/env bash
# SessionStart hook (agent-pipeline plugin). Its stdout is injected into the session context.
# Reports: git state (branch, HEAD, drift vs the integration branch, dirty files, stale
# worktrees), current knowledge-store topics, and any active pipeline runs.
#
# Deliberately `set -u` only (NOT -e / pipefail): this is a fail-open report hook that runs
# many best-effort probes, several of which legitimately exit non-zero (a grep with no match,
# an offline fetch). It must never wedge or abort a session.

set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Only run inside a git working tree; stay silent everywhere else.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# Shared config reader (see hooks/lib.sh). A missing lib means a broken install; stay silent
# rather than emit a half-formed warmup report.
LIB="$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=./lib.sh
[[ -f "$LIB" ]] && . "$LIB" || exit 0

# CUSTOMIZE: set "integrationBranch" in pipeline.config.json if yours is not "main".
INTEGRATION_BRANCH="$(read_config integrationBranch main)"
# CUSTOMIZE: set "knowledgeDir" in pipeline.config.json if your knowledge store is not ./knowledge.
KNOWLEDGE_SUBDIR="$(read_config knowledgeDir knowledge)"

echo "=== AGENT PIPELINE WARMUP ==="
echo ""

# --- Git state ---
BRANCH=$(git branch --show-current 2>/dev/null || echo "?")
HEAD=$(git log -1 --oneline 2>/dev/null || echo "?")
echo "Branch: $BRANCH"
echo "HEAD: $HEAD"

# Branch-aware issue extraction: branches like fix/1297-foo, feat/847-bar carry an issue number.
# Surface the issue title so resumed work does not re-discover context. Skipped silently when the
# branch has no leading issue number, gh is absent, or gh fails (offline / non-GitHub remote).
ISSUE_FROM_BRANCH=$(printf '%s' "$BRANCH" | sed -nE 's#^(fix|feat|chore|docs|refactor|test)/([0-9]+)-.*#\2#p')
if [[ -n "$ISSUE_FROM_BRANCH" ]] && command -v gh >/dev/null 2>&1; then
  ISSUE_INFO=$(gh issue view "$ISSUE_FROM_BRANCH" --json number,title,state,updatedAt \
    --jq '"#\(.number) [\(.state)] \(.title) (updated \(.updatedAt))"' 2>/dev/null)
  [[ -n "$ISSUE_INFO" ]] && echo "Branch references: $ISSUE_INFO"
fi

# Fetch + drift vs the integration branch (best-effort; fall back to cached refs on failure).
if git fetch origin "$INTEGRATION_BRANCH" --quiet 2>/dev/null; then
  DRIFT=$(git rev-list --left-right --count "HEAD...origin/$INTEGRATION_BRANCH" 2>/dev/null || echo "? ?")
  echo "Drift from origin/$INTEGRATION_BRANCH: $DRIFT (ahead behind)"
else
  CACHED=$(git rev-list --left-right --count "HEAD...origin/$INTEGRATION_BRANCH" 2>/dev/null || echo "")
  if [[ -n "$CACHED" ]]; then
    echo "Drift from origin/$INTEGRATION_BRANCH: $CACHED (ahead behind, cached; fetch failed)"
  else
    echo "Drift from origin/$INTEGRATION_BRANCH: unknown (no remote ref; fetch failed)"
  fi
fi

# Dirty working tree (first few entries).
DIRTY=$(git status --porcelain 2>/dev/null | head -5)
if [[ -n "$DIRTY" ]]; then
  echo "Working tree has uncommitted changes:"
  echo "$DIRTY" | sed 's/^/  /'
fi

# Stale-worktree hygiene: flag the count, never delete.
WT_COUNT=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
if [[ -n "$WT_COUNT" ]] && [[ "$WT_COUNT" -gt 3 ]]; then
  echo "Worktrees: $WT_COUNT registered. Prune stale ones with 'git worktree prune' / 'git worktree remove'."
fi

echo ""

# --- Knowledge store: current living-context topics (file-based; no network, no embeddings) ---
KDIR="$PROJECT_DIR/$KNOWLEDGE_SUBDIR/living-context"
STORE="$PLUGIN_ROOT/scripts/knowledge-store.mjs"
printed=0
echo "Knowledge (current living-context topics):"
if [[ -n "$PLUGIN_ROOT" ]] && [[ -f "$STORE" ]] && command -v node >/dev/null 2>&1; then
  LINES=$(node "$STORE" --list --collection living-context --root "$PROJECT_DIR" 2>/dev/null \
          | grep -i '\[current\]' | head -5)
  if [[ -n "$LINES" ]]; then
    printf '%s\n' "$LINES"
    printed=1
  fi
fi
if [[ "$printed" -eq 0 ]]; then
  if [[ -d "$KDIR" ]]; then
    count=0
    for f in "$KDIR"/*.json; do
      [[ -f "$f" ]] || continue
      grep -q '"status"[[:space:]]*:[[:space:]]*"current"' "$f" 2>/dev/null || continue
      TITLE=$(grep -oE '"title"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
              | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/')
      DOMAIN=$(grep -oE '"domain"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
               | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/')
      [[ -n "$TITLE" ]] || continue
      echo "  [${DOMAIN:-?}] $TITLE"
      count=$((count + 1))
      [[ "$count" -ge 5 ]] && break
    done
    [[ "$count" -eq 0 ]] && echo "  (none current yet; populate $KNOWLEDGE_SUBDIR/living-context/)"
  else
    echo "  (no knowledge store yet; see the plugin's knowledge/README.md)"
  fi
fi

echo ""

# --- Active pipeline runs (generic; reads .pipeline/<issue>/status.json in the project) ---
if [[ -d .pipeline ]]; then
  ACTIVE=""
  for dir in .pipeline/[0-9]*/; do
    [[ -d "$dir" ]] || continue
    [[ -f "$dir/status.json" ]] || continue
    ISSUE=$(basename "$dir")
    # status.json is pretty-printed ("current_phase": "..."), so the parse must tolerate
    # whitespace around the colon (a no-space grep matches nothing and blanks the phase).
    # A FINISHED run is not an active pipeline, so skip it: recognize finished by the
    # phase-5 terminal set (any "5-" prefix, e.g. 5-archive, 5-archived) OR a non-empty
    # completed_at, so a run left under any phase-5 variant or carrying completed_at is
    # skipped without depending on one exact label. A non-terminal 4-* run (e.g.
    # 4-review-complete) or a halted-error run is NOT finished and stays listed as active.
    PHASE=$(grep -oE '"current_phase"[[:space:]]*:[[:space:]]*"[^"]*"' "$dir/status.json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    [[ -z "$PHASE" ]] && PHASE="?"
    COMPLETED=$(grep -oE '"completed_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$dir/status.json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    if [[ "$PHASE" == 5-* || -n "$COMPLETED" ]]; then continue; fi
    ACTIVE="${ACTIVE}  #${ISSUE}: ${PHASE}"$'\n'
  done
  if [[ -n "$ACTIVE" ]]; then
    echo "Active pipelines:"
    printf '%s' "$ACTIVE"
    echo ""
  fi
fi

# CUSTOMIZE: if your project wires monitoring / DB / log / docs data sources (via MCP or CLI),
# list them here so the session knows to reach for them on demand. Optionally probe their health.
# Example:
#   echo "Data sources: <your logs backend>, <your database>, <your platform docs>"

echo "=== Pipeline primitives loaded ==="
echo "  Subagents: ba, dba, devops, secops, dev, qa, design, librarian"
echo "  Commands: /pipeline, /phase, /warmup"
echo '  Schemas: ${CLAUDE_PLUGIN_ROOT}/schemas/*.schema.json'
echo "=== END WARMUP ==="
exit 0
