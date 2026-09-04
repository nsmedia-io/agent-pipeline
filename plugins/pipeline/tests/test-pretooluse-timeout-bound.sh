#!/usr/bin/env bash
# #132, part 1 of 2: THE DECLARED PreToolUse TIMEOUT AND THE MEASUREMENTS THAT SIZE IT.
#
# AC1  the sizing corpus is reachable from the reviewed commit alone, and carries its density
# AC2  the covered set, with BOTH recorded spreads applied to the number
# AC3  the uncovered cells are named with their milliseconds and their density, or they are covered
# AC4  the population is derived from the tree AT CHECK TIME, not frozen as a list of filenames
# AC5  the four timing probes' millisecond bound is ABSOLUTE, not the declaration times 1000
# AC6  that absolute bound carries a measurement from the host the guard is EVALUATED on
# AC7  each probe asserts BOTH bounds, with BYPASS and REGRESSION distinguishable
# AC8  the declaration suite's range assertion names the measurement that fixes it
# AC9  the declared timeout stays STRICTLY under the platform's 600 s default
# AC10 a change to the declared timeout makes an in-tree assertion fail, printing BOTH values
# AC11 the fail-open direction is demonstrated by a PAIR, not asserted
# AC12 every independent re-derivation of the old bound carries the new value or an era marker
# AC13 the operator-facing disclosure states the crossing at BOTH density ends, the fail-open, the
#      uncovered cells, the ALLOW-path stall, and that the crossing RETURNS as the corpus grows
# AC14 the superseded published figures are reconciled rather than left standing beside the new ones
# AC15 the #106-era gate suites' rows are compared against origin/main, not merely 'all green'
# AC16 no child process receives the caller's command text, with its own non-zero control
#
# AC17/AC18/AC19 are in test-pretooluse-timeout-knowledge.sh.
#
# THE TESTS IN THIS FILE FAIL AT THE REVIEWED COMMIT AND ARE MEANT TO. Each row fails on its own,
# with its own message about the missing behaviour, rather than behind one setup throw: a run
# reporting N skips at exit 0 is indistinguishable from a run that checked nothing.
#
# ---------------------------------------------------------------------------------------------
# THE COST OF THIS FILE, STATED RATHER THAN HIDDEN. Four blocks drive the real gate against real
# tracked bodies (the AC2 floor fixture three times plus its ALLOW control, the AC3/AC11
# constructed dense cell twice, the AC16 spy once) and one block runs
# test-pretooluse-gate-declaration.sh five times against materialized copies. On darwin 25.5.0 at
# load ~5 that is roughly three minutes. The alternative -- asserting these from a transcript
# somebody else produced -- is what AC2 and AC11 exist to refuse, and re-running
# test-pretooluse-gate-verdicts.sh (211 s at 62d7a17, measured) was rejected as the more expensive
# way to learn less. Where a criterion is discharged by reading a published figure rather than by
# re-taking it, the row says so in its own name.
# ---------------------------------------------------------------------------------------------

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/timeout-bound-lib.sh"
require_node

make_temp_project 132 || exit 90
GATE_SCRATCH="$TEMP_PROJECT"
gate_cache_declaration

HOOKS_REL="plugins/pipeline/hooks/hooks.json"
HOOK_REL="plugins/pipeline/hooks/pre-tool-use.sh"
VERDICTS_REL="plugins/pipeline/tests/test-pretooluse-gate-verdicts.sh"
DECLSUITE_REL="plugins/pipeline/tests/test-pretooluse-gate-declaration.sh"
README_REL="plugins/pipeline/README.md"
FLOOR_REL="knowledge/issue-archive/106.json"

# The two spreads AC2 requires to be applied to the number rather than asserted beside it. Both are
# figures spec.json's measured_state records, cited here as x100 integers because this file runs
# under the bash 3.2 macOS ships and has no floating point.
LOAD_SPREAD_X100=142   # spec.json measured_state, 'same-host load spread'
HOST_SPREAD_X100=132   # spec.json measured_state, 'issue-row reproduction ratio', upper end

DECLARED_S="$(gate_declared_timeout)"
[[ "$DECLARED_S" =~ ^[0-9]+$ ]] || DECLARED_S=""
DECLARED_MS=0
[[ -n "$DECLARED_S" ]] && DECLARED_MS=$(( DECLARED_S * 1000 ))

LOAD_AT_START="$(tb_loadavg)"
record "HOST $(uname -sr), node $("$GATE_REAL_NODE" -v 2>/dev/null), load at start ${LOAD_AT_START}; declared PreToolUse timeout read from hooks.json: [${DECLARED_S:-<absent-or-non-integer>}] s"

# ===============================================================================================
suite "AC1: the sizing corpus is reachable from the commit alone, and it carries its density"
# ===============================================================================================
#
# Materialized with `git archive <tree> | tar x`, which is what AC1 mandates. The consequence that
# matters, and the reason the row below asserts a git command FAILS: inside that directory there is
# no `.git`, so `git rev-parse` and `git check-ignore` exit 128. A population rule expressed in git
# enumerates ZERO there and reports a clean scan -- and that tree is the one CI runs against, so a
# git-expressed rule is not merely inelegant, it silently checks nothing on every CI run.

new_tmpdir || exit 90
MAT="$NEW_TMPDIR/corpus"
mkdir -p "$MAT"
if tb_materialize "$MAT"; then MAT_STATUS=ok; else MAT_STATUS="FAILED: $TB_MAT_ERR"; fi
assert_eq "the tracked tree materializes into an empty directory via git archive | tar x" "$MAT_STATUS" "ok"
MAT_FILES="$(tb_mat_file_count "$MAT")"
record "MATERIALIZED tree ${TB_MAT_SHA:-<none>} -> $MAT_FILES files at $MAT"
assert_eq "VACUITY: the materialized corpus is non-empty (an empty tree makes every enumeration below report a clean zero)" \
  "$([[ "$MAT_FILES" -ge 100 ]] && echo populated || echo "ONLY $MAT_FILES FILES")" "populated"

git -C "$MAT" rev-parse HEAD >/dev/null 2>&1; MAT_GIT_RC=$?
git -C "$GATE_REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; REAL_GIT_RC=$?
assert_eq "inside the materialized corpus \`git rev-parse\` FAILS -- so any population rule expressed in git enumerates nothing there" \
  "$([[ "$MAT_GIT_RC" -ne 0 ]] && echo fails || echo "SUCCEEDED rc=$MAT_GIT_RC")" "fails"
assert_eq "NON-ZERO CONTROL for the row above: the same command in the checkout SUCCEEDS, so the failure is the missing .git and not a broken invocation" \
  "$REAL_GIT_RC" "0"

assert_eq "AC1 FLOOR FIXTURE is reachable from the commit: $FLOOR_REL is in the materialized corpus" \
  "$([[ -f "$MAT/$FLOOR_REL" ]] && echo present || echo "MISSING: $FLOOR_REL")" "present"
# The round-1 corpus's own failure, kept as a LIVE control on the archive really excluding ignored
# content. IF THIS ROW EVER FAILS the file was tracked by some later change and this control needs a
# new subject -- it is not evidence that the archive stopped excluding anything.
assert_eq "CONTROL: .pipeline/106/impl-report.json is NOT in the corpus (gitignored), while .pipeline/106/status.json IS -- if this flips, the file was tracked later and this control needs a new subject" \
  "$([[ ! -f "$MAT/.pipeline/106/impl-report.json" && -f "$MAT/.pipeline/106/status.json" ]] && echo "excluded-and-included" || echo "MOVED: impl-report=$([[ -f "$MAT/.pipeline/106/impl-report.json" ]] && echo in || echo out) status=$([[ -f "$MAT/.pipeline/106/status.json" ]] && echo in || echo out)")" \
  "excluded-and-included"

# ===============================================================================================
suite "AC1 (density half): the structural class is the hook's VALUE, never its source text"
# ===============================================================================================
#
# `_STRUCT` is assigned from a DOUBLE-QUOTED string opening with the variable reference `$_NL` and
# carrying a deliberately DOUBLED backslash. Read AS TEXT it yields a FIFTEEN member set that ADDS
# `$ _ N L` and LOSES the newline. Measured at 62d7a17: impl-report.schema.json reads 8.38 B/struct
# (rank 2 of the 159 tracked files at or above 2000 bytes) under the evaluated class and 11.44
# B/struct (rank 47) under the source-text one -- so a density ranking built on the source text
# never selects the dense end of the corpus at all, and the sentinel control cannot catch that
# because the sentinel is chosen by the same wrong ranking.

STRUCT_LINES="$(tb_struct_assign_lines "$MAT/$HOOK_REL" | grep -c . | tr -d ' \n')"
assert_eq "exactly ONE line assigns _STRUCT in the hook (a red here means the hook's set MOVED SHAPE -- e.g. refactored into a concatenation, the form _DELIMS already uses -- not that the density figures are wrong)" \
  "$STRUCT_LINES" "1"
STRUCT_CLASS="$(tb_struct_class "$MAT/$HOOK_REL" || printf '')"
assert_eq "MEMBERSHIP PIN: the EVALUATED class has exactly 12 distinct characters (the source-text reading has 15)" \
  "$(tb_struct_distinct "$STRUCT_CLASS")" "12"
assert_eq "MEMBERSHIP PIN: a NEWLINE is a member (the source-text reading loses it, and it is the most frequent structural character in the corpus)" \
  "$(tb_struct_has "$STRUCT_CLASS" '
')" "yes"
assert_eq "MEMBERSHIP PIN: a BACKSLASH is a member (the doubling in the source is one escaped backslash, not two members)" \
  "$(tb_struct_has "$STRUCT_CLASS" '\')" "yes"
assert_eq "MEMBERSHIP PIN: a DOUBLE QUOTE is a member" "$(tb_struct_has "$STRUCT_CLASS" '"')" "yes"
assert_eq "DISCRIMINATION: \`\$\` is NOT a member (it is a member only of the source-text reading, so this row is what separates the correct extraction from the plausible one)" \
  "$(tb_struct_has "$STRUCT_CLASS" '$')" "no"
assert_eq "DISCRIMINATION: \`L\` is NOT a member (it enters only from the \$_NL reference in the source text)" \
  "$(tb_struct_has "$STRUCT_CLASS" 'L')" "no"

# GATE-BITES PROOF, run rather than recorded: delete one member from _STRUCT in a COPY of the tree
# and require the density figure to MOVE. A counter that reports an unchanged number after the
# hook's own set is mutated is reading a private copy of the class.
new_tmpdir || exit 90
STRUCT_MUT="$NEW_TMPDIR/structmut"
mkdir -p "$STRUCT_MUT/$(dirname "$HOOK_REL")"
cp "$MAT/$HOOK_REL" "$STRUCT_MUT/$HOOK_REL"
"$GATE_REAL_NODE" -e '
  const fs = require("node:fs");
  const p = process.argv[1];
  const src = fs.readFileSync(p, "utf8");
  fs.writeFileSync(p, src.replace(/^_STRUCT="(.*)#"$/m, (m, g) => `_STRUCT="${g}"`));
' "$STRUCT_MUT/$HOOK_REL"
STRUCT_MUT_CLASS="$(tb_struct_class "$STRUCT_MUT/$HOOK_REL" || printf '')"
assert_eq "MUTATION LANDED: removing \`#\` from _STRUCT leaves 11 distinct members" \
  "$(tb_struct_distinct "$STRUCT_MUT_CLASS")" "11"
DENS_BEFORE="$(tb_density "$STRUCT_CLASS" "$MAT/plugins/pipeline/schemas/impl-report.schema.json")"
DENS_AFTER="$(tb_density "$STRUCT_MUT_CLASS" "$MAT/plugins/pipeline/schemas/impl-report.schema.json")"
assert_eq "GATE BITES: the density figure MOVES when the hook's own _STRUCT is mutated (before [$DENS_BEFORE] after [$DENS_AFTER])" \
  "$([[ "$DENS_BEFORE" != "$DENS_AFTER" && -n "$DENS_BEFORE" ]] && echo moved || echo "UNCHANGED -- the counter is reading a private copy of the class")" \
  "moved"
record "DENSITY of impl-report.schema.json over the evaluated class: $DENS_BEFORE (bytes struct B/struct); over the \`#\`-deleted class: $DENS_AFTER"

