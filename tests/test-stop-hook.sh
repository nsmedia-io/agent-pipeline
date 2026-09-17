#!/usr/bin/env bash
# Stop hook: blocks turn completion (exit 2) when the project check fails on uncommitted work.
# The gate-bites discipline applies to the gate itself: every case below was recorded failing
# against the pre-fix hook before it was recorded passing against this one.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

HOOK="$HOOKS_DIR/stop.sh"

# run_hook <config-json> [extra-env...] -> sets RC, ERR; leaves a dirty tree by default
run_hook() {
  local config="$1" clean="${2:-dirty}" dir err
  dir=$(make_repo)
  # Commit the config, as a real project would. Left untracked it is itself uncommitted work,
  # which would arm the gate and make the clean-tree case untestable.
  if [[ -n "$config" ]]; then
    printf '%s' "$config" > "$dir/pipeline.config.json"
    git -C "$dir" add -A
    git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m config
  fi
  [[ "$clean" == "dirty" ]] && echo "uncommitted" > "$dir/scratch.txt"
  err=$(mktemp)
  CLAUDE_PROJECT_DIR="$dir" bash "$HOOK" >/dev/null 2>"$err"
  RC=$?
  ERR=$(cat "$err")
  rm -rf "$dir" "$err"
}

suite "Stop hook: gate behavior"

run_hook '{"checkCommand":"true"}'
assert_eq "green check lets the turn end" "$RC" "0"

run_hook '{"checkCommand":"exit 1"}'
assert_eq "failing check blocks the turn" "$RC" "2"
assert_contains "block message names the command" "$ERR" "Command: exit 1"
assert_contains "block message explains itself" "$ERR" "Stop hook blocked completion"

run_hook '{"checkCommand":"echo boom-marker-9f3 && exit 1"}'
assert_contains "check output is fed back to the model" "$ERR" "boom-marker-9f3"

run_hook ''
assert_eq "no config is a no-op" "$RC" "0"

run_hook '{"checkCommand":"exit 1"}' clean
assert_eq "clean tree skips the check entirely" "$RC" "0"

suite "Stop hook: opt-out"

dir=$(make_repo); echo dirty > "$dir/f.txt"; printf '%s' '{"checkCommand":"exit 1"}' > "$dir/pipeline.config.json"
CLAUDE_HOOK_STOP_SKIP=1 CLAUDE_PROJECT_DIR="$dir" bash "$HOOK" >/dev/null 2>&1
assert_eq "CLAUDE_HOOK_STOP_SKIP=1 bypasses the gate" "$?" "0"
rm -rf "$dir"

suite "Stop hook: config shapes the old grep parser got wrong"

# Regression: a value on its own line did not match the single-line regex, so checkCommand
# came back empty and the gate silently stopped firing.
run_hook '{
  "checkCommand":
    "exit 1"
}'
assert_eq "value on its own line still arms the gate" "$RC" "2"

# Regression: the regex truncated at the escaped quote.
run_hook '{"checkCommand":"echo \"quoted\" && exit 1"}'
assert_eq "escaped quote in value still arms the gate" "$RC" "2"

# Regression: the regex matched the key ANYWHERE, so a nested key was executed as the
# project check. Worse than missing a value: it ran the wrong one.
run_hook '{"other":{"checkCommand":"exit 1"}}'
assert_eq "nested same-named key is NOT executed" "$RC" "0"

# Positive control for the above: the top-level key still wins when both are present.
run_hook '{"other":{"checkCommand":"true"},"checkCommand":"exit 1"}'
assert_eq "top-level key wins over a nested one" "$RC" "2"

suite "Stop hook: malformed config fails OPEN, but loudly"

run_hook '{"checkCommand": }'
assert_eq "unparseable JSON does not wedge the turn" "$RC" "0"
assert_contains "unparseable JSON warns on stderr" "$ERR" "is not valid JSON"

run_hook '{"checkCommand":42}'
assert_eq "non-string value does not wedge the turn" "$RC" "0"
assert_contains "non-string value warns on stderr" "$ERR" "non-string value"

run_hook '[1,2,3]'
assert_eq "array at top level does not wedge the turn" "$RC" "0"
assert_contains "array at top level warns on stderr" "$ERR" "top level"

finish
