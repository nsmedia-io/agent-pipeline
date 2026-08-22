#!/usr/bin/env bash
# =============================================================================
# verify-21.sh -- the QA Phase 3a verification battery for issue #21.
#
# THIS IS A COMMAND, NOT A CI GATE. Nothing runs it automatically. It is not
# registered anywhere, it is not globbed by plugins/pipeline/tests/run.sh, and
# it lives in a gitignored artifact directory ON PURPOSE: this session may not
# create or modify anything under plugins/pipeline/tests/ (that directory is a
# concurrent session's surface, and AC15 asserts the diff touches nothing
# outside the owned one). So the strongest control available here is a command
# a human runs. It is strictly better than reviewer eyes and strictly weaker
# than a test. Read that sentence twice before citing a green run of this file
# as evidence of anything, and read the MANUAL section it prints at the end.
#
# RUN IT (one command, from anywhere, no setup):
#     bash .pipeline/21/verify-21.sh                   # every cell
#     bash .pipeline/21/verify-21.sh --only 'AC4*'     # one cell or one glob
#     bash .pipeline/21/verify-21.sh --skip 'AC14*'    # defer the 6-minute cell
#     bash .pipeline/21/verify-21.sh --controls        # the non-zero controls
#
# EXIT: 0 only when every selected cell PASSes and no cell SKIPs. A SKIP IS NOT
# A PASS and never contributes to a zero exit.
#
# EACH CELL declares the state it is EXPECTED to be in at the Phase 3a base
# (d6b7998), before Dev implements anything:
#   [base:RED]   the implementation is absent, so the cell MUST fail now. These
#                are the contract. Dev drives them green.
#   [base:GREEN] the cell passes at the base. It is a NON-REGRESSION check or
#                an INSTRUMENT check, NOT coverage of this change. A green here
#                proves nothing about the new prose. A cell that fails while
#                declaring base:GREEN is the loud one: something unrelated to
#                the missing implementation is wrong.
#   [base:SKIP]  the cell cannot run until a Phase 3 artifact exists. It prints
#                SKIP and keeps the exit non-zero.
#
# EVERY MUTATION IN THIS FILE HAPPENS ON A COPY under $TMPDIR, never in the
# worktree, and is restored by deleting the copy -- never by `git checkout` in
# the worktree, which is how an agent once discarded its own uncommitted work.
# The worktree is never written to by this script.
# =============================================================================

set -uo pipefail

# ---- location ---------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/../.." && pwd)"   # .pipeline/21/ -> repo root
SRC="$REPO"                             # content root for file-content cells
ARTDIR="$SELF_DIR"
ONLY='*'
SKIPPAT=''
MODE=run
BASELINE=''                             # AC15/D2 diff base; default resolved below

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="$2"; SRC="$2"; shift 2;;
    --src)      SRC="$2"; shift 2;;
    --only)     ONLY="$2"; shift 2;;
    --skip)     SKIPPAT="$2"; shift 2;;
    --baseline) BASELINE="$2"; shift 2;;
    --controls) MODE=controls; shift;;
    -h|--help)  sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 64;;
  esac
done

PP="$SRC/plugins/pipeline"
BA="$PP/agents/ba.md"
DEV="$PP/agents/dev.md"
SEC="$PP/agents/secops.md"
CMD="$PP/commands/pipeline.md"
DOCTOR="$PP/scripts/config-doctor.mjs"
PREADME="$PP/README.md"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify21.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

# ---- the literals this change is about --------------------------------------
# Written once, here, so a reader can see every string the battery keys on and
# so no cell hand-copies one from another cell.
LIT_PATH='pipeline.config.json'
LIT_BOLD='A diff that touches `pipeline.config.json` itself is architectural, always'
LIT_BA_FLOOR='the `data`, `security`, or `compliance` domains'
LIT_CMD_FLOOR='intersects `{data, security, compliance}`'
LIT_ORIG_PAREN='(it is listed under `architecturalTriggers.paths` in both this repo'"'"'s config and the shipped example)'
DIGEST='14b65c48479dfceefb780689adccfbd53656b21e'
REF_SHA='587a4aa'          # the named, reachable SHA the run.sh table was taken at
# RE-PINNED 2026-08-22, after this branch was rebased onto origin/main. The old pin,
# 60ad335, was a BRANCH commit, and a rebase rewrites every branch commit: AC14a caught
# it going dangling, which is the cell working, not the cell rotting. The replacement is
# an INTEGRATION-branch commit (origin/main's tip at the rebase) for exactly that reason:
# it survives every future rebase of this branch. The table below was measured at it, in
# a detached worktree, and separately on this branch -- the two agree suite for suite.
CTRL_RANGE='7a052d3^...7a052d3'   # a range that genuinely touched unowned paths

# The five TRIPWIRE axes, spelled EXACTLY as secops.md spells them. The
# hyphenation of the third is load-bearing: `webhook` alone matches two lines of
# the span, so a check on the bare word survives deletion of the axis and
# reports PASS while checking nothing. See AC10b.naive-is-dead.
AXES='auth flow
crypto
webhook-verification
external data intake
compliance-relevant data type'

# R10's owned surface, repo-root-relative, matching what `git diff --name-only`
# emits. AC15 compares against exactly this list.
OWNED_RE='^plugins/pipeline/agents/[a-z-]+\.md$|^plugins/pipeline/schemas/(review|peer-review)\.schema\.json$|^plugins/pipeline/scripts/config-doctor\.mjs$|^plugins/pipeline/commands/pipeline\.md$'

# ---- reporting --------------------------------------------------------------
PASS_N=0; FAIL_N=0; SKIP_N=0; SURPRISE_N=0
FAILED=''
B=RED       # per-cell expected state at the Phase 3a base; set before each cell
D=''        # per-check detail, set by the chk_ functions

ok()   { printf 'PASS  [base:%-5s] %-30s %s\n' "$B" "$1" "$2"; PASS_N=$((PASS_N+1)); }
no()   { printf 'FAIL  [base:%-5s] %-30s %s\n' "$B" "$1" "$2"; FAIL_N=$((FAIL_N+1)); FAILED="$FAILED $1"
         if [ "$B" = GREEN ]; then SURPRISE_N=$((SURPRISE_N+1)); fi; }
skip() { printf 'SKIP  [base:%-5s] %-30s %s\n' "$B" "$1" "$2"; SKIP_N=$((SKIP_N+1)); FAILED="$FAILED $1(skip)"; }
det()  { printf '                       | %s\n' "$1"; }
hdr()  { printf '\n--- %s\n' "$1"; }

want() {
  case "$1" in $ONLY) ;; *) return 1;; esac
  if [ -n "$SKIPPAT" ]; then
    case "$1" in $SKIPPAT) skip "$1" 'deferred by --skip (a deferral is not a pass; exit stays non-zero)'; return 1;; esac
  fi
  return 0
}
# cell <id> <chkfn> <args...> : run a check function, report, carry its detail
cell() {
  local id="$1"; shift
  want "$id" || return 0
  D=''
  if "$@"; then ok "$id" "$D"; else no "$id" "$D"; fi
}

# ---- copies -----------------------------------------------------------------
# A content copy of the tree under test. 2.1 MB; a fresh one per mutation, so no
# mutation can ever outlive its cell or be "restored" from memory.
N_COPY=0
mkcopy() {
  N_COPY=$((N_COPY+1))
  local d="$TMPROOT/c$N_COPY"
  mkdir -p "$d"
  ( cd "$SRC" && tar -cf - plugins/pipeline pipeline.config.json 2>/dev/null ) | ( cd "$d" && tar -xf - )
  echo "$d"
}

# =============================================================================
# EXTRACTORS -- every region this battery reasons about, derived here once.
# A cell that greps a whole FILE where the criterion names a REGION is the
# defect AC10(a) exists to catch, so region extraction is never inlined.
# =============================================================================

# ba.md, the ONE physical line carrying the mandatory trigger list (line 61 at
# d6b7998). AC1 is scoped to THIS LINE and not to the file: the read-duty
# paragraph will also name the path literal, so a file-wide grep would pass with
# the floor deleted from the contract list. That is the whole of AC1's mutation.
ba_bullet() { grep -n '\*\*architectural\*\*, MANDATORY' "$1/plugins/pipeline/agents/ba.md" 2>/dev/null | head -1; }

# ba.md Phase 1 duty 6, from its numbered head to the head of duty 7.
ba_duty6() { awk '/^6\. \*\*Triage severity and set the risk tier/{f=1} /^7\. /{f=0} f' "$1/plugins/pipeline/agents/ba.md" 2>/dev/null; }

# ba.md duty 6 with the mandatory-trigger line removed: the region the config
# READ duty must live in. Keeps AC4/AC5 from being satisfied by text that
# happens to sit on the pre-existing bullet.
ba_readduty() { ba_duty6 "$1" | grep -v '\*\*architectural\*\*, MANDATORY'; }

# commands/pipeline.md `### Risk-tiered orchestration depth`, heading to the
# line before the next heading or rule.
cmd_section() { awk '/^### Risk-tiered orchestration depth/{f=1;print;next} f&&/^(---|#{1,6} )/{exit} f' "$1/plugins/pipeline/commands/pipeline.md" 2>/dev/null; }

# the physical line carrying the tier-read sentence, the bold sentence, the
# post-BA validation clause and the parenthetical (all four are on one line).
cmd_tierline() { grep '^The tier is read once after BA returns' "$1/plugins/pipeline/commands/pipeline.md" 2>/dev/null | head -1; }

# the parenthetical IMMEDIATELY after the bold sentence, and nothing else.
cmd_paren() {
  local l after; l="$(cmd_tierline "$1")"; [ -n "$l" ] || return 1
  case "$l" in *"$LIT_BOLD"*) ;; *) return 1;; esac
  after="${l#*"$LIT_BOLD"\*\*}"
  after="${after# }"
  case "$after" in '('*) ;; *) return 1;; esac
  printf '%s)\n' "${after%%)*}"
}

# the orchestrator's post-BA validation clause, and nothing else.
cmd_validation() {
  local l after; l="$(cmd_tierline "$1")"; [ -n "$l" ] || return 1
  case "$l" in *'validated by the orchestrator'*) ;; *) return 1;; esac
  after="${l#*validated by the orchestrator}"
  printf '%s)\n' "${after%%)*}"
}

# secops.md's STANDARD-TIER CONSTRAINTS span, extracted with THE SAME COMMAND
# commands/pipeline.md:225 uses to build constraints.md. Text outside this span
# does not reach the standard-tier Dev thread at all, which is the one tier with
# no Phase 2 and no pre-code SecOps review.
sec_span() { sed -n '/BEGIN STANDARD-TIER CONSTRAINTS/,/END STANDARD-TIER CONSTRAINTS/p' "$1/plugins/pipeline/agents/secops.md" 2>/dev/null; }

