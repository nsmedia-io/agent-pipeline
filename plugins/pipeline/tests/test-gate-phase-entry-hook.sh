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

# (a) node not on PATH. THE CONDITION IS CONSTRUCTED THROUGH THE PATH THE HOOK ACTUALLY RUNS
#     WITH, not the one this file hands it, and the difference between those two is the whole of
#     issue #46.
#
#     stop.sh and session-start.sh both OPEN with an unconditional
#       export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
#     so a PATH= passed on the command line is REBUILT by the hook before `command -v node` ever
#     runs. On ubuntu-latest node is /usr/local/bin/node, so the guard was ARMED in CI: this cell
#     got exit 2 where it expects 0, and -- because it was armed -- AC28(a) below correctly
#     emitted no notice where it expects 1. One cause, both failures. It passed on the author's
#     macOS only because that machine's node lives under ~/.nvm, which is in none of the four
#     prepended dirs. The old precondition measured `command -v node` under the PATH THIS FILE
#     builds, before stop.sh mutated it, so it inspected something other than what acts and
#     reported "absent" while the hook went on to find node three lines later.
#
#     SHADOWING WAS TRIED FIRST AND CANNOT WORK. A `node` planted in an earlier PATH entry does
#     not SUPPRESS a later one: bash's path search skips a non-executable file, a directory and a
#     dangling symlink alike and walks on to the real binary (all three measured, against a
#     control that reports NOTFOUND when the later dir is empty). And a shadow that IS found makes
#     `command -v node` SUCCEED, which arms the guard and lands the run on case (d)'s
#     runs-and-crashes leg -- this cell would go green for the wrong reason and AC28(a) would fail
#     outright. There is no directory this suite can write to that sits ahead of /usr/local/bin.
#
#     So the prepend is DECLINED rather than out-run. BASH_ENV names a file bash sources before
#     the hook body, and that file marks PATH readonly; the hook's own `export PATH=...` then
#     fails (one diagnostic line on stderr, no change of control flow -- these hooks are `set -u`
#     only, and the assignment is a standalone statement) and PATH stays exactly the node-free
#     directory built below. Nothing here doctors an ANSWER: `command -v node` fails because node
#     genuinely is not on the PATH the hook is holding at the moment it asks. That is the property
#     the two rejected alternatives lack -- a stub on PATH and an override of the `command`
#     builtin both leave the real node reachable and only change what the hook is told.
#
#     WHAT THIS CELL STILL DOES NOT PROVE: that an operator whose node sits in one of those four
#     hardcoded dirs can ever present a node-free PATH to these hooks. They cannot, and that is a
#     property of the prepend rather than of the guard. It is #46's sibling half and belongs to
#     whoever owns that posture, not to this fixture.
mk_project "$REFUSING_STATUS" '{"checkCommand":"true"}'
new_tmpdir || exit 90
NO_NODE_HOME="$NEW_TMPDIR"
NO_NODE_BIN="$NO_NODE_HOME/bin"
WITH_NODE_BIN="$NO_NODE_HOME/bin-with-node"
mkdir -p "$NO_NODE_BIN" "$WITH_NODE_BIN"
# THE LIST HAS TO BE COMPLETE NOW, which it did not before. With the system dirs declined these
# two dirs are the hooks' whole world, and a missing tool does not fail loudly: stop.sh exits 0 at
# its is-inside-work-tree line the moment `git` is unreachable, which is the same exit code this
# cell asserts. The WITH_NODE control below is what tells those two apart.
for t in git bash sh cat cut mktemp rm rmdir tail head dirname basename grep sed tr wc find ls sort env; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  ln -sf "$p" "$NO_NODE_BIN/$t"
  ln -sf "$p" "$WITH_NODE_BIN/$t"
done
ln -sf "$(command -v node)" "$WITH_NODE_BIN/node"
DECLINE_PREPEND="$NO_NODE_HOME/decline-path-prepend.sh"
printf 'readonly PATH\n' > "$DECLINE_PREPEND"
# THE COUPLING THIS FIXTURE RESTS ON, pinned rather than left in the prose above. `readonly PATH`
# works because the hook's failed `export PATH=...` is a diagnostic and not a control-flow change,
# which is only true while stop.sh stays `set -u` ONLY. Add -e and the assignment aborts the hook
# before its body, and AC23(a) below plus its rc=2 CONTROL both go red for a reason that has
# nothing to do with the guard.
assert_not_contains "the declined-prepend fixture requires stop.sh to stay set -u only" \
  "$(cat "$HOOK")" "set -e"
