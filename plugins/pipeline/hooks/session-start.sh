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

# --- Is this checkout configured for the plugin at all? ---
#
# A LOUD LINE, NEVER A REFUSAL. A hook that wedged a session over a missing config would be the
# wrong instrument entirely; the refusal lives in commands/pipeline.md Phase 0 step 0, where a
# run can be halted before it dispatches anything.
#
# WHY IT IS FIRST, AND WHY IT IS LOUD. A session ran an entire pipeline end to end inside a
# worktree created before its project adopted this plugin. That tree carried the project's own
# retired in-repo copy, so every phase dispatched, every gate ran, every gate PASSED, and Phase 5
# silently no-opped into a store nothing read. Nothing in the run looked wrong, because the stale
# copy answered consistently about itself. The absent config file is the cheapest early signal
# that separates that tree from a configured one.
#
# config-doctor.mjs also reports this, further down and in the sober register it uses for every
# other key. That register is right for "you misspelled a glob" and wrong for "this may be the
# wrong checkout", and the doctor's line needs node on PATH while this one does not.
if [[ ! -f "$PROJECT_DIR/pipeline.config.json" ]]; then
  echo "NOT CONFIGURED: there is no pipeline.config.json at $PROJECT_DIR."
  echo "  This checkout either predates the plugin's adoption or was never configured. A pipeline"
  echo "  run started from it would use stale or missing tooling, and a stale in-repo copy passes"
  echo "  every gate it owns. /pipeline HALTS at Phase 0 until this is settled."
  echo "  Settle it: cp \"\$CLAUDE_PLUGIN_ROOT/pipeline.config.example.json\" pipeline.config.json"
  echo "  and edit it, or move to the checkout that already has one."
  echo ""
