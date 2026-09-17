#!/usr/bin/env bash
# scripts/version-check.mjs: the warning a stale plugin install never gave.
#
# The defect: a consumer machine ran hooks from cache/agent-pipeline/pipeline/0.24.0 while
# 0.42.0 was published, and neither the SessionStart hook nor /warmup compared anything. Every
# case below builds a fake Claude Code plugins dir (marketplace clone + cache) in a temp dir,
# so nothing here reads the real ~/.claude. Each warning row has a CONTROL that holds everything
# fixed except the one version that makes the copy stale, and the control must stay silent.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

CHECK="$SCRIPTS_DIR/version-check.mjs"
HOOK="$PLUGIN_ROOT/hooks/session-start.sh"

# fake_plugins <dir> <marketplace-version> <cached-version>... -> a plugins dir shaped like
# Claude Code's: marketplaces/agent-pipeline/{.claude-plugin/marketplace.json,
# plugins/pipeline/.claude-plugin/plugin.json} and cache/agent-pipeline/pipeline/<v>/.
fake_plugins() {
  local dir="$1" mv="$2"; shift 2
  mkdir -p "$dir/marketplaces/agent-pipeline/.claude-plugin" \
           "$dir/marketplaces/agent-pipeline/plugins/pipeline/.claude-plugin"
  printf '{"name":"agent-pipeline","plugins":[{"name":"pipeline","source":"./plugins/pipeline","version":"%s"}]}' "$mv" \
    > "$dir/marketplaces/agent-pipeline/.claude-plugin/marketplace.json"
  printf '{"name":"pipeline","version":"%s"}' "$mv" \
    > "$dir/marketplaces/agent-pipeline/plugins/pipeline/.claude-plugin/plugin.json"
  local v
  for v in "$@"; do
    mkdir -p "$dir/cache/agent-pipeline/pipeline/$v/.claude-plugin"
    printf '{"name":"pipeline","version":"%s"}' "$v" > "$dir/cache/agent-pipeline/pipeline/$v/.claude-plugin/plugin.json"
  done
}

run_check() { OUT=$(node "$CHECK" --plugin-root "$1" --plugins-dir "$2" 2>&1); RC=$?; }

# ---------------------------------------------------------------------------
suite "version-check: the marketplace clone is ahead of the running cache copy"

new_tmpdir || exit 90; P="$NEW_TMPDIR/plugins"
fake_plugins "$P" 0.42.0 0.24.0
run_check "$P/cache/agent-pipeline/pipeline/0.24.0" "$P"
assert_eq "exits 0" "$RC" "0"
assert_contains "warns that the copy is out of date" "$OUT" "PLUGIN OUT OF DATE"
assert_contains "names the running version" "$OUT" "runs pipeline 0.24.0"
assert_contains "names the marketplace version" "$OUT" "marketplace clone has 0.42.0"
assert_contains "names the update command" "$OUT" "/plugin update pipeline@agent-pipeline"
assert_eq "prints exactly one line" "$(printf '%s\n' "$OUT" | grep -c .)" "1"

new_tmpdir || exit 90; P="$NEW_TMPDIR/plugins"
fake_plugins "$P" 0.24.0 0.24.0
run_check "$P/cache/agent-pipeline/pipeline/0.24.0" "$P"
assert_eq "CONTROL: the same layout with the marketplace at the running version is silent" "$OUT" ""

new_tmpdir || exit 90; P="$NEW_TMPDIR/plugins"
fake_plugins "$P" 0.9.0 0.10.0
run_check "$P/cache/agent-pipeline/pipeline/0.10.0" "$P"
assert_eq "CONTROL: versions compare numerically (0.10.0 is newer than 0.9.0, no warning)" "$OUT" ""

# ---------------------------------------------------------------------------
suite "version-check: an older cached copy runs while a newer one is cached"

new_tmpdir || exit 90; P="$NEW_TMPDIR/plugins"
fake_plugins "$P" 0.42.0 0.24.0 0.42.0
run_check "$P/cache/agent-pipeline/pipeline/0.24.0" "$P"
assert_contains "when the marketplace is ahead, a newer copy already in the cache is named too" "$OUT" "0.42.0 is already in the plugin cache"
assert_contains "and names both versions" "$OUT" "runs pipeline 0.24.0"

