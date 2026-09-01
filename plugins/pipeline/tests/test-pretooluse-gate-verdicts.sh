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
LEN_BOUND_MS=$(( LEN_TIMEOUT_S * 1000 ))
assert_eq "VACUITY: hooks.json declares a positive PreToolUse timeout to bound against (read, not transcribed): ${LEN_TIMEOUT_S}s" \
  "$([[ "$LEN_BOUND_MS" -gt 0 ]] && echo declared || echo "MISSING: [$LEN_TIMEOUT_S]")" "declared"

len_now_ms() { "$GATE_REAL_NODE" -e 'process.stdout.write(String(Date.now()))'; }
LEN_WORST_MS=0
LEN_SLOW=""
len_probe() {  # <label> <command> <expected-verdict>
  local a b el
  a="$(len_now_ms)"
  local v; v="$(sub_verdict "$P4" "$2")"
  b="$(len_now_ms)"
  el=$(( b - a ))
  [[ "$el" -gt "$LEN_WORST_MS" ]] && LEN_WORST_MS="$el"
  [[ "$el" -lt "$LEN_BOUND_MS" ]] || LEN_SLOW="$LEN_SLOW
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
assert_eq "AC7 LENGTH: every probe above returned inside the ${LEN_TIMEOUT_S}s the declaration commits to (worst ${LEN_WORST_MS} ms). A hook killed at its declared timeout emits nothing and the call is ALLOWED, so a row over this bound is a bypass, not a slow test" \
  "$LEN_SLOW" ""
record "LENGTH AXIS worst observed: ${LEN_WORST_MS} ms against a declared bound of ${LEN_BOUND_MS} ms, on $(uname -sr)"

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

finish
