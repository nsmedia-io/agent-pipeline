#!/usr/bin/env bash
# #106, part 2 of 5: WHO is denied, for WHAT command, at WHICH phase.
#
# AC2  the origin term is agent_id PRESENCE, and the control reddens under its own mutation
# AC3  the orchestrator's own checkpoint commands, read out of the convention that writes them
# AC4  agent_type is still READ, and the namespace strip is load-bearing
# AC5  no role allowlist
# AC6  R3's over-refusal is pinned rather than assumed
# AC7  the forbidden set is a CLASS over flag semantics, with a negative population and quoting
# AC8  explicit-path staging is allowed whatever the path, including under a blanket flag
# AC9  mention is not invocation, paired per row
# AC10 the 18-cell cross product, no contradictions
# AC11 phase discrimination, all three Phase 4 literals asserted BEHAVIOURALLY
# AC17 the two stages agree, element-wise, over AC7's table and AC9's mentions
#
# EVERY ROW HERE FAILS AT THE REVIEWED COMMIT WITH `GATE-UNDECLARED`, ON ITS OWN LINE. There is no
# shared setup that can throw and turn the file into skips.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/timeout-bound-lib.sh"
require_node

make_temp_project 106 || exit 90
GATE_SCRATCH="$TEMP_PROJECT"
gate_cache_declaration

# ---- the standard record store: ONE in-flight record at '4-review' -----------------------------
P4="$TEMP_PROJECT/p4"
gate_inflight_status "$P4/.pipeline/106/status.json" "4-review"
P3="$TEMP_PROJECT/p3"
gate_inflight_status "$P3/.pipeline/106/status.json" "3-impl"

# verdict <project-root> <command> [payload key=value ...] -> prints deny|none|...
verdict() {
  local root="$1" cmd="$2"; shift 2
  gate_reset_env "$root"
  run_gate "$(gate_payload "$cmd" "$@")"
  printf '%s' "$GATE_DECISION"
}
# The subagent-originated default: agent_id PRESENT (R2's origin term), a seated panelist role.
sub_verdict() { verdict "$1" "$2" agent_id=sub-panelist-1 agent_type=pipeline:qa; }

# ===============================================================================================
# THE FORBIDDEN CLASS. Eleven ENUMERATED spellings -- which are FIXTURES OF A CLASS, not the rule
# (R7) -- each also under `cd x && `, `git -C <path>` and `git -c k=v`. Then the two rows that
# check the FLOOR: spellings nobody enumerated whose effect is identical. `git commit -aqm 'm'`
# was verified with real git to commit every tracked modification while matching none of the
# eleven, because git bundles short flags; a matcher built as a literal table passes all eleven
# and fails exactly there, which is the cell that separates a class from a list.
# ===============================================================================================
FORBIDDEN=(
  'git commit -a'
  'git commit -am "m"'
  'git commit --all'
  'git add -A'
  'git add --all'
  'git add .'
  'git add :/'
  'git add -u'
  'git add --update'
  'git stage -A'
  'git stage -u'
)
FLOOR_ROWS=(
  "git commit -aqm 'm'"
  'git add -Av'
)

# ===============================================================================================
suite "AC7: the forbidden class -- eleven enumerated spellings, bare"
# ===============================================================================================
for c in "${FORBIDDEN[@]}"; do
  assert_eq "DENY: $c" "$(sub_verdict "$P4" "$c")" "deny"
done

suite "AC7: the same eleven under \`cd <dir> && \`, \`git -C <path>\` and \`git -c k=v\`"
for c in "${FORBIDDEN[@]}"; do
  assert_eq "DENY (cd-prefixed): cd plugins && $c" \
    "$(sub_verdict "$P4" "cd plugins && $c")" "deny"
  assert_eq "DENY (git -C): ${c/git /git -C /tmp/other-tree }" \
    "$(sub_verdict "$P4" "${c/git /git -C /tmp/other-tree }")" "deny"
  assert_eq "DENY (git -c): ${c/git /git -c user.name=x }" \
    "$(sub_verdict "$P4" "${c/git /git -c user.name=x }")" "deny"
done

# ===============================================================================================
suite "AC7 METATEXT: a redirection or a comment is not a pathspec"
# ===============================================================================================
#
# THE SECOND FLOOR, AND IT SHIPPED BROKEN. `git add -A` was denied and `git add -A > /dev/null`
# was ALLOWED, along with ` 2>/dev/null`, ` >/dev/null 2>&1`, ` >>out.log` and ` # note` -- thirty
# of the sixty-six rows below. The tokenizer knew only `; & | newline ( )` as separators, so the
# redirection operator and its target, and every word of a trailing comment, arrived at the
# operand walk as ordinary words; one of them read as a PATHSPEC, and a pathspec is exactly the
# term that decides an `-A`/`-u` stage is narrow rather than blanket. The commit branch never
# consulted that term, which is why `git commit -a > /dev/null` kept denying and hid the hole.
#
# The two allow rows at the end are what stop the fix being "delete the pathspec term": a REAL
# narrowing operand must still narrow.
for c in "${FORBIDDEN[@]}" "${FLOOR_ROWS[@]}"; do
  for tail in ' > /dev/null' ' 2>/dev/null' ' >/dev/null 2>&1' ' >>out.log' ' # note'; do
    assert_eq "DENY (metatext appended): $c$tail" "$(sub_verdict "$P4" "$c$tail")" "deny"
  done
done
assert_eq "ALLOW is preserved: git add -u <path> > /dev/null (a real pathspec still narrows)" \
  "$(sub_verdict "$P4" 'git add -u plugins/pipeline/agents/dba.md > /dev/null')" "none"
assert_eq "ALLOW is preserved: git status --porcelain > /dev/null" \
  "$(sub_verdict "$P4" 'git status --porcelain > /dev/null')" "none"
assert_eq "ALLOW is preserved: git add foo#bar (a # INSIDE a word is not a comment)" \
  "$(sub_verdict "$P4" 'git add foo#bar')" "none"

# ===============================================================================================
suite "AC7 METATEXT: a LINE CONTINUATION is deleted, not escaped"
# ===============================================================================================
#
# THE SIXTH MEMBER OF THE SAME CLASS, AND THE TABLE ABOVE DID NOT CONTAIN IT. Round 2 closed
# redirection and comment -- two SPELLINGS -- and shipped 66 rows as proof the class was closed.
# `\<newline>` is the same defect: the tokenizer took it as an escaped literal newline, POSIX
# DELETES the pair before tokenizing, and the manufactured character became a phantom operand.
# One operand is the whole of the term that says an `-A`/`-u` stage was narrowed, so
# `git add -A \<newline> && git commit -m "x"` -- the most ordinary way an agent writes a
# multi-line command -- came back with NO decision at all while a real bash staged three files and
# committed them. `git commit -a \` kept denying, because the commit branch never consults the
# pathspec term, which is the same asymmetry that hid the redirection hole a round earlier.
#
# THE ROWS ARE POSITIONS, NOT EXAMPLES: after the final flag, between the subcommand and the flag,
# and as a bare trailing backslash with nothing behind it. Every one is applied to all thirteen
# commands, so a future spelling nobody enumerated inherits the coverage.
NLC=$'\n'
for c in "${FORBIDDEN[@]}" "${FLOOR_ROWS[@]}"; do
  for tail in " \\${NLC}  && echo done" ' \' " \\${NLC}"; do
    assert_eq "DENY (continuation appended): $(printf '%q' "$c$tail")" \
      "$(sub_verdict "$P4" "$c$tail")" "deny"
  done
  assert_eq "DENY (continuation between the subcommand and the flag): $(printf '%q' "${c/git /git \\${NLC} }")" \
    "$(sub_verdict "$P4" "${c/git /git \\${NLC} }")" "deny"
done
# The four ALLOW twins, so the fix cannot be "delete the pathspec term" or "deny any backslash".
assert_eq "ALLOW is preserved: git add -u <path> \\<newline> && echo done" \
  "$(sub_verdict "$P4" "git add -u plugins/pipeline/agents/dba.md \\${NLC} && echo done")" "none"
assert_eq "ALLOW is preserved: git status --porcelain \\<newline> && echo done" \
  "$(sub_verdict "$P4" "git status --porcelain \\${NLC} && echo done")" "none"
assert_eq "ALLOW is preserved: git add \\<newline> <path> (the continuation does not invent an operand or remove one)" \
  "$(sub_verdict "$P4" "git add \\${NLC} plugins/pipeline/agents/dba.md")" "none"
assert_eq "ALLOW is preserved: git add foo#bar \\ (a trailing backslash is not a stage)" \
  "$(sub_verdict "$P4" 'git add foo#bar \')" "none"
# The pair is DELETED, so the words either side of it JOIN into one the way the shell joins them.
assert_eq "DENY: git a\\<newline>dd -A (the continuation splices one word, it does not split two)" \
  "$(sub_verdict "$P4" "git a\\${NLC}dd -A")" "deny"
# THE GROUND TRUTH, recorded rather than assumed. Every command above was run through a REAL bash
# against a REAL scratch repository holding one modified tracked file and two untracked ones, and
# `git diff --cached --name-only` (plus the new commit's own file list, because a command that
# COMMITS leaves an index that matches HEAD and looks empty) was read back:
#   git add -A \<newline> && git commit -m "chore: x"  -> COMMITTED tracked.txt, untracked_a.txt,
#                                                        untracked_b.txt and named.txt
#   git add -A \  /  git add \<newline> -A  /  git a\<newline>dd -A  -> staged all four
#   git add -u \                                       -> staged tracked.txt
#   git add -u tracked.txt \<newline> && echo done     -> staged tracked.txt AND NOTHING ELSE
# so every deny above is a command that really does stage what its author did not name, and the
# allow twin really does stage only what it named.

# ===============================================================================================
suite "AC7 EMPTY OPERAND: a LITERAL empty string is not a pathspec"
# ===============================================================================================
#
# The same phantom, one layer down. `git add -A ''` read the empty string as a PATHSPEC and so as
# a narrowing, which credited the command with a restriction the shell never handed it. Measured
# against real git 2.x in a scratch repository: both spellings exit 128 with `fatal: empty string
# is not a valid pathspec` and stage NOTHING, so refusing them refuses no correct work -- while
# reading them as narrow is the same mistake that made a line continuation an operand.
#
# THE TITLE SAYS `LITERAL` BECAUSE THAT IS ALL THESE ROWS CONSTRUCT, and the first version of this
# block said "a word that names nothing narrows nothing" over exactly the same eight literal
# rows -- a general sentence over a specific fixture, which is what makes the next reader stop
# looking. The word that VANISHES rather than arriving empty is a different fixture and a much
# more dangerous one; it is the suite below, and it is not tested here.
for q in "''" '""'; do
  for c in 'git add -A' 'git add -u' 'git add --all' 'git stage -A'; do
    assert_eq "DENY (an empty operand is not a pathspec): $c $q" \
      "$(sub_verdict "$P4" "$c $q")" "deny"
  done
done
assert_eq "ALLOW is preserved: git add -u '<path>' (a QUOTED real path still narrows)" \
  "$(sub_verdict "$P4" "git add -u 'plugins/pipeline/agents/dba.md'")" "none"
assert_eq "ALLOW is preserved: git add '' (no blanket flag, so nothing is staged blanket either)" \
  "$(sub_verdict "$P4" "git add ''")" "none"

# ===============================================================================================
suite "AC7 OPAQUE OPERAND: a word the shell has not resolved yet cannot narrow anything"
# ===============================================================================================
#
# THE HALF THAT ACTUALLY STAGES FILES, and the block above closed the other one. The two are the
# same sentence and opposite in effect: `git add -A ''` hands git an EMPTY ARGUMENT, which git
# refuses (exit 128, nothing staged), while `git add -A $CHANGED` with CHANGED unset or empty
# hands git NO ARGUMENT AT ALL -- the word is deleted before git is executed -- and that is a full
# blanket stage. Refusing the literal prevented no staging; the vanishing one is the ordinary
# shape an agent writes, and it fires EXACTLY WHEN THE VARIABLE CAME BACK EMPTY, which is
# precisely when its author did not mean to stage everything.
#
# THE ROWS ARE THE CLASS, NOT SPELLINGS OF IT. POSIX sh introduces a substitution with exactly two
# characters, `$` and the backquote, and the operand column below walks every syntactic form each
# one takes: bare name, braced, braced-with-default, command substitution in both its spellings,
# arithmetic, the backquoted form, the double-quoted form, and two in a row. It is a CROSS with
# two POSITIONS -- as an ordinary operand and behind `--`, where the scanner takes a different
# branch and every word is an operand -- over all thirteen commands. A gate that closed one
# spelling, or closed one of the two branches, passes its own row and fails the rest: the two
# branches were separately mutated and each reddened only its own cells.
OPAQUE_OPERANDS=(
  '$NOPE'
  '${NOPE}'
  '${NOPE:-}'
  '$(true)'
  '$(echo)'
  '`true`'
  '"$NOPE"'
  '$NOPE $NOPE'
  '$(( 1 - 1 ))'
)
for c in "${FORBIDDEN[@]}" "${FLOOR_ROWS[@]}"; do
  for pos in '' '-- '; do
    for op in "${OPAQUE_OPERANDS[@]}"; do
      assert_eq "DENY (opaque operand appended): $c $pos$op" \
        "$(sub_verdict "$P4" "$c $pos$op")" "deny"
    done
  done
done
# THE TEST SITS AT THE OPERAND POSITION AND NOWHERE ELSE. A word that opens with a dash is read
# for its FLAG letters whatever follows them, so skipping an opaque word wholesale would have
# traded one phantom operand for a LOST BLANKET FLAG -- `git add -A$X` is `-A` however X resolves.
assert_eq "DENY: git add -A\$X (an expansion attached to a flag cluster does not erase the flag)" \
  "$(sub_verdict "$P4" 'git add -A$X')" "deny"
assert_eq "DENY: git commit -a\$X (the same, on the commit branch)" \
  "$(sub_verdict "$P4" 'git commit -a$X')" "deny"
assert_eq "DENY: git commit -a\`true\` (the same, in the backquoted spelling)" \
  "$(sub_verdict "$P4" 'git commit -a`true`')" "deny"
