#!/usr/bin/env bash
# SessionStart hook: prints a warmup report into session context. Fail-open everywhere; it must
# never wedge a session, so nearly every assertion here is about degrading quietly and correctly.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

HOOK="$HOOKS_DIR/session-start.sh"

# run_hook <config-json> -> sets OUT, RC. Repo dir is exported as REPO for per-case setup.
run_hook() {
  local config="${1:-}"
  [[ -n "$config" ]] && printf '%s' "$config" > "$REPO/pipeline.config.json"
  OUT=$(CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" 2>/dev/null)
  RC=$?
}

suite "SessionStart hook: basic report"

REPO=$(make_repo)
run_hook ''
assert_eq "exits 0" "$RC" "0"
assert_contains "emits the warmup banner" "$OUT" "=== AGENT PIPELINE WARMUP ==="
assert_contains "closes the banner" "$OUT" "=== END WARMUP ==="
assert_contains "reports the branch" "$OUT" "Branch:"
assert_contains "reports HEAD" "$OUT" "HEAD:"
assert_contains "lists the subagents" "$OUT" "Subagents: ba, dba"
rm -rf "$REPO"

suite "SessionStart hook: outside a git repo"

REPO=$(mktemp -d)
OUT=$(CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" 2>/dev/null)
assert_eq "stays silent outside a work tree" "$OUT" ""
rm -rf "$REPO"

suite "SessionStart hook: dirty tree and knowledge store"

REPO=$(make_repo)
echo "wip" > "$REPO/uncommitted.txt"
run_hook ''
assert_contains "surfaces uncommitted changes" "$OUT" "uncommitted changes"
assert_contains "names the dirty file" "$OUT" "uncommitted.txt"
rm -rf "$REPO"

REPO=$(make_repo)
mkdir -p "$REPO/knowledge/living-context"
cat > "$REPO/knowledge/living-context/data--widgets.json" <<'JSON'
{"domain":"data","title":"Widget table shape","status":"current","content":"x"}
JSON
cat > "$REPO/knowledge/living-context/data--old.json" <<'JSON'
{"domain":"data","title":"Superseded thing","status":"superseded","content":"x"}
JSON
run_hook ''
assert_contains "lists a current knowledge topic" "$OUT" "Widget table shape"
assert_not_contains "omits superseded topics" "$OUT" "Superseded thing"
rm -rf "$REPO"

suite "SessionStart hook: active pipeline runs"

REPO=$(make_repo)
mkdir -p "$REPO/.pipeline/847" "$REPO/.pipeline/848"
printf '{\n  "current_phase": "3-impl"\n}\n'    > "$REPO/.pipeline/847/status.json"
printf '{\n  "current_phase": "5-archived"\n}\n' > "$REPO/.pipeline/848/status.json"
run_hook ''
assert_contains "lists an in-flight run" "$OUT" "#847"
assert_not_contains "omits a finished run" "$OUT" "#848"
rm -rf "$REPO"

suite "SessionStart hook: config shapes the old grep parser got wrong"

# integrationBranch drives the drift line. A value on its own line did not match the old
# single-line regex, so the report silently measured drift against "main" instead.
REPO=$(make_repo)
run_hook '{
  "integrationBranch":
    "develop"
}'
assert_contains "reads a branch value on its own line" "$OUT" "origin/develop"
rm -rf "$REPO"

# The old regex matched the key anywhere, so a nested key hijacked the value.
REPO=$(make_repo)
run_hook '{"other":{"integrationBranch":"wrong-branch"}}'
assert_not_contains "ignores a nested same-named key" "$OUT" "wrong-branch"
assert_contains "falls back to the documented default" "$OUT" "origin/main"
rm -rf "$REPO"

# knowledgeDir relocates the store; a missed read pointed at the wrong directory.
REPO=$(make_repo)
mkdir -p "$REPO/docs/living-context"
cat > "$REPO/docs/living-context/data--relocated.json" <<'JSON'
{"domain":"data","title":"Relocated store entry","status":"current","content":"x"}
JSON
run_hook '{
  "knowledgeDir":
    "docs"
}'
assert_contains "honors a relocated knowledge dir" "$OUT" "Relocated store entry"
rm -rf "$REPO"

suite "SessionStart hook: malformed config fails OPEN"

REPO=$(make_repo)
run_hook '{"integrationBranch": }'
assert_eq "unparseable JSON still exits 0" "$RC" "0"
assert_contains "still prints the report" "$OUT" "=== AGENT PIPELINE WARMUP ==="
assert_contains "falls back to the default branch" "$OUT" "origin/main"
rm -rf "$REPO"

finish
