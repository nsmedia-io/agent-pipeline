#!/usr/bin/env bash
# The CONSUMERS of issue #30's three changes: the boundary case that asserts the bug, the two
# cross-file pointers at it, the two prose enumerations, and the commit-subject collision.
#
# BEHAVIOURAL CONTRACT, authored at Phase 3a before the implementation exists.
#
# WHY THESE LIVE IN THEIR OWN FILE. Every assertion here is about a site the #30 diff changes
# INDIRECTLY. test-issue17-integration.sh:963 and :966-971 are cross-file consumers of a label
# in the GATE suite, in a file a #16-scoped diff would never open; pipeline.md:534 and
# README.md's Upgrading section are prose readers that go stale rather than wrong. A diff-scoped
# audit is structurally blind to all four: the breakage lives in the unchanged dependent, so it
# never appears in `git diff origin/main...HEAD`.
#
# THE SHAPE THIS FILE DEFENDS AGAINST is "satisfy the requirement by deleting the assertion".
# A8 and A9 both say INVERT, do not delete: a boundary that silently disappears when it moves
# leaves the next reader with no way to tell coverage from a guarantee. AC19's floors are what
# make deletion cost something.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

PLUGIN_DIR="$PLUGIN_ROOT"
TESTS_DIR="$PLUGIN_DIR/tests"
GATE_SUITE="$TESTS_DIR/test-gate-pre-phase4.sh"
TELEM_SUITE="$TESTS_DIR/test-pipeline-telemetry.sh"
R17_SUITE="$TESTS_DIR/test-issue17-integration.sh"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"
README="$PLUGIN_DIR/README.md"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"

suite "AC5/A8: the boundary case is INVERTED IN PLACE, not deleted"

GATE_TEXT=$(cat "$GATE_SUITE")
# The case itself must survive. Its fixture path is the stable identifier: the label changes,
# the migration does not.
assert_contains "AC5: the executable-down case still exists" "$GATE_TEXT" "023_exec_down.sql"
# ...and it must no longer assert the BUG.
assert_eq "AC5: it no longer asserts that an executable down region passes" \
  "$(grep -cF 'an executable (uncommented) down region passes today' "$GATE_SUITE" | tr -d ' ')" "0"
assert_eq "AC5: the 'KNOWN GAP' label is gone" \
  "$(grep -cF 'KNOWN GAP' "$GATE_SUITE" | tr -d ' ')" "0"
assert_eq "AC5: and so is the 'BOUNDARY' label on that case" \
  "$(grep -cF 'BOUNDARY: an executable' "$GATE_SUITE" | tr -d ' ')" "0"
# A8's other half: replace the label with a STATEMENT of the now-guaranteed behaviour, so a
# reader can still tell coverage from a guarantee. The tracked-gap pointer is what must go.
assert_eq "AC5: the case no longer points at #16 as an open gap" \
  "$(grep -cF 'Tracked as follow-up issue #16' "$GATE_SUITE" | tr -d ' ')" "0"

suite "AC6/A9: the two CROSS-FILE consumers assert the CLOSED state"

R17_TEXT=$(cat "$R17_SUITE")
# :963 today asserts `grep -c 'Tracked as follow-up issue #16' == 1` in the gate suite. It goes
# red the moment the label is replaced, in a file a #16-scoped diff would never open.
assert_eq "AC6: the gate-suite pointer no longer expects a tracked #16 gap" \
  "$(grep -cF "grep -c 'Tracked as follow-up issue #16'" "$R17_SUITE" | tr -d ' ')" "0"
# ...but it must still ASSERT something about that site. A9 says update, not delete.
assert_contains "AC6: the site still asserts the executable-down state, now as closed" \
  "$R17_TEXT" "executable-down"
# :966-971 resolves #16's LIVE title. The pointer is resolved against the issue's TITLE, not by
# asserting a digit is present -- a digit-only check would accept any issue number.
assert_contains "AC6: the #16 title resolution survives as a live check" "$R17_TEXT" "executable down section"
# NOTE, and this is why the whole-suite-green half of AC6 is NOT run here: test-issue17-
# integration.sh takes about four minutes and is run by run.sh and by CI. Running it inside
# another suite would double that on every checkCommand invocation for no new information.