# `--$X` is NOT end-of-options, and the row below says so because the verdict alone cannot: only
# the exact two-character word `--` sets it, and `--$X` falls to the unknown-long-option arm, which
# ignores the word and leaves the already-read `-A` standing. The two rows after it are the
# DISCRIMINATOR that earns the sentence -- if `--$X` opened end-of-options, the word after it would
# be read as an OPERAND and would narrow.
assert_eq "DENY: git add -A --\$X (\`--\` with an expansion attached is an unknown long option, not end-of-options; the blanket -A stands)" \
  "$(sub_verdict "$P4" 'git add -A --$X')" "deny"
assert_eq "DISCRIMINATOR (positive control): git add -A -- -u (a REAL \`--\` does make the next word an operand, so this narrows)" \
  "$(sub_verdict "$P4" 'git add -A -- -u')" "none"
assert_eq "DISCRIMINATOR: git add -A --\$X -u (\`-u\` is still read as a FLAG, so \`--\$X\` did not open end-of-options)" \
  "$(sub_verdict "$P4" 'git add -A --$X -u')" "deny"

# THE FALSIFICATION HALF, so the fix cannot be "deny every operand carrying a dollar sign". A
# REAL narrowing operand must still narrow, INCLUDING when an opaque word stands beside it.
assert_eq "ALLOW is preserved: git add -A <path> \$NOPE (a real pathspec beside an opaque word still narrows)" \
  "$(sub_verdict "$P4" 'git add -A plugins/pipeline/agents/dba.md $NOPE')" "none"
assert_eq "ALLOW is preserved: git add -u <path> (untouched)" \
  "$(sub_verdict "$P4" 'git add -u plugins/pipeline/agents/dba.md')" "none"
assert_eq "ALLOW is preserved: git add -A file.txt (untouched)" \
  "$(sub_verdict "$P4" 'git add -A file.txt')" "none"
assert_eq "ALLOW is preserved: git status --porcelain (untouched)" \
  "$(sub_verdict "$P4" 'git status --porcelain')" "none"
assert_eq "ALLOW is preserved: git add foo#bar (untouched)" \
  "$(sub_verdict "$P4" 'git add foo#bar')" "none"
# THE DISCLOSED RESIDUAL, asserted so it is a decision and not a silence. An opaque word is
# refused the power to NARROW; it is NOT credited with the power to BLANKET, because crediting it
# would refuse `git add $FILE` -- what an agent staging a computed path actually writes. So
# `git add $X` with X set to `.` is not seen. That is the deliberate half: an empty expansion is
# an ACCIDENT its author did not intend, while `X=.` is a blanket stage its author chose, and a
# gate that reads command TEXT never claimed to refuse a stage somebody meant to write.
assert_eq "ALLOW, disclosed residual: git add \$X (no blanket flag, so there is nothing to narrow)" \
  "$(sub_verdict "$P4" 'git add $X')" "none"
assert_eq "ALLOW, disclosed residual: git add \${X} (same, braced)" \
  "$(sub_verdict "$P4" 'git add ${X}')" "none"

# ---- THE ORACLE: what a REAL SHELL hands git, run rather than asserted from memory -------------
#
# Every row above is a claim about ARGV, and argv is not visible in the command text -- which is
# the whole defect. So the claim is MEASURED here rather than recorded in a comment: a recording
# `git` shim goes first on PATH, /bin/sh runs the identical string, and the shim writes back the
# argument count the shell really produced. Its own NON-ZERO CONTROL is the literal-path row,
# which must come back with one MORE argument than the vanishing one; without that, "2 arguments"
# and "the shim was never reached" are the same reading.
#
# THESE NINE ROWS ARE NOT COVERAGE OF THE HOOK, AND THAT IS RECORDED SO NOBODY COUNTS THEM AS IT.
# They assert a property of /bin/sh, so every hook mutation SURVIVES them by construction: with
# the opacity arm reverted to its literal-empty-only form, 63 verdict rows above went red and all
# nine of these stayed green. What they pin is the fixture population's PREMISE -- that the rows
# above really do construct a vanishing word -- which is the half a green suite cannot otherwise
# tell from a row that was never dangerous.
GATE_SHIM_DIR="$TEMP_PROJECT/argv-shim"
mkdir -p "$GATE_SHIM_DIR"
cat > "$GATE_SHIM_DIR/git" <<'SHIMEOF'
#!/bin/sh
printf '%s' "$#" > "$GIT_SHIM_LOG"
for a in "$@"; do printf ' [%s]' "$a" >> "$GIT_SHIM_LOG"; done
exit 0
SHIMEOF
chmod +x "$GATE_SHIM_DIR/git"
real_argv() {  # <command string> -> "<argc> [arg] [arg] ..." or "(git never invoked)"
  export GIT_SHIM_LOG="$TEMP_PROJECT/argv-shim.log"
  : > "$GIT_SHIM_LOG"
  env -u NOPE -u X -u CHANGED PATH="$GATE_SHIM_DIR:$PATH" /bin/sh -c "$1" >/dev/null 2>&1
  local out; out="$(cat "$GIT_SHIM_LOG" 2>/dev/null)"
  [[ -n "$out" ]] && printf '%s' "$out" || printf '(git never invoked)'
}
assert_eq "ORACLE VACUITY: the shim is reached at all, so an argument count is a reading and not a silence" \
  "$(real_argv 'git add -A')" "2 [add] [-A]"
assert_eq "ORACLE NON-ZERO CONTROL: a LITERAL path really does reach git as a third argument" \
  "$(real_argv 'git add -A file.txt')" "3 [add] [-A] [file.txt]"
assert_eq "ORACLE: an unset variable's word is DELETED, not passed empty -- git sees a bare blanket stage" \
  "$(real_argv 'git add -A $NOPE')" "2 [add] [-A]"
assert_eq "ORACLE: the braced spelling is deleted the same way" \
  "$(real_argv 'git add -A ${NOPE}')" "2 [add] [-A]"
assert_eq "ORACLE: an empty command substitution is deleted the same way" \
  "$(real_argv 'git add -A $(true)')" "2 [add] [-A]"
assert_eq "ORACLE: the backquoted spelling is deleted the same way" \
  "$(real_argv 'git add -A `true`')" "2 [add] [-A]"
assert_eq "ORACLE: a WHITESPACE-ONLY value is deleted too (field splitting, not emptiness)" \
  "$(real_argv 'WS="   "; git add -A $WS')" "2 [add] [-A]"
assert_eq "ORACLE: behind \`--\` the vanishing word leaves git with end-of-options and no pathspec" \
  "$(real_argv 'git add -A -- $NOPE')" "3 [add] [-A] [--]"
# THE ASYMMETRY THAT SAYS WHICH HALF MATTERED. The literal empty string ARRIVES, as an empty
# third argument git then refuses; the expansion does not arrive at all.
assert_eq "ORACLE: the LITERAL empty string arrives as a real (empty) argument, which is why git can refuse it" \
  "$(real_argv "git add -A ''")" "3 [add] [-A] []"
# GROUND TRUTH ON A REAL REPOSITORY, recorded from a run against real git 2.x in a scratch tree
# holding one modified tracked file and two untracked ones, with the variables unset:
#   git add -A $NOPE / ${NOPE} / ${NOPE:-} / $(true) / $(echo) / `true` / -- $NOPE
#                                     -> exit 0, staged tracked.txt, untracked_a.txt, untracked_b.txt
#   EMPTY=""; git add -A $EMPTY       -> exit 0, staged all three
#   WS="   "; git add -A $WS          -> exit 0, staged all three
#   git add -A ''                     -> exit 128, staged NOTHING
#   git add -A plugins/... $NOPE      -> exit 128, staged NOTHING (it narrowed to the named path)
# so every deny above is a command that really does stage what its author did not name, and the
# allow twin really does narrow.

# ---- THE DISCLOSED OVER-DENIAL, asserted for the same reason the residual above is ------------
#
# BOTH HALVES OF ONE TRADE-OFF, OR NEITHER. The under-denial (`git add $X` is not credited with the
# power to blanket) gets two ALLOW cells above, and they bite: a mutation that credits an opaque
# operand with blanketing reddens them. The over-denial had only prose, so a later change that
# widened or narrowed it would redden nothing. These rows are that missing half.
#
# WHAT IS OVER-DENIED, and it is not the two exit-128 curiosities an earlier note named. A blanket
# flag beside an operand carrying a substitution is refused EVEN WHEN THE SUBSTITUTION RESOLVES to
# a real path and the command would have staged a correctly narrowed set. Ground truth from real
# git 2.x in a scratch repository holding a modified `packages/pipeline/a.txt`, an untracked
# `packages/pipeline/new.txt` and an untracked `outside.txt`:
#   PKG=pipeline; git add -A packages/$PKG      -> rc 0, staged packages/pipeline/{a,new}.txt only
#   F=packages/pipeline/a.txt; git add -u "$F"  -> rc 0, staged exactly that one file
#   git add -A                       (control)  -> rc 0, staged all three, INCLUDING outside.txt
# The first two are correct narrowed work and this gate refuses them. That is accepted, because
# `$F` holding a path and `$F` holding nothing are the same text to a scanner that never sees argv.
# The rows are here so the acceptance is a decision the suite defends, not a sentence.
assert_eq "DENY, disclosed OVER-denial: git add -A packages/\$PKG (the expansion RESOLVES; a real shell stages two files at rc 0 and this refuses it)" \
  "$(sub_verdict "$P4" 'git add -A packages/$PKG')" "deny"
assert_eq "DENY, disclosed OVER-denial: PKG=pipeline; git add -A packages/\$PKG (the assignment stands in the same command line and still does not make the word readable)" \
  "$(sub_verdict "$P4" 'PKG=pipeline; git add -A packages/$PKG')" "deny"
assert_eq "DENY, disclosed OVER-denial: git add -u \"\$F\" (a real shell stages exactly the one file F names, rc 0)" \
  "$(sub_verdict "$P4" 'git add -u "$F"')" "deny"
# THE TWO REWRITES THAT ARE ALLOWED, which is what bounds the cost of the three denies above -- and
# they are also the falsification half: if these went red the deny would be bought by the command
# SHAPE rather than by the expansion, and the over-denial would be far wider than stated.
assert_eq "OVER-DENIAL BOUND: git add -A packages/pipeline (the same stage with the path written LITERALLY is allowed)" \
  "$(sub_verdict "$P4" 'git add -A packages/pipeline')" "none"
assert_eq "OVER-DENIAL BOUND: git add \"\$DIR\" (dropping the blanket flag is the other rewrite the deny leaves open)" \
  "$(sub_verdict "$P4" 'git add "$DIR"')" "none"
# AND THE ARGV THAT MAKES THE THREE DENIES AN OVER-DENIAL RATHER THAN A CORRECT REFUSAL, measured
# by the same shim rather than asserted: the word the scanner could not read arrives at git as a
# real, narrowing pathspec. Without these two rows the block above would be indistinguishable from
# three rows that refuse nothing.
assert_eq "ORACLE: the over-denied operand RESOLVES -- git really is handed a narrowing pathspec" \
  "$(real_argv 'PKG=pipeline; git add -A packages/$PKG')" "3 [add] [-A] [packages/pipeline]"
assert_eq "ORACLE: the quoted form resolves too, to exactly one pathspec" \
  "$(real_argv 'F=packages/pipeline/a.txt; git add -u "$F"')" "3 [add] [-u] [packages/pipeline/a.txt]"

# ===============================================================================================
suite "AC7 LENGTH AXIS: a forbidden command stays forbidden however long its operand is"
# ===============================================================================================
#
# THE BYPASS THIS PINS WAS LIVE. `git commit -a -m "chore: checkpoint"` was denied in 0.157 s;
# the same command with 2500 characters appended to the message took 5.014 s, was killed at the
# `timeout` hooks.json declares, produced nothing on stdout, and a PreToolUse hook that produces
# nothing FAILS OPEN -- so the identical forbidden staging was ALLOWED. The tokenizer was
# quadratic in command length, so a longer commit message, which is ordinary correct work, was
# sufficient. Length is not a privilege and must not buy a bypass.
#
# The bound is the DECLARED timeout, read from hooks.json rather than transcribed, because that
# is the value the runtime actually kills at -- not a ratio to a floor, which would be a threshold
# on this host. The verdict rows are the real assertion; the elapsed row is what says WHY when
# they go red, and it is asserted rather than only recorded.
LEN_TIMEOUT_S="$(gate_declared_timeout)"
[[ "$LEN_TIMEOUT_S" =~ ^[0-9]+$ ]] || LEN_TIMEOUT_S=0
BYPASS_BOUND_MS=$(( LEN_TIMEOUT_S * 1000 ))
assert_eq "VACUITY: hooks.json declares a positive PreToolUse timeout to bound against (read, not transcribed): ${LEN_TIMEOUT_S}s" \
  "$([[ "$BYPASS_BOUND_MS" -gt 0 ]] && echo declared || echo "MISSING: [$LEN_TIMEOUT_S]")" "declared"