# the backstop text itself, per file: the line(s) naming the trigger path AND
# calling it a mis-tier. dev.md names pipeline.config.json on three unrelated
# lines (checkCommand, frontendSurface), so presence of the path alone is not
# the backstop and a check keyed on it would pass at the base.
backstop_secops() { sec_span "$1" | grep -i -- "$LIT_PATH" | grep -i 'mis-tier'; }
backstop_dev()    { grep -i -- "$LIT_PATH" "$1/plugins/pipeline/agents/dev.md" 2>/dev/null | grep -i 'mis-tier'; }

# =============================================================================
# CHECK FUNCTIONS -- each takes a source root so the SAME function can be run
# against the worktree (default mode) and against a mutated copy (controls).
# A control that re-implements the check it is controlling proves nothing.
# =============================================================================

# ---- AC1: the floor exists IN THE CONTRACT ----------------------------------
chk_ac1_floor() {
  local l; l="$(ba_bullet "$1")"
  if [ -z "$l" ]; then D='the mandatory-trigger bullet was not found in ba.md at all'; return 1; fi
  case "$l" in
    *'`'"$LIT_PATH"'`'*) D="the mandatory list names \`$LIT_PATH\` (ba.md:${l%%:*})"; return 0;;
    *) D="ba.md:${l%%:*} mandatory list names NO file path (floor absent; a reader with only ba.md and no config on disk has no path trigger)"; return 1;;
  esac
}
# the discrimination that makes AC1 a reading: file-wide vs bullet-scoped.
# NOTE THE FIRST DRAFT'S BUG, because it is the class this whole battery guards:
# the mutator originally only APPENDED the literal to a read-duty line. That
# discriminates at the base (where the bullet lacks it) and is a NO-OP after
# implementation (where the bullet already carries it), so the instrument only
# worked in one of the two states it exists to distinguish -- and it reported
# INSTRUMENT BROKEN against a correct reference implementation. It now DELETES
# the literal from the contract list first, so the cell reads the same way
# before and after Dev.
chk_ac1_scoped() {
  local c f
  c="$(mkcopy)"
  perl -ni -e 'if (/\*\*architectural\*\*, MANDATORY/) { s/, or touches the file `pipeline\.config\.json` itself//g; s/`pipeline\.config\.json`/`SOME-OTHER-PATH`/g; } print' "$c/plugins/pipeline/agents/ba.md"
  printf '\n   The config read duty mentions %s and nothing in the contract list does.\n' "\`$LIT_PATH\`" >> "$c/plugins/pipeline/agents/ba.md"
  f="$(grep -c -- "$LIT_PATH" "$c/plugins/pipeline/agents/ba.md")"
  if chk_ac1_floor "$c"; then
    D="INSTRUMENT BROKEN: the bullet-scoped check PASSED on a copy whose contract list carries no path literal at all (file-wide grep=$f). AC1 would then be satisfiable by the read-duty paragraph alone, which is AC1's own named mutation."
    rm -rf "$c"; return 1
  fi
  D="literal stripped from the contract list and left only in a read-duty line: the bullet-scoped check reads FAIL while a file-wide grep still reads $f. So AC1 cannot be satisfied by the read-duty paragraph alone."
  rm -rf "$c"; return 0
}
# the floor is a FLOOR: its presence must not depend on any config file.
# Four live inputs, each applied to its own copy.
ac1_four_inputs() {  # echoes "<label> <PASS|FAIL>" per line
  local c
  c="$(mkcopy)"; rm -f "$c/pipeline.config.json"
  if chk_ac1_floor "$c"; then echo 'no-config-file PASS'; else echo 'no-config-file FAIL'; fi; rm -rf "$c"
  c="$(mkcopy)"; printf '{}\n' > "$c/pipeline.config.json"
  if chk_ac1_floor "$c"; then echo 'empty-object PASS'; else echo 'empty-object FAIL'; fi; rm -rf "$c"
  c="$(mkcopy)"; printf '{ "architecturalTriggers": \n' > "$c/pipeline.config.json"
  if chk_ac1_floor "$c"; then echo 'malformed PASS'; else echo 'malformed FAIL'; fi; rm -rf "$c"
  c="$(mkcopy)"; printf '{"checkCommand":"true"}\n' > "$c/pipeline.config.json"
  if chk_ac1_floor "$c"; then echo 'key-omitted PASS'; else echo 'key-omitted FAIL'; fi; rm -rf "$c"
}
chk_ac1_inputs_pass() {
  local out n; out="$(ac1_four_inputs)"; n="$(printf '%s\n' "$out" | grep -c ' PASS$')"
  D="$(printf '%s' "$out" | tr '\n' ';')"
  [ "$n" -eq 4 ]
}
chk_ac1_inputs_invariant() {
  local out base want; out="$(ac1_four_inputs)"
  if chk_ac1_floor "$SRC"; then base=PASS; else base=FAIL; fi
  want="$(printf '%s\n' "$out" | awk -v b="$base" '$2!=b{print $1}')"
  D="unmutated=$base; four live inputs: $(printf '%s' "$out" | tr '\n' ';')"
  [ -z "$want" ]
}

# ---- AC2: widen-only stated, and the ban is WORD-BOUNDED --------------------
chk_ac2_mechanism() {
  local r; r="$(ba_readduty "$1")"
  local has_floor=0 has_add=0
  printf '%s' "$r" | grep -qi 'floor' && has_floor=1
  printf '%s' "$r" | grep -qiE 'only[^.]{0,40}(ADD|widen)|never remove|can never remove|never removes|only ever widen' && has_add=1
  D="in ba.md duty 6 (read-duty region): 'floor'=$has_floor, only-add/never-remove=$has_add"
  [ "$has_floor" -eq 1 ] && [ "$has_add" -eq 1 ]
}
chk_ac2_bare_ban() {
  local f n a
  f="$1/plugins/pipeline/agents/ba.md"
  n="$(grep -cE 'migrationGlobs([^A-Za-z]|$)' "$f" 2>/dev/null || true)"
  a="$(grep -c 'migrationGlobsForTripwire' "$f" 2>/dev/null || true)"
  if [ "$a" -eq 0 ]; then
    D="bare word-bounded \`migrationGlobs\` = $n; NOTE THE VACUITY: the halting-control analogy is ABSENT from ba.md ($a hits for migrationGlobsForTripwire), so this cell is currently a zero with nothing to discriminate. AC2's second mutation only bites once the analogy exists."
  else
    D="bare word-bounded \`migrationGlobs\` = $n, with the analogy present ($a hits for migrationGlobsForTripwire)"
  fi
  [ "$n" -eq 0 ]
}
# The oracle for the ban, asserted rather than printed. A ban that refuses the
# text R2(a) MANDATES is a criterion contradicting its own requirement.
chk_ac2_oracle() {
  local good bad gb bb gp bp
  good='the union is migrationGlobsForTripwire, never the gate resolver'
  bad='the config unions into migrationGlobs'
  gb="$(printf '%s\n' "$good" | grep -cE 'migrationGlobs([^A-Za-z]|$)')"
  bb="$(printf '%s\n' "$bad"  | grep -cE 'migrationGlobs([^A-Za-z]|$)')"
  gp="$(printf '%s\n' "$good" | grep -c 'migrationGlobs')"
  bp="$(printf '%s\n' "$bad"  | grep -c 'migrationGlobs')"
  D="word-bounded: compliant=$gb (must be 0), mutation=$bb (must be 1). Plain substring, for contrast: compliant=$gp, mutation=$bp -- the plain form REFUSES the compliant text, which is why the ban is word-bounded."
  [ "$gb" -eq 0 ] && [ "$bb" -eq 1 ] && [ "$gp" -eq 1 ] && [ "$bp" -eq 1 ]
}

# ---- AC3: the config read is a DUTY, not a comment --------------------------
# Strip every line containing `# CUSTOMIZE:` and ask whether the read duty is
# still there. The naive implementation puts the read duty on a line that also
# carries the marker (ba.md writes every paragraph as ONE physical line), and
# the strip takes it to zero.
ac3_stripped() { grep -v '# CUSTOMIZE:' "$1/plugins/pipeline/agents/ba.md" 2>/dev/null; }
chk_ac3_survives() {
  local s n
  s="$(ac3_stripped "$1")"
  n="$(printf '%s\n' "$s" | grep -ciE 'read[^.]{0,120}architecturalTriggers|architecturalTriggers[^.]{0,120}read')"
  D="after deleting every \`# CUSTOMIZE:\` line from ba.md, read-duty instructions naming architecturalTriggers = $n (need >=1)"
  [ "$n" -ge 1 ]
}
# The non-zero control for that zero: the strip must be SURGICAL, not a blanket
# delete. An unrelated duty-6 sentence has to survive it, or the cell above is
# measuring the strip rather than the prose.
chk_ac3_surgical() {
  local before after ctrl
  ctrl='This generalizes the older'
  before="$(grep -c "$ctrl" "$1/plugins/pipeline/agents/ba.md")"
  after="$(ac3_stripped "$1" | grep -c "$ctrl")"
  D="control sentence 'This generalizes the older': $before before the strip, $after after (a blanket delete would read 0)"
  [ "$before" -eq 1 ] && [ "$after" -eq 1 ]
}

# ---- AC4: all four degenerate inputs, MUTATED SEPARATELY --------------------
# One sub-cell per clause. AC4 forbids reading the paragraph as one blob,
# because a blob check passes on any cell where some new text appeared.
ac4_re() {  # <which> -> a regex
  case "$1" in
    which-file) echo 'project root';;
    not-cache)  echo 'never the plugin cache|not the plugin cache|rather than the plugin cache';;
    absent)     echo 'absent|does not exist|is missing|no such file';;
    unparse)    echo 'fails? to parse|unparseable|cannot be parsed|invalid JSON';;
    notobject)  echo 'other than a JSON object|not a JSON object|not an object|non-object';;
    resolution) echo 'floor alone|built-in floor alone|treat it as `\{\}`|treat it as \{\}';;
    nocite)     echo 'do not name the config|not name the config|does not cite|must not cite|do not cite';;
  esac
}
chk_ac4() {
  local r n; r="$(ba_readduty "$1")"
  n="$(printf '%s\n' "$r" | grep -ciE "$(ac4_re "$2")")"
  D="ba.md duty 6 read-duty region, clause '$2': $n line(s) match /$(ac4_re "$2")/"
  [ "$n" -ge 1 ]
}

