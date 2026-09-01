#!/usr/bin/env bash
# Shared driver for the five #106 PreToolUse-gate suites. SOURCED, never run: it lives under
# fixtures/ so run.sh's flat `test-*.sh` glob does not pick it up as a suite (the placement rule
# test-issue17-integration.sh pins).
#
# ---------------------------------------------------------------------------------------------
# THE ENTRY POINT IS DERIVED FROM hooks.json, NOT SPELLED HERE.
#
# The runtime learns where the hook lives by reading hooks/hooks.json and substituting
# ${CLAUDE_PLUGIN_ROOT}. The suite does the same. That is the difference between testing the
# BEHAVIOUR ("a Bash tool call in this state is denied") and testing an implementation shape
# ("the file scripts/foo.sh returns this") -- and it is load-bearing twice over:
#
#   * QA authors this contract before the implementation exists, so no filename is knowable here
#     without inventing one and forcing Dev to match it;
#   * a gate that exists on disk but is not DECLARED enforces nothing, and a suite that invoked
#     the script directly would be green on exactly that defect. #106 is an issue about a rule
#     nobody reads; a test that reads the script rather than the declaration repeats it.
#
# When hooks.json declares no PreToolUse entry -- which is the state at the reviewed commit --
# every driver call returns the sentinel GATE-UNDECLARED. That is deliberate and is rule 9 of the
# test-discipline standard: each test then FAILS on its own, with "expected deny, actual
# GATE-UNDECLARED", rather than N tests collapsing into N skips behind one setup throw.
# ---------------------------------------------------------------------------------------------

GATE_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_TESTS_DIR="$(cd "$GATE_FIXTURES_DIR/.." && pwd)"
GATE_PLUGIN_DIR="$(cd "$GATE_TESTS_DIR/.." && pwd)"
GATE_REPO_ROOT="$(cd "$GATE_PLUGIN_DIR/../.." && pwd)"
GATE_HOOKS_JSON="$GATE_PLUGIN_DIR/hooks/hooks.json"
GATE_PIPELINE_MD="$GATE_PLUGIN_DIR/commands/pipeline.md"

PAYLOAD_MJS="$GATE_FIXTURES_DIR/pretooluse-payload.mjs"
STATUS_MJS="$GATE_FIXTURES_DIR/pretooluse-status.mjs"
DECISION_MJS="$GATE_FIXTURES_DIR/pretooluse-decision.mjs"
SINK_MJS="$GATE_FIXTURES_DIR/pretooluse-sink.mjs"

# The real node, resolved ONCE before any shim goes on PATH, so the shim can exec it and so the
# suite's own helper calls never go through the spy.
GATE_REAL_NODE="$(command -v node 2>/dev/null || true)"

# ---- reading the declaration -----------------------------------------------------------------

# gate_hook_field <jq-ish path> -> prints the value, or the empty string.
# Implemented in node rather than with grep so "the file parses as JSON" (AC1) is answered by an
# actual parse and not by a pattern that a broken file could still satisfy.
gate_hook_probe() {  # <expr over the parsed hooks.json, as `h`>
  [[ -n "$GATE_REAL_NODE" ]] || { printf ''; return 0; }
  "$GATE_REAL_NODE" -e '
    const fs = require("node:fs");
    let h;
    try { h = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.stdout.write("PARSE-ERROR"); process.exit(0); }
    let v;
    try { v = (function (h) { return eval(process.argv[2]); })(h); } catch { v = undefined; }
    process.stdout.write(v === undefined || v === null ? "" : String(v));
  ' "$GATE_HOOKS_JSON" "$1" 2>/dev/null
}

# The first PreToolUse command template, verbatim (with ${CLAUDE_PLUGIN_ROOT} unexpanded).
gate_command_template() {
  gate_hook_probe '(h.hooks && h.hooks.PreToolUse && h.hooks.PreToolUse[0] && h.hooks.PreToolUse[0].hooks && h.hooks.PreToolUse[0].hooks[0] || {}).command'
}

gate_declared_timeout() {
  gate_hook_probe '(h.hooks && h.hooks.PreToolUse && h.hooks.PreToolUse[0] && h.hooks.PreToolUse[0].hooks && h.hooks.PreToolUse[0].hooks[0] || {}).timeout'
}

gate_declared_matcher() {
  gate_hook_probe 'JSON.stringify((h.hooks && h.hooks.PreToolUse && h.hooks.PreToolUse[0] || {}).matcher)'
}

# gate_resolved_command [plugin-root] -> the command with ${CLAUDE_PLUGIN_ROOT} substituted,
# or the empty string when nothing is declared.
gate_resolved_command() {
  local root="${1:-$GATE_PLUGIN_DIR}" tpl
  tpl="$(gate_command_template)"
  [[ -n "$tpl" && "$tpl" != "PARSE-ERROR" ]] || { printf ''; return 0; }
  printf '%s' "${tpl//\$\{CLAUDE_PLUGIN_ROOT\}/$root}"
}

