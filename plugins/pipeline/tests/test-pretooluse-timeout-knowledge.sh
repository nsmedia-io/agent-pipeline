#!/usr/bin/env bash
# #132, part 2 of 2: THE KNOWLEDGE STORE AND THE DECLARED TIMEOUT (AC17, AC18, AC19).
#
# THIS FILE IS EXPECTED TO BE RED FROM THE MOMENT DEV OPENS THE PR AND TO STAY RED UNTIL THE
# PHASE 5 LIBRARIAN EDIT LANDS. That is structural and it is not a failing implementation.
# `knowledge/living-context/architecture--pretooluse-tracked-write-gate.json` is Librarian-owned;
# neither BA nor Dev may edit it, so the stored `5-SECOND` / `5000ms` literals cannot move inside
# Dev's diff. AC17/AC18/AC19 exist precisely so Phase 4 refuses to close while that record is
# stale. The rows below must NOT be made green by weakening them.
#
# The rows that are Dev's to make green in Phase 3 are the ones about the CHECK -- that it exists,
# that it says out loud what it compared, and that it discriminates. The rows that stay red until
# Phase 5 are the ones about the record's CONTENT. They are labelled `[PHASE-5]` in their names so
# the panel can tell the two apart in a transcript without reading this header.
#
# ---------------------------------------------------------------------------------------------
# THE OUTPUT CONTRACT THIS SUITE DRIVES, AND WHY SPECIFYING ONE IS NOT OVERFITTING.
#
# AC17 is not satisfiable by a check whose output is opaque: its own words are that the check
# "must print, in its own output, the FILE and the LITERAL VALUE it read from the store and
# compared, such that a run which compared ZERO stored literals is distinguishable from a run
# which compared one and found it equal". A criterion that demands machine-distinguishable output
# has to say what distinguishable means, so this suite fixes the minimum shape and nothing else:
#
#   node plugins/pipeline/scripts/check-knowledge-timeout-literals.mjs --root <dir>
#
#     reads <dir>/plugins/pipeline/hooks/hooks.json for the DECLARED PreToolUse timeout and
#     <dir>/knowledge/living-context/*.json for the stored claims, and prints, on stdout, one
#     TAB-separated line per observation plus one summary line:
#
#       COMPARED <TAB> <file-relative-to-root> <TAB> <literal-as-written> <TAB> ok|MISMATCH
#       ADEQUACY <TAB> <file-relative-to-root> <TAB> present|absent
#       RESIDUAL <TAB> <file-relative-to-root> <TAB> present|absent
#       COMPARED-COUNT <TAB> <n>
#
#     exit 0 when every COMPARED line is `ok` AND no qualifying file has ADEQUACY present with
#     RESIDUAL absent; non-zero otherwise.
#
# Anything above that -- how sentences are segmented, how the subject is qualified, whether it is
# one pass or three -- is Dev's, and this suite asserts none of it. What it does assert is that the
# check discriminates, in BOTH directions, against the eight live controls AC18 and the Phase 2
# reviewers name. All eight are real text in the tree at 62d7a17, not planted fixtures; five of
# them sit inside the very file being scanned.
#
# THE ANCHOR MUST BE THE SUBJECT, NOT THE PHRASE. A check anchored on the verbatim parenthetical
# `(not 5000ms -- the declaration is genuinely tiny against the platform's 600s default)` is an
# assertion that its own change removes: AC19 REQUIRES the Phase 5 Librarian to rewrite that exact
# sentence, after which the pattern stops matching, the check turns GREEN BY DELETION OF ITS OWN
# SUBJECT, and it is permanently dead against every future drift AC18 exists to catch. The
# `ADEQUACY-REWRITE SURVIVAL` block below is the row that refuses that: it rewrites the sentence
# the way an honest Librarian would and requires the check to still find and compare a literal.
# ---------------------------------------------------------------------------------------------

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/timeout-bound-lib.sh"
require_node

make_temp_project 132 || exit 90

CHECK_REL="plugins/pipeline/scripts/check-knowledge-timeout-literals.mjs"
STORE_REL="knowledge/living-context/architecture--pretooluse-tracked-write-gate.json"
INFLIGHT_REL="knowledge/living-context/architecture--gate-phase-entry-inflight-boundary.json"

DECLARED_S="$(gate_declared_timeout)"
[[ "$DECLARED_S" =~ ^[0-9]+$ ]] || DECLARED_S=""