NO_NODE_ENV=(BASH_ENV="$DECLINE_PREPEND" HOME="$NO_NODE_HOME" PATH="$NO_NODE_BIN")
WITH_NODE_ENV=(BASH_ENV="$DECLINE_PREPEND" HOME="$NO_NODE_HOME" PATH="$WITH_NODE_BIN")

# THE PRECONDITION IS THE HOOK'S OWN PROLOGUE, cut out of stop.sh at the first line that stops
# touching PATH, so it measures the effective PATH rather than restating how it is built. A
# hand-written copy of the prepend here would be a second vocabulary with no drift test behind it.
# stop.sh's prologue is a superset of session-start.sh's (same four dirs, plus the ~/.nvm entry),
# so node unreachable here is node unreachable there too, and one probe covers both AC23(a) and
# AC28(a).
HOOK_PROLOGUE="$NO_NODE_HOME/hook-prologue-probe.sh"
awk '/^PROJECT_DIR=/{exit} {print}' "$HOOK" > "$HOOK_PROLOGUE"
printf 'command -v node >/dev/null 2>&1 && echo FOUND || echo absent\n' >> "$HOOK_PROLOGUE"
node_on_hook_path() { env "$@" bash "$HOOK_PROLOGUE" 2>/dev/null; }
assert_contains "  precondition: the probe really carries the hook's PATH prepend, or it measures nothing" \
  "$(cat "$HOOK_PROLOGUE")" 'export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"'
assert_eq "  precondition: node is unreachable from the EFFECTIVE PATH stop.sh builds, not the one passed in" \
  "$(node_on_hook_path "${NO_NODE_ENV[@]}")" "absent"
assert_eq "  CONTROL: the same probe says FOUND once node is put back, so 'absent' is a measurement" \
  "$(node_on_hook_path "${WITH_NODE_ENV[@]}")" "FOUND"

# THE DECLINED PREPEND IS LOAD-BEARING, and this is where that is watched rather than asserted.
# On the machine this suite was written on, node lives under ~/.nvm and none of the four hardcoded
# dirs contains it, so the cell below would go green with or without any of the above -- luck
# about one machine's layout, which is precisely how #46 shipped. stop.sh carries a SECOND prepend
# that is reproducible anywhere: point HOME at an nvm layout holding a node and the hook rebuilds
# a PATH that reaches it, the same shape /usr/local/bin/node produced on ubuntu-latest. So the red
# is reproduced here, on purpose, and then shown to turn green on the declined prepend alone --
# same fixture, same hook, same caller PATH, one variable. session-start.sh has no ~/.nvm block,
# so its half of the red is only reproducible where the hardcoded prepend reaches a node; it
# shares the first prepend and this same construction.
new_tmpdir || exit 90
NVM_HOME="$NEW_TMPDIR"
mkdir -p "$NVM_HOME/.nvm/versions/node/v99.0.0/bin"
ln -sf "$(command -v node)" "$NVM_HOME/.nvm/versions/node/v99.0.0/bin/node"
assert_eq "  CONTROL: left alone, the hook's own prepend reaches a node the caller's PATH does not" \
  "$(node_on_hook_path HOME="$NVM_HOME" PATH="$NO_NODE_BIN")" "FOUND"
run_stop "$HOOK" "$HP_ROOT" '' HOME="$NVM_HOME" PATH="$NO_NODE_BIN"
assert_eq "  CONTROL: so the guard is ARMED and refuses -- this is the #46 red, reproduced" "$STOP_RC" "2"
assert_eq "  CONTROL: declining the prepend, and nothing else, makes node unreachable again" \
  "$(node_on_hook_path BASH_ENV="$DECLINE_PREPEND" HOME="$NVM_HOME" PATH="$NO_NODE_BIN")" "absent"
