#!/usr/bin/env bash
# Stop hook (agent-pipeline plugin). When the project defines a check command AND the working
# tree has uncommitted changes, run the check; block completion (exit 2 + stderr) if it fails,
# nudging the model to fix rather than declare the task done. No-op (exit 0) when no check is
# configured. Fail-open on any tooling error.
#
# Deliberately `set -u` only (NOT -e / pipefail): the check's exit code is handled explicitly,
# and an early abort would defeat the block-on-failure behavior.

set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# The app-inherited PATH can carry a stale nvm Node (v16) ahead of everything, breaking
# pnpm-based checks in repos that require modern Node. Prefer the NEWEST installed nvm
# Node explicitly; harmless no-op when nvm is absent.
if [[ -d "$HOME/.nvm/versions/node" ]]; then
  NEWEST_NODE=$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)
  [[ -n "$NEWEST_NODE" ]] && export PATH="$HOME/.nvm/versions/node/$NEWEST_NODE/bin:$PATH"
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Opt-out for one-off iterations.
[[ "${CLAUDE_HOOK_STOP_SKIP:-0}" == "1" ]] && exit 0

# Read a TOP-LEVEL string key from pipeline.config.json.
#
# Uses node (already required by the plugin's bundled scripts) rather than a grep over JSON.
# The previous regex matched a single-line quoted value ANYWHERE in the file, so a
# reformatted config, a value containing an escaped quote, or a same-named key nested inside
# another object all silently yielded the default. For `checkCommand` that default is empty,
# which turns this entire gate into a no-op: the hook stops verifying and nothing says so.
# A control that quietly stops firing is exactly what the gate-bites rule exists to catch,
# so a config that exists but cannot be read now warns on stderr instead of passing silently.
#
# Still fail-OPEN by design (see the header): a malformed config must not permanently wedge
# the owner out of ending a turn. It warns, falls back to the default, and lets the run stop.
read_config() {
  local key="$1" default="${2:-}" file="$PROJECT_DIR/pipeline.config.json" val="" errfile="" rc=0
  [[ -f "$file" ]] || { printf '%s' "$default"; return; }

  if ! command -v node >/dev/null 2>&1; then
    echo "agent-pipeline Stop hook: node not found, cannot read $file. Check gate skipped." >&2
    printf '%s' "$default"
    return
  fi

  errfile=$(mktemp)
  val=$(node -e '
    const fs = require("fs");
    const file = process.argv[1], key = process.argv[2];
    let cfg;
    try {
      cfg = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (e) {
      console.error("is not valid JSON (" + e.message + ")");
      process.exit(3);
    }
    if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) {
      console.error("does not have a JSON object at its top level");
      process.exit(4);
    }
    const v = cfg[key];
    if (v === undefined || v === null) process.exit(0);
    if (typeof v !== "string") {
      console.error("has a non-string value for \"" + key + "\"");
      process.exit(5);
    }
    process.stdout.write(v);
  ' "$file" "$key" 2>"$errfile")
  rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "agent-pipeline Stop hook: $file $(head -1 "$errfile" 2>/dev/null). Check gate skipped." >&2
    rm -f "$errfile"
    printf '%s' "$default"
    return
  fi
  rm -f "$errfile"

  [[ -n "$val" ]] && printf '%s' "$val" || printf '%s' "$default"
}

# CUSTOMIZE: set "checkCommand" in pipeline.config.json to your verify command, e.g.
#   "npm run typecheck && npm test && npm run lint"
# Fallback: if unset but package.json declares a "typecheck" script, run `npm run typecheck`.
# If neither is available, this hook is a no-op.
CHECK="$(read_config checkCommand "")"
if [[ -z "$CHECK" ]]; then
  if [[ -f package.json ]] && grep -q '"typecheck"' package.json 2>/dev/null && command -v npm >/dev/null 2>&1; then
    CHECK="npm run typecheck"
  else
    exit 0
  fi
fi

# Only verify when there is something uncommitted to verify.
[[ -n "$(git status --porcelain 2>/dev/null)" ]] || exit 0

LOG=$(mktemp)
if bash -c "$CHECK" >"$LOG" 2>&1; then
  rm -f "$LOG"
  exit 0
fi

# Check failed: block completion and feed the model the tail of the output.
{
  echo "Stop hook blocked completion: project check failed."
  echo "Command: $CHECK"
  echo "Uncommitted changes require a passing check before stopping."
  echo ""
  echo "--- tail of check output ---"
  tail -30 "$LOG"
  echo "--- end ---"
  echo ""
  echo "To bypass for one-off iterations: CLAUDE_HOOK_STOP_SKIP=1"
} >&2
rm -f "$LOG"
exit 2