record "HOST: $(uname -sr), load $(tb_loadavg), declared PreToolUse timeout as read from hooks.json: [${DECLARED_S:-<absent-or-non-integer>}] s"

# ===============================================================================================
suite "AC17/18/19 SETUP: a materialized tree to mutate, so no row here edits the checkout"
# ===============================================================================================
#
# Every mutation below is applied to a `git archive | tar x` copy. Nothing in this file writes to
# the working tree. A reviewer that mutates the tree it is reviewing corrupts the evidence of every
# other reviewer sharing it, and an interrupted battery leaves the planted defect behind.

new_tmpdir || exit 90
KS_ROOT="$NEW_TMPDIR/base"
mkdir -p "$KS_ROOT"
if tb_materialize "$KS_ROOT"; then KS_MAT=ok; else KS_MAT="FAILED: $TB_MAT_ERR"; fi
assert_eq "the tracked tree materializes into a git-less directory (AC1's corpus mechanism)" "$KS_MAT" "ok"
record "MATERIALIZED from ${TB_MAT_SHA:-<none>} -- $(tb_mat_file_count "$KS_ROOT") files"

assert_eq "VACUITY: the materialized tree carries the living-context store (an empty copy would make every row below pass by scanning nothing)" \
  "$([[ -f "$KS_ROOT/$STORE_REL" ]] && echo present || echo "MISSING: $STORE_REL")" "present"

# The eight controls are asserted to be PRESENT in the tree before any of them is used as a
# control. A control anchored to text that is not there is a zero result about the harness.
for lit in '5-SECOND' '5000ms' '600s' '66.68ms' '4.45ms' '9-13ms'; do
  assert_eq "CONTROL PREMISE: the literal \`$lit\` is live in $STORE_REL (if this is false the record was rewritten and the control below needs a new subject)" \
    "$(grep -c -- "$lit" "$KS_ROOT/$STORE_REL" 2>/dev/null | tr -d ' \n')" "1"
done
assert_eq "CONTROL PREMISE: the literal \`300000ms\` is live in $INFLIGHT_REL (if this is false the record was rewritten and the control below needs a new subject)" \
  "$(grep -c -- '300000ms' "$KS_ROOT/$INFLIGHT_REL" 2>/dev/null | tr -d ' \n')" "1"
assert_eq "CONTROL PREMISE: the literal \`6ms\` is live in $STORE_REL (if this is false the record was rewritten and the control below needs a new subject)" \
  "$([[ "$(grep -c -- 'measured 6ms' "$KS_ROOT/$STORE_REL" 2>/dev/null | tr -d ' \n')" == "1" ]] && echo present || echo ABSENT)" "present"

# ---- driving the check ---------------------------------------------------------------------------
#
# KS_RC / KS_OUT / KS_COMPARED / KS_MISMATCHES are set by ks_run. When the script is ABSENT the
# driver returns the sentinel CHECK-ABSENT and every row below fails with its own message about
# the missing behaviour, rather than one setup throw turning N rows into N skips.
KS_RC=""; KS_OUT=""; KS_COMPARED=""; KS_MISMATCHES=""; KS_LITERALS=""; KS_LINES=""
ks_run() {  # <root>
  local root="$1" out
  KS_RC=""; KS_OUT=""; KS_COMPARED=""; KS_MISMATCHES=""; KS_LITERALS=""; KS_LINES=""
  if [[ ! -f "$KS_ROOT/$CHECK_REL" ]]; then
    KS_OUT="CHECK-ABSENT"; KS_RC="127"; KS_COMPARED="CHECK-ABSENT"; KS_MISMATCHES="CHECK-ABSENT"
    KS_LITERALS="CHECK-ABSENT"; KS_LINES="CHECK-ABSENT"
    return 0
  fi
  out="$( "$GATE_REAL_NODE" "$KS_ROOT/$CHECK_REL" --root "$root" 2>&1 )"
  KS_RC=$?
  KS_OUT="$out"
  KS_COMPARED="$(printf '%s\n' "$out" | awk -F'\t' '$1=="COMPARED-COUNT"{print $2}' | head -1 | tr -d ' ')"
  [[ -n "$KS_COMPARED" ]] || KS_COMPARED="NO-COUNT-LINE"
  KS_LINES="$(printf '%s\n' "$out" | awk -F'\t' '$1=="COMPARED"' | grep -c . | tr -d ' \n')"
  KS_MISMATCHES="$(printf '%s\n' "$out" | awk -F'\t' '$1=="COMPARED" && $4=="MISMATCH"{print $3}' | sort | tr '\n' ' ' | sed 's/ *$//')"
  KS_LITERALS="$(printf '%s\n' "$out" | awk -F'\t' '$1=="COMPARED"{print $3}' | sort | tr '\n' ' ' | sed 's/ *$//')"
  return 0
}

