# PreToolUse hook on Agent, Task and Workflow (agent-pipeline plugin, #163): append one line per
# subagent dispatch to the dispatch log through scripts/dispatch-log.mjs.
#
# POSIX sh and no shebang, for the reason hooks/pre-tool-use.sh gives: hooks.json runs this through
# a shell, and an interpreter line costs a second exec on every call.
#
# OFF BY DEFAULT, AND OFF COSTS NO NODE START. The telemetry switch is CLAUDE_PIPELINE_USAGE_TELEMETRY
# or `usageTelemetry` in pipeline.config.json. With the env var at 0, or unset and no such key in the
# config, this drains stdin and exits 0 without starting node. A config that names the key
# with `enabled: false` pays one node start, which then writes nothing.
#
# NEVER BLOCKS A DISPATCH. Exit 0 always, no decision on stdout. When telemetry is ENABLED and the
# line could not be written (node absent, script absent, script failure, unwritable log), the check
# says so through hooks/disarm.sh, per the 0.43.0 rule: a stderr line, a systemMessage, and a line
# in the disarm log. Disabled telemetry never produces a disarm line.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# Off: drain the payload (one cat, no node) so the writer never sees a closed pipe, then leave.
off() {
  cat >/dev/null 2>&1
  exit 0
}

case "${CLAUDE_PIPELINE_USAGE_TELEMETRY:-}" in
  0 | false) off ;;
  1 | true) ;;
  *)
    [ -f "$PROJECT_DIR/pipeline.config.json" ] || off
    grep -q '"usageTelemetry"' "$PROJECT_DIR/pipeline.config.json" 2>/dev/null || off
    ;;
esac

INPUT=$(cat)

DISARM_LIB="$(dirname "$0")/disarm.sh"
if [ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/hooks/disarm.sh" ]; then
  DISARM_LIB="$PLUGIN_ROOT/hooks/disarm.sh"
fi
if [ -f "$DISARM_LIB" ]; then
  DISARM_SOURCED=1
  . "$DISARM_LIB"
else
  disarm_record() { printf 'agent-pipeline %s: pipeline check %s did not run: %s\n' "$1" "$2" "$3" >&2; }
  disarm_flush() { :; }
fi

not_logged() {
  disarm_record PreToolUse dispatch-log "$1"
  disarm_flush
  exit 0
}

[ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/dispatch-log.mjs"

command -v node >/dev/null 2>&1 || {
  # Config names the key but node is missing: only a disarm if the key actually enables it. Without
  # node that cannot be parsed, so the env var or a literal `"enabled": true` is the evidence.
  case "${CLAUDE_PIPELINE_USAGE_TELEMETRY:-}" in
    1 | true) not_logged "node is not on this hook's PATH, so the dispatch was not logged" ;;
  esac
  grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$PROJECT_DIR/pipeline.config.json" 2>/dev/null &&
    not_logged "node is not on this hook's PATH, so the dispatch was not logged"
  exit 0
}
[ -f "$SCRIPT" ] || not_logged "scripts/dispatch-log.mjs is not installed, so the dispatch was not logged"

ERR=$(printf '%s' "$INPUT" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" node "$SCRIPT" hook 2>&1 >/dev/null)
RC=$?
case $RC in
  0) exit 0 ;;
  3)
    # The script's reason is fixed vocabulary; take only its disarm line and drop quotes.
    REASON=$(printf '%s\n' "$ERR" | sed -n 's/^dispatch-log: disarm: //p' | head -n 1 | tr -d '"\\')
    not_logged "${REASON:-the dispatch log could not be appended}"
    ;;
  *) not_logged "scripts/dispatch-log.mjs exited $RC, so the dispatch was not logged" ;;
esac
