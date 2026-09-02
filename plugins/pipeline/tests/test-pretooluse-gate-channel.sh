#!/usr/bin/env bash
# #106, part 4 of 5: what comes OUT, and what can turn it off.
#
# AC19 no command strings out, across all FOUR sinks, including the abstention paths
# AC20 attribution: distinct per gap, ON DEMAND, and absent on the non-acting fast path
# AC21 the eight-gap fail-open matrix, each asserted independently, exit 0 in all eight
# AC22 the disarm's literal name appears in NO value-carrying field of the emitted object
# AC23 the disarm's SCOPE, by enumerated class, with the shell observation made and recorded
# AC39 the disarm is TRACEABLE

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
require_node

make_temp_project 106 || exit 90
GATE_SCRATCH="$TEMP_PROJECT"
gate_cache_declaration

# A distinctive high-entropy literal, so a leak cannot be confused with an incidental substring.
SECRET="ZQ7X4KLEAKCANARY9F2WVB"
LEAKY_CMD="git commit -a -m \"chore: $SECRET\""
CLEAN_CMD='git commit -a -m "m"'

P4="$TEMP_PROJECT/p4"; gate_inflight_status "$P4/.pipeline/106/status.json" "4-review"
P_TWO="$TEMP_PROJECT/two"; gate_inflight_status "$P_TWO/.pipeline/39/status.json" "3-impl"; gate_inflight_status "$P_TWO/.pipeline/98/status.json" "4-review"
P_NONE="$TEMP_PROJECT/no-pipeline"; mkdir -p "$P_NONE"

SINK_TMP="$TEMP_PROJECT/sink-tmp"; mkdir -p "$SINK_TMP"
MANIFEST="$TEMP_PROJECT/channel-manifest.json"

# ===============================================================================================
suite "AC21: the eight-gap FAIL-OPEN matrix, each gap asserted independently"
# ===============================================================================================
#
# Every tooling gap and every abstention produces NO deny, and the exit code is 0 in all eight. A
# hook that wedges a tool call over its own missing dependency is worse than one that misses a
# blanket commit -- that is the posture hooks/lib.sh and session-start.sh already take, and this
# gate inherits it.

# The scratch plugin roots the "absent" and "crashing" gaps need. The command template is read out
# of hooks.json, so the RELATIVE path under the plugin root is derived rather than spelled.
GATE_REL="$(gate_declaration_template_cached | awk '{print $1}' | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||')"
record "the declared PreToolUse command, relative to \${CLAUDE_PLUGIN_ROOT}: ${GATE_REL:-<none declared>}"

EMPTY_ROOT="$TEMP_PROJECT/plugin-root-empty"; mkdir -p "$EMPTY_ROOT"
CRASH_ROOT="$TEMP_PROJECT/plugin-root-crashing"
if [[ -n "$GATE_REL" ]]; then
  mkdir -p "$CRASH_ROOT/$(dirname "$GATE_REL")"
  printf '#!/bin/sh\nexit 3\n' > "$CRASH_ROOT/$GATE_REL"
  chmod +x "$CRASH_ROOT/$GATE_REL"
fi

NO_NODE_DIR="$TEMP_PROJECT/no-node-path"; mkdir -p "$NO_NODE_DIR"
for t in sh bash git grep sed awk cat printf env find; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NO_NODE_DIR/$t" 2>/dev/null
done

BAD_JSON_ROOT="$TEMP_PROJECT/status-not-json"
mkdir -p "$BAD_JSON_ROOT/.pipeline/106"; printf '%s' '{ this is not json' > "$BAD_JSON_ROOT/.pipeline/106/status.json"
NO_PHASE_ROOT="$TEMP_PROJECT/status-no-phase"
gate_status "$NO_PHASE_ROOT/.pipeline/106/status.json" current_phase=__ABSENT__ "updated_at=agoms:60000"

