#!/usr/bin/env bash
# The phase-entry guard as WIRED: hooks/stop.sh, hooks/session-start.sh, and the two suites
# that already own this hook.
#
# THE PLACEMENT IS A WINDOW, NOT A FLOOR, AND IT WAS MEASURED. stop.sh has FIVE early exits
# above a natural insertion point, and one UPPER bound:
#
#   TREE GENUINELY CLEAN                        CLEAN + CLAUDE_HOOK_STOP_SKIP=1
#   A above both early exits   exit=2  wanted   A  exit=2  wanted
#   C below CHECK-config exit  exit=2           C  exit=0  disarmed
#   B below clean-tree exit    exit=0  wrong    B  exit=0  disarmed
#   NON-ZERO CONTROL (dirty):  C exit=2, B exit=2
#
# The exit most easily missed is `CHECK` empty -> exit 0: no checkCommand and no package.json
# typecheck script is the ADOPTING-PROJECT DEFAULT, in which stop.sh is already a complete
# no-op before the clean-tree check is ever reached -- and every fixture in
# tests/test-stop-hook.sh sets a checkCommand, so that state is asserted NOWHERE today.
#
# The UPPER bound is silent by nature: stdin is not re-readable, so a guard placed above the
# `PAYLOAD=$(cat)` read consumes it, PAYLOAD comes back empty, and the voice-lint block --
# guarded by its own `[[ -n "$PAYLOAD" ]]` test -- is skipped with no error anywhere. AC26(d)
# reddens under a mutation in the OPPOSITE direction from the other three cells. That is what
# makes this a window.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

HOOK="$HOOKS_DIR/stop.sh"
SESSION_START="$HOOKS_DIR/session-start.sh"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FRESH_ISO="$(node -e 'process.stdout.write(new Date(Date.now()-3600e3).toISOString())')"

# Two token-shaped plants for AC22. NEITHER shares a substring with anything AC21 asserts is
# PRESENT (3-impl, design.json, 4242, SKIPPED, note, /phase, "cannot end", "already done").
# evidence.md's exact-match-twin trap is what that constraint is for: a control added to make
# another control falsifiable can BLIND it.
PLANT_ASK='ghp_zzqqwwxxyyvv99887766'
PLANT_NOTE='sk_live_qqzzwwxxyyvv55443322'

REFUSING_STATUS="$(printf '{"issue_number":4242,"current_phase":"3-impl","risk_tier":"architectural","updated_at":"%s","ask_text":"%s","events":[{"phase":"2-review","verdict":"complete","at":"2026-01-01T00:00:00Z","note":"%s"}]}' \
  "$FRESH_ISO" "$PLANT_ASK" "$PLANT_NOTE")"
GRANTING_STATUS="$(printf '{"issue_number":4242,"current_phase":"4-review-complete","risk_tier":"architectural","updated_at":"%s","events":[]}' "$FRESH_ISO")"

# mk_project <status-json> [config-json] [issue-dir] -> HP_ROOT (a committed, CLEAN git repo)
mk_project() {
  new_tmpdir || exit 90
  HP_ROOT="$NEW_TMPDIR"
  HP_ISSUE="${3:-4242}"
  git -C "$HP_ROOT" init -q
  mkdir -p "$HP_ROOT/.pipeline/$HP_ISSUE"
  printf '%s' "$1" > "$HP_ROOT/.pipeline/$HP_ISSUE/status.json"
  [[ -n "${2:-}" ]] && printf '%s' "$2" > "$HP_ROOT/pipeline.config.json"
  git -C "$HP_ROOT" add -A >/dev/null 2>&1
  git -C "$HP_ROOT" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
}

