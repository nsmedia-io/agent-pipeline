# Shared orphan-reaper runner for the agent-pipeline hooks. POSIX sh, no shebang: SOURCED (never
# executed) by session-start.sh, subagent-stop.sh and stop.sh, after they have sourced disarm.sh.
#
# WHAT IT IS FOR. scripts/reap-orphans.mjs finds, and when it is certain kills, the processes a
# finished sub-agent left running under this session's claude process (docs/rationale.md,
# "Orphaned sub-agent processes"). This file is only the plumbing that keeps each hook fail-open:
#
#   reap_orphans <hook> <event> [payload]
#       <hook>     the name disarm lines carry (SessionStart, SubagentStop, Stop)
#       <event>    passed to the script (it throttles SubagentStop and Stop, never SessionStart)
#       [payload]  the hook's stdin payload, which carries transcript_path. Omit it (SessionStart,
#                  which never consumed its stdin) and the script reads the inherited stdin itself.
#   sets REAP_SUMMARY: one line, empty when nothing was killed or newly reported.
#
# ALWAYS RETURNS 0 AND NEVER PRINTS TO STDOUT, because two of the three callers print one JSON
# object (or a decision) on stdout and a stray line would corrupt it. The caller decides where
# REAP_SUMMARY goes: SessionStart prints it into the warmup context, SubagentStop and Stop append it
# to the disarm accumulator (reap_note) so it leaves as the hook's single systemMessage.
#
# OFF: CLAUDE_PIPELINE_REAPER=off (or orphanReaper.mode "off" in pipeline.config.json, which the
# script reads). With the env var off this returns before any node start.
#
# A TOOLING GAP SAYS SO (the 0.43.0 rule) and still returns 0: node absent, a script that crashed,
# or the process list unreadable (no PowerShell / ps). In a project with a .pipeline directory that
# is a disarm line, so the next warmup reports it; elsewhere it is one stderr line.

REAP_SUMMARY=''

reap_note() {
  [ -n "${1:-}" ] || return 0
  if [ -n "${DISARM_MSGS:-}" ]; then
    DISARM_MSGS="$DISARM_MSGS; $1"
  else
    DISARM_MSGS=$1
  fi
  return 0
}

_reap_gap() { # <hook> <reason>
  if [ -d "${CLAUDE_PROJECT_DIR:-.}/.pipeline" ] && command -v disarm_record >/dev/null 2>&1; then
    disarm_record "$1" "orphan-reaper" "$2"
  else
    printf 'agent-pipeline %s: orphan reaper did not run: %s\n' "$1" "$2" >&2
  fi
  return 0
}

reap_orphans() {
  REAP_SUMMARY=''
  _ro_hook=$1
  _ro_event=$2
  case "${CLAUDE_PIPELINE_REAPER:-}" in
    off | 0 | false | no) return 0 ;;
  esac
  _ro_script=${CLAUDE_PLUGIN_ROOT:-}/scripts/reap-orphans.mjs
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$_ro_script" ] || return 0
  if ! command -v node >/dev/null 2>&1; then
    _reap_gap "$_ro_hook" "node is not on this hook's PATH"
    return 0
  fi
  _ro_err=$(mktemp 2>/dev/null) || _ro_err=''
  if [ "$#" -ge 3 ]; then
    _ro_out=$(printf '%s' "$3" | node "$_ro_script" --event "$_ro_event" 2>"${_ro_err:-/dev/null}")
  else
    _ro_out=$(node "$_ro_script" --event "$_ro_event" 2>"${_ro_err:-/dev/null}")
  fi
  _ro_rc=$?
  _ro_why=''
  if [ -n "$_ro_err" ]; then
    _ro_why=$(sed -n 's/^reap-orphans: disarm: //p' "$_ro_err" | head -n 1 | tr -d '"\\')
    # Config warnings and the like are not a failure, but the owner should be able to see them.
    grep -v '^reap-orphans: disarm: ' "$_ro_err" >&2 2>/dev/null
    rm -f "$_ro_err"
  fi
  case $_ro_rc in
    0) REAP_SUMMARY=$(printf '%s' "$_ro_out" | tr '\r\n\t' '   ') ;;
    3) _reap_gap "$_ro_hook" "${_ro_why:-the process list could not be read}" ;;
    *) _reap_gap "$_ro_hook" "scripts/reap-orphans.mjs exited $_ro_rc" ;;
  esac
  return 0
}
