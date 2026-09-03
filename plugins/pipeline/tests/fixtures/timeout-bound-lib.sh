#!/usr/bin/env bash
# Shared fixture for the two #132 PreToolUse-timeout suites. SOURCED, never run: it lives under
# fixtures/ so run.sh's flat `test-*.sh` glob does not pick it up as a suite.
#
# ---------------------------------------------------------------------------------------------
# WHAT THIS FILE IS FOR, AND THE ONE THING IT REFUSES TO DO.
#
# #132 raises the PreToolUse hook's declared `timeout` out of a value the gate demonstrably
# outruns. Almost every criterion in that spec is a statement about a MEASUREMENT and about the
# corpus the measurement was taken over, so the fixture's job is to make both reproducible:
#
#   * tb_materialize        -- AC1's corpus: the tracked content of the tree under test, laid out
#                             in a directory with NO .git, so that any rule expressed in git
#                             (`git check-ignore`, `git ls-files`) reports NOTHING there rather
#                             than silently reporting the checkout's answer.
#   * tb_struct_class       -- the hook's OWN structural-character set, obtained by EVALUATING
#                             pre-tool-use.sh's `_STRUCT=` line, never by reading its source text.
#   * tb_struct_count       -- bytes-per-structural-character over that class.
#   * tb_enumerate_*        -- a content-only enumeration of a materialized tree.
#
# THE ONE THING IT REFUSES: it holds no second copy of the structural class. `_STRUCT` is assigned
# from a DOUBLE-QUOTED shell string that opens with the variable reference `$_NL` and carries a
# deliberately DOUBLED backslash (pre-tool-use.sh:1183-1190 documents at length why the doubling is
# load-bearing). Reading that line AS TEXT and using it as a character class yields a FIFTEEN
# member set: it ADDS `$`, `_`, `N` and `L`, and it LOSES the newline, which is the most frequent
# structural character in every file in the population. Measured at 62d7a17, the consequence is not
# cosmetic: plugins/pipeline/schemas/impl-report.schema.json reads 8.38 B/struct and ranks 2nd
# densest of the 159 tracked files at or above 2000 bytes under the evaluated 12-character set, and
# 11.44 B/struct at rank 47 under the source-text set. A density ranking built on the source text
# therefore never selects the densest end of the corpus at all.
# ---------------------------------------------------------------------------------------------

TB_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB_TESTS_DIR="$(cd "$TB_FIXTURES_DIR/.." && pwd)"
TB_PLUGIN_DIR="$(cd "$TB_TESTS_DIR/.." && pwd)"
TB_REPO_ROOT="$(cd "$TB_PLUGIN_DIR/../.." && pwd)"

TB_REAL_NODE="$(command -v node 2>/dev/null || true)"

TB_MAT_SHA=""
TB_MAT_ERR=""