# ---- AC5: the trust premise, WITH its void condition ------------------------
chk_ac5_trust() {
  local r c s; r="$(ba_readduty "$1")"
  c="$(printf '%s\n' "$r" | grep -c 'checkCommand')"
  s="$(printf '%s\n' "$r" | grep -ciE 'every Stop|at each Stop|executed at .{0,12}Stop')"
  D="read-duty region: checkCommand=$c, execution-at-Stop=$s (both needed; a trust claim with no named mechanism is an assertion)"
  [ "$c" -ge 1 ] && [ "$s" -ge 1 ]
}
chk_ac5_void() {
  local r v; r="$(ba_readduty "$1")"
  v="$(printf '%s\n' "$r" | grep -ciE '(void|no longer applies|does not apply)[^.]{0,200}(writable|readable|less trusted|lower-trust|untrusted)|(writable|readable|less trusted|lower-trust|untrusted)[^.]{0,200}(void|no longer applies|does not apply)')"
  D="read-duty region: void condition (trust premise + its expiry) = $v (a trust statement with no expiry is what lets a future change move the file to a lower-trust source with nothing failing)"
  [ "$v" -ge 1 ]
}

# ---- AC6: the twelve-cell matrix -------------------------------------------
# The matrix itself is a Phase 3 impl-report duty; the battery audits the RECORD
# and, separately, re-reads the one input that is a live fact rather than a
# hand-copy. A recorded fixture that no longer matches production is the defect
# this second cell exists to catch.
chk_ac6_live_input() {
  local dom paths
  dom="$(node -e 'const c=require(process.argv[1]);console.log(JSON.stringify(c.architecturalTriggers.domains))' "$1/pipeline.config.json" 2>/dev/null)"
  paths="$(node -e 'const c=require(process.argv[1]);console.log(JSON.stringify(c.architecturalTriggers.paths))' "$1/pipeline.config.json" 2>/dev/null)"
  D="LIVE re-read of $1/pipeline.config.json: domains=$dom paths=$paths"
  D="$D  -- if this cell ever fails, the on-disk cell of AC6's matrix has moved and impl-report.json's recorded literal is stale, not wrong-by-typo"
  [ "$dom" = '["security","compliance"]' ] && [ "$paths" = '["pipeline.config.json"]' ]
}
chk_ac6_matrix() {
  local f raw miss row col n
  f="$ARTDIR/impl-report.json"
  if [ ! -f "$f" ]; then D="no impl-report.json at $f yet"; return 2; fi
  raw="$(tr -d ' \n\t' < "$f")"
  miss=''
  for row in wider narrower absent malformed; do
    for col in paths domains keywords; do
      printf '%s' "$raw" | grep -qi "$row" && printf '%s' "$raw" | grep -qi "$col" || miss="$miss $row/$col"
    done
  done
  n=0
  printf '%s' "$raw" | grep -q '{"architecturalTriggers":{"domains":\["security","compliance"\]}}' && n=$((n+1))
  printf '%s' "$raw" | grep -qi 'noarchitecturaltriggers\|"architecturalTriggers"' && n=$((n+1))
  D="impl-report.json: missing row/col labels ={$miss}; verbatim inputs found=$n/2. AC6 also requires each cell to record its LITERAL config fragment beside its outcome, and that six of twelve collapse to two distinct inputs -- a human reads that, this cell only checks the labels are all present."
  [ -z "$miss" ] && [ "$n" -eq 2 ]
}

# ---- AC7: the bold sentence is byte-identical -------------------------------
chk_ac7_worktree() {
  local n; n="$(grep -c -- "$LIT_BOLD" "$1/plugins/pipeline/commands/pipeline.md" 2>/dev/null || true)"
  D="worktree copy: $n occurrence(s) of the frozen bold sentence (need exactly 1)"
  [ "$n" -eq 1 ]
}
chk_ac7_origin() {
  local n
  git -C "$REPO" rev-parse origin/main >/dev/null 2>&1 || { D='origin/main is not present in this checkout'; return 2; }
  n="$(git -C "$REPO" show origin/main:plugins/pipeline/commands/pipeline.md 2>/dev/null | grep -c -- "$LIT_BOLD")"
  D="origin/main ($(git -C "$REPO" rev-parse --short origin/main)): $n occurrence(s) (need exactly 1)"
  [ "$n" -eq 1 ]
}
chk_ac7_oracle() {
  local c n
  c="$(mkcopy)"
  perl -0pi -e 's/is architectural, always/is normally architectural/' "$c/plugins/pipeline/commands/pipeline.md"
  n="$(grep -c -- "$LIT_BOLD" "$c/plugins/pipeline/commands/pipeline.md" || true)"
  D="on a copy with 'always' reworded to 'normally', the same grep reads $n (must be 0, or the AC7 check is not byte-exact)"
  rm -rf "$c"
  [ "$n" -eq 0 ]
}

# ---- AC8: three halves, each separately mutable -----------------------------
chk_ac8a_evaluators() {
  local s n; s="$(cmd_section "$1")"
  n="$(printf '%s\n' "$s" | grep -cE 'evaluate|evaluators?' | head -1)"
  local both
  both="$(printf '%s\n' "$s" | grep -E 'evaluate' | grep -c 'orchestrator')"
  D="section: lines naming evaluation=$n, of which lines also naming the orchestrator=$both (AC8's first half wants BOTH prose evaluators named in the section's own sentence)"
  [ "$both" -ge 1 ] && printf '%s\n' "$s" | grep -E 'evaluate' | grep -qE '(^|[^A-Za-z])BA([^A-Za-z]|$)'
}
chk_ac8b_nopredicate() {
  local s n; s="$(cmd_section "$1")"
  n="$(printf '%s\n' "$s" | grep -ciE 'no path predicate|no script evaluates a diff|no predicate evaluates a diff')"
  D="section: 'no path predicate evaluates a diff' claim = $n (deleting only this half leaves the section reading as fully mechanised, which is the defect this issue names)"
  [ "$n" -ge 1 ]
}
chk_ac8c_parenthetical() {
  local p
  p="$(cmd_paren "$1")" || { D='no parenthetical immediately follows the bold sentence'; return 1; }
  if [ "$p" = "$LIT_ORIG_PAREN" ]; then
    D="the parenthetical is UNCHANGED: $p -- it attributes the always-ness solely to two config files, so a reader with no config file gets the wrong answer at the nearest possible distance"
    return 1
  fi
  local names_floor=0
  printf '%s' "$p" | grep -qiE 'ba\.md|agent contract|mandatory trigger' && printf '%s' "$p" | grep -qiE 'floor|built-in|hardcoded' && names_floor=1
  D="parenthetical: $p  [names the built-in floor in the agent contract = $names_floor]"
  [ "$names_floor" -eq 1 ]
}

# ---- AC9: the post-BA validation clause -------------------------------------
chk_ac9a_names_path() {
  local v
  v="$(cmd_validation "$1")" || { D='the post-BA validation clause was not found'; return 1; }
  D="validation clause: $v"
  printf '%s' "$v" | grep -q -- "$LIT_PATH"
}
chk_ac9b_floor_phrased() {
  local v bad floor
  v="$(cmd_validation "$1")" || { D='the post-BA validation clause was not found'; return 1; }
  floor=0; bad=0
  printf '%s' "$v" | grep -qiE 'floor|built-in' && floor=1
  printf '%s' "$v" | grep -qiE 'configured (in|under|path)|a path configured|listed in `?architecturalTriggers' && bad=1
  D="validation clause: floor-or-built-in phrasing=$floor, 'a configured path' phrasing=$bad (AC9's mutation is exactly the second; with no config file the clause must still promote)"
  [ "$floor" -eq 1 ] && [ "$bad" -eq 0 ]
}

# ---- AC10(a): SITING, checked on the EXTRACTION and not the file ------------
chk_ac10a_secops() {
  local inspan infile
  inspan="$(backstop_secops "$1" | wc -l | tr -d ' ')"
  infile="$(grep -i -- "$LIT_PATH" "$1/plugins/pipeline/agents/secops.md" 2>/dev/null | grep -ci 'mis-tier' || true)"
  D="constraints.md EXTRACTION (the only text the standard-tier Dev thread sees): $inspan backstop line(s); whole file: $infile. A file grep passing where the extraction reads 0 is the defect."
  [ "$inspan" -ge 1 ]
}
chk_ac10a_dev() {
  local n; n="$(backstop_dev "$1" | wc -l | tr -d ' ')"
  D="dev.md (read whole at every tier, no markers): $n backstop line(s) naming \`$LIT_PATH\` as a mis-tier"
  [ "$n" -ge 1 ]
}
# the instrument: siting DECIDES EXISTENCE. Measured, not asserted. Same fix as
# AC1.bullet-scoped, for the same reason: the copy has any IN-SPAN backstop
# removed first, so the oracle reads the same way before and after Dev.
chk_ac10a_oracle() {
  local c inb outb
  c="$(mkcopy)"
  perl -ni -e 'print unless (/pipeline\.config\.json/ && /mis-tier/i)' "$c/plugins/pipeline/agents/secops.md"
  printf -- '- Config-tier backstop: a diff that touches `%s` itself under a non-architectural tier is a mis-tier.\n' "$LIT_PATH" >> "$c/plugins/pipeline/agents/secops.md"
  inb="$(backstop_secops "$c" | wc -l | tr -d ' ')"
  outb="$(grep -i -- "$LIT_PATH" "$c/plugins/pipeline/agents/secops.md" | grep -ci 'mis-tier' || true)"
  D="the SAME sentence appended OUTSIDE the END marker: extraction reads $inb, whole file reads $outb. Extraction 0 / file non-zero IS the discrimination -- only text between the markers reaches the standard-tier Dev thread, and that is the one tier with no Phase 2 and no pre-code SecOps review."
  rm -rf "$c"
  [ "$inb" -eq 0 ] && [ "$outb" -ge 1 ]
}