# The stderr capture file lives OUTSIDE every fixture repo, and that is load-bearing, not
# tidiness. A redirection is set up by the shell BEFORE the command runs, so `2>"$root/..."`
# created an untracked file inside the fixture repo before stop.sh ever started: measured, the
# tree was [] before run_stop and [?? .stop-err.txt] as the hook saw it. AC26(a) asserts the
# guard still refuses on a CLEAN tree, and with the capture file inside the repo that fixture
# was never clean at the moment under test -- the cell could not fail, and a guard gated on a
# dirty tree passed it.
new_tmpdir || exit 90
ERR_DIR="$NEW_TMPDIR"
ERR_SEQ=0

# run_stop <hook-path> <root> <payload> [VAR=VAL ...] -> STOP_RC, STOP_ERR
# stdin is ALWAYS piped: stop.sh reads it when it is not a tty, and leaving it inherited makes
# the result depend on how the suite was launched.
run_stop() {
  local hook="$1" root="$2" payload="$3"; shift 3
  ERR_SEQ=$((ERR_SEQ + 1))
  local errf="$ERR_DIR/stop-err-$ERR_SEQ.txt"
  printf '%s' "$payload" | env "$@" CLAUDE_PROJECT_DIR="$root" bash "$hook" >/dev/null 2>"$errf"
  STOP_RC=$?
  STOP_ERR="$(cat "$errf" 2>/dev/null)"
}