# ---- THE SECOND BOUND, AND WHY IT IS NOT THE FIRST ONE TIMES A CONSTANT (#132) -----------------
#
# The four timing blocks below (LENGTH, WORD-BOUNDARY, DENSITY, DENSITY-GROWTH) used to apply ONE
# bound, `LEN_BOUND_MS=$(( LEN_TIMEOUT_S * 1000 ))`, read from the declaration. That is the right
# bound for the question "did this call get KILLED", and it is the wrong bound for the question
# "did this gate get SLOWER", and the two have different remedies. Leaving them merged means the
# one-integer edit in hooks.json that #132 makes -- 5 to 30 -- silently widens all four regression
# guards by a factor of six, with nothing anywhere going red to say so. So the two are separated:
#
#   BYPASS       -- over the DECLARED timeout. The runtime kills the hook there, it emits nothing,
#                   and a PreToolUse hook that emits nothing FAILS OPEN, so the forbidden staging
#                   is ALLOWED. This is a security failure and it moves with hooks.json.
#   REGRESSION   -- over the ABSOLUTE budget below. The gate still decided, and still refused, but
#                   it took longer than its recorded derivation permits. This is a performance
#                   failure, it does not move with hooks.json, and it is the guard #116's linear
#                   scan is held to.
#
# THE BUDGET IS ABSOLUTE AND ITS DERIVATION IS RECORDED HERE. Every probe below pays two node
# starts and a resolver run before it reads a byte of the command, so the figure is a whole-probe
# wall clock and not a scan cost. Worst observed per block, min-of-3 where a block runs more than
# one cell:
#
#   MEASURED ON darwin 25.5.0 / bash 3.2.57(1) in sh mode / node v24.19.0, at load 2.57-2.79:
#     LENGTH 397 ms, WORD-BOUNDARY 1147 ms, DENSITY 982 ms,
#     DENSITY-GROWTH 1028 ms.
#     Command: bash plugins/pipeline/tests/run.sh (this suite reads its own `record` lines back).
#
#   MEASURED ON ubuntu-latest, WHICH IS THE HOST THE GUARD IS EVALUATED ON.
#   .github/workflows/tests.yml:17,60 runs `bash plugins/pipeline/tests/run.sh` on ubuntu-latest
#   for every pull_request and every push to main, so these four blocks execute there on every
#   change and the figures below were read off that run rather than estimated from the darwin ones:
#     LENGTH 119 ms, WORD-BOUNDARY 175 ms, DENSITY 154 ms,
#     DENSITY-GROWTH 156 ms.
#     Command: bash plugins/pipeline/tests/run.sh, on ubuntu-latest, run id 33747342504 (Linux
#     6.17.0-1022-azure, load 2.00). The earlier run 33744488416 of the same four blocks read
#     174/265/205/214 ms; both are recorded because the spread between two runs of one host is the
#     thing a single figure hides. ubuntu-latest is FASTER than the darwin host above by roughly
#     3x to 6x on these blocks, not slower, so the budget's binding constraint is darwin.
#
# WHY 5000 AND NOT A ROUNDED MULTIPLE OF THE WORST FIGURE. It is the millisecond value these four
# guards effectively carried before this change, when the declaration they read was the superseded
# 5 s -- so the number is a historical one deliberately frozen. Pinning it there
# makes the property structural rather than numerical: raising hooks.json cannot widen these four
# guards, because the number they compare against is the one they already had. It also sits above
# every figure recorded above with a stated margin -- 4.4x the worst darwin block -- rather than
# padded to cover a host nobody measured, because padding blind is the same loss of discrimination
# the separation exists to prevent. A red on a REGRESSION row means the scan got slower; a red on a
# BYPASS row means a call is falling open.
REGRESSION_BUDGET_MS=5000
record "REGRESSION BUDGET: ${REGRESSION_BUDGET_MS} ms absolute, declared separately from the ${LEN_TIMEOUT_S}s (${BYPASS_BOUND_MS} ms) bypass bound read from hooks.json, on $(uname -sr) at load $(uptime | sed 's/.*averages*: //')"

len_now_ms() { "$GATE_REAL_NODE" -e 'process.stdout.write(String(Date.now()))'; }
LEN_WORST_MS=0
LEN_SLOW=""
LEN_REGRESS=""
len_probe() {  # <label> <command> <expected-verdict>
  local a b el
  a="$(len_now_ms)"
  local v; v="$(sub_verdict "$P4" "$2")"
  b="$(len_now_ms)"
  el=$(( b - a ))
  [[ "$el" -gt "$LEN_WORST_MS" ]] && LEN_WORST_MS="$el"
  [[ "$el" -lt "$BYPASS_BOUND_MS" ]] || LEN_SLOW="$LEN_SLOW
$1 -> ${el} ms"
  [[ "$el" -lt "$REGRESSION_BUDGET_MS" ]] || LEN_REGRESS="$LEN_REGRESS
$1 -> ${el} ms"
  assert_eq "AC7 LENGTH: $1 -> $3" "$v" "$3"
}

for n in 200 1000 2000 4000 8000 32000; do
  PAD="$("$GATE_REAL_NODE" -e 'process.stdout.write("y".repeat(Number(process.argv[1])))' "$n")"
  len_probe "git commit -a with a ${n}-char -m operand" "git commit -a -m \"chore: checkpoint $PAD\"" "deny"
  len_probe "git add -A with a ${n}-char trailing comment" "git add -A # $PAD" "deny"
  # The paired ALLOW at the same length, so the rows above cannot be satisfied by a gate that
  # denies everything once a command gets long.
  len_probe "git add <path> with a ${n}-char -m operand" \
    "git add plugins/pipeline/agents/dba.md && git commit -m \"chore: $PAD\"" "none"
done
assert_eq "AC7 LENGTH BYPASS: every probe above returned inside the ${LEN_TIMEOUT_S}s the declaration commits to (worst ${LEN_WORST_MS} ms). A hook killed at its declared timeout emits nothing and the call is ALLOWED, so a row over this bound is a BYPASS, not a slow test" \
  "$LEN_SLOW" ""
assert_eq "AC7 LENGTH REGRESSION: and inside the ${REGRESSION_BUDGET_MS} ms absolute budget this suite derives for itself (worst ${LEN_WORST_MS} ms). A row over THIS bound is a REGRESSION -- the gate still decided and still refused, it just got slower than its derivation permits -- and its remedy is the scan, not hooks.json" \
  "$LEN_REGRESS" ""
record "LENGTH AXIS worst observed: ${LEN_WORST_MS} ms against a bypass bound of ${BYPASS_BOUND_MS} ms and a regression budget of ${REGRESSION_BUDGET_MS} ms, on $(uname -sr)"

# ===============================================================================================
suite "AC7 WORD-BOUNDARY AXIS: the cost is driven by boundary COUNT, and the block above cannot see it"
# ===============================================================================================
#
# WHY THE LENGTH AXIS ABOVE IS NOT SUFFICIENT, STATED AS THE REASON THIS BLOCK EXISTS. Every pad
# it builds is `"y".repeat(n)` -- one unbroken run of one character -- so its word-boundary count
# is O(1) at every n. The scan cost is (number of cursor moves) x (remaining length), and a cursor
# move happens per WORD BOUNDARY, not per character; so all eighteen probes above sit in the one
# cell of the cost model that round 2 fixed, and the whole of the surviving quadratic lived where
# they could not reach. Every fixture in that block was green while `echo <5000 short words> ;
# git add -A` took 6273 ms in the scan alone -- with no git invocation needed to reach the cost --
# crossed the declared timeout, was killed, and let the staging on the far side of the `;` through.
#
# Three shapes, because they are three different boundary sources and the fix had to be different
# for each: many WORDS ahead of the staging invocation, many OPERANDS to one git invocation, and
# many LINES (an agent writing a document with a heredoc and staging it in the same Bash call --
# the shape SecOps reached without trying to, at 8399 ms).
#
# THE BOUND IS THE SAME DECLARED TIMEOUT and for the same reason: it is the value the runtime
# actually kills at, not a ratio to a floor, which would be a threshold on this host. The growth
# figures are RECORDED rather than asserted for that reason -- a multiple would measure the runner.
WB_WORST_MS=0
WB_SLOW=""
WB_REGRESS=""
wb_probe() {  # <label> <command> <expected-verdict>
  local a b el v
  a="$(len_now_ms)"
  v="$(sub_verdict "$P4" "$2")"
  b="$(len_now_ms)"
  el=$(( b - a ))
  [[ "$el" -gt "$WB_WORST_MS" ]] && WB_WORST_MS="$el"
  [[ "$el" -lt "$BYPASS_BOUND_MS" ]] || WB_SLOW="$WB_SLOW
$1 -> ${el} ms"
  [[ "$el" -lt "$REGRESSION_BUDGET_MS" ]] || WB_REGRESS="$WB_REGRESS
$1 -> ${el} ms"
  WB_LAST_MS="$el"
  assert_eq "AC7 BOUNDARY: $1 -> $3" "$v" "$3"
}
# wb_pad <n> <mode> -> n whitespace-separated tokens (mode=words|paths|lines)
wb_pad() {
  "$GATE_REAL_NODE" -e '
    const n = Number(process.argv[1]), mode = process.argv[2];
    const w = Array.from({ length: n }, (_, i) => (mode === "paths" ? "p" + i + ".txt" : "w" + (i % 97)));
    if (mode !== "lines") { process.stdout.write(w.join(" ")); }
    else {
      const out = [];
      for (let i = 0; i < w.length; i += 12) out.push(w.slice(i, i + 12).join(" "));
      process.stdout.write(out.join("\n"));
    }
  ' "$1" "$2"
}
WB_GROWTH=""
for n in 500 2000 8000; do
  WORDS="$(wb_pad "$n" words)"
  # THE FIXTURE'S OWN CONTROL, and it is the one this block exists for: assert the pad really
  # carries n boundaries. Without it a future edit could quietly turn this into another
  # `"y".repeat(n)` axis and the suite would stay green over the defect it was written to catch.
  assert_eq "AC7 BOUNDARY VACUITY: the ${n}-word pad really carries ${n} whitespace-separated tokens (a single-run pad would make every row below unfalsifiable)" \
    "$(printf '%s' "$WORDS" | tr ' ' '\n' | grep -c .)" "$n"
  wb_probe "echo <${n} short words> ; git add -A" "echo $WORDS ; git add -A" "deny"
  [[ "$n" == 8000 ]] && WB_GROWTH="$WB_GROWTH words@8000=${WB_LAST_MS}ms"
  [[ "$n" == 500 ]] && WB_GROWTH="$WB_GROWTH words@500=${WB_LAST_MS}ms"
  # The paired ALLOW: the same boundary count in front of a command that names its paths.
  wb_probe "echo <${n} short words> ; git add <path>" \
    "echo $WORDS ; git add plugins/pipeline/agents/dba.md" "none"

  PATHS="$(wb_pad "$n" paths)"
  # Many OPERANDS to ONE git invocation. The blanket-pathspec row settles at the `.`; the explicit
  # row has to walk all n and is the shape the staging discipline this gate enforces produces.
  wb_probe "git add . <${n} operands>" "git add . $PATHS" "deny"
  wb_probe "git add <${n} explicit paths> && git commit -a" \
    "git add $PATHS && git commit -a -m 'chore: x'" "deny"
  wb_probe "git add <${n} explicit paths>" "git add $PATHS" "none"

  LINES="$(wb_pad "$n" lines)"
  # Many LINES: an ordinary heredoc document written and staged in the same Bash call.
  wb_probe "heredoc with a ${n}-word body, then git add -A" \
    "cat > notes.md <<'EOF'
$LINES
EOF
git add -A" "deny"
  wb_probe "heredoc with a ${n}-word body, then git add <path>" \
    "cat > notes.md <<'EOF'
$LINES
EOF
git add plugins/pipeline/agents/dba.md" "none"
done
assert_eq "AC7 BOUNDARY BYPASS: every probe above returned inside the ${LEN_TIMEOUT_S}s the declaration commits to (worst ${WB_WORST_MS} ms). This is the axis that was live at the reviewed commit: a hook killed at its declared timeout emits nothing and the call is ALLOWED, so a row over this bound is a BYPASS" \
  "$WB_SLOW" ""
assert_eq "AC7 BOUNDARY REGRESSION: and inside the ${REGRESSION_BUDGET_MS} ms absolute budget (worst ${WB_WORST_MS} ms). Over THIS bound the gate still decided and the failure is a REGRESSION in the scan, not a bypass" \
  "$WB_REGRESS" ""
# WHAT THE MARGIN ABOVE IS A MARGIN OVER, said plainly so it is not read as more than it is. Every
# pad here is quote-free -- `wb_pad` emits `w<n>` tokens, so its densest mode is one newline per
# ~48 bytes. This record therefore says the BOUNDARY-COUNT mechanism is closed and says nothing
# about structural DENSITY, which is #116's and is the block below.
record "WORD-BOUNDARY AXIS worst observed: ${WB_WORST_MS} ms against a bypass bound of ${BYPASS_BOUND_MS} ms and a regression budget of ${REGRESSION_BUDGET_MS} ms over a QUOTE-FREE population (density is the block below), on $(uname -sr);${WB_GROWTH}"

