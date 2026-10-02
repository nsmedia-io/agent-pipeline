#!/usr/bin/env bash
# The PreToolUse gate refuses two RUNAWAY-COMMAND classes for a subagent (0.49.0):
#
#   python-stdin-heredoc   `python3 - <<'E'` on Windows (the Store-alias stub hangs reading stdin)
#   unbounded-wait-loop    `until ...; do sleep N; done` / `while ...` with no deadline or bound
#
# WHY. A Bash command that outlives the tool's timeout is moved to the background and nothing reaps
# it; a finished sub-agent leaves its background commands running. On the owner's Windows host
# (2026-10-02) one session left five spinning python stubs and four stale wait loops burning CPU
# for a day (docs/rationale.md, "Orphaned sub-agent processes"). scripts/reap-orphans.mjs is the
# second line (test-reap-orphans.sh); this suite is the first.
#
# TWO LAYERS, AND WHY. The classifier (scripts/runaway-commands.mjs) decides; the gate
# (hooks/pre-tool-use.sh) is the plumbing around it. The whole table of commands goes through the
# classifier in ONE node process, because a node start costs seconds on a loaded host and the table
# has dozens of rows; the gate is then driven for real on a representative subset of both
# directions, plus every one of its own behaviours (origin, off switches, fail-open, two-stage).
#
# WHAT IS PINNED, in both directions:
#   - each refused form is DENIED for a subagent, and the deny names the alternative;
#   - the commands that MUST still pass do pass: bounded loops, loops that consume input, a loop
#     written to a file rather than run, python from a file or `-c`, python heredocs on POSIX;
#   - the SAME refused command from the main session is not denied (the gate's origin term);
#   - it is a TWO-STAGE gate: a command that is neither a python heredoc nor a sleep loop starts no
#     node; a candidate starts one, with a non-zero control; and the command text is never on a
#     child's argv or environment;
#   - every tooling gap and every off switch allows the call, with an attribution line.
#
# The gate's entry point is read from hooks.json through the shared fixture driver, like the #106
# suites. The python rule is Windows-only, so the platform is FORCED through
# PIPELINE_RUNAWAY_PLATFORM (operator environment, read by the classifier): the suite then means the
# same on every host.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
require_node

make_temp_project 149 || exit 90
GATE_SCRATCH="$TEMP_PROJECT"
gate_cache_declaration

NOPIPE="$TEMP_PROJECT/no-pipeline"
mkdir -p "$NOPIPE"

# verdict <platform> <command> [payload key=value ...] -> deny|none|...   (through the REAL gate)
verdict() {
  local platform="$1" cmd="$2"; shift 2
  gate_reset_env "$NOPIPE"
  GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=$platform")
  run_gate "$(gate_payload "$cmd" "$@")"
  printf '%s' "$GATE_DECISION"
}
sub()  { verdict "$1" "$2" agent_id=sub-rw-1 agent_type=pipeline:dev; }
main() { verdict "$1" "$2" agent_id=__ABSENT__; }

NL=$'\n'
# An assertion NAME must be one line: the harness's ledger counts lines, so a multi-line command in
# a name makes it count one assertion several times and trips its own count guard.
oneline() { printf '%s' "${1//$NL/ / }"; }