# ks_edit <root> <file-rel> <from> <to>: literal (non-regex) substring replacement inside a JSON
# record, done in node so the file stays valid JSON and so no shell escaping layer sits underneath
# the edit. Prints the number of replacements it made, which the caller ASSERTS -- an edit that
# silently landed nowhere is a mutation that was never planted, and a battery whose mutation never
# lands reports SURVIVED for the wrong reason.
ks_edit() {
  KS_FROM="$3" KS_TO="$4" "$GATE_REAL_NODE" -e '
    const fs = require("node:fs");
    const p = process.argv[1];
    const from = process.env.KS_FROM, to = process.env.KS_TO;
    const src = fs.readFileSync(p, "utf8");
    const n = src.split(from).length - 1;
    if (n > 0) fs.writeFileSync(p, src.split(from).join(to));
    process.stdout.write(String(n));
  ' "$1/$2" 2>/dev/null
}

# ks_clone <name> -> a fresh copy of the materialized tree, so each mutation starts from an
# unmutated tree and no battery step can inherit the previous step's plant. Every copy is a NEW
# registered tmpdir rather than a reused-and-cleared one: nothing in a new script suite may
# hand-roll `rm -rf` (test-harness.sh:159 asserts exactly that), and the harness's single trap
# reclaims each registered dir at exit.
# It SETS A GLOBAL rather than echoing, and must be called as a statement: a `$( ... )` capture
# runs in a SUBSHELL, where new_tmpdir's registry update would be discarded and the harness's trap
# would then never own the directory it handed out.
KS_CLONE=""
ks_clone() {
  KS_CLONE=""
  new_tmpdir || return 90
  KS_CLONE="$NEW_TMPDIR/$1"
  mkdir -p "$KS_CLONE"
  cp -R "$KS_ROOT/." "$KS_CLONE/" 2>/dev/null
}

# ===============================================================================================
suite "AC17: the check says what it compared, so an empty comparison is not a pass"
# ===============================================================================================

ks_run "$KS_ROOT"
KS_BASE_OUT="$KS_OUT"; KS_BASE_COMPARED="$KS_COMPARED"; KS_BASE_MISMATCH="$KS_MISMATCHES"
KS_BASE_LITERALS="$KS_LITERALS"; KS_BASE_LINES="$KS_LINES"

assert_eq "a knowledge-store timeout check EXISTS and runs (absent, every row below is a claim about a check nobody wrote)" \
  "$([[ "$KS_OUT" == "CHECK-ABSENT" ]] && echo "ABSENT: $CHECK_REL" || echo runs)" "runs"

assert_eq "AC17: the check reports a COMPARED-COUNT, so 'compared nothing' is readable in its own output" \
  "$([[ "$KS_COMPARED" =~ ^[0-9]+$ ]] && echo reported || echo "NOT REPORTED: [$KS_COMPARED]")" "reported"

assert_eq "AC17 NON-VACUITY: it compared at least one stored literal (a check that compared zero is not a pass)" \
  "$([[ "$KS_COMPARED" =~ ^[0-9]+$ && "$KS_COMPARED" -ge 1 ]] && echo "at-least-one" || echo "COMPARED $KS_COMPARED")" \
  "at-least-one"

assert_contains "AC17: it names the FILE it read the literal from" "$KS_BASE_OUT" "$STORE_REL"

# THE COUNT MUST COUNT SOMETHING. A summary integer that is not derived from the lines beside it is
# a report about a comparison that may never have happened, and AC17's whole subject is telling
# "compared one and found it equal" apart from "found nothing to compare". Found by mutation: a
# reference implementation with the count replaced by a CONSTANT passed every other row in this
# file, because stripping the clause still changed the COMPARED lines and AC17's own observation is
# satisfied by "a different outcome OR a different count".
assert_eq "AC17 SELF-CONSISTENCY: the reported COMPARED-COUNT equals the number of COMPARED lines printed" \
  "$(if [[ "$KS_COMPARED" == "CHECK-ABSENT" ]]; then echo "NO CHECK RAN, so nothing was counted"; \
     elif [[ "$KS_COMPARED" == "$KS_BASE_LINES" ]]; then echo consistent; \
     else echo "COUNT SAYS $KS_COMPARED, LINES SAY $KS_BASE_LINES"; fi)" "consistent"