# porcelain <root> -> the working-tree status as ONE line, or `[]` when clean.
porcelain() { printf '[%s]' "$(git -C "$1" status --porcelain 2>/dev/null | tr '\n' ';')"; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------------
suite "AC21: the refusal names four bounded values and both ways out"
# ---------------------------------------------------------------------------
mk_project "$REFUSING_STATUS" '{"checkCommand":"true"}'
run_stop "$HOOK" "$HP_ROOT" ''
assert_eq "a turn cannot END at 3-impl with no design.json: exit 2" "$STOP_RC" "2"
assert_contains "  (i) the message names the current_phase token" "$STOP_ERR" "3-impl"
assert_contains "  (ii) and the prerequisite FILENAME" "$STOP_ERR" "design.json"
assert_contains "  (iii) and the ISSUE DIR, so a sibling-caused wedge is self-diagnosing" "$STOP_ERR" "4242"
assert_contains "  (iv-a) clearance route one: record a SKIPPED events[] entry" "$STOP_ERR" "SKIPPED"
assert_contains "  (iv-a) which costs a written reason" "$STOP_ERR" "note"
assert_contains "  (iv-b) clearance route two names the /phase re-run case" "$STOP_ERR" "/phase"
assert_contains "  (v) and it says the TURN cannot end in this state" "$(lower "$STOP_ERR")" "cannot end"
assert_contains "  (v) and that work already done in this turn is not undone" "$(lower "$STOP_ERR")" "already done"

# ---------------------------------------------------------------------------
suite "AC22: stderr is a FIXED template -- status.json free text is never republished"
# ---------------------------------------------------------------------------
# status.schema.json says outright that ask_text 'must never carry a secret' because the file
# is committed, i.e. the schema already treats it as a field that can receive a pasted token
# before anyone notices. stderr is fed back into the transcript, so echoing it republishes it.
#
# NON-ZERO CONTROL for the two absence assertions: the same substring search, over a haystack
# that DOES contain the plants (stderr plus the record itself). If those two do not fire, the
# absence checks below prove nothing about the template.
HAYSTACK_CONTROL="$STOP_ERR$(cat "$HP_ROOT/.pipeline/4242/status.json")"
assert_contains "CONTROL: the ask_text plant really is in the record being read" "$HAYSTACK_CONTROL" "$PLANT_ASK"
assert_contains "CONTROL: and so is the events[].note plant" "$HAYSTACK_CONTROL" "$PLANT_NOTE"
assert_eq "CONTROL: and the message under test is non-empty" \
  "$([[ -n "$STOP_ERR" ]] && echo nonempty || echo EMPTY)" "nonempty"
assert_not_contains "ask_text is not passed through to stderr" "$STOP_ERR" "$PLANT_ASK"
assert_not_contains "and neither is an events[].note" "$STOP_ERR" "$PLANT_NOTE"

# ---------------------------------------------------------------------------
suite "AC26: the placement WINDOW, four cells, one per bound"
# ---------------------------------------------------------------------------
# (a) A checkpoint commit leaves the tree CLEAN, so a guard below the clean-tree exit never
#     runs at the moment it matters most.
mk_project "$REFUSING_STATUS" '{"checkCommand":"true"}'
assert_eq "  precondition: the fixture tree really is clean BEFORE the hook runs" \
  "$(porcelain "$HP_ROOT")" "[]"
run_stop "$HOOK" "$HP_ROOT" ''
# Both sides of the run, because the defect this brackets was a file created by the harness's
# own redirection at hook-start. stop.sh writes nothing into the project dir (its only temp is
# an mktemp LOG), so clean-before AND clean-after is the tree the hook saw.
assert_eq "  precondition: and STILL clean after it, so the hook's own view was clean" \
  "$(porcelain "$HP_ROOT")" "[]"
assert_eq "(a) clean tree, guard refuses -> exit 2" "$STOP_RC" "2"

# (b) The opt-out bypasses voice-lint and the project check. It must NOT bypass the guard:
#     Q3 rejected a config knob and an env opt-out, and this is the same door.
mk_project "$REFUSING_STATUS" '{"checkCommand":"true"}'
run_stop "$HOOK" "$HP_ROOT" '' CLAUDE_HOOK_STOP_SKIP=1
assert_eq "(b) CLAUDE_HOOK_STOP_SKIP=1, guard refuses -> still exit 2" "$STOP_RC" "2"

# (c) THE ADOPTING-PROJECT DEFAULT, unasserted anywhere in tests/test-stop-hook.sh today: no
#     checkCommand and no package.json typecheck script, in which stop.sh is a total no-op
#     before the clean-tree check is ever reached.
mk_project "$REFUSING_STATUS" ''
assert_eq "  precondition: no pipeline.config.json in the fixture" \
  "$([[ -f "$HP_ROOT/pipeline.config.json" ]] && echo PRESENT || echo absent)" "absent"
assert_eq "  precondition: and no package.json either" \
  "$([[ -f "$HP_ROOT/package.json" ]] && echo PRESENT || echo absent)" "absent"
run_stop "$HOOK" "$HP_ROOT" ''
assert_eq "(c) no check configured at all, guard refuses -> exit 2" "$STOP_RC" "2"

# (d) UPPER BOUND. A guard above the PAYLOAD read consumes stdin, PAYLOAD comes back empty,
#     and voice-lint is skipped by its own emptiness test with no error anywhere. This cell
#     reddens under the OPPOSITE mutation from the three above.
mk_project "$GRANTING_STATUS" '{"checkCommand":"true"}'
printf '{}' > "$HP_ROOT/.pipeline/4242/peer-review.json"     # the granting prerequisite
TRANSCRIPT="$HP_ROOT/transcript.jsonl"
node -e '
  const fs=require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    type:"assistant", message:{content:[{type:"text",
      text:"Done — the panel returned — six blocks merged — nothing else to report."}]}
  })+"\n");
' "$TRANSCRIPT"
run_stop "$HOOK" "$HP_ROOT" "$(printf '{"cwd":"%s","transcript_path":"%s"}' "$HP_ROOT" "$TRANSCRIPT")" \
  CLAUDE_PIPELINE_ACTIVE_ISSUE=4242
assert_contains "(d) with the guard installed and GRANTING, voice-lint still sees the payload" \
  "$STOP_ERR" "full voice mode moment"
assert_eq "  and voice-lint still blocks on its own account" "$STOP_RC" "2"

# ---------------------------------------------------------------------------
suite "AC23: the DECISION is fail-closed; the TOOLING is fail-open"
# ---------------------------------------------------------------------------
# SecOps was invited to reverse this and declined, naming the event and its environment: the
# skip occurs inside the agent session, a missing Node install occurs in the operator's
# environment and is not discretion. A fail-closed-on-tooling control would refuse 100% of
# legitimate stops in every adopting project without Node on the hook's PATH.

