#!/usr/bin/env bash
# verify-19.sh - the executable verification contract for issue #19.
#
# WHAT THIS IS: a COMMAND you run by hand. It is NOT a CI gate, it is NOT
# registered in plugins/pipeline/tests/run.sh, and nothing runs it for you.
# Issue #19 forbids creating or modifying anything under plugins/pipeline/tests/,
# so this battery lives in the artifact directory and is invoked explicitly:
#
#     bash .pipeline/19/verify-19.sh
#
# It is authored in Phase 3a, BEFORE any implementation exists. It therefore
# EXITS NON-ZERO TODAY, on purpose, and the record at
# .pipeline/19/qa-battery-record-19.md names exactly which cells fail now and
# why. After a correct implementation of .pipeline/19/design.json it exits 0.
#
# DISCIPLINE BAKED IN:
#   * A SKIP IS NOT A PASS. Any cell that cannot run prints SKIP and the battery
#     cannot exit 0.
#   * A VACUOUS PASS IS A FAIL. Every cell whose assertion would be trivially
#     satisfied by an empty diff asserts its presence half FIRST and
#     unconditionally, and reports VACUOUS (counted as a failure) otherwise.
#   * A ZERO NEEDS A NON-ZERO CONTROL. Run `bash verify-19.sh --controls` to
#     plant each defect on a throwaway clone and watch the corresponding cell
#     redden. Controls never touch the working tree.
#
# MODES:
#   (no args)    run every cell
#   --controls   run the plant-and-observe control battery on throwaway clones
#   --no-suites  skip the slow non-regression suites (AC3/AC10 report SKIP, and
#                the battery then cannot exit 0 - this is for fast iteration)
#   --list       print the cell inventory and exit
#
# EXIT: 0 only when every cell PASSED. 1 if any cell FAILED, SKIPPED or was
# VACUOUS. 2 on a harness error (bad repo, missing design.json).

set -uo pipefail

# ---------------------------------------------------------------- bootstrap --

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || {
  echo "HARNESS ERROR: $SCRIPT_DIR is not inside a git repository" >&2; exit 2; }
cd "$REPO" || exit 2

ART="$REPO/.pipeline/19"
DESIGN="$ART/design.json"
[ -r "$DESIGN" ] || { echo "HARNESS ERROR: cannot read $DESIGN" >&2; exit 2; }