# gap <name> ; runs it and leaves GATE_* set. Each gap is its own function call so a failure names
# the gap rather than a line number.
run_gap() {
  case "$1" in
    node-absent)
      gate_reset_env "$P4"; GATE_PATH="$NO_NODE_DIR"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=g1 agent_type=pipeline:qa)" ;;
    plugin-root-unset)
      gate_reset_env "$P4"; GATE_PLUGIN_ROOT_OVERRIDE="__UNSET__"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=g2 agent_type=pipeline:qa)" ;;
    script-absent)
      gate_reset_env "$P4"; GATE_PLUGIN_ROOT_OVERRIDE="$EMPTY_ROOT"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=g3 agent_type=pipeline:qa)" ;;
    script-crashing)
      gate_reset_env "$P4"; GATE_PLUGIN_ROOT_OVERRIDE="$CRASH_ROOT"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=g4 agent_type=pipeline:qa)" ;;
    no-pipeline-anywhere)
      gate_reset_env "$P_NONE"; GATE_PROJECT_DIR="$P_NONE"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=g5 agent_type=pipeline:qa "cwd=$P_NONE")" ;;
    status-not-json)
      gate_reset_env "$BAD_JSON_ROOT"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=g6 agent_type=pipeline:qa)" ;;
    status-no-current-phase)
      gate_reset_env "$NO_PHASE_ROOT"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=g7 agent_type=pipeline:qa)" ;;
    payload-not-json)
      gate_reset_env "$P4"; run_gate '{"hook_event_name":"PreToolUse", "tool_input": { BROKEN' ;;
    ownership-abstention)
      gate_reset_env "$P_TWO"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=g9 agent_type=pipeline:qa)" ;;
    marker-not-honoured)
      gate_reset_env "$P_TWO"; GATE_EXTRA_ENV=("CLAUDE_PIPELINE_ACTIVE_ISSUE=9999"); run_gate "$(gate_payload "$LEAKY_CMD" agent_id=g10 agent_type=pipeline:qa)" ;;
  esac
}

GAPS="node-absent plugin-root-unset script-absent script-crashing no-pipeline-anywhere status-not-json status-no-current-phase payload-not-json"
for g in $GAPS; do
  run_gap "$g"
  assert_eq "AC21 [$g]: no deny" \
    "$([[ "$GATE_DECISION" == "deny" ]] && echo "DENIED" || echo "$GATE_DECISION")" "none"
  assert_eq "AC21 [$g]: exit code 0" "$GATE_RC" "0"
done

# ===============================================================================================
suite "AC19: NO COMMAND STRINGS OUT -- four sinks, denied, escalation, every gap, both abstentions"
# ===============================================================================================
#
# The enumerated sinks are stdout, stderr, ANY file created or appended under any resolved root or
# temp dir, AND the argv and environment of any child process the gate spawns. The fourth arrived
# with R10's two-stage split and is readable by other local users on an adopting host. Project
# authority for the rule: plugins/pipeline/agents/secops.md:125, "Never log secrets, tokens, or
# PII beyond request IDs. User-controlled text is sanitized before logging."
#
# THE ABSTENTION PATHS ARE SINKS TOO. On this repo's own live state they are the highest-frequency
# outputs the gate produces, and round 5 checked them for leakage nowhere.
LEAK_SPY="$TEMP_PROJECT/leak-spy"; gate_spy_setup "$LEAK_SPY"

leak_check() {  # <label> <setup-fn-name-or-inline>: runs, then reports every sink carrying $SECRET
  local label="$1"; shift
  : > "$GATE_SPY_LOG"
  gate_sink_snap "$MANIFEST" "$P4" "$P_TWO" "$SINK_TMP"
  "$@"
  local files stdout_hit stderr_hit file_hit child_hit
  files="$(gate_sink_diff "$MANIFEST" "$P4" "$P_TWO" "$SINK_TMP")"
  stdout_hit=""; stderr_hit=""; file_hit=""; child_hit=""
  [[ "$GATE_OUT"  == *"$SECRET"* ]] && stdout_hit="stdout "
  [[ "$GATE_ERR"  == *"$SECRET"* ]] && stderr_hit="stderr "
  [[ "$files"     == *"$SECRET"* ]] && file_hit="file "
  grep -q "$SECRET" "$GATE_SPY_LOG" 2>/dev/null && child_hit="child-argv-or-env "
  printf '%s' "${stdout_hit}${stderr_hit}${file_hit}${child_hit}"
}