# ---- AC1: the corpus, materialized from the tree under test ------------------------------------
#
# tb_materialize <destdir> -> 0 on success, non-zero with TB_MAT_ERR set otherwise.
#
# THE SOURCE IS `HEAD` UNLESS `TB_MATERIALIZE_WORKING_TREE=1` IS SET (re-derived at #132 after a
# CI-only false-red). `git stash create` writes a commit object for the working tree without
# touching the index, the worktree or the stash ref -- which is exactly the problem: it answers
# for ANY uncommitted change to a tracked file, including one this run.sh invocation itself put
# there a moment earlier in an unrelated suite (a `git add` in a fixture whose own cleanup missed
# a spot, a mode bit, anything). A one-shot CI job has no Dev sitting at the keyboard mid-edit, so
# there is nothing legitimate for the stash-preferring read to observe there; every non-empty
# answer it can give in that context is noise from THIS process's own prior suites, not signal
# about the tree under test, and it is silent about which -- the CI incident this note replaces
# measured a materialized corpus one file larger than the committed tree, from a `stash create`
# sha no `git log` can ever find again because the stash ref was never touched. Two properties this
# split preserves, stated because a reader who only sees the code cannot tell them apart from the
# original bug: (1) LOCAL PHASE-3 ITERATION still measures Dev's uncommitted edits, exactly as
# before, but only when asked for by name (`TB_MATERIALIZE_WORKING_TREE=1`), so an accidental
# adoption of the same footgun elsewhere in this file's callers has to be spelled out at the call
# site rather than inherited by default; (2) CI AND PHASE 4 REVIEW always measure the actual
# reviewed commit, `HEAD`, deterministically, regardless of what any earlier suite in the same
# `run.sh` invocation left lying around -- never an incidental artifact of test execution order.
# Either way the sha is RECORDED, so a transcript says which tree the figures below were taken over
# and which of the two modes produced it.
tb_materialize() {
  local dest="$1" sha=""
  TB_MAT_ERR=""
  [[ -n "$dest" && -d "$dest" ]] || { TB_MAT_ERR="destination is not a directory: [$dest]"; return 1; }
  if [[ "${TB_MATERIALIZE_WORKING_TREE:-0}" == "1" ]]; then
    sha="$(git -C "$TB_REPO_ROOT" stash create 2>/dev/null | tr -d ' \n')"
  fi
  if [[ -z "$sha" ]]; then
    sha="$(git -C "$TB_REPO_ROOT" rev-parse HEAD 2>/dev/null | tr -d ' \n')"
  fi
  [[ -n "$sha" ]] || { TB_MAT_ERR="no sha: neither \`git stash create\` nor \`git rev-parse HEAD\` answered"; return 1; }
  git -C "$TB_REPO_ROOT" archive "$sha" 2>/dev/null | ( cd "$dest" && tar xf - ) || {
    TB_MAT_ERR="git archive $sha | tar x failed into $dest"; return 1; }
  TB_MAT_SHA="$sha"
  return 0
}

# tb_mat_file_count <root> -> how many regular files the materialized tree holds.
tb_mat_file_count() {
  find "$1" -type f 2>/dev/null | grep -c . | tr -d ' \n'
}

# ---- the hook's own structural class ------------------------------------------------------------
#
# tb_struct_assign_lines <pre-tool-use.sh> -> every line assigning _STRUCT, one per line.
# The caller asserts there is EXACTLY ONE. Two matches or zero must fail the suite rather than
# fall back to the first, because the fallback is what turns a refactor into a plausible wrong
# number instead of a loud red. A red here means THE HOOK'S SET MOVED SHAPE (e.g. it was rewritten
# as a concatenation, which is the shape `_DELIMS` immediately below it already uses); it does NOT
# mean the density figures are wrong.
tb_struct_assign_lines() {
  grep '^_STRUCT=' "$1" 2>/dev/null
}

# tb_struct_class <pre-tool-use.sh> -> the VALUE of _STRUCT, evaluated the way the hook computes
# it, with $_NL bound to a newline. Prints nothing when the extraction is not unique.
tb_struct_class() {
  local src="$1" line n
  n="$(tb_struct_assign_lines "$src" | grep -c . | tr -d ' \n')"
  [[ "$n" == "1" ]] || return 1
  line="$(tb_struct_assign_lines "$src")"
  (
    _NL='
'
    eval "$line" || exit 1
    printf '%s' "$_STRUCT"
  )
}

# tb_struct_distinct <class> -> the number of DISTINCT characters in the class.
# `_STRUCT`'s value is 13 bytes and 12 distinct characters, because the backslash appears twice:
# the string is re-read AS A BRACKET PATTERN (`[$_STRUCT]`) where `\\` is one escaped backslash
# and therefore one member.
tb_struct_distinct() {
  TB_CLASS="$1" "$TB_REAL_NODE" -e '
    const s = process.env.TB_CLASS || "";
    process.stdout.write(String(new Set(Array.from(s)).size));
  ' 2>/dev/null
}

# tb_struct_has <class> <one-character> -> "yes" | "no"
tb_struct_has() {
  TB_CLASS="$1" TB_CH="$2" "$TB_REAL_NODE" -e '
    const s = new Set(Array.from(process.env.TB_CLASS || ""));
    process.stdout.write(s.has(process.env.TB_CH) ? "yes" : "no");
  ' 2>/dev/null
}