# ===============================================================================================
suite "AC7 DENSITY AXIS (#116): at FIXED length, cost must not follow structural density"
# ===============================================================================================
#
# WHY EVERY BLOCK ABOVE IS BLIND TO THIS, WHICH IS THE REASON THIS ONE EXISTS. The LENGTH AXIS pads
# with `"y".repeat(n)` -- one unbroken run, O(1) structural characters at every n. The WORD-BOUNDARY
# AXIS pads with quote-free `w<n>` tokens -- one newline per ~48 bytes, the CHEAPEST structural
# class anyone writes. Both vary the SIZE of the command and neither varies its DENSITY, and the
# scan's cost was (structural characters) x (length): a product, not a sum. So a body a quarter the
# size of a green cell above crossed the same declared bound, purely because it carried quotes.
#
# Measured against the shipped hook before the bounded window: quote-dense text crossed the
# declared 5 s at ~12 KB, ordinary JSON at ~29 KB and quote-free prose at ~117 KB -- an 8x range in
# SIZE for one mechanism, which is why publishing a size was the wrong unit. This block fixes the
# length and moves density instead, over classes an agent really writes.
#
# THREE THINGS ARE ASSERTED AND EACH ONE FAILS DIFFERENTLY.
#
#   1. Every cell returns inside the DECLARED timeout, read from hooks.json. That is the bound the
#      runtime actually kills at, so a cell over it is a bypass and not a slow test.
#   2. The cells' MARGINAL costs -- each cell minus a same-run floor measured through the identical
#      path -- sit inside a bounded factor of each other. This is the property: cost must be linear
#      in LENGTH and blind to DENSITY. A cost that still followed the product would spread by
#      roughly the density span, which the vacuity row below asserts is over 100x.
#   3. The same factor is bounded BELOW as well as above. A spread of 1.0 would mean the instrument
#      is measuring its own floor and the row above is unfalsifiable, so the cells must differ
#      measurably from each other as well as not differ hugely.
#
# THE LENGTH IS SIZED FOR THE RUNNER AND NOT FOR THE DEFECT, and saying so is the honest half of
# this block. Every probe here pays the whole gate -- two node starts and a resolver run -- and the
# same-run floor recorded below measured 447 ms on an idle host and 922 ms on the same host under
# load. At 12 KB the densest cells then read 3183 ms idle and 6474 ms loaded, so a fixture that
# discriminated hardest would also be the one that went red on a busy shared runner for a gate that
# was working. 6 KB is what fits with margin. The consequence, stated rather than hidden: these
# timing rows would not by themselves have caught the defect at the reviewed commit, which crossed
# the same bound from about 12 KB of this shape. The DISCRIMINATING evidence for this issue is the
# 38864-row old-versus-new differential and the density-by-length matrix recorded in #116 and #132;
# what this block gives the tree afterwards is the axis itself -- six structural classes at one
# fixed length, each with its verdict and its bound -- so the next change cannot be green over
# density the way both axes above were.
DENS_TARGET=6144
dens_pad() { # <kind> <bytes> -> a body of exactly that length in the named structural class
  "$GATE_REAL_NODE" -e '
    const kind = process.argv[1], n = Number(process.argv[2]);
    const mk = {
      // one double quote per two bytes: the densest thing an agent writes
      quotes: () => "\"a\" ".repeat(Math.ceil(n / 4)),
      // minified JSON: dense AND carrying no whitespace at all, so it is one word to a splitter
      minified: () => "{\"k\":\"v\",\"n\":1},".repeat(Math.ceil(n / 16)),
      // pretty-printed JSON, the shape this pipeline writes its own artifacts in
      json: () => { const r = []; while (r.join("\n").length < n) r.push(`  "field${r.length}": "value ${r.length}",`); return r.join("\n"); },
      // source code: quotes, parentheses, semicolons and comment marks together
      code: () => { const r = []; while (r.join("\n").length < n) r.push(`const x${r.length} = f(a, "b"); // note`); return r.join("\n"); },
      // quote-free prose: the WORD-BOUNDARY AXIS population, here as the sparse end of this one
      prose: () => { const w = []; for (let i = 0; i < n; i++) w.push("w" + (i % 97)); const L = []; for (let i = 0; i < w.length; i += 12) L.push(w.slice(i, i + 12).join(" ")); return L.join("\n"); },
      // one unbroken run: the LENGTH AXIS population, here as the O(1)-structure extreme
      run: () => "y".repeat(n),
    };
    // THE TRUNCATION USED TO BALANCE QUOTE PARITY, AND THAT WAS PAPERING OVER A GATE DEFECT, NOT
    // FIXING A FIXTURE (#140). Cutting a generated body to a fixed length can end it inside a
    // `"...`, and this scanner had NO heredoc-body opacity at all: an odd raw quote count left in
    // the body leaked the scanner'"'"'s "still inside a quote" state past the heredoc'"'"'s REAL
    // terminator line, so the terminator and the staging command on the far side of it were read
    // as inert QUOTED TEXT and the row came back `none`. The prior version of this comment read
    // that `none` as "a fixture reporting an allow for a gate that is correct" and spent the
    // body'"'"'s last two bytes forcing an even quote count to make the symptom go away. That
    // reading was WRONG: the allow was a genuine bypass, not a fixture defect -- a real shell
    // really does execute the trailing `git add -A` in that construction -- and #140 fixes the
    // scanner to give a heredoc body real opacity (R1) regardless of what it contains, so the
    // body'"'"'s own quote parity no longer has any bearing on the verdict and no longer needs to
    // be engineered around. Truncating to the full requested length, balanced or not, is now the
    // honest fixture; #140'"'"'s own regression suite (AC3/AC6, see the "#140 AC" suites below) is
    // what asserts the post-fix verdict is `deny` on a body this truncation leaves unbalanced.
    process.stdout.write(mk[kind]().slice(0, n));
  ' "$1" "$2"
}
# THE CLASS IS THE HOOK'S OWN VALUE, NOT A COPY OF IT AND NOT ITS SOURCE TEXT (#132). This
# function used to carry a hand-transcribed twelve-member set. A transcription tracks the
# transcriber's attention rather than the code: mutate _STRUCT in pre-tool-use.sh and every number
# this block reports stays exactly where it was, so the density rows would go on agreeing with a
# hook that had stopped counting what they say it counts. Reading the source LINE instead is worse
# than the copy, and measurably so: `_STRUCT` is assigned from a double-quoted string opening with
# the variable reference $_NL and carrying a deliberately doubled backslash, so the source TEXT is a
# FIFTEEN member set that adds `$ _ N L` and loses the NEWLINE. tb_struct_class evaluates the
# assignment with $_NL bound, so what is held here is the value the hook computes.
GATE_STRUCT_CLASS="$(tb_struct_class "$GATE_PLUGIN_DIR/hooks/pre-tool-use.sh" || printf '')"
assert_eq "VACUITY for every density figure below: the hook's own _STRUCT evaluates to a 12-member class (a red here means the assignment MOVED SHAPE -- e.g. was refactored into a concatenation, the form _DELIMS already uses -- not that the density figures are wrong)" \
  "$(tb_struct_distinct "$GATE_STRUCT_CLASS")" "12"
dens_struct() { # <string> -> how many characters of it are in the hook's own structural set
  TB_CLASS="$GATE_STRUCT_CLASS" "$GATE_REAL_NODE" -e '
    const S = new Set(Array.from(process.env.TB_CLASS || ""));
    let n = 0; for (const c of process.argv[1]) if (S.has(c)) n++;
    process.stdout.write(String(n));
  ' "$1"
}

# The same-run floor, RECORDED and never subtracted. It is what every cell below carries in
# common -- a node cold start and a resolver run -- and knowing it is what stops a reader mistaking
# the cheap cells for a fast scan. Subtracting it is the trap: on a loaded host it exceeded the
# cheap cells outright and turned a stable ratio into noise.
DENS_FLOOR_A="$(len_now_ms)"
for _ in 1 2 3; do sub_verdict "$P4" 'git commit -a -m x' >/dev/null; done
DENS_FLOOR_B="$(len_now_ms)"
DENS_FLOOR=$(( (DENS_FLOOR_B - DENS_FLOOR_A) / 3 ))
record "DENSITY AXIS same-run floor (the identical driver and decision on a command too small to measure): ${DENS_FLOOR} ms/call, carried in common by every cell below"

DENS_KINDS=(quotes minified json code prose run)
DENS_SLOW=""
DENS_REGRESS=""
DENS_WORST=0
DENS_MIN_MS=""
DENS_MAX_MS=""
DENS_MIN_D=""
DENS_MAX_D=""
DENS_ROWS=""
for k in "${DENS_KINDS[@]}"; do
  BODY="$(dens_pad "$k" "$DENS_TARGET")"
  BODY_STRUCT="$(dens_struct "$BODY")"
  BODY_LEN="${#BODY}"
  # THE FIXTURE'S OWN CONTROL. A pad that quietly stopped varying density would make every row
  # below green over the defect this block exists to catch, exactly as the LENGTH AXIS's
  # `"y".repeat(n)` did. Both terms are asserted, because a pad of the wrong LENGTH breaks the
  # "at fixed length" premise just as completely as a pad of the wrong density.
  assert_eq "AC7 DENSITY VACUITY: the '${k}' pad is the agreed fixed length (${BODY_LEN} of ${DENS_TARGET} bytes)" \
    "$BODY_LEN" "$DENS_TARGET"

  DENS_A="$(len_now_ms)"
  DENS_V="$(sub_verdict "$P4" "cat > notes.md <<'EOF'
$BODY
EOF
git add -A")"
  DENS_B="$(len_now_ms)"
  DENS_MS=$(( DENS_B - DENS_A ))
  [[ "$DENS_MS" -gt "$DENS_WORST" ]] && DENS_WORST="$DENS_MS"
  [[ "$DENS_MS" -lt "$BYPASS_BOUND_MS" ]] || DENS_SLOW="$DENS_SLOW
${k} (${BODY_STRUCT} structural chars in ${BODY_LEN} bytes) -> ${DENS_MS} ms"
  [[ "$DENS_MS" -lt "$REGRESSION_BUDGET_MS" ]] || DENS_REGRESS="$DENS_REGRESS
${k} (${BODY_STRUCT} structural chars in ${BODY_LEN} bytes) -> ${DENS_MS} ms"
  assert_eq "AC7 DENSITY: a ${DENS_TARGET}-byte '${k}' body (${BODY_STRUCT} structural chars), then git add -A -> deny" \
    "$DENS_V" "deny"
  # The paired ALLOW at the same density and the same length, so no row above can be satisfied by
  # a gate that denies whatever it finds expensive.
  assert_eq "AC7 DENSITY: the same ${DENS_TARGET}-byte '${k}' body, then git add <path> -> none" \
    "$(sub_verdict "$P4" "cat > notes.md <<'EOF'
$BODY
EOF
git add plugins/pipeline/agents/dba.md")" "none"

  DENS_ROWS="$DENS_ROWS ${k}=${DENS_MS}ms/${BODY_STRUCT}s"
  if [[ -z "$DENS_MIN_MS" || "$DENS_MS" -lt "$DENS_MIN_MS" ]]; then DENS_MIN_MS="$DENS_MS"; fi
  if [[ -z "$DENS_MAX_MS" || "$DENS_MS" -gt "$DENS_MAX_MS" ]]; then DENS_MAX_MS="$DENS_MS"; fi
  if [[ -z "$DENS_MIN_D" || "$BODY_STRUCT" -lt "$DENS_MIN_D" ]]; then DENS_MIN_D="$BODY_STRUCT"; fi
  if [[ -z "$DENS_MAX_D" || "$BODY_STRUCT" -gt "$DENS_MAX_D" ]]; then DENS_MAX_D="$BODY_STRUCT"; fi
done

assert_eq "AC7 DENSITY: every cell returned inside the ${LEN_TIMEOUT_S}s the declaration commits to (worst ${DENS_WORST} ms). A hook killed at its declared timeout emits nothing and the call is ALLOWED, so a row over this bound is a bypass and not a slow test. This is the assertion the block exists for: at the reviewed commit the quote-dense cell at this length took over 5 s and returned NOTHING" \
  "$DENS_SLOW" ""
assert_eq "AC7 DENSITY REGRESSION: and every cell returned inside the ${REGRESSION_BUDGET_MS} ms absolute budget (worst ${DENS_WORST} ms). This is the row that would notice #116's linear scan going quadratic again: over THIS bound the gate still decided, so it is a REGRESSION and not a BYPASS, and the remedy is the scan rather than the declaration" \
  "$DENS_REGRESS" ""

DENS_SPAN=$(( DENS_MAX_D - DENS_MIN_D ))
DENS_SPREAD_X10=$(( DENS_MAX_MS * 10 / (DENS_MIN_MS < 1 ? 1 : DENS_MIN_MS) ))
record "DENSITY AXIS at ${DENS_TARGET} bytes:${DENS_ROWS}; totals ${DENS_MIN_MS}-${DENS_MAX_MS} ms (spread $(( DENS_SPREAD_X10 / 10 )).$(( DENS_SPREAD_X10 % 10 ))x) over a population carrying ${DENS_MIN_D} to ${DENS_MAX_D} structural characters at that one length, on $(uname -sr)"

assert_eq "AC7 DENSITY VACUITY: the population really spans density -- ${DENS_MIN_D} to ${DENS_MAX_D} structural characters at ONE fixed length. A cost that followed the PRODUCT of the two would spread by roughly that factor, and a pad set that quietly stopped varying would make every timing row here green over the defect this block exists to catch, exactly as the LENGTH AXIS's single-character pad did" \
  "$([[ "$DENS_SPAN" -ge 2048 ]] && echo spans || echo "TOO NARROW: ${DENS_MIN_D}..${DENS_MAX_D}")" "spans"

# THE SPREAD IS A REGRESSION GUARD AND IT IS HONEST ABOUT BEING ONE. It is taken over RAW totals,
# never over a floor-subtracted marginal: a first draft subtracted a same-run floor to sharpen the
# ratio, and on a loaded host the floor exceeded the cheap cells outright, the marginal clamped to
# 1 ms and the ratio read 832x for a gate that was working. A ratio whose denominator can go to
# noise is not an instrument. Raw totals carry the harness's fixed cost in BOTH terms, which damps
# the figure and is exactly what makes it stable.
#
# WHAT IT CAN AND CANNOT DO, so nobody reads it as a proof. It cannot separate the reviewed commit
# from this one at a length CI can afford, because at 12 KB the fixed cost still dominates both:
# measured on darwin 25.5.0 the same six cells spread 7.7x before this change and 6.2x after, at
# 8 KB. What it CAN do is catch a return to the product, which grows without bound: at 64 KB the
# same population spread over 22x before (three cells past a 120 s cap, so the true figure is
# larger) and 13.7x after. The DISCRIMINATING evidence for this issue is the differential and the
# curve recorded above, not this row; this row is here so a regression cannot land silently.
assert_eq "AC7 DENSITY: the densest cell stays inside 12x of the cheapest at one fixed length ($(( DENS_SPREAD_X10 / 10 )).$(( DENS_SPREAD_X10 % 10 ))x over a ${DENS_MIN_D}-to-${DENS_MAX_D} structural-character span). A REGRESSION GUARD against cost returning to the product of density and length, not a proof that it has not: see the comment above it and the recorded curve" \
  "$([[ "$DENS_SPREAD_X10" -le 120 ]] && echo bounded || echo "FOLLOWS DENSITY: $(( DENS_SPREAD_X10 / 10 )).$(( DENS_SPREAD_X10 % 10 ))x over ${DENS_MIN_D}..${DENS_MAX_D} structural characters")" "bounded"
assert_eq "AC7 DENSITY DISCRIMINATION: and the cells still differ measurably from each other ($(( DENS_SPREAD_X10 / 10 )).$(( DENS_SPREAD_X10 % 10 ))x > 1.2x), so the row above is bounding the GATE and not a harness floor that swamped every cell" \
  "$([[ "$DENS_SPREAD_X10" -gt 12 ]] && echo discriminates || echo "FLOOR-DOMINATED: $(( DENS_SPREAD_X10 / 10 )).$(( DENS_SPREAD_X10 % 10 ))x -- every cell is the harness and the bound above proves nothing")" \
  "discriminates"

# ===============================================================================================
suite "AC7 DENSITY AXIS (#116): and the cost is LINEAR in length at each fixed density"
# ===============================================================================================
#
# The other half of the same property, and the half a single length cannot see. A quadratic in
# LENGTH is what #106 round 2 closed and a product with DENSITY is what the block above closes;
# neither is visible from one point on the curve. Four times the length must cost about four times
# as much and not sixteen, at BOTH ends of the density range, so the growth is measured at the
# densest class and the sparsest one and each is bounded separately.
#
# THE GROWTH FIGURE IS RECORDED AND THE VERDICT AND THE DECLARED BOUND ARE ASSERTED, which is the
# same division the two axes above make and is deliberate. A growth RATIO cannot be asserted here
# without either subtracting a floor -- which on a loaded host exceeded the small cell outright and
# read 424x for a gate that was working -- or spending a length CI cannot afford. What IS asserted
# is the thing a reader of this file cares about: at four times the length, at both ends of the
# density range, the gate still decides, and still decides inside the timeout the runtime kills at.
DENS_GROWTH=""
DENS_GROW_SLOW=""
DENS_GROW_REGRESS=""
for k in quotes prose; do
  GROW_MS=()
  for mult in 1 4; do
    GBODY="$(dens_pad "$k" $(( 1536 * mult )))"
    GA="$(len_now_ms)"
    GV="$(sub_verdict "$P4" "cat > notes.md <<'EOF'