AGENTS=(plugins/pipeline/agents/*.md)
NAGENTS=${#AGENTS[@]}
PIPEMD=plugins/pipeline/commands/pipeline.md

BASE=$(git merge-base origin/main HEAD 2>/dev/null) || BASE=""
# HISTORICAL PIN, LEFT UNCHANGED BY THE LIBRARIAN (2026-09-02, #106 archival pass).
# FROZEN_SHA is what the ten-file replicated span hashed to AT #19's merge, and this
# script's job was to prove #19's own edits did not move it. Rewriting it to match a
# later tree would falsify that historical claim, not correct it. #106 (merged fc9a171)
# legitimately re-edited the span (a stale citation) and moved the digest to
# 847cd28217115c41dc8628cb8e35a4f9162c5bfe -- see
# knowledge/living-context/architecture--agent-contract-replication-digest.json. Running
# this script against a tree at or after #106 will therefore FAIL this cell on that
# ground alone; that is expected drift-with-provenance, not a regression in #19's work,
# and not a defect in this pin.
FROZEN_SHA=14b65c48479dfceefb780689adccfbd53656b21e
FROZEN_LINES=15

RUN_SUITES=1
RUN_AC9=1
MODE=cells
for a in "$@"; do
  case "$a" in
    --controls)  MODE=controls ;;
    --no-suites) RUN_SUITES=0 ;;
    --fast)      RUN_AC9=0 ;;
    --list)      MODE=list ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/verify19.XXXXXX") || exit 2
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

# ------------------------------------------------------------- cell harness --

PASS=0; FAIL=0; SKIP=0
RESULTS=()
CUR_AC=""; CUR_NAME=""

cell() { CUR_AC="$1"; CUR_NAME="$2"; }
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS  $CUR_AC  $CUR_NAME"); printf 'PASS  %-7s %s\n' "$CUR_AC" "$CUR_NAME"; [ $# -gt 0 ] && printf '        %s\n' "$@"; return 0; }
no()   { FAIL=$((FAIL+1)); RESULTS+=("FAIL  $CUR_AC  $CUR_NAME"); printf 'FAIL  %-7s %s\n' "$CUR_AC" "$CUR_NAME"; printf '        %s\n' "$@"; return 0; }
vac()  { FAIL=$((FAIL+1)); RESULTS+=("VACUOUS(=FAIL)  $CUR_AC  $CUR_NAME"); printf 'FAIL  %-7s %s  [VACUOUS - assertion had nothing to bite on]\n' "$CUR_AC" "$CUR_NAME"; printf '        %s\n' "$@"; return 0; }
sk()   { SKIP=$((SKIP+1)); RESULTS+=("SKIP(=FAIL)  $CUR_AC  $CUR_NAME"); printf 'SKIP  %-7s %s  [A SKIP IS NOT A PASS]\n' "$CUR_AC" "$CUR_NAME"; printf '        %s\n' "$@"; return 0; }

hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# ------------------------------------------------------------- shared probes --

# The frozen-span digest, extracted BY CONTENT ANCHOR, never by line number.
frozen_digest() {
  sed -n '/^## The property, not the fix/,/This block is replicated verbatim in ten files\./p' "$1" \
    | shasum | cut -d' ' -f1
}
frozen_linecount() {
  sed -n '/^## The property, not the fix/,/This block is replicated verbatim in ten files\./p' "$1" | wc -l | tr -d ' '
}

# Count, over the NINE agent contracts AT THE MERGE BASE, of files containing a
# literal. This is what makes a chosen literal's "pre-change count of 0" claim
# checkable from the post-change tree.
pre_change_files_with() {
  local lit="$1" n=0 f
  [ -n "$BASE" ] || { echo "-1"; return; }
  for f in "${AGENTS[@]}"; do
    if git show "$BASE:$f" 2>/dev/null | grep -qF -- "$lit"; then n=$((n+1)); fi
  done
  echo "$n"
}

files_with() {  # over the nine agent contracts, in the working tree
  local lit="$1" n=0 f
  for f in "${AGENTS[@]}"; do
    if grep -qF -- "$lit" "$f"; then n=$((n+1)); fi
  done
  echo "$n"
}

# NOTE: `grep -c` prints 0 AND exits 1 when there is no match. Under
# `set -o pipefail` a naive `... || echo 0` therefore emits TWO zeros and every
# downstream integer test breaks. Swallow the status inside the group instead.
count_in() { local c; c=$( { grep -cF -- "$2" "$1" 2>/dev/null || true; } | head -1 | tr -d ' \n' ); echo "${c:-0}"; }

# Is `needle` within `w` characters of `anchor` in `file` (newlines flattened)?
# Used instead of splitting on '.', because one of the strings under test IS
# `git add .` - a period-splitting "same sentence" check cuts it in half.
# exit 0 = within window, 1 = outside, 2 = anchor absent.
window_has() {
  tr '\n' ' ' < "$1" | awk -v a="$2" -v w="$3" -v nd="$4" '
    { i = index($0, a); if (i == 0) exit 2;
      s = i - w; if (s < 1) s = 1;
      win = substr($0, s, w * 2 + length(a));
      exit (index(win, nd) > 0 ? 0 : 1) }'
}

# The diff, split into the change under review and the pipeline's own bookkeeping.
# .pipeline/** is orchestrator bookkeeping (status.json, artifacts, this file).
# It is carved out of the SUBSET half of AC11 and is still held to the
# FORBIDDEN-PATH half. The carve-out is required because the branch already
# carries a committed .pipeline/19/status.json against origin/main; without it
# AC11 fails on the orchestrator's bookkeeping rather than on Dev's work.
diff_all()    { [ -n "$BASE" ] && git diff --name-only "$BASE"...HEAD; }
diff_review() { diff_all | grep -v '^\.pipeline/' || true; }
added_lines() { [ -n "$BASE" ] && git diff -U0 "$BASE"...HEAD -- "$@" | grep '^+' | grep -v '^+++' || true; }

# EVERY changed line on the + side, not just each hunk's START.
# THE DEFECT THIS REPLACES (QA concern C2, found by a plant that SURVIVED a
# green battery): the old spelling was
#     grep -oE '^@@ -[0-9,]+ \+([0-9]+)' | sed 's/.*+//'
# which keeps c from `@@ -a,b +c,d @@` and DISCARDS d. A single contiguous hunk
# that STARTS inside a permitted span and ENDS outside it was therefore invisible:
# a 6-line edit at pipeline.md 808-813, crossing the preamble end at 811 and
# rewriting the `### Dispatch model routing` heading itself, left the battery
# byte-identical to a clean run while AC12.s printed "all changed hunks inside
# preamble span 627-811". AC12.x is masked by the AC2.a digest cell; AC12.s is
# masked by nothing, so the cells below claimed a line-level property and
# measured a hunk-level one.
# d is omitted (meaning 1) for a single-line hunk. d=0 means a pure DELETION,
# which changes no line on the + side; it is reported as the single line c so a
# deletion inside a guarded span still reddens rather than vanishing.
changed_lines() {  # file -> one + side line number per output line
  [ -n "$BASE" ] || return 0
  git diff -U0 "$BASE"...HEAD -- "$1" \
    | grep -oE '^@@ -[0-9,]+ \+[0-9]+(,[0-9]+)? ' \
    | sed -E 's/^@@ -[0-9,]+ \+//; s/ $//' \
    | awk -F, '{ s=$1; n=(NF>1 ? $2 : 1); if (n==0) print s; else for (i=0;i<n;i++) print s+i }'
}

# The four literals under test. Dev may re-choose them, but each must still
# carry a PRE-CHANGE count of 0 (AC5/AC6/AC7/AC13) - the cell below enforces
# that rather than trusting the choice. Read from impl-report.json when present.
IMPL="$ART/impl-report.json"
read_literal() {  # $1 = json key, $2 = default
  local v=""
  if [ -r "$IMPL" ] && command -v node >/dev/null 2>&1; then
    v=$(node -e '
      const fs=require("fs");
      try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        const s=j.chosen_literals||j.literals||(j.qa_signoff&&j.qa_signoff.chosen_literals)||{};
        if(typeof s[process.argv[2]]==="string") process.stdout.write(s[process.argv[2]]);
      }catch(e){}' "$IMPL" "$1" 2>/dev/null)
  fi
  [ -n "$v" ] && echo "$v" || echo "$2"
}
LIT_MEDIUM=$(read_literal medium     'absolute-git-dir')
LIT_TRIGGER=$(read_literal trigger   'about to write a tracked file')
LIT_HYGIENE=$(read_literal hygiene   'stage explicit paths')
LIT_DISCLOSE=$(read_literal disclosure 'silence is not compliance')
LIT_TERM='copied byte-for-byte'

if [ "$MODE" = list ]; then
  echo "cell inventory (AC ids; AC9.<topology>.* expand twice at runtime, once per topology):"
  grep -oE 'cell +"?AC[A-Za-z0-9.]+' "$0" | sed -E "s/.*cell +\"?//" | sort -u | sed 's/^/  /'
  exit 0
fi

echo "verify-19.sh   repo=$REPO"
echo "               HEAD=$(git rev-parse --short HEAD)  base=${BASE:0:7}  agents=$NAGENTS"
echo "               literals: medium=[$LIT_MEDIUM] trigger=[$LIT_TRIGGER] hygiene=[$LIT_HYGIENE] disclosure=[$LIT_DISCLOSE]"
echo "               THIS IS A COMMAND, NOT A CI GATE."

# ============================================================================
#  CONTROL BATTERY - plant each defect on a throwaway clone, watch it redden.
# ============================================================================
if [ "$MODE" = controls ]; then
  hdr "CONTROL BATTERY (plant a defect, RUN THIS BATTERY, watch the NAMED CELL move)"
  cat <<'CTLNOTE'
  Each control plants a defect on a throwaway clone and then INVOKES THIS
  BATTERY inside that clone, asserting the NAMED CELL changes state. It does
  not restate the cell's assertion.

  THE DEFECT THIS REPLACES (QA structural finding): the previous controls
  re-implemented each probe INLINE, so a control firing proved that the
  CONTROL's copy of the assertion worked and said nothing about the cell that
  ships. That is why two real cell defects - AC12.s measuring hunk starts while
  claiming changed lines, and AC9.obs discriminating by English adjectives with
  no non-zero control - both survived a fully green --controls run.

  Nested runs use --no-suites --fast, so AC3/AC10/AC9.main/AC9.linked report
  SKIP inside them. That is harmless here: each control reads ONE named cell's
  status, never the nested exit code.
CTLNOTE
  C="$SCRATCH/ctl"
  git clone -q --no-hardlinks "$REPO" "$C" || { echo "clone failed" >&2; exit 2; }
  mkdir -p "$C/.pipeline/19"
  cp "$SCRIPT_DIR/verify-19.sh" "$C/.pipeline/19/" || exit 2
  for f in design.json impl-report.json baseline-run-sh.txt; do
    [ -r "$ART/$f" ] && cp "$ART/$f" "$C/.pipeline/19/"
  done
  CFAIL=0

  nested() { ( cd "$C" && env "$@" bash .pipeline/19/verify-19.sh --no-suites --fast </dev/null 2>&1 ); }
  cell_status() {  # full-output, cell-id -> PASS | FAIL | SKIP | ABSENT
    printf '%s\n' "$1" | awk -v id="$2" \
      '($1=="PASS"||$1=="FAIL"||$1=="SKIP") && $2==id { print $1; f=1; exit } END { if (!f) print "ABSENT" }'
  }

  printf '\n  baseline: running the battery inside the CLEAN clone ...\n'
  CLEAN=$(nested V19_CTL=1)
  printf '  clean clone: %s\n\n' "$(printf '%s\n' "$CLEAN" | grep -E '^  PASS=' | tr -s ' ')"

  ctl_cell() {  # name, cell-id, mutation, want(FAIL|PASS), [restore]
    local name="$1" id="$2" mut="$3" want="${4:-FAIL}" restore="${5:-git checkout -- .}"
    local before after out
    before=$(cell_status "$CLEAN" "$id")
    ( cd "$C" && eval "$mut" ) >/dev/null 2>&1
    out=$(nested V19_CTL=1); after=$(cell_status "$out" "$id")
    ( cd "$C" && eval "$restore" ) >/dev/null 2>&1
    if [ "$before" != PASS ]; then
      printf 'CONTROL UNUSABLE  %-10s %s\n        the cell is %s in the CLEAN clone, so a move proves nothing about it\n' \
        "$id" "$name" "$before"; CFAIL=$((CFAIL+1)); return
    fi
    if [ "$after" = "$want" ]; then
      if [ "$want" = FAIL ]; then printf 'CONTROL FIRES     %-10s %s  (cell PASS -> %s)\n' "$id" "$name" "$after"
      else printf 'CONTROL SURVIVES  %-10s %s  (cell stays %s - EXPECTED, see note)\n' "$id" "$name" "$after"; fi
    else
      printf 'CONTROL MISBEHAVED %-10s %s  (cell PASS -> %s, wanted %s)\n' "$id" "$name" "$after" "$want"
      CFAIL=$((CFAIL+1))
    fi
  }

  # --- the frozen span, its anchor, and the two pinned telemetry counts ---
  ctl_cell "an edit INSIDE the frozen span" AC2.a \
      "perl -0pi -e 's/\*\*Halves\.\*\*/**Halves.** MUTANT/' $PIPEMD"
  ctl_cell "a second 'replicated verbatim' breaks the extraction anchor" AC2.b \
      "printf '\nreplicated verbatim\n' >> plugins/pipeline/agents/qa.md"
  ctl_cell "the forbidden shard-path sentence reappears" AC1.a \
      "printf '\nwrite the shard beside your own worktree at <WORKTREE_PATH>/.pipeline/<issue>/\n' >> $PIPEMD"
  ctl_cell "the pinned fallback-shards count moves off 1" AC1.b \
      "printf '\nfallback-shards/peer-review.<role>.json\n' >> $PIPEMD"

  # --- the four keyed literals and the nine-copy byte identity ---
  ctl_cell "the MEDIUM literal stripped from qa.md ALONE (the 9-vs-8 case)" AC5 \
      "perl -0pi -e 's/\Q$LIT_MEDIUM\E//g' plugins/pipeline/agents/qa.md"
  ctl_cell "one character of dba.md's copy of the block diverges" ACblk.1 \
      "perl -0pi -e 's/(not a variation\.)\s*\z/not a variation!\n/' plugins/pipeline/agents/dba.md"

  # --- C2: THE PLANT THAT USED TO SURVIVE ---
  # A contiguous edit STARTING inside the preamble span and ENDING outside it,
  # rewriting the `### Dispatch model routing` heading that bounds the span.
  # Under the old hunk-start extraction the whole battery stayed byte-identical
  # to a clean run. It must now redden AC12.s. Needs a COMMIT, because the cell
  # reads the diff against the merge base, so the restore is a reset.
  ctl_cell "a contiguous hunk CROSSING the end of the preamble span" AC12.s \
      "PS=\$(grep -nF '### Dispatch model routing' $PIPEMD | head -1 | cut -d: -f1); \
       awk -v a=\$((PS-3)) -v b=\$((PS+2)) 'NR>=a && NR<=b { \$0 = \$0 \" QAPLANT2\" } { print }' $PIPEMD > /tmp/p2.\$\$ \
       && mv /tmp/p2.\$\$ $PIPEMD && git commit -aqm 'control: boundary-crossing hunk'" \
      FAIL "git reset -q --hard HEAD~1"

  # --- C4: both directions, on the cell itself ---
  ctl_cell "a bare --git-dir PREDICATE line (no prescribed spelling beside it)" AC9.obs \
      "printf 'Compare \`git rev-parse --git-dir\` between the two trees and never proceed unless they differ.\n\n%s' \"\$(cat plugins/pipeline/agents/qa.md)\" > /tmp/gd.\$\$ && mv /tmp/gd.\$\$ plugins/pipeline/agents/qa.md"
  ctl_cell "a DISQUALIFYING MENTION of --git-dir must NOT be read as a use" AC9.obs \
      "printf 'Use \`--absolute-git-dir\`, never \`--git-dir\`, which is relative in a main checkout.\n\n%s' \"\$(cat plugins/pipeline/agents/qa.md)\" > /tmp/gd.\$\$ && mv /tmp/gd.\$\$ plugins/pipeline/agents/qa.md" \
      PASS

  # --- THE MUTATION WE EXPECT TO SURVIVE ---
  # A battery in which every mutation reddens cannot tell real coverage from a
  # probe that reddens on any edit at all: "all red" is a zero result about the
  # instrument. The frozen-span digest must be BLIND to an edit OUTSIDE the
  # span. If this one reddens, AC2.a is measuring the file, not the span.
  ctl_cell "an edit OUTSIDE the frozen span leaves the digest alone" AC2.a \
      "printf '\nMUTANT LINE APPENDED AT EOF, OUTSIDE THE SPAN\n' >> $PIPEMD" PASS

  # --- C6: the expiry path of the live-defect control, exercised ---
  # Cannot plant the ABSENCE of a directory owned by another session, so point
  # the cell at a path that does not exist and require it to PASS with its
  # expiry message rather than SKIP.
  printf '\n'
  EXP=$(nested V19_LIVE_CTR=/private/tmp/sketchB-43-DOES-NOT-EXIST V19_CTL=1)
  EXPS=$(cell_status "$EXP" AC16.live)
  if [ "$EXPS" = PASS ]; then
    printf 'CONTROL FIRES     %-10s %s\n        %s\n' "AC16.live" \
      "the ABSENCE path is a PASS carrying its expiry, not a SKIP that reddens the battery" \
      "$(printf '%s\n' "$EXP" | grep -A2 '^PASS  AC16.live' | tail -2 | tr -s ' ' | head -1)"
  else
    printf 'CONTROL MISBEHAVED %-10s absence reported %s, wanted PASS\n' "AC16.live" "$EXPS"; CFAIL=$((CFAIL+1))
  fi

  echo
  if [ "$CFAIL" = 0 ]; then
    echo "CONTROL BATTERY: every control behaved as predicted (fired, or survived where predicted),"
    echo "                 and every one of them read the SHIPPING CELL, not a copy of its assertion."
    exit 0
  else
    echo "CONTROL BATTERY: $CFAIL control(s) MISBEHAVED - the instrument is not trustworthy."; exit 1
  fi
fi

# ============================================================================
#  AC11 / diff shape  - run FIRST, because several later cells are vacuous
#                       without a non-empty diff and must say so.
# ============================================================================
hdr "diff shape"

EDITABLE_RE='^(plugins/pipeline/agents/[a-z-]+\.md|plugins/pipeline/commands/pipeline\.md)$'
FORBIDDEN_RE='^(plugins/pipeline/tests/|plugins/pipeline/hooks/|plugins/pipeline/schemas/|plugins/pipeline/scripts/|\.github/workflows/|schemas/status\.schema\.json|pipeline\.config\.json|README\.md)'

cell AC11 "diff is NON-EMPTY and a subset of the declared editable surface"
if [ -z "$BASE" ]; then
  sk "no merge-base with origin/main; cannot compute the reviewed diff"
else
  DR=$(diff_review); NDR=$(printf '%s' "$DR" | grep -c . || true)
  if [ "$NDR" = 0 ]; then
    vac "the reviewed diff (excluding .pipeline/ bookkeeping) is EMPTY. The presence half is asserted unconditionally, so 'nothing changed' is a FAILURE, not a subset."
  else
    STRAY=$(printf '%s\n' "$DR" | grep -Ev "$EDITABLE_RE" || true)
    if [ -n "$STRAY" ]; then no "outside the editable surface:" $(printf '%s ' $STRAY)
    else ok; fi
  fi
fi

cell AC11.f "diff touches NO forbidden path (tests/ hooks/ schemas/ scripts/ workflows/ config/README)"
if [ -z "$BASE" ]; then sk "no merge-base"
else
  BAD=$(diff_all | grep -E "$FORBIDDEN_RE" || true)
  # Non-zero control for a zero-assertion: prove the matcher can fire at all.
  CTLHIT=$(printf 'plugins/pipeline/scripts/config-doctor.mjs\n' | grep -cE "$FORBIDDEN_RE")
  if [ "$CTLHIT" != 1 ]; then no "HARNESS: the forbidden-path matcher does not even match a known-forbidden path; the zero above would be meaningless."
  elif [ -n "$BAD" ]; then no "forbidden paths in the diff:" $(printf '%s ' $BAD)
  else ok "0 forbidden paths (matcher control fired: 1/1 on a planted path)"; fi
fi

cell AC11.n "the nine agent contracts and pipeline.md are ALL in the diff"
if [ -z "$BASE" ]; then sk "no merge-base"
else
  MISS=""
  for f in "${AGENTS[@]}" "$PIPEMD"; do
    diff_all | grep -qxF "$f" || MISS="$MISS $f"
  done
  if [ -n "$MISS" ]; then no "not changed:$MISS"; else ok "all 10 files changed"; fi
fi

# ============================================================================
#  AC1  - the two telemetry counts test-pipeline-telemetry.sh:91/:93 pin
# ============================================================================
hdr "AC1 pinned telemetry counts (non-regression)"

cell AC1.a "grep -c 'write the shard beside your own worktree at <WORKTREE_PATH>/.pipeline/<issue>/' is still 0"
n=$(count_in "$PIPEMD" 'write the shard beside your own worktree at <WORKTREE_PATH>/.pipeline/<issue>/')
[ "$n" = 0 ] && ok "0" || no "expected 0, got $n"

cell AC1.b "grep -c 'fallback-shards/peer-review.<role>.json' is still exactly 1"
n=$(count_in "$PIPEMD" 'fallback-shards/peer-review.<role>.json')
[ "$n" = 1 ] && ok "1" || no "expected 1, got $n"

# ============================================================================
#  AC2  - the ten-copy frozen span, and its terminator anchor
# ============================================================================
hdr "AC2 frozen span digest and terminator anchor"

cell AC2.a "the frozen span hashes to $FROZEN_SHA in ALL TEN files, one group"
DIGSET=$(for f in "${AGENTS[@]}" "$PIPEMD"; do frozen_digest "$f"; done | sort -u)
NG=$(printf '%s\n' "$DIGSET" | grep -c .)
if [ "$NG" != 1 ]; then
  no "the ten files produce $NG distinct digests, not 1:" $(printf '%s ' $DIGSET) \
     "A handful of groups means the extraction bounds were wrong, not necessarily that the block drifted."
elif [ "$DIGSET" != "$FROZEN_SHA" ]; then
  no "ten AGREEING digests, but $DIGSET != $FROZEN_SHA - suspect the extraction bounds first."
else ok "10/10 = $FROZEN_SHA"; fi

cell AC2.a2 "the extracted span is still $FROZEN_LINES lines in all ten (extraction-bounds premise)"
BADL=""
for f in "${AGENTS[@]}" "$PIPEMD"; do
  l=$(frozen_linecount "$f"); [ "$l" = "$FROZEN_LINES" ] || BADL="$BADL $f=$l"
done
[ -z "$BADL" ] && ok "10/10 at $FROZEN_LINES lines" || no "wrong span length:$BADL"

cell AC2.b "'replicated verbatim' still occurs EXACTLY ONCE in each of the ten files"
BADR=""
for f in "${AGENTS[@]}" "$PIPEMD"; do
  c=$(count_in "$f" 'replicated verbatim'); [ "$c" = 1 ] || BADR="$BADR $f=$c"
done
if [ -z "$BADR" ]; then ok "10/10 at exactly 1"
else no "the AC2 extraction terminator anchor is no longer unique:$BADR" \
        "A second occurrence is a new false-drift surface and fails AC2 EVEN IF every digest still agrees."; fi

cell AC2.c "the new block closes with '$LIT_TERM' in all $NAGENTS agent contracts (pre-change 0)"
pre=$(pre_change_files_with "$LIT_TERM"); now=$(files_with "$LIT_TERM")
if [ "$pre" != 0 ]; then no "PRE-CHANGE count is $pre, not 0 - this literal cannot attribute the red to the new block."
elif [ "$now" = "$NAGENTS" ]; then ok "$now/$NAGENTS (pre-change 0)"
else no "expected $NAGENTS files carrying '$LIT_TERM', got $now (pre-change 0, so the shortfall is the missing block)"; fi

# ============================================================================
#  Literal hygiene - the trap that already caught one criterion
# ============================================================================
hdr "chosen-literal admissibility (AC5/AC6/AC7/AC13 share this gate)"

cell AClit "every chosen literal has a VERIFIED pre-change count of 0 over the nine contracts"
BADLIT=""
for pair in "medium:$LIT_MEDIUM" "trigger:$LIT_TRIGGER" "hygiene:$LIT_HYGIENE" "disclosure:$LIT_DISCLOSE"; do
  role=${pair%%:*}; lit=${pair#*:}
  p=$(pre_change_files_with "$lit")
  printf '        pre-change %-11s [%s] = %s/%s\n' "$role" "$lit" "$p" "$NAGENTS"
  [ "$p" = 0 ] || BADLIT="$BADLIT $role=[$lit]:$p"
done
if [ -n "$BADLIT" ]; then
  no "DISQUALIFIED literal(s) chosen:$BADLIT" \
     "A literal with a non-zero pre-change count reads GREEN with the rule delivered to zero files."
else ok "all four at 0/$NAGENTS pre-change"; fi

cell AClit.c "CONTROL: the disqualification gate fires on the known-bad literals"
KNOWN_BAD=0; KB_DETAIL=""
for lit in 'worktree' 'git commit -a' 'worktree isolation' 'porcelain'; do
  p=$(pre_change_files_with "$lit"); KB_DETAIL="$KB_DETAIL [$lit]=$p"
  [ "$p" != 0 ] && KNOWN_BAD=$((KNOWN_BAD+1))
done
if [ "$KNOWN_BAD" = 4 ]; then ok "4/4 known-disqualified literals report non-zero:$KB_DETAIL"
else no "only $KNOWN_BAD/4 known-bad literals report non-zero:$KB_DETAIL" \
        "The zero reported by AClit above is then a zero result about the probe, not about the literals."; fi

cell AClit.d "the four chosen literals are pairwise DISTINCT (AC6/AC7 require distinctness)"
DUP=$(printf '%s\n%s\n%s\n%s\n' "$LIT_MEDIUM" "$LIT_TRIGGER" "$LIT_HYGIENE" "$LIT_DISCLOSE" | sort | uniq -d)
[ -z "$DUP" ] && ok || no "repeated literal(s): $DUP"

# ============================================================================
#  AC5 / AC6 / AC7 / AC13 - the three-way equalities
# ============================================================================
hdr "AC5/AC6/AC7/AC13 three-way equalities"

equality_cell() {  # ac, label, literal, need_pipeline_md(1/0)
  local ac="$1" label="$2" lit="$3" needp="$4"
  cell "$ac" "$label: ls | wc -l == grep -rl | wc -l == $NAGENTS$([ "$needp" = 1 ] && echo ' , and pipeline.md >= 1')"
  local n p
  n=$(files_with "$lit"); p=$(count_in "$PIPEMD" "$lit")
  if [ "$n" = 0 ] && [ "$NAGENTS" = 0 ]; then
    vac "0 == 0 is the degenerate case the criterion names; it is not a pass."
  elif [ "$n" != "$NAGENTS" ]; then
    no "$NAGENTS == $n is FALSE for [$lit] (pipeline.md count $p)"
  elif [ "$needp" = 1 ] && [ "$p" -lt 1 ]; then
    no "$NAGENTS == $n holds over the contracts, but pipeline.md carries [$lit] $p times (need >= 1)"
  else
    ok "$NAGENTS == $n == $NAGENTS$([ "$needp" = 1 ] && echo " ; pipeline.md=$p")"
  fi
}
equality_cell AC5  "MEDIUM"     "$LIT_MEDIUM"   0
equality_cell AC6  "TRIGGER"    "$LIT_TRIGGER"  1
equality_cell AC7  "HYGIENE"    "$LIT_HYGIENE"  1
equality_cell AC13 "DISCLOSURE" "$LIT_DISCLOSE" 1

BADS=""
for f in "${AGENTS[@]}" "$PIPEMD"; do
  for want in 'git commit -a' 'git add -A' 'git add .'; do
    window_has "$f" "$LIT_HYGIENE" 400 "$want"
    case $? in 0) ;; 2) BADS="$BADS $(basename "$f"):no-literal" ;; *) BADS="$BADS $(basename "$f"):far[$want]" ;; esac
  done