# tb_density <class> <file> -> "<bytes> <structural-chars> <bytes-per-struct, 2dp>"
# Counted over BYTES (latin1), because "bytes per structural character" is a byte figure and every
# member of the class is ASCII; decoding as UTF-8 would make a multi-byte character count as one.
tb_density() {
  TB_CLASS="$1" "$TB_REAL_NODE" -e '
    const fs = require("node:fs");
    const set = new Set(Array.from(process.env.TB_CLASS || ""));
    let b; try { b = fs.readFileSync(process.argv[1]); } catch { process.stdout.write("0 0 0.00"); process.exit(0); }
    const s = b.toString("latin1");
    let n = 0; for (const ch of s) if (set.has(ch)) n++;
    process.stdout.write(b.length + " " + n + " " + (n ? (b.length / n).toFixed(2) : "0.00"));
  ' "$2" 2>/dev/null
}

# ---- the population, enumerated from a materialized tree ----------------------------------------
#
# CONTENT-ONLY AND EXTENSION-OPEN, and both halves are load-bearing.
#
# CONTENT-ONLY: inside a `git archive | tar x` tree there is no `.git`, so `git rev-parse` and
# `git check-ignore` exit 128. A population rule expressed in git therefore enumerates ZERO there
# and reports a clean scan -- and that tree is the one AC1 mandates, which is the tree CI runs
# against, so the failure is not hypothetical.
#
# EXTENSION-OPEN: at 62d7a17 the densest tracked file at or above 2000 bytes is NOT a `.json`. It
# is plugins/pipeline/tests/test-frontend-surface.sh at 8.30 B/struct, ahead of
# plugins/pipeline/schemas/impl-report.schema.json at 8.38; ranks 3 and 4 are also `.sh`. A rule
# restricted to `.json` is already selecting the wrong rank-1 density row.
#
# tb_enumerate <root> <floor-bytes> -> one line per file: "<bytes>\t<relative-path>"
tb_enumerate() {
  local root="$1" floor="$2"
  ( cd "$root" 2>/dev/null || exit 0
    find . -type f -size +$(( floor - 1 ))c 2>/dev/null |
      while IFS= read -r f; do
        printf '%s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "${f#./}"
      done
  )
}

# tb_enumerate_count <root> <floor-bytes>
tb_enumerate_count() {
  tb_enumerate "$1" "$2" | grep -c . | tr -d ' \n'
}

# ---- reading numbers out of prose ----------------------------------------------------------------
#
# tb_numbers <text> <unit-regex> -> every integer immediately preceding the unit, one per line.
tb_numbers() {
  printf '%s' "$1" | grep -oE "[0-9][0-9,._]*[[:space:]]*(${2})" | grep -oE '^[0-9][0-9,._]*' |
    tr -d ',' | sed 's/\.$//'
}

# tb_min3 <a> <b> <c> -> the smallest. Integer only.
tb_min3() {
  local m="$1"
  [[ "$2" -lt "$m" ]] && m="$2"
  [[ "$3" -lt "$m" ]] && m="$3"
  printf '%s' "$m"
}

# tb_loadavg -> the 1-minute load average, or "unknown". RECORDED beside every timing figure,
# because a millisecond number without the load it was taken under is not re-takeable.
tb_loadavg() {
  uptime 2>/dev/null | sed -n 's/.*load averages\{0,1\}:[[:space:]]*\([0-9.,]*\).*/\1/p' | tr -d ' ' |
    grep -E '^[0-9]' || printf 'unknown'
}