# ---- AC10(b): the 5x5 TABLE, not five greps ---------------------------------
# For axis i: with every axis present check_i must read 1; deleting axis i must
# take check_i to 0; and deleting any of the OTHER FOUR must leave check_i at 1.
# Twenty-five outcomes. Five checks that each merely return 1 prove only that
# five strings exist somewhere in the span.
chk_ac10b_table() {
  local span tmp i j ai aj v bad n
  span="$TMPROOT/span.$$"; sec_span "$1" > "$span"
  bad=''; n=0
  i=0
  while IFS= read -r ai; do
    [ -n "$ai" ] || continue
    i=$((i+1))
    v="$(grep -c -- "$ai" "$span" || true)"
    [ "$v" -ge 1 ] || bad="$bad baseline($ai)=$v"
    j=0
    while IFS= read -r aj; do
      [ -n "$aj" ] || continue
      j=$((j+1))
      tmp="$TMPROOT/span.$i.$j"
      # delete axis j from a COPY of the extraction; never touch the worktree
      awk -v a="$aj" '{gsub(a,"");print}' "$span" > "$tmp"
      v="$(grep -c -- "$ai" "$tmp" || true)"
      n=$((n+1))
      if [ "$i" -eq "$j" ]; then
        [ "$v" -eq 0 ] || bad="$bad self($ai)=$v(want 0)"
      else
        [ "$v" -ge 1 ] || bad="$bad cross($ai|del $aj)=$v(want >=1)"
      fi
      rm -f "$tmp"
    done <<EOF_AXES
$AXES
EOF_AXES
  done <<EOF_AXES2
$AXES
EOF_AXES2
  rm -f "$span"
  D="$n of 25 table outcomes evaluated over the five axes, spelled as the file spells them; deviations={$bad}"
  [ -z "$bad" ]
}
# the reading that makes the table a finding rather than a rubber stamp: the
# OBVIOUS RELAXATION is worse than the dead cell it replaces.
chk_ac10b_naive_dead() {
  local span cut base_ci base_cs cut_ci cut_hy
  span="$TMPROOT/span.n.$$"; sec_span "$1" > "$span"
  cut="$TMPROOT/span.n.cut.$$"; awk '{gsub("webhook-verification","");print}' "$span" > "$cut"
  base_ci="$(grep -ci 'webhook' "$span" || true)"; base_cs="$(grep -c 'webhook' "$span" || true)"
  cut_ci="$(grep -ci 'webhook' "$cut" || true)";  cut_hy="$(grep -c 'webhook-verification' "$cut" || true)"
  D="span baseline: 'webhook' -i=$base_ci, -c=$base_cs. With the AXIS DELETED: 'webhook' -i=$cut_ci (>=1, so a case-insensitive check STILL REPORTS PASS -- a dead check that looks alive) vs 'webhook-verification'=$cut_hy (0, so the hyphenated spelling is the one that discriminates)."
  rm -f "$span" "$cut"
  [ "$cut_ci" -ge 1 ] && [ "$cut_hy" -eq 0 ]
}

# ---- AC10(c): the label claims only itself ----------------------------------
chk_ac10c() {  # <src> <secops|dev>
  local t hits
  case "$2" in
    secops) t="$(backstop_secops "$1")";;
    dev)    t="$(backstop_dev "$1")";;
  esac
  if [ -z "$t" ]; then
    D="no backstop text found in $2 to check the label of -- this cell REFUSES to pass vacuously"
    return 1
  fi
  hits=''
  printf '%s' "$t" | grep -qi 'not a mechanism'   && hits="$hits 'not a mechanism'"
  printf '%s' "$t" | grep -qiE '(^|[^a-z])unlike([^a-z]|$)' && hits="$hits 'unlike'"
  printf '%s' "$t" | grep -qi 'the others'        && hits="$hits 'the others'"
  D="$2 backstop, banned contrastive constructions found:{$hits} (per #66 NOTHING mechanical backs any bullet in that file in a plugin-installed project, so labelling exactly one bullet a norm tells the reader the unlabelled ones are mechanical)"
  [ -z "$hits" ]
}
chk_ac4_vac() { chk_ac4 "$1" absent; }
chk_ac10c_secops_wrap() { chk_ac10c "$1" secops; }
chk_ac10c_dev_wrap()    { chk_ac10c "$1" dev; }
# the substring trap, asserted: 'unlikely' contains 'unlike'. A plain ban would
# refuse compliant text, which is AC2's lesson applied to AC10(c).
chk_ac10c_oracle() {
  local a b
  a="$(printf 'this is unlikely to fire\n' | grep -cE '(^|[^a-z])unlike([^a-z]|$)')"
  b="$(printf 'unlike the rules above\n'   | grep -cE '(^|[^a-z])unlike([^a-z]|$)')"
  D="word-bounded 'unlike': on 'unlikely'=$a (must be 0, or the ban refuses compliant text), on 'unlike the rules above'=$b (must be 1)"
  [ "$a" -eq 0 ] && [ "$b" -eq 1 ]
}

# ---- AC11: the config-doctor reader string ----------------------------------
doctor_reader() {
  # The path goes in the ENVIRONMENT, never in argv[1]: config-doctor.mjs uses
  # isMain(import.meta.url), and passing its own path as argv[1] makes the
  # import run the whole diagnosis and prepend three INFO lines to the value.
  # The first draft of this battery did exactly that, and AC11b PASSED at a
  # base where it must fail, because the polluted string was != the literal.
  # A cell that came out the way I hoped, for a reason that was not the prose.
  command -v node >/dev/null 2>&1 || return 2
  DOC="$1/plugins/pipeline/scripts/config-doctor.mjs" node -e 'import(process.env.DOC).then(m=>process.stdout.write("READER>>"+String(m.ALL_KEYS.architecturalTriggers.reader)))' 2>/dev/null | sed -n 's/^.*READER>>//p'
}
chk_ac11_both() {
  local r; r="$(doctor_reader "$1")" || { D='node unavailable'; return 2; }
  local ba cmd
  ba=0; cmd=0
  printf '%s' "$r" | grep -qi 'ba\.md' && ba=1
  printf '%s' "$r" | grep -qi 'pipeline\.md' && cmd=1
  D="reader = \"$r\"  [names agents/ba.md=$ba, names commands/pipeline.md=$cmd; AC11 also wants the SECTION each lives in, which a human reads]"
  [ "$ba" -eq 1 ] && [ "$cmd" -eq 1 ]
}
chk_ac11_not_prose_only() {
  local r; r="$(doctor_reader "$1")" || { D='node unavailable'; return 2; }
  D="reader = \"$r\""
  [ "$r" != "BA's tiering decision (prose, not code)" ]
}

# ---- AC12: config-doctor self-test, exactly 16 ------------------------------
chk_ac12() {
  command -v node >/dev/null 2>&1 || { D='node unavailable'; return 2; }
  local out; out="$(node "$1/plugins/pipeline/scripts/config-doctor.mjs" --self-test 2>&1 | tail -1)"
  D="config-doctor --self-test tail: '$out' (R6 forbids a new case: one planted check took it to 17 and reddened tests/test-config-doctor.sh 26/0 -> 25/1)"
  case "$out" in *'16 passed, 0 failed'*) return 0;; *) return 1;; esac
}

# ---- AC13: no bare backticked sub-key in the SCANNED files ------------------
# The extractor's file list is README.md + commands/pipeline.md, and only those.
# agents/*.md are NOT scanned, which is why R5's text is not at risk.
doc_tokens() { grep -ohE '`[a-z][a-zA-Z]+`' "$1/plugins/pipeline/README.md" "$1/plugins/pipeline/commands/pipeline.md" 2>/dev/null | sed 's/.*`\(.*\)`/\1/' | sort -u; }
chk_ac13_tokens() {
  local hits; hits="$(doc_tokens "$1" | grep -xE 'paths|domains|keywords' | tr '\n' ' ')"
  D="bare backticked sub-keys in README.md + commands/pipeline.md: {${hits}} (each takes tests/test-config-doctor-surfaces.sh from 85/0 to 84/1; ALL_KEYS registers only the top-level key)"
  [ -z "$hits" ]
}
chk_ac13_oracle() {
  local c bare dotted
  c="$(mkcopy)"
  printf '\nA sentence naming `paths` bare.\n' >> "$c/plugins/pipeline/commands/pipeline.md"
  bare="$(doc_tokens "$c" | grep -xcE 'paths|domains|keywords' || true)"
  rm -rf "$c"
  c="$(mkcopy)"
  printf '\nA sentence naming `architecturalTriggers.paths` dotted, and `architecturalTriggers` bare.\n' >> "$c/plugins/pipeline/commands/pipeline.md"
  dotted="$(doc_tokens "$c" | grep -xcE 'paths|domains|keywords' || true)"
  rm -rf "$c"
  D="extractor on a copy with a BARE \`paths\` appended: $bare hit(s) (must be >=1); with the DOTTED \`architecturalTriggers.paths\` and bare \`architecturalTriggers\`: $dotted (must be 0 -- these two are the deliberate SURVIVORS that make the three failures a reading rather than a rubber stamp)"
  [ "$bare" -ge 1 ] && [ "$dotted" -eq 0 ]
}
# MEASURED, and it is why these cells refuse to run against a bare content copy:
# test-config-doctor-surfaces.sh DIAGNOSES THE SOURCE ROOT as a git project, and
# test-pipeline-telemetry.sh WALKS THE REAL `.pipeline/` CORPUS. On an isolated
# `tar` copy of the UNMODIFIED tree they read 83/2 and 98/8 with zero prose
# changed, while the same tree in a real checkout reads 85/0 and 107/0. A red
# there says "you ran me in a scratch directory", not "the diff broke me", and
# reporting it as a red would be a false finding. Verified both directions.
src_is_real_checkout() { [ -e "$1/.git" ] && [ -d "$1/.pipeline" ]; }
chk_ac13_suite() {
  local out p f
  src_is_real_checkout "$1" || { D="--src $1 is not a real git checkout with a .pipeline/ corpus; this suite diagnoses the source root and reads 83/2 there on an UNMODIFIED tree"; return 2; }
  out="$(CLAUDE_PLUGIN_ROOT="$1/plugins/pipeline" bash "$1/plugins/pipeline/tests/test-config-doctor-surfaces.sh" 2>&1 | tail -2 | grep -E '^passed=')"
  p="${out%% *}"; p="${p#passed=}"; f="${out##* }"; f="${f#failed=}"
  D="tests/test-config-doctor-surfaces.sh: passed=$p failed=$f (reference 85/0 at $REF_SHA)"
  [ "$p" = 85 ] && [ "$f" = 0 ]
}