done
cell AC7.s "the hygiene literal sits WITH all three blanket forms (AC7's same-sentence clause)"
if [ -z "$BADS" ]; then ok "all $NAGENTS contracts + pipeline.md carry the literal within 400 chars of all three forbids"
else no "incomplete or dispersed hygiene clause:$BADS"; fi

cell AC7.sc "CONTROL: the proximity check REFUSES a dispersed clause it should refuse"
{ printf '%s' "$LIT_HYGIENE"; head -c 3000 /dev/zero | tr '\0' 'x'; printf ' git commit -a git add -A git add .\n'; } > "$SCRATCH/disp.txt"
{ printf '%s' "$LIT_HYGIENE"; printf ' never git commit -a, git add -A or git add .\n'; } > "$SCRATCH/tight.txt"
window_has "$SCRATCH/disp.txt"  "$LIT_HYGIENE" 400 'git add -A'; DISP=$?
window_has "$SCRATCH/tight.txt" "$LIT_HYGIENE" 400 'git add -A'; TIGHT=$?
if [ "$DISP" = 1 ] && [ "$TIGHT" = 0 ]; then
  ok "dispersed=REFUSED, tight=ACCEPTED - the check DISCRIMINATES rather than merely firing"
else no "the proximity check does not discriminate: dispersed exit=$DISP (want 1), tight exit=$TIGHT (want 0)"; fi