# AC17's own deciding observation: strip the timeout clause from the one qualifying file and
# confirm the run is DISTINGUISHABLE from the unmodified one. A check that correctly reddens on a
# wrong value but is byte-identical between 'compared one and agreed' and 'found nothing to
# compare' does not satisfy AC17, and that is the shape a future Librarian edit would silence.
ks_clone strip; KS_D_STRIP="$KS_CLONE"
KS_STRIP_N="$(ks_edit "$KS_D_STRIP" "$STORE_REL" 'with a 5-SECOND timeout (not 5000ms -- the declaration is genuinely tiny' 'with a declaration whose value this sentence no longer states (and nothing here is genuinely tiny')"
assert_eq "MUTATION LANDED: the timeout clause was removed from the strip copy exactly once" "$KS_STRIP_N" "1"
ks_run "$KS_D_STRIP"
assert_eq "AC17 SELF-CONSISTENCY (strip copy): the reported COMPARED-COUNT still equals the number of COMPARED lines printed" \
  "$(if [[ "$KS_COMPARED" == "CHECK-ABSENT" ]]; then echo "NO CHECK RAN, so nothing was counted"; \
     elif [[ "$KS_COMPARED" == "$KS_LINES" ]]; then echo consistent; \
     else echo "COUNT SAYS $KS_COMPARED, LINES SAY $KS_LINES"; fi)" "consistent"
assert_eq "AC17: with the timeout clause removed the run DIFFERS from the unmodified run (compared-count or outcome), it is not byte-identical" \
  "$([[ "$KS_COMPARED" != "$KS_BASE_COMPARED" || "$KS_OUT" != "$KS_BASE_OUT" ]] && echo differs || echo "BYTE-IDENTICAL: compared=$KS_COMPARED both runs")" \
  "differs"

# ===============================================================================================
suite "AC18: every literal, mutated SEPARATELY, with the six discriminating controls"
# ===============================================================================================
#
# The positive cells first. The record states the timeout TWICE in one sentence, so a check that
# reads the first literal and stops ships a record reading '<new>-SECOND timeout (not 5000ms -- ...)'
# -- precisely the stale stored fact this criterion exists to prevent.
#
# NOTE ON DIRECTION. At Phase 3 the unmodified record already disagrees with hooks.json (it says 5,
# the declaration will not), so both positive cells are red for TWO reasons at once and the
# mutation adds nothing observable. The cells below therefore mutate the literal to a value that is
# WRONG IN A DIFFERENT WAY and assert the check names THAT literal, which stays discriminating in
# both eras: before Phase 5 (record stale) and after it (record correct).

ks_positive() {  # <label> <from> <to> <expect-named>
  local d n
  ks_clone "pos-$4"; d="$KS_CLONE"
  n="$(ks_edit "$d" "$STORE_REL" "$2" "$3")"
  assert_eq "MUTATION LANDED: \`$2\` -> \`$3\` replaced exactly once ($1)" "$n" "1"
  ks_run "$d"
  assert_contains "AC18 $1: the check names the mutated literal \`$4\` as a MISMATCH" \
    "$KS_MISMATCHES" "$4"
}
ks_positive "5-SECOND alone" '5-SECOND timeout' '997-SECOND timeout' '997'
ks_positive "5000ms alone" '(not 5000ms' '(not 993000ms' '993000'