LOOPS=(
  'until grep -q "^exit" /tmp/agent.log; do sleep 10; done'
  'while true; do sleep 5; done'
  'while :; do sleep 5; done'
  'while ! curl -sf localhost:3000; do sleep 1; done; echo up'
  'until curl -sf http://localhost:3000/health; do sleep 2; done'
  'while kill -0 1234 2>/dev/null; do sleep 1; done'
  "bash -c 'until grep -q ready /tmp/a.log; do sleep 2; done'"
  "source ~/.claude/shell-snapshots/s.sh && eval 'until grep -q \"^exit\" /tmp/x.log; do sleep 10; done' < /dev/null"
  "until [ -f /tmp/done ]${NL}do${NL}  sleep 3${NL}done"
  'cd build && until ls out/*.js >/dev/null 2>&1; do sleep 1; done && node out/main.js'
  'while [ ! -s /tmp/result.json ]; do sleep 0.5; done'
  'sleep 1; until grep -q ok log; do usleep 100000; done'
  "bash <<'E'${NL}until grep -q x f; do sleep 1; done${NL}E"
)
PY=(
  "python3 - <<'E'${NL}print(1)${NL}E"
  "python - <<EOF${NL}print(1)${NL}EOF"
  "python3 <<'E'${NL}print(1)${NL}E"
  "cd repo && python3 -u - <<'PY'${NL}print(1)${NL}PY"
  "C:/Python311/python.exe - <<'E'${NL}print(1)${NL}E"
  "python3.12 - <<'E'${NL}print(1)${NL}E"
  "python3 - <<< 'print(1)'"
  "python3 -B - arg1 <<'E'${NL}import sys${NL}E"
)
OK_LOOPS=(
  'timeout 60 bash -c "until grep -q x /tmp/f; do sleep 1; done"'
  'for i in $(seq 1 30); do grep -q x f && break; sleep 2; done'
  'n=0; until grep -q x f; do n=$((n+1)); [ $n -gt 30 ] && break; sleep 2; done'
  'end=$((SECONDS+120)); while [ $SECONDS -lt $end ]; do grep -q x f && break; sleep 1; done'
  'deadline=$(( $(date +%s) + 60 )); until grep -q x f || [ $(date +%s) -gt $deadline ]; do sleep 1; done'
  'while read -r l; do echo "$l"; sleep 1; done < list.txt'
  'while IFS= read -r line; do sleep 1; done < f'
  'while true; do x; sleep 1; if [ -f stop ]; then break; fi; done'
  'until grep -q x f; do sleep 1; [ -f giveup ] && exit 1; done'
  'until grep -q x f; do :; done'
  'sleep 5 && ls'
  'echo "wait until it finishes"; sleep 1'
  "grep -n 'while .*sleep' file.sh"
  'git commit -m "fix: until loop; do sleep"'
  "cat > wait.sh <<'E'${NL}until grep -q x f; do sleep 1; done${NL}E"
  "tee run.sh <<EOF >/dev/null${NL}while true; do sleep 1; done${NL}EOF"
)
OK_PY=(
  "python3 -c 'print(1)'"
  'python3 script.py'
  'python3 -m json.tool < in.json'
  'python3 -m pytest -x'
  'python3 -V'
  'cat in.json | python3 -'
  'python3 - < prog.py'
  "cat <<'E' > f.py${NL}import sys${NL}print(1)${NL}E${NL}python3 f.py"
  'node -e "console.log(1)"'
  "echo 'python3 - <<E'"
)

# ===============================================================================================
suite "THE CLASSIFIER, whole table (one node process): what is refused and what must still pass"
# ===============================================================================================
new_tmpdir || exit 90
ROWS="$NEW_TMPDIR"
SEQ=0
emit_rows() { # <platform> <command>...   writes <seq>.<platform>.cmd, in the order the asserts below read them
  local platform="$1" c; shift
  for c in "$@"; do
    SEQ=$((SEQ + 1))
    printf '%s' "$c" > "$ROWS/$(printf '%04d' "$SEQ").$platform.cmd"
  done
}
emit_rows linux "${LOOPS[@]}"
emit_rows win32 "${PY[@]}"
emit_rows linux "${OK_LOOPS[@]}"
emit_rows win32 "${OK_PY[@]}"
emit_rows linux "python3 - <<'E'${NL}print(1)${NL}E"
emit_rows darwin "python3 - <<'E'${NL}print(1)${NL}E"

cat > "$ROWS/classify.mjs" <<'MJS'
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
const { classifyRunawayCommand } = await import(process.env.CLASSIFIER_MJS);
const dir = process.argv[2];
const out = [];
for (const f of readdirSync(dir).filter((n) => n.endsWith(".cmd")).sort()) {
  const platform = f.split(".")[1];
  const r = classifyRunawayCommand(readFileSync(path.join(dir, f), "utf8"), { platform });
  out.push(`${f.split(".")[0]}=${r ? r.kind : "none"}`);
}
process.stdout.write(out.join("\n") + "\n");
MJS
CLASSIFIER_MJS="$SCRIPTS_DIR/runaway-commands.mjs" node "$ROWS/classify.mjs" "$ROWS" > "$ROWS/verdicts.txt" 2> "$ROWS/classify.err"
assert_eq "the classifier ran over every row with nothing on stderr" "$?:$(cat "$ROWS/classify.err")" "0:"
verdict_of() { awk -v k="$(printf '%04d' "$1")=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$ROWS/verdicts.txt"; }