deny_leaky()      { gate_reset_env "$P4";    GATE_TMPDIR="$SINK_TMP"; GATE_PATH="$GATE_SPY_PATH"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=leak agent_type=pipeline:qa)"; }
escalate_leaky()  { deny_leaky; }
abstain_leaky()   { gate_reset_env "$P_TWO"; GATE_TMPDIR="$SINK_TMP"; GATE_PATH="$GATE_SPY_PATH"; run_gate "$(gate_payload "$LEAKY_CMD" agent_id=leak agent_type=pipeline:qa)"; }
marker_leaky()    { gate_reset_env "$P_TWO"; GATE_TMPDIR="$SINK_TMP"; GATE_PATH="$GATE_SPY_PATH"; GATE_EXTRA_ENV=("CLAUDE_PIPELINE_ACTIVE_ISSUE=9999"); run_gate "$(gate_payload "$LEAKY_CMD" agent_id=leak agent_type=pipeline:qa)"; }

assert_eq "AC19 DENIED case: the command literal reaches none of the four sinks" "$(leak_check denied deny_leaky)" ""
# THE NON-ZERO CONTROL FOR THE LEAK CHECK ITSELF: the escalation case must have SPAWNED something,
# or the child-argv sink was never observed and its clean result is a statement about nothing.
escalate_leaky
assert_eq "NON-ZERO CONTROL: the escalation branch really did spawn a child the spy could read" \
  "$([[ "$(gate_spy_invocations)" -ge 1 ]] && echo observed || echo "SAW NO CHILD: the argv/env sink was not actually inspected")" "observed"
assert_eq "AC19 OWNERSHIP ABSTENTION is a sink too: no leak" "$(leak_check abstain abstain_leaky)" ""
assert_eq "AC19 MARKER-NOT-HONOURED ABSTENTION is a sink too: no leak" "$(leak_check marker marker_leaky)" ""
for g in $GAPS; do
  assert_eq "AC19 [$g]: no leak into stdout, stderr, files or child argv/env" "$(leak_check "$g" run_gap "$g")" ""
done

# THE SECRET MUST BE FINDABLE SOMEWHERE, or `grep` found nothing because the fixture never carried
# it. A leak check whose canary was never in the payload is a zero result about the harness.
assert_contains "CANARY CONTROL: the payload the leak check drives really does carry the literal" \
  "$(gate_payload "$LEAKY_CMD" agent_id=leak agent_type=pipeline:qa)" "$SECRET"

# ===============================================================================================
suite "AC20: ATTRIBUTION, distinct per gap, ON DEMAND, and ABSENT on the non-acting fast path"
# ===============================================================================================
#
# "Recoverable afterwards without re-running the session" is read the way an operator would read
# it: the gate's stderr plus any file it wrote under a root the test binds. R15 already enumerates
# those as the gate's sinks, so nothing here invents a channel -- but if the shipped gate persists
# its attribution somewhere outside every root a test can bind, that is a finding for Dev to raise
# with QA rather than a fixture to widen: an attribution a suite cannot reach is one an operator
# cannot reach either.
attribution_for() {  # <gap> -> normalized recovered attribution
  gate_sink_snap "$MANIFEST" "$P4" "$P_TWO" "$SINK_TMP"
  GATE_TMPDIR="$SINK_TMP"
  run_gap "$1"
  printf '%s\n%s\n%s' "$(gate_sink_diff "$MANIFEST" "$P4" "$P_TWO" "$SINK_TMP")" "$GATE_ERR" "$GATE_REASON" \
    | gate_normalize_attribution
}