# The six DISCRIMINATING CONTROLS. Each must leave the reported MISMATCH set unchanged: none of
# them states THIS hook's declared timeout, and a check that reddens on any of them is wider than
# the property and refuses the correct work of recording a platform default, an in-flight ceiling
# or a measured latency in the store at all.
ks_control() {  # <label> <file-rel> <from> <to>
  local d n
  ks_clone "ctl-$(printf '%s' "$1" | tr -cd 'a-z0-9')"; d="$KS_CLONE"
  n="$(ks_edit "$d" "$2" "$3" "$4")"
  assert_eq "MUTATION LANDED: control \`$1\` replaced exactly once" "$n" "1"
  ks_run "$d"
  # A control whose two sides are BOTH the CHECK-ABSENT sentinel would report `unchanged` and
  # prove nothing, which is the same green a working control produces. The sentinel is therefore
  # collapsed to its own failing value first: "no check ran" is never "the control held".
  assert_eq "AC18 CONTROL (must stay unchanged): mutating \`$1\` does not move the MISMATCH set -- it does not state this hook's declared timeout" \
    "$(if [[ "$KS_MISMATCHES" == "CHECK-ABSENT" ]]; then echo "NO CHECK RAN, so this control observed nothing"; \
       elif [[ "$KS_MISMATCHES" == "$KS_BASE_MISMATCH" ]]; then echo unchanged; \
       else echo "MOVED: [$KS_MISMATCHES] against baseline [$KS_BASE_MISMATCH]"; fi)" "unchanged"
}
ks_control "600s platform default" "$STORE_REL" "platform's 600s default" "platform's 991s default"
ks_control "300000ms in-flight margin" "$INFLIGHT_REL" "MARGIN = 300000ms" "MARGIN = 990000ms"
ks_control "66.68ms node cold start" "$STORE_REL" "66.68ms" "989.68ms"
ks_control "4.45ms shell baseline" "$STORE_REL" "4.45ms" "988.45ms"
ks_control "6ms no-shebang measurement" "$STORE_REL" "measured 6ms" "measured 987ms"
ks_control "9-13ms with-shebang measurement" "$STORE_REL" "9-13ms" "986-987ms"

# THE POPULATION CELL. AC18's two literal cells and AC17's naming cell are jointly satisfiable by a
# hardcode that reads one file and two offsets. A SECOND `status: current` record carrying the same
# sentence is what refuses that: the population must be derived at run time from `status: current`
# across the whole directory, not from a filename.
ks_clone pop; KS_D_POP="$KS_CLONE"
"$GATE_REAL_NODE" -e '
  const fs = require("node:fs");
  const [, src, dst] = process.argv;
  const rec = JSON.parse(fs.readFileSync(src, "utf8"));
  const copy = JSON.parse(JSON.stringify(rec));
  copy.slug = "architecture--pretooluse-timeout-population-control";
  copy.title = "POPULATION CONTROL for #132 AC18";
  copy.status = "current";
  copy.content = "The PreToolUse Bash gate is declared in hooks.json with a 5-SECOND timeout (not 5000ms), and this sentence exists only so a checker cannot satisfy AC18 by hardcoding one filename.";
  fs.writeFileSync(dst, JSON.stringify(copy, null, 2));
' "$KS_D_POP/$STORE_REL" "$KS_D_POP/knowledge/living-context/architecture--pretooluse-timeout-population-control.json"
KS_POP_N="$(ks_edit "$KS_D_POP" "knowledge/living-context/architecture--pretooluse-timeout-population-control.json" '5-SECOND timeout (not 5000ms)' '984-SECOND timeout (not 984000ms)')"
assert_eq "MUTATION LANDED: the population-control copy carries the mutated sentence" "$KS_POP_N" "1"
ks_run "$KS_D_POP"
assert_contains "AC18 POPULATION: a SECOND status:current record carrying the sentence is scanned too (the file list is derived at run time, not spelled)" \
  "$KS_MISMATCHES" "984"

# A `status: archived` copy of the same mutated sentence must NOT be scanned: the population is
# `status: current`, and a check that reads every file regardless of status would refuse correct
# work on every superseded record in the store.
ks_clone arch; KS_D_ARCH="$KS_CLONE"
"$GATE_REAL_NODE" -e '
  const fs = require("node:fs");
  const [, src, dst] = process.argv;
  const rec = JSON.parse(fs.readFileSync(src, "utf8"));
  const copy = JSON.parse(JSON.stringify(rec));
  copy.slug = "architecture--pretooluse-timeout-archived-control";
  copy.title = "ARCHIVED CONTROL for #132 AC18";
  copy.status = "archived";
  copy.content = "The PreToolUse Bash gate is declared in hooks.json with a 982-SECOND timeout (not 982000ms). This record is archived and must not be compared.";
  fs.writeFileSync(dst, JSON.stringify(copy, null, 2));
' "$KS_D_ARCH/$STORE_REL" "$KS_D_ARCH/knowledge/living-context/architecture--pretooluse-timeout-archived-control.json"
ks_run "$KS_D_ARCH"
assert_eq "AC18 POPULATION (other direction): a status:archived record carrying the same sentence is NOT compared" \
  "$(if [[ "$KS_MISMATCHES" == "CHECK-ABSENT" ]]; then echo "NO CHECK RAN, so this control observed nothing"; \
     elif [[ "$KS_MISMATCHES" == *982* ]]; then echo "COMPARED an archived record"; \
     else echo not-compared; fi)" "not-compared"