$GBODY
EOF
git add -A")"
    GB="$(len_now_ms)"
    # `${arr[-1]}` is bash 4; this file runs under the 3.2 that ships with macOS.
    GTHIS=$(( GB - GA ))
    GROW_MS+=( "$GTHIS" )
    assert_eq "AC7 DENSITY LINEARITY: a $(( 1536 * mult ))-byte '${k}' body (density class '${k}'), then git add -A -> deny" "$GV" "deny"
    [[ "$GTHIS" -lt "$BYPASS_BOUND_MS" ]] || DENS_GROW_SLOW="$DENS_GROW_SLOW
${k} at $(( 1536 * mult )) bytes -> ${GTHIS} ms"
    [[ "$GTHIS" -lt "$REGRESSION_BUDGET_MS" ]] || DENS_GROW_REGRESS="$DENS_GROW_REGRESS
${k} at $(( 1536 * mult )) bytes -> ${GTHIS} ms"
  done
  GROWTH_X10=$(( GROW_MS[1] * 10 / (GROW_MS[0] < 1 ? 1 : GROW_MS[0]) ))
  DENS_GROWTH="$DENS_GROWTH ${k}: 1536B=${GROW_MS[0]}ms 6144B=${GROW_MS[1]}ms ($(( GROWTH_X10 / 10 )).$(( GROWTH_X10 % 10 ))x for 4x length, floor ${DENS_FLOOR} ms in both);"
done
record "DENSITY LINEARITY:${DENS_GROWTH} on $(uname -sr)"
assert_eq "AC7 DENSITY LINEARITY BYPASS: at four times the length, at BOTH ends of the density range, every probe still returned inside the ${LEN_TIMEOUT_S}s the declaration commits to, so none of them was killed and fell open.${DENS_GROWTH}" \
  "$DENS_GROW_SLOW" ""
assert_eq "AC7 DENSITY LINEARITY REGRESSION: and inside the ${REGRESSION_BUDGET_MS} ms absolute budget, which is the bound that does NOT move when hooks.json does.${DENS_GROWTH}" \
  "$DENS_GROW_REGRESS" ""

# ===============================================================================================
suite "AC7 FLOOR: two spellings nobody enumerated, whose effect is identical"
# These are the rows a literal eleven-row table passes the whole suite without catching.
assert_eq "DENY: git commit -aqm 'm' (bundled short flags; verified with real git to commit every tracked modification)" \
  "$(sub_verdict "$P4" "${FLOOR_ROWS[0]}")" "deny"
assert_eq "DENY: git add -Av (bundled -A)" \
  "$(sub_verdict "$P4" "${FLOOR_ROWS[1]}")" "deny"

# THE FLOOR CLAIM'S OWN CONTROL, because a floor row that a table happens to contain proves
# nothing about the floor. Asserted against the enumeration, in the suite, so it cannot rot.
for f in "${FLOOR_ROWS[@]}"; do
  hit=0
  for c in "${FORBIDDEN[@]}"; do [[ "$f" == "$c" ]] && hit=1; done
  assert_eq "FLOOR CONTROL: '$f' is genuinely OUTSIDE the eleven enumerated rows" "$hit" "0"
done

# ===============================================================================================
suite "AC7 NEGATIVE POPULATION: the staging-verb term has a boundary, and it is asserted"
# ===============================================================================================
#
# Absent from the round-5 spec entirely, and the omission was load-bearing: a mutation widening
# the deny to ANY `git` invocation passes every positive fixture above. It would also refuse
# `git checkout -- .`, which agents/qa.md rule 13 mandates BY NAME for restoring a planted
# mutation from git -- so the gate would break the very battery discipline #19 exists to protect.
NOT_STAGING=(
  'git checkout -- .'
  'git checkout -- plugins/pipeline/agents/qa.md'
  'git restore .'
  'git stash'
  'git stash push -u'
  'git clean -fd'
  'git diff --stat'
  'git log --oneline -5'
)
for c in "${NOT_STAGING[@]}"; do
  assert_eq "ALLOW (not a staging verb): $c" "$(sub_verdict "$P4" "$c")" "none"
done

# ===============================================================================================
suite "AC7 COMPOUND: staging narrowly and then committing blanket is a DENY"
# ===============================================================================================
#
# Two plausible implementations get these wrong in the PERMISSIVE direction -- "decide on the
# first git invocation" sees an explicit-path add, and "any pathspec present -> allow" sees a
# pathspec. So the rule is that EVERY git invocation in a compound command is evaluated and a
# deny by any one of them denies the whole call.
assert_eq "DENY: git add <path> && git commit -a -m 'm'" \
  "$(sub_verdict "$P4" "git add plugins/pipeline/scripts/foo.mjs && git commit -a -m 'm'")" "deny"
assert_eq "DENY: git add <path>; git commit --all" \
  "$(sub_verdict "$P4" "git add plugins/pipeline/scripts/foo.mjs; git commit --all")" "deny"
assert_eq "DENY: git status --porcelain && git add -A" \
  "$(sub_verdict "$P4" "git status --porcelain && git add -A")" "deny"

# ===============================================================================================
suite "AC7 QUOTE-AWARE SPLITTING: this issue's OWN doc-retirement commit message"
# ===============================================================================================
#
# A naive `&&`/`;` splitter run over the message below mis-parses the quoted operand into a second
# invocation and falsely denies a correct commit -- and this issue's own ten-file doc retirement
# produces exactly that commit, so the fixture is the real shape rather than a contrived one.
#
# THE TWO HALVES MUST BE ASSERTED TOGETHER. A matcher that refuses to split at all passes every
# quoted cell here and fails every genuine compound cell above; a matcher that splits without
# honouring quotes does the reverse. Neither half alone can tell them apart.
QUOTED_OK=(
  "git commit -m \"docs: retire the 'nothing mechanically enforces it either' sentence, which banned git commit -a\""
  "git commit -m \"docs: retire the sentence that banned git add -A across the nine agent contracts\""
  "git commit -m \"docs: the retired sentence also named git add . as a blanket spelling\""
  "git commit -m \"docs: the rule read 'never git commit -a && never git add -A' before this change\""
  "git commit -m \"docs: the rule read 'never git commit -a; never git add .' before this change\""
)
for c in "${QUOTED_OK[@]}"; do
  assert_eq "ALLOW (forbidden spelling lives inside a quoted -m operand): ${c:0:72}..." \
    "$(sub_verdict "$P4" "$c")" "none"
done

# ===============================================================================================
suite "AC9: mention is not invocation, PAIRED PER ROW"
# ===============================================================================================
#
# One mention fixture per forbidden row, each paired with that row's operative form in the same
# suite. A single representative mention leaves most rows unpaired, and the mutation this exists
# for -- replace the decision with a raw substring match over the command string -- is caught only
# by the rows it is actually run against.
for c in "${FORBIDDEN[@]}"; do
  m="git commit -m \"docs: ban $c in Phase 4\""
  assert_eq "PAIR: the OPERATIVE form is denied  -> $c" "$(sub_verdict "$P4" "$c")" "deny"
  assert_eq "PAIR: the MENTION is allowed        -> $m" "$(sub_verdict "$P4" "$m")" "none"
done
assert_eq "ALLOW: git add <path> && git commit -m \"chore: git commit -a is now denied\"" \
  "$(sub_verdict "$P4" 'git add plugins/pipeline/agents/dba.md && git commit -m "chore: git commit -a is now denied"')" "none"

# ===============================================================================================
suite "AC8: explicit-path staging is ALLOWED, whatever the path"
# ===============================================================================================
#
# The `.pipeline` row is the one that fails the naive reconciliation of AC4 against this criterion
# ("deny paths under .pipeline"), which would wedge every panelist's own shard write. The
# `git add -u <path>` row is the cell separating the FLAG from its blanket EFFECT: -u with a
# pathspec updates only that path.
assert_eq "ALLOW: git add <path> && git commit -m ..." \
  "$(sub_verdict "$P4" 'git add plugins/pipeline/scripts/data-layer-surface.mjs && git commit -m "fix: restore glob row"')" "none"
assert_eq "ALLOW: git add .pipeline/106/peer-review.secops.json (a panelist's own shard write)" \
  "$(sub_verdict "$P4" 'git add .pipeline/106/peer-review.secops.json')" "none"
assert_eq "ALLOW: a bare commit with no staging verb" \
  "$(sub_verdict "$P4" 'git commit -m "fix: something already staged"')" "none"
assert_eq "ALLOW: git add -u <pathspec> -- the flag is blanket only when nothing narrows it" \
  "$(sub_verdict "$P4" 'git add -u plugins/pipeline/agents/dba.md')" "none"
assert_eq "ALLOW: git add -- plugins/pipeline/agents/dba.md" \
  "$(sub_verdict "$P4" 'git add -- plugins/pipeline/agents/dba.md')" "none"

# ===============================================================================================
suite "AC2: the ORIGIN term is agent_id PRESENCE, and this control reddens under its own mutation"
# ===============================================================================================
#
# The command is drawn from the forbidden table ON PURPOSE. An explicit-path fixture would survive
# the mutation "delete the agent_id-presence term" and prove nothing; only a fixture that WOULD be
# denied if the origin term were dropped can act as this control.
assert_eq "AC2: agent_id ABSENT, one in-flight '4-review', a forbidden command -> NOT denied" \
  "$(verdict "$P4" 'git commit -a -m "m"' agent_id=__ABSENT__)" "none"

# The exact payload a NAMED-AGENT MAIN THREAD produces: no agent_id, but a panelist agent_type
# present. 2.1.85's schema is literal about this -- agent_id is "Absent for the main thread, even
# in --agent sessions. Use this field (not agent_type) to distinguish subagent calls from
# main-thread calls." This is the payload the pre-round-1 design would have denied.
for at in ba pipeline:ba plugin:pipeline:ba; do
  assert_eq "AC2: agent_id ABSENT but agent_type '$at' PRESENT -> still NOT denied" \
    "$(verdict "$P4" 'git commit -a -m "m"' agent_id=__ABSENT__ "agent_type=$at")" "none"
done
# An EMPTY agent_id is not a present one. Absence and emptiness are the whole of R2.
assert_eq "AC2: an EMPTY agent_id is not a subagent origin" \
  "$(verdict "$P4" 'git commit -a -m "m"' agent_id= agent_type=pipeline:qa)" "none"

# ===============================================================================================
suite "AC3: the orchestrator's own checkpoint, on the REAL command shapes"
# ===============================================================================================
#
# Re-read from the convention at the reviewed commit rather than copied, so a WIDENED checkpoint
# scope reddens this row instead of silently agreeing with a stale transcription. pipeline.md
# documents the checkpoint as TWO commands and PreToolUse fires once per Bash call, so all three
# forms are asserted separately. Deliberately redundant with AC8 on the command term, and labelled
# so: the subject here is the real-world shape, not a predicate term.
CKPT_BLOCK="$(awk '/^# Run BEFORE entering each phase/{f=1} f&&/^```$/{exit} f' "$GATE_PIPELINE_MD")"
CKPT_ADD="$(printf '%s\n' "$CKPT_BLOCK" | grep -m1 '^git add ' | sed 's|<issue>|106|g')"
CKPT_COMMIT="$(printf '%s\n' "$CKPT_BLOCK" | grep -m1 '^git commit ' | sed 's|<issue>|106|g; s|<n>|4-review|g')"
record "CHECKPOINT CONVENTION, read from commands/pipeline.md at this commit: [$CKPT_ADD] and [$CKPT_COMMIT]"
assert_eq "VACUITY: both checkpoint commands were actually extracted (an empty fixture asserts nothing)" \
  "$([[ -n "$CKPT_ADD" && -n "$CKPT_COMMIT" ]] && echo extracted || echo "MISSING add=[$CKPT_ADD] commit=[$CKPT_COMMIT]")" "extracted"
assert_eq "VACUITY: the extracted add stages exactly one status.json, not a blanket pathspec" \
  "$([[ "$CKPT_ADD" == *"status.json" ]] && echo scoped || echo "WIDENED: $CKPT_ADD")" "scoped"

for who in "agent_id=__ABSENT__" "agent_id=sub-orchestrator-impersonator"; do
  assert_eq "AC3 ALLOW ($who): $CKPT_ADD" "$(verdict "$P4" "$CKPT_ADD" "$who")" "none"
  assert_eq "AC3 ALLOW ($who): $CKPT_COMMIT" "$(verdict "$P4" "$CKPT_COMMIT" "$who")" "none"
  assert_eq "AC3 ALLOW ($who): the &&-joined form" \
    "$(verdict "$P4" "$CKPT_ADD && $CKPT_COMMIT" "$who")" "none"
done

# ===============================================================================================
suite "AC4: agent_type is READ, and the namespace strip is LOAD-BEARING"
# ===============================================================================================
#
# The deny half first: a payload identical to AC2's except CARRYING agent_id is denied over every
# agent_type shape, including its absence.
for at in "agent_type=__ABSENT__" "agent_type=ba" "agent_type=pipeline:ba" "agent_type=plugin:pipeline:ba"; do
  assert_eq "AC4 DENY with agent_id present and $at" \
    "$(verdict "$P4" 'git commit -a -m "m"' agent_id=sub-4 "$at")" "deny"
done

# THE HALF THAT MAKES THE ROW MUTABLE NOW THAT NO ALLOWLIST EXISTS. Without an allowlist, nothing
# above changes when agent_type reading is deleted outright -- so R2's HALVES clause is enforced
# here, on the ATTRIBUTION, not left to intent. The attribution is recovered the way an operator
# would recover it (the gate's own stderr plus any file it wrote under a bound root), normalized
# only for the parts that legitimately vary between two runs.
ATTR_MANIFEST="$TEMP_PROJECT/attr-manifest.json"
attr_for() {  # <agent_type> -> normalized recovered attribution
  gate_reset_env "$P4"; GATE_TMPDIR="$TEMP_PROJECT/attr-tmp"; mkdir -p "$GATE_TMPDIR"
  gate_run_with_sinks "$(gate_payload 'git commit -a -m "m"' agent_id=sub-4 "agent_type=$1")" \
    "$ATTR_MANIFEST" "$P4" "$GATE_TMPDIR"
  printf '%s\n%s' "$GATE_ATTRIBUTION" "$GATE_REASON" | gate_normalize_attribution
}
ATTR_NS="$(attr_for pipeline:ba)"
ATTR_BARE="$(attr_for ba)"
ATTR_NONE="$(attr_for __ABSENT__)"