# ---- payloads whose command is too large for argv ------------------------------------------------
#
# tb_payload_file <command-file> <cwd> [key=value ...] -> the payload JSON on stdout.
#
# WHY THIS EXISTS BESIDE gate_payload. The shared helper passes the command as a node ARGV, which is
# the right shape for every fixture in the #106 suites. AC11's fail-open pair is not one of them: it
# has to build a command LARGER than the gate can decide inside the declared timeout, and at the
# raised bound that is megabytes. MEASURED: a 3,111,437-byte command handed to the argv builder made
# the exec fail, the payload came back EMPTY, and the gate returned `none` in 352 ms -- a fixture
# reporting an ALLOW for a gate that was working, which is the exact reading AC11's arm one exists to
# refuse. Reading the command from a FILE has no such ceiling. The payload SHAPE is the same one
# fixtures/pretooluse-payload.mjs builds (Claude Code 2.1.85: hook_event_name, session_id,
# tool_name, tool_input.command, agent_id present only for a subagent-originated call), and `cwd` is
# REQUIRED here for the same reason it is required there.
tb_payload_file() {
  local cmdfile="$1" cwd="$2"; shift 2
  [[ -n "$cwd" ]] || { printf 'tb_payload_file: a cwd is required and is never inferred\n' >&2; return 2; }
  TB_CMD_FILE="$cmdfile" "$TB_REAL_NODE" -e '
    const fs = require("node:fs");
    const cmd = fs.readFileSync(process.env.TB_CMD_FILE, "utf8");
    const payload = {
      hook_event_name: "PreToolUse",
      session_id: "qa-132-contract",
      transcript_path: "/dev/null",
      cwd: process.argv[1],
      tool_name: "Bash",
      tool_input: { command: cmd },
    };
    for (const kv of process.argv.slice(2)) {
      const i = kv.indexOf("=");
      if (i < 0) continue;
      payload[kv.slice(0, i)] = kv.slice(i + 1);
    }
    process.stdout.write(JSON.stringify(payload));
  ' "$cwd" "$@"
}

# tb_rank <class> <root> <floor-bytes> -> "<bytes>\t<struct>\t<B-per-struct>\t<relative-path>" for
# every file at or above the floor, ranked DENSEST FIRST.
#
# ONE node process for the whole tree, not one per file. The obvious spelling -- a shell loop
# calling tb_density per path -- spawns a node start per row, and at 159 rows that is about twenty
# seconds of a suite whose whole point is to measure something else. The enumeration itself stays
# content-only: `find -size`, no git, no extension filter.
tb_rank() {
  local class="$1" root="$2" floor="$3"
  TB_CLASS="$class" "$TB_REAL_NODE" -e '
    const fs = require("node:fs"), path = require("node:path");
    const root = process.argv[1], floor = Number(process.argv[2]);
    const set = new Set(Array.from(process.env.TB_CLASS || ""));
    const rows = [];
    const walk = (d) => {
      let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
      for (const e of ents) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) { walk(p); continue; }
        if (!e.isFile()) continue;
        let b; try { b = fs.readFileSync(p); } catch { continue; }
        if (b.length < floor) continue;
        const s = b.toString("latin1");
        let n = 0; for (const ch of s) if (set.has(ch)) n++;
        rows.push([b.length, n, n ? b.length / n : Infinity, path.relative(root, p)]);
      }
    };
    walk(root);
    rows.sort((a, b) => a[2] - b[2]);
    process.stdout.write(rows.map((r) => r[0] + "\t" + r[1] + "\t" + (Number.isFinite(r[2]) ? r[2].toFixed(2) : "inf") + "\t" + r[3]).join("\n"));
  ' "$root" "$floor" 2>/dev/null
}