# ===============================================================================================
suite "AC19: claim drift -- an adequacy statement without the residual the README discloses"
# ===============================================================================================
#
# THIS IS NOT VALUE DRIFT. A number-only edit satisfies AC18 and leaves this open: the surviving
# parenthetical frames the declaration as comfortably small and says nothing about the timeout-kill
# fail-open the README must disclose under AC13. A record that carries NO adequacy statement at all
# also satisfies AC19, which is why the two controls below run in the must-stay-GREEN direction.

ks_run "$KS_ROOT"
KS_ADQ="$(printf '%s\n' "$KS_BASE_OUT" | awk -F'\t' -v f="$STORE_REL" '$1=="ADEQUACY" && $2==f {print $3}' | head -1)"
KS_RES="$(printf '%s\n' "$KS_BASE_OUT" | awk -F'\t' -v f="$STORE_REL" '$1=="RESIDUAL" && $2==f {print $3}' | head -1)"

assert_eq "AC19: the check reports whether the record carries an ADEQUACY statement about the declaration" \
  "$([[ "$KS_ADQ" == "present" || "$KS_ADQ" == "absent" ]] && echo reported || echo "NOT REPORTED: [$KS_ADQ]")" "reported"
assert_eq "AC19: and whether it carries the RESIDUAL (a large enough command still outruns the declaration and the hook fails open)" \
  "$([[ "$KS_RES" == "present" || "$KS_RES" == "absent" ]] && echo reported || echo "NOT REPORTED: [$KS_RES]")" "reported"
assert_eq "[PHASE-5] AC19: the record does NOT frame the declaration as adequate while omitting the residual (Librarian-owned; RED until the Phase 5 pass, and it must not be made green by weakening this row)" \
  "$(if [[ -z "$KS_ADQ" || -z "$KS_RES" ]]; then echo "NO ADEQUACY/RESIDUAL LINE, so nothing was observed"; \
     elif [[ "$KS_ADQ" == "present" && "$KS_RES" != "present" ]]; then echo "ADEQUACY-WITHOUT-RESIDUAL"; \
     else echo consistent; fi)" \
  "consistent"

# TWO CONTROLS IN THE MUST-GO-GREEN DIRECTION. Without them "AC19 is satisfied" and "the check
# always fires" are the same output, and the second would refuse every honest Librarian rewrite.
ks_clone noadq; KS_D_NOADQ="$KS_CLONE"
KS_NOADQ_N="$(ks_edit "$KS_D_NOADQ" "$STORE_REL" ' (not 5000ms -- the declaration is genuinely tiny against the platform' ' (not 5000ms; the platform')"
assert_eq "MUTATION LANDED: the adequacy clause was removed from the no-adequacy copy" "$KS_NOADQ_N" "1"
ks_run "$KS_D_NOADQ"
KS_ADQ2="$(printf '%s\n' "$KS_OUT" | awk -F'\t' -v f="$STORE_REL" '$1=="ADEQUACY" && $2==f {print $3}' | head -1)"
assert_eq "AC19 CONTROL (must go GREEN): a record carrying NO adequacy statement satisfies AC19 even with no residual" \
  "$KS_ADQ2" "absent"

ks_clone resid; KS_D_RESID="$KS_CLONE"
KS_RESID_N="$(ks_edit "$KS_D_RESID" "$STORE_REL" 'and an explicit fail-open tail' 'A LARGE ENOUGH COMMAND STILL OUTRUNS THE DECLARED PreToolUse TIMEOUT: the hook is killed, emits nothing, and the call is ALLOWED -- see README item 27 cost (4) for the lengths and densities where that begins. There is also an explicit fail-open tail')"
assert_eq "MUTATION LANDED: the residual sentence was added to the residual copy" "$KS_RESID_N" "1"
ks_run "$KS_D_RESID"
KS_RES2="$(printf '%s\n' "$KS_OUT" | awk -F'\t' -v f="$STORE_REL" '$1=="RESIDUAL" && $2==f {print $3}' | head -1)"
assert_eq "AC19 CONTROL (must go GREEN): adding the residual sentence to the record satisfies AC19 with the adequacy statement left standing" \
  "$KS_RES2" "present"