assert_eq "AC4: the recovered role attribution is NON-EMPTY for 'pipeline:ba'" \
  "$([[ -n "$(printf '%s' "$ATTR_NS" | tr -d '[:space:]')" ]] && echo non-empty || echo EMPTY)" "non-empty"
assert_eq "AC4: and NON-EMPTY for bare 'ba'" \
  "$([[ -n "$(printf '%s' "$ATTR_BARE" | tr -d '[:space:]')" ]] && echo non-empty || echo EMPTY)" "non-empty"
assert_eq "AC4: and the two are EQUAL -- replacing the namespace strip with a bare equality reddens exactly here" \
  "$ATTR_NS" "$ATTR_BARE"
assert_contains "AC4: and it actually names the role (a strip that yields nothing is not a strip)" \
  "$ATTR_NS" "ba"
# DISCRIMINATION: if the attribution were the same for every agent_type, the equality above would
# be satisfied by a gate that never reads agent_type at all -- which is the mutation "delete
# agent_type reading entirely". An ABSENT agent_type must therefore attribute DIFFERENTLY.
assert_eq "AC4 DISCRIMINATION: an ABSENT agent_type attributes differently from 'ba' (else the equality above is vacuous)" \
  "$([[ "$ATTR_NONE" != "$ATTR_BARE" ]] && echo differs || echo "IDENTICAL, so agent_type is not being read at all")" "differs"

# ===============================================================================================
suite "AC5: NO ROLE ALLOWLIST"
# ===============================================================================================
#
# The seven CITABLE dispatch literals are fixtures proving no seated role escapes. art_director's
# dispatched agent_type is fixed NOWHERE in commands/pipeline.md's Phase 4 block; that absence is
# RECORDED as a finding rather than filled with an invented literal, because a guess with a
# fixture's authority is worse than a stated gap.
for r in pipeline:ba pipeline:dba pipeline:devops pipeline:secops pipeline:dev pipeline:qa pipeline:design; do
  assert_eq "AC5 DENY for seated role $r" "$(verdict "$P4" 'git add -A' agent_id=sub-5 "agent_type=$r")" "deny"
done
assert_eq "AC5 DENY for 'art-director' (the spelling the plugin's own agent FILE carries)" \
  "$(verdict "$P4" 'git add -A' agent_id=sub-5 agent_type=art-director)" "deny"
assert_eq "AC5 DENY for an agent_type that is ABSENT entirely" \
  "$(verdict "$P4" 'git add -A' agent_id=sub-5 agent_type=__ABSENT__)" "deny"
assert_eq "AC5 DENY for an UNRECOGNISED agent_type string" \
  "$(verdict "$P4" 'git add -A' agent_id=sub-5 agent_type=totally-unknown-worker-9)" "deny"

AD_LINES="$(grep -c 'art_director\|art-director' "$GATE_PIPELINE_MD" | tr -d ' ')"
record "FINDING (recorded, not invented): commands/pipeline.md mentions art-director on ${AD_LINES} line(s) and fixes its DISPATCHED agent_type literal nowhere in the Phase 4 block; R3 removes the allowlist so coverage does not depend on that literal."

# ===============================================================================================
suite "AC6: R3's OVER-REFUSAL is pinned, not assumed"
# ===============================================================================================
#
# A general-purpose Task worker, or an adopting project's own agent, blanket-staging while a
# Phase 4 run is the resolved owner IS refused. That is deliberate -- narrowing it reintroduces
# the allowlist R3 removes -- and R21(d) plus the operator README must say so in words. This row
# pins the BEHAVIOUR; test-pretooluse-doc-retirement.sh pins the sentence.
assert_eq "AC6: a non-pipeline agent_type ('general-purpose') IS denied while a Phase 4 run owns the root" \
  "$(verdict "$P4" 'git add -A' agent_id=sub-6 agent_type=general-purpose)" "deny"
assert_eq "AC6 CONTROL: with NO in-flight record, the same payload is NOT denied (the refusal is scoped to a Phase 4 owner)" \
  "$(verdict "$TEMP_PROJECT/no-records" 'git add -A' agent_id=sub-6 agent_type=general-purpose)" "none"

# ===============================================================================================
suite "AC11: PHASE DISCRIMINATION, all three Phase 4 literals asserted BEHAVIOURALLY"
# ===============================================================================================
#
# AC15 pins the VOCABULARY; it does not pin a verdict, so round 5 exercised only '4-review' end to
# end. The other two fall on opposite sides of the harm, and `phase === '4-review'` and
# `phase.startsWith('4-')` diverge on both SILENTLY: '4-veto-rework-required' is a LIVE phase where
# rework subagents are actively dispatched, so an equality implementation leaves the gate silent
# exactly when panelist-driven rework is running.
assert_eq "AC11: '3-impl' with a forbidden command is NOT denied" \
  "$(sub_verdict "$P3" 'git commit -a -m "feat: implement"')" "none"
for ph in $(gate_phase4_literals); do
  R="$TEMP_PROJECT/phase-$ph"
  gate_inflight_status "$R/.pipeline/106/status.json" "$ph"
  assert_eq "AC11: '$ph' with a forbidden command IS denied" "$(sub_verdict "$R" 'git commit -a -m "m"')" "deny"
done
# The synthetic future-suffix probe, LABELLED as synthetic per AC15: it is not a literal
# pipeline.md writes, and it is here only to show which side of the prefix test the gate is on.
R_FUT="$TEMP_PROJECT/phase-future"
gate_inflight_status "$R_FUT/.pipeline/106/status.json" "4-review-round-2"
record "SYNTHETIC FUTURE-SUFFIX PROBE (not a literal pipeline.md writes): '4-review-round-2' -> $(sub_verdict "$R_FUT" 'git commit -a -m "m"')"

# ===============================================================================================
suite "AC10: the 18-cell cross product, stated in full"
# ===============================================================================================
#
# {agent_id absent, present} x {3-impl, 4-review} x {explicit-path, blanket, mention-only}.
# EXACTLY ONE cell is a deny: {present, 4-review, blanket}. A reader given only this table can
# state every outcome with no contradictions, which is the criterion.
CMD_EXPLICIT='git add plugins/pipeline/agents/qa.md && git commit -m "fix: one file"'
CMD_BLANKET='git commit -a -m "m"'
CMD_MENTION='git commit -m "docs: git commit -a is denied in Phase 4"'
DENY_CELLS=0
for origin in absent present; do
  for ph in 3-impl 4-review; do
    ROOT="$TEMP_PROJECT/x-$ph"
    gate_inflight_status "$ROOT/.pipeline/106/status.json" "$ph"
    for kind in explicit blanket mention; do
      case "$kind" in
        explicit) C="$CMD_EXPLICIT" ;;
        blanket)  C="$CMD_BLANKET" ;;
        mention)  C="$CMD_MENTION" ;;
      esac
      if [[ "$origin" == "absent" ]]; then
        V="$(verdict "$ROOT" "$C" agent_id=__ABSENT__)"
      else
        V="$(verdict "$ROOT" "$C" agent_id=sub-10 agent_type=pipeline:qa)"
      fi
      if [[ "$origin" == "present" && "$ph" == "4-review" && "$kind" == "blanket" ]]; then
        assert_eq "AC10 cell {$origin, $ph, $kind}: DENY (the one deny in the table)" "$V" "deny"
      else
        assert_eq "AC10 cell {$origin, $ph, $kind}: allow" "$V" "none"
      fi
      [[ "$V" == "deny" ]] && DENY_CELLS=$((DENY_CELLS + 1))
    done
  done
done
assert_eq "AC10: EXACTLY ONE of the eighteen cells is a deny" "$DENY_CELLS" "1"

# ===============================================================================================
suite "AC17: the two stages agree, ELEMENT-WISE, over AC7's table and AC9's mentions"
# ===============================================================================================
#
# R11 puts the forbidden vocabulary in ONE source and splits its EVALUATION across two stages. The
# observable content of "the two stages agree" is that the cheap stage ESCALATES exactly the
# payloads the authoritative stage DENIES: a row the cheap stage drops is never denied and no
# criterion elsewhere reddens, and a cheap stage that escalates everything reinstates the
# permanent node tax R10 exists to refuse. Escalation is observed with the node spy (a process
# observation, as AC16 requires), never with a clock.
AGREE_SPY="$TEMP_PROJECT/agree-spy"
gate_spy_setup "$AGREE_SPY"

escalated_and_verdict() {  # <command> -> "escalated:<0|1> verdict:<d>"
  : > "$GATE_SPY_LOG"
  gate_reset_env "$P4"; GATE_PATH="$GATE_SPY_PATH"
  run_gate "$(gate_payload "$1" agent_id=sub-17 agent_type=pipeline:qa)"
  local n; n="$(gate_spy_invocations)"
  printf 'escalated:%s verdict:%s' "$([[ "${n:-0}" -ge 1 ]] && echo 1 || echo 0)" "$GATE_DECISION"
}

MISMATCHES=""
for c in "${FORBIDDEN[@]}" "${FLOOR_ROWS[@]}"; do
  r="$(escalated_and_verdict "$c")"
  [[ "$r" == "escalated:1 verdict:deny" ]] || MISMATCHES="$MISMATCHES
DENY-ROW [$c] -> $r"
done
for c in "${FORBIDDEN[@]}"; do
  r="$(escalated_and_verdict "git commit -m \"docs: ban $c in Phase 4\"")"
  [[ "$r" == "escalated:0 verdict:none" ]] || MISMATCHES="$MISMATCHES
MENTION-ROW [$c] -> $r"
done
assert_eq "AC17: every forbidden row ESCALATES and DENIES, every mention row does NEITHER -- element-wise, no mismatches" \
  "$MISMATCHES" ""

# ===============================================================================================
suite "AC1/AC3/AC4 (#132): the sizing corpus is ENUMERATED from the tree at check time, and DRIVEN"
# ===============================================================================================
#
# WHAT THIS BLOCK IS AND WHY IT IS NOT A LIST OF FILENAMES. The declared timeout is sized against
# the largest and densest things this repository can put into one Bash call, and Phase 5 writes one
# knowledge/issue-archive/<n>.json per issue FOREVER -- so a bound sized against today's largest
# file is a ratchet against a moving target. A frozen list of filenames would keep reporting a
# clean scan while the corpus outgrew the bound. The population is therefore a RULE evaluated at
# check time, and its enumerated count is published in README item 27 cost (4) and compared here:
# when the corpus outgrows what was measured, this block reddens instead of the gate falling open.
#
# THREE PROPERTIES OF THE RULE, each of which a cheaper rule gets wrong:
#
#   CONTENT-ONLY. `find -type f -size` over a materialized tree, no git call anywhere. AC1's corpus
#   is `git archive | tar x`, which has no .git, so any rule expressed in `git ls-files` or
#   `git check-ignore` enumerates ZERO there and reports a clean scan -- and that is the tree CI
#   runs against, so the failure is not hypothetical.
#
#   EXTENSION-OPEN. The densest tracked file in this repository is NOT a .json: it is a .sh, and so
#   are ranks 3 and 4. A rule restricted to .json already selects the wrong rank-1 density row.
#
#   TWO RAW AXES, NOT ONE SCALAR. Cost is driven by LENGTH and by STRUCTURAL DENSITY and the two do
#   not compress into one ordering without losing rows: a measured pair 1% apart on a composite key
#   sat 2.1x apart on cost, in the wrong direction. So the driven set is the union of the top rows
#   on each RAW axis, plus SENTINELS drawn from outside both, whose job is to fail if a row the
#   ranking does not see is slower than every row it does.
CORPUS_FLOOR=2000
CORPUS_TOP_K=5
new_tmpdir || exit 90
CORPUS_ROOT="$NEW_TMPDIR/corpus"
mkdir -p "$CORPUS_ROOT"
if tb_materialize "$CORPUS_ROOT"; then CORPUS_MAT=ok; else CORPUS_MAT="FAILED: $TB_MAT_ERR"; fi
assert_eq "AC1: the tracked tree materializes into an empty directory via \`git archive | tar x\`" "$CORPUS_MAT" "ok"
CORPUS_FILES="$(tb_mat_file_count "$CORPUS_ROOT")"
assert_eq "AC1 VACUITY: the materialized corpus is non-empty (an empty tree makes every enumeration below report a clean zero)" \
  "$([[ "${CORPUS_FILES:-0}" -ge 100 ]] && echo populated || echo "ONLY ${CORPUS_FILES} FILES")" "populated"
git -C "$CORPUS_ROOT" rev-parse HEAD >/dev/null 2>&1; CORPUS_GIT_RC=$?
assert_eq "AC1: inside that corpus \`git rev-parse\` FAILS, which is why the rule below is content-only -- a git-expressed population would enumerate nothing here and call it clean" \
  "$([[ "$CORPUS_GIT_RC" -ne 0 ]] && echo fails || echo "SUCCEEDED rc=$CORPUS_GIT_RC")" "fails"
assert_eq "AC1 NON-ZERO CONTROL for the row above: the same command in the real checkout SUCCEEDS, so the failure is the missing .git and not a broken invocation" \
  "$(git -C "$GATE_REPO_ROOT" rev-parse HEAD >/dev/null 2>&1 && echo 0 || echo NONZERO)" "0"