N=0
for c in "${LOOPS[@]}"; do N=$((N + 1)); assert_eq "REFUSED as a wait loop: $(oneline "$c")" "$(verdict_of $N)" "unbounded-wait-loop"; done
for c in "${PY[@]}"; do N=$((N + 1)); assert_eq "REFUSED as a python stdin heredoc (win32): $(oneline "$c")" "$(verdict_of $N)" "python-stdin-heredoc"; done
for c in "${OK_LOOPS[@]}"; do N=$((N + 1)); assert_eq "MUST STILL PASS: $(oneline "$c")" "$(verdict_of $N)" "none"; done
for c in "${OK_PY[@]}"; do N=$((N + 1)); assert_eq "MUST STILL PASS (win32): $(oneline "$c")" "$(verdict_of $N)" "none"; done
N=$((N + 1)); assert_eq "MUST STILL PASS: the python heredoc on a POSIX host (the stub is a Windows problem)" "$(verdict_of $N)" "none"
N=$((N + 1)); assert_eq "MUST STILL PASS: the python heredoc on macOS" "$(verdict_of $N)" "none"

# ===============================================================================================
suite "THE GATE: a subagent's call is DENIED, a main-session call is not (representative rows, both directions)"
# ===============================================================================================
assert_eq "DENY (subagent): the incident's wait loop" "$(sub linux "${LOOPS[0]}")" "deny"
assert_eq "DENY (subagent): while true; do sleep" "$(sub linux "${LOOPS[1]}")" "deny"
assert_eq "DENY (subagent): the eval-wrapped form the Bash tool actually sends" "$(sub linux "${LOOPS[7]}")" "deny"
assert_eq "DENY (subagent): the multi-line form" "$(sub linux "${LOOPS[8]}")" "deny"
assert_eq "DENY (subagent, win32): the incident's python heredoc" "$(sub win32 "${PY[0]}")" "deny"
assert_eq "DENY (subagent, win32): python <<EOF without the dash" "$(sub win32 "${PY[2]}")" "deny"
assert_eq "ALLOW (subagent): the bounded for-loop" "$(sub linux "${OK_LOOPS[1]}")" "none"
assert_eq "ALLOW (subagent): the same loop under timeout" "$(sub linux "${OK_LOOPS[0]}")" "none"
assert_eq "ALLOW (subagent): a loop in a file that is only written" "$(sub linux "${OK_LOOPS[14]}")" "none"
assert_eq "ALLOW (subagent, win32): python from a file" "$(sub win32 "${OK_PY[1]}")" "none"
assert_eq "ALLOW (subagent, linux): the python heredoc" "$(sub linux "${PY[0]}")" "none"
assert_eq "ALLOW (subagent): an ordinary command" "$(sub linux 'ls -la')" "none"
# The gate's origin term is agent_id. These controls fail if the new rule forgot it.
assert_eq "ALLOW (main session): the incident's wait loop" "$(main linux "${LOOPS[0]}")" "none"
assert_eq "ALLOW (main session): while true; do sleep" "$(main linux "${LOOPS[1]}")" "none"
assert_eq "ALLOW (main session, win32): the python heredoc" "$(main win32 "${PY[0]}")" "none"

# ===============================================================================================
suite "the deny says what was refused, why, and what to do instead; it carries no command text"
# ===============================================================================================
SECRET_MARK="zq-unique-marker-7731"
gate_reset_env "$NOPIPE"
GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=linux")
run_gate "$(gate_payload "until grep -q $SECRET_MARK /tmp/x; do sleep 3; done" agent_id=sub-rw-2 agent_type=pipeline:qa)"
assert_eq "the wait-loop deny is a PreToolUse permissionDecision" "$GATE_DECISION" "deny"
assert_contains "it names the construct" "$GATE_REASON" "unbounded wait loop"
assert_contains "it says WHY: nothing reaps a command moved to the background" "$GATE_REASON" "nothing reaps it"
assert_contains "it names a bounded loop as the alternative" "$GATE_REASON" 'for i in $(seq 1 60)'
assert_contains "it names timeout as the alternative" "$GATE_REASON" "timeout 300 bash -c"
assert_contains "it names the Monitor tool as the alternative" "$GATE_REASON" "Monitor"
assert_not_contains "it carries none of the refused command's text" "$GATE_REASON" "$SECRET_MARK"
assert_not_contains "nor does the attribution line on stderr" "$GATE_ERR" "$SECRET_MARK"
assert_contains "stderr carries the attribution line" "$GATE_ERR" "refused a runaway command for a subagent (unbounded-wait-loop)"
assert_eq "exit 0 always (the decision is the JSON)" "$GATE_RC" "0"