cell AC6.s "the trigger literal sits WITH the panel clause and the read-only-reviewer clause"
BADT=""
for f in "${AGENTS[@]}" "$PIPEMD"; do
  for want in 'not by the panel as a whole' 'only reads stays'; do
    window_has "$f" "$LIT_TRIGGER" 400 "$want"
    case $? in 0) ;; 2) BADT="$BADT $(basename "$f"):no-literal" ;; *) BADT="$BADT $(basename "$f"):far[$want]" ;; esac
  done
done
[ -z "$BADT" ] && ok "all $NAGENTS contracts + pipeline.md" || no "trigger clause incomplete:$BADT"

# ============================================================================
#  Block identity - nine byte-identical copies, matching the LOCKED design
# ============================================================================
hdr "block identity against the locked design.json"

node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  fs.writeFileSync(process.argv[2], j.chosen_approach.canonical_agent_contract_block.replace(/\s*$/,"")+"\n");
  fs.writeFileSync(process.argv[3], j.chosen_approach.preamble_paragraph_1_isolation.trim()+"\n");
  fs.writeFileSync(process.argv[4], j.chosen_approach.preamble_paragraph_2_boundary_limitation.trim()+"\n");
' "$DESIGN" "$SCRATCH/block.txt" "$SCRATCH/p1.txt" "$SCRATCH/p2.txt" 2>/dev/null || true

BLOCK_HEAD='## Phase 4 tracked-write isolation'

cell ACblk.1 "the appended block is BYTE-IDENTICAL across all $NAGENTS contracts"
DIGS=""
for f in "${AGENTS[@]}"; do
  d=$(sed -n "/^$BLOCK_HEAD\$/,\$p" "$f" | sed 's/[[:space:]]*$//' | shasum | cut -d' ' -f1)
  present=$(grep -cxF "$BLOCK_HEAD" "$f")
  [ "$present" = 1 ] || d="ABSENT($present)"
  DIGS="$DIGS $d"
done
UNIQ=$(printf '%s\n' $DIGS | sort -u); NU=$(printf '%s\n' "$UNIQ" | grep -c .)
if printf '%s' "$UNIQ" | grep -q ABSENT; then
  no "the '$BLOCK_HEAD' heading is not present exactly once in every contract:" $(printf '%s ' $DIGS)
elif [ "$NU" = 1 ]; then ok "$NAGENTS/$NAGENTS identical ($UNIQ)"
else no "$NU distinct block digests across the nine - the disagreement IS the defect:" $(printf '%s ' $DIGS); fi

cell ACblk.2 "the appended block matches the LOCKED design.json canonical block byte-for-byte"
if [ ! -s "$SCRATCH/block.txt" ]; then sk "could not extract the canonical block from design.json (node missing?)"
else
  WANT=$(sed 's/[[:space:]]*$//' "$SCRATCH/block.txt" | shasum | cut -d' ' -f1)
  GOT=$(sed -n "/^$BLOCK_HEAD\$/,\$p" plugins/pipeline/agents/qa.md | sed 's/[[:space:]]*$//' | shasum | cut -d' ' -f1)
  if ! grep -qxF "$BLOCK_HEAD" plugins/pipeline/agents/qa.md; then
    no "qa.md carries no '$BLOCK_HEAD' section at all (design.json wants $WANT)"
  elif [ "$WANT" = "$GOT" ]; then ok "$GOT"
  else
    no "qa.md block digest $GOT != design.json $WANT" \
       "diff (design.json expected vs shipped):" \
       "$(diff <(sed 's/[[:space:]]*$//' "$SCRATCH/block.txt") <(sed -n "/^$BLOCK_HEAD\$/,\$p" plugins/pipeline/agents/qa.md | sed 's/[[:space:]]*$//') | head -20)"
  fi
fi

cell ACblk.3 "the block is at END OF FILE in every contract (nothing follows it)"
BADE=""
for f in "${AGENTS[@]}"; do
  ln=$(grep -nxF "$BLOCK_HEAD" "$f" | head -1 | cut -d: -f1)
  if [ -z "$ln" ]; then BADE="$BADE $(basename "$f"):absent"; continue; fi
  after=$(awk -v s="$ln" 'NR>s && /^## /' "$f" | head -1)
  [ -n "$after" ] && BADE="$BADE $(basename "$f"):followed-by[$after]"
done
[ -z "$BADE" ] && ok || no "the block is not the last section:$BADE"

cell ACblk.4 'the preamble text opens no triple-backtick fence and starts no line with "- " or "#"'
if [ -s "$SCRATCH/p1.txt" ] && [ -s "$SCRATCH/p2.txt" ]; then
  HZ=""
  grep -q '```' "$SCRATCH/p1.txt" "$SCRATCH/p2.txt" && HZ="$HZ triple-backtick"
  grep -qE '^- ' "$SCRATCH/p1.txt" "$SCRATCH/p2.txt" && HZ="$HZ leading-dash"
  grep -qE '^#'  "$SCRATCH/p1.txt" "$SCRATCH/p2.txt" && HZ="$HZ leading-hash"
  [ -z "$HZ" ] && ok "preamble text carries none of the three fence/list/heading hazards" \
    || no "preamble text would break the fence or the list:$HZ"
else sk "could not extract the preamble paragraphs from design.json"; fi

# ============================================================================
#  AC4 / AC8 / AC15 / AC16 prose obligations, as literal probes
# ============================================================================
hdr "AC4/AC8/AC14/AC15 prose obligations"

prose_cell() {  # ac, label, file-scope(agents|preamble|both), literal
  local ac="$1" label="$2" scope="$3" lit="$4"
  cell "$ac" "$label -- [$lit]"
  local n p
  n=$(files_with "$lit"); p=$(count_in "$PIPEMD" "$lit")
  case "$scope" in
    agents)   [ "$n" = "$NAGENTS" ] && ok "$n/$NAGENTS" || no "$n/$NAGENTS contracts carry it" ;;
    preamble) [ "$p" -ge 1 ] && ok "pipeline.md=$p" || no "pipeline.md carries it $p times (need >= 1)" ;;
    both)     { [ "$n" = "$NAGENTS" ] && [ "$p" -ge 1 ]; } && ok "$n/$NAGENTS + pipeline.md=$p" \
                || no "contracts $n/$NAGENTS, pipeline.md $p (need $NAGENTS and >= 1)" ;;
  esac
}
prose_cell AC4.h  "two harms named as SEPARATE harms"          both 'two separate harms'
prose_cell AC4.l  "boundary check stated as a LIMITATION"      preamble 'limitation of the boundary check'
prose_cell AC8.c  "clause 2: ls-files exits 0, non-zero count" both 'ls-files'
prose_cell AC8.e  "clause 1 meaningful only when rev-parse EXITS 0" both 'EXITS 0'
prose_cell AC8.n1 "the 83/2 worked number"                     agents '83/2'
prose_cell AC8.n2 "the 85/0 worked number"                     agents '85/0'
prose_cell AC9.d1 "--git-dir disqualified by name"             both '--git-dir'
prose_cell AC9.d2 "--git-common-dir disqualified by name"      both '--git-common-dir'
prose_cell AC15.a "registry NAME is the identity to record"    agents 'registry NAME'
prose_cell AC15.b "no actor sweeps today"                      agents 'no actor sweeps'
prose_cell AC15.c "prune reclaims only once the directory is gone" agents 'only once its directory is already gone'

cell AC14.p "R6's effect: presence asserted FIRST and unconditionally"
n=$(files_with "$LIT_HYGIENE"); p=$(count_in "$PIPEMD" "$LIT_HYGIENE")
tot=$((n+p))
[ "$tot" -ge 1 ] && ok "hygiene literal appears $tot times across the changed files (>=1, unconditional)" \
  || no "hygiene literal count is 0 across the changed files; stating nothing is a FAILURE, not a vacuous pass"

