#!/usr/bin/env bash
# Runs every test suite under this directory: the bash hooks, the bundled .mjs scripts, and
# the harness itself. Exit 0 only when all pass.
#
# Wire this as your checkCommand to gate the plugin's own development:
#   { "checkCommand": "bash tests/run.sh" }
#
# THE SUMMARY NAMES THE SUITES, not only how many there were (#91). A count alone is an
# observability defect with a measured cost: this summary reported "1 suite(s) FAILED" against a
# ~40-suite run during #56's review, and identifying WHICH suite meant grepping back through a
# transcript that scrolls past a terminal's scrollback. The per-suite `== name ==` banner is
# printed BEFORE the suite runs and says nothing about its outcome, so it is not a substitute.
#
# TWO PROPERTIES OF THIS HARNESS THAT LOOK LIKE FLAKES AND ARE NOT (#91, both reproduced during
# #56's review). Read these before concluding that a one-off red is a real regression.
#
#   (a) DO NOT RUN THIS CONCURRENTLY WITH AN IN-FLIGHT EDIT TO ../scripts/*.mjs. Every test-*.sh
#       here shells out to the LIVE checkout path (harness.sh's SCRIPTS_DIR is `../plugins/pipeline/scripts`, a
#       read path into the working tree) rather than to a snapshot taken at the start of the run.
#       An editor or tool save that is mid-write when a suite reads the file yields a partial
#       file, so node reports a transient SyntaxError in exactly one invocation and the same
#       suite is green on the next run. DIRECTION: a FALSE RED, which is the cheap direction, but
#       it costs an investigation each time. It is a TOCTOU window, not a race this harness can
#       close from inside: the fix would be running against a snapshot, which would then test
#       code that is not the code in the tree.
#
#   (b) test-issue17-integration.sh's AC41(c) IS STRUCTURALLY BLIND TO UNCOMMITTED CHANGES. That
#       cell does `git clone file://$REPO_ROOT` into a temp dir and runs this script inside the
#       CLONE. A clone transfers committed refs only, so the nested run tests the tree as of the
#       last commit and never the working tree. If you are iterating on an uncommitted fix, the
#       nested run reports the PRE-implementation pass/fail tally while your outer run reports
#       the post-implementation one, and the two disagree for a reason that has nothing to do
#       with the change. COMMIT FIRST, then re-run, before treating that disagreement as a bug.
#
# MODES, JOBS AND SERIAL SUITES (#162).
#
#   bash tests/run.sh                        # routine: suites in parallel, release-only cells off
#   PIPELINE_TESTS_FULL=1 bash tests/run.sh  # full: every cell, including the release-only ones
#   PIPELINE_TESTS_JOBS=1 bash tests/run.sh  # one suite at a time (default 4)
#
#   - FULL MODE is what a release is cut on (CLAUDE.md, Versioning). A cell guarded by
#     harness.sh's full_mode_only (the nested fresh-checkout run, oversized timeout and sweep
#     cells) is RECORDED as not run in routine mode, never skipped in silence.
#   - A suite carrying the line `# pipeline-tests: serial` runs AFTER the parallel pool drains,
#     alone. That is for suites that measure wall time against a budget (a loaded host is a false
#     red there) or that act on the shared checkout (git worktree add, the nested run).
#   - A parallel suite's output is buffered to a file and printed whole when it finishes, so two
#     suites never interleave; the `== name ==` banner still precedes each suite's lines, which
#     is what the fresh-checkout cell's transcript reader keys on. A serial suite streams.
set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# WALL TIME PER SUITE (#162). A suite's elapsed time is printed after it runs, and every suite's
# time is printed again, slowest first, before the verdict. Without it the split between the
# nested fresh-checkout run, timeout-bound cells and per-assertion process starts was unmeasured.
# Tenths of a second from EPOCHREALTIME where bash has it (5.0+); whole seconds from `date +%s`
# on bash 3.2, which is what macOS ships.
_now_ds() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local r="${EPOCHREALTIME/,/.}"
    printf '%s' "$(( ${r%%.*} * 10 + 10#${r#*.} / 100000 ))"
  else
    printf '%s' "$(( $(date +%s) * 10 ))"
  fi
}
_fmt_ds() { printf '%d.%d' "$(( $1 / 10 ))" "$(( $1 % 10 ))"; }

JOBS="${PIPELINE_TESTS_JOBS:-4}"
case "$JOBS" in
  ''|*[!0-9]*|0) printf 'run.sh: PIPELINE_TESTS_JOBS must be a positive integer, got [%s]\n' "$JOBS" >&2; exit 2 ;;
esac
MODE=routine
[[ "${PIPELINE_TESTS_FULL:-0}" == "1" ]] && MODE=full