# ---- AC14: run.sh green, per suite, at a named REACHABLE sha ----------------
# RE-TAKEN 2026-08-22 at 587a4aa. Three suites moved, +68 total (2561 -> 2629), and every
# one of the three is ATTRIBUTED, not waved through -- measured, in a detached worktree,
# at the commit on each side of the cause:
#   test-gate-phase-entry-drift.sh  37 -> 70   (+33)
#   test-gate-phase-entry.sh       493 -> 505  (+12)
#   test-voice-lint.sh              48 -> 71   (+23)
# CAUSE: 055038e (#79, 'declare 0-setup in both Lane-1 consumer tables (#53)'), the only
# commit in 13e40e9..587a4aa that touches plugins/pipeline/tests/. Measured both sides: at
# 13e40e9 (its parent) the three read 37/493/48, the OLD table exactly; at 587a4aa they read
# 70/505/71. NON-ZERO CONTROL, same method, same run: test-gate-phase-entry-hook.sh reads 59
# on both sides and 59 here, so the method reports an unmoved suite as unmoved.
# AND THE ZERO THAT MATTERS FOR THIS DIFF: this branch reads 70/505/71 too, identical to
# origin/main suite for suite, so the #21 diff moves NO suite. 055038e's own AC27 assertion
# independently pins test-voice-lint.sh at exactly 71.
REF_TABLE='test-archive-pipeline.sh 74
test-claims-consumers.sh 41
test-config-doctor-surfaces.sh 85
test-config-doctor.sh 26
test-corpus-union.sh 30
test-data-layer-surface.sh 153
test-dispatch-model-resolver.sh 108
test-dispatch-model-sites.sh 22
test-frontend-surface.sh 36
test-gate-down-classifier.sh 122
test-gate-empty-down.sh 17
test-gate-phase-entry-drift.sh 70
test-gate-phase-entry-hook.sh 59
test-gate-phase-entry.sh 505
test-gate-pre-phase4-frontend.sh 36
test-gate-pre-phase4.sh 95
test-harness.sh 87
test-issue17-integration.sh 135
test-knowledge-store.sh 59
test-merge-peer-review.sh 35
test-mis-tier-tripwire.sh 79
test-moving-ref-population.sh 26
test-open-questions-and-design-lock.sh 43
test-panel-composition-fail-direction.sh 165
test-pipeline-status.sh 41
test-scripts-lib.sh 28
test-session-start-hook.sh 20
test-status-schema-contract.sh 150
test-stop-hook.sh 18
test-subagent-stop-hook.sh 13
test-telemetry-exit-attribution.sh 48
test-validate-pipeline-artifact.sh 25
test-voice-lint.sh 71
test-pipeline-telemetry.sh 107'

chk_ac14_reach() {
  local s bad; bad=''
  for s in $REF_SHA $(git -C "$REPO" rev-parse --short HEAD); do
    git -C "$REPO" cat-file -e "$s^{commit}" 2>/dev/null && git -C "$REPO" merge-base --is-ancestor "$s" HEAD 2>/dev/null || bad="$bad $s"
  done
  D="reachability (git cat-file -e <sha>^{commit} && git merge-base --is-ancestor <sha> HEAD) for $REF_SHA and HEAD: unreachable={$bad}. The superseded b3fa566 was the dangling pre-rebase twin and failed exactly this check."
  [ -z "$bad" ]
}

RUNSH_LOG=''; RUNSH_SAMPLES=''; RUNSH_EXIT=''
run_runsh_with_sampler() {
  RUNSH_LOG="$TMPROOT/runsh.log"; RUNSH_SAMPLES="$TMPROOT/gitstatus.samples"
  : > "$RUNSH_SAMPLES"
  ( while :; do printf '%s\t%s\n' "$(date +%s)" "$(git -C "$REPO" status --short 2>/dev/null | tr '\n' '|')" >> "$RUNSH_SAMPLES"; sleep 15; done ) &
  local sampler=$!
  CLAUDE_PLUGIN_ROOT="$SRC/plugins/pipeline" bash "$SRC/plugins/pipeline/tests/run.sh" > "$RUNSH_LOG" 2>&1
  RUNSH_EXIT=$?
  kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
}
chk_ac14_suites() {
  src_is_real_checkout "$SRC" || { D="--src $SRC is not a real git checkout with a .pipeline/ corpus; several suites read both, so a run there is not comparable to the reference table"; return 1; }
  [ -n "$RUNSH_LOG" ] || run_runsh_with_sampler
  local got want bad n tot
  got="$TMPROOT/got.tbl"
  sed $'s/\033\\[[0-9;]*m//g' "$RUNSH_LOG" | awk '/^== /{s=$2} /^passed=/{p=$1;f=$2;sub("passed=","",p);sub("failed=","",f);print s" "p" "f}' > "$got"
  n="$(wc -l < "$got" | tr -d ' ')"
  tot="$(awk '{t+=$2}END{print t+0}' "$got")"
  bad="$(awk 'NR==FNR{r[$1]=$2;next}{ if(!($1 in r)) print "NEW:"$1"="$2; else if(r[$1]!=$2) print $1":"r[$1]"->"$2; if($3!="0") print $1":FAILED="$3; delete r[$1]}END{for(k in r) print "GONE:"k}' <(printf '%s\n' "$REF_TABLE") "$got" | tr '\n' ' ')"
  D="run.sh exit=$RUNSH_EXIT, suites=$n (reference 34), total passed=$tot (reference 2561). Per-suite deltas vs the $REF_SHA table: {$bad}. ANY delta must be ATTRIBUTED to a named upstream commit, not waved through -- a total alone cannot distinguish a suite that gained an assertion from one that lost one."
  [ "$RUNSH_EXIT" = 0 ] && [ "$n" -eq 34 ] && [ -z "$bad" ]
}
chk_ac14_contamination() {
  [ -n "$RUNSH_SAMPLES" ] || { D='the run.sh window was never sampled (AC14 cell not run)'; return 1; }
  local n first last span gap dirty
  n="$(wc -l < "$RUNSH_SAMPLES" | tr -d ' ')"
  first="$(head -1 "$RUNSH_SAMPLES" | cut -f1)"; last="$(tail -1 "$RUNSH_SAMPLES" | cut -f1)"
  span=$(( ${last:-0} - ${first:-0} ))
  gap="$(cut -f1 "$RUNSH_SAMPLES" | awk 'NR>1{d=$1-p; if(d>m)m=d}{p=$1}END{print m+0}')"
  # a dirty path is contamination unless it is under .pipeline/, which the
  # ORCHESTRATOR writes at every checkpoint and AC15 carves out by name.
  dirty="$(cut -f2 "$RUNSH_SAMPLES" | tr '|' '\n' | sed 's/^ *[A-Z?][A-Z? ] *//' | grep -v '^$' | grep -v '^\.pipeline/' | sort -u | tr '\n' ' ')"
  D="$n samples over a ${span}s window, max gap ${gap}s (AC14 requires a cadence well under 60s). Paths dirty in ANY sample, excluding the .pipeline/ carve-out: {$dirty}. A before/after pair cannot distinguish 'never contaminated' from 'contaminated inside the window' -- #19, and it is LIVE: a concurrent process mutated a file in this worktree mid-measurement during Phase 2."
  [ "$n" -ge 3 ] && [ "$gap" -lt 60 ] && [ -z "$dirty" ]
}

# ---- AC15: scope, with the .pipeline/ carve-out NAMED and nothing else ------
ac15_base() {
  if [ -n "$BASELINE" ]; then echo "$BASELINE"; return; fi
  # RE-PINNED 2026-08-22: d6b7998 was the pre-rebase Phase 3a base; 7245da1 is its twin
  # after the rebase onto origin/main. This one MUST stay a branch commit and so it will rot
  # at the next rebase -- deliberately, and loudly, the way it just did. The rebase-proof
  # alternative (merge-base with origin/main) goes VACUOUS the moment this branch lands on
  # main, where the base equals HEAD and an empty diff passes silently. Loud rot beats a
  # silent zero.
  git -C "$REPO" rev-parse --short 7245da1 2>/dev/null || git -C "$REPO" merge-base origin/main HEAD
}
chk_ac15_subset() {
  local b files bad
  b="$(ac15_base)"
  git -C "$REPO" cat-file -e "$b^{commit}" 2>/dev/null && git -C "$REPO" merge-base --is-ancestor "$b" HEAD 2>/dev/null || { D="baseline $b is not reachable from HEAD"; return 1; }
  files="$(git -C "$REPO" diff --name-only "$b...HEAD" -- ':(exclude).pipeline/')"
  bad="$(printf '%s\n' "$files" | grep -v '^$' | grep -vE "$OWNED_RE" | tr '\n' ' ')"
  D="git diff --name-only $b...HEAD minus .pipeline/ = [$(printf '%s' "$files" | tr '\n' ' ')]; outside the owned surface: {$bad}"
  [ -z "$bad" ]
}
# the carve-out must SUBTRACT ONE DIRECTORY, not blind the check.
chk_ac15_carveout_bites() {
  local n
  n="$(git -C "$REPO" diff --name-only $CTRL_RANGE -- ':(exclude).pipeline/' 2>/dev/null | grep -c . || true)"
  D="the SAME command with the SAME carve-out over $CTRL_RANGE (a range that genuinely touched unowned paths) reports $n path(s) -- must be >=1, or the carve-out is blinding the check rather than subtracting one directory"
  [ "$n" -ge 1 ]
}
# Hunk-header parser, ISOLATED so it can be oracle-tested on every shape git
# emits. Echoes "<old_line> <old_count> <new_line> <new_count>", or returns 1.
#
# THIS IS WHERE THE FIRST DRAFT BROKE, and the shape of the break is the lesson:
# git OMITS the ",count" when a hunk is exactly one line, and the locked design
# puts every commands/pipeline.md edit on ONE physical line, so the real diff
# renders as `@@ -125 +125 @@`. The draft ran a sed that collapsed the optional
# groups to empty strings and then split them with an unquoted `set -- $a`;
# word splitting DELETED the empty fields, $3 went unbound, and `set -uo
# pipefail` killed the entire battery at AC15 -- so AC16, AC17 and the D cells
# never ran at all. The defect was a function of hunk SHAPE, not of diff
# CONTENT, which is why it stayed invisible while the cell was vacuous: a cell
# that has never seen a real hunk has never been evaluated in either direction.
# No positional splitting now, defaults stated explicitly, and an explicit
# UNPARSED branch -- a header this cannot read is a FAILURE, never a silent skip.
parse_hunk() {
  local re='^@@ -([0-9]+)(,([0-9]+))? \+([0-9]+)(,([0-9]+))? @@'
  [[ "$1" =~ $re ]] || return 1
  printf '%s %s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-1}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[6]:-1}"
}

# The parser is now an ORACLE, so it gets its own control, asserted every run
# rather than printed. Four positive shapes with their exact expected readings
# (including the one-line shape that crashed the draft) and two shapes it must
# REFUSE -- a combined-diff header from a merge, and noise. Deliberately not
# all-positive: an oracle that accepts everything is not an oracle.
chk_ac15b_parser_oracle() {
  local bad got want pair h
  bad=''
  for pair in \
    '@@ -125,2 +125,3 @@=125 2 125 3' \
    '@@ -126,0 +127,1 @@=126 0 127 1' \
    '@@ -125 +125,3 @@=125 1 125 3' \
    '@@ -125 +125 @@=125 1 125 1'
  do
    h="${pair%%=*}"; want="${pair#*=}"
    if got="$(parse_hunk "$h")"; then
      [ "$got" = "$want" ] || bad="$bad [$h -> '$got' want '$want']"
    else
      bad="$bad [$h REFUSED, must parse]"
    fi
  done
  for h in '@@@ -1,2 -1,2 +1,3 @@@' 'not a hunk header at all'; do
    if got="$(parse_hunk "$h")"; then bad="$bad [$h ACCEPTED as '$got', must refuse]"; fi
  done
  D="hunk-header parser over 4 shapes it must read and 2 it must refuse; deviations={$bad}. The one-line shape \`@@ -125 +125 @@\` is the shape this change actually produces and the shape that killed the first draft of the battery."
  [ -z "$bad" ]
}