run_check "$P/cache/agent-pipeline/pipeline/0.42.0" "$P"
assert_eq "CONTROL: running the NEWEST cached copy of that same cache is silent" "$OUT" ""

# An ORPHANED newer cache directory (no newer marketplace entry: a rolled-back install, a local
# build) must not warn: the update command cannot change it, so the line would repeat every session.
new_tmpdir || exit 90; P="$NEW_TMPDIR/plugins"
fake_plugins "$P" 0.24.0 0.24.0 0.42.0
run_check "$P/cache/agent-pipeline/pipeline/0.24.0" "$P"
assert_eq "an orphaned newer cached version with the marketplace at the running version is silent" "$OUT" ""
new_tmpdir || exit 90; P="$NEW_TMPDIR/plugins"
fake_plugins "$P" 0.30.0 0.24.0 0.42.0
run_check "$P/cache/agent-pipeline/pipeline/0.24.0" "$P"
assert_contains "CONTROL: the same orphan with the marketplace ahead of the running copy warns" "$OUT" "PLUGIN OUT OF DATE"
assert_contains "  ...and the update target is the marketplace version, not the orphan" "$OUT" "Update to 0.30.0"

# ---------------------------------------------------------------------------
suite "version-check: what it must not claim"

# A development checkout (not under cache/) says nothing about the cache beside it.
new_tmpdir || exit 90; P="$NEW_TMPDIR/plugins"; DEV="$NEW_TMPDIR/dev/plugins/pipeline"
fake_plugins "$P" 0.24.0 0.24.0 0.99.0
mkdir -p "$DEV/.claude-plugin"; printf '{"name":"pipeline","version":"0.42.0"}' > "$DEV/.claude-plugin/plugin.json"
run_check "$DEV" "$P"
assert_eq "a checkout outside the cache is not compared against other cached copies" "$OUT" ""

run_check "$NEW_TMPDIR/does-not-exist" "$P"
assert_eq "an unreadable plugin root is silent" "$OUT" ""
assert_eq "and exits 0" "$RC" "0"
run_check "$P/cache/agent-pipeline/pipeline/0.24.0" "$NEW_TMPDIR/no-plugins-dir"
assert_eq "an absent plugins dir is silent" "$OUT" ""

new_tmpdir || exit 90; P="$NEW_TMPDIR/plugins"
fake_plugins "$P" 0.24.0 0.24.0
printf '{ not json' > "$P/marketplaces/agent-pipeline/.claude-plugin/marketplace.json"
printf '{ not json' > "$P/marketplaces/agent-pipeline/plugins/pipeline/.claude-plugin/plugin.json"
run_check "$P/cache/agent-pipeline/pipeline/0.24.0" "$P"
assert_eq "an unparseable marketplace manifest is silent, not a crash" "$OUT" ""
assert_eq "and exits 0" "$RC" "0"

# The real plugin root reads its own manifest (not a fixture), so a renamed field would show here.
JSON=$(node "$CHECK" --plugin-root "$PLUGIN_ROOT" --plugins-dir "$NEW_TMPDIR/no-plugins-dir" --json)
assert_contains "the shipped plugin.json is readable by the check" "$JSON" "\"plugin\":\"pipeline\""

# ---------------------------------------------------------------------------
suite "version-check: wired into SessionStart and /warmup"

new_tmpdir || exit 90; P="$NEW_TMPDIR/claude/plugins"; REPO="$NEW_TMPDIR/repo"
fake_plugins "$P" 99.0.0
mkdir -p "$REPO" && git -C "$REPO" init -q && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
OUT=$(CLAUDE_CONFIG_DIR="$NEW_TMPDIR/claude" CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" 2>/dev/null)
assert_contains "the SessionStart report carries the warning" "$OUT" "PLUGIN OUT OF DATE"
assert_contains "naming the marketplace version" "$OUT" "has 99.0.0"

fake_plugins "$P" 0.0.1
OUT=$(CLAUDE_CONFIG_DIR="$NEW_TMPDIR/claude" CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" 2>/dev/null)
assert_not_contains "CONTROL: an older marketplace version adds nothing to the report" "$OUT" "PLUGIN OUT OF DATE"
assert_contains "CONTROL: and the report itself still ran" "$OUT" "=== END WARMUP ==="

assert_contains "/warmup runs the check" "$(cat "$PLUGIN_ROOT/commands/warmup.md")" "scripts/version-check.mjs"

finish
