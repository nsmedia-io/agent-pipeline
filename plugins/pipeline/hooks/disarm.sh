# Shared "a pipeline check did not run" reporter for the agent-pipeline hooks. POSIX sh, no
# shebang: it is SOURCED by stop.sh, subagent-stop.sh and session-start.sh (set DISARM_SOURCED=1
# first), and EXECUTED by hooks.json's PreToolUse fail-open tail as
# `sh disarm.sh <hook> <check> <reason>`.
#
# WHY IT EXISTS. Every hook here fails OPEN on tooling, and that stays: a hook that wedged a
# session over its own missing dependency would be the worse failure. But a fail-open that says
# nothing is indistinguishable from a check that ran and passed, and the hooks used to take
# exactly that shape -- `|| exit 0` on a crashed PreToolUse gate, a Stop hook that skipped the
# phase-entry guard with no node, a voice lint that passed on an unreadable schema. So a check that
# cannot run now does three things and still exits 0:
#
#   1. one line on stderr:  agent-pipeline <hook>: pipeline check <check> did not run: <reason>
#   2. the same sentence as the hook's JSON `systemMessage` on stdout (disarm_flush), which is the
#      channel Claude Code shows to the USER rather than only to the transcript;
#   3. an appended line in the disarm log, which the next session-start warmup reports once and
#      then rotates, so a disarm that happened while nobody was looking is still heard about.
#
# THE LOG LIVES IN THE GIT COMMON DIR (agent-pipeline-disarm.log), not under .pipeline/: it must
# never be committed, it must not create a .pipeline/ directory in a project that has none (the
# SubagentStop validator's silence floor is "no .pipeline directory"), and every worktree of one
# repository should report into the same place. CLAUDE_PIPELINE_DISARM_LOG overrides the path.
# No git dir resolvable means no log line; the stderr line and the systemMessage still happen.
#
# REASONS ARE FIXED VOCABULARY written by the hooks, never payload or record text. The JSON
# escape below handles backslash and double quote so a path in a reason cannot break the object.

DISARM_MSGS=''

disarm_log_path() {
  if [ -n "${CLAUDE_PIPELINE_DISARM_LOG:-}" ]; then
    printf '%s' "$CLAUDE_PIPELINE_DISARM_LOG"
    return 0
  fi
  _dl_dir=${CLAUDE_PROJECT_DIR:-$(pwd)}
  _dl_git=$(git -C "$_dl_dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$_dl_git" ] || return 1
  case $_dl_git in
    /* | [A-Za-z]:/* | [A-Za-z]:\\*) ;;
    *) _dl_git=$_dl_dir/$_dl_git ;;
  esac
  printf '%s/agent-pipeline-disarm.log' "$_dl_git"
}

# disarm_record <hook> <check> <reason>
disarm_record() {
  _dr_line="pipeline check $2 did not run: $3"
  printf 'agent-pipeline %s: %s\n' "$1" "$_dr_line" >&2
  _dr_log=$(disarm_log_path 2>/dev/null) || _dr_log=''
  if [ -n "$_dr_log" ]; then
    printf '%s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" "$1" "$_dr_line" >>"$_dr_log" 2>/dev/null
  fi
  if [ -n "$DISARM_MSGS" ]; then
    DISARM_MSGS="$DISARM_MSGS; $_dr_line"
  else
    DISARM_MSGS=$_dr_line
  fi
  return 0
}

# disarm_flush: print the accumulated sentences as ONE JSON object on stdout, then clear them.
# One object per hook run, because a second object on stdout would make the first unparseable.
disarm_flush() {
  [ -n "$DISARM_MSGS" ] || return 0
  _df_esc=$(printf '%s' "$DISARM_MSGS" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n\t')
  printf '{"systemMessage":"agent-pipeline: %s"}\n' "$_df_esc"
  DISARM_MSGS=''
  return 0
}

# DISARM_NO_JSON=1: the caller may already have written a JSON decision on stdout (pre-tool-use.sh's
# EXIT trap sets it), and a second object would make stdout unparseable. The stderr line and the log
# line still happen; only the systemMessage is withheld.
if [ "${DISARM_SOURCED:-0}" != 1 ] && [ $# -ge 3 ]; then
  disarm_record "$1" "$2" "$3"
  [ "${DISARM_NO_JSON:-0}" = 1 ] || disarm_flush
  exit 0
fi