chk_ac15_hunks() {
  local b old_lo old_hi new_lo new_hi bad h f ol oc nl nc n touched vac
  b="$(ac15_base)"
  # section range in the OLD file and in the NEW file, computed from each side.
  old_lo="$(git -C "$REPO" show "$b:plugins/pipeline/commands/pipeline.md" 2>/dev/null | grep -n '^### Risk-tiered orchestration depth' | cut -d: -f1)"
  old_hi="$(git -C "$REPO" show "$b:plugins/pipeline/commands/pipeline.md" 2>/dev/null | awk -v s="$old_lo" 'NR>s && /^(---|#{1,6} )/{print NR-1; exit}')"
  new_lo="$(grep -n '^### Risk-tiered orchestration depth' "$CMD" | cut -d: -f1)"
  new_hi="$(awk -v s="$new_lo" 'NR>s && /^(---|#{1,6} )/{print NR-1; exit}' "$CMD")"
  bad=''; n=0
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    n=$((n+1))
    if ! f="$(parse_hunk "$h")"; then bad="$bad UNPARSED[$h]"; continue; fi
    ol="${f%% *}"; f="${f#* }"
    oc="${f%% *}"; f="${f#* }"
    nl="${f%% *}"; nc="${f#* }"
    # a zero count means the hunk has no extent on that side (pure insert or
    # pure delete); it is LOCATED on the other side, whose count is non-zero,
    # so every hunk still gets at least one real range check.
    [ "$oc" = 0 ] || { [ "$ol" -ge "${old_lo:-0}" ] && [ $((ol+oc-1)) -le "${old_hi:-0}" ] || bad="$bad old@$ol,$oc"; }
    [ "$nc" = 0 ] || { [ "$nl" -ge "${new_lo:-0}" ] && [ $((nl+nc-1)) -le "${new_hi:-0}" ] || bad="$bad new@$nl,$nc"; }
  done <<EOF_HUNKS
$(git -C "$REPO" diff -U0 "$b...HEAD" -- plugins/pipeline/commands/pipeline.md 2>/dev/null | grep '^@@')
EOF_HUNKS
  # THE VACUITY IS NOW CHECKED RATHER THAN CONFESSED. Zero hunks is legitimate
  # only while the file is untouched; once the diff changes it, zero hunks means
  # the walk read nothing and the cell is reporting a clean sweep of an empty
  # set. That contradiction is a failure, not a pass with a caveat.
  touched="$(git -C "$REPO" diff --name-only "$b...HEAD" -- plugins/pipeline/commands/pipeline.md 2>/dev/null | grep -c . || true)"
  [ "$touched" -ge 1 ] && [ "$n" -eq 0 ] && bad="$bad CONTRADICTION[file-changed-but-the-hunk-walk-saw-none]"
  if [ "$n" -eq 0 ] && [ "$touched" -eq 0 ]; then
    vac="VACUOUS: 0 hunks and commands/pipeline.md is not in the diff at all -- this cell says nothing here; read it beside AC15a."
  elif [ "$n" -eq 0 ]; then
    vac="CONTRADICTORY: git lists the file as changed but the hunk walk read nothing (a mode-only change does exactly this). A clean sweep of an empty set is not a pass."
  else
    vac="NON-VACUOUS: the walk read $n hunk(s) and range-checked each one."
  fi
  D="section range: old ${old_lo:-?}-${old_hi:-?} (at $b), new ${new_lo:-?}-${new_hi:-?} (at HEAD). $n hunk(s) in commands/pipeline.md, file-in-diff=$touched; outside the section: {$bad}. $vac"
  [ -z "$bad" ]
}

# ---- AC16: the ten-file replicated span -------------------------------------
span_hash() { awk '/^## The property, not the fix/{f=1} f{print} f&&/^This block is replicated verbatim in ten files\./{exit}' "$1" | shasum | awk '{print $1}'; }
ac16_files() { grep -rln '^## The property, not the fix' "$1/plugins/pipeline/agents/"*.md "$1/plugins/pipeline/commands/"*.md 2>/dev/null | sort; }
chk_ac16() {
  local f n bad h
  n=0; bad=''
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1)); h="$(span_hash "$f")"
    [ "$h" = "$DIGEST" ] || bad="$bad $(basename "$f")=$h"
  done <<EOF_F
$(ac16_files "$1")
EOF_F
  D="FILES carrying the span = $n (must be 10; NOT a count of distinct hashes and NOT a group count -- two of the four documented false-alarm readings). Bounds are the block's OWN published ones: heading down to the 'replicated verbatim in ten files.' line, not to the next '## ' and not to EOF. Divergent: {$bad}"
  [ "$n" -eq 10 ] && [ -z "$bad" ]
}
chk_ac16_oracle() {
  local c h n
  c="$(mkcopy)"
  perl -0pi -e 's/(## The property, not the fix)/$1./' "$c/plugins/pipeline/agents/qa.md"
  h="$(span_hash "$c/plugins/pipeline/agents/qa.md")"
  n=0
  if [ "$h" != "$DIGEST" ]; then n=1; fi
  D="one-character edit inside the span of ONE file: its hash reads $h (differs from the published $DIGEST = $n). Without this the ten-way equality could be a harness that hashes nothing."
  rm -rf "$c"
  [ "$n" -eq 1 ]
}

# ---- AC17: both prose floors still enumerate `data` -------------------------
chk_ac17_ba()  { local n; n="$(grep -c -- "$LIT_BA_FLOOR"  "$1/plugins/pipeline/agents/ba.md" || true)";            D="agents/ba.md '$LIT_BA_FLOOR' = $n (need exactly 1)"; [ "$n" -eq 1 ]; }
chk_ac17_cmd() { local n; n="$(grep -c -- "$LIT_CMD_FLOOR" "$1/plugins/pipeline/commands/pipeline.md" || true)";     D="commands/pipeline.md '$LIT_CMD_FLOOR' = $n (need exactly 1)"; [ "$n" -eq 1 ]; }
chk_ac17_oracle() {
  local c a b cov ctl
  c="$(mkcopy)"
  perl -0pi -e 's/the `data`, `security`, or `compliance` domains/the `security` or `compliance` domains/' "$c/plugins/pipeline/agents/ba.md"
  perl -0pi -e 's/intersects `\{data, security, compliance\}`/intersects `{security, compliance}`/' "$c/plugins/pipeline/commands/pipeline.md"
  a="$(grep -c -- "$LIT_BA_FLOOR" "$c/plugins/pipeline/agents/ba.md" || true)"
  b="$(grep -c -- "$LIT_CMD_FLOOR" "$c/plugins/pipeline/commands/pipeline.md" || true)"
  rm -rf "$c"
  cov="$(grep -rl -- "$LIT_BA_FLOOR" "$1/plugins/pipeline/tests/" 2>/dev/null | wc -l | tr -d ' ')"
  ctl="$(grep -rl 'is architectural, always' "$1/plugins/pipeline/tests/" 2>/dev/null | wc -l | tr -d ' ')"
  D="data-removed variants read $a and $b (both must be 0, or the greps do not discriminate). AND THE ZERO THAT MATTERS: test files pinning the ba.md floor = $cov; NON-ZERO CONTROL by the same method in the same directory: files pinning 'is architectural, always' = $ctl. So the method finds pinned prose where pinned prose exists, and this floor is genuinely unpinned. This criterion is the only protection it has until #76."
  [ "$a" -eq 0 ] && [ "$b" -eq 0 ] && [ "$ctl" -ge 1 ]
}

# ---- D: locked-design conformance (NOT acceptance criteria) -----------------
# Dev implements the LOCKED design in design.json. These gate because a
# departure from it invalidates the grafts the judge made to keep AC3, AC10(b)
# and AC16 passable; they are labelled D so no reader mistakes them for an AC.
chk_d1_dev_own_bullet() {
  local t
  t="$(backstop_dev "$1")"
  [ -n "$t" ] || { D='no backstop in dev.md to site'; return 1; }
  local onbullet appended
  onbullet="$(printf '%s\n' "$t" | grep -cE '^[[:space:]]*-')"
  appended="$(printf '%s\n' "$t" | grep -c 'Tripwire (trivial/standard tier, hard rule)' || true)"
  D="dev.md backstop: own-bullet lines=$onbullet, lines that are the EXISTING tripwire bullet=$appended (design (5): a new bullet at the same nesting level, so #76's landing is a one-line delete rather than surgery inside a bullet carrying other content)"
  [ "$onbullet" -ge 1 ] && [ "$appended" -eq 0 ]
}
chk_d2_no_new_heading() {
  local b n
  b="$(ac15_base)"
  n="$(git -C "$REPO" diff -U0 "$b...HEAD" -- plugins/pipeline 2>/dev/null | grep -cE '^\+#{2,3} ' || true)"
  D="added lines matching /^\\+#{2,3} / across plugins/pipeline = $n (GRAFT 3: no new heading anywhere in the diff, which is what keeps AC16's awk-bounded extraction unambiguous in all ten files)"
  [ "$n" -eq 0 ]
}
chk_d3_secops_adjacent() {
  local span ti bi
  span="$TMPROOT/span.d3.$$"; sec_span "$1" > "$span"
  ti="$(grep -n '^- TRIPWIRE:' "$span" | head -1 | cut -d: -f1)"
  bi="$(grep -ni -- "$LIT_PATH" "$span" | grep -i 'mis-tier' | head -1 | cut -d: -f1)"
  D="within the extraction: TRIPWIRE bullet at line ${ti:-none}, backstop bullet at line ${bi:-none} (GRAFT 2: DIRECTLY AFTER, with all five axis strings untouched)"
  rm -f "$span"
  [ -n "$ti" ] && [ -n "$bi" ] && [ "$bi" -eq $((ti+1)) ]
}
chk_d4_marker_text() {
  local l
  l="$(ba_bullet "$1")"
  D="ba.md mandatory-trigger line marker: $(printf '%s' "$l" | grep -o '# CUSTOMIZE:.*' || echo '<none>')"
  printf '%s' "$l" | grep -q 'architecturalTriggers (paths + domains + keywords)'
}