# (a) node not on PATH. HOME is redirected too, because stop.sh explicitly prepends the newest
#     nvm Node from $HOME/.nvm; leaving HOME alone would put node back on the PATH it just
#     stripped, and the case would pass while testing nothing.
mk_project "$REFUSING_STATUS" '{"checkCommand":"true"}'
new_tmpdir || exit 90
NO_NODE_HOME="$NEW_TMPDIR"
NO_NODE_BIN="$NO_NODE_HOME/bin"
mkdir -p "$NO_NODE_BIN"
for t in git bash cat mktemp rm tail dirname grep sed; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NO_NODE_BIN/$t"
done
assert_eq "  precondition: node is genuinely unreachable from the stripped PATH+HOME" \
  "$(env -i HOME="$NO_NODE_HOME" PATH="$NO_NODE_BIN" bash -c 'command -v node >/dev/null 2>&1 && echo FOUND || echo absent')" \
  "absent"
# NON-ZERO CONTROL, on the SAME fixture. Without it, "exit 0" is indistinguishable from a
# guard that never runs at all -- which is exactly the state this contract is authored in.
run_stop "$HOOK" "$HP_ROOT" ''
assert_eq "  CONTROL: this same fixture DOES refuse when the tooling is present" "$STOP_RC" "2"
run_stop "$HOOK" "$HP_ROOT" '' HOME="$NO_NODE_HOME" PATH="$NO_NODE_BIN"
assert_eq "(a) node absent -> exit 0, the guard does not wedge the operator's environment" "$STOP_RC" "0"

