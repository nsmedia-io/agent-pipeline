#!/usr/bin/env bash
# Shared helpers for the agent-pipeline hooks. Sourced, never executed directly.
#
# This file exists because `read_config` was duplicated in stop.sh and session-start.sh and the
# two copies drifted: a parsing bug fixed in one survived in the other. One definition now.

# Read a TOP-LEVEL string key from pipeline.config.json.
#
# Uses node (already required by the plugin's bundled scripts) rather than a grep over JSON.
# The previous regex matched a single-line quoted value ANYWHERE in the file, so three shapes
# went wrong, each silently:
#   - a config formatted with the value on its own line did not match, yielding the default;
#   - a value containing an escaped quote truncated at the escape;
#   - a same-named key NESTED inside another object DID match, so the wrong value was used.
# For stop.sh's `checkCommand` the default is empty, which turns the check gate into a no-op:
# it stops verifying and nothing says so. A control that quietly stops firing is what the
# gate-bites rule exists to catch, so a config that exists but cannot be read now warns on
# stderr instead of degrading in silence.
#
# Fail-OPEN by design: both hooks that call this document fail-open behavior, and a malformed
# config must not wedge a session or block the owner from ending a turn. It warns, returns the
# default, and lets the run proceed.
#
# Usage: read_config <key> [default]
# Requires: PROJECT_DIR set by the caller.
read_config() {
  local key="$1" default="${2:-}" file="$PROJECT_DIR/pipeline.config.json" val="" errfile="" rc=0
  [[ -f "$file" ]] || { printf '%s' "$default"; return; }

  if ! command -v node >/dev/null 2>&1; then
    echo "agent-pipeline: node not found, cannot read $file. Using default for \"$key\"." >&2
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
    echo "agent-pipeline: $file $(head -1 "$errfile" 2>/dev/null). Using default for \"$key\"." >&2
    rm -f "$errfile"
    printf '%s' "$default"
    return
  fi
  rm -f "$errfile"

  [[ -n "$val" ]] && printf '%s' "$val" || printf '%s' "$default"
}
