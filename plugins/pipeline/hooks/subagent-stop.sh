#!/usr/bin/env bash
# SubagentStop hook (agent-pipeline plugin). Validates the stopping agent's just-written
# pipeline artifact against its JSON Schema and emits a decision:block (on stdout) only when an
# artifact exists, was just written, and fails validation. Fail-open in every other case:
# ad-hoc (non-pipeline) agent calls, missing node, no plugin root, absent validator, or a
# validator error. A validation hook must never wedge an agent stop.
#
# The validator (scripts/validate-pipeline-artifact.mjs) reads the hook payload on stdin,
# resolves the ONE active .pipeline/<issue> dir under the project (newest status.json mtime,
# or an explicit active-issue signal in the payload/env if a future orchestrator sets one),
# and prints the decision JSON only on a real failure. Until that script ships in the plugin's
# scripts/ dir, this hook simply no-ops (the -f guard below), which is the safe default.

set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

INPUT=$(cat)

# Never wedge a stop because tooling is absent.
command -v node >/dev/null 2>&1 || exit 0
[[ -n "$PLUGIN_ROOT" ]] || exit 0

VALIDATOR="$PLUGIN_ROOT/scripts/validate-pipeline-artifact.mjs"
[[ -f "$VALIDATOR" ]] || exit 0

# Pass the project dir explicitly so the validator locates the user's .pipeline/ regardless of cwd.
OUT=$(printf '%s' "$INPUT" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" node "$VALIDATOR" 2>/dev/null) || exit 0

# A non-empty payload is the decision:block JSON; pass it through to Claude Code.
[[ -n "$OUT" ]] && printf '%s' "$OUT"
exit 0