gate_reset_env "$NOPIPE"
GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=win32")
run_gate "$(gate_payload "python3 - <<'E'${NL}print('$SECRET_MARK')${NL}E" agent_id=sub-rw-3 agent_type=pipeline:dev)"
assert_eq "the python deny is a PreToolUse permissionDecision" "$GATE_DECISION" "deny"
assert_contains "it names the Store-alias stub and the spin" "$GATE_REASON" "Store-alias python stub"
assert_contains "it names node -e as the alternative" "$GATE_REASON" "node -e"
assert_contains "it names a script file as the alternative" "$GATE_REASON" "python3 path/to/script.py"
assert_not_contains "it carries none of the refused command's text" "$GATE_REASON" "$SECRET_MARK"
assert_contains "stderr carries the attribution line" "$GATE_ERR" "(python-stdin-heredoc)"

# ===============================================================================================
suite "off switches: the config key and the operator disarm"
# ===============================================================================================
new_tmpdir || exit 90
OFFPROJ="$NEW_TMPDIR"
printf '{"runawayCommandGuard": false}\n' > "$OFFPROJ/pipeline.config.json"
gate_reset_env "$OFFPROJ"
GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=linux")
run_gate "$(gate_payload 'until grep -q x f; do sleep 3; done' agent_id=sub-rw-4 agent_type=pipeline:dev)"
assert_eq "runawayCommandGuard:false lets the loop through" "$GATE_DECISION" "none"
assert_contains "and says so on stderr, so a non-action is diagnosable" "$GATE_ERR" "runawayCommandGuard is false"

printf '{"runawayCommandGuard": true}\n' > "$OFFPROJ/pipeline.config.json"
run_gate "$(gate_payload 'until grep -q x f; do sleep 3; done' agent_id=sub-rw-4 agent_type=pipeline:dev)"
assert_eq "runawayCommandGuard:true still refuses (the key only ever turns it OFF)" "$GATE_DECISION" "deny"

printf '{ this is not json' > "$OFFPROJ/pipeline.config.json"
run_gate "$(gate_payload 'until grep -q x f; do sleep 3; done' agent_id=sub-rw-4 agent_type=pipeline:dev)"
assert_eq "an unreadable config leaves the guard ON (fail toward the refusal, not away from it)" "$GATE_DECISION" "deny"

gate_reset_env "$NOPIPE"
GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=linux" "CLAUDE_HOOK_PRETOOLUSE_SKIP=1")
run_gate "$(gate_payload 'until grep -q x f; do sleep 3; done' agent_id=sub-rw-5 agent_type=pipeline:dev)"
assert_eq "the operator-set disarm that covers the whole gate covers this rule" "$GATE_DECISION" "none"

# ===============================================================================================
suite "FAIL-OPEN: every tooling gap allows the call and says which gap it was"
# ===============================================================================================
LOOP_CMD='until grep -q x f; do sleep 3; done'

# A plugin root that carries the REAL gate (the driver substitutes the root into the hook path too)
# but a chosen state of scripts/: absent, or a classifier that crashes.
fake_root() { # <dir>
  mkdir -p "$1/hooks" "$1/scripts"
  cp "$HOOKS_DIR/pre-tool-use.sh" "$HOOKS_DIR/disarm.sh" "$1/hooks/"
}

# no node on PATH: the current PATH with node's own directory taken out. Symlinking sh into a
# directory instead (what the #106 channel suite does) leaves it unable to load its DLLs under Git
# Bash, so this keeps every other directory and removes only the one node lives in.
NODE_DIR="$(dirname "$(command -v node)")"
NONODE_PATH=""
_ifs="$IFS"; IFS=:
for _d in $PATH; do
  [[ "$_d" == "$NODE_DIR" ]] && continue
  NONODE_PATH="${NONODE_PATH:+$NONODE_PATH:}$_d"
done
IFS="$_ifs"
if PATH="$NONODE_PATH" command -v node >/dev/null 2>&1; then
  record "node is ALSO reachable outside its own directory on this host, so the no-node cell cannot be built here"
  [[ "$CAPABILITY_STRICT" = 1 ]] && assert_eq "a PATH without node can be built (PIPELINE_TESTS_REQUIRE_CAPABILITIES=1)" "no" "yes"