run_stop "$HOOK" "$HP_ROOT" '' BASH_ENV="$DECLINE_PREPEND" HOME="$NVM_HOME" PATH="$NO_NODE_BIN"
assert_eq "  CONTROL: and the same run then exits 0, which is the fix and not the machine" "$STOP_RC" "0"
# NON-ZERO CONTROLS, on the SAME fixture. Without them, "exit 0" is indistinguishable from a
# guard that never runs at all -- which is exactly the state this contract is authored in. The
# FIRST of the two is the one #46 added: it holds the constructed environment fixed and changes
# only node, so it fails if the stripped bin dir is missing anything the hook needs.
run_stop "$HOOK" "$HP_ROOT" '' "${WITH_NODE_ENV[@]}"
assert_eq "  CONTROL: the same fixture in that same stripped env, node restored -> refuses, exit 2" "$STOP_RC" "2"
run_stop "$HOOK" "$HP_ROOT" ''
assert_eq "  CONTROL: this same fixture DOES refuse when the tooling is present" "$STOP_RC" "2"
run_stop "$HOOK" "$HP_ROOT" '' "${NO_NODE_ENV[@]}"
assert_eq "(a) node absent -> exit 0, the guard does not wedge the operator's environment" "$STOP_RC" "0"
# ...and it exited 0 because the guard never RAN, not because it ran and chose to allow. The
# refusal template is the only thing that distinguishes those two from outside.
assert_not_contains "  and it is silent about the phase it did not check" "$(lower "$STOP_ERR")" "cannot end"

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
#
# RE-BASELINED TWICE, each time deliberately, and each reason is recorded because a number
# bumped without one turns this assertion into a rubber stamp.
#
# 41 -> 48 (#27): voice-lint.mjs got the validator's exported ISSUE_DIR_RE, closing the gap
# where an `exp-<slug>` experiment run resolved to no active issue and was therefore never
# voice-checked at all. The +7 is one new suite block ("exp-<slug> runs are LINTED, not
# exempt"): 4 behavioural cases and 3 controls. Nothing existing was removed or renumbered,
# which is the property this cell is actually guarding -- verify that by diffing the suite, not
# by trusting this note.
#
# 48 -> 71 (#53): the same property VERIFIED THE SAME WAY, and it does NOT hold in its pure
# form this time, so it is stated rather than claimed. Diffed by label set (run the suite at
# 13e40e9 and at this commit, strip the ANSI codes, sort the `ok`/`FAIL` labels, `comm`): 26
# labels ADDED, 3 REMOVED, net +23. Each of the three is named here with where its substance
# went, because "removed" and "replaced by something stronger" are the two readings this number
# cannot tell apart:
#   - "every phase pipeline.md writes is accounted for in voice-lint.mjs" was RENAMED, not
#     dropped: it now reads "... in voice-lint.mjs's own tables (SET MEMBERSHIP, never a source
#     grep)". Same subject, same direction; the instrument moved from `grep -q "\"$phase\""`
#     over the source -- which a phase named in a COMMENT satisfies -- to membership over the
#     module's newly exported tables.
#   - "CONTROL: the phase derivation is non-empty (found 26)" was RETIRED into the pinned
#     26-label SET assertion plus the tri-partition's "UNCLASSIFIED is EMPTY". A count floor
#     with the count in its own label is strictly weaker than the set (#33).
#   - "CONTROL: the drift grep can report a miss" was RETIRED WITH ITS INSTRUMENT. Its
#     successor is the discrimination pair over the new one: "with `0-setup` removed from the
#     tables, the accounting names it", the cell asserting the string is still present in the
#     source while that happens, and the injection control that dropping a phase the tables
#     never held moves nothing.
#
# 71 -> 257 (#56): voice-lint's obligation is scoped to the turn that produced the status
# record, and the behavioural contract for it was authored BEFORE the implementation. Verified
# the same way the two re-baselines above were, and this time the property DOES hold in its pure
# form: diffed by label set (run the suite from the parent commit and from this one, strip the
# ANSI codes, sort the `ok`/`FAIL` labels, `comm`) -- 186 labels ADDED, 0 REMOVED, 0 RENAMED.
# Purely additive, so there is no "removed or replaced by something stronger" reading to
# disambiguate here. Re-derive it rather than trusting this note.
#
# THE SISTER ASSERTION BELOW (`with none failing`) IS RED ON PURPOSE AT THE COMMIT THAT ADDS
# THOSE 186, and that is the point rather than an oversight: they are a FAILING behavioural
# contract, authored ahead of the code, and 57 of them are red until the implementation lands.
# This cell is what makes that visible from outside the suite that owns it. If it is still red
# after #56 ships, the fix is incomplete; if it is green with a passed= other than 260, a cell
# was added or removed and the label-set diff above is how to find out which.
#
# 257 -> 260 (#56 Phase 4): the panel's binding QA verdict was REQUEST_CHANGES on a gap the
# implementation battery found and reported rather than closed -- voice-lint's assistant-text
# accept condition (a non-blank JOINED string) had no cell, so paraphrasing it as a non-empty
# ARRAY of text blocks passed all 257 while going SILENT on a transcript whose last assistant
# record carries a whitespace-only text block. Three cells added under the label AC5b: a shape
# PREMISE proving the fixture builds the one input the two conditions disagree on, the
# discriminating pair, and the graded-message assertion. Test-only; no production file changed,
# because the shipped condition was already correct. THIS COUNT IS RE-DERIVED FROM A RUN, never
# incremented by hand -- measured passed=260 failed=0 at the commit that adds it.
#
# 260 -> 267 (#56 Phase 4, the DBA's major): a stat failure on voice-lint's mtime-SCAN branch --
# the branch production actually takes -- drops the candidate, and #56 inverted what dropping
# costs, so a tooling failure that used to refuse loudly against a foreign record now SILENCES the
# refusal on the session's own. Declared as residual (ix) rather than fixed (the loud alternative
# refuses correct work: an unreadable FOREIGN lane's status.json would refuse every message in the
# session), and pinned the AC16(d) way -- assert the documented silence, plus two one-variable
# controls and a reported pre-#56 contrast. SEVEN cells, and the label-set diff is what says that:
# 9 labels added, 2 "removed", and both of those two are the SAME population-report lines carrying
# their own count in the label (95 -> 101 mtime stamps, 81 -> 84 exit codes), re-baselined by the
# three extra lint runs. 0 real removals, 0 renames. THIS COUNT IS RE-DERIVED FROM A RUN, never
# incremented by hand -- measured passed=267 failed=0 at the commit that adds it, and re-derived
# to passed=272 failed=0 at #91, which added five cells (a premise, the tie, its one-millisecond
# twin either side, and a reported measurement) and removed none.
#
# AND THE IRONY, recorded as a pointer rather than acted on here: this cell is a bare exact-count
# pin over another suite's whole population, which is the class #33 retired elsewhere in Lane 1.
# It would be better as a LABEL-SET assertion -- pin the sorted label list, and an addition then
# forces the editor to paste the label while a REMOVAL or a rename reddens by name instead of
# arriving as an unexplained delta that a re-baseline can absorb. CLOSURE IS TRACKED, so this is
# a pointer with a destination rather than a wish: the count-pin re-baseline and the
# label-set successor are recorded in the deferral ledger posted as a comment on issue #53,
# which is where a future reader picks this up. #53 itself only re-baselined the number it
# broke, and deliberately touched nothing else here.
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
assert_eq "test-voice-lint.sh still passes exactly its 272 assertions (41 pre-existing + 7 from #27 + 26 from #53, less 3 retired by #53, + 186 from #56's authored contract, + 3 from #56's Phase-4 gap closure, + 7 from #56's Phase-4 residual (ix) pin, + 5 from #91's turn-boundary tie block -- see the note above)" "${SUITE_PASSED:-<none>}" "272"
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
# Same constructed environment as AC23(a): session-start.sh opens with the same unconditional
# PATH prepend, so a bare PATH= here is rebuilt before line 151's `command -v node` and the notice
# is correctly withheld -- a cell that fails for the guard being ARMED, not for the notice being
# broken.
start_notice "$SESSION_START" "$HP_ROOT" "${NO_NODE_ENV[@]}"
assert_eq "(a) guarded run in flight + node absent -> exactly one notice line" "$NOTICE_N" "1"
# NON-ZERO CONTROL for (a), holding the stripped environment fixed and changing only node: the
# notice has to be a statement about the DISARM rather than about running in a bare environment.
start_notice "$SESSION_START" "$HP_ROOT" "${WITH_NODE_ENV[@]}"
assert_eq "  CONTROL: node restored in that same stripped env -> no notice" "$NOTICE_N" "0"

start_notice "$COPY_ROOT/hooks/session-start.sh" "$HP_ROOT"
assert_eq "(b) guarded run in flight + guard script missing -> exactly one notice line" "$NOTICE_N" "1"

start_notice "$SESSION_START" "$HP_ROOT"
assert_eq "(c) both present -> no notice" "$NOTICE_N" "0"

# (d) The cell a positive-only test omits, and where a notice that ALWAYS fires would hide.
mk_project "$(printf '{"issue_number":4242,"current_phase":"5-archived","risk_tier":"architectural","updated_at":"%s","events":[]}' "$FRESH_ISO")" '{"checkCommand":"true"}'
start_notice "$SESSION_START" "$HP_ROOT" "${NO_NODE_ENV[@]}"
assert_eq "(d) no in-flight GUARDED run -> no notice, even with node absent" "$NOTICE_N" "0"

finish
