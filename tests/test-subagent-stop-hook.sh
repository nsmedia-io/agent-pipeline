#!/usr/bin/env bash
# SubagentStop hook: passes the validator's decision:block JSON through to Claude Code, and
# fail-opens on every tooling gap. A validation hook that wedges an agent stop is worse than
# one that misses a bad artifact, so the fail-open paths are the ones worth pinning down.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

HOOK="$HOOKS_DIR/subagent-stop.sh"
PAYLOAD='{"hook_event_name":"SubagentStop","session_id":"test"}'

# run_hook <plugin-root> -> sets OUT, RC
run_hook() {
  local root="$1"
  OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$root" bash "$HOOK" 2>/dev/null)
  RC=$?
}

REPO=$(make_repo)

suite "SubagentStop hook: fail-open paths"

run_hook ""
assert_eq "no plugin root exits 0" "$RC" "0"
assert_eq "no plugin root emits nothing" "$OUT" ""

EMPTY=$(mktemp -d)
run_hook "$EMPTY"
assert_eq "absent validator exits 0" "$RC" "0"
assert_eq "absent validator emits nothing" "$OUT" ""
rm -rf "$EMPTY"

# A validator that crashes must not block the stop.
CRASH=$(mktemp -d); mkdir -p "$CRASH/scripts"
printf 'process.exit(1);\n' > "$CRASH/scripts/validate-pipeline-artifact.mjs"
run_hook "$CRASH"
assert_eq "crashing validator exits 0" "$RC" "0"
assert_eq "crashing validator emits nothing" "$OUT" ""
rm -rf "$CRASH"

# A validator that says nothing means the artifact was fine.
SILENT=$(mktemp -d); mkdir -p "$SILENT/scripts"
printf 'process.exit(0);\n' > "$SILENT/scripts/validate-pipeline-artifact.mjs"
run_hook "$SILENT"
assert_eq "silent validator exits 0" "$RC" "0"
assert_eq "silent validator emits nothing" "$OUT" ""
rm -rf "$SILENT"

suite "SubagentStop hook: decision pass-through"

BLOCK=$(mktemp -d); mkdir -p "$BLOCK/scripts"
cat > "$BLOCK/scripts/validate-pipeline-artifact.mjs" <<'MJS'
process.stdout.write(JSON.stringify({ decision: "block", reason: "spec.json failed validation" }));
MJS
run_hook "$BLOCK"
assert_eq "still exits 0 (the JSON carries the decision)" "$RC" "0"
assert_contains "passes the decision through" "$OUT" '"decision":"block"'
assert_contains "passes the reason through" "$OUT" "spec.json failed validation"
rm -rf "$BLOCK"

suite "SubagentStop hook: payload plumbing"

# The hook must forward the stdin payload to the validator, and pass the project dir
# explicitly so the validator can find .pipeline/ regardless of its own cwd.
ECHOER=$(mktemp -d); mkdir -p "$ECHOER/scripts"
cat > "$ECHOER/scripts/validate-pipeline-artifact.mjs" <<'MJS'
let raw = "";
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  process.stdout.write(JSON.stringify({
    sawPayload: raw.includes("SubagentStop"),
    sawProjectDir: !!process.env.CLAUDE_PROJECT_DIR,
  }));
});
MJS
run_hook "$ECHOER"
assert_contains "forwards the stdin payload" "$OUT" '"sawPayload":true'
assert_contains "forwards CLAUDE_PROJECT_DIR" "$OUT" '"sawProjectDir":true'
rm -rf "$ECHOER"

rm -rf "$REPO"
finish