# ---- sizing a probe body: a BOUNDED CLIMB, never one long extrapolation (#132 blocker B1) --------
#
# WHAT WENT WRONG WITH THE FIRST METHOD, MEASURED RATHER THAN ARGUED. AC11's pair needs a command
# the gate cannot decide inside the declared timeout, and the first version of this fixture found
# that length by fitting a STRAIGHT LINE through two calibration points at 26,506 and 105,910 bytes
# and solving it for the target. On darwin that lands: 266 copies, 1,760,160 bytes, aimed at 45,000
# ms and measured 49,276. On ubuntu-latest, where `sh` is dash, it does not: CI run 33747342504
# solved the same line for 3,500 copies = 23,159,538 bytes, aimed at 45,000 ms and MEASURED 700,683
# -- eleven minutes and forty seconds, a 15.6x miss, paid twice per CI job because
# test-issue17-integration.sh re-runs run.sh inside a clone.
#
# The line was not wrong about the points it was fitted to. It was extrapolated 219x BEYOND them,
# and the scan's per-byte cost is not constant over that range: 1.93 microseconds per byte at the
# calibration sizes against 30.3 at the fitted size, a factor of 15.7. #116 established linearity
# over KILOBYTES; nothing had measured it over tens of megabytes until this issue did.
#
# SO THE MODEL IS NEVER ASKED TO PREDICT FAR FROM WHERE IT WAS MEASURED. Four properties, and the
# first two are the ones the straight line lacked:
#
#   RE-FIT LOCALLY. Every step re-estimates the exponent from the TWO MOST RECENT measured points,
#   with the gate's fixed overhead subtracted first (two node starts and a resolver run happen
#   before the gate reads a byte, so the term that scales with length is ms MINUS that floor; a
#   power law fitted to the raw milliseconds reads the overhead as sub-linear growth and asks for
#   more copies than the straight line did).
#
#   CAP THE STEP. A candidate is never more than <cap> times the largest count actually MEASURED.
#   Against the worst curve this issue recorded (per-byte cost rising as c^0.44), a 32x step costs
#   2.8x more than a linear model predicts -- which the probe bound below absorbs -- where the 219x
#   step cost 15.6x more, which nothing absorbed.
#
#   BOUND EVERY PROBE'S WALL CLOCK. A probe is killed at its bound and reported as killed rather
#   than allowed to run for eleven minutes. A killed probe still carries information: it fixes an
#   upper BRACKET on the copy count, and the climb halves the gap instead of growing.
#
#   CLAMP TO THE CEILING BEFORE WRITING, NOT AFTER RUNNING. The old fixture asserted its 6 MB
#   ceiling AFTER the 23 MB body had already been built and driven, so the ceiling was a verdict on
#   work already paid for. <max-copies> is inverted from the ceiling and clamps every candidate, and
#   what the suite asserts instead is the climb's STOP REASON: it must stop because it REACHED the
#   target, not because it ran out of room.

# tb_fit_floor <c1> <ms1> <c2> <ms2> -> the two-point line's INTERCEPT, in ms, clamped to
# [0, ms1/2] when the pair is too noisy to separate a constant from a slope.
#
# This is the term that does not scale with the command's length: two node starts and a resolver run
# happen before the gate reads a byte. It is taken from the SAME two points the exponent is
# estimated from, rather than from a separate bare-command probe, because the two must be consistent
# for the estimate to mean anything: subtract an independently measured constant that differs from
# this line's intercept and the exponent comes out different from 1 at a scale where the cost really
# is linear, which is a spurious curve invented by the arithmetic. The independently measured floor
# is kept beside it in the transcript as a control on this one, not as its replacement.
tb_fit_floor() {
  local c1="$1" ms1="$2" c2="$3" ms2="$4" f
  if [[ "$c2" -le "$c1" || "$ms2" -le "$ms1" ]]; then printf '0'; return 0; fi
  f=$(( ms1 - (ms2 - ms1) * c1 / (c2 - c1) ))
  [[ "$f" -lt 0 ]] && f=0
  [[ "$f" -ge "$ms1" ]] && f=$(( ms1 / 2 ))
  printf '%s' "$f"
}

# tb_next_copies <c1> <ms1> <c2> <ms2> <floor-ms> <aim-ms> <cap-x100> <max-copies>
#   -> the next copy count to probe.
#
# Floats, so node and not bash: bash 3.2 has no logarithm and the exponent is the whole point.
tb_next_copies() {
  "$TB_REAL_NODE" -e '
    const [c1, m1, c2, m2, floor, aim, capX100, maxc] = process.argv.slice(1).map(Number);
    const cap = capX100 / 100;
    const EPS = 1;
    // The term that scales with length is the milliseconds ABOVE the gate fixed overhead.
    const a1 = Math.max(m1 - floor, EPS), a2 = Math.max(m2 - floor, EPS);
    const want = Math.max(aim - floor, EPS);
    let p = 1;
    if (c2 > c1 && a2 > a1) p = Math.log(a2 / a1) / Math.log(c2 / c1);
    if (!Number.isFinite(p) || p < 0.5) p = 0.5;   // a degenerate fit must not explode 1/p
    if (p > 4) p = 4;
    let next = c2 * Math.pow(want / a2, 1 / p);
    if (!Number.isFinite(next)) next = c2 * cap;
    next = Math.min(next, c2 * cap, maxc);
    next = Math.ceil(next);
    if (next < 1) next = 1;
    process.stdout.write(String(next));
  ' "$@" 2>/dev/null
}