# Per-suite output and result files. Removed on exit; the removal refuses anything but the dir
# this run created.
OUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-run.XXXXXX" 2>/dev/null)" || OUTDIR=""
if [[ -z "$OUTDIR" || ! -d "$OUTDIR" ]]; then
  printf 'run.sh: mktemp -d failed; nothing was run\n' >&2
  exit 1
fi
_cleanup_outdir() {
  case "$OUTDIR" in
    */pipeline-run.*) [[ -d "$OUTDIR" ]] && rm -rf "$OUTDIR" ;;
  esac
  return 0
}
trap '_cleanup_outdir' EXIT
trap '_cleanup_outdir; exit 130' INT
trap '_cleanup_outdir; exit 143' TERM

FAILED=0
# A newline-delimited STRING and not an array, matching harness.sh's TMP_REGISTRY for the same
# reason: bash 3.2 is what macOS ships and what this script runs under, and `"${arr[@]}"` on an
# empty array is an unbound-variable error there under `set -u`.
FAILED_SUITES=""
TIMES=""
PARALLEL=""
SERIAL=""
RUNNING=""
N_RUNNING=0   # kept in step with RUNNING, so the poll spawns no process
N_SUITES=0

# _run_suite <t> -> the banner, the suite's output, its elapsed line; <t>.res holds "<rc> <ds>".
# Written to .res.tmp and renamed, so the poller never reads a half-written result.
_run_suite() {
  local t="$1" t0 rc dt
  printf '\n\033[1m== %s ==\033[0m\n' "$t"
  t0="$(_now_ds)"
  bash "$t" </dev/null
  rc=$?
  dt=$(( $(_now_ds) - t0 ))
  printf 'elapsed %s s  %s\n' "$(_fmt_ds "$dt")" "$t"
  printf '%s %s\n' "$rc" "$dt" > "$OUTDIR/$t.res.tmp" && mv "$OUTDIR/$t.res.tmp" "$OUTDIR/$t.res"
}

_tally() {  # <t> <rc> <ds>
  if [[ "$2" -ne 0 ]]; then
    FAILED=$((FAILED + 1))
    FAILED_SUITES="${FAILED_SUITES}  ${1}
"
  fi
  TIMES="${TIMES}${3} ${1}
"
}

# _reap: print and tally every running suite that has finished; leaves the rest in RUNNING.
_reap() {
  local t still="" n=0 rc dt
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    if [[ -f "$OUTDIR/$t.res" ]]; then
      cat "$OUTDIR/$t.out"
      read -r rc dt < "$OUTDIR/$t.res"
      _tally "$t" "$rc" "$dt"
    else
      still="${still}${t}
"
      n=$((n + 1))
    fi
  done <<< "$RUNNING"
  RUNNING="$still"
  N_RUNNING=$n
}

for t in test-*.sh; do
  [[ -f "$t" ]] || continue
  N_SUITES=$((N_SUITES + 1))
  if grep -q '^# pipeline-tests: serial$' "$t"; then
    SERIAL="${SERIAL}${t}
"
  else
    PARALLEL="${PARALLEL}${t}
"
  fi
done

printf 'run.sh: %s suites, mode=%s (PIPELINE_TESTS_FULL=1 runs the release-only cells), jobs=%s, serial=%s\n' \
  "$N_SUITES" "$MODE" "$JOBS" "$(printf '%s' "$SERIAL" | grep -c . | tr -d ' ')"

RUN_START="$(_now_ds)"
while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  while [[ "$N_RUNNING" -ge "$JOBS" ]]; do
    sleep 0.2
    _reap
  done
  _run_suite "$t" > "$OUTDIR/$t.out" 2>&1 &
  RUNNING="${RUNNING}${t}
"
  N_RUNNING=$((N_RUNNING + 1))
done <<< "$PARALLEL"
while [[ "$N_RUNNING" -gt 0 ]]; do
  sleep 0.2
  _reap
done
wait

while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  _run_suite "$t"
  read -r rc dt < "$OUTDIR/$t.res"
  _tally "$t" "$rc" "$dt"
done <<< "$SERIAL"

printf '\nSuite wall time, slowest first (run total %s s, mode=%s, jobs=%s):\n' \
  "$(_fmt_ds $(( $(_now_ds) - RUN_START )))" "$MODE" "$JOBS"
printf '%s' "$TIMES" | sort -rn | while read -r dt t; do
  [[ -n "$t" ]] && printf '  %8s s  %s\n' "$(_fmt_ds "$dt")" "$t"
done

printf '\n'
if [[ "$FAILED" -eq 0 ]]; then
  printf 'All test suites passed.\n'
  exit 0
fi
printf '%s suite(s) FAILED.\n' "$FAILED"
printf '%s' "$FAILED_SUITES"
exit 1