CORPUS_ENUM="$(tb_enumerate_count "$CORPUS_ROOT" "$CORPUS_FLOOR")"
CORPUS_BY_DENSITY="$(tb_rank "$GATE_STRUCT_CLASS" "$CORPUS_ROOT" "$CORPUS_FLOOR")"
CORPUS_BY_LENGTH="$(tb_enumerate "$CORPUS_ROOT" "$CORPUS_FLOOR" | sort -rn)"
record "AC4 ENUMERATION: ${CORPUS_ENUM} files at or above ${CORPUS_FLOOR} bytes in the materialized tree ${TB_MAT_SHA:-<none>}, ranked on two raw axes; top-${CORPUS_TOP_K} of each is driven"
assert_eq "AC4 VACUITY: the two rankings are non-empty and agree on the population size (a ranking that silently dropped rows would make the selection below a subset of a subset)" \
  "$(_d="$(printf '%s' "$CORPUS_BY_DENSITY" | grep -c .)"; _l="$(printf '%s' "$CORPUS_BY_LENGTH" | grep -c .)"; \
     if [[ "$_d" == "$CORPUS_ENUM" && "$_l" == "$CORPUS_ENUM" && "$CORPUS_ENUM" -ge 50 ]]; then echo agree; else echo "density=$_d length=$_l enumerated=$CORPUS_ENUM"; fi)" \
  "agree"

# THE SELECTION: top-K on each RAW axis, unioned. Recorded, per AC4, because a top-K selection is
# only honest when K and the ordering it is taken over are both published.
CORPUS_SELECTED="$( { printf '%s\n' "$CORPUS_BY_DENSITY" | head -"$CORPUS_TOP_K" | cut -f4
                      printf '%s\n' "$CORPUS_BY_LENGTH" | head -"$CORPUS_TOP_K" | cut -f2; } | sort -u )"
# THE SENTINELS, one per axis, drawn from OUTSIDE both top-K sets: the sparsest row above the floor
# and the shortest. They exist because the two axes do not rank WORD COUNT, which the hook's own
# header names as a third term in the scan's cost, so a row that is long, sparse and word-dense
# could be the true worst row and be selected by neither. If either sentinel outruns the slowest
# selected row, the ranking missed something and the assertion below says so.
CORPUS_SENTINELS="$( { printf '%s\n' "$CORPUS_BY_DENSITY" | tail -1 | cut -f4
                       printf '%s\n' "$CORPUS_BY_LENGTH" | tail -1 | cut -f2; } | sort -u )"
CORPUS_SENTINELS="$(comm -23 <(printf '%s\n' "$CORPUS_SENTINELS") <(printf '%s\n' "$CORPUS_SELECTED") | grep -v '^$')"
assert_eq "AC4 SENTINEL PREMISE: at least one sentinel row is genuinely OUTSIDE both top-${CORPUS_TOP_K} sets (a sentinel that is also a selected row validates nothing)" \
  "$([[ "$(printf '%s' "$CORPUS_SENTINELS" | grep -c .)" -ge 1 ]] && echo outside || echo "EVERY SENTINEL IS ALSO SELECTED")" "outside"

# Every driven row is the same shape: the file's content as a heredoc body, then the blanket stage
# the gate refuses. QUOTE PARITY IS PART OF THIS FIXTURE AND IT IS SETTLED BY OUTCOME, NEVER BY
# COUNTING. An unbalanced quote earlier in the command defeats the blanket-staging refusal outright
# (#140), so a body the scanner reads as quote-open answers \`none\` and would be recorded as a gate
# that is working. The obvious guard -- count \`"\` and \`'\` in the raw bytes and append one of each
# when the count is odd -- is on the WRONG SIDE OF THE TRANSFORMATION, and that was measured here
# rather than argued: knowledge/issue-archive/106.json carries 9387 raw double quotes, an ODD
# number, and the gate refuses it correctly, because the scanner resolves backslash escapes before
# it counts and what the raw count calls open the scanner calls closed. Appending a balancing quote
# to that body flipped a working \`deny\` into \`none\`: the fixture broke the thing it was guarding.
# So the pad is SEARCHED rather than computed. Each row is driven with no pad first and the first
# pad that produces a decision is the one kept, which observes what the scanner did instead of
# predicting it from the bytes. The pad each row needed is recorded, because a row that needs one is
# a live instance of #140 on tracked content and the transcript should say which rows those are.
CORPUS_DRIVEN=0
CORPUS_WORST_SELECTED=0
CORPUS_ROWS=""
CORPUS_MISVERDICT=""
CORPUS_UNDISCLOSED=""
CORPUS_SENTINEL_SLOW=""
CORPUS_PADDED=""
CORPUS_PADS=( "" "\"" "'" "\"'" )
corpus_drive() { # <relative-path> <selected|sentinel> -> sets CD_MS CD_BYTES CD_DENS CD_PAD
  local rel="$1" kind="$2" body a b pad v deny allow
  body="$(cat "$CORPUS_ROOT/$rel")"
  CD_DENS="$(tb_density "$GATE_STRUCT_CLASS" "$CORPUS_ROOT/$rel" | awk '{print $3}')"
  CD_PAD=""; CD_MS=0; CD_BYTES=0; v=""
  for pad in "${CORPUS_PADS[@]}"; do
    deny="cat > notes.md <<'PIPELINE_CORPUS_EOF'
${body}${pad}
PIPELINE_CORPUS_EOF
git add -A"
    CD_BYTES="${#deny}"
    a="$(len_now_ms)"; v="$(sub_verdict "$P4" "$deny")"; b="$(len_now_ms)"
    CD_MS=$(( b - a ))
    CD_PAD="$pad"
    [[ "$v" == "deny" ]] && break
  done
  allow="cat > notes.md <<'PIPELINE_CORPUS_EOF'
${body}${CD_PAD}
PIPELINE_CORPUS_EOF
git add plugins/pipeline/agents/dba.md"
  local av; av="$(sub_verdict "$P4" "$allow")"
  [[ -n "$CD_PAD" ]] && CORPUS_PADDED="$CORPUS_PADDED ${rel}"
  [[ "$v" == "deny" && "$av" == "none" ]] || CORPUS_MISVERDICT="$CORPUS_MISVERDICT
${rel} (${kind}) -> blanket=${v} narrowed=${av} after trying every pad, expected deny/none. A row that answers none for BOTH is #140 on tracked content: an unbalanced quote earlier in the command defeats the refusal outright."
  CORPUS_DRIVEN=$(( CORPUS_DRIVEN + 1 ))
  CORPUS_ROWS="$CORPUS_ROWS ${rel}=${CD_BYTES}B/${CD_DENS}Bps/${CD_MS}ms(${kind});"
  # AC2's inequality, applied to the NUMBER: min-of-1 here (the floor row is the one #132's own
  # suite takes a min-of-3 over), both spreads applied, compared against the DECLARED bound.
  local adj=$(( CD_MS * 142 * 132 / 10000 ))
  if [[ "$adj" -gt "$BYPASS_BOUND_MS" ]] && ! grep -q -- "$rel" "$GATE_PLUGIN_DIR/README.md"; then
    CORPUS_UNDISCLOSED="$CORPUS_UNDISCLOSED
${rel} at ${CD_MS} ms (${adj} ms adjusted) exceeds the declared ${BYPASS_BOUND_MS} ms and is not named in README.md"
  fi
}
for rel in $CORPUS_SELECTED; do
  corpus_drive "$rel" selected
  [[ "$CD_MS" -gt "$CORPUS_WORST_SELECTED" ]] && CORPUS_WORST_SELECTED="$CD_MS"
done
for rel in $CORPUS_SENTINELS; do
  corpus_drive "$rel" sentinel
  [[ "$CD_MS" -le "$CORPUS_WORST_SELECTED" ]] || CORPUS_SENTINEL_SLOW="$CORPUS_SENTINEL_SLOW
${rel} (outside both top-${CORPUS_TOP_K} sets) measured ${CD_MS} ms against the slowest SELECTED row's ${CORPUS_WORST_SELECTED} ms"
done
record "#140 REACH on this corpus: the rows needing a balancing quote before the gate would decide at all:${CORPUS_PADDED:- none}"
record "AC3/AC4 DRIVEN SET (${CORPUS_DRIVEN} rows of ${CORPUS_ENUM} enumerated, top-${CORPUS_TOP_K} by raw length unioned with top-${CORPUS_TOP_K} by raw B/struct, plus sentinels):${CORPUS_ROWS} worst selected ${CORPUS_WORST_SELECTED} ms, on $(uname -sr) at load $(tb_loadavg)"
assert_eq "AC3 NON-VACUITY: every driven row DENIES the blanket stage and ALLOWS the narrowed one at the identical body -- a row that returned none for both would be a fixture defect (quote parity, #140) reported as a passing measurement" \
  "$CORPUS_MISVERDICT" ""
assert_eq "AC4 ORDERING VALIDATION: no row from OUTSIDE both top-${CORPUS_TOP_K} sets is slower than the slowest row inside them. This is the only thing standing between a two-axis ranking and a silent miss on an axis it does not rank" \
  "$CORPUS_SENTINEL_SLOW" ""
assert_eq "AC3: every driven row whose adjusted cost exceeds the DECLARED timeout is named in the operator-facing disclosure, so an uncovered cell cannot be measured and then left unpublished" \
  "$CORPUS_UNDISCLOSED" ""
assert_eq "AC4 DRIVEN COUNT is non-zero and is what the record line above reports (a scan that inspected nothing produces the same clean output as one that inspected everything)" \
  "$([[ "$CORPUS_DRIVEN" -ge 1 ]] && echo driven || echo "DROVE NOTHING")" "driven"

# THE PUBLISHED RULE MUST BE THE RULE THAT RAN. README item 27 cost (4) states the floor, the
# enumerated count and the driven count; all three are re-derived here from the materialized tree
# rather than trusted. A frozen count diverges the moment the corpus grows, which is the tripwire.
CORPUS_README="$(grep -n '^27\. ' "$GATE_PLUGIN_DIR/README.md" | head -1 | cut -d: -f1)"
CORPUS_README_TEXT="$(sed -n "${CORPUS_README:-1}p" "$GATE_PLUGIN_DIR/README.md")"
assert_eq "VACUITY: README item 27 was located and is long enough to be the disclosure (a grep that found nothing makes the three rows below pass on an empty string)" \
  "$([[ "${#CORPUS_README_TEXT}" -gt 2000 ]] && echo located || echo "ONLY ${#CORPUS_README_TEXT} BYTES")" "located"
assert_eq "AC4: the published size FLOOR is the floor this block enumerated over" \
  "$(printf '%s' "$CORPUS_README_TEXT" | grep -oE 'at or above [0-9]+ bytes' | grep -oE '[0-9]+' | head -1)" "$CORPUS_FLOOR"
assert_eq "AC4: the published ENUMERATED count is the count this block measured -- when the tracked corpus grows past what was sized, this row reddens instead of the gate falling open" \
  "$(printf '%s' "$CORPUS_README_TEXT" | grep -oE 'enumerated [0-9]+' | grep -oE '[0-9]+' | head -1)" "$CORPUS_ENUM"
assert_eq "AC4: and the published DRIVEN count is the number of rows actually driven above" \
  "$(printf '%s' "$CORPUS_README_TEXT" | grep -oE 'drove [0-9]+' | grep -oE '[0-9]+' | head -1)" "$CORPUS_DRIVEN"

# =================================================================================================
# #140: heredoc-body-opacity contract. QA-authored (Phase 3a), all 12 spec.json acceptance criteria.
# =================================================================================================
#
# THE DEFECT, RESTATED FROM BEHAVIOR NOT FROM SHAPE. `_scan_go`'s redirection arm ('>'*|'<'* at
# hooks/pre-tool-use.sh ~1153) marks only the delimiter WORD immediately after `<<`/`<<-` as an
# inert redirect target; the heredoc BODY -- everything from there to the real terminator line --
# is then fed through ordinary quote/comment/operator scanning exactly as if it were live command
# text. A real shell never re-tokenizes a heredoc body; it copies it verbatim (with only
# $-expansion, and not even that behind a quoted delimiter) to the terminator. When the body
# carries an ODD raw count of one quote character, the scanner's "still inside a quote" state does
# not close at the body's real end -- it leaks past the terminator line into whatever follows,
# including a bare `git add -A`, which is then read as inert quoted text instead of its own
# invocation. Every row below is a real, syntactically valid Bash command a real shell accepts;
# nothing here asserts on the scanner's internal state names.
#
# EVERY ROW FAILS AT THE REVIEWED COMMIT (no heredoc-body opacity exists at all), ON ITS OWN LINE.

suite "#140 AC1: the 12-cell heredoc-body-opacity matrix (9 bare << cells + 3 delimiter-spelling cells)"

HD_TAB=$'\t'

# Three bodies, each varying which single raw quote character appears an ODD number of times, and
# a balanced control. Built with real embedded newlines (a heredoc body is multi-line by nature).
HD_ODD_DQ="line one
say \"hi
line three"
HD_ODD_SQ="line one
it's fine
line three"
HD_BAL="line one
say \"hi\" and 'bye'
line three"

HD_BLANKET='git add -A'
HD_NARROW='git add plugins/pipeline/agents/dba.md'

# hd_verdict <heredoc-intro-line, e.g. "cat <<EOF"> <body> <terminator-line> <tail-cmd>
hd_verdict() {
  sub_verdict "$P4" "$1
$2
$3
$4"
}

# ---- 9 cells: bare << introducer, {odd-dq, odd-sq, balanced} x {blanket, narrow} + 3 no-heredoc --
for parity in odd_dq odd_sq balanced; do
  case "$parity" in
    odd_dq) BODY="$HD_ODD_DQ" ;;
    odd_sq) BODY="$HD_ODD_SQ" ;;
    balanced) BODY="$HD_BAL" ;;
  esac
  assert_eq "#140 AC1 (bare <<, $parity body, blanket 'git add -A' after the real terminator): deny" \
    "$(hd_verdict 'cat <<EOF' "$BODY" 'EOF' "$HD_BLANKET")" "deny"
  assert_eq "#140 AC1 (bare <<, $parity body, narrow 'git add <path>' after the real terminator): none" \
    "$(hd_verdict 'cat <<EOF' "$BODY" 'EOF' "$HD_NARROW")" "none"
done
# The "no heredoc at all" context. An unterminated raw quote outside a heredoc is a real shell
# SYNTAX ERROR, so odd/even is expressed here by NESTING one quote character inside the other kind
# rather than by leaving anything actually open -- every row below is valid, ordinary shell text,
# and none of them invoke git. This proves the fix leaves plain (non-heredoc) quote scanning alone.
assert_eq "#140 AC1 (no heredoc, balanced: echo \"git add -A\"): none" \
  "$(sub_verdict "$P4" 'echo "git add -A"')" "none"
assert_eq "#140 AC1 (no heredoc, odd single-quote raw count nested in a double-quoted string): none" \
  "$(sub_verdict "$P4" "echo \"git add -A; it's fine\"")" "none"