else
  gate_reset_env "$NOPIPE"
  GATE_PATH="$NONODE_PATH"
  GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=linux")
  run_gate_raw "$(gate_payload "$LOOP_CMD" agent_id=sub-rw-6 agent_type=pipeline:dev)"
  assert_eq "no node: exit 0" "$GATE_RC" "0"
  assert_not_contains "no node: no decision on stdout" "$GATE_OUT" "permissionDecision"
  assert_contains "no node: one attribution line says so" "$GATE_ERR" "node is not on PATH, so the runaway-command check could not run"
fi
# the classifier missing from the plugin root
new_tmpdir || exit 90
EMPTYROOT="$NEW_TMPDIR"
fake_root "$EMPTYROOT"
gate_reset_env "$NOPIPE"
GATE_PLUGIN_ROOT_OVERRIDE="$EMPTYROOT"
GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=linux")
run_gate_raw "$(gate_payload "$LOOP_CMD" agent_id=sub-rw-6 agent_type=pipeline:dev)"
assert_eq "no classifier: exit 0" "$GATE_RC" "0"
assert_not_contains "no classifier: no decision" "$GATE_OUT" "permissionDecision"
assert_contains "no classifier: one attribution line says so" "$GATE_ERR" "runaway-command classifier is not present"

# the classifier crashing
new_tmpdir || exit 90
CRASHROOT="$NEW_TMPDIR"
fake_root "$CRASHROOT"
printf 'process.exit(1);\n' > "$CRASHROOT/scripts/runaway-commands.mjs"
gate_reset_env "$NOPIPE"
GATE_PLUGIN_ROOT_OVERRIDE="$CRASHROOT"
GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=linux")
run_gate_raw "$(gate_payload "$LOOP_CMD" agent_id=sub-rw-6 agent_type=pipeline:dev)"
assert_eq "crashing classifier: exit 0" "$GATE_RC" "0"
assert_not_contains "crashing classifier: no decision" "$GATE_OUT" "permissionDecision"
assert_contains "crashing classifier: one attribution line says so" "$GATE_ERR" "runaway-command classifier exited non-zero"

# CLAUDE_PLUGIN_ROOT unset
gate_reset_env "$NOPIPE"
GATE_PLUGIN_ROOT_OVERRIDE="__UNSET__"
GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=linux")
run_gate_raw "$(gate_payload "$LOOP_CMD" agent_id=sub-rw-6 agent_type=pipeline:dev)"
assert_eq "no plugin root: exit 0" "$GATE_RC" "0"
assert_not_contains "no plugin root: no decision" "$GATE_OUT" "permissionDecision"

# ===============================================================================================
suite "TWO STAGES: the fast path starts no node, a candidate starts one, and the command is never on its argv"
# ===============================================================================================
new_tmpdir || exit 90
gate_spy_setup "$NEW_TMPDIR"

gate_reset_env "$NOPIPE"
GATE_PATH="$GATE_SPY_PATH"
GATE_EXTRA_ENV=("PIPELINE_RUNAWAY_PLATFORM=linux")
: > "$GATE_SPY_LOG"
run_gate "$(gate_payload 'ls -la && echo done' agent_id=sub-rw-7 agent_type=pipeline:dev)"
assert_eq "an ordinary subagent command starts no node" "$(gate_spy_invocations)" "0"
run_gate "$(gate_payload 'sleep 5 && ls' agent_id=sub-rw-7 agent_type=pipeline:dev)"
assert_eq "a sleep with no loop starts no node" "$(gate_spy_invocations)" "0"
run_gate "$(gate_payload 'echo while waiting; echo until later' agent_id=sub-rw-7 agent_type=pipeline:dev)"
assert_eq "the words while and until with no sleep: still no node" "$(gate_spy_invocations)" "0"
run_gate "$(gate_payload 'until grep -q x f; do sleep 3; done' agent_id=__ABSENT__)"
assert_eq "the main thread's loop starts no node (the origin reject comes first)" "$(gate_spy_invocations)" "0"

: > "$GATE_SPY_LOG"
run_gate "$(gate_payload "until grep -q $SECRET_MARK f; do sleep 3; done" agent_id=sub-rw-7 agent_type=pipeline:dev)"
assert_eq "NON-ZERO CONTROL: the candidate branch does start node (the shim is on the gate's PATH)" \
  "$([[ "$(gate_spy_invocations)" -ge 1 ]] && echo yes || echo no)" "yes"
assert_eq "and still refuses" "$GATE_DECISION" "deny"
assert_not_contains "the command text is on no child's argv or environment" "$(cat "$GATE_SPY_LOG")" "$SECRET_MARK"

finish