# tb_climb <probe-fn> <c-prev> <ms-prev> <c-cur> <ms-cur> <floor-ms> <aim-ms> <accept-ms> \
#          <cap-x100> <max-copies> <max-steps>
#
# <probe-fn> is called as `<probe-fn> <copies>` and MUST set TB_PROBE_MS and TB_PROBE_KILLED (1 when
# the probe hit its own wall-clock bound and produced no decision). It is called WITHOUT a command
# substitution on purpose: a probe that has to print its result cannot also hand back the decision
# and the stdout byte count the caller asserts on.
#
# Sets: TB_CLIMB_COPIES TB_CLIMB_MS TB_CLIMB_STOP TB_CLIMB_TRACE TB_CLIMB_STEPS TB_CLIMB_PROBES
#   TB_CLIMB_STOP is one of:
#     target   -- a probe measured at or above <accept-ms>. This is the only success.
#     ceiling  -- the climb reached <max-copies> without reaching the target: the pair is not
#                 constructible from this corpus at this declaration inside the size ceiling.
#     bracket  -- a killed probe and a measured one closed on adjacent counts.
#     steps    -- <max-steps> probes were spent without reaching the target.
tb_climb() {
  local fn="$1" cp="$2" mp="$3" cc="$4" mc="$5" floor="$6" aim="$7" accept="$8" cap="$9"
  local maxc="${10}" maxsteps="${11}"
  local step=0 next hi=0
  TB_CLIMB_COPIES="$cc"; TB_CLIMB_MS="$mc"; TB_CLIMB_TRACE=""; TB_CLIMB_STEPS=0
  TB_CLIMB_PROBES=0; TB_CLIMB_STOP=""
  if [[ "$mc" -ge "$accept" ]]; then TB_CLIMB_STOP="target"; return 0; fi
  while :; do
    step=$(( step + 1 ))
    if [[ "$step" -gt "$maxsteps" ]]; then TB_CLIMB_STOP="steps"; break; fi
    next="$(tb_next_copies "$cp" "$mp" "$cc" "$mc" "$floor" "$aim" "$cap" "$maxc")"
    [[ "$next" =~ ^[0-9]+$ ]] || { TB_CLIMB_STOP="steps"; break; }
    # An upper BRACKET from a killed probe: never re-probe at or above a count already known to
    # outrun the bound. Halve the gap instead, which is the only direction that can still land.
    if [[ "$hi" -gt 0 && "$next" -ge "$hi" ]]; then next=$(( (cc + hi) / 2 )); fi
    if [[ "$next" -le "$cc" ]]; then
      if [[ "$hi" -gt 0 ]]; then TB_CLIMB_STOP="bracket"; else TB_CLIMB_STOP="ceiling"; fi
      break
    fi
    TB_PROBE_MS=0; TB_PROBE_KILLED=0
    "$fn" "$next"
    TB_CLIMB_PROBES=$(( TB_CLIMB_PROBES + 1 ))
    TB_CLIMB_STEPS="$step"
    if [[ "$TB_PROBE_KILLED" == "1" ]]; then
      TB_CLIMB_TRACE="$TB_CLIMB_TRACE [step${step} ${next}copies KILLED at ${TB_PROBE_MS}ms]"
      hi="$next"
      continue
    fi
    TB_CLIMB_TRACE="$TB_CLIMB_TRACE [step${step} ${next}copies ${TB_PROBE_MS}ms]"
    cp="$cc"; mp="$mc"; cc="$next"; mc="$TB_PROBE_MS"
    TB_CLIMB_COPIES="$cc"; TB_CLIMB_MS="$mc"
    if [[ "$mc" -ge "$accept" ]]; then TB_CLIMB_STOP="target"; break; fi
  done
  [[ -n "$TB_CLIMB_STOP" ]] || TB_CLIMB_STOP="steps"
  return 0
}