cell AC14.o "R6's effect is never OVERSTATED: 0 occurrences of /prevent/i in the ADDED lines"
if [ -z "$BASE" ]; then sk "no merge-base"
else
  AL=$(added_lines "${AGENTS[@]}" "$PIPEMD")
  NAL=$(printf '%s' "$AL" | grep -c . || true)
  if [ "$NAL" = 0 ]; then
    vac "there are no added lines to inspect; a 0 here is a zero result about the diff, not about the prose."
  else
    HITS=$(printf '%s\n' "$AL" | grep -ci 'prevent' || true)
    CTLH=$(printf '+it prevents the harm\n' | grep -ci 'prevent')
    if [ "$CTLH" != 1 ]; then no "HARNESS: the /prevent/i probe does not match a planted 'prevents'."
    elif [ "$HITS" = 0 ]; then ok "0 in $NAL added lines (probe control fired on a planted line)"
    else no "$HITS added line(s) contain 'prevent':" "$(printf '%s\n' "$AL" | grep -i 'prevent' | head -5)"; fi
  fi
fi

cell AC14.s "every sentence stating R6's effect carries BOTH the ship-event clause and the no-enforcement clause"
BADN=""
for f in "${AGENTS[@]}" "$PIPEMD"; do
  # sentences mentioning the effect
  hits=$(tr '\n' ' ' < "$f" | grep -oE '[^.]*stops nothing[^.]*\.' || true)
  [ -z "$hits" ] && continue
  printf '%s' "$hits" | grep -qF 'only one of these rules sited at the actual ship event' || \
    printf '%s' "$hits" | grep -qF 'only one of the three legs sited at the ship event' || \
    printf '%s' "$hits" | grep -qF 'only one of these rules sited at the ship event' || \
      BADN="$BADN $(basename "$f"):no-ship-event-clause"
  printf '%s' "$hits" | grep -qF 'nothing mechanically enforces it' || BADN="$BADN $(basename "$f"):no-enforcement-clause"
done
FOUND=0
for f in "${AGENTS[@]}" "$PIPEMD"; do FOUND=$(( FOUND + $(count_in "$f" 'stops nothing') )); done
if [ "$FOUND" -lt 1 ]; then
  vac "no sentence in any changed file states R6's effect at all; AC14 makes stating nothing a FAILURE."
elif [ -n "$BADN" ]; then no "incomplete effect sentence(s):$BADN"
else ok "all effect sentences carry both clauses"; fi

# ============================================================================
#  AC12 - fence-aware section resolver, demonstrated ON THE POST-CHANGE FILE
# ============================================================================
hdr "AC12 fence-aware resolver and frozen-span exclusion"