ALL_GAPS="$GAPS ownership-abstention"
ATTR_SEEN=""
COLLISIONS=""
EMPTY_ATTRS=""
for g in $ALL_GAPS; do
  a="$(attribution_for "$g")"
  if [[ -z "$(printf '%s' "$a" | tr -d '[:space:]')" ]]; then
    EMPTY_ATTRS="$EMPTY_ATTRS $g"
  fi
  # DIGESTED, because an attribution legitimately spans several lines and a line-oriented walk
  # over the raw text reads half an entry and reports no collisions -- a distinctness matrix that
  # cannot see a collision is the thing this row exists to prevent.
  d="$(printf '%s' "$a" | gate_digest)"
  # A collision is reported by NAME, so a failure says which two gaps collapsed rather than
  # printing a count a reader has to interpret.
  while IFS=' ' read -r pg pd; do
    [[ -z "$pg" ]] && continue
    [[ "$pd" == "$d" ]] && COLLISIONS="$COLLISIONS [$pg == $g]"
  done <<< "$ATTR_SEEN"
  ATTR_SEEN="$ATTR_SEEN$g $d
"
done
assert_eq "AC20: every one of the nine gaps produces a NON-EMPTY recoverable attribution" "$EMPTY_ATTRS" ""
assert_eq "AC20: and all nine are mutually DISTINCT (a collision is named, never counted)" "$COLLISIONS" ""

# THE HALVES CLAUSE, and the cheap half is the one that gets dropped: the attribution is available
# ON DEMAND and is NOT emitted unconditionally on the non-acting fast path. A gate that writes on
# every Bash call of every adopting session is the permanent tax R10 exists to refuse, and a
# strictly-more-informative always-emitting fix does not satisfy this.
for fast in 'pnpm exec vitest run' 'ls -la'; do
  gate_sink_snap "$MANIFEST" "$P4" "$SINK_TMP"
  gate_reset_env "$P4"; GATE_TMPDIR="$SINK_TMP"
  run_gate "$(gate_payload "$fast" agent_id=fast agent_type=pipeline:qa)"
  assert_eq "AC20 FAST PATH ['$fast']: no attribution is written (an always-emitting gate is the tax R10 refuses)" \
    "$(gate_sink_count "$MANIFEST" "$P4" "$SINK_TMP")" "0"
done
gate_sink_snap "$MANIFEST" "$P4" "$SINK_TMP"
gate_reset_env "$P4"; GATE_TMPDIR="$SINK_TMP"
run_gate "$(gate_payload "$CLEAN_CMD" agent_id=__ABSENT__)"
assert_eq "AC20 FAST PATH [no agent_id]: no attribution is written" \
  "$(gate_sink_count "$MANIFEST" "$P4" "$SINK_TMP")" "0"

# ===============================================================================================
suite "AC22/AC23/AC39: the DISARM -- documented, channel-clean, operator-only, traceable"
# ===============================================================================================
#
# THE DISARM'S NAME IS DISCOVERED FROM THE OPERATOR README, not spelled here. R17 requires the
# README to carry it in FULL and requires the CLAUDE_HOOK_*_SKIP naming convention, so the README
# is the authority a reader would consult and is therefore the authority the suite consults. This
# also discharges R17's cheap half in the same breath: a fix that satisfies the channel property
# by DELETING the knob from the README fails here rather than passing quietly.
PIPELINE_README="$GATE_PLUGIN_DIR/README.md"
DISARM_CANDIDATES="$(grep -oh 'CLAUDE_HOOK_[A-Z0-9_]*_SKIP' "$PIPELINE_README" 2>/dev/null | sort -u | grep -v '^CLAUDE_HOOK_STOP_SKIP$' | tr '\n' ' ' | sed 's/ *$//')"
record "DISARM discovered from plugins/pipeline/README.md (excluding the already-shipped CLAUDE_HOOK_STOP_SKIP): [${DISARM_CANDIDATES:-none}]"
assert_eq "AC22/R17: the operator README documents EXACTLY ONE new CLAUDE_HOOK_*_SKIP disarm for this gate" \
  "$(printf '%s\n' $DISARM_CANDIDATES | grep -c . | tr -d ' ')" "1"