fi

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

  # --- Phase-entry guard availability ---
  #
  # The Stop-hook guard (scripts/gate-phase-entry.mjs) fails OPEN on tooling: a missing node or
  # a missing script disarms it exactly like a grant, permanently, with nothing said at the
  # moment it happens. That disarm occurs in the OPERATOR's environment, and session start is
  # the only place in that environment this plugin already speaks, so the check is paid once
  # here instead of at every stop.
  GATE_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../scripts/gate-phase-entry.mjs"
  GATE_DISARM=""
  [[ -f "$GATE_SCRIPT" ]] || GATE_DISARM="its script is not installed"
  command -v node >/dev/null 2>&1 || GATE_DISARM="node is not on this hook's PATH"
  if [[ -n "$GATE_DISARM" ]]; then
    # WHICH COLUMN THIS READS, AND WHY IT CHANGED (#74 s2). This used to date a record by its
    # FILE MTIME (`find "$dir/status.json" -mtime -1`) where the guard dates it by its own
    # `updated_at`. Those are not the same quantity and they disagreed on live records in the
    # most common environment: MEASURED in a fresh `git clone --no-hardlinks` pinned at 856a5d0,
    # all 6 notice-eligible records had mtime age 0.00h -- checkout time -- while their
    # `updated_at` ages spanned 9.99h to 341.49h, so the notice fired on 6 and the guard called
    # 5 of those 6 not in flight. 83% disagreement, every one of them in the CLAIM-MORE
    # direction: the operator was told a run was in flight that the guard had already abstained
    # on. A clone rewrites every mtime, so mtime is a property of the CHECKOUT; `updated_at` is
    # the run's own claim about itself, which is the thing the sentence below asserts.
    #
    # WHAT THE NARROWER PREDICATE REFUSES, stated because a notice nobody sees is worth as
    # little as one nobody believes. It no longer announces a disarmed guard in a checkout where
    # every record is already stale by its own `updated_at` -- which is exactly the case where
    # the guard would have abstained on all of them anyway, so the disarm has no live
    # consequence to announce. It newly SURFACES one shape the mtime test missed: a record dated
    # in the FUTURE. The guard has no floor either (`now - updated <= IN_FLIGHT_MS` is satisfied
    # by any negative age), so agreeing with it there is the point, not an accident.
    #
    # NO NODE. This must report in the very environment where node is absent, so the comparison
    # is done on the ISO strings themselves. `updated_at` is UTC-Z in every record this repo has
    # ever committed (25 of 25 blobs across all history: 22 `...SSZ`, 3 `...SS.mmmZ`), and both
    # spellings share a fixed-width first 19 characters, so truncating both sides to 19 makes
    # the lexicographic compare exact to the second with no format hazard. A value that is NOT
    # that shape is not compared as a string at all; see the fallback below.
    #
    # The two `date` invocations are ORDERED, not interchangeable. BSD is tried first because
    # BSD's `-d` means "set DST", not "parse this description", so on macOS the GNU spelling
    # would silently parse as something else rather than fail; the BSD spelling fails loudly on
    # GNU (`invalid option -- 'v'`, exit 1) and hands over cleanly. A third `date` that
    # understands neither leaves CUTOFF empty, which the per-record fallback below handles.
    #
    # Compared as INTEGERS, not with `[[ > ]]`: the string operator collates by locale, and a
    # locale that ignores punctuation at the primary level would be comparing something other
    # than what this line appears to compare. Stripping to 14 digits (YYYYMMDDHHMMSS) removes
    # the question. `10#` forces base 10 so a future field with a leading zero cannot be read
    # as octal.
    CUTOFF_ISO="$(date -u -v-1d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
      || date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)"
    CUTOFF_NUM="${CUTOFF_ISO//[^0-9]/}"
    for dir in .pipeline/[0-9]*/ .pipeline/exp-*/; do
      [[ -f "$dir/status.json" ]] || continue
      # "Guarded" reuses the phase-5 / completed_at / final_verdict exclusions rather than
      # restating the guard's 15-row phase table, which would be a second vocabulary with no
      # drift test behind it, so the notice is a superset: a run parked in a tripwire state is
      # not guarded but is still reported here.
      grep -q '"completed_at"\|"final_verdict"' "$dir/status.json" 2>/dev/null && continue
      PHASE=$(grep -oE '"current_phase"[[:space:]]*:[[:space:]]*"[^"]*"' "$dir/status.json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
      [[ "$PHASE" == 5-* ]] && continue
      UPDATED=$(grep -oE '"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$dir/status.json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
      # THE DEGRADED PATH IS THE OLD PATH, DELIBERATELY. Two things can make the string compare
      # unavailable: neither `date` dialect produced a cutoff (BSD `-v` and GNU `-d` are both
      # tried), or this record's `updated_at` is absent or is not the UTC-Z shape the compare is
      # exact for. In either case fall back to the mtime approximation rather than to silence:
      # this is a WARNING about a disarmed safety control, so a superset that costs noise beats a
      # subset that costs the announcement. That is also why the fallback is byte-identical to
      # what shipped before -- a degraded run is today's behaviour, never a new one.
      if [[ -n "$CUTOFF_NUM" && "$UPDATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
        UPDATED_NUM="${UPDATED:0:19}"
        UPDATED_NUM="${UPDATED_NUM//[^0-9]/}"
        [[ $((10#$UPDATED_NUM)) -gt $((10#$CUTOFF_NUM)) ]] || continue
      else
        [[ -n "$(find "$dir/status.json" -mtime -1 2>/dev/null)" ]] || continue
      fi
      echo "NOTICE: a pipeline run is in flight and the phase-entry guard (scripts/gate-phase-entry.mjs) is DISARMED because $GATE_DISARM. A turn can end at a phase whose prerequisite was never produced and nothing will refuse it."
      echo ""
      break
    done
  fi
fi

# CUSTOMIZE: if your project wires monitoring / DB / log / docs data sources (via MCP or CLI),
# list them here so the session knows to reach for them on demand. Optionally probe their health.
# Example:
#   echo "Data sources: <your logs backend>, <your database>, <your platform docs>"

# --- Config health ---
# Every knob in this plugin fails SOFT: a missing key takes a default, a misspelled key is
# ignored, a wrong-typed value falls back. That is correct at runtime and it is exactly why a
# broken config is invisible. Report it once, here, where the owner is actually looking.
# Advisory only: a bad config must never wedge a session, so any failure is silent.
DOCTOR="$PLUGIN_ROOT/scripts/config-doctor.mjs"
if [[ -n "$PLUGIN_ROOT" ]] && [[ -f "$DOCTOR" ]] && command -v node >/dev/null 2>&1; then
  CONFIG_REPORT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" node "$DOCTOR" 2>/dev/null)
  [[ -n "$CONFIG_REPORT" ]] && { printf '%s\n' "$CONFIG_REPORT"; echo ""; }
fi

echo "=== Pipeline primitives loaded ==="
echo "  Subagents: ba, dba, devops, secops, dev, qa, design, librarian"
echo "  Commands: /pipeline, /phase, /warmup"
echo '  Schemas: ${CLAUDE_PLUGIN_ROOT}/schemas/*.schema.json'
echo "=== END WARMUP ==="
exit 0