resolve_fence_aware() {  # file, probe-literal -> nearest preceding ^## outside a fence
  awk -v probe="$2" '
    /^```/ { infence = !infence; next }
    !infence && /^## / { last = $0 }
    index($0, probe) > 0 { print last; found=1; exit }
    END { if (!found) print "PROBE-NOT-FOUND" }' "$1"
}
resolve_fence_blind() {
  awk -v probe="$2" '
    /^## / { last = $0 }
    index($0, probe) > 0 { print last; found=1; exit }
    END { if (!found) print "PROBE-NOT-FOUND" }' "$1"
}

cell AC12.u "both probes are UNIQUE in pipeline.md (1 occurrence each)"
h=$(count_in "$PIPEMD" '**Halves.**'); w=$(count_in "$PIPEMD" 'WRITE YOUR SHARD FIRST')
bad=$(count_in "$PIPEMD" 'Agent({subagent_type: "ba"')
if [ "$h" = 1 ] && [ "$w" = 1 ]; then
  ok "Halves=1 WRITE-YOUR-SHARD-FIRST=1 (and the disallowed anchor Agent({subagent_type: \"ba\" = $bad, correctly not used)"
else no "Halves=$h WRITE YOUR SHARD FIRST=$w - a non-unique probe is not a probe"; fi

cell AC12.r "the fence-aware and fence-blind walks DISAGREE, and the difference is printed"
FA_H=$(resolve_fence_aware "$PIPEMD" '**Halves.**')
FA_W=$(resolve_fence_aware "$PIPEMD" 'WRITE YOUR SHARD FIRST')
FB_H=$(resolve_fence_blind "$PIPEMD" '**Halves.**')
FB_W=$(resolve_fence_blind "$PIPEMD" 'WRITE YOUR SHARD FIRST')
printf '        fence-aware  Halves          -> %s\n' "$FA_H"
printf '        fence-aware  WRITE-SHARD     -> %s\n' "$FA_W"
printf '        fence-blind  Halves          -> %s\n' "$FB_H"
printf '        fence-blind  WRITE-SHARD     -> %s\n' "$FB_W"
WANT_AWARE='## Phase 4: Peer Review Panel (parallel)'
WANT_BLIND='## The property, not the fix'
if [ "$FA_H" = "$WANT_AWARE" ] && [ "$FA_W" = "$WANT_AWARE" ] \
   && [ "${FB_H#"$WANT_BLIND"}" != "$FB_H" ] && [ "${FB_W#"$WANT_BLIND"}" != "$FB_W" ]; then
  ok "both probes resolve to the Phase 4 heading fence-aware, and to the phantom heading fence-blind"
else
  no "the two walks do not separate as AC12 requires" \
     "expected fence-aware='$WANT_AWARE' for both, fence-blind to start '$WANT_BLIND' for both"
fi

cell AC12.x "NO changed line in pipeline.md lies inside the frozen span (EVERY + side line, not hunk starts)"
if [ -z "$BASE" ]; then sk "no merge-base"
else
  START=$(grep -nF '## The property, not the fix' "$PIPEMD" | head -1 | cut -d: -f1)
  END=$(grep -nF 'This block is replicated verbatim in ten files.' "$PIPEMD" | head -1 | cut -d: -f1)
  CH=$(changed_lines "$PIPEMD")
  NCH=$(printf '%s' "$CH" | grep -c . || true)
  if [ "$NCH" = 0 ]; then
    vac "pipeline.md has no changed hunk; the frozen-span exclusion has nothing to exclude."
  else
    IN=""
    for l in $CH; do [ "$l" -ge "$START" ] && [ "$l" -le "$END" ] && IN="$IN $l"; done
    # non-zero control: the Halves probe line MUST be reported as inside the span
    HL=$(grep -nF '**Halves.**' "$PIPEMD" | head -1 | cut -d: -f1)
    CTLIN=$([ "$HL" -ge "$START" ] && [ "$HL" -le "$END" ] && echo 1 || echo 0)
    if [ "$CTLIN" != 1 ]; then no "HARNESS: the span check does not even place the **Halves.** probe (line $HL) inside span $START-$END."
    elif [ -n "$IN" ]; then no "changed line(s) inside the frozen span $START-$END:$IN"
    else ok "0 of $(printf '%s' "$CH" | grep -c .) changed LINES in span $START-$END (control: **Halves.** at line $HL IS reported inside)"; fi
  fi
fi

cell AC12.s "every changed line in pipeline.md lies in the Phase 4 preamble span (EVERY + side line, not hunk starts)"
if [ -z "$BASE" ]; then sk "no merge-base"
else
  PSTART=$(grep -nF '## Phase 4: Peer Review Panel (parallel)' "$PIPEMD" | head -1 | cut -d: -f1)
  PEND=$(grep -nF '### Dispatch model routing' "$PIPEMD" | head -1 | cut -d: -f1)
  CH=$(changed_lines "$PIPEMD")
  NCH=$(printf '%s' "$CH" | grep -c . || true)
  if [ "$NCH" = 0 ]; then vac "pipeline.md has no changed hunk."
  else
    OUT=""
    for l in $CH; do { [ "$l" -gt "$PSTART" ] && [ "$l" -lt "$PEND" ]; } || OUT="$OUT $l"; done
    NL=$(printf '%s' "$CH" | grep -c .)
    [ -z "$OUT" ] && ok "all $NL changed LINES inside preamble span $PSTART-$PEND (line-level, not hunk-start-level)" \
      || no "changed line(s) outside the preamble span $PSTART-$PEND:$OUT"
  fi
fi

# ============================================================================
#  AC9 - the ten-cell topology matrix, RUN, in both topologies, 3 spellings
# ============================================================================
hdr "AC9 ten-cell isolation-predicate matrix (main checkout AND linked worktree)"

RW_BEFORE=$(git worktree list | wc -l | tr -d ' ')
RS_BEFORE=$(git status --porcelain | wc -l | tr -d ' ')

# The predicate under test, parameterised by spelling.
judge() {  # dispatch, candidate, spelling -> ADMIT | REFUSE(reason)
  local disp="$1" cand="$2" sp="$3" dg cg n rc
  dg=$(git -C "$disp" rev-parse "$sp" 2>/dev/null); [ -z "$dg" ] && { echo "REFUSE(dispatch-rev-parse-failed)"; return; }
  cg=$(git -C "$cand" rev-parse "$sp" 2>/dev/null); rc=$?
  [ $rc -ne 0 ] || [ -z "$cg" ] && { echo "REFUSE(rev-parse exit != 0)"; return; }
  [ "$cg" = "$dg" ] && { echo "REFUSE(same gitdir)"; return; }
  n=$(git -C "$cand" ls-files 2>/dev/null | wc -l | tr -d ' '); rc=$?
  [ $rc -ne 0 ] && { echo "REFUSE(ls-files exit != 0)"; return; }
  [ "${n:-0}" -eq 0 ] && { echo "REFUSE(ls-files count 0)"; return; }
  echo "ADMIT(n=$n)"
}
verdict() { case "$1" in ADMIT*) echo ADMIT ;; *) echo REFUSE ;; esac; }

build_topology() {  # $1 = main|linked ; echoes the dispatch path
  local kind="$1" root="$SCRATCH/ac9/$kind"
  mkdir -p "$root"
  if [ "$kind" = main ]; then
    git clone -q --no-hardlinks "$REPO" "$root/dispatch" >/dev/null 2>&1 || return 1
  else
    git clone -q --no-hardlinks "$REPO" "$root/origin" >/dev/null 2>&1 || return 1
    git -C "$root/origin" worktree add -q --detach "$root/dispatch" >/dev/null 2>&1 || return 1
  fi
  echo "$root/dispatch"
}

run_topology() {  # $1 = main|linked ; $2 = expected 5-cell verdict row under --absolute-git-dir
  local kind="$1" expect="$2" root="$SCRATCH/ac9/$1"
  local D; D=$(build_topology "$kind") || { cell "AC9.$kind" "build the $kind topology"; sk "could not build the $kind dispatch tree"; return; }

  # PREMISE: assert the topology BEFORE judging any cell.
  cell "AC9.$kind.t" "topology asserted before any cell is judged: <dispatch>/.git is a $([ "$kind" = main ] && echo DIRECTORY || echo FILE)"
  if [ "$kind" = main ]; then
    [ -d "$D/.git" ] && [ ! -f "$D/.git" ] && ok "directory" || { no "expected a DIRECTORY, got $(ls -ld "$D/.git" 2>&1 | head -1)"; return; }
  else
    [ -f "$D/.git" ] && ok "file: $(head -c 120 "$D/.git")" || { no "expected a FILE, got $(ls -ld "$D/.git" 2>&1 | head -1)"; return; }
  fi

  # Build the five cells.
  git -C "$D" worktree add -q --detach "$root/cell1" >/dev/null 2>&1
  git clone -q --no-hardlinks "$D" "$root/cell2" >/dev/null 2>&1
  local cell3="$D/plugins/pipeline/scripts"
  mkdir -p "$root/cell4" "$root/cell5" "$root/ctl_untracked"
  ( cd "$D" && tar cf - . 2>/dev/null ) | ( cd "$root/cell4" && tar xf - 2>/dev/null )
  ( cd "$D" && tar cf - --exclude .git . 2>/dev/null ) | ( cd "$root/cell5" && tar xf - 2>/dev/null )
  mkdir -p "$D/__untracked_ctl__" && : > "$D/__untracked_ctl__/x"

  # PREMISE: cell 3 must be TRACKED, and the untracked control must refuse for
  # the unrelated ls-files reason.
  cell "AC9.$kind.c3" "cell 3 is a TRACKED subdirectory (not untracked - that hides the bug)"
  local n3 nu
  n3=$(git -C "$cell3" ls-files | wc -l | tr -d ' ')
  nu=$(git -C "$D/__untracked_ctl__" ls-files 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n3:-0}" -gt 0 ] && [ "${nu:-0}" -eq 0 ]; then
    ok "cell3 ls-files=$n3 (tracked); named CONTROL untracked subdir ls-files=$nu, which refuses for the UNRELATED reason"
  else
    no "cell3 ls-files=$n3 (need >0), untracked control ls-files=$nu (need 0) - a run with an untracked cell 3 gets the right answer for the wrong reason"
  fi

  # PREMISE for cell 4's mechanism: the index INODE comparison.
  cell "AC9.$kind.i" "cell 4's mechanism PROVED by inode of <absolute-git-dir>/index, not asserted"
  local dgd cgd di ci
  dgd=$(git -C "$D" rev-parse --absolute-git-dir 2>/dev/null)
  cgd=$(git -C "$root/cell4" rev-parse --absolute-git-dir 2>/dev/null)
  di=$(stat -f %i "$dgd/index" 2>/dev/null || stat -c %i "$dgd/index" 2>/dev/null)
  ci=$(stat -f %i "$cgd/index" 2>/dev/null || stat -c %i "$cgd/index" 2>/dev/null)
  if [ -z "$di" ] || [ -z "$ci" ]; then no "could not stat the index inodes (dispatch=$dgd cell4=$cgd)"
  elif [ "$kind" = main ]; then
    [ "$di" != "$ci" ] && ok "DIFFERENT inodes $di vs $ci -> cell 4 is an independent repository, so REFUSING it would refuse correct work" \
      || no "expected DIFFERENT inodes in a main checkout, got $di == $ci"
  else
    [ "$di" = "$ci" ] && ok "IDENTICAL inode $di -> cell 4 shares the dispatch index, HEAD and branch, so ADMITTING it would admit the harm" \
      || no "expected IDENTICAL inodes in a linked worktree, got $di vs $ci"
  fi

  # The matrix, all three spellings.
  local sp row
  for sp in --absolute-git-dir --git-dir --git-common-dir; do
    row=""
    local raw1 raw2 raw3 raw4 raw5
    raw1=$(judge "$D" "$root/cell1" "$sp"); raw2=$(judge "$D" "$root/cell2" "$sp")
    raw3=$(judge "$D" "$cell3"      "$sp"); raw4=$(judge "$D" "$root/cell4" "$sp")
    raw5=$(judge "$D" "$root/cell5" "$sp")
    row="$(verdict "$raw1")/$(verdict "$raw2")/$(verdict "$raw3")/$(verdict "$raw4")/$(verdict "$raw5")"
    printf '        %-18s %-45s %s\n' "$kind $sp" "$row" ""
    printf '          1 worktree-add=%s\n          2 clone=%s\n          3 tracked-subdir=%s\n          4 tar+.git=%s\n          5 tar--exclude=%s\n' \
      "$raw1" "$raw2" "$raw3" "$raw4" "$raw5"
    if [ "$sp" = --absolute-git-dir ]; then
      cell "AC9.$kind" "--absolute-git-dir produces $expect in the $kind topology"
      [ "$row" = "$expect" ] && ok "$row" || no "expected $expect, measured $row"
    elif [ "$sp" = --git-dir ] && [ "$kind" = main ]; then
      cell "AC9.bite" "THE BITE: --git-dir is WRONG in a main checkout (cells 2 and 3)"
      [ "$row" = "ADMIT/REFUSE/ADMIT/ADMIT/REFUSE" ] || [ "$(verdict "$raw2")" = REFUSE -a "$(verdict "$raw3")" = ADMIT ] \
        && ok "cell2=$raw2 (a real clone falsely REFUSED), cell3=$raw3 (a tracked subdir of the dispatch tree falsely ADMITTED, where git commit -a commits the DISPATCH tree)" \
        || no "the bite did not reproduce: row=$row. If --git-dir looks correct here the run is not in a main checkout, and the spelling decision has no evidence."
    elif [ "$sp" = --git-dir ] && [ "$kind" = linked ]; then
      cell "AC9.blind" "ASSERTED, not incidental: --git-dir is INDISTINGUISHABLE from correct in the linked topology"
      [ "$row" = "ADMIT/ADMIT/REFUSE/REFUSE/REFUSE" ] \
        && ok "$row - all five correct, which is why two review rounds passed the wrong spelling; a criterion run only here cannot fail" \
        || no "expected ADMIT/ADMIT/REFUSE/REFUSE/REFUSE, measured $row"
    elif [ "$sp" = --git-common-dir ] && [ "$kind" = linked ]; then
      cell "AC9.gcd" "--git-common-dir refuses the very mechanism the rule recommends (cell 1)"
      [ "$(verdict "$raw1")" = REFUSE ] \
        && ok "cell1=$raw1 - it would refuse git worktree add --detach" \
        || no "expected cell 1 REFUSE under --git-common-dir in a linked worktree, got $raw1"
    fi
  done

  # Tear the cells down. Clean up any worktree we registered - the convention
  # under test has a measured compliance record of zero and we do not add to it.
  git -C "$D" worktree remove --force "$root/cell1" >/dev/null 2>&1
  git -C "$D" worktree prune >/dev/null 2>&1
  [ "$kind" = linked ] && { git -C "$root/origin" worktree remove --force "$D" >/dev/null 2>&1; git -C "$root/origin" worktree prune >/dev/null 2>&1; }
  return 0
}

if [ "$RUN_AC9" = 1 ]; then
  run_topology main   "ADMIT/ADMIT/REFUSE/ADMIT/REFUSE"
  run_topology linked "ADMIT/ADMIT/REFUSE/REFUSE/REFUSE"
else
  cell AC9.main   "--absolute-git-dir matrix, main topology";   sk "--fast was passed; the clone-heavy topology matrix did not run"
  cell AC9.linked "--absolute-git-dir matrix, linked topology"; sk "--fast was passed; the clone-heavy topology matrix did not run"
fi

cell AC9.iso "the ten-cell run registered NOTHING against the real repository"
RW_AFTER=$(git worktree list | wc -l | tr -d ' ')
RS_AFTER=$(git status --porcelain | wc -l | tr -d ' ')
if [ "$RW_BEFORE" = "$RW_AFTER" ] && [ "$RS_BEFORE" = "$RS_AFTER" ]; then
  ok "worktree count $RW_BEFORE -> $RW_AFTER, status lines $RS_BEFORE -> $RS_AFTER, both unchanged"
else
  no "the run leaked into the real repo: worktrees $RW_BEFORE -> $RW_AFTER, status $RS_BEFORE -> $RS_AFTER"
fi

# Classify every line that names the disqualified spelling. `--git-dir` as a
# FIXED string is unambiguous: neither `--absolute-git-dir` (which reads
# `e-git-dir`) nor `--git-common-dir` contains it.
# THE DEFECT THIS REPLACES (QA concern C4): the old filter was
#     grep -v 'never' | grep -v 'falsely'
# which decided MENTION versus PREDICATE USE by the presence of two ENGLISH
# WORDS - a guard on how a defect is SPELLED, not on what it does. A predicate
# instruction reading "compare `git rev-parse --git-dir` and never proceed
# unless they differ" passed it, measured. It was also A ZERO WITH NO NON-ZERO
# CONTROL: the reviewed tree contained no `rev-parse --git-dir` at all, so
# neither filter ever engaged and the cell reported 0 whether or not the probe
# worked.
# The classification is now STRUCTURAL: a line naming `--git-dir` while
# PRESCRIBING `absolute-git-dir` in the same breath is disqualifying the
# spelling; a line naming it WITHOUT prescribing the correct one is telling a
# reader to use it. That is a property of the sentence rather than of its
# adjectives, and it gives this cell a live NON-ZERO denominator (the ten real
# disqualification sentences) instead of a zero.
# RESIDUAL, stated rather than hidden: a predicate instruction that never spells
# the flag with its leading `--` is out of this probe's reach.
gitdir_predicate_lines() {  # files... -> lines USING the disqualified spelling
  grep -nF -- '--git-dir' "$@" 2>/dev/null | grep -v 'absolute-git-dir' || true
}

cell AC9.obs "diff-observable half: --absolute-git-dir 9/9 + >=1, and 0 uses of --git-dir AS THE PREDICATE"
n=$(files_with 'absolute-git-dir'); p=$(count_in "$PIPEMD" 'absolute-git-dir')
SUBJ=$(grep -nF -- '--git-dir' "${AGENTS[@]}" "$PIPEMD" 2>/dev/null || true)
NSUBJ=$(printf '%s' "$SUBJ" | grep -c . || true)
PRED=$(gitdir_predicate_lines "${AGENTS[@]}" "$PIPEMD")
NPRED=$(printf '%s' "$PRED" | grep -c . || true)
# DISCRIMINATION CONTROL, both directions, before the count is believed.
printf 'Compare `git rev-parse --git-dir` between the two trees and never proceed unless they differ.\n' > "$SCRATCH/gd_use.txt"
printf 'Use `--absolute-git-dir`, never `--git-dir` (it prints a relative path in a main checkout).\n' > "$SCRATCH/gd_mention.txt"
CU=$(gitdir_predicate_lines "$SCRATCH/gd_use.txt"     | grep -c . || true)
CM=$(gitdir_predicate_lines "$SCRATCH/gd_mention.txt" | grep -c . || true)
if [ "$CU" != 1 ] || [ "$CM" != 0 ]; then
  no "HARNESS: the classifier does not DISCRIMINATE (planted predicate USE flagged $CU, want 1; planted disqualifying MENTION flagged $CM, want 0)." \
     "The count below would be a zero result about the probe, not about the prose."
elif [ "$n" != "$NAGENTS" ] || [ "$p" -lt 1 ]; then
  no "absolute-git-dir: contracts $n/$NAGENTS, pipeline.md $p (need $NAGENTS and >= 1)"
elif [ "$NSUBJ" -lt 1 ]; then
  vac "no line in any changed file names --git-dir at all, so the classifier had nothing to classify and its 0 is a zero about the diff."
elif [ "$NPRED" != 0 ]; then
  no "$NPRED line(s) name --git-dir WITHOUT prescribing absolute-git-dir in the same breath, i.e. they read as predicate USES:" "$PRED"
else ok "contracts $n/$NAGENTS, pipeline.md $p; $NSUBJ line(s) name --git-dir and all $NSUBJ classify as DISQUALIFYING MENTIONS, 0 predicate uses" \
        "(control DISCRIMINATES: planted USE flagged 1/1, planted MENTION flagged 0/1)"; fi

# ============================================================================
#  AC16 - the location clause, one stat per case, over the WHOLE ancestor chain
# ============================================================================
hdr "AC16 whole-ancestor-chain location outcome"

# NOTE ON A HARNESS BUG THIS CELL ALREADY CAUGHT: `stat` prints the mode in
# OCTAL ("755", "700"). `$(( 755 % 8 ))` evaluates it as DECIMAL and returns 3,
# which happens to be non-zero, so the first draft of this probe returned the
# RIGHT verdict for /private/tmp/sketchB-43 for the WRONG reason, and the wrong
# verdict for every mode-700 case. Every mode is parsed with `8#` below.
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null; }
oct()     { local m="$1"; m=${m#"${m%%[!0]*}"}; echo $(( 8#${m:-0} )); }

# The CORRECT clause, as an OUTCOME over the whole path: another local user can
# reach the tree only when EVERY ancestor grants o+x AND the leaf grants o+r or
# o+x. ADMIT means unreachable. This is what makes the session scratchpad
# (leaf drwxr-xr-x, ancestor drwx------) correct to ADMIT: the ancestor blocks
# traversal, so the leaf's own permissive mode is unreachable.
loc_whole_chain() {
  local leaf; leaf=$(cd "$1" 2>/dev/null && pwd -P) || { echo "NOPATH"; return; }
  local m o p
  m=$(mode_of "$leaf"); [ -z "$m" ] && { echo NOSTAT; return; }
  o=$(oct "$m")
  if [ $(( o & 5 )) -eq 0 ]; then echo "ADMIT(leaf $leaf mode $m denies other read+traverse)"; return; fi
  p=$(dirname "$leaf")
  while :; do
    m=$(mode_of "$p"); [ -z "$m" ] && { echo NOSTAT; return; }
    o=$(oct "$m")
    if [ $(( o & 1 )) -eq 0 ]; then echo "ADMIT(ancestor $p mode $m denies other traverse)"; return; fi
    [ "$p" = / ] && break
    p=$(dirname "$p")
  done
  echo "REFUSE(every ancestor grants o+x and the leaf is other-accessible)"
}
# WRONG SPELLING 1, named by AC16: decided on the LEAF alone.
loc_leaf_only() {
  local m o; m=$(mode_of "$1"); [ -z "$m" ] && { echo NOSTAT; return; }
  o=$(oct "$m")
  [ $(( o & 5 )) -eq 0 ] && echo "ADMIT(leaf mode $m)" || echo "REFUSE(leaf mode $m)"
}
# WRONG SPELLING 2, named by AC16: a list of BLESSED DIRECTORIES rather than an
# outcome. It admits anything under a blessed root regardless of actual modes.
loc_allowlist() {
  local p; p=$(cd "$1" 2>/dev/null && pwd -P) || { echo NOPATH; return; }
  case "$p" in
    "${TMPDIR%/}"/*|"${TMPDIR%/}") echo "ADMIT(blessed: \$TMPDIR)" ;;
    "$HOME"/.cache/*)              echo "ADMIT(blessed: ~/.cache)" ;;
    /private/tmp/claude-*)         echo "ADMIT(blessed: scratchpad root)" ;;
    *)                             echo "REFUSE(not on the allowlist)" ;;
  esac
}

# Build the cases. NOTE: the scratchpad-shaped fixture must NOT be built under
# $TMPDIR - $TMPDIR is itself mode 700, so every path under it admits and the
# leaf-only discrimination below would pass without discriminating anything.
CASE_BARE="/private/tmp/verify19-bare-$$"
( umask 022; mkdir -p "$CASE_BARE" ) 2>/dev/null
CACHE_DEF="$HOME/.cache/verify19-def-$$"; ( umask 022; mkdir -p "$CACHE_DEF" ) 2>/dev/null
CACHE_700="$HOME/.cache/verify19-700-$$"; mkdir -p "$CACHE_700" 2>/dev/null && chmod 700 "$CACHE_700"
SPAD_ANC="/private/tmp/verify19-anc-$$"; SPAD_LEAF="$SPAD_ANC/tree"
mkdir -p "$SPAD_LEAF" 2>/dev/null && chmod 700 "$SPAD_ANC" && chmod 755 "$SPAD_LEAF"
LIVE_CTR=${V19_LIVE_CTR:-/private/tmp/sketchB-43}   # overridable so --controls can exercise the ABSENCE path

ac16() {  # label, description, path, expected
  cell "AC16.$1" "$2 -> expected $4"
  if [ ! -d "$3" ]; then sk "$3 does not exist on this machine; the case cannot be observed"
  else
    local got v; got=$(loc_whole_chain "$3"); case "$got" in ADMIT*) v=ADMIT;; *) v=REFUSE;; esac
    [ "$v" = "$4" ] && ok "$got" || no "expected $4, got $got"
  fi
}
# THE LIVE COUNTER-EXAMPLE, AND ITS EXPIRY (QA concern C6).
# $LIVE_CTR is a leftover registered worktree from a concurrent reviewer: a full
# tracked checkout (106 files) whose whole chain grants other-traversal
# (755 leaf / 777 /private/tmp / 755 / 755). It is a LIVE defect used as a
# control, and a control anchored on a live defect has a shelf life, because the
# CORRECT outcome for the defect is that somebody removes it.
# THE DEFECT THIS REPLACES: absence used to report SKIP, and a SKIP fails the
# battery - so the instrument was RED-WHEN-FIXED rather than merely
# stale-when-fixed. It made the exit code depend on a world-readable checkout
# continuing to exist, and asked a panel to preserve a leak so a fixture kept
# working. Absence is now a PASS that states the expiry IN PLACE, and the
# load-bearing discrimination sits on AC16.bare, which synthesises the same mode
# chain and returns the IDENTICAL refusal reason - verified, so nothing is lost.
# IF THIS PASSES WITH "GONE": the precedent was cleaned up and this cell has no
# live subject. That is success, not a hole. Re-anchor only on another
# world-traversable FULL CHECKOUT, never on a synthesised empty directory.
cell AC16.live "LIVE counter-example $LIVE_CTR: REFUSE while it exists, and its ABSENCE is the correct outcome, not a failure"
if [ -d "$LIVE_CTR" ]; then
  gotl=$(loc_whole_chain "$LIVE_CTR")
  case "$gotl" in
    REFUSE*) ok "still present, and REFUSED: $gotl" ;;
    *)       no "the live counter-example is present and was ADMITTED: $gotl" ;;
  esac
elif [ ! -d "$CASE_BARE" ]; then
  sk "$LIVE_CTR is gone AND the synthesised twin at $CASE_BARE could not be built, so the class is observed by nothing here."
else
  gotb=$(loc_whole_chain "$CASE_BARE")
  case "$gotb" in
    REFUSE*) ok "$LIVE_CTR is GONE - the correct outcome for a leftover world-readable checkout, and this cell's stated expiry." \
                "The class is still covered by AC16.bare, which synthesises the same chain and returns the identical reason: $gotb" ;;
    *)       no "the live counter-example is GONE and the synthesised twin does NOT refuse ($gotb): the world-traversable-checkout class is now covered by nothing." ;;
  esac
fi
ac16 bare  "a bare /private/tmp/<name> created under the default umask 022"    "$CASE_BARE" REFUSE
# $TMPDIR IS NOT A CONSTANT, AND THIS CELL USED TO PRETEND IT WAS (QA concern
# C1's instrument half). It asserted an unconditional ADMIT, which passed only
# because $TMPDIR is 0700 on this macOS box. Re-run with TMPDIR=/tmp - the shape
# wherever TMPDIR is unset, since /private/tmp is 1777 - and the cell went RED,
# reporting a broken harness when the truth was a different environment. A
# threshold on a rendered measurement measures the runner.
# The expectation is now DERIVED from the mode chain by a SECOND, deliberately
# separate implementation, and the environment is fingerprinted every run and
# ASSERTED rather than printed. The load-bearing oracle for the clause stays on
# AC16.w1/w2/w3, whose fixtures are pinned BY CONSTRUCTION (umask 022 versus
# chmod 700), because two implementations agreeing is weaker than a constructed
# fixture and must not be mistaken for it.
# RESIDUAL, stated rather than papered over: this cell cannot judge whether the
# shipped PROSE names $TMPDIR as an unconditionally passing example, because any
# such check pins a wording that is Dev's to choose. That half of C1 is a
# criterion on the text, not a cell here.
expect_from_modes() {  # second implementation, independent of loc_whole_chain
  local leaf; leaf=$(cd "$1" 2>/dev/null && pwd -P) || { echo "NOPATH"; return; }
  local m o q
  m=$(mode_of "$leaf"); o=$(oct "$m")
  [ $(( o & 5 )) -eq 0 ] && { echo "ADMIT leaf=$leaf($m)"; return; }
  q=$(dirname "$leaf")
  while :; do
    m=$(mode_of "$q"); o=$(oct "$m")
    [ $(( o & 1 )) -eq 0 ] && { echo "ADMIT ancestor=$q($m)"; return; }
    [ "$q" = / ] && break
    q=$(dirname "$q")
  done
  echo "REFUSE chain-fully-traversable"
}
cell AC16.tmpd "\$TMPDIR: the clause agrees with an INDEPENDENT read of the mode chain (expectation DERIVED, not pinned to this machine)"
TD="${TMPDIR:-/tmp}"
if [ ! -d "$TD" ]; then sk "\$TMPDIR resolves to $TD, which does not exist"
else
  TDP=$(cd "$TD" && pwd -P)
  FP="$TDP"; q="$TDP"
  while :; do FP="$FP [$(mode_of "$q")]"; [ "$q" = / ] && break; q=$(dirname "$q"); FP="$FP < $q"; done
  EXPR_=$(expect_from_modes "$TD"); EXPV=${EXPR_%% *}
  GOTR=$(loc_whole_chain "$TD"); case "$GOTR" in ADMIT*) GOTV=ADMIT;; *) GOTV=REFUSE;; esac
  # ASSERT the fingerprint rather than only printing it: a probe that only ever
  # prints is a zero result about the harness.
  if [ -z "$(mode_of "$TDP")" ]; then
    no "HARNESS: could not read a mode for $TDP, so the derived expectation below is not grounded."
  elif [ "$EXPV" = "$GOTV" ]; then
    ok "environment fingerprint: $FP" \
       "derived expectation $EXPV ($EXPR_) == clause verdict $GOTV -> $GOTR" \
       "$([ "$EXPV" = REFUSE ] && echo 'NOTE: in THIS environment \$TMPDIR is NOT a safe location. Any prose calling it one is false here.' || echo 'In this environment \$TMPDIR is safe; that is a fact about this host, not about the rule.')"
  else
    no "the clause and an independent read of the mode chain DISAGREE about $TDP" \
       "independent: $EXPR_ ; clause: $GOTR ; fingerprint: $FP"
  fi
fi
ac16 spad  "scratchpad shape: leaf drwxr-xr-x under a drwx------ ancestor"     "$SPAD_LEAF" ADMIT
ac16 cach  "~/.cache/<name> at the default umask (world-readable)"             "$CACHE_DEF" REFUSE
ac16 c700  "the same ~/.cache tree created 0700"                               "$CACHE_700" ADMIT

cell AC16.w1 "WRONG SPELLING 1 (leaf alone) gets the scratchpad shape wrong IN THE REFUSING DIRECTION"
if [ ! -d "$SPAD_LEAF" ]; then sk "could not build the scratchpad-shaped fixture at $SPAD_LEAF"
else
  right=$(loc_whole_chain "$SPAD_LEAF"); wrong=$(loc_leaf_only "$SPAD_LEAF")
  case "$right$wrong" in
    ADMIT*REFUSE*) ok "whole-chain=$right ; leaf-only=$wrong - the spellings DISCRIMINATE, so this is not two negatives being compared" ;;
    *) no "no discrimination: whole-chain=$right leaf-only=$wrong" ;;
  esac
fi

cell AC16.w2 "WRONG SPELLING 2 (a blessed-directory allowlist) gets ~/.cache wrong IN THE ADMITTING DIRECTION"
if [ ! -d "$CACHE_DEF" ]; then sk "could not create $CACHE_DEF"
else
  right=$(loc_whole_chain "$CACHE_DEF"); wrong=$(loc_allowlist "$CACHE_DEF")
  case "$right$wrong" in
    REFUSE*ADMIT*) ok "whole-chain=$right ; allowlist=$wrong - an allowlist ships a world-readable tree, which is why AC16 forbids one" ;;
    *) no "no discrimination: whole-chain=$right allowlist=$wrong" ;;
  esac
fi

cell AC16.w3 "CONTROL: the two wrong spellings AGREE with the correct one where they should"
a=$(loc_whole_chain "$CASE_BARE"); b=$(loc_leaf_only "$CASE_BARE"); c=$(loc_allowlist "$CASE_BARE")
case "$a$b$c" in
  REFUSE*REFUSE*REFUSE*) ok "on the bare /private/tmp case all three REFUSE - the wrong spellings are wrong SOMEWHERE, not everywhere, so w1/w2 are real discriminations and not a probe that always disagrees" ;;
  *) no "expected all three to refuse the bare world-readable case: whole=$a leaf=$b allowlist=$c" ;;
esac

cell AC16.p "the shipped clause is an OUTCOME over the chain, not a directory allowlist"
n=$(files_with 'every ancestor directory'); p=$(count_in "$PIPEMD" 'ancestor chain')
{ [ "$n" = "$NAGENTS" ] && [ "$p" -ge 1 ]; } && ok "contracts $n/$NAGENTS, pipeline.md $p" \
  || no "contracts $n/$NAGENTS carry the whole-chain phrasing, pipeline.md $p (need $NAGENTS and >= 1)"

chmod 755 "$SPAD_ANC" 2>/dev/null
rm -rf "$CASE_BARE" "$CACHE_DEF" "$CACHE_700" "$SPAD_ANC" 2>/dev/null

# ============================================================================
#  AC3 / AC10 - NON-REGRESSION. These are not coverage. They are the floor.
# ============================================================================
hdr "AC3/AC10 non-regression (NOT coverage - these pass today and must keep passing)"

BASELINE="$ART/baseline-run-sh.txt"

cell AC10.a "config-doctor.mjs --self-test reports the same passed/failed counts"
if [ "$RUN_SUITES" = 0 ]; then sk "--no-suites was passed; a skipped non-regression check is not a pass"
else
  SD=$(CLAUDE_PLUGIN_ROOT="$REPO/plugins/pipeline" node plugins/pipeline/scripts/config-doctor.mjs --self-test 2>&1 | grep -E '^self-test:' | tail -1)
  [ "$SD" = "self-test: 16 passed, 0 failed" ] && ok "$SD" || no "expected 'self-test: 16 passed, 0 failed', got '$SD'"
fi

cell AC10.b "the doctor's output against THIS repository still contains no literal WARNING"
if [ "$RUN_SUITES" = 0 ]; then sk "--no-suites was passed"
else
  DO=$(CLAUDE_PLUGIN_ROOT="$REPO/plugins/pipeline" node plugins/pipeline/scripts/config-doctor.mjs 2>&1)
  W=$(printf '%s' "$DO" | grep -c 'WARNING' || true)
  CTLW=$(printf 'WARNING\n' | grep -c 'WARNING')
  if [ "$CTLW" != 1 ]; then no "HARNESS: the WARNING probe cannot match a planted WARNING."
  elif [ "$W" = 0 ]; then ok "0 (probe control fired on a planted line)"
  else no "$W occurrence(s) of WARNING in the doctor's output"; fi
fi

cell AC3 "run.sh: the same suite-by-suite pass/fail table as the pre-change baseline"
if [ "$RUN_SUITES" = 0 ]; then sk "--no-suites was passed; a skipped suite comparison is not a pass"
elif [ ! -r "$BASELINE" ]; then
  sk "no baseline at $BASELINE; AC3 compares PER SUITE against a run at the pre-change SHA and cannot be judged on totals"
else
  # NOTE: run.sh only terminates with STDIN CLOSED. Without </dev/null it hangs
  # at 0% CPU for 20+ minutes, looking exactly like a failing suite.
  OUT="$SCRATCH/run-now.txt"
  CLAUDE_PLUGIN_ROOT="$REPO/plugins/pipeline" bash plugins/pipeline/tests/run.sh </dev/null > "$OUT" 2>&1
  suitetable() { grep -E '^(passed=|== )' "$1" | paste - - 2>/dev/null || grep -E '^(passed=|== )' "$1"; }
  NOWT=$(grep -E '^passed=[0-9]+ failed=[0-9]+$' "$OUT")
  BT=$(grep -E '^passed=[0-9]+ failed=[0-9]+$' "$BASELINE")
  if [ -z "$NOWT" ]; then no "run.sh produced no per-suite counters; see $OUT"
  elif [ "$NOWT" = "$BT" ]; then
    NS=$(printf '%s\n' "$NOWT" | grep -c .)
    ok "$NS suites, per-suite counters identical to the baseline (compared per suite, never on totals)"
  else
    no "per-suite counters MOVED:" "$(diff <(printf '%s\n' "$BT") <(printf '%s\n' "$NOWT") | head -20)"
  fi
fi

# ============================================================================
hdr "SUMMARY"
printf '\n'
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
printf '\n  PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" = 0 ] && [ "$SKIP" = 0 ]; then
  printf '\n  verify-19.sh: GREEN. Every cell passed.\n'; exit 0
else
  printf '\n  verify-19.sh: NOT GREEN (%d failed, %d skipped). A SKIP IS NOT A PASS.\n' "$FAIL" "$SKIP"; exit 1
fi