gate_is_declared() {
  local c
  c="$(gate_command_template)"
  [[ -n "$c" && "$c" != "PARSE-ERROR" ]]
}

# ---- the declaration is read ONCE, like the runtime reads it -----------------------------------
#
# NOT AN OPTIMISATION, A MEASUREMENT CORRECTNESS FIX. Re-probing hooks.json per call put a node
# start inside AC18's measured loop, and the first draft of this suite duly measured 78 ms/call
# for a gate that does not exist yet: the figure was the SUITE's node probe, not the gate. The
# runtime resolves the hooks.json command once at load and then executes the string, so the
# driver does the same, and the cache is refreshed explicitly by a case that edits hooks.json.
GATE_DECL_CACHED=""
GATE_DECL_TPL=""
gate_cache_declaration() {
  GATE_DECL_TPL="$(gate_command_template)"
  [[ "$GATE_DECL_TPL" == "PARSE-ERROR" ]] && GATE_DECL_TPL=""
  GATE_DECL_CACHED="yes"
}
gate_declaration_template_cached() {
  [[ -n "$GATE_DECL_CACHED" ]] || gate_cache_declaration
  printf '%s' "$GATE_DECL_TPL"
}

# ---- driving the gate ------------------------------------------------------------------------
#
# Every knob a case needs is a GLOBAL set before the call, because the harness's assertion ledger
# refuses assertions evaluated inside a subshell: the driver must therefore run the child in a
# subshell and hand its results BACK through globals, so the assert_* lines stay in the shell
# that owns the counters.
#
#   GATE_CWD          cwd for the child (the "adopting project with no .pipeline" axis, R18)
#   GATE_PROJECT_DIR  CLAUDE_PROJECT_DIR, or the literal __UNSET__ to unset it
#   GATE_PLUGIN_ROOT_OVERRIDE  CLAUDE_PLUGIN_ROOT, or __UNSET__ (AC21's second gap)
#   GATE_TMPDIR       TMPDIR for the child (a sink the suite can walk)
#   GATE_PATH         PATH for the child (AC21's "node absent", AC16's spy)
#   GATE_EXTRA_ENV    extra `K=V` entries, one per array element
#
# After run_gate:
#   GATE_RC        exit code           GATE_OUT / GATE_ERR   raw stdout / stderr
#   GATE_DECISION  deny|allow|ask|none|NOT-JSON|BAD-EVENT|GATE-UNDECLARED
#   GATE_REASON    the reason string the caller would render

GATE_CWD=""
GATE_PROJECT_DIR=""
GATE_PLUGIN_ROOT_OVERRIDE=""
GATE_TMPDIR=""
GATE_PATH=""
GATE_EXTRA_ENV=()
GATE_RC=""
GATE_OUT=""
GATE_ERR=""
GATE_DECISION=""
GATE_REASON=""
GATE_SCRATCH=""

gate_reset_env() {
  GATE_CWD="${1:-$PWD}"
  GATE_PROJECT_DIR="${1:-$PWD}"
  GATE_PLUGIN_ROOT_OVERRIDE="$GATE_PLUGIN_DIR"
  GATE_TMPDIR=""
  GATE_PATH="$PATH"
  GATE_EXTRA_ENV=()
}