# ===============================================================================================
suite "ADEQUACY-REWRITE SURVIVAL: the check must not go green by deletion of its own subject"
# ===============================================================================================
#
# THE DEFECT THIS ROW REFUSES, SPELLED OUT BECAUSE IT PASSES EVERY OTHER ROW IN THIS FILE. Anchor
# the check on the verbatim parenthetical `(not (\d+)ms -- the declaration is genuinely tiny` and
# every cell above is satisfied today. Then Phase 5 lands the AC19 rewrite that this issue
# REQUIRES, the anchor is deleted, the pattern matches nothing, COMPARED-COUNT falls to zero, and
# the check reports success forever after -- against a record it is no longer reading. That is an
# assertion outliving its own premise, shipped inside the change that removes the premise.
#
# The rewrite below is what an honest Librarian pass produces: same subject, no surviving phrase.
ks_clone rewrite; KS_D_RW="$KS_CLONE"
# The two strings go through the ENVIRONMENT, not through the shell quoting, because the record's
# own sentence contains an apostrophe and a single-quoted `node -e` body cannot carry one. A
# shell-escaping layer stacked underneath a mutation is how a battery reports that it planted an
# edit it never planted.
KS_RW_FROM="with a 5-SECOND timeout (not 5000ms -- the declaration is genuinely tiny against the platform's 600s default)"
KS_RW_TO="with a declared timeout of 977 seconds (the field is SECONDS, not milliseconds, against the platform's 600s default). A large enough command still outruns that declaration: the hook is killed, emits nothing, and the call is ALLOWED -- README item 27 cost (4) carries the lengths and densities where the crossing begins"
KS_RW_STATUS="$(KS_FROM="$KS_RW_FROM" KS_TO="$KS_RW_TO" "$GATE_REAL_NODE" -e '
  const fs = require("node:fs");
  const p = process.argv[1];
  const rec = JSON.parse(fs.readFileSync(p, "utf8"));
  const before = rec.content;
  rec.content = before.split(process.env.KS_FROM).join(process.env.KS_TO);
  fs.writeFileSync(p, JSON.stringify(rec, null, 2));
  process.stdout.write(before === rec.content ? "NO-OP" : "rewritten");
' "$KS_D_RW/$STORE_REL" 2>/dev/null)"
assert_eq "MUTATION LANDED: the record was rewritten the way an AC19-compliant Librarian pass would rewrite it" \
  "$KS_RW_STATUS" "rewritten"
ks_run "$KS_D_RW"
assert_eq "SURVIVAL: after the AC19 rewrite the check still COMPARES at least one literal (a check anchored on the retired phrase reports zero here and is dead forever)" \
  "$([[ "$KS_COMPARED" =~ ^[0-9]+$ && "$KS_COMPARED" -ge 1 ]] && echo "still-comparing" || echo "COMPARED $KS_COMPARED after the rewrite -- the anchor was the phrase, not the subject")" \
  "still-comparing"
assert_contains "SURVIVAL: and it still names the rewritten literal as a MISMATCH, so drift after the Librarian pass is still caught" \
  "$KS_MISMATCHES" "977"

# ===============================================================================================
suite "[PHASE-5] AC18: the stored literals equal the declared timeout"
# ===============================================================================================
#
# THESE TWO ROWS ARE THE KNOWN-RED PAIR. They compare the record's CONTENT against hooks.json, and
# the record is Librarian-owned, so they cannot go green inside Dev's diff. Recorded in
# impl-report.json as known-red with this reason; the orchestrator must not merge on a green suite
# obtained by weakening them.
ks_run "$KS_ROOT"
assert_eq "[PHASE-5] AC18: every compared literal in a status:current record equals hooks.json's declared PreToolUse timeout (${DECLARED_S:-?} s)" \
  "$KS_MISMATCHES" ""
assert_eq "[PHASE-5] AC18: and the check exits 0 on the unmodified tree" \
  "$([[ "$KS_RC" == "0" ]] && echo "exit-0" || echo "EXIT $KS_RC -- mismatched literals [$KS_MISMATCHES], adequacy [$KS_ADQ], residual [$KS_RES]")" \
  "exit-0"

record "COMPARED on the unmodified tree: count=[$KS_BASE_COMPARED] literals=[$KS_BASE_LITERALS] mismatched=[$KS_BASE_MISMATCH]"

finish