DISARM="${DISARM_CANDIDATES%% *}"

# R17's carve-out statement must be IN the shipped text: stop.sh:60-63 and README.md:84 carve
# HALTING controls out of this convention, and this gate sits outside that carve-out because it
# fails OPEN by construction. Deleting that statement reddens AC31 as a residual-text check; the
# presence half is asserted here so the two land in different suites and cannot both be edited by
# one hand without noticing.
CARVEOUT_LINES="$(grep -n 'carve-out\|halting control' "$PIPELINE_README" | wc -l | tr -d ' ')"
assert_eq "R17: the README states which side of hooks/stop.sh:60-63's halting-control carve-out this gate sits on, and why" \
  "$([[ "${CARVEOUT_LINES:-0}" -ge 1 ]] && echo states-it || echo "the README never mentions the carve-out this gate must place itself against")" "states-it"
# The two must be on the SAME line: a README that mentions the carve-out in one paragraph and the
# disarm in another has not said which side THIS knob is on, which is the whole of R17's ask.
assert_eq "R17: and it does so on a line that also names this gate's disarm (${DISARM:-<none discovered>})" \
  "$([[ -n "$DISARM" ]] && { grep 'carve-out\|halting control' "$PIPELINE_README" | grep -c "$DISARM" | tr -d ' '; } || echo 0)" \
  "1"

# ---- AC22: the channel property, bound over the WHOLE emitted object --------------------------
#
# THE CHANNEL SET IS RE-DERIVED AGAINST THE VERSION UNDER TEST AND RECORDED, so a genuinely new
# sixth channel surfaces as a red fixture rather than as a silent gap. In 2.1.85 there are FIVE
# value-carrying fields, not four: hookSpecificOutput.permissionDecisionReason, top-level `reason`,
# top-level `systemMessage`, hookSpecificOutput.additionalContext, and
# hookSpecificOutput.updatedInput. (updatedInput does not reach the agent on a deny -- the consumer
# reads permissionDecisionReason || reason || "Blocked by hook" -- but the round-3 spec's tripwire
# sentence was written believing four was the complete set, and it was not.)
record "VALUE-CARRYING CHANNELS in 2.1.85, re-derived and recorded beside the assertion (FIVE): hookSpecificOutput.permissionDecisionReason, reason, systemMessage, hookSpecificOutput.additionalContext, hookSpecificOutput.updatedInput"

FORBIDDEN_TABLE=(
  'git commit -a' 'git commit -am "m"' 'git commit --all' 'git add -A' 'git add --all'
  'git add .' 'git add :/' 'git add -u' 'git add --update' 'git stage -A' 'git stage -u'
)
DISARM_LEAKS=""
NO_ALTERNATIVE=""
for c in "${FORBIDDEN_TABLE[@]}"; do
  gate_reset_env "$P4"
  run_gate "$(gate_payload "$c" agent_id=disarm-chan agent_type=pipeline:qa)"
  WHOLE="$GATE_OUT
$GATE_ERR"
  [[ -n "$DISARM" && "$WHOLE" == *"$DISARM"* ]] && DISARM_LEAKS="$DISARM_LEAKS [$c]"
  # The EXPLICIT-PATH ALTERNATIVE must be present in the field the consumer renders. Asserted as
  # a property of the rendered reason, so a gate that denies without telling the agent what to do
  # instead does not pass.
  case "$GATE_REASON" in
    *"explicit path"*|*"explicit paths"*|*"git add <path>"*|*"stage explicit"*) : ;;
    *) NO_ALTERNATIVE="$NO_ALTERNATIVE [$c -> ${GATE_REASON:0:60}]" ;;
  esac
