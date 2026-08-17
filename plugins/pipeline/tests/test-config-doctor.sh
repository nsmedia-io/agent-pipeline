#!/usr/bin/env bash
# config-doctor.mjs — the session-start check that a project's pipeline.config.json does
# anything at all.
#
# The defect class it exists for: every knob in this plugin fails SOFT. A missing key takes a
# default, a misspelled key is ignored, a wrong-typed value falls back. Correct at runtime, and
# precisely why a broken config is invisible. The plugin shipped an example config carrying the
# bug for real (`migrationsGlob` where the code reads `migrationGlobs`, and a string where it
# requires an array), and the doctor's own self-test found it on its first run.
#
# Two layers, same split as the other script suites:
#   (1) the bundled --self-test, WIRED IN rather than re-implemented;
#   (2) the process contract: what the session-start hook actually prints, and the guarantee
#       that a broken config never wedges a session.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

DOCTOR="$SCRIPTS_DIR/config-doctor.mjs"
HOOK="$PLUGIN_ROOT/hooks/session-start.sh"

make_temp_project 4246 || exit 90
( cd "$TEMP_PROJECT" && git init -q . && git commit -q --allow-empty -m init ) 2>/dev/null

CFG="$TEMP_PROJECT/pipeline.config.json"

# doctor -> OUT (stdout of the script alone)
doctor() { OUT=$(CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$DOCTOR" 2>/dev/null); }
# warmup -> OUT (stdout of the whole session-start hook), RC
warmup() {
  OUT=$(CLAUDE_PROJECT_DIR="$TEMP_PROJECT" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" 2>/dev/null)
  RC=$?
}

# ---------------------------------------------------------------------------
suite "config-doctor: the pure diagnosis (script self-test, wired in not copied)"

SELFTEST_OUT=$(node "$DOCTOR" --self-test 2>&1)
assert_eq "the bundled --self-test passes" "$?" "0"
assert_contains "and it actually ran its cases (16)" "$SELFTEST_OUT" "16 passed"

# The example is shipped, so it is not a fixture: assert against the real file. This is the
# case that caught the live defect, and it is the one that must keep running.
assert_contains "the shipped example declares only real keys" "$SELFTEST_OUT" "none unknown"

# ---------------------------------------------------------------------------
suite "config-doctor: what it tells an owner"

rm -f "$CFG"
doctor
assert_contains "with no config it says so plainly" "$OUT" "No pipeline.config.json"
assert_contains "and names what silently stops working" "$OUT" "verifies NOTHING"
assert_contains "and gives the copy command" "$OUT" "pipeline.config.example.json"

printf '%s' '{"checkCommand":"npm test","migrationsGlob":"db/migrations/**"}' > "$CFG"
doctor
assert_contains "a misspelled key is flagged" "$OUT" "read by nothing"
assert_contains "and the nearest real key is suggested" "$OUT" 'Did you mean "migrationGlobs"'
assert_contains "and it says which script would have read it" "$OUT" "gate-pre-phase4.mjs"

printf '%s' '{"checkCommand":"npm test","migrationGlobs":"db/migrations/**"}' > "$CFG"
doctor
assert_contains "right key, wrong type is flagged" "$OUT" "should be string[] but is string"
assert_contains "and says the value is ignored" "$OUT" "IGNORED"

printf '%s' '{"integrationBranch":"trunk"}' > "$CFG"
doctor
assert_contains "a config with no checkCommand is flagged" "$OUT" "verifies NOTHING"

printf '%s' '{ not valid json' > "$CFG"
doctor
assert_contains "an unparseable config is reported" "$OUT" "not valid JSON"
assert_contains "and warns that everything silently defaults" "$OUT" "falls back to its default"

# CONTROL. A correct config must produce ONE quiet line. Without this every case above would
# only prove the doctor complains about everything it is shown.
printf '%s' '{"checkCommand":"npm test","migrationGlobs":["db/migrations/**"]}' > "$CFG"
doctor
assert_contains "CONTROL: a correct config reports ok" "$OUT" "all keys recognized"
assert_not_contains "CONTROL: and raises no attention banner" "$OUT" "needs attention"

# ---------------------------------------------------------------------------
suite "config-doctor: wired into the session-start warmup"

rm -f "$CFG"
warmup
assert_eq "the warmup still exits 0 with no config" "$RC" "0"
assert_contains "and surfaces the config section" "$OUT" "Config: not configured"
assert_contains "without losing the rest of the warmup" "$OUT" "Pipeline primitives loaded"

printf '%s' '{"checkCommand":"npm test","migrationsGlob":"x/**"}' > "$CFG"
warmup
assert_eq "a broken config never wedges the session (exit 0)" "$RC" "0"
assert_contains "and the misspelling reaches the warmup output" "$OUT" 'Did you mean "migrationGlobs"'
assert_contains "and the warmup still completes" "$OUT" "END WARMUP"

printf '%s' '{ not valid json' > "$CFG"
warmup
assert_eq "an unparseable config never wedges the session (exit 0)" "$RC" "0"
assert_contains "and the warmup still completes" "$OUT" "END WARMUP"

# CONTROL: with a good config the warmup must NOT shout. A startup check that always prints a
# banner is one people learn to scroll past, which is the failure mode that makes it worthless.
printf '%s' '{"checkCommand":"npm test"}' > "$CFG"
warmup
assert_not_contains "CONTROL: a good config raises no banner in the warmup" "$OUT" "needs attention"
assert_not_contains "CONTROL: and no not-configured banner either" "$OUT" "not configured"

finish