# tb_gate_bounded <payload> <cwd> <bound-seconds>
#   -> TB_GB_MS TB_GB_KILLED TB_GB_OUT_BYTES TB_GB_OUT TB_GB_DECISION
#
# ONE RUNNER FOR BOTH OF AC11's ARMS, which is what makes the pair a pair: the same resolved hook
# command from hooks.json, the same payload, the same environment, driven twice with two different
# wall-clock bounds. Arm one runs under a bound it does not hit and emits a decision; arm two runs
# under the DECLARED bound, is killed there, and emits nothing -- and a PreToolUse hook that emits
# nothing fails open. Before #132's B1 fix the two arms went through two different drivers, so the
# only thing making them the same call was that two blocks of the suite agreed.
#
# The child enumeration is `ps -o pid=,ppid=` filtered in awk rather than `ps -P`, because `-P`
# means "parent pid" on BSD and "add a PSR column" on procps: on Linux the BSD spelling enumerates
# nothing, the shell is killed, and its `sh`/`node` grandchildren survive to keep scanning a
# multi-megabyte command with nobody waiting for them.
tb_gate_bounded() {
  local payload="$1" cwd="$2" secs="$3"
  local tpl root cmd of pid limit waited kid gkid a b parsed
  TB_GB_MS=0; TB_GB_KILLED=0; TB_GB_OUT_BYTES=0; TB_GB_OUT=""; TB_GB_DECISION="GATE-UNDECLARED"
  tpl="$(gate_declaration_template_cached)"
  [[ -n "$tpl" ]] || return 0
  root="$GATE_PLUGIN_DIR"
  cmd="${tpl//\$\{CLAUDE_PLUGIN_ROOT\}/$root}"
  of="${TEMP_PROJECT:-${TMPDIR:-/tmp}}/tb-gate-bounded.out"
  : > "$of"
  a="$("$TB_REAL_NODE" -e 'process.stdout.write(String(Date.now()))')"
  ( cd "$cwd" 2>/dev/null || exit 126
    printf '%s' "$payload" | env "CLAUDE_PROJECT_DIR=$cwd" "CLAUDE_PLUGIN_ROOT=$root" "PATH=$PATH" \
      sh -c "$cmd" ) > "$of" 2>/dev/null &
  pid=$!
  # THE BOUND IS WALL CLOCK, NOT A COUNT OF SLEEPS. Counting 200 ms polls makes the bound a FLOOR
  # that drifts upward with load, because each iteration also pays a fork for `sleep` and whatever
  # the scheduler adds: measured here, a nominal 90 s bound let a probe run 97.9 s at load 9.7.
  # `SECONDS` is a bash builtin present in the 3.2 macOS ships, so the elapsed check costs nothing.
  limit="$secs"
  waited="$SECONDS"
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $(( SECONDS - waited )) -ge "$limit" ]]; then TB_GB_KILLED=1; break; fi
    sleep 0.2
  done
  if [[ "$TB_GB_KILLED" == "1" ]]; then
    # Kill by EXPLICIT PID only, never by pattern: children first, then the shell that started them.
    for kid in $(ps -o pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2==p {print $1}'); do
      for gkid in $(ps -o pid=,ppid= 2>/dev/null | awk -v p="$kid" '$2==p {print $1}'); do
        kill -KILL "$gkid" 2>/dev/null
      done
      kill -KILL "$kid" 2>/dev/null
    done
    kill -KILL "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null
  b="$("$TB_REAL_NODE" -e 'process.stdout.write(String(Date.now()))')"
  TB_GB_MS=$(( b - a ))
  TB_GB_OUT_BYTES="$(wc -c < "$of" 2>/dev/null | tr -d ' ')"
  [[ -n "$TB_GB_OUT_BYTES" ]] || TB_GB_OUT_BYTES=0
  TB_GB_OUT="$(cat "$of" 2>/dev/null)"
  if [[ "$TB_GB_KILLED" == "1" ]]; then
    TB_GB_DECISION="KILLED"
  else
    parsed="$(printf '%s' "$TB_GB_OUT" | "$TB_REAL_NODE" "$DECISION_MJS" 2>/dev/null)"
    TB_GB_DECISION="${parsed%%	*}"
    [[ -n "$TB_GB_DECISION" ]] || TB_GB_DECISION="none"
  fi
  return 0
}