done
assert_eq "AC22: over the WHOLE forbidden table, the disarm's literal name appears in NEITHER stdout NOR stderr (bound on the whole object, which is the class)" \
  "$DISARM_LEAKS" ""
assert_eq "AC22: while the EXPLICIT-PATH alternative IS present in the field the consumer renders" \
  "$NO_ALTERNATIVE" ""

# ---- AC23: SCOPE, by enumerated class, with the shell observation MADE ------------------------
#
# FIRST, OBSERVE and RECORD which shell executes the hooks.json command and which startup files it
# reads non-interactively. That answer is a property of the runtime rather than of this repo, so
# it is derived at test time and recorded rather than guessed in the spec.
HOOK_SHELL="$(command -v sh)"
HOOK_SHELL_REAL="$(cd "$(dirname "$(readlink "$HOOK_SHELL" 2>/dev/null || printf '%s' "$HOOK_SHELL")")" && pwd)/$(basename "$(readlink "$HOOK_SHELL" 2>/dev/null || printf '%s' "$HOOK_SHELL")")"
record "OBSERVATION (\`command -v sh\`): the hooks.json command is executed through $HOOK_SHELL -> $HOOK_SHELL_REAL on $(uname -sr)"
STARTUP_PROBE="$TEMP_PROJECT/startup-probe"; mkdir -p "$STARTUP_PROBE"
printf 'PROBE_STARTUP_FILE_WAS_READ=yes\nexport PROBE_STARTUP_FILE_WAS_READ\n' > "$STARTUP_PROBE/envfile"
SH_READS_ENV="$(ENV="$STARTUP_PROBE/envfile" "$HOOK_SHELL" -c 'printf "%s" "${PROBE_STARTUP_FILE_WAS_READ:-no}"' 2>/dev/null)"
ZSHENV_READ="no"
if command -v zsh >/dev/null 2>&1; then ZSHENV_READ="zsh-present(~/.zshenv is read non-interactively)"; fi
record "OBSERVATION (non-interactive startup files): \$ENV honoured by this sh = $SH_READS_ENV; zsh on PATH = $ZSHENV_READ"

# For each class of one-tool-call set-step, perform it and replay the BYTE-IDENTICAL denied
# payload; the deny must PERSIST. If it does NOT for some class, that is the finding and the
# disarm moves to a channel the denied agent cannot reach in one call.
DENIED_PAYLOAD="$(gate_payload "$CLEAN_CMD" agent_id=scope agent_type=pipeline:qa)"
gate_reset_env "$P4"; run_gate "$DENIED_PAYLOAD"
assert_eq "AC23 PRECONDITION: the byte-identical payload IS denied before any set-step" "$GATE_DECISION" "deny"

ESCAPES=""
# class (a): a file write under a resolved root -- the routine shard write AC8 exists to permit.
mkdir -p "$P4/.pipeline/106"
printf '%s=1\n' "${DISARM:-CLAUDE_HOOK_UNKNOWN_SKIP}" > "$P4/.pipeline/106/$( [[ -n "$DISARM" ]] && printf '%s' "$DISARM" || printf 'DISARM' ).env"
printf '{"%s":1}\n' "${DISARM:-CLAUDE_HOOK_UNKNOWN_SKIP}" > "$P4/.pipeline/106/peer-review.qa.json"
gate_reset_env "$P4"; run_gate "$DENIED_PAYLOAD"
[[ "$GATE_DECISION" == "deny" ]] || ESCAPES="$ESCAPES [file-write-under-a-resolved-root]"
assert_eq "AC23 class (a) file write under a resolved root: the deny PERSISTS" "$GATE_DECISION" "deny"