# run_gate_raw <payload-json>: executes the child and captures rc/stdout/stderr. Does NOT parse
# the decision, so a cost measurement over it measures the GATE and not the suite's JSON reader.
run_gate_raw() {
  local payload="$1"
  local of ef

  GATE_OUT=""; GATE_ERR=""; GATE_RC=""; GATE_REASON=""; GATE_DECISION=""
  local tpl
  tpl="$(gate_declaration_template_cached)"
  if [[ -z "$tpl" ]]; then
    GATE_DECISION="GATE-UNDECLARED"
    GATE_REASON="hooks/hooks.json declares no PreToolUse entry"
    GATE_RC="127"
    return 0
  fi

  local cmd root
  root="${GATE_PLUGIN_ROOT_OVERRIDE:-$GATE_PLUGIN_DIR}"
  [[ "$root" == "__UNSET__" ]] && root="$GATE_PLUGIN_DIR"
  cmd="${tpl//\$\{CLAUDE_PLUGIN_ROOT\}/$root}"

  [[ -n "$GATE_SCRATCH" ]] || GATE_SCRATCH="${TMPDIR:-/tmp}"
  of="$GATE_SCRATCH/gate.out.$$"
  ef="$GATE_SCRATCH/gate.err.$$"

  local -a envv=()
  [[ "$GATE_PROJECT_DIR" == "__UNSET__" ]] || envv+=("CLAUDE_PROJECT_DIR=$GATE_PROJECT_DIR")
  [[ "$GATE_PLUGIN_ROOT_OVERRIDE" == "__UNSET__" ]] || envv+=("CLAUDE_PLUGIN_ROOT=$GATE_PLUGIN_ROOT_OVERRIDE")
  [[ -z "$GATE_TMPDIR" ]] || envv+=("TMPDIR=$GATE_TMPDIR")
  envv+=("PATH=${GATE_PATH:-$PATH}")
  if [[ ${#GATE_EXTRA_ENV[@]} -gt 0 ]]; then envv+=("${GATE_EXTRA_ENV[@]}"); fi

  # `env -i` is deliberately NOT used: the real runtime hands the hook an inherited environment,
  # and a stripped one would make the disarm/marker reachability cells (AC23, AC38) measure a
  # world the gate never runs in.
  ( cd "${GATE_CWD:-$PWD}" 2>/dev/null || exit 126
    printf '%s' "$payload" | env "${envv[@]}" sh -c "$cmd" ) >"$of" 2>"$ef"
  GATE_RC=$?

  GATE_OUT="$(cat "$of" 2>/dev/null)"
  GATE_ERR="$(cat "$ef" 2>/dev/null)"
  rm -f "$of" "$ef"
  return 0
}

# run_gate <payload-json>: run_gate_raw plus the caller's own reading of the decision.
run_gate() {
  run_gate_raw "$1"
  [[ "$GATE_DECISION" == "GATE-UNDECLARED" ]] && return 0
  local parsed
  parsed="$(printf '%s' "$GATE_OUT" | "$GATE_REAL_NODE" "$DECISION_MJS" 2>/dev/null)"
  GATE_DECISION="${parsed%%$'\t'*}"
  local restp="${parsed#*$'\t'}"
  GATE_REASON="${restp%%$'\t'*}"
  [[ -n "$GATE_DECISION" ]] || GATE_DECISION="none"
  return 0
}

# ---- fixture builders --------------------------------------------------------------------------

# gate_payload <command> [key=value ...]
gate_payload() {
  "$GATE_REAL_NODE" "$PAYLOAD_MJS" "$@"
}

# gate_status <file> [key=value ...]
gate_status() {
  "$GATE_REAL_NODE" "$STATUS_MJS" "$@"
}

# gate_inflight_status <file> <phase> [extra key=value ...]
# The default in-flight record: no final_verdict, updated_at one minute ago.
gate_inflight_status() {
  local f="$1" phase="$2"; shift 2
  gate_status "$f" "current_phase=$phase" "updated_at=agoms:60000" "$@"
}

# ---- the node spy: process observation, not a clock (AC16, AC19's 4th sink) --------------------
#
# A `node` shim placed first on PATH appends its own argv AND its environment to a log, then execs
# the real node. That answers two questions one mechanism at a time:
#   AC16 -- "the gate spawns ZERO node child processes on the fast path", by counting invocations
#           rather than by timing them, since a timing bound would pass on a host where the node
#           start happened to be fast;
#   AC19 -- "the caller's command string appears in no child's argv or environment", by capturing
#           both AT SPAWN rather than trying to read /proc after the fact (macOS has none).
#
# THE SHIM'S OWN NON-ZERO CONTROL is mandatory and each suite that uses it asserts one: a case on
# the ESCALATION branch must show at least one spy line. Without that, "0 node invocations" is
# equally consistent with "the gate is two-stage" and with "the shim was never on the gate's PATH"
# -- e.g. a gate that calls node by an absolute path, which the shim cannot see.
gate_spy_setup() {  # <dir> -> sets GATE_SPY_LOG and GATE_SPY_PATH
  local dir="$1"
  mkdir -p "$dir/bin"
  GATE_SPY_LOG="$dir/node-invocations.log"
  : > "$GATE_SPY_LOG"
  cat > "$dir/bin/node" <<SPY
#!/bin/sh
{ printf 'ARGV\t%s\n' "\$*"; env | sed 's/^/ENV\t/'; } >> "$GATE_SPY_LOG"
exec "$GATE_REAL_NODE" "\$@"
SPY
  chmod +x "$dir/bin/node"
  GATE_SPY_PATH="$dir/bin:$PATH"
}

gate_spy_invocations() {
  grep -c '^ARGV' "$GATE_SPY_LOG" 2>/dev/null | tr -d ' \n' || printf '0'
}

# ---- sink observation (AC19 leak / AC20 attribution) -------------------------------------------

gate_sink_snap() {  # <manifest> <root...>
  "$GATE_REAL_NODE" "$SINK_MJS" snap "$@"
}
gate_sink_diff() {  # <manifest> <root...> -> the content of every new/changed file
  "$GATE_REAL_NODE" "$SINK_MJS" diff "$@"
}
gate_sink_count() {
  "$GATE_REAL_NODE" "$SINK_MJS" count "$@"
}

# gate_run_with_sinks <payload> <manifest> <root...>
# Runs the gate with the file sinks snapshotted around it, then sets:
#   GATE_SINK_DIFF      the content of every file the gate created or appended to
#   GATE_SINK_COUNT     how many files that was
#   GATE_ATTRIBUTION    what a reader could recover about WHY the gate did not act, without
#                       re-running the session: the sink content plus stderr.
# ONE definition of "recoverable", used by every suite, because R11's one-vocabulary argument
# applies to the tests as much as to the gate: two suites with their own readings of
# "attribution" would agree the day they ship and drift after.
GATE_SINK_DIFF=""
GATE_SINK_COUNT=""
GATE_ATTRIBUTION=""
gate_run_with_sinks() {
  local payload="$1" manifest="$2"; shift 2
  gate_sink_snap "$manifest" "$@"
  run_gate "$payload"
  GATE_SINK_DIFF="$(gate_sink_diff "$manifest" "$@")"
  GATE_SINK_COUNT="$(gate_sink_count "$manifest" "$@")"
  GATE_ATTRIBUTION="$(printf '%s\n%s' "$GATE_SINK_DIFF" "$GATE_ERR")"
}

# gate_fresh_root: a brand-new, never-before-used record-store root under the caller's TEMP_PROJECT.
#
# WHY THIS EXISTS RATHER THAN `rm -rf "$r"; mkdir -p "$r"`. tests/test-harness.sh asserts that no
# new script suite hand-rolls `rm -rf`, and it is right to: a variable assigned from a FAILED
# mktemp is set-and-EMPTY, which `set -u` does not catch, so an inline removal expands to a
# removal at the filesystem root. Nothing here removes anything -- each call takes a FRESH name
# and the harness's single trap reclaims the whole TEMP_PROJECT tree at exit. mktemp with a
# TEMPLATE argument is portable across BSD and GNU (the `-p` flag is not), and it is atomic, so
# this is also safe from a `$( ... )` subshell where a counter increment would be lost.
gate_fresh_root() {
  local d
  d="$(mktemp -d "${TEMP_PROJECT:?gate_fresh_root needs make_temp_project to have run}/rootXXXXXX" 2>/dev/null)" || d=""
  if [[ -z "$d" || ! -d "$d" ]]; then
    printf 'FATAL: mktemp -d under %s failed; refusing to hand back an empty root.\n' "$TEMP_PROJECT" >&2
    return 90
  fi
  printf '%s' "$d"
}

# gate_digest: a one-line digest of a multi-line blob, so a distinctness matrix can be held in a
# line-oriented variable. An attribution containing a newline broke the first draft's collision
# walk silently -- it read half an entry and reported no collisions.
gate_digest() {  # reads stdin
  "$GATE_REAL_NODE" -e '
    let raw = ""; process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => (raw += c));
    process.stdin.on("end", () => process.stdout.write(
      require("node:crypto").createHash("sha1").update(raw).digest("hex")));'
}

# gate_normalize_attribution: strip the parts that legitimately differ between two runs of the
# SAME gap -- ISO timestamps, epoch millisecond stamps, pids, and the session/agent identifiers
# the caller varied on purpose. What is left is the CLASS of the non-action, which is what AC20's
# distinctness and AC4's strip-equality are actually about.
gate_normalize_attribution() {  # reads stdin
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?/<TS>/g' \
    -e 's/\b[0-9]{10,}\b/<EPOCH>/g' \
    -e 's/\bpid[=: ]*[0-9]+/pid=<PID>/g' \
    -e 's/sub-[a-z0-9-]+/<AGENT_ID>/g'
}

# ---- the phase vocabulary, derived from its WRITER (AC15, R12) ---------------------------------
#
# Same derivation tests/test-status-schema-contract.sh:414 performs, deliberately: R12 forbids a
# third private spelling, and a suite that hard-coded '4-review' would BE one.
gate_pipeline_md_phases() {  # [file] -> one phase literal per line, sorted
  local f="${1:-$GATE_PIPELINE_MD}"
  grep -o '"\?current_phase"\?: *"[^"]*"' "$f" \
    | sed 's/.*: *"\(.*\)"/\1/' | grep -vx '<phase>-error' | LC_ALL=C sort -u
}

gate_phase4_literals() {  # the Phase 4 subset of that vocabulary
  gate_pipeline_md_phases "${1:-$GATE_PIPELINE_MD}" | grep '^4-'
}