# =============================================================================
# CONTROLS -- for every cell asserting absence or cleanliness, plant the defect
# and watch that cell go red. Each control mutates its OWN copy and deletes it.
# =============================================================================
CN_OK=0; CN_BAD=0
control() {  # <name> <expect-red-fn> ...
  local name="$1"; shift
  want "$name" || return 0
  D=''
  if "$@"; then printf 'CTRL-OK   %-34s %s\n' "$name" "$D"; CN_OK=$((CN_OK+1))
  else printf 'CTRL-BAD  %-34s %s\n' "$name" "$D"; CN_BAD=$((CN_BAD+1)); FAILED="$FAILED $name"; fi
}
# a control passes when the mutation makes the named check FAIL.
mutate_and_expect_red() {  # <chkfn> <mutator...>   (mutator is called with the copy dir)
  local fn="$1"; shift
  local c; c="$(mkcopy)"
  "$@" "$c"
  if "$fn" "$c"; then D="MUTATION SURVIVED: $D"; rm -rf "$c"; return 1; fi
  D="mutation caught: $D"; rm -rf "$c"; return 0
}
m_ac1_delete_literal() { perl -0pi -e 's/, or touches the file `pipeline\.config\.json` itself//; s/ or touches `pipeline\.config\.json`//' "$1/plugins/pipeline/agents/ba.md"; }
m_ac2_bare_analogy()   { printf '\n   The config unions into migrationGlobs.\n' >> "$1/plugins/pipeline/agents/ba.md"; }
m_ac8c_restore_paren() { perl -0pi -e 's/\Q always**\E \([^)]*\)/ always** '"$(printf '%s' "$LIT_ORIG_PAREN" | sed 's/[\/&]/\\&/g')"'/' "$1/plugins/pipeline/commands/pipeline.md"; }
m_ac10a_move_outside() {
  # MOVE, not delete. The first draft used a single perl -ni with an END block,
  # and perl closes the in-place redirect BEFORE END runs, so the saved line went
  # to the terminal instead of the file: the "move" was a DELETE, and the cell
  # reddened for a reason I had not meant. The tell was in the cell's own detail
  # ("whole file: 0" where a move must leave it at 1). Two explicit passes now.
  local f line
  f="$1/plugins/pipeline/agents/secops.md"
  line="$(grep -i -- 'pipeline\.config\.json' "$f" | grep -i 'mis-tier' | head -1)"
  perl -ni -e 'print unless (/pipeline\.config\.json/ && /mis-tier/i)' "$f"
  printf '%s\n' "$line" >> "$f"
}
m_ac13_bare_token()    { printf '\nThe `domains` sub-key.\n' >> "$1/plugins/pipeline/commands/pipeline.md"; }
m_ac16_edit_span()     { perl -0pi -e 's/(## The property, not the fix)/$1./' "$1/plugins/pipeline/agents/dba.md"; }
m_ac17_drop_data()     { perl -0pi -e 's/the `data`, `security`, or `compliance` domains/the `security` or `compliance` domains/' "$1/plugins/pipeline/agents/ba.md"; }
# THE TRAP THE JUDGE GRAFTED AROUND, planted so the cell that catches it is
# proven rather than argued: Sketch B verbatim put the `# CUSTOMIZE:` marker at
# the END of the new read-duty paragraph, and ba.md writes every paragraph as
# ONE physical line, so AC3's CUSTOMIZE-line strip deletes the whole read duty.
m_ac3_marker_on_paragraph() {
  perl -ni -e 'if (/architecturalTriggers\.paths/ && !/# CUSTOMIZE:/) { chomp; print $_ . " `# CUSTOMIZE: architecturalTriggers (paths + domains + keywords) in pipeline.config.json`\n" } else { print }' "$1/plugins/pipeline/agents/ba.md"
}
# VACUITY FORM for AC4/AC5: the read duty exists in the file, but not in duty 6.
# A cell that greps the whole file would pass; the region-scoped cells must not.
m_ac4_move_out_of_duty6() {
  local f line
  f="$1/plugins/pipeline/agents/ba.md"
  line="$(grep -- 'architecturalTriggers\.paths' "$f" | head -1)"
  perl -ni -e 'print unless /architecturalTriggers\.paths/' "$f"
  printf '%s\n' "$line" >> "$f"
}
# AC8's two halves must be SEPARATELY mutable: this deletes only the second.
m_ac8b_delete_half() {
  perl -0pi -e 's/ \*\*No path predicate evaluates a diff for this rule\*\*[^.]*\.[^.]*\.//' "$1/plugins/pipeline/commands/pipeline.md"
}
# AC9's own named mutation: phrase the clause against a CONFIGURED path, which
# reads correctly in this repo and silently stops promoting in a project with
# no config file -- the exact defeat-by-absence this whole issue is about.
m_ac9b_configured_path() {
  perl -0pi -e 's/the built-in-floor-plus-union path trigger from `agents\/ba\.md` duty 6 -- currently `pipeline\.config\.json`, plus whatever a project.s config adds --/a path configured in `architecturalTriggers.paths` --/' "$1/plugins/pipeline/commands/pipeline.md"
}
m_ac7_reword()         { perl -0pi -e 's/is architectural, always/is normally architectural/' "$1/plugins/pipeline/commands/pipeline.md"; }
m_ac10c_contrast() {
  # target THE BACKSTOP LINE, not the file's first 'mis-tier'. The first draft
  # used a bare s/(mis-tier)/.../ over the whole file, which landed on an
  # unrelated earlier line and left the backstop clean, so the mutation SURVIVED
  # and looked like a coverage hole in AC10c rather than a bug in the mutator.
  perl -ni -e 'if (/pipeline\.config\.json/ && /mis-tier/i) { s/mis-tier/mis-tier -- a norm, not a mechanism, unlike the rules above/ } print' "$1/plugins/pipeline/agents/secops.md"
}

# =============================================================================
# RUN
# =============================================================================
printf 'verify-21.sh -- QA Phase 3a verification battery for issue #21\n'
printf 'THIS IS A COMMAND, NOT A CI GATE. Nothing runs it automatically.\n'
printf 'repo   : %s\n' "$REPO"
printf 'src    : %s\n' "$SRC"
printf 'HEAD   : %s\n' "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '<not a git checkout>')"
printf 'dirty  : [%s]\n' "$(git -C "$REPO" status --short 2>/dev/null | tr '\n' '|')"
printf 'mode   : %s   only=%s   skip=%s\n' "$MODE" "$ONLY" "${SKIPPAT:-<none>}"
printf 'date   : %s\n' "$(date -u +%FT%TZ)"

if [ "$MODE" = controls ]; then
  hdr 'NON-ZERO CONTROLS (each plants a defect on its own copy and requires the named cell to REDDEN)'
  control CTRL.AC1.delete-literal    mutate_and_expect_red chk_ac1_floor          m_ac1_delete_literal
  control CTRL.AC2.bare-analogy      mutate_and_expect_red chk_ac2_bare_ban       m_ac2_bare_analogy
  control CTRL.AC7.reword-always     mutate_and_expect_red chk_ac7_worktree       m_ac7_reword
  control CTRL.AC8c.restore-paren    mutate_and_expect_red chk_ac8c_parenthetical m_ac8c_restore_paren
  control CTRL.AC10a.move-outside    mutate_and_expect_red chk_ac10a_secops       m_ac10a_move_outside
  control CTRL.AC13.bare-token       mutate_and_expect_red chk_ac13_tokens        m_ac13_bare_token
  control CTRL.AC16.edit-span        mutate_and_expect_red chk_ac16               m_ac16_edit_span
  control CTRL.AC17.drop-data        mutate_and_expect_red chk_ac17_ba            m_ac17_drop_data
  control CTRL.AC10c.contrast        mutate_and_expect_red chk_ac10c_secops_wrap  m_ac10c_contrast
  control CTRL.AC3.marker-on-paragraph mutate_and_expect_red chk_ac3_survives    m_ac3_marker_on_paragraph
  control CTRL.AC4.outside-duty6     mutate_and_expect_red chk_ac4_vac            m_ac4_move_out_of_duty6
  control CTRL.AC5.outside-duty6     mutate_and_expect_red chk_ac5_trust          m_ac4_move_out_of_duty6
  control CTRL.AC8b.delete-that-half mutate_and_expect_red chk_ac8b_nopredicate   m_ac8b_delete_half
  control CTRL.AC9b.configured-path  mutate_and_expect_red chk_ac9b_floor_phrased m_ac9b_configured_path
  hdr 'TWO MORE EXPECTED SURVIVORS (a battery where everything reddens is a zero result about itself)'
  printf 'CTRL.AC3.marker-on-paragraph must leave AC1 GREEN -- the marker graft moves the\n'
  printf '  duty, not the floor literal, so the contract list is untouched:\n'
  c="$(mkcopy)"; m_ac3_marker_on_paragraph "$c"
  if chk_ac1_floor "$c"; then printf '  RESULT: AC1 survived, as expected. %s\n' "$D"
  else printf '  RESULT: *** AC1 died; the mutation is not the one I meant. *** %s\n' "$D"; CN_BAD=$((CN_BAD+1)); fi
  rm -rf "$c"
  printf 'CTRL.AC8b.delete-that-half must leave AC8a GREEN -- AC8 demands the two halves\n'
  printf '  be separately mutable, and a mutation that takes both cannot discriminate:\n'
  c="$(mkcopy)"; m_ac8b_delete_half "$c"
  if chk_ac8a_evaluators "$c"; then printf '  RESULT: AC8a survived, as expected. %s\n' "$D"
  else printf '  RESULT: *** AC8a died with AC8b; the two halves are NOT separately mutable. *** %s\n' "$D"; CN_BAD=$((CN_BAD+1)); fi
  rm -rf "$c"

  hdr 'THE ONE CONTROL EXPECTED TO SURVIVE'
  printf 'CTRL.AC7.expected-survivor -- reworded parenthetical, AC7 cell:\n'
  printf '  A battery where EVERYTHING reddens cannot distinguish real coverage from a harness\n'
  printf '  that reddens indiscriminately. AC8c mutation (restoring the original parenthetical)\n'
  printf '  MUST leave AC7 GREEN, because the bold sentence is byte-identical either way. That\n'
  printf '  is exactly why AC7 and AC8c are separate criteria.\n'
  c="$(mkcopy)"; m_ac8c_restore_paren "$c"
  if chk_ac7_worktree "$c"; then printf '  RESULT: AC7 survived the AC8c mutation, as expected. %s\n' "$D"
  else printf '  RESULT: *** AC7 DIED under the AC8c mutation. The two criteria are NOT independent; investigate. *** %s\n' "$D"; CN_BAD=$((CN_BAD+1)); fi
  rm -rf "$c"
  printf '\ncontrols: %d caught, %d not caught\n' "$CN_OK" "$CN_BAD"
  [ "$CN_BAD" -eq 0 ] || exit 1
  exit 0
fi

