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
#
# STDERR IS NOT DISCARDED, and that is the fix rather than an oversight (#66 property 2). This
# used to end `2>/dev/null`, which threw away the only channel the validator has for saying what
# it DID. With it discarded, "no rules matched this agent" and "this agent's artifacts are valid"
# reached the operator as the same thing -- 0 bytes of stdout and exit 0 -- and a gate that has
# never fired was indistinguishable from a gate that has never had cause to. Only stdout carries
# the decision, so letting stderr through cannot corrupt the JSON contract below; and the
# validator writes NOTHING at all in a project with no .pipeline dir, so an ad-hoc session pays
# no line. A validator CRASH now also surfaces its trace here instead of vanishing, which is the
# same trade in the same direction: still exit 0, still fail open, but no longer in silence.
OUT=$(printf '%s' "$INPUT" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" node "$VALIDATOR") || exit 0

# A non-empty payload is the decision:block JSON; pass it through to Claude Code.
[[ -n "$OUT" ]] && printf '%s' "$OUT"
exit 0