assert_eq "#140 AC1 (no heredoc, odd double-quote raw count nested in a single-quoted string): none" \
  "$(sub_verdict "$P4" "echo 'git add -A; he said \"hi'")" "none"

# ---- 3 cells: the delimiter-introducer-spelling axis, odd-dq body, blanket stage -----------------
# SecOps's round-1 oracle (review.secops.json concerns[0]) independently reproduced all three of
# these genuinely invoking `git add -A` in real bash while the reviewed-commit gate answered
# 'none' for all three -- the same leak as the bare-<< case, on every legal delimiter spelling.
assert_eq "#140 AC1 (delimiter spelling <<- with a TAB-indented terminator, odd-dq body, blanket): deny" \
  "$(hd_verdict 'cat <<-EOF' "$HD_ODD_DQ" "${HD_TAB}EOF" "$HD_BLANKET")" "deny"
assert_eq "#140 AC1 (delimiter spelling <<'EOF' single-quoted, odd-dq body, blanket): deny" \
  "$(hd_verdict "cat <<'EOF'" "$HD_ODD_DQ" 'EOF' "$HD_BLANKET")" "deny"
assert_eq "#140 AC1 (delimiter spelling <<\\EOF backslash-escaped, odd-dq body, blanket): deny" \
  "$(hd_verdict 'cat <<\EOF' "$HD_ODD_DQ" 'EOF' "$HD_BLANKET")" "deny"

# =================================================================================================
suite "#140 AC2: genuinely-quoted staging text stays ALLOWED, both before and after the fix"
# =================================================================================================
# Stated as its own criterion (spec.json: "so it cannot be traded away for AC1") precisely because
# a fix implemented as "opaque anything that looks like a quote" would satisfy AC1 by ALSO denying
# ordinary quoted mentions, which is a different and unacceptable failure mode.
assert_eq "#140 AC2: echo \"git add -A\" (restated as its own row per spec.json's explicit anti-trade-away text; also asserted above as AC1's no-heredoc balanced cell)" \
  "$(sub_verdict "$P4" 'echo "git add -A"')" "none"
assert_eq "#140 AC2: a SECOND genuinely-quoted staging string, distinct wording, inside a printf argument and not inside any heredoc" \
  "$(sub_verdict "$P4" 'printf "run git add -A yourself\n"')" "none"

# =================================================================================================
suite "#140 AC3: the core defect / primary red-green pair"
# =================================================================================================
assert_eq "#140 AC3: an ODD double-quote-count heredoc body followed by git add -A after the real terminator -> deny post-fix (returns 'none' pre-fix: the leaked quote-open state swallows the terminator line and the trailing git add -A as inert quoted text)" \
  "$(hd_verdict 'cat <<EOF' "$HD_ODD_DQ" 'EOF' "$HD_BLANKET")" "deny"

# =================================================================================================
suite "#140 AC4: a BALANCED heredoc body stays denied -- the fix discriminates rather than always-allows"
# =================================================================================================
assert_eq "#140 AC4: an EVEN (already-balanced) heredoc body followed by git add -A continues to return deny post-fix (it was already deny pre-fix, by the pre-fix scanner's unrelated newline-as-separator behavior -- proving the fix parses rather than blanket-denies every heredoc)" \
  "$(hd_verdict 'cat <<EOF' "$HD_BAL" 'EOF' "$HD_BLANKET")" "deny"

# =================================================================================================
suite "#140 AC5: a narrowly-scoped git add <path> after the real terminator stays ALLOWED -- no new false positive"
# =================================================================================================
assert_eq "#140 AC5: odd-dq heredoc body + git add <path> after the real terminator -> none" \
  "$(hd_verdict 'cat <<EOF' "$HD_ODD_DQ" 'EOF' "$HD_NARROW")" "none"
assert_eq "#140 AC5: balanced heredoc body + git add <path> after the real terminator -> none" \
  "$(hd_verdict 'cat <<EOF' "$HD_BAL" 'EOF' "$HD_NARROW")" "none"

# =================================================================================================
suite "#140 AC6: dens_pad() no longer force-balances quote parity, and the resulting body still denies"
# =================================================================================================
# R5/AC6: the quote-balancing patch in dens_pad() (above, DENSITY AXIS block) is reverted and its
# comment corrected -- both done directly in that function. This row proves the REVERTED function's
# own output, whatever raw quote parity truncation happens to leave it with, still denies once
# heredoc opacity exists. The `quotes` kind repeats the 4-byte unit `"a" ` (2 double quotes per
# unit); at a length that is a multiple of 4, or 3 mod 4, truncation lands on a unit boundary or
# takes a matched quote pair and the count stays EVEN (measured: 511 -> 256, still balanced -- not
# useful as a fixture for THIS row). At 1 or 2 mod 4 truncation stops mid-unit after exactly one of
# the pair's two quote characters, which IS unbalanced. 509 (509 mod 4 == 1) was measured to leave
# a raw count of 255 -- odd -- which is the exact shape the old padding existed to prevent dens_pad
# from ever producing; the VACUITY row below re-derives this on every run rather than trusting the
# comment's arithmetic.
DPAD_BODY="$(dens_pad quotes 509)"
DPAD_DQ_RAW="$(printf '%s' "$DPAD_BODY" | tr -cd '"' | wc -c | tr -d ' ')"
record "#140 AC6: dens_pad('quotes', 509) raw double-quote count = ${DPAD_DQ_RAW}"
assert_eq "#140 AC6 VACUITY: the chosen length genuinely leaves dens_pad()'s output with an UNBALANCED (odd) raw double-quote count -- without this, the row below would not be exercising the unbalanced case the old padding used to prevent" \
  "$(( DPAD_DQ_RAW % 2 ))" "1"
assert_eq "#140 AC6: dens_pad()'s own generated body (509 bytes, quote parity left as truncation leaves it, genuinely unbalanced per the row above), followed by a blanket stage after the real terminator -> deny" \
  "$(hd_verdict "cat <<'EOF'" "$DPAD_BODY" 'EOF' "$HD_BLANKET")" "deny"
assert_eq "#140 AC6: the reverted function still produces exactly the requested length (509 bytes) -- the DENSITY AXIS block's own VACUITY premise is unaffected by removing the balance" \
  "${#DPAD_BODY}" "509"

# =================================================================================================
suite "#140 AC7: no regression on the existing WORD-BOUNDARY AXIS / DENSITY AXIS suites"
# =================================================================================================
# R7/AC7 requires no new bypass or timing regression on the suites already in this file. There is
# no new probe here by design: AC7 is discharged by the WORD-BOUNDARY AXIS and DENSITY AXIS blocks
# above (which this same file run already re-measures against the post-fix tree, on every run,
# including the DENSITY AXIS heredoc probes whose dens_pad() bodies AC6 just stopped force-
# balancing) rather than by a duplicate timing harness here. A second, independent timing rig would
# measure the runner rather than the gate (see evidence.md's rendered-measurement rule).
record "#140 AC7: discharged by the pre-existing AC7 LENGTH/WORD-BOUNDARY/DENSITY AXIS blocks above, re-measured against this same post-fix tree on every run of this file -- not a separate probe"

# =================================================================================================
suite "#140 AC8: the tracked reproduction file (knowledge/issue-archive/40-verify-40.sh), re-derived"
# =================================================================================================
AC8_FILE="$GATE_REPO_ROOT/knowledge/issue-archive/40-verify-40.sh"
assert_eq "#140 AC8 VACUITY: the reproduction file exists and is non-empty (an absent/empty file makes the row below pass on nothing)" \
  "$([[ -s "$AC8_FILE" ]] && echo present || echo "MISSING: $AC8_FILE")" "present"
AC8_BYTES="$(wc -c < "$AC8_FILE" 2>/dev/null | tr -d ' ')"
record "#140 AC8: ${AC8_FILE} is ${AC8_BYTES} bytes at this commit -- re-derived, not trusted from the issue's own 137,457-byte command-string figure (spec.json measured_state: that figure is the constructed command string, not this file's raw size)"
AC8_BODY="$(cat "$AC8_FILE" 2>/dev/null)"
assert_eq "#140 AC8: the tracked file staged as a heredoc body in the same Bash call, followed by git add -A after the real terminator -> deny" \
  "$(sub_verdict "$P4" "cat <<'PIPELINE_140_EOF'
$AC8_BODY
PIPELINE_140_EOF
$HD_BLANKET")" "deny"

# =================================================================================================
suite "#140 AC9: the <<- tab-strip mechanism discriminates rather than leaving <<- unhandled or blanket-denying it"
# =================================================================================================
assert_eq "#140 AC9: a BALANCED-quote body inside a <<- heredoc (TAB-indented terminator), followed by git add -A after the real terminator -> deny (the AC4-equivalent discrimination proof for the newly-introduced dash-strip mechanism)" \
  "$(hd_verdict 'cat <<-EOF' "$HD_BAL" "${HD_TAB}EOF" "$HD_BLANKET")" "deny"

# =================================================================================================
suite "#140 AC10: no new false positive on the widened delimiter-spelling axis"
# =================================================================================================
assert_eq "#140 AC10: a <<- heredoc (TAB-indented terminator) followed by git add <path> after the real terminator -> none" \
  "$(hd_verdict 'cat <<-EOF' "$HD_BAL" "${HD_TAB}EOF" "$HD_NARROW")" "none"
assert_eq "#140 AC10: a single-quoted-delimiter <<'EOF' heredoc followed by git add <path> after the real terminator -> none" \
  "$(hd_verdict "cat <<'EOF'" "$HD_BAL" 'EOF' "$HD_NARROW")" "none"

# =================================================================================================
suite "#140 AC11: named negative controls -- here-string and process substitution are NOT heredocs"
# =================================================================================================
# All four verdicts taken verbatim from SecOps's round-1 real-shell-plus-recording-git-shim oracle
# (review.secops.json concerns[1]), re-verified against the fixed gate rather than re-derived here.
assert_eq "#140 AC11(a): here-string with a genuine 'git add -A' STRING operand (fed to cat's stdin; no git process ever runs) -> none" \
  "$(sub_verdict "$P4" "cat <<< 'git add -A'")" "none"
assert_eq "#140 AC11(b): a here-string whose quote is deliberately left unterminated across a line, trailing git add -A -> none (real bash: the whole construction is a syntax error and nothing ever executes)" \
  "$(sub_verdict "$P4" "cat <<< 'unterminated
git add -A")" "none"
assert_eq "#140 AC11(c): process substitution wrapping a real git add -A -> deny" \
  "$(sub_verdict "$P4" 'diff <(git add -A) /dev/null')" "deny"
assert_eq "#140 AC11(d): a narrow-stage-inside-process-substitution / blanket-stage-outside combination -> deny" \
  "$(sub_verdict "$P4" 'diff <(git add x.txt) /dev/null; git add -A')" "deny"

# =================================================================================================
suite "#140 AC12: the unquoted-introducer coarse \$( / backtick / \${ guard (SecOps's Phase 2.5 VETO)"
# =================================================================================================
# Full body opacity (AC1-AC11) for an UNQUOTED heredoc introducer must not silently flip a
# currently-denied live construction to 'none'. All 4 fixture cells are verbatim from
# secops-2.5-ruling.json's required_negative_and_positive_fixture_cells (spec.json AC12), plus one
# extra, explicitly-labeled non-required cell covering '${' per SecOps's own low-severity note.
AC12_DOLLAR_BLANKET="before
\$(git add -A)
after"
AC12_DOLLAR_NARROW="before
\$(git add plugins/pipeline/agents/dba.md)
after"
AC12_BACKTICK_BLANKET="before
\`git add -A\`
after"

assert_eq "#140 AC12(a) [PRIMARY VETO-CLOSING PAIR]: unquoted <<EOF body containing \$(git add -A), no terminator-adjacent trailing command at all -> deny post-fix (already deny pre-fix via the accidental top-level '(' -separator mechanism; full opacity with no guard would silently flip this to 'none')" \
  "$(sub_verdict "$P4" "cat <<EOF
$AC12_DOLLAR_BLANKET
EOF")" "deny"
assert_eq "#140 AC12(b) [discrimination proof, the AC5/AC10-equivalent for AC12]: unquoted <<EOF body containing \$(git add <path>) (narrow) -> none post-fix, proving the guard discriminates blanket vs narrow rather than blanket-denying every '\$(' occurrence regardless of content" \
  "$(sub_verdict "$P4" "cat <<EOF
$AC12_DOLLAR_NARROW
EOF")" "none"
assert_eq "#140 AC12(c) [genuinely NEW protection, not preserved: 'none' pre-fix because backtick is not in the scanner's structural-character set today]: unquoted <<EOF body containing backtick-wrapped git add -A -> deny post-fix" \
  "$(sub_verdict "$P4" "cat <<EOF
$AC12_BACKTICK_BLANKET
EOF")" "deny"
assert_eq "#140 AC12(d)/1 [non-weakening guard]: quoted-delimiter <<'EOF' body containing \$(git add -A) -> none post-fix (full opacity for a QUOTED delimiter is correct per AC1/R1 and must not be second-guessed by AC12's narrower unquoted-only guard)" \
  "$(sub_verdict "$P4" "cat <<'EOF'
$AC12_DOLLAR_BLANKET
EOF")" "none"
assert_eq "#140 AC12(d)/2 [non-weakening guard]: quoted-delimiter <<'EOF' body containing backtick-wrapped git add -A -> none post-fix" \
  "$(sub_verdict "$P4" "cat <<'EOF'
$AC12_BACKTICK_BLANKET
EOF")" "none"
# EXTRA, NON-REQUIRED CELL (SecOps concerns[0], low severity, explicitly non-blocking): '${' is the
# third $-expansion spelling named by AC12's own text as governed by the same coarse rule, though
# SecOps's ruling ran no dedicated real-shell '${' reproduction. Included so the regression
# population does not silently omit the spelling AC12's prose already commits to covering.
AC12_BRACE_BODY="before
\${SOMEVAR}
after"
assert_eq "#140 AC12 EXTRA (non-blocking, SecOps concerns[0], not one of the 4 required fixture cells): unquoted <<EOF body containing \${SOMEVAR} with no \$( or backtick present -> deny, per the coarse rule's own text (deny on sighting any of the three sequences)" \
  "$(sub_verdict "$P4" "cat <<EOF
$AC12_BRACE_BODY
EOF")" "deny"

finish