suite "AC19: both suites are green, and neither lost an assertion"

# The floors are the TRUE current values, not one below. A floor one below the current value
# lets exactly one assertion be deleted through the guard that exists to stop assertions being
# deleted -- which is precisely how requirement C could be "satisfied" by removing the ten
# assertions that defend the wrong convention.
#
# A BARE FLOOR DRIFTS, AND IT HAS DRIFTED TWICE. r1 set telemetry at 95 against a true 96; r3
# raised it to 96, and commits C6/C7 then took the suite to 99 without deleting anything, so
# three assertions could again be deleted in silence. Nothing about a legitimate addition makes
# a `>=` literal move: the guard degrades every time the thing it guards grows, and it degrades
# QUIETLY, which is the same claim-more-than-you-measured defect this issue is about.
#
# So each floor is pinned from BOTH sides. The `>=` half is the deletion guard and is what
# AC19 asks for. The `<=` half carries no safety claim at all -- it exists so that the next
# legitimate addition FAILS HERE, loudly, with the new number in the message, instead of
# silently opening a deletion window. Its failure is a two-character edit and a re-read of what
# was added; that is the price of a floor that tracks reality rather than the last person who
# remembered it. If this ever becomes an obstruction rather than a prompt, replace the literals
# with a mechanism, do not widen them.
# 56 -> 95 closing #31 (the up section is classified, not line-prefix matched) and #48 (an AC
# label is authoritative, and the token floor is proportional). Nothing was deleted: three
# suites were added, 22 + 11 + 6, each rule pinned in both directions with its own non-zero
# control. The alarm below is what forced this line to be re-read rather than the deletion
# window being opened by thirty-nine.
GATE_FLOOR=95
# 99 -> 106 in the Phase 4 fix round: one `unreadable == 0` pin over the LIVE corpus was
# REPLACED (a concurrent phase-transition write makes it a transient, not a defect) by five
# crafted cells that construct the half-written record on demand, plus two accounting
# assertions on the absolute-path walk. Net +7, and the alarm below is what forced this line to
# be re-read rather than the window being opened by one.
#
# 106 -> 107 for the archive redaction fix: the `the archive corpus is ... empty today` pin,
# a deliberate one-shot tripwire, fired when the first archive landed and was re-founded on the
# derived relation (every archive record enumerated is one the walk read), which is one cell
# for one cell -- plus a non-zero control, because that relation reads 0-of-0 while the archive
# directory is empty and a vacuous pass is what the pin was there to prevent. Net +1.
TELEM_FLOOR=107
run_suite() { bash "$1" 2>&1 | tail -1; }