# (b) the guard script itself missing. A COPY of the plugin, minus the one file.
new_tmpdir || exit 90
COPY_ROOT="$NEW_TMPDIR"
mkdir -p "$COPY_ROOT/hooks" "$COPY_ROOT/scripts"
cp "$HOOKS_DIR"/*.sh "$COPY_ROOT/hooks/" 2>/dev/null
cp "$SCRIPTS_DIR"/*.mjs "$COPY_ROOT/scripts/" 2>/dev/null
rm -f "$COPY_ROOT/scripts/gate-phase-entry.mjs"
assert_eq "  precondition: the copy really is missing the guard" \
  "$([[ -f "$COPY_ROOT/scripts/gate-phase-entry.mjs" ]] && echo PRESENT || echo absent)" "absent"
mk_project "$REFUSING_STATUS" '{"checkCommand":"true"}'
run_stop "$HOOK" "$HP_ROOT" ''
assert_eq "  CONTROL: the SAME fixture refuses through the installed hook, which has the guard" "$STOP_RC" "2"
run_stop "$COPY_ROOT/hooks/stop.sh" "$HP_ROOT" ''
assert_eq "(b) guard script absent -> exit 0" "$STOP_RC" "0"

# (c) a status.json that parses as nothing. R11 covers the TRUNCATED half; R14's write-order
#     convention is what covers the semantically PARTIAL half, which is a different case.
mk_project "$REFUSING_STATUS" '{"checkCommand":"true"}'
run_stop "$HOOK" "$HP_ROOT" ''
assert_eq "  CONTROL: the same phase in a PARSEABLE record refuses" "$STOP_RC" "2"
mk_project '{"current_phase": "3-impl", "events": [' '{"checkCommand":"true"}'
run_stop "$HOOK" "$HP_ROOT" ''
assert_eq "(c) unparseable status.json -> exit 0" "$STOP_RC" "0"

# (d) THE LEG THE OTHER THREE CANNOT REACH: a guard that RUNS and FAILS. (a) is short-circuited
#     by `command -v node`, (b) by the `-f $GATE` test, and (c) exits 0 inside the guard itself,
#     so none of them ever reaches the hook's own exit-code test and none distinguishes "blocks
#     on exactly 2" from "blocks on anything non-zero". A partial install -- scripts/ present
#     but one of the guard's imports missing -- makes node exit 1 with a message on stderr,
#     which is the shape that turns a fail-open contract into a permanent wedge: under
#     `-ne 0` this fixture exits 2, i.e. EVERY turn in EVERY adopting project with a broken
#     install would be unstoppable, and that is the exact failure R11 exists to prevent.
new_tmpdir || exit 90
BROKEN_ROOT="$NEW_TMPDIR"
mkdir -p "$BROKEN_ROOT/hooks" "$BROKEN_ROOT/scripts"
cp "$HOOKS_DIR"/*.sh "$BROKEN_ROOT/hooks/" 2>/dev/null
cp "$SCRIPTS_DIR"/*.mjs "$BROKEN_ROOT/scripts/" 2>/dev/null
rm -f "$BROKEN_ROOT/scripts/lib.mjs"          # an IMPORT of the guard, not the guard itself
assert_eq "  precondition: the guard script is PRESENT in the broken copy (unlike case (b))" \
  "$([[ -f "$BROKEN_ROOT/scripts/gate-phase-entry.mjs" ]] && echo present || echo MISSING)" "present"
assert_eq "  precondition: and one of its imports is genuinely gone" \
  "$([[ -f "$BROKEN_ROOT/scripts/lib.mjs" ]] && echo PRESENT || echo absent)" "absent"
# The leg is only reached if node really runs and really fails NON-ZERO-BUT-NOT-2. Asserted on
# the guard directly, because "the hook exited 0" is otherwise indistinguishable from a guard
# that was skipped before it ever started -- which is what the other three cells do.
BROKEN_ERR="$(node "$BROKEN_ROOT/scripts/gate-phase-entry.mjs" --root "$HP_ROOT" 2>&1 >/dev/null)"
BROKEN_RC=$?
assert_eq "  precondition: the broken guard exits non-zero and NOT 2 (it is a crash, not a refusal)" \
  "$([[ "$BROKEN_RC" -ne 0 && "$BROKEN_RC" -ne 2 ]] && echo "crash($BROKEN_RC)" || echo "UNEXPECTED($BROKEN_RC)")" \
  "crash($BROKEN_RC)"
assert_eq "  precondition: and it printed to stderr, so the hook's -n GATE_ERR test is satisfied too" \
  "$([[ -n "$BROKEN_ERR" ]] && echo nonempty || echo EMPTY)" "nonempty"
mk_project "$REFUSING_STATUS" '{"checkCommand":"true"}'
run_stop "$HOOK" "$HP_ROOT" ''
assert_eq "  CONTROL: the SAME fixture refuses through the intact install" "$STOP_RC" "2"
run_stop "$BROKEN_ROOT/hooks/stop.sh" "$HP_ROOT" ''
assert_eq "(d) a guard that RUNS and CRASHES -> exit 0, because only exit 2 blocks" "$STOP_RC" "0"
assert_eq "  and the crash text is not republished as if it were a refusal" "$STOP_ERR" ""

# ---------------------------------------------------------------------------
suite "AC25: an ordinary developer session in a project that ran a pipeline once"
# ---------------------------------------------------------------------------
new_tmpdir || exit 90
NOPIPE="$NEW_TMPDIR"
git -C "$NOPIPE" init -q
git -C "$NOPIPE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
run_stop "$HOOK" "$NOPIPE" ''
assert_eq "no .pipeline/ at all -> exit 0" "$STOP_RC" "0"
assert_eq "  and the hook says nothing" "$STOP_ERR" ""
# NON-ZERO CONTROL: the same hook, the same invocation, one refusing record added. Silence has
# to be shown to be a CHOICE about this project rather than the hook's only behaviour.
mkdir -p "$NOPIPE/.pipeline/4242"
printf '%s' "$REFUSING_STATUS" > "$NOPIPE/.pipeline/4242/status.json"
printf '%s' '{"checkCommand":"true"}' > "$NOPIPE/pipeline.config.json"
run_stop "$HOOK" "$NOPIPE" ''
assert_eq "  CONTROL: add one refusing record to that same repo and the hook exits 2" "$STOP_RC" "2"

# ---------------------------------------------------------------------------
suite "AC27: the two suites that already own this hook are UNCHANGED consumers"
# ---------------------------------------------------------------------------
# Recorded at f6ba1c4, BEFORE this contract was authored. Exact counts, not just failed=0: a
# suite that silently stopped running half its cases also reports failed=0.
run_suite_counts() {  # <suite-file> -> SUITE_PASSED, SUITE_FAILED
  local out
  out="$(cd "$TESTS_DIR" && bash "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
  SUITE_PASSED="$(printf '%s\n' "$out" | sed -n 's/^passed=\([0-9]*\).*/\1/p' | tail -1)"
  SUITE_FAILED="$(printf '%s\n' "$out" | sed -n 's/^passed=[0-9]* failed=\([0-9]*\).*/\1/p' | tail -1)"
}
run_suite_counts test-stop-hook.sh
assert_eq "test-stop-hook.sh still passes exactly its 18 pre-existing assertions" "${SUITE_PASSED:-<none>}" "18"
assert_eq "  with none failing" "${SUITE_FAILED:-<none>}" "0"
run_suite_counts test-voice-lint.sh
assert_eq "test-voice-lint.sh still passes exactly its 41 pre-existing assertions" "${SUITE_PASSED:-<none>}" "41"
assert_eq "  with none failing" "${SUITE_FAILED:-<none>}" "0"