# THE SECOND MUTATION IS THE DISCRIMINATING ONE. Deleting `#` moves the count by a single character
# on this fixture, which proves granularity but would also pass on a counter that agreed by luck.
# Deleting the NEWLINE moves it by hundreds, and the newline is precisely the member the source-text
# reading LOSES -- so this is the mutation that separates "reads the hook's value" from "reads the
# hook's source text".
new_tmpdir || exit 90
STRUCT_NL="$NEW_TMPDIR/structnl"
mkdir -p "$STRUCT_NL/$(dirname "$HOOK_REL")"
cp "$MAT/$HOOK_REL" "$STRUCT_NL/$HOOK_REL"
"$GATE_REAL_NODE" -e '
  const fs = require("node:fs");
  const p = process.argv[1];
  const src = fs.readFileSync(p, "utf8");
  fs.writeFileSync(p, src.replace(/^_STRUCT="\$_NL/m, `_STRUCT="`));
' "$STRUCT_NL/$HOOK_REL"
STRUCT_NL_CLASS="$(tb_struct_class "$STRUCT_NL/$HOOK_REL" || printf '')"
assert_eq "MUTATION LANDED: removing \`\$_NL\` from _STRUCT leaves 11 distinct members" \
  "$(tb_struct_distinct "$STRUCT_NL_CLASS")" "11"
DENS_NONL="$(tb_density "$STRUCT_NL_CLASS" "$MAT/plugins/pipeline/schemas/impl-report.schema.json")"
assert_eq "GATE BITES (discriminating): dropping the NEWLINE from the hook's own class moves the density by more than 1 B/struct -- evaluated [$DENS_BEFORE] against newline-less [$DENS_NONL]" \
  "$( "$GATE_REAL_NODE" -e '
     const a = Number(process.argv[1]), b = Number(process.argv[2]);
     if (!Number.isFinite(a) || !Number.isFinite(b)) { process.stdout.write("NOT COMPARABLE"); process.exit(0); }
     process.stdout.write(Math.abs(a - b) > 1 ? "moved" : "BARELY MOVED: " + Math.abs(a - b).toFixed(2));
   ' "$(printf '%s' "$DENS_BEFORE" | awk '{print $3}')" "$(printf '%s' "$DENS_NONL" | awk '{print $3}')" )" \
  "moved"

# ===============================================================================================
suite "AC9: the declaration stays strictly under the platform default, in SECONDS"
# ===============================================================================================
assert_eq "a timeout is DECLARED (absent is indistinguishable from taking the platform's 600 s default)" \
  "$([[ -n "$DECLARED_S" ]] && echo declared || echo "ABSENT-OR-NON-INTEGER")" "declared"
assert_eq "AC9: the declared timeout is STRICTLY LESS than the 600 SECONDS Claude Code 2.1.85's \`E=H.timeout?H.timeout*1000:EL\`, \`EL=600000\` takes as its default" \
  "$([[ -n "$DECLARED_S" && "$DECLARED_S" -lt 600 && "$DECLARED_S" -gt 0 ]] && echo under-600 || echo "OUT OF RANGE: [$DECLARED_S]")" \
  "under-600"

# ===============================================================================================
suite "AC2: the covered floor, with BOTH recorded spreads applied to the number"
# ===============================================================================================
#
# THE INEQUALITY IS EVALUATED, NOT ASSERTED BESIDE THE FIGURE:
#     min_of_3_ms x LOAD_SPREAD (1.42) x HOST_SPREAD (1.32) <= declared_ms
# Both spreads are figures spec.json's measured_state records as the reason a margin was chosen; a
# criterion that compares an unadjusted min-of-3 against the declaration cannot then exclude them
# from the arithmetic that applies the margin.
#
# THE FLOOR IS THE LARGEST TRACKED ARTIFACT STAGED IN ONE BASH CALL, read from the materialized
# corpus so AC1 holds: knowledge/issue-archive/106.json as a heredoc body followed by `git add -A`.
# AT HEAD THIS ROW IS RED: 7366 x 1.42 x 1.32 = 13,807 ms against a declared 5000 ms.
#
# ON WHICH BYTE COUNT IS PINNED. The file is 461,758 bytes at 62d7a17 and carries 19,307 structural
# characters as a FILE; the COMMAND built around it carries the heredoc wrapper's own structural
# characters too. Both figures are correct and they are not the same figure. Everything below
# measures and records the COMMAND, and says so.

P4="$TEMP_PROJECT/p4"
gate_inflight_status "$P4/.pipeline/106/status.json" "4-review"

FLOOR_BODY="$(cat "$MAT/$FLOOR_REL" 2>/dev/null)"
FLOOR_DENY_CMD="cat > notes.md <<'EOF'
$FLOOR_BODY
EOF
git add -A"
FLOOR_ALLOW_CMD="cat > notes.md <<'EOF'
$FLOOR_BODY
EOF
git add plugins/pipeline/agents/dba.md"
FLOOR_CMD_BYTES="${#FLOOR_DENY_CMD}"
FLOOR_FILE_DENS="$(tb_density "$STRUCT_CLASS" "$MAT/$FLOOR_REL")"
assert_eq "VACUITY: the floor fixture's body was read from the materialized corpus and is non-empty" \
  "$([[ "$FLOOR_CMD_BYTES" -gt 100000 ]] && echo read || echo "ONLY $FLOOR_CMD_BYTES COMMAND BYTES")" "read"

now_ms() { "$GATE_REAL_NODE" -e 'process.stdout.write(String(Date.now()))'; }
FLOOR_MS=()
FLOOR_DECISION=""
FLOOR_STDOUT_BYTES=""
for _i in 1 2 3; do
  gate_reset_env "$P4"
  _a="$(now_ms)"
  run_gate "$(gate_payload "$FLOOR_DENY_CMD" agent_id=sub-panelist-1 agent_type=pipeline:qa)"
  _b="$(now_ms)"
  FLOOR_MS+=( "$(( _b - _a ))" )
  FLOOR_DECISION="$GATE_DECISION"
  FLOOR_STDOUT_BYTES="${#GATE_OUT}"
done
FLOOR_MIN="$(tb_min3 "${FLOOR_MS[0]}" "${FLOOR_MS[1]}" "${FLOOR_MS[2]}")"
FLOOR_ADJ=$(( FLOOR_MIN * LOAD_SPREAD_X100 * HOST_SPREAD_X100 / 10000 ))
record "AC2 FLOOR: $FLOOR_CMD_BYTES COMMAND bytes (file is $FLOOR_FILE_DENS as bytes/struct/B-per-struct), runs ${FLOOR_MS[0]}/${FLOOR_MS[1]}/${FLOOR_MS[2]} ms, min-of-3 $FLOOR_MIN ms, load $(tb_loadavg) on $(uname -sr); adjusted $FLOOR_ADJ ms = $FLOOR_MIN x 1.42 x 1.32"

assert_eq "AC2 NON-VACUITY: the floor fixture actually DENIES (a measurement of a gate that returned 'none' is a measurement of the wrong thing)" \
  "$FLOOR_DECISION" "deny"
assert_eq "AC2 NON-VACUITY: and it emitted a non-empty decision on stdout ($FLOOR_STDOUT_BYTES bytes)" \
  "$([[ "$FLOOR_STDOUT_BYTES" -gt 0 ]] && echo emitted || echo "ZERO BYTES")" "emitted"
# The ALLOW-side control at the IDENTICAL body: without it the row above is equally consistent with
# a gate that denies whatever it finds expensive.
gate_reset_env "$P4"
_a="$(now_ms)"
run_gate "$(gate_payload "$FLOOR_ALLOW_CMD" agent_id=sub-panelist-1 agent_type=pipeline:qa)"
_b="$(now_ms)"
FLOOR_ALLOW_MS=$(( _b - _a ))
FLOOR_ALLOW_DECISION="$GATE_DECISION"
assert_eq "AC2 ALLOW-SIDE CONTROL: the same $FLOOR_CMD_BYTES-byte body followed by a narrowed \`git add <path>\` returns none" \
  "$FLOOR_ALLOW_DECISION" "none"
record "AC2 ALLOW-PATH STALL: the correctly narrowed call paid $FLOOR_ALLOW_MS ms against the denied arm's $FLOOR_MIN ms on the identical body -- this is the latency AC13(d) requires the disclosure to publish"

# ATTRIBUTION FOR THE ROW BELOW, because it is the one row here whose red has two possible causes.
# The 1.42 LOAD SPREAD spec.json records was taken on a SAME-HOST comparison, not across an idle
# and a saturated host, so it does not cover an arbitrarily loaded runner. MEASURED during this
# contract's own mutation battery: the identical fixture read 9,093 ms min-of-3 at load 9.4 and
# 12,203 ms min-of-3 at load ~12 while four suite runs were in flight, and at a declared 20 s the
# row flipped from green to red purely on that. So the transcript records the load beside the
# figure and a reader compares it against the load the spread was derived under; a red at a load
# far above it is the runner, and a red at a comparable load is the declaration.
record "AC2 ATTRIBUTION: load at measurement $(tb_loadavg) against the same-host spread of 1.42 that spec.json's measured_state derives from a comparison at load 4.5 and load 10.3-13.1. A red below at a load far above that band is the runner; at a comparable load it is the declaration."
assert_eq "AC2: min_of_3 x 1.42 x 1.32 <= the declared timeout ($FLOOR_ADJ ms against ${DECLARED_MS} ms). A row over this is a BYPASS: the hook is killed, emits nothing, and the blanket staging is ALLOWED" \
  "$([[ "$DECLARED_MS" -gt 0 && "$FLOOR_ADJ" -le "$DECLARED_MS" ]] && echo covered || echo "UNCOVERED: $FLOOR_ADJ ms adjusted needs a declaration of at least $(( (FLOOR_ADJ + 999) / 1000 )) s, declared ${DECLARED_S:-<none>} s at load $(tb_loadavg)")" \
  "covered"

# ===============================================================================================
suite "AC3 + AC11: the dense cell, and the fail-open PAIR built at a length that discriminates"
# ===============================================================================================
#
# THE DENSE END IS NOT A .json. At 62d7a17 the densest tracked file at or above 2000 bytes is
# plugins/pipeline/tests/test-frontend-surface.sh at 8.30 B/struct, ahead of
# plugins/pipeline/schemas/impl-report.schema.json at 8.38; ranks 3 and 4 are also `.sh`. The cell
# below is therefore built from whatever the run-time enumeration says is densest, whatever its
# extension, and the choice is RECORDED so a reader holding only the commit can rebuild the body.
#
# AC11's pair must still DISCRIMINATE after the raise, and at some length it always can. The
# multiplicity is therefore CALIBRATED at run time from one small measurement rather than frozen:
# a fixed copy count sized on darwin would make the killed arm emit output on a faster runner and
# the row would go red for a gate that is working. The chosen length is recorded, as AC11 requires.

DENSEST_REL="$(tb_rank "$STRUCT_CLASS" "$MAT" 2000 | head -1 | cut -f4)"
assert_eq "VACUITY: a densest tracked file was selected by the run-time enumeration" \
  "$([[ -n "$DENSEST_REL" && -f "$MAT/$DENSEST_REL" ]] && echo selected || echo "NONE SELECTED: [$DENSEST_REL]")" "selected"
DENSEST_DENS="$(tb_density "$STRUCT_CLASS" "$MAT/$DENSEST_REL")"
DENSEST_BYTES="$(printf '%s' "$DENSEST_DENS" | awk '{print $1}')"
record "AC3 DENSE END selected at run time: $DENSEST_REL -- $DENSEST_DENS (bytes struct B/struct)"

# ---- THE BODY: one file, one pad settled by outcome, and a size found by a BOUNDED CLIMB --------
#
# The command is built into a FILE, never into an argv. The pair AC11 needs is megabytes at the
# raised bound, and the shared argv-based payload builder fails silently above Linux's
# MAX_ARG_STRLEN: a 3,111,437-byte command came back as an EMPTY payload and the gate answered
# `none` in 352 ms -- a fixture reporting an ALLOW for a gate that was working.
DENSE_CMD_FILE="$TEMP_PROJECT/dense.cmd"
# 16 MB since 0.40.2, from 6 MB. The ceiling bounds the work this harness PERFORMS, not the
# property; it has to sit above the length the pair needs on the FASTEST host this suite runs on.
# 0.40.0 changed the densest unit to tests/test-materiality.sh (9640 bytes/copy), and on
# ubuntu-latest the gate then decided 5996118 bytes in 26.6 s -- under the 30 s kill -- so the
# climb hit the ceiling before it could build arm two (CI run 33905241529). Darwin reaches the
# target at ~2 MB and is unaffected. The recorded-curve fixture below keeps its own 906-copy
# ceiling from the 6 MB era, on purpose: it is a fixed oracle, not a mirror of this constant.
DENSE_MAX_BYTES=16000000
DENSE_PAD=""
dense_write() {  # <copies> [pad] -> writes the command to DENSE_CMD_FILE and prints its byte count
  "$GATE_REAL_NODE" -e '
    const fs = require("node:fs");
    const q = String.fromCharCode(39);
    const src = fs.readFileSync(process.argv[1]).toString("latin1");
    const body = (src + process.argv[3]).repeat(Number(process.argv[2]));
    const cmd = "cat > notes.md <<" + q + "EOF" + q + "\n" + body + "\nEOF\ngit add -A";
    fs.writeFileSync(process.argv[4], Buffer.from(cmd, "latin1"));
    process.stdout.write(String(Buffer.byteLength(cmd, "latin1")));
  ' "$MAT/$DENSEST_REL" "$1" "${2-$DENSE_PAD}" "$DENSE_CMD_FILE"
}

# THE TWO ARMS SHARE ONE RUNNER (tb_gate_bounded): the same resolved hook command from hooks.json,
# the same payload, the same environment, two different wall-clock bounds. Before #132's B1 fix arm
# one went through run_gate and arm two through a separate killer, so the only thing making them
# the same call was that two blocks of the suite agreed about it.
dense_bounded() {  # <bound-seconds> -> TB_GB_MS TB_GB_KILLED TB_GB_DECISION TB_GB_OUT_BYTES
  tb_gate_bounded \
    "$(tb_payload_file "$DENSE_CMD_FILE" "$P4" agent_id=sub-panelist-1 agent_type=pipeline:qa)" \
    "$P4" "$1"
}

# WHAT THE PAIR NEEDS, AND WHAT THE FIT AIMS AT, ARE TWO DIFFERENT NUMBERS.
#
#   ACCEPT is the property. Arm two runs the same body under the declared kill and must not finish
#   inside it. Arm one and arm two are two runs on one host, so the margin arm two needs over arm
#   one is the SAME-HOST LOAD SPREAD this suite already carries from spec.json's measured_state
#   (1.42, the figure LOAD_SPREAD_X100 holds). Below that margin a quieter moment could let arm two
#   finish and emit bytes, and the pair would go red for a gate that is working.
#
#   AIM is deliberately ABOVE accept (1.5x the declaration), because a probe that lands just under
#   accept costs a whole further probe of the same size, while one that lands above it costs only
#   the difference.
TARGET_MS=$(( DECLARED_MS * 15 / 10 ))
ACCEPT_MS=$(( DECLARED_MS * LOAD_SPREAD_X100 / 100 ))
DENSE_CAP_X100=3200        # no candidate is more than 32x the largest count actually MEASURED
DENSE_MAX_STEPS=6
DENSE_PROBE_BOUND_S=$(( TARGET_MS * 2 / 1000 ))
[[ "$DENSE_PROBE_BOUND_S" -lt 1 ]] && DENSE_PROBE_BOUND_S=1

# QUOTE PARITY IS SETTLED BY OUTCOME AND CARRIED PER COPY, NEVER COUNTED. An unbalanced quote
# earlier in the command defeats the blanket-staging refusal entirely (#140), so a body the scanner
# reads as quote-open answers `none` and would be recorded as a gate that is working. The obvious
# guard -- count `"` and `'` in the raw bytes and append one of each when the count is odd -- is on
# the WRONG SIDE OF THE TRANSFORMATION and was measured to break what it guards: the scanner
# resolves backslash escapes before it counts, knowledge/issue-archive/106.json carries an ODD raw
# double-quote count and is refused correctly, and appending a balancing quote to it flipped a
# working `deny` into `none`.
#
# AND THE PAD GOES INSIDE THE REPEATED UNIT, which is the half a per-body pad gets wrong. This body
# is one source file repeated N times. A pad computed from ONE copy and appended ONCE is correct
# only when N is odd: at an even N the concatenation is already balanced and the pad UNBALANCES it.
# Padding the UNIT instead makes the property hold for every N, and the outcome search below proves
# the unit is balanced at the smallest N the fixture ever drives.
DENSE_PAD_TRIED=""
DENSE_PAD_FOUND="no"
CAL_C1=4; CAL_C2=16
CAL_B1=""; CAL_MS1=""; CAL_D1=""
for _pad in "" '"' "'" "\"'"; do
  CAL_B1="$(dense_write "$CAL_C1" "$_pad")"
  dense_bounded "$DENSE_PROBE_BOUND_S"
  CAL_MS1="$TB_GB_MS"; CAL_D1="$TB_GB_DECISION"
  DENSE_PAD_TRIED="$DENSE_PAD_TRIED [pad=[${_pad}] -> ${CAL_D1} in ${CAL_MS1}ms]"
  if [[ "$CAL_D1" == "deny" ]]; then DENSE_PAD="$_pad"; DENSE_PAD_FOUND="yes"; break; fi
done
record "AC11 PAD SEARCH on $DENSEST_REL:$DENSE_PAD_TRIED -- kept [${DENSE_PAD}] (${#DENSE_PAD} character(s), carried once per copy). A row needing a pad is a live #140 instance on tracked content"
assert_eq "AC11 PAD: the fixture's quote parity is settled by OUTCOME -- some pad in the searched set makes the smallest cell DENY. Counting raw quotes sits on the wrong side of the scanner's escape resolution and was measured to break the very refusal it guards (#140)" \
  "$DENSE_PAD_FOUND" "yes"

# THE CEILING IS INVERTED INTO A COPY COUNT AND CLAMPS EVERY CANDIDATE BEFORE IT IS WRITTEN. The
# body is exactly (source + pad) x N inside a fixed wrapper, so the inversion is algebra and not a
# fit: two writes with no gate run give the unit and the wrapper. The old fixture asserted this
# ceiling AFTER building and driving a 23,159,538-byte body, so the ceiling was a verdict on work
# already paid for -- eleven minutes and forty seconds of it, twice per CI job.
DENSE_B_ONE="$(dense_write 1)"
DENSE_B_TWO="$(dense_write 2)"
DENSE_UNIT_BYTES=$(( DENSE_B_TWO - DENSE_B_ONE ))
DENSE_WRAP_BYTES=$(( DENSE_B_ONE - DENSE_UNIT_BYTES ))
DENSE_MAX_COPIES=0
[[ "$DENSE_UNIT_BYTES" -gt 0 ]] && DENSE_MAX_COPIES=$(( (DENSE_MAX_BYTES - DENSE_WRAP_BYTES) / DENSE_UNIT_BYTES ))
assert_eq "AC11 CEILING PREMISE: the ${DENSE_MAX_BYTES}-byte ceiling inverts to $DENSE_MAX_COPIES copies of a ${DENSE_UNIT_BYTES}-byte unit plus a ${DENSE_WRAP_BYTES}-byte wrapper, which leaves the climb room above its ${CAL_C2}-copy calibration" \
  "$([[ "$DENSE_MAX_COPIES" -gt "$CAL_C2" ]] && echo "room-above-calibration" || echo "ONLY $DENSE_MAX_COPIES COPIES FIT, against a $CAL_C2 copy calibration")" \
  "room-above-calibration"

# The second calibration point. Two points separate the constant from the slope; the FLOOR above
# separates the gate's start-up from both.
CAL_B2="$(dense_write "$CAL_C2")"
dense_bounded "$DENSE_PROBE_BOUND_S"
CAL_MS2="$TB_GB_MS"; CAL_D2="$TB_GB_DECISION"
assert_eq "CALIBRATION NON-VACUITY: both calibration cells DENY (a 'none' here means the fixture -- an unbalanced quote or a truncated payload -- and every extrapolation from it would be wrong)" \
  "$CAL_D1/$CAL_D2" "deny/deny"
assert_eq "CALIBRATION NON-VACUITY: the larger cell costs measurably more than the smaller ($CAL_MS1 -> $CAL_MS2 ms). A flat pair means the instrument is measuring its own floor and the fit below is meaningless" \
  "$([[ "$CAL_MS2" -gt "$CAL_MS1" && "$CAL_MS1" -ge 50 ]] && echo "slope-present" || echo "FLAT OR TOO FAST: ${CAL_MS1} -> ${CAL_MS2} ms")" \
  "slope-present"

# THE TERM THAT DOES NOT SCALE WITH LENGTH, taken from the same two points the exponent is estimated
# from. Two node starts and a resolver run happen before the gate reads a byte, and a power law
# fitted to the RAW milliseconds reads that overhead as sub-linear growth: on this host's own
# calibration that spurious curve asks for MORE copies than the straight line it replaces.
# INDEPENDENTLY MEASURED BESIDE IT, and recorded rather than substituted: a bare `git add -A` with
# no body at all, which is the same deny branch with the length term removed. The two are different
# observations of one quantity and the transcript carries both, so a reader can see when they part.
DENSE_FIT_FLOOR="$(tb_fit_floor "$CAL_C1" "$CAL_MS1" "$CAL_C2" "$CAL_MS2")"
DENSE_FLOOR_FILE="$TEMP_PROJECT/dense.floor.cmd"
printf 'git add -A' > "$DENSE_FLOOR_FILE"
tb_gate_bounded \
  "$(tb_payload_file "$DENSE_FLOOR_FILE" "$P4" agent_id=sub-panelist-1 agent_type=pipeline:qa)" \
  "$P4" "$DENSE_PROBE_BOUND_S"
DENSE_FLOOR_MS="$TB_GB_MS"; DENSE_FLOOR_DECISION="$TB_GB_DECISION"
record "AC11 GATE FLOOR: the two-point line's intercept is $DENSE_FIT_FLOOR ms and is what the fit subtracts; a bare \`git add -A\` with no body measured $DENSE_FLOOR_MS ms ($DENSE_FLOOR_DECISION) at load $(tb_loadavg) as the independent observation of the same quantity ($(( DENSE_FLOOR_MS * 100 / (DENSE_FIT_FLOOR < 1 ? 1 : DENSE_FIT_FLOOR) ))/100 of it)"
# THE COMPARISON IS AGAINST THE LARGER CELL, AND THE SMALLER ONE IS WHY. This row first required
# the measured floor to be under the SMALLEST cell, and that is false on the host CI evaluates:
# ubuntu-latest run 33757283077 read a 231 ms floor against a 229 ms 4-copy cell, because 26,506
# bytes of scanning costs dash almost nothing and the smallest cell is then ~100% overhead. That is
# the expected physics of a fast host, not a broken measurement, and the row was red for it. What
# the fit actually needs -- an intercept strictly under the smallest cell -- is the FIT-FLOOR
# PREMISE row below, which is asserted on the quantity the fit uses. This row stays a control on
# that one: same branch, positive, and under the LARGER cell, so a length term is separable at all.
assert_eq "AC11 FLOOR NON-VACUITY: the independently measured overhead took the SAME deny branch the sized cells take (a floor measured on the allow branch would be the wrong constant) and sits under the LARGER calibration cell, so a length term is separable at all ($DENSE_FLOOR_MS ms against $CAL_MS2 ms; it is deliberately NOT required to be under the 4-copy cell, which is ~100% overhead on a fast host)" \
  "$([[ "$DENSE_FLOOR_DECISION" == "deny" && "$DENSE_FLOOR_MS" -gt 0 && "$DENSE_FLOOR_MS" -lt "$CAL_MS2" ]] && echo "below-the-larger-cell" || echo "GOT $DENSE_FLOOR_DECISION in $DENSE_FLOOR_MS ms against a ${CAL_MS2} ms 16-copy cell")" \
  "below-the-larger-cell"
assert_eq "AC11 FIT-FLOOR PREMISE: the intercept the fit subtracts is a fraction of the smallest measured cell, not the whole of it ($DENSE_FIT_FLOOR ms of $CAL_MS1 ms) -- an intercept at or above the cell means the two calibration points could not separate a constant from a slope" \
  "$([[ "$DENSE_FIT_FLOOR" -ge 0 && "$DENSE_FIT_FLOOR" -lt "$CAL_MS1" ]] && echo "separated" || echo "INTERCEPT $DENSE_FIT_FLOOR ms against a ${CAL_MS1} ms smallest cell")" \
  "separated"

# THE CLIMB. Each step re-estimates the exponent from the two most recent MEASURED points with the
# floor subtracted, caps the candidate at 32x the largest measured count and at the ceiling, and
# runs it under a wall-clock bound of twice the aim. A killed probe is not a stall: it fixes an
# upper bracket and the climb halves the gap. See fixtures/timeout-bound-lib.sh for the recorded
# reason the single straight-line solve this replaces cannot be salvaged by lowering the target.
DENSE_DECISION=""; DENSE_OUT_BYTES=0; DENSE_BYTES="$CAL_B2"
dense_probe() {  # <copies> -> tb_climb's contract (TB_PROBE_MS/TB_PROBE_KILLED) plus this fixture's
  local b
  b="$(dense_write "$1")"
  dense_bounded "$DENSE_PROBE_BOUND_S"
  TB_PROBE_MS="$TB_GB_MS"; TB_PROBE_KILLED="$TB_GB_KILLED"
  # A killed probe emits no decision, so it must not overwrite the last cell that produced one.
  if [[ "$TB_GB_KILLED" != "1" ]]; then
    DENSE_BYTES="$b"; DENSE_DECISION="$TB_GB_DECISION"; DENSE_OUT_BYTES="$TB_GB_OUT_BYTES"
  fi
}
DENSE_DECISION="$CAL_D2"; DENSE_OUT_BYTES=1
tb_climb dense_probe "$CAL_C1" "$CAL_MS1" "$CAL_C2" "$CAL_MS2" "$DENSE_FIT_FLOOR" \
  "$TARGET_MS" "$ACCEPT_MS" "$DENSE_CAP_X100" "$DENSE_MAX_COPIES" "$DENSE_MAX_STEPS"
DENSE_COPIES="$TB_CLIMB_COPIES"; DENSE_MS="$TB_CLIMB_MS"; DENSE_STOP="$TB_CLIMB_STOP"
# Re-write the ACCEPTED body, so arm two below drives the identical command whatever the last probe
# in the climb happened to be.
DENSE_BYTES="$(dense_write "$DENSE_COPIES")"
DENSE_ADJ=$(( DENSE_MS * LOAD_SPREAD_X100 * HOST_SPREAD_X100 / 10000 ))
record "AC11 CALIBRATION: $CAL_C1 copies = $CAL_B1 bytes in $CAL_MS1 ms and $CAL_C2 copies = $CAL_B2 bytes in $CAL_MS2 ms, over a ${DENSE_FIT_FLOOR} ms fitted gate floor (${DENSE_FLOOR_MS} ms measured independently), at load $(tb_loadavg); aim ${TARGET_MS} ms (1.5x the declared ${DECLARED_MS}), accept ${ACCEPT_MS} ms (the declared timeout x the 1.42 same-host load spread)"
record "AC11 CLIMB: stop=$DENSE_STOP after $TB_CLIMB_PROBES probe(s), cap 32x per step, ceiling $DENSE_MAX_COPIES copies, per-probe wall-clock bound ${DENSE_PROBE_BOUND_S}s --$TB_CLIMB_TRACE"
record "AC3 CONSTRUCTED DENSE CELL: $DENSE_COPIES concatenated copies of $DENSEST_REL = $DENSE_BYTES command bytes at $(printf '%s' "$DENSEST_DENS" | awk '{print $3}') B/struct -> $DENSE_DECISION in $DENSE_MS ms (adjusted $DENSE_ADJ ms) at load $(tb_loadavg) on $(uname -sr)"
assert_eq "AC11 ARM ONE (unbounded): the ${DENSE_BYTES}-byte dense cell DECIDES, and emits a non-empty decision ($DENSE_OUT_BYTES bytes of stdout)" \
  "$([[ "$DENSE_DECISION" == "deny" && "$DENSE_OUT_BYTES" -gt 0 ]] && echo "deny-with-output" || echo "GOT $DENSE_DECISION with $DENSE_OUT_BYTES bytes -- a 'none' at this size is the fixture (payload truncation or quote parity), not the gate")" \
  "deny-with-output"
assert_eq "AC11 SIZE CEILING: the climb stopped because it REACHED the length the pair needs, not because it ran out of room -- accepted at $DENSE_BYTES of the ${DENSE_MAX_BYTES}-byte ceiling, $DENSE_MS ms against the ${ACCEPT_MS} ms accept. A 'ceiling' here means AC11's pair is no longer constructible from this corpus at this declaration" \
  "$DENSE_STOP" "target"
assert_eq "AC11 CEILING ARITHMETIC: the accepted body really is inside the ceiling the copy cap was inverted from, so the clamp is a bound on work PERFORMED and not a verdict on work already paid for ($DENSE_BYTES bytes at $DENSE_COPIES copies)" \
  "$([[ "$DENSE_BYTES" -le "$DENSE_MAX_BYTES" && "$DENSE_COPIES" -le "$DENSE_MAX_COPIES" ]] && echo "within-ceiling" || echo "NEEDED $DENSE_BYTES BYTES AT $DENSE_COPIES COPIES, over the ${DENSE_MAX_BYTES} / ${DENSE_MAX_COPIES} ceiling")" \
  "within-ceiling"

# ARM TWO: the same command through the same runner and the same resolved hook command, killed at
# the DECLARED timeout. ZERO BYTES of stdout, which is what makes the call fall open.
dense_bounded "${DECLARED_S:-5}"
KILL_BYTES="$TB_GB_OUT_BYTES"; KILL_KILLED="$TB_GB_KILLED"; KILL_MS="$TB_GB_MS"
assert_eq "AC11 ARM TWO (killed at the declared ${DECLARED_S:-?} s): the SAME command through the SAME resolved hook command emits ZERO BYTES -- and a PreToolUse hook that emits nothing FAILS OPEN, so the blanket staging is allowed" \
  "$KILL_BYTES" "0"
assert_eq "AC11 ARM TWO was really KILLED at ${DECLARED_S:-?} s rather than finishing early and happening to print nothing (${KILL_MS} ms). Without this the zero above is equally consistent with a gate that returned silently" \
  "$KILL_KILLED" "1"
assert_eq "AC11 DISCRIMINATION: the pair discriminates -- arm one emitted $DENSE_OUT_BYTES bytes at $DENSE_MS ms, arm two emitted $KILL_BYTES at the ${DECLARED_S:-?} s kill. If arm one finished INSIDE the kill the pair proves nothing" \
  "$([[ "$DENSE_MS" -gt "$DECLARED_MS" ]] && echo discriminates || echo "ARM ONE FINISHED IN $DENSE_MS ms, INSIDE the ${DECLARED_MS} ms kill -- no discrimination at this length")" \
  "discriminates"

# ===============================================================================================
suite "AC11 SIZING METHOD: the climb driven against KNOWN cost curves, including the recorded one"
# ===============================================================================================
#
# THE ROWS ABOVE MEASURE THIS HOST. These rows measure the METHOD, and they are the non-zero
# controls for it: a sizing search whose failure modes have never been watched to fire is a search
# nobody has checked. The oracle is not invented. It is the ubuntu-latest curve CI actually
# recorded on run 33747342504, reconstructed to pass through all three of its measured points:
#
#     ms(c) = 137 + 18.375c                     for c <= 16     (Dev's fit: 137 ms + 18.4 per copy,
#     ms(c) = 137 + 294 (c/16)^1.4432           for c >  16      6617 bytes per copy)
#
#   c=4    -> 210 ms      the first calibration cell   (26,506 bytes)
#   c=16   -> 431 ms      the second                   (105,910 bytes)
#   c=3500 -> 700,560 ms  against the 700,683 the run recorded, 0.02% out -- what the straight line
#                         through those two points ASKED FOR, and got
#
# so the third point is the eleven-minute measurement itself. Anyone can re-derive the curve from
# the three figures; nothing here is fitted to the answer this block wants.
SYN_FLOOR=0   # derived per scenario by tb_fit_floor, exactly as the real climb derives it
syn_ms() {  # <copies> <high-exponent-x10000> -> the modelled milliseconds
  "$GATE_REAL_NODE" -e '
    const c = Number(process.argv[1]), p = Number(process.argv[2]) / 10000;
    const A = 18.375, F = 137, B = 16;
    const ms = c <= B ? F + A * c : F + A * B * Math.pow(c / B, p);
    process.stdout.write(String(Math.round(ms)));
  ' "$1" "$2"
}
SYN_P=14432          # the recorded curve
SYN_BOUND_MS=0
SYN_KILLS=0
SYN_MAX_FACTOR_X100=0
SYN_LAST_OK=0
syn_probe() {  # <copies>
  local c="$1" ms f
  ms="$(syn_ms "$c" "$SYN_P")"
  if [[ "$SYN_LAST_OK" -gt 0 ]]; then
    f=$(( c * 100 / SYN_LAST_OK ))
    [[ "$f" -gt "$SYN_MAX_FACTOR_X100" ]] && SYN_MAX_FACTOR_X100="$f"
  fi
  if [[ "$SYN_BOUND_MS" -gt 0 && "$ms" -gt "$SYN_BOUND_MS" ]]; then
    TB_PROBE_MS="$SYN_BOUND_MS"; TB_PROBE_KILLED=1; SYN_KILLS=$(( SYN_KILLS + 1 ))
  else
    TB_PROBE_MS="$ms"; TB_PROBE_KILLED=0; SYN_LAST_OK="$c"
  fi
}
syn_climb() {  # <high-exponent-x10000> <max-copies> <bound-ms>
  local m1 m2
  SYN_P="$1"; SYN_BOUND_MS="$3"; SYN_KILLS=0; SYN_MAX_FACTOR_X100=0; SYN_LAST_OK=16
  m1="$(syn_ms 4 "$SYN_P")"; m2="$(syn_ms 16 "$SYN_P")"
  # The floor comes through tb_fit_floor, exactly as the real climb above derives it, so this block
  # drives the same code path and not a simplified copy of it. On this oracle it returns 137, which
  # is the intercept the recorded ubuntu-latest fit had.
  SYN_FLOOR="$(tb_fit_floor 4 "$m1" 16 "$m2")"
  tb_climb syn_probe 4 "$m1" 16 "$m2" "$SYN_FLOOR" 45000 42600 3200 "$2" 6
}

# The ceiling in copies at the recorded 6617 bytes per copy, at the 6 MB ceiling this curve was
# recorded under: 6000000 / 6617 = 906. Fixed here even though DENSE_MAX_BYTES has since moved.
SYN_MAXC=906
# WHAT THE METHOD THIS REPLACES WOULD HAVE ASKED FOR, from the SAME two points: solve the straight
# line ms = 137 + 18.375c for 45000 and you get 2442 copies = 16.2 MB, over the ceiling and 15.6x
# past the target in time. That is the defect, stated as a number this row re-derives.
SYN_LINEAR="$("$GATE_REAL_NODE" -e 'process.stdout.write(String(Math.ceil((45000 - 137) / 18.375)))')"
syn_climb "$SYN_P" "$SYN_MAXC" 90000
record "AC11 METHOD on the recorded ubuntu-latest curve: stop=$TB_CLIMB_STOP at $TB_CLIMB_COPIES copies / $TB_CLIMB_MS ms in $TB_CLIMB_PROBES probe(s), largest step ${SYN_MAX_FACTOR_X100}/100 x;$TB_CLIMB_TRACE -- the straight line through the same two points asked for $SYN_LINEAR copies"
assert_eq "AC11 METHOD: on the curve ubuntu-latest actually measured, the climb REACHES the target inside the ceiling ($TB_CLIMB_COPIES copies of $SYN_MAXC, $TB_CLIMB_MS ms)" \
  "$([[ "$TB_CLIMB_STOP" == "target" && "$TB_CLIMB_COPIES" -le "$SYN_MAXC" && "$TB_CLIMB_MS" -ge 42600 ]] && echo "reached" || echo "stop=$TB_CLIMB_STOP at $TB_CLIMB_COPIES copies / $TB_CLIMB_MS ms")" \
  "reached"
assert_eq "AC11 METHOD: and it gets there in at most three probes ($TB_CLIMB_PROBES), which is the whole cost argument -- the row this replaces spent ONE probe of 700,683 ms, twice per CI job" \
  "$([[ "$TB_CLIMB_PROBES" -le 3 ]] && echo "cheap" || echo "$TB_CLIMB_PROBES PROBES")" "cheap"
assert_eq "AC11 METHOD CONTROL, and the reason this block exists: the SINGLE straight-line solve through the identical two points asks for $SYN_LINEAR copies, which is OVER the $SYN_MAXC-copy ceiling. The old fixture built and drove that body before checking" \
  "$([[ "$SYN_LINEAR" -gt "$SYN_MAXC" ]] && echo "over-the-ceiling" || echo "$SYN_LINEAR copies, inside the ceiling -- this control has lost its subject")" \
  "over-the-ceiling"
assert_eq "AC11 METHOD: no step of that climb exceeded the 32x cap on the largest MEASURED count (largest ${SYN_MAX_FACTOR_X100}/100 x)" \
  "$([[ "$SYN_MAX_FACTOR_X100" -le 3200 ]] && echo "capped" || echo "STEPPED ${SYN_MAX_FACTOR_X100}/100 x")" "capped"

# NON-ZERO CONTROL FOR THE `AC11 SIZE CEILING` ROW ABOVE. That row asserts stop=target; unless
# stop=ceiling has been watched to happen, it is a row nobody has seen fail. Same curve, a ceiling
# that cannot reach the target.
syn_climb "$SYN_P" 100 90000
record "AC11 METHOD (ceiling control): a 100-copy ceiling on the same curve -> stop=$TB_CLIMB_STOP at $TB_CLIMB_COPIES copies / $TB_CLIMB_MS ms;$TB_CLIMB_TRACE"
assert_eq "AC11 METHOD CONTROL: with a ceiling too small to reach the target the climb reports 'ceiling' and stops, rather than clamping silently and reporting a pair it never built" \
  "$TB_CLIMB_STOP" "ceiling"

# NON-ZERO CONTROL FOR THE PER-PROBE WALL-CLOCK BOUND. A curve that is linear where the calibration
# looks and cubic beyond it: the capped first step overruns the bound, is killed, and the climb has
# to bracket DOWN to land. Without this the kill branch is code no run has ever taken.
syn_climb 26000 "$SYN_MAXC" 90000
record "AC11 METHOD (kill/bracket control): a c^2.6 curve beyond the calibration -> stop=$TB_CLIMB_STOP at $TB_CLIMB_COPIES copies / $TB_CLIMB_MS ms after $TB_CLIMB_PROBES probes, $SYN_KILLS killed;$TB_CLIMB_TRACE"
assert_eq "AC11 METHOD CONTROL: on a curve steeper than the calibration can see, at least one probe HITS its wall-clock bound and is killed -- which is the difference between a bounded search and the 700,683 ms stall it replaces" \
  "$([[ "$SYN_KILLS" -ge 1 ]] && echo "bounded" || echo "NO PROBE WAS KILLED, so the bound never fired and this control validates nothing")" \
  "bounded"
assert_eq "AC11 METHOD CONTROL: and the climb still lands on the target after bracketing down from that kill (stop=$TB_CLIMB_STOP, $TB_CLIMB_COPIES copies, $TB_CLIMB_MS ms)" \
  "$([[ "$TB_CLIMB_STOP" == "target" && "$TB_CLIMB_MS" -ge 42600 ]] && echo "recovered" || echo "stop=$TB_CLIMB_STOP at $TB_CLIMB_MS ms")" \
  "recovered"

# AC3's disclosure obligation, evaluated as the CONDITIONAL it is: a cell that fails AC2's
# inequality must appear in the operator-facing disclosure with its milliseconds AND its density.
README_ITEM27="$(grep -n '^27\. ' "$MAT/$README_REL" 2>/dev/null | head -1 | cut -d: -f1)"
README_COST4="$(sed -n "${README_ITEM27:-1}p" "$MAT/$README_REL" 2>/dev/null)"
assert_eq "VACUITY: README item 27 was located and is non-empty (a grep that found nothing makes every disclosure row below pass by scanning an empty string)" \
  "$([[ "${#README_COST4}" -gt 2000 ]] && echo located || echo "ONLY ${#README_COST4} BYTES AT LINE ${README_ITEM27:-none}")" "located"
DENSE_UNCOVERED="$([[ "$DENSE_ADJ" -gt "$DECLARED_MS" ]] && echo uncovered || echo covered)"
record "AC3 CELL VERDICT under the inequality: adjusted $DENSE_ADJ ms against declared $DECLARED_MS ms -> $DENSE_UNCOVERED"
assert_eq "AC3: the uncovered dense cell is DISCLOSED -- README item 27 cost (4) names the source file the body is built from, so a reader holding only the commit can rebuild it" \
  "$(if [[ "$DENSE_UNCOVERED" == "covered" ]]; then echo "n/a: this cell is covered at the declared bound"
     elif [[ "$README_COST4" == *"$DENSEST_REL"* ]]; then echo disclosed
     else echo "NOT DISCLOSED: item 27 cost (4) does not name $DENSEST_REL"; fi)" \
  "$([[ "$DENSE_UNCOVERED" == "covered" ]] && echo "n/a: this cell is covered at the declared bound" || echo disclosed)"

# ===============================================================================================
suite "AC4: the population is a RULE over the tree at check time, not a list of filenames"
# ===============================================================================================
#
# The disclosure must state the rule's FLOOR and the count it enumerated. Both are then re-derived
# here from the materialized tree: a frozen list produces a constant that stops tracking the tree,
# which is exactly the ratchet AC4 exists to convert into a standing tripwire (Phase 5 writes one
# knowledge/issue-archive/<n>.json per issue, forever).

RULE_FLOOR="$(printf '%s' "$README_COST4" | grep -oE 'at or above [0-9]+ bytes' | grep -oE '[0-9]+' | head -1)"
RULE_ENUM="$(printf '%s' "$README_COST4" | grep -oE 'enumerated [0-9]+' | grep -oE '[0-9]+' | head -1)"
RULE_DRIVEN="$(printf '%s' "$README_COST4" | grep -oE 'drove [0-9]+|driven [0-9]+' | grep -oE '[0-9]+' | head -1)"
assert_eq "AC4: the disclosure states the RULE's size floor, in the form \`at or above <N> bytes\`, so the figure cannot be confused with any other byte count in the paragraph" \
  "$([[ "$RULE_FLOOR" =~ ^[0-9]+$ ]] && echo stated || echo "NOT STATED (no byte floor found in item 27 cost (4))")" "stated"
assert_eq "AC3/AC4: it reports how many rows the rule ENUMERATED, in the form \`enumerated <N>\` (a scan that inspected nothing produces the same clean output as one that inspected everything)" \
  "$([[ "$RULE_ENUM" =~ ^[0-9]+$ ]] && echo reported || echo "NOT REPORTED")" "reported"
assert_eq "AC3/AC4: and how many it DROVE, in the form \`drove <N>\`" \
  "$([[ "$RULE_DRIVEN" =~ ^[0-9]+$ && "$RULE_DRIVEN" -ge 1 ]] && echo reported || echo "NOT REPORTED OR ZERO: [$RULE_DRIVEN]")" "reported"

LIVE_ENUM="$(tb_enumerate_count "$MAT" "${RULE_FLOOR:-2000}")"
# ONE DIRECTION, as in test-pretooluse-gate-verdicts.sh AC4: growth past the published count is
# the tripwire (the bound could be undersized); shrinkage is not, and used to redden this row on
# every archive deletion. The growth control below still flips the enumerator.
assert_eq "AC4: an INDEPENDENT enumeration of the materialized tree at the published floor (${RULE_FLOOR:-?} bytes) is at most the published count (${RULE_ENUM:-?}) -- a frozen list diverges here the moment the corpus grows, which is the tripwire AC4 asks for" \
  "$([[ "$LIVE_ENUM" =~ ^[0-9]+$ && "$RULE_ENUM" =~ ^[0-9]+$ && "$LIVE_ENUM" -le "$RULE_ENUM" ]] && echo within-sizing || echo "GREW: live $LIVE_ENUM > published ${RULE_ENUM:-?}")" "within-sizing"

# AC4's own deciding observation, and the non-zero control on the enumerator: add one tracked file
# larger than today's largest and require the count to change and the file to rank first by length.
new_tmpdir || exit 90
GROWN="$NEW_TMPDIR/grown"
mkdir -p "$GROWN"
cp -R "$MAT/." "$GROWN/" 2>/dev/null
BIGGEST_BYTES="$(tb_enumerate "$MAT" "${RULE_FLOOR:-2000}" | sort -rn | head -1 | cut -f1)"
mkdir -p "$GROWN/knowledge/issue-archive"
"$GATE_REAL_NODE" -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({ note: "AC4 growth probe", pad: "x".repeat(Number(process.argv[2])) }));
' "$GROWN/knowledge/issue-archive/999999.json" "$(( ${BIGGEST_BYTES:-100000} + 50000 ))"
GROWN_ENUM="$(tb_enumerate_count "$GROWN" "${RULE_FLOOR:-2000}")"
GROWN_TOP="$(tb_enumerate "$GROWN" "${RULE_FLOOR:-2000}" | sort -rn | head -1 | cut -f2)"
assert_eq "AC4 NON-ZERO CONTROL: adding one tracked file larger than today's largest CHANGES the enumerated count ($LIVE_ENUM -> $GROWN_ENUM)" \
  "$(( GROWN_ENUM - LIVE_ENUM ))" "1"
assert_eq "AC4 NON-ZERO CONTROL: and the new file ranks FIRST on the length axis, so any top-K-by-length selection must draw it" \
  "$GROWN_TOP" "knowledge/issue-archive/999999.json"

# ===============================================================================================
suite "AC5 + AC6 + AC7: the regression budget is ABSOLUTE, measured on the host that evaluates it"
# ===============================================================================================
#
# WHY THIS BLOCK READS A DECLARED NAME RATHER THAN RE-RUNNING THE VERDICTS SUITE. AC5's own text
# names the source line it refuses (`LEN_BOUND_MS=$(( LEN_TIMEOUT_S * 1000 ))`, :390) and the four
# sites that consume it, so the criterion is about what the suite DECLARES. Re-running
# test-pretooluse-gate-verdicts.sh under a mutated declaration would observe the same fact for
# 211 s (measured at 62d7a17) plus whatever this change adds, twice. The contract therefore fixes
# ONE name -- `REGRESSION_BUDGET_MS`, an integer literal, one assignment -- and asserts everything
# else about its VALUE and its recorded derivation. Nothing here constrains how the four blocks use
# it beyond AC7's requirement that both failures be told apart.
VERDICTS_SRC="$MAT/$VERDICTS_REL"
BUDGET_LINES="$(grep -c '^REGRESSION_BUDGET_MS=[0-9][0-9]*$' "$VERDICTS_SRC" 2>/dev/null | tr -d ' \n')"
assert_eq "AC5: the verdicts suite declares EXACTLY ONE absolute regression budget (\`REGRESSION_BUDGET_MS=<integer>\`, no arithmetic, no gate_declared_timeout)" \
  "$BUDGET_LINES" "1"
BUDGET_MS="$(grep '^REGRESSION_BUDGET_MS=[0-9][0-9]*$' "$VERDICTS_SRC" 2>/dev/null | head -1 | cut -d= -f2)"
[[ "$BUDGET_MS" =~ ^[0-9]+$ ]] || BUDGET_MS=0
assert_eq "AC5: and that budget is NOT the declared timeout times 1000 -- a change that raises hooks.json and leaves the four guards reading the declaration widens all four by exactly the factor of the raise, in one integer edit that nothing reddens" \
  "$([[ "$BUDGET_MS" -gt 0 && "$BUDGET_MS" -ne "$DECLARED_MS" ]] && echo absolute || echo "BUDGET $BUDGET_MS EQUALS THE DECLARATION x1000 ($DECLARED_MS), or is unset")" \
  "absolute"
assert_eq "AC7: the four timing probes report a BYPASS (the gate emits nothing and the call is allowed) distinguishably from a REGRESSION (the gate still decides, slower than its derivation permits) -- at least four assertion strings of each" \
  "$(_byp="$(grep -o 'BYPASS' "$VERDICTS_SRC" | grep -c . | tr -d ' \n')"; _reg="$(grep -o 'REGRESSION' "$VERDICTS_SRC" | grep -c . | tr -d ' \n')"; \
     if [[ "$_byp" -ge 4 && "$_reg" -ge 4 ]]; then echo both; else echo "BYPASS=$_byp REGRESSION=$_reg"; fi)" \
  "both"

# AC6: the bound is EVALUATED on a Linux host (0.40.2: tests/run-linux.sh runs
# `bash plugins/pipeline/tests/run.sh` in a pinned Debian container, on demand, replacing the
# ubuntu-latest workflow that ran it on every PR) and was DERIVED on darwin. A figure re-taken on
# the evaluating host must sit beside the bound, in the same form measured_state records the
# darwin figures. A bound padded to cover an unmeasured host fails AC6 explicitly. The recorded
# ubuntu-latest figures below stay what they are: measurements taken on that runner, still the
# closest Linux figures this repo holds until run-linux.sh's are recorded beside them.
CI_RUNS_SUITE="$(grep -cE 'bookworm|ubuntu' "$MAT/plugins/pipeline/tests/run-linux.sh" 2>/dev/null | tr -d ' \n')"
assert_eq "PREMISE for AC6: tests/run-linux.sh still runs this suite on a Linux image (if this is 0 the criterion's evaluating host changed and the row below needs a new subject)" \
  "$([[ "$CI_RUNS_SUITE" -ge 1 ]] && echo runs || echo "NOT FOUND")" "runs"
UBUNTU_FIGS="$(grep -n 'ubuntu-latest' "$VERDICTS_SRC" 2>/dev/null | head -1 | cut -d: -f1)"
UBUNTU_BLOCK="$(sed -n "$(( ${UBUNTU_FIGS:-1} - 6 )),$(( ${UBUNTU_FIGS:-1} + 8 ))p" "$VERDICTS_SRC" 2>/dev/null)"
UBUNTU_MS_COUNT="$(tb_numbers "$UBUNTU_BLOCK" 'ms' | grep -c . | tr -d ' \n')"
assert_eq "AC6: an ubuntu-latest measurement of the four blocks sits beside the absolute bound -- at least four millisecond figures, taken on the host the guard is EVALUATED on, not only on the one it was derived on" \
  "$([[ -n "$UBUNTU_FIGS" && "$UBUNTU_MS_COUNT" -ge 4 ]] && echo recorded || echo "FOUND ${UBUNTU_MS_COUNT} ms figures near an ubuntu-latest mention (need 4)")" \
  "recorded"
assert_contains "AC6: and the recorded measurement carries the COMMAND that produced it" "$UBUNTU_BLOCK" "run.sh"
UBUNTU_MAX="$(tb_numbers "$UBUNTU_BLOCK" 'ms' | sort -n | tail -1)"
assert_eq "AC6: the budget EXCEEDS every figure it was measured against but is not padded blind -- worst recorded ubuntu figure ${UBUNTU_MAX:-none} ms against a budget of $BUDGET_MS ms" \
  "$([[ "$BUDGET_MS" -gt 0 && "${UBUNTU_MAX:-0}" -gt 0 && "$BUDGET_MS" -gt "${UBUNTU_MAX:-0}" ]] && echo bounded || echo "budget=$BUDGET_MS worst-ubuntu=${UBUNTU_MAX:-none}")" \
  "bounded"

# ===============================================================================================
suite "AC5/AC7: the absolute budget is a LIVE guard -- watched to fire, and watched to clear"
# ===============================================================================================
#
# THE GAP THIS CLOSES, NAMED. Four of the five build-failing controls #132 adds carry a recorded
# plant-red/restore-green pair. REGRESSION_BUDGET_MS carried none, and the reason given was that
# the only way to push a probe past 5000 ms on demand is to slow the host. There is another way,
# and it is the one a mutation battery always uses: leave the host alone and move the THRESHOLD,
# in a copy.
#
# WHAT MADE THE OBSERVATION UNAFFORDABLE, AND WHAT MAKES IT AFFORDABLE HERE. The block above
# declines to re-run test-pretooluse-gate-verdicts.sh, and it is right to: that suite costs 240 s
# on darwin and a pair costs two of them, twice per run.sh. So this cell does not run that suite.
# It EXTRACTS the LENGTH block onto the suite's own setup -- byte-identical lines, the real
# `len_probe`, the real accumulator, the real assertion, read out of the shipped file at check time
# -- and runs THAT. MEASURED on darwin 25.5.0 at load 9.67: 9.5 s and 23 rows, against 240 s.
#
# WHAT ONE BLOCK PROVES ABOUT FOUR. The live observation is on the LENGTH block alone. The other
# three carry the identical guard, so they are pinned STRUCTURALLY in the same breath: four
# `-lt "$REGRESSION_BUDGET_MS"` guards and four `-lt "$BYPASS_BOUND_MS"` guards, counted from the
# shipped source. A refactor that rewires one of them moves that count instead of passing quietly.
#
# WHAT IT DOES NOT PROVE, SAID PLAINLY. The red is produced by moving the budget UNDER a real
# measured probe time, not by making the scan genuinely slower. It observes the accumulator, the
# comparison and the assertion against real timings; it does not re-time a slower gate, which would
# cost eighteen probes times whatever latency was added. The threshold is planted at a QUARTER of
# the millisecond figure this host just measured rather than at 1, so the red is a real probe over
# a real threshold and cannot be read as a degenerate zero.
new_tmpdir || exit 90
RB_ROOT="$NEW_TMPDIR/regbudget"
cp -R "$MAT" "$RB_ROOT" 2>/dev/null
RB_SRC="$RB_ROOT/$VERDICTS_REL"
RB_EXTRACT_REL="plugins/pipeline/tests/rb-length-axis.sh"
RB_SETUP_LINE="$(grep -n '^sub_verdict() ' "$RB_SRC" 2>/dev/null | head -1 | cut -d: -f1)"
RB_START="$(grep -n '^suite "AC7 LENGTH AXIS' "$RB_SRC" 2>/dev/null | head -1 | cut -d: -f1)"
RB_END="$(grep -n '^record "LENGTH AXIS worst observed' "$RB_SRC" 2>/dev/null | head -1 | cut -d: -f1)"
assert_eq "AC5 EXTRACT PREMISE: the three anchors bounding the extract were each found where the shipped suite puts them (setup :${RB_SETUP_LINE:-none}, block :${RB_START:-none} to :${RB_END:-none}). A missing anchor builds an extract that runs nothing and reports a clean pass" \
  "$([[ -n "$RB_SETUP_LINE" && -n "$RB_START" && -n "$RB_END" && "$RB_START" -gt "$RB_SETUP_LINE" && "$RB_END" -gt "$RB_START" ]] && echo bounded || echo "setup=${RB_SETUP_LINE:-none} start=${RB_START:-none} end=${RB_END:-none}")" \
  "bounded"
RB_PLANT_LANDED="unrun"
rb_build() {  # [budget] -> rebuild the extract, planting the budget when one is given
  { sed -n "1,${RB_SETUP_LINE:-1}p" "$RB_SRC"
    sed -n "${RB_START:-1},${RB_END:-1}p" "$RB_SRC"
    printf 'finish\n'; } > "$RB_ROOT/$RB_EXTRACT_REL"
  [[ -n "${1:-}" ]] || return 0
  # The plant is a literal line replacement and it REPORTS whether it landed: a mutation that
  # silently matched nothing is a green row about an unmutated file.
  RB_PLANT_LANDED="$("$GATE_REAL_NODE" -e '
    const fs = require("node:fs");
    const p = process.argv[1], s = fs.readFileSync(p, "utf8");
    const out = s.replace(/^REGRESSION_BUDGET_MS=[0-9]+$/m, "REGRESSION_BUDGET_MS=" + process.argv[2]);
    fs.writeFileSync(p, out);
    process.stdout.write(out === s ? "DID-NOT-LAND" : "landed");
  ' "$RB_ROOT/$RB_EXTRACT_REL" "$1" 2>/dev/null)"
  return 0
}
rb_run() {  # -> RB_OUT
  RB_OUT="$( cd "$RB_ROOT" 2>/dev/null && bash "$RB_EXTRACT_REL" 2>/dev/null )"
}
rb_row() {  # <row-name-substring> -> ok | FAIL | (empty when the row never ran)
  printf '%s\n' "$RB_OUT" | awk -v k="$1" 'index($0,k)>0 && ($1=="ok"||$1=="FAIL"){print $1; exit}'
}
rb_failed() { printf '%s\n' "$RB_OUT" | sed -n 's/^passed=[0-9]* failed=\([0-9]*\)$/\1/p' | head -1; }
rb_passed() { printf '%s\n' "$RB_OUT" | sed -n 's/^passed=\([0-9]*\) failed=[0-9]*$/\1/p' | head -1; }

rb_build
rb_run
RB_G_REG="$(rb_row 'AC7 LENGTH REGRESSION')"
RB_G_BYP="$(rb_row 'AC7 LENGTH BYPASS')"
RB_G_FAILED="$(rb_failed)"
RB_WORST="$(printf '%s\n' "$RB_OUT" | sed -n 's/.*LENGTH AXIS worst observed: \([0-9][0-9]*\) ms.*/\1/p' | head -1)"
record "AC5 EXTRACT: the LENGTH block of $VERDICTS_REL lifted onto its own setup ($(( RB_END - RB_START + 1 )) lines of the block, ${RB_SETUP_LINE} of setup) -> $(rb_passed) passed / ${RB_G_FAILED} failed, worst probe ${RB_WORST:-none} ms, at load $(tb_loadavg) on $(uname -sr)"
assert_eq "AC5 RESTORE-GREEN: at the budget the tree ships, the extracted block passes BOTH of its bounds (regression=${RB_G_REG:-ABSENT} bypass=${RB_G_BYP:-ABSENT}, ${RB_G_FAILED:-?} failing rows). Without this half the red below is equally consistent with an extract that never worked" \
  "${RB_G_REG:-ABSENT}/${RB_G_BYP:-ABSENT}/${RB_G_FAILED:-?}" "ok/ok/0"

RB_PLANT=$(( ${RB_WORST:-0} / 4 ))
[[ "$RB_PLANT" -lt 1 ]] && RB_PLANT=1
rb_build "$RB_PLANT"
rb_run
RB_R_REG="$(rb_row 'AC7 LENGTH REGRESSION')"
RB_R_BYP="$(rb_row 'AC7 LENGTH BYPASS')"
RB_R_FAILED="$(rb_failed)"
record "AC5 PLANT: budget moved to ${RB_PLANT} ms (a quarter of the ${RB_WORST:-?} ms measured above), plant $RB_PLANT_LANDED -> $(rb_passed) passed / ${RB_R_FAILED} failed"
assert_eq "AC5 PLANT LANDED: the budget line was really rewritten in the extract (a substitution that matched nothing would make every row below a statement about an unmutated file)" \
  "$RB_PLANT_LANDED" "landed"
assert_eq "AC5 PLANT-RED: with the budget under a probe time this host actually measured, the LENGTH REGRESSION row FAILS. This is the control the budget did not have: the host is untouched and the threshold moved, which is what a mutation battery does everywhere else in this contract" \
  "${RB_R_REG:-ABSENT}" "FAIL"
assert_eq "AC5 PLANT-RED DISCRIMINATION: and the BYPASS row over the SAME probes stays green while exactly ONE row moves (${RB_G_FAILED:-?} -> ${RB_R_FAILED:-?} failing). The two bounds are genuinely separate -- the budget is absolute, the bypass bound is read from hooks.json -- and a mutation of one does not move the other" \
  "${RB_R_BYP:-ABSENT}/$(( ${RB_R_FAILED:-0} - ${RB_G_FAILED:-0} ))" "ok/1"

RB_REG_GUARDS="$(grep -c -- '-lt "$REGRESSION_BUDGET_MS"' "$RB_SRC" 2>/dev/null | tr -d ' \n')"
RB_BYP_GUARDS="$(grep -c -- '-lt "$BYPASS_BOUND_MS"' "$RB_SRC" 2>/dev/null | tr -d ' \n')"
assert_eq "AC5/AC7: the live observation above is on ONE of the five timing blocks (a fifth, #140 AC7 SUPPLEMENT, joined this round to measure the many-blank-line corpus the heredoc-opacity fix's own comment claims to have re-measured), and the other four are pinned STRUCTURALLY in the same breath -- five guards read the absolute budget and five read the declared bypass bound (found $RB_REG_GUARDS and $RB_BYP_GUARDS). A block rewired to read the declaration moves this count instead of passing quietly" \
  "$RB_REG_GUARDS/$RB_BYP_GUARDS" "5/5"

# ===============================================================================================
suite "AC8: the declaration suite's range assertion names the measurement that fixes it"
# ===============================================================================================
#
# The superseded rationale at :86-90 ('66.68 ms node cold start plus one git subprocess') must no
# longer stand ALONE. What must stand beside the bound is a command length in bytes, a structural
# density in bytes per structural character, and a measured decision time on a NAMED host.
DECL_SRC="$MAT/$DECLSUITE_REL"
RANGE_LINE="$(grep -n 'plausible bound' "$DECL_SRC" 2>/dev/null | head -1 | cut -d: -f1)"
assert_eq "VACUITY: the declaration suite's upper-bound assertion was located (a grep that found nothing makes the rows below pass on an empty window)" \
  "$([[ -n "$RANGE_LINE" ]] && echo located || echo "NOT LOCATED")" "located"
RANGE_WIN="$(sed -n "$(( ${RANGE_LINE:-1} - 14 )),$(( ${RANGE_LINE:-1} + 3 ))p" "$DECL_SRC" 2>/dev/null | tr '\n' ' ' | sed 's/#//g; s/  */ /g')"
assert_eq "AC8: a command LENGTH stands beside the bound, written as \`<N> bytes\` or \`<N> command bytes\`" \
  "$(printf '%s' "$RANGE_WIN" | grep -qE '[0-9]{4,}( [A-Za-z-]+)? bytes' && echo present || echo ABSENT)" "present"
assert_contains "AC8: a structural DENSITY in bytes per structural character stands beside the bound" "$RANGE_WIN" "B/struct"
assert_eq "AC8: a measured decision time in MILLISECONDS stands beside the bound" \
  "$([[ -n "$(tb_numbers "$RANGE_WIN" 'ms')" ]] && echo present || echo ABSENT)" "present"
assert_eq "AC8: and the HOST it was measured on is named" \
  "$(printf '%s' "$RANGE_WIN" | grep -ciE 'darwin|ubuntu|linux' | tr -d ' \n' | sed 's/^0$/ABSENT/;s/^[1-9].*/present/')" "present"

# ===============================================================================================
suite "AC10: a change to the declared timeout fails an in-tree assertion, printing BOTH values"
# ===============================================================================================
#
# THE OBSERVATION, RUN RATHER THAN ASSERTED: with ONLY hooks.json's PreToolUse timeout edited, one
# value at a time, test-pretooluse-gate-declaration.sh must report at least one failing row whose
# text contains BOTH the expected and the found number. At 62d7a17 it reports 68 passed / 0 failed
# at 5, 15, 19 AND 30, because PreToolUse is the only one of the four entries checked by a RANGE
# rather than by exact serialization -- and it is the security-critical one.
#
# THE COMPARISON IS OVER FAILING-ROW SETS, NOT OVER TALLIES, because the baseline is not
# necessarily zero: a materialized (git-less) tree fails the declaration suite's own
# paired-capture rows, and the knowledge-store rows are known-red until the Phase 5 Librarian pass.
# A tally comparison would be unfalsifiable in exactly those states; a set difference is not.

decl_fail_rows() {  # <root> -> the FAIL row names, sorted, one per line
  ( cd "$1" 2>/dev/null || exit 0
    bash plugins/pipeline/tests/test-pretooluse-gate-declaration.sh 2>/dev/null ) |
    awk '/^  FAIL /{sub(/^  FAIL  /,""); print}' | sort
}
decl_fail_text() {  # <root> -> the FAIL blocks with their expected/actual lines
  ( cd "$1" 2>/dev/null || exit 0
    bash plugins/pipeline/tests/test-pretooluse-gate-declaration.sh 2>/dev/null ) |
    awk '/^  FAIL /{p=1} /^  ok /{p=0} p'
}
decl_ok_count() {  # <root>
  ( cd "$1" 2>/dev/null || exit 0
    bash plugins/pipeline/tests/test-pretooluse-gate-declaration.sh 2>/dev/null ) |
    grep -c '^  ok  ' | tr -d ' \n'
}

DECL_BASE_ROWS="$(decl_fail_rows "$MAT")"
DECL_BASE_OK="$(decl_ok_count "$MAT")"
record "AC10 BASELINE on the materialized tree: $DECL_BASE_OK ok rows, $(printf '%s' "$DECL_BASE_ROWS" | grep -c . | tr -d ' ') failing rows"
assert_eq "AC10 VACUITY: the declaration suite RAN against the materialized tree and produced rows (a suite that did not run makes every set difference below empty and every mutation look uncaught)" \
  "$([[ "$DECL_BASE_OK" -ge 20 ]] && echo ran || echo "ONLY $DECL_BASE_OK ok ROWS")" "ran"

# The three values AC10 names, minus whatever Dev chose, kept at three by substitution -- so the
# battery never mutates the declaration to the value it already holds, which would be a no-op
# wearing a mutation's name.
DECL_MUTANTS=""
for v in 15 19 30 5 25 29; do
  [[ "$v" == "$DECLARED_S" ]] && continue
  DECL_MUTANTS="$DECL_MUTANTS $v"
  [[ "$(printf '%s' "$DECL_MUTANTS" | wc -w | tr -d ' ')" -ge 4 ]] && break
done
record "AC10 MUTANTS (AC10 names 15, 19 and 30; the declared value itself is skipped and substituted so no cell is a no-op):$DECL_MUTANTS, plus the pre-change 5"

set_timeout() {  # <root> <event> <value>
  "$GATE_REAL_NODE" -e '
    const fs = require("node:fs");
    const [, p, ev, v] = process.argv;
    const h = JSON.parse(fs.readFileSync(p, "utf8"));
    const before = h.hooks[ev][0].hooks[0].timeout;
    h.hooks[ev][0].hooks[0].timeout = Number(v);
    fs.writeFileSync(p, JSON.stringify(h, null, 2) + "\n");
    process.stdout.write(String(before));
  ' "$1/$HOOKS_REL" "$2" "$3"
}

for v in $DECL_MUTANTS; do
  new_tmpdir || exit 90
  MUT="$NEW_TMPDIR/decl-$v"
  mkdir -p "$MUT"
  cp -R "$MAT/." "$MUT/" 2>/dev/null
  WAS="$(set_timeout "$MUT" PreToolUse "$v")"
  assert_eq "MUTATION LANDED: hooks.json's PreToolUse timeout is $v in the copy (was $WAS)" \
    "$(cd "$MUT" && "$GATE_REAL_NODE" -e 'const h=require("node:fs").readFileSync(process.argv[1],"utf8");process.stdout.write(String(JSON.parse(h).hooks.PreToolUse[0].hooks[0].timeout))' "$MUT/$HOOKS_REL")" "$v"
  MUT_ROWS="$(decl_fail_rows "$MUT")"
  NEW_ROWS="$(comm -13 <(printf '%s\n' "$DECL_BASE_ROWS") <(printf '%s\n' "$MUT_ROWS") | grep -c . | tr -d ' \n')"
  assert_eq "AC10: editing ONLY the PreToolUse timeout to $v adds at least one FAILING row to test-pretooluse-gate-declaration.sh" \
    "$([[ "$NEW_ROWS" -ge 1 ]] && echo reddens || echo "NO NEW FAILING ROW: the suite reports the same failures at $v as at ${DECLARED_S:-?}")" \
    "reddens"
  MUT_TEXT="$(decl_fail_text "$MUT")"
  assert_eq "AC10: and that failure prints BOTH numbers -- the found $v and the expected ${DECLARED_S:-?}" \
    "$(if [[ "$MUT_TEXT" == *"$v"* && "$MUT_TEXT" == *"${DECLARED_S:-__none__}"* ]]; then echo both; \
       else echo "MISSING: found=$([[ "$MUT_TEXT" == *"$v"* ]] && echo yes || echo no) expected=$([[ "$MUT_TEXT" == *"${DECLARED_S:-__none__}"* ]] && echo yes || echo no)"; fi)" \
    "both"
done

# AC10'S OWN NON-ZERO CONTROL, ALREADY IN THE TREE AND NAMED BY THE CRITERION: the same edit applied
# to SubagentStop (15 -> 20) reddens the pinned-serialization row at :95-105. That block must NOT be
# retired or generalised -- it is what distinguishes 'the suite cannot see a timeout edit' from
# 'the suite sees this one'.
new_tmpdir || exit 90
SSMUT="$NEW_TMPDIR/decl-subagentstop"
mkdir -p "$SSMUT"
cp -R "$MAT/." "$SSMUT/" 2>/dev/null
SS_WAS="$(set_timeout "$SSMUT" SubagentStop 20)"
assert_eq "MUTATION LANDED: SubagentStop's timeout is 20 in the control copy (was $SS_WAS)" \
  "$("$GATE_REAL_NODE" -e 'const h=require("node:fs").readFileSync(process.argv[1],"utf8");process.stdout.write(String(JSON.parse(h).hooks.SubagentStop[0].hooks[0].timeout))' "$SSMUT/$HOOKS_REL")" "20"
SS_NEW="$(comm -13 <(printf '%s\n' "$DECL_BASE_ROWS") <(printf '%s\n' "$(decl_fail_rows "$SSMUT")") | grep -c . | tr -d ' \n')"
assert_eq "AC10 NON-ZERO CONTROL: the SubagentStop 15->20 edit still reddens the pinned-serialization row, so 'the suite sees a timeout edit' is demonstrated and not assumed" \
  "$([[ "$SS_NEW" -ge 1 ]] && echo fires || echo "DID NOT FIRE -- the ad hoc pins at :95-105 were retired or generalised")" \
  "fires"

# ===============================================================================================
suite "AC15: the #106-era rows are COMPARED against origin/main, not merely reported green"
# ===============================================================================================
#
# 'Green at both commits' is equally consistent with a verdict having moved and a row having been
# rewritten to match it. What is compared here is the ROW NAME SET: every row present before the
# change must still be present after it, so a row cannot be deleted or renamed out of the way.
#
# NAMED LIMITATION, because a partial check presented as complete is worse than an honest one: only
# test-pretooluse-gate-declaration.sh is compared here. The other five #106-era suites cost 47 s
# (ownership), 18 s (channel) and 211 s (verdicts) PER SIDE at 62d7a17, and doubling that inside
# every CI run buys less than the impl-report's own row-for-row comparison, which AC15 requires of
# Dev regardless. Phase 4 should read this row as covering ONE of the six suites.
BASE_REF="$(git -C "$GATE_REPO_ROOT" rev-parse --verify -q origin/main 2>/dev/null || git -C "$GATE_REPO_ROOT" rev-parse --verify -q main 2>/dev/null || printf '')"
if [[ -n "$BASE_REF" ]]; then
  new_tmpdir || exit 90
  BASE_TREE="$NEW_TMPDIR/basemain"
  mkdir -p "$BASE_TREE"
  git -C "$GATE_REPO_ROOT" archive "$BASE_REF" 2>/dev/null | ( cd "$BASE_TREE" && tar xf - ) || true
fi
BASE_OK="$([[ -n "$BASE_REF" ]] && decl_ok_count "$BASE_TREE" || printf 'NO-BASE')"
BASE_ROWS_BEFORE="$([[ -n "$BASE_REF" ]] && ( cd "$BASE_TREE" && bash plugins/pipeline/tests/test-pretooluse-gate-declaration.sh 2>/dev/null ) | awk '/^  (ok|FAIL) /{sub(/^  (ok|FAIL)  /,""); gsub(/-?[0-9]+(\.[0-9]+)?/,"#"); print}' | sort || printf '')"
ROWS_AFTER="$( ( cd "$MAT" && bash plugins/pipeline/tests/test-pretooluse-gate-declaration.sh 2>/dev/null ) | awk '/^  (ok|FAIL) /{sub(/^  (ok|FAIL)  /,""); gsub(/-?[0-9]+(\.[0-9]+)?/,"#"); print}' | sort )"
record "AC15 BASE: $BASE_REF -> $BASE_OK ok rows, $(printf '%s' "$BASE_ROWS_BEFORE" | grep -c . | tr -d ' ') total rows; HEAD -> $(printf '%s' "$ROWS_AFTER" | grep -c . | tr -d ' ') total rows"
assert_eq "AC15 VACUITY: the base commit's declaration suite ran and produced rows (an unreachable origin/main makes the comparison below empty and unfalsifiable)" \
  "$([[ "$(printf '%s' "$BASE_ROWS_BEFORE" | grep -c . | tr -d ' ')" -ge 20 ]] && echo ran || echo "BASE REF [$BASE_REF] PRODUCED $(printf '%s' "$BASE_ROWS_BEFORE" | grep -c . | tr -d ' ') ROWS")" "ran"
DROPPED="$(comm -23 <(printf '%s\n' "$BASE_ROWS_BEFORE") <(printf '%s\n' "$ROWS_AFTER") | grep -v '^$' | head -5 | tr '\n' '|')"
# Digits are normalised out of both sides before comparing: several rows in that suite carry a
# measured millisecond figure in their own NAME, which legitimately differs between two runs, and a
# raw set difference reports every one of them as a deleted row.
#
# ACKNOWLEDGED RENAMES: BASE_REF is resolved above as origin/main's CURRENT tip, which for any PR
# not yet merged is always a commit before that PR's own fix -- so a PR that legitimately renames a
# row it is itself the reason for changing (because what the row certifies changed, not because the
# row was deleted to dodge scrutiny) will ALWAYS show that rename here, on every CI run, until it
# merges. AC15 has no way to tell that class of rename apart from a silent deletion by itself, and
# should not be made to guess -- so a rename is let through only when it is paired HERE explicitly,
# old name to new name (both digit-normalised the same way as $BASE_ROWS_BEFORE / $ROWS_AFTER), and
# only after the new name is confirmed present in $ROWS_AFTER -- an unpaired row, or a paired row
# whose new half is not actually in the tree, still fails below. Adding a line here is reviewed
# exactly once, in the diff that adds it, same as any other assertion; it is not a standing
# exemption for future renames of the same row, and #138's PR is the only diff that should ever add
# to this list.
KNOWN_RENAMES=(
  "  SessionStart entry carries ##'s corrected (seconds) timeout|  SessionStart entry is UNCHANGED (## did not establish a measured basis to replace it)"
  "  Stop entry carries ##'s corrected (seconds) timeout|  Stop entry carries ##'s measured (seconds) timeout"
)
for pair in "${KNOWN_RENAMES[@]}"; do
  old_name="${pair%%|*}"
  new_name="${pair#*|}"
  if [[ "|$DROPPED" == *"|$old_name|"* ]] \
     && printf '%s\n' "$ROWS_AFTER" | grep -qxF "$new_name"; then
    DROPPED="${DROPPED//$old_name\|/}"
    record "AC15: ACKNOWLEDGED RENAME (#138) -- '$old_name' -> '$new_name' (new name confirmed present, so this is excused as a pinned pair, not a silent drop)"
  fi
done
assert_eq "AC15: no row that existed in test-pretooluse-gate-declaration.sh at $BASE_REF was deleted or renamed away by this change (row names compared with digits normalised, since several carry a measured figure, and known acknowledged renames excused above)" \
  "${DROPPED:-none}" "none"

# ===============================================================================================
suite "AC12: every independent re-derivation carries the new value or says which era it describes"
# ===============================================================================================
#
# THE ENUMERATION IS THE FIXTURE. A change that updates hooks.json and one adjacent comment does not
# satisfy AC12. A scanner cannot tell a quotation from a claim, so the rule here is not 'the old
# number is banned' -- it is 'a line stating the OLD declared value must carry an ERA MARKER in its
# own window'. The old value is read from the base commit's hooks.json rather than transcribed.
OLD_S="$(git -C "$GATE_REPO_ROOT" show "$BASE_REF:$HOOKS_REL" 2>/dev/null | "$GATE_REAL_NODE" -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{ try { process.stdout.write(String(JSON.parse(s).hooks.PreToolUse[0].hooks[0].timeout)); } catch { process.stdout.write(""); } });' 2>/dev/null)"
assert_eq "VACUITY: the OLD declared value was read from $BASE_REF's own hooks.json rather than transcribed into this suite" \
  "$([[ "$OLD_S" =~ ^[0-9]+$ ]] && echo read || echo "NOT READ: [$OLD_S]")" "read"

ERA='historical|superseded|before this change|before the bounded window|pre-#|at the reviewed commit|used to|went from|prior to|the OLD bound|describes the'
scan_stale() {  # <root> -> "<file>:<line>" for each unmarked claim, one per line
  local root="$1" f
  for f in "$HOOK_REL" "$VERDICTS_REL" "$README_REL"; do
    [[ -f "$root/$f" ]] || continue
    OLD_S="$OLD_S" ERA="$ERA" awk -v file="$f" '
      { lines[NR] = $0 }
      END {
        old = ENVIRON["OLD_S"]; era = ENVIRON["ERA"];
        # awk ERE has no backslash-b, so the boundary is spelled as an explicit non-letter or EOL.
        pat = "(^|[^0-9.])" old "[ -]?(s|second|seconds|SECOND|SECONDS)([^a-zA-Z]|$)";
        for (i = 1; i <= NR; i++) {
          if (lines[i] !~ pat) continue;
          if (lines[i] !~ /declar|hooks\.json|timeout/) continue;
          win = lines[i-2] "\n" lines[i-1] "\n" lines[i] "\n" lines[i+1] "\n" lines[i+2];
          if (win ~ era) continue;
          print file ":" i;
        }
      }' "$root/$f"
  done
}
STALE="$(scan_stale "$MAT" | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "AC12: no in-tree site still states the OLD ${OLD_S:-?}-second declaration as a CURRENT claim without an era marker in its own window" \
  "${STALE:-none}" "none"

# NON-ZERO CONTROL on the scanner. Without it, 'none' is equally consistent with 'every site was
# updated' and with 'the pattern matches nothing at all'.
new_tmpdir || exit 90
STALE_PLANT="$NEW_TMPDIR/stale"
mkdir -p "$STALE_PLANT"
cp -R "$MAT/." "$STALE_PLANT/" 2>/dev/null
printf '\n# the %s s its hooks.json entry declares\n' "${OLD_S:-5}" >> "$STALE_PLANT/$HOOK_REL"
# THE CONTROL MUST OBSERVE THE PLANT, not merely produce a non-zero count. Measured: an earlier
# draft asserted `findings >= 1` on the planted copy, and it passed at the reviewed commit for the
# wrong reason -- the copy still carried three pre-existing unmarked sites, so the row was green
# with a plant the scanner never matched, and it only surfaced once a reference implementation
# era-marked those three and the count fell to zero. The comparison is therefore against the
# baseline finding SET: the plant must ADD one.
PLANTED_SET="$(scan_stale "$STALE_PLANT" | sort)"
BASE_SET="$(scan_stale "$MAT" | sort)"
PLANTED_NEW="$(comm -13 <(printf '%s\n' "$BASE_SET") <(printf '%s\n' "$PLANTED_SET") | grep -c . | tr -d ' \n')"
assert_eq "AC12 NON-ZERO CONTROL: a planted unmarked claim about the old ${OLD_S:-?}-second declaration ADDS a finding the unplanted tree does not have" \
  "$([[ "$PLANTED_NEW" -ge 1 ]] && echo reports || echo "ADDED NOTHING -- the scanner did not match the plant, so the clean scan above proves nothing")" "reports"

# AC12 entry 11: the historical records must NOT be rewritten. Compared byte for byte against the
# base commit rather than against a transcribed count, so an over-eager sweep is caught exactly.
for hist in "knowledge/issue-archive/106.json" "knowledge/issue-archive/56.json"; do
  assert_eq "AC12 entry 11: $hist is byte-identical to $BASE_REF (HISTORICAL RECORD -- AC1 and AC2 read 106.json as a FIXTURE and must not rewrite it)" \
    "$(git -C "$GATE_REPO_ROOT" show "$BASE_REF:$hist" 2>/dev/null | cmp -s - "$MAT/$hist" && echo unchanged || echo REWRITTEN)" \
    "unchanged"
done

# The three DERIVED crossings the raise invalidates (pre-tool-use.sh:619-624 and
# test-pretooluse-gate-verdicts.sh:526, each stating ~12 KB / ~29 KB / ~117 KB). These are derived
# values rather than prose: they must be re-derived or explicitly marked as describing an earlier
# commit.
crossings_unmarked() {
  local root="$1" f n
  n=0
  for f in "$HOOK_REL" "$VERDICTS_REL"; do
    [[ -f "$root/$f" ]] || continue
    ERA="$ERA" awk -v file="$f" '
      { l[NR] = $0 }
      END {
        era = ENVIRON["ERA"];
        for (i = 1; i <= NR; i++) {
          if (l[i] !~ /(12\.0|~12|29\.0|~29|116\.9|~117) ?KB/) continue;
          win = l[i-4] "\n" l[i-3] "\n" l[i-2] "\n" l[i-1] "\n" l[i] "\n" l[i+1] "\n" l[i+2];
          if (win ~ era) continue;
          print file ":" i;
        }
      }' "$root/$f"
  done
}
CROSS="$(crossings_unmarked "$MAT" | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "AC12: the three derived crossing figures (~12 KB / ~29 KB / ~117 KB) are re-derived or carry an era marker naming the commit they describe" \
  "${CROSS:-none}" "none"

# ===============================================================================================
suite "AC13 + AC14: the operator-facing disclosure, all of it at once"
# ===============================================================================================
#
# A rewrite that reports the new figures but drops the fail-open sentence does not satisfy AC13, and
# neither does one that keeps the sentence with the old figures: the disclosure's job is to let an
# operator decide, and it can only do that if the direction and the current size are both true.
DENSITY_FIGS="$(printf '%s' "$README_COST4" | grep -oE '[0-9]+(\.[0-9]+)? ?B/struct' | sort -u | grep -c . | tr -d ' \n')"
assert_eq "AC13(a): the crossing is stated at BOTH ENDS of the density range -- at least two distinct bytes-per-structural-character figures, not one density" \
  "$([[ "$DENSITY_FIGS" -ge 2 ]] && echo "both-ends" || echo "ONLY $DENSITY_FIGS DISTINCT B/struct FIGURES")" "both-ends"
assert_eq "AC13(b): it says PLAINLY that a large enough command still outruns the declaration and FAILS OPEN" \
  "$(printf '%s' "$README_COST4" | grep -ciE '(outrun|large enough|still exceeds).{0,120}(fails? open|FAILS OPEN)|(fails? open|FAILS OPEN).{0,120}(outrun|large enough)' | tr -d ' \n' | sed 's/^0$/ABSENT/;s/^[1-9].*/present/')" "present"
assert_eq "AC13(d): it publishes that the stall is paid on the ALLOW path too, with both figures -- the developer running a correctly narrowed \`git add <path>\` pays it in full" \
  "$(printf '%s' "$README_COST4" | grep -ciE '(allow|narrowed).{0,200}[0-9]{3,} ?ms' | tr -d ' \n' | sed 's/^0$/ABSENT/;s/^[1-9].*/present/')" "present"
assert_eq "AC13(e): it says the crossing RETURNS as the tracked corpus grows, since Phase 5 writes one knowledge/issue-archive/<n>.json per issue" \
  "$(printf '%s' "$README_COST4" | grep -ciE 'issue-archive.{0,200}(grow|per issue|returns)|(grow|returns).{0,200}issue-archive' | tr -d ' \n' | sed 's/^0$/ABSENT/;s/^[1-9].*/present/')" "present"
assert_eq "AC14: the superseded '64 KB quote-dense went from over 120 s to 26 s' figure is re-taken, or carries the LOAD and HOST that make it comparable to the new ones" \
  "$(if [[ "$README_COST4" != *"went from over 120"* ]]; then echo "re-taken-or-removed"; \
     elif printf '%s' "$README_COST4" | grep -qiE 'went from over 120.{0,200}(load|darwin|ubuntu)'; then echo labelled; \
     else echo "CARRIED UNRECONCILED AND UNLABELLED beside the new figures"; fi)" \
  "$([[ "$README_COST4" != *"went from over 120"* ]] && echo "re-taken-or-removed" || echo labelled)"

# THE SEAM. The disclosure publishes a density; this suite RE-DERIVES it from the same single
# definition of the structural class, over the same file, and requires them to agree. A hand-copied
# figure restates the contract instead of observing it, and it is exactly the figure a grep-derived
# structural class gets wrong by 37% while every other row stays green.
PUBLISHED_DENS="$(printf '%s' "$README_COST4" | grep -oE '[0-9]+(\.[0-9]+)? ?B/struct' | grep -oE '^[0-9]+(\.[0-9]+)?' | sort -n | head -1)"
MEASURED_DENS="$(printf '%s' "$DENSEST_DENS" | awk '{print $3}')"
assert_eq "AC13/AC1 SEAM: the DENSEST figure the disclosure publishes agrees with this suite's independent re-derivation over the hook's own evaluated _STRUCT class (published ${PUBLISHED_DENS:-none}, re-derived $MEASURED_DENS B/struct from $DENSEST_REL)" \
  "$( "$GATE_REAL_NODE" -e '
     const p = Number(process.argv[1]), m = Number(process.argv[2]);
     if (!Number.isFinite(p) || !Number.isFinite(m) || m === 0) { process.stdout.write("NOT COMPARABLE"); process.exit(0); }
     process.stdout.write(Math.abs(p - m) <= 0.05 ? "agrees" : "DISAGREES by " + Math.abs(p - m).toFixed(2) + " B/struct");
   ' "${PUBLISHED_DENS:-nan}" "$MEASURED_DENS" )" \
  "agrees"

# ===============================================================================================
suite "AC16: no child process receives the caller's command text, at the NEW scale"
# ===============================================================================================
#
# Driven at the floor fixture's own length rather than at a short synthetic one, because that is the
# body this change exists to bring inside the declaration and the escalation branch is where a child
# is started at all. A zero from a spy that was never on the gate's PATH is the same output as a
# zero from a gate that starts no child, which is why the control is part of this criterion.
new_tmpdir || exit 90
SPY_DIR="$NEW_TMPDIR/spy"
mkdir -p "$SPY_DIR"
gate_spy_setup "$SPY_DIR"
gate_reset_env "$P4"
GATE_PATH="$GATE_SPY_PATH"
run_gate "$(gate_payload "$FLOOR_DENY_CMD" agent_id=sub-panelist-1 agent_type=pipeline:qa)"
SPY_DECISION="$GATE_DECISION"
SPY_N="$(gate_spy_invocations)"
SPY_HITS="$(grep -c 'notes.md' "$GATE_SPY_LOG" 2>/dev/null | tr -d ' \n')"
assert_eq "AC16 NON-ZERO CONTROL: the escalation branch really started a child through the spy ($SPY_N invocations) -- without this, the zero below is equally consistent with a spy that was never on the gate's PATH" \
  "$([[ "$SPY_N" -ge 1 ]] && echo "spy-fired" || echo "ZERO SPY LINES -- the shim was not on the gate's PATH, so the row below proves nothing")" \
  "spy-fired"
assert_eq "AC16 NON-VACUITY: the driven call was the DENY branch ($SPY_DECISION), which is the branch that starts a child at all" \
  "$SPY_DECISION" "deny"
assert_eq "AC16: the caller's command text appears in NO child's argv and in NO child's environment, at $FLOOR_CMD_BYTES command bytes" \
  "$SPY_HITS" "0"

record "LOAD at end $(tb_loadavg) (was $LOAD_AT_START at start). Every millisecond figure above is a min-of-3 or a single run as its own row states, taken on $(uname -sr); a figure without its load is not re-takeable."

finish