hdr 'AC1  the floor exists IN THE CONTRACT, and holds with no config file'
B=RED;   cell AC1.floor-in-bullet        chk_ac1_floor "$SRC"
B=GREEN; cell AC1.bullet-scoped          chk_ac1_scoped
B=GREEN; cell AC1.four-inputs-invariant  chk_ac1_inputs_invariant
B=RED;   cell AC1.four-inputs-pass       chk_ac1_inputs_pass

hdr 'AC2  the widen-only mechanism is STATED, and the ban is WORD-BOUNDED'
B=RED;   cell AC2.mechanism              chk_ac2_mechanism "$SRC"
B=GREEN; cell AC2.bare-ban               chk_ac2_bare_ban "$SRC"
B=GREEN; cell AC2.oracle                 chk_ac2_oracle

hdr 'AC3  the config read is a DUTY, not a comment'
B=RED;   cell AC3.survives-strip         chk_ac3_survives "$SRC"
B=GREEN; cell AC3.strip-is-surgical      chk_ac3_surgical "$SRC"

hdr 'AC4  all four degenerate inputs plus the no-cite clause, MUTATED SEPARATELY'
B=RED;   cell AC4a.which-file            chk_ac4 "$SRC" which-file
B=RED;   cell AC4a.not-plugin-cache      chk_ac4 "$SRC" not-cache
B=RED;   cell AC4b.absent                chk_ac4 "$SRC" absent
B=RED;   cell AC4c.unparseable           chk_ac4 "$SRC" unparse
B=RED;   cell AC4d.not-a-json-object     chk_ac4 "$SRC" notobject
B=RED;   cell AC4e.no-cite               chk_ac4 "$SRC" nocite
B=RED;   cell AC4f.resolves-to-floor     chk_ac4 "$SRC" resolution

hdr 'AC5  the trust premise, WITH its void condition'
B=RED;   cell AC5a.trust-premise         chk_ac5_trust "$SRC"
B=RED;   cell AC5b.void-condition        chk_ac5_void "$SRC"

hdr 'AC6  the twelve-cell matrix'
B=GREEN; cell AC6.on-disk-input-is-live  chk_ac6_live_input "$SRC"
B=SKIP;  if want AC6.matrix-recorded; then D=''; chk_ac6_matrix "$SRC"; case $? in
           0) ok AC6.matrix-recorded "$D";; 2) skip AC6.matrix-recorded "$D";; *) no AC6.matrix-recorded "$D";; esac; fi

hdr 'AC7  the bold sentence is byte-identical at both refs'
B=GREEN; cell AC7.worktree               chk_ac7_worktree "$SRC"
B=GREEN; if want AC7.origin-main; then D=''; chk_ac7_origin; case $? in
           0) ok AC7.origin-main "$D";; 2) skip AC7.origin-main "$D";; *) no AC7.origin-main "$D";; esac; fi
B=GREEN; cell AC7.oracle                 chk_ac7_oracle
B=GREEN; if want AC7.telemetry-suite; then
         if ! src_is_real_checkout "$SRC"; then
           skip AC7.telemetry-suite "--src $SRC is not a real git checkout with a .pipeline/ corpus; this suite walks the real corpus and reads 98/8 there on an UNMODIFIED tree"
         else
           out="$(CLAUDE_PLUGIN_ROOT="$SRC/plugins/pipeline" bash "$SRC/plugins/pipeline/tests/test-pipeline-telemetry.sh" 2>&1 | grep -E '^passed=' | tail -1)"
           D="tests/test-pipeline-telemetry.sh: $out (reference 107/0; AC32 asserts the bold sentence with assert_contains, so the PARENTHETICAL is unpinned and free to change)"
           case "$out" in 'passed=107 failed=0') ok AC7.telemetry-suite "$D";; *) no AC7.telemetry-suite "$D";; esac
         fi; fi

hdr 'AC8  three halves of the section, each separately mutable'
B=RED;   cell AC8a.evaluators-named      chk_ac8a_evaluators "$SRC"
B=RED;   cell AC8b.no-path-predicate     chk_ac8b_nopredicate "$SRC"
B=RED;   cell AC8c.parenthetical         chk_ac8c_parenthetical "$SRC"

hdr 'AC9  the post-BA validation clause, phrased against floor-plus-union'
B=RED;   cell AC9a.names-the-path        chk_ac9a_names_path "$SRC"
B=RED;   cell AC9b.floor-phrased         chk_ac9b_floor_phrased "$SRC"

hdr 'AC10 the backstop: SITED where it is read, ADDITIVE, and its LABEL claims only itself'
B=RED;   cell AC10a.secops-siting        chk_ac10a_secops "$SRC"
B=GREEN; cell AC10a.siting-oracle        chk_ac10a_oracle
B=RED;   cell AC10a.dev-presence         chk_ac10a_dev "$SRC"
B=GREEN; cell AC10b.axes-5x5             chk_ac10b_table "$SRC"
B=GREEN; cell AC10b.naive-is-dead        chk_ac10b_naive_dead "$SRC"
B=RED;   cell AC10c.secops-label         chk_ac10c "$SRC" secops
B=RED;   cell AC10c.dev-label            chk_ac10c "$SRC" dev
B=GREEN; cell AC10c.oracle               chk_ac10c_oracle

hdr 'AC11 the config-doctor reader string names both prose evaluators'
B=RED;   if want AC11a.names-both; then D=''; chk_ac11_both "$SRC"; case $? in
           0) ok AC11a.names-both "$D";; 2) skip AC11a.names-both "$D";; *) no AC11a.names-both "$D";; esac; fi
B=RED;   if want AC11b.not-prose-only; then D=''; chk_ac11_not_prose_only "$SRC"; case $? in
           0) ok AC11b.not-prose-only "$D";; 2) skip AC11b.not-prose-only "$D";; *) no AC11b.not-prose-only "$D";; esac; fi

hdr 'AC12 config-doctor --self-test stays at exactly 16'
B=GREEN; if want AC12.self-test-16; then D=''; chk_ac12 "$SRC"; case $? in
           0) ok AC12.self-test-16 "$D";; 2) skip AC12.self-test-16 "$D";; *) no AC12.self-test-16 "$D";; esac; fi

hdr 'AC13 no bare backticked sub-key in the SCANNED files'
B=GREEN; cell AC13a.no-bare-subkey       chk_ac13_tokens "$SRC"
B=GREEN; cell AC13a.extractor-oracle     chk_ac13_oracle
B=GREEN; if want AC13b.surfaces-suite; then D=''; chk_ac13_suite "$SRC"; case $? in
           0) ok AC13b.surfaces-suite "$D";; 2) skip AC13b.surfaces-suite "$D";; *) no AC13b.surfaces-suite "$D";; esac; fi

hdr 'AC14 run.sh green PER SUITE at a named reachable sha, with the window SAMPLED'
B=GREEN; cell AC14a.sha-reachability     chk_ac14_reach
B=GREEN; cell AC14b.per-suite-table      chk_ac14_suites
B=GREEN; cell AC14c.contamination        chk_ac14_contamination

hdr 'AC15 scope, with the .pipeline/ carve-out NAMED and nothing else'
B=GREEN; cell AC15a.owned-surface        chk_ac15_subset
B=GREEN; cell AC15b.parser-oracle        chk_ac15b_parser_oracle
B=GREEN; cell AC15b.pipeline-md-hunks    chk_ac15_hunks
B=GREEN; cell AC15c.carveout-still-bites chk_ac15_carveout_bites

hdr 'AC16 the ten-file replicated span still hashes to the published digest'
B=GREEN; cell AC16.ten-file-digest       chk_ac16 "$SRC"
B=GREEN; cell AC16.digest-oracle         chk_ac16_oracle

hdr 'AC17 BOTH prose floors still enumerate `data`'
B=GREEN; cell AC17a.ba-floor             chk_ac17_ba "$SRC"
B=GREEN; cell AC17b.pipeline-floor       chk_ac17_cmd "$SRC"
B=GREEN; cell AC17.oracle                chk_ac17_oracle "$SRC"

hdr 'D    locked-design conformance (design.json). NOT acceptance criteria.'
B=RED;   cell D1.dev-backstop-own-bullet chk_d1_dev_own_bullet "$SRC"
B=GREEN; cell D2.no-new-heading          chk_d2_no_new_heading
B=RED;   cell D3.secops-directly-after   chk_d3_secops_adjacent "$SRC"
B=RED;   cell D4.ba-marker-text          chk_d4_marker_text "$SRC"

# ---- summary ----------------------------------------------------------------
printf '\n=============================================================\n'
printf 'PASS %d   FAIL %d   SKIP %d\n' "$PASS_N" "$FAIL_N" "$SKIP_N"
if [ "$SURPRISE_N" -gt 0 ]; then
  printf '*** %d cell(s) declared base:GREEN and FAILED. Those are NOT the\n' "$SURPRISE_N"
  printf '*** contract: something unrelated to the missing implementation is\n'
  printf '*** wrong (a broken harness, a stale rebase, a fixture that rotted,\n'
  printf '*** or a concurrent session writing this worktree). Read them first.\n'
fi
[ -n "$FAILED" ] && printf 'not passing:%s\n' "$FAILED"

cat <<'EOF_MANUAL'

MANUAL -- what a zero exit from this file DOES NOT discharge:
  * AC1's actual criterion is a READING: "a reader who has only agents/ba.md,
    in a project with NO pipeline.config.json, tiers an ask that edits that file
    as architectural". This battery proves the mechanical half (the literal is
    in the contract list, and its presence is invariant across four live config
    inputs). Whether a reader ACTS on it is not mechanically checkable.
  * AC2's mechanism cell is a keyword check over duty 6, not a comprehension
    check. It cannot tell a correct widen-only sentence from a confused one.
  * AC4/AC5 are regex presence checks per clause. They prove five distinct
    things were said; they cannot judge whether each says the right thing.
  * AC6's twelve cells are APPLIED BY A READER to the rule as written. The
    battery audits the record and re-reads the one live input; it does not run
    the matrix, because there is nothing executable to run it against.
  * AC10(c)'s ban is three strings. A contrastive construction spelled any
    other way ("the rules above are enforced") passes this and fails the
    criterion.
  * AC11 requires the reader string to name the FILE:SECTION each evaluator
    lives in. The cell checks the two filenames only.
  * KNOWN RESIDUAL, NOT A CELL (design.json residual_risks #1): under the
    locked design the `# CUSTOMIZE:` marker STAYS on ba.md's mandatory-trigger
    line, so a CUSTOMIZE-line strip takes the FLOOR LITERAL to 0 even though
    AC3's read duty survives. That is an accepted residual with #76 as its
    seat, not a defect this battery reports. Do not "fix" it by moving the
    marker: that was measured as the minority convention (6 of 79) and
    rejected in design.json.
EOF_MANUAL

if [ "$FAIL_N" -eq 0 ] && [ "$SKIP_N" -eq 0 ]; then exit 0; fi
exit 1