# ---------------------------------------------------------------------------
suite "AC28: the session-start notice, because a fail-open disarm is otherwise INVISIBLE"
# ---------------------------------------------------------------------------
# A broken Node install disarms the guard identically to a grant, forever, with no signal.
# session-start.sh already runs in the operator's environment and already reads status.json,
# so it is the one place in that environment the plugin already speaks.
NOTICE_ANCHOR="gate-phase-entry"

# start_notice <session-start-path> <root> [VAR=VAL ...] -> NOTICE_N
# Cell (b) runs the COPY of session-start.sh, whose sibling scripts/ dir genuinely has no
# gate-phase-entry.mjs in it. Simulating a missing script with a test-only env knob would add
# exactly the narrowing knob Q3 rejected, and would prove the knob works rather than the check.
start_notice() {
  local hook="$1" root="$2"; shift 2
  local out
  out="$( cd "$root" && env "$@" CLAUDE_PROJECT_DIR="$root" bash "$hook" 2>&1 )"
  NOTICE_N="$(printf '%s\n' "$out" | grep -c "$NOTICE_ANCHOR" | tr -d ' ')"
}

mk_project "$REFUSING_STATUS" '{"checkCommand":"true"}'
start_notice "$SESSION_START" "$HP_ROOT" HOME="$NO_NODE_HOME" PATH="$NO_NODE_BIN"
assert_eq "(a) guarded run in flight + node absent -> exactly one notice line" "$NOTICE_N" "1"

start_notice "$COPY_ROOT/hooks/session-start.sh" "$HP_ROOT"
assert_eq "(b) guarded run in flight + guard script missing -> exactly one notice line" "$NOTICE_N" "1"

start_notice "$SESSION_START" "$HP_ROOT"
assert_eq "(c) both present -> no notice" "$NOTICE_N" "0"

# (d) The cell a positive-only test omits, and where a notice that ALWAYS fires would hide.
mk_project "$(printf '{"issue_number":4242,"current_phase":"5-archived","risk_tier":"architectural","updated_at":"%s","events":[]}' "$FRESH_ISO")" '{"checkCommand":"true"}'
start_notice "$SESSION_START" "$HP_ROOT" HOME="$NO_NODE_HOME" PATH="$NO_NODE_BIN"
assert_eq "(d) no in-flight GUARDED run -> no notice, even with node absent" "$NOTICE_N" "0"

finish