GATE_LINE=$(run_suite "$GATE_SUITE")
GATE_PASSED=$(printf '%s' "$GATE_LINE" | sed -n 's/.*passed=\([0-9]*\).*/\1/p')
GATE_FAILED=$(printf '%s' "$GATE_LINE" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')
assert_eq "AC19: the gate suite reports failed=0" "$GATE_FAILED" "0"
assert_eq "AC19: and its assertion count has not decreased from $GATE_FLOOR" \
  "$([[ "${GATE_PASSED:-0}" -ge "$GATE_FLOOR" ]] && echo ok || echo "passed=$GATE_PASSED")" "ok"
assert_eq "AC19 DRIFT ALARM: the gate suite still measures $GATE_FLOOR -- raise GATE_FLOOR here if it grew" \
  "$([[ "${GATE_PASSED:-0}" -le "$GATE_FLOOR" ]] && echo ok || echo "grew to $GATE_PASSED, floor is $GATE_FLOOR")" "ok"

TELEM_LINE=$(run_suite "$TELEM_SUITE")
TELEM_PASSED=$(printf '%s' "$TELEM_LINE" | sed -n 's/.*passed=\([0-9]*\).*/\1/p')
TELEM_FAILED=$(printf '%s' "$TELEM_LINE" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')
assert_eq "AC19: the telemetry suite reports failed=0" "$TELEM_FAILED" "0"
assert_eq "AC19: and its assertion count has not decreased from $TELEM_FLOOR" \
  "$([[ "${TELEM_PASSED:-0}" -ge "$TELEM_FLOOR" ]] && echo ok || echo "passed=$TELEM_PASSED")" "ok"
assert_eq "AC19 DRIFT ALARM: the telemetry suite still measures $TELEM_FLOOR -- raise TELEM_FLOOR here if it grew" \
  "$([[ "${TELEM_PASSED:-0}" -le "$TELEM_FLOOR" ]] && echo ok || echo "grew to $TELEM_PASSED, floor is $TELEM_FLOOR")" "ok"

suite "AC23: the halt-cause enumeration is complete after A and B"

# The site does not OVERclaim, which is true and beside the point: an operator hitting a halt
# they cannot find in the list has a diagnosis gap. The enumeration is the first place they look.
HALT_LINE=$(grep -n 'absent or unparseable artifact, schema violation' "$PIPELINE_MD" | head -1)
assert_eq "AC23 CONTROL: the halt enumeration is still where this assertion looks" \
  "$([[ -n "$HALT_LINE" ]] && echo found || echo missing)" "found"
HALT_TEXT=$(grep -A2 'absent or unparseable artifact, schema violation' "$PIPELINE_MD" | head -3)
assert_contains "AC23: it names the executable-down-region halt" "$HALT_TEXT" "executable"
assert_contains "AC23: and the unterminated-block-comment halt" "$HALT_TEXT" "unterminated block comment"
assert_contains "AC23: and the empty-down halt that commit B adds" "$HALT_TEXT" "empty down"

suite "AC29: the Upgrading section's count word equals the bullets beneath it"

# A stale count above the bullets is the SAME claim-more-than-you-measured defect, in the very
# document that announces this fix. The count is asserted, not just the presence of the two new
# bullets: presence alone cannot catch a stale count.
UPGRADE=$(awk '/^### Upgrading$/{f=1} f{print} /^Four more customization points:/{if(f)exit}' "$README")
BULLETS=$(printf '%s\n' "$UPGRADE" | grep -cE '^[0-9]+\. ' | tr -d ' ')
assert_eq "AC29 CONTROL: the Upgrading section was found and has numbered bullets" \
  "$([[ "${BULLETS:-0}" -ge 3 ]] && echo ok || echo "bullets=$BULLETS")" "ok"
# There are TWO count words in that lead paragraph today ("Three changes ... there are three
# things to know"). Both must move, or the section contradicts itself one sentence later.
COUNT_WORDS=$(printf '%s\n' "$UPGRADE" | grep -oiE '\b(one|two|three|four|five|six|seven)\b' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')
WORD_FOR=$(node -e 'const w=["zero","one","two","three","four","five","six","seven","eight","nine"];console.log(w[Number(process.argv[1])]||"?")' "$BULLETS")
assert_eq "AC29: every count word in the lead paragraph matches the bullet count" \
  "$(printf '%s\n' "$UPGRADE" | sed -n '1,4p' | grep -oiE '\b(one|two|three|four|five|six|seven)\b' | tr 'A-Z' 'a-z' | sort -u | grep -v "^$WORD_FOR$" | tr '\n' ',')" \
  ""
# The two new bullets, asserted INDEPENDENTLY of the count so each can redden alone.
assert_contains "AC29: a bullet names the gate's new refusal" "$UPGRADE" "executable SQL"
assert_contains "AC29: a bullet names the telemetry relabel" "$UPGRADE" "phase_elapsed_ms"
assert_contains "AC29: and tells a reader to read \`attribution\` to know which convention applies" \
  "$UPGRADE" "attribution"
# A7(a)'s REAL cost. r2's blanket "the remedy is one line" was wrong here: a `#`-convention down
# region has EVERY line refused, so the remedy is a per-line substitution across every migration
# this pipeline touches -- the same permanent-failure blast radius A1 exists to prevent,
# arriving by a different path. Asserted separately from the count word, so the r3 clause is
# proven asserted rather than carried incidentally.
assert_contains "AC29: the gate bullet states the MySQL \`#\` line-comment cost" "$UPGRADE" "# line comment"
assert_contains "AC29: named as a per-line substitution, not a one-line edit" "$UPGRADE" "per-line"
# And the adopter must not be able to read A1's marker fix as covering it. Two different
# failures, named separately in the same bullet.
assert_contains "AC29: and states that the marker fix does not cover a \`#\`-written down BODY" \
  "$UPGRADE" "down BODY"

suite "AC30: no commit subject on this branch collides with R17's frozen delimiters"

# test-issue17-integration.sh resolves R17's frozen series anchors by exact-substring match on
# commit SUBJECT, NEWEST MATCH FIRST, and its own header records that this delimiter has gone
# stale three times. A near-duplicate would NOT fail loudly: it would silently shift which sha
# `head -1` returns for a frozen anchor. Requirement C's subject matter is thematically adjacent
# to R17's already-shipped 'fix: telemetry attributes suffixed phase labels'.
#
# THE DELIMITERS ARE DERIVED FROM THE FILE, NEVER HAND-COPIED. A copied list restates the
# contract instead of observing it, so it would track whoever last remembered to update it --
# which is the exact defect class this whole issue is about.
DELIMS=$(awk '
  /^SERIES_FIRST_SUBJECT=/ || /^SERIES_LAST_SUBJECT=/ {
    line=$0; sub(/^[A-Z_]+=/,"",line); gsub(/^['"'"'"]|['"'"'"]$/,"",line); print line; next
  }
  /^ROUND1_SUBJECTS=\(/ || /^CLOSED_ROUND_TIPS=\(/ { inarr=1; next }
  inarr && /^\)/ { inarr=0; next }
  inarr {
    line=$0; sub(/#.*$/,"",line); gsub(/^[ \t]+|[ \t]+$/,"",line);
    if (line ~ /^\$/ || line ~ /^"\$/) next;
    gsub(/^['"'"'"]|['"'"'"]$/,"",line);
    if (length(line)) print line
  }' "$R17_SUITE")
DELIM_COUNT=$(printf '%s\n' "$DELIMS" | grep -c . | tr -d ' ')
# NON-ZERO CONTROL. Without it, an extractor that matched nothing would report "0 collisions"
# and read as a pass -- a zero over an empty population.
assert_eq "AC30 CONTROL: the delimiter set was actually extracted" \
  "$([[ "$DELIM_COUNT" -ge 10 ]] && echo ok || echo "found=$DELIM_COUNT")" "ok"

BRANCH_SUBJECTS=$(cd "$REPO_ROOT" && git log --format=%s origin/main..HEAD 2>/dev/null)
COLLISIONS=""
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    [[ "$s" == *"$d"* ]] && COLLISIONS="$COLLISIONS[$s <- $d]"
  done <<< "$BRANCH_SUBJECTS"
done <<< "$DELIMS"
# On the INTEGRATION BRANCH itself `origin/main..HEAD` is empty, and that is not a failure --
# it is the same "population derived from a ref that moves" defect that broke the R17 series
# delimiters once already, arriving in a newer assertion. An empty range here is not "nothing
# to check": every delimiter IS a real commit subject, so over full history each one matches
# its own commit, and the property "no OTHER commit contains a delimiter" is exactly what the
# resolves-to-exactly-one assertion below already enforces over full history. So on the
# integration branch this half is SUBSUMED, and says so, rather than asserting over an empty
# set (which passes for the wrong reason) or demanding a population that cannot exist.
assert_eq "AC30: no subject on this branch contains a frozen delimiter" "$COLLISIONS" ""
assert_eq "AC30 CONTROL: the population was real, or is subsumed on the integration branch" \
  "$(if [[ -n "$BRANCH_SUBJECTS" ]]; then echo ok; \
     elif [[ -z "$(cd "$REPO_ROOT" && git log --format=%s origin/main..HEAD 2>/dev/null)" ]]; then echo ok; \
     else echo "no subjects and not on the integration branch"; fi)" "ok"

# The other half: each delimiter must still resolve to EXACTLY ONE commit. A collision that
# shifts `head -1` shows up here as a 2.
AMBIGUOUS=""
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  n=$( (cd "$REPO_ROOT" && git log --format=%s) | grep -cF "$d" | tr -d ' ')
  [[ "$n" == "1" ]] || AMBIGUOUS="$AMBIGUOUS[$d => $n]"
done <<< "$DELIMS"
assert_eq "AC30: every frozen delimiter still resolves to exactly one commit" "$AMBIGUOUS" ""

finish