# class (b): pipeline.config.json.
printf '{"%s": 1, "checkCommand": "true"}\n' "${DISARM:-CLAUDE_HOOK_UNKNOWN_SKIP}" > "$P4/pipeline.config.json"
gate_reset_env "$P4"; run_gate "$DENIED_PAYLOAD"
[[ "$GATE_DECISION" == "deny" ]] || ESCAPES="$ESCAPES [pipeline.config.json]"
assert_eq "AC23 class (b) pipeline.config.json: the deny PERSISTS" "$GATE_DECISION" "deny"

# class (c): the hook's own invocation environment, through an observed non-interactive startup
# file of the shell that executes the hooks.json command.
printf '%s=1\nexport %s\n' "${DISARM:-CLAUDE_HOOK_UNKNOWN_SKIP}" "${DISARM:-CLAUDE_HOOK_UNKNOWN_SKIP}" > "$STARTUP_PROBE/envfile"
gate_reset_env "$P4"; GATE_EXTRA_ENV=("ENV=$STARTUP_PROBE/envfile")
run_gate "$DENIED_PAYLOAD"
[[ "$GATE_DECISION" == "deny" ]] || ESCAPES="$ESCAPES [shell-startup-file:\$ENV]"
assert_eq "AC23 class (c) an observed shell startup file (\$ENV, honoured=$SH_READS_ENV): the deny PERSISTS" \
  "$GATE_DECISION" "deny"

assert_eq "AC23: NO enumerated one-tool-call class reaches the disarm (an escape here is the finding, and the disarm must move channel)" \
  "$ESCAPES" ""

# ...AND THE OPERATOR-SET DISARM DOES WORK. Without this the three rows above are satisfied by a
# disarm that does not exist: "the deny persists" is trivially true of a knob nothing reads.
gate_reset_env "$P4"; GATE_EXTRA_ENV=("${DISARM:-CLAUDE_HOOK_UNKNOWN_SKIP}=1")
run_gate "$DENIED_PAYLOAD"
assert_eq "AC23 NON-ZERO CONTROL: with the disarm OPERATOR-SET in the hook's own environment, the same payload is NOT denied" \
  "$GATE_DECISION" "none"

# ---- AC39: the disarm is TRACEABLE ------------------------------------------------------------
#
# stop.sh:60-63 refuses a suppression that leaves no trace in the archived run record. This gate
# sits outside that carve-out (it is a ratchet that fails OPEN, not a halting control), but the
# carve-out's REASON binds regardless of which side of it the gate is on.
gate_sink_snap "$MANIFEST" "$P4" "$SINK_TMP"
gate_reset_env "$P4"; GATE_TMPDIR="$SINK_TMP"; GATE_EXTRA_ENV=("${DISARM:-CLAUDE_HOOK_UNKNOWN_SKIP}=1")
run_gate "$DENIED_PAYLOAD"
ATTR_DISARM="$(printf '%s\n%s' "$(gate_sink_diff "$MANIFEST" "$P4" "$SINK_TMP")" "$GATE_ERR" | gate_normalize_attribution)"
assert_eq "AC39: operating the disarm produces its own recoverable attribution, non-empty" \
  "$([[ -n "$(printf '%s' "$ATTR_DISARM" | tr -d '[:space:]')" ]] && echo non-empty || echo "EMPTY: the suppression left no trace")" "non-empty"
DISARM_DIGEST="$(printf '%s' "$ATTR_DISARM" | gate_digest)"
DISARM_COLLIDES=""
while IFS=' ' read -r pg pd; do
  [[ -z "$pg" ]] && continue
  [[ "$pd" == "$DISARM_DIGEST" ]] && DISARM_COLLIDES="$DISARM_COLLIDES [$pg]"
done <<< "$ATTR_SEEN"
assert_eq "AC39: and it equals NONE of the nine AC20 enumerates" "$DISARM_COLLIDES" ""
assert_not_contains "AC39: and the disarm's own name still does not appear on stderr" "$GATE_ERR" "${DISARM:-CLAUDE_HOOK_UNKNOWN_SKIP}"

finish
