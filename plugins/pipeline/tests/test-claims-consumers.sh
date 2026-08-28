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

suite "AC19: both suites are green, and the assertion SET is pinned BY NAME (#33)"

# WHAT A COUNT COULD NOT DO, MEASURED TWICE BEFORE THIS WAS WRITTEN.
#
# AC19 asks that neither guarded suite lose an assertion. That was a `>=` floor against a
# literal, and a bare floor DECAYS every time the suite it guards legitimately grows -- quietly,
# because nothing forces the literal up. It happened at 95 against a true 96, and again at 96
# against a true 99, at which point three assertions could have been deleted in silence: exactly
# the defect the floor exists to prevent, arriving through the floor. #30 landed a two-sided pin
# as an interim patch -- the `>=` half caught deletion, a `<=` DRIFT ALARM caught growth -- and
# QA's position on it was that the alarm is "a patch on the symptom, not the cause" and must not
# be removed until the real fix exists. This is the real fix, so the four literals are gone.
#
# THE SET, NOT THE COUNT. An integer says something changed. A label set says WHAT: a deletion is
# reported by the name of the assertion that vanished, and an addition is a diff a reviewer
# reads. Nothing here is a number a future author has to remember to raise.
#
# TO REFRESH A PIN after adding or renaming assertions -- and READ THE DIFF, that is the point:
#   bash tests/test-gate-pre-phase4.sh 2>/dev/null \
#     | sed -n -e 's/^  ok    //p' -e 's/^  FAIL  //p' | LC_ALL=C sort \
#     > tests/fixtures/labels/test-gate-pre-phase4.labels
#
# WHY fixtures/ AND NOT A HERE-DOC. The pins are read by this suite in a FRESH CHECKOUT too
# (AC41(c) clones the repo and runs run.sh inside it), so they have to be tracked files. Nothing
# under fixtures/ is reachable by run.sh's `test-*.sh` glob, which test-issue17-integration.sh
# asserts in both directions, so a pin is never mistaken for a suite.
#
# LC_ALL=C IS LOAD-BEARING. macOS and ubuntu-latest disagree about collation for anything but the
# C locale, and a pin sorted one way and compared the other reports every line as both missing
# and extra. Both sides of every comparison below are C-sorted.

new_tmpdir || exit 90
SCRATCH="$NEW_TMPDIR"
LABELS_DIR="$TESTS_DIR/fixtures/labels"

# The extraction is only possible because the harness prints one assertion per line in a fixed
# shape, so that shape is pinned HERE. Change it and this whole check would extract nothing and
# pass over an empty set -- a guard that reports success because it can no longer see anything.
HARNESS_SRC="$(cat "$TESTS_DIR/harness.sh")"
assert_contains "AC19: the harness still prints a passing assertion as '  ok    <label>'" \
  "$HARNESS_SRC" "'  ok    %s\n'"
assert_contains "AC19: and a failing one as '  FAIL  <label>'" \
  "$HARNESS_SRC" "'  FAIL  %s\n"

extract_labels() { sed -n -e 's/^  ok    //p' -e 's/^  FAIL  //p' "$1" | LC_ALL=C sort; }

pin_labels() {  # $1 = suite path
  local name out pin got missing extra
  name="$(basename "$1")"
  out="$SCRATCH/$name.out"
  got="$SCRATCH/$name.labels"
  pin="$LABELS_DIR/${name%.sh}.labels"
  bash "$1" > "$out" 2>/dev/null
  extract_labels "$out" > "$got"

  # Two vacuity controls, because every claim below is an EMPTY-difference claim and an empty
  # difference between two empty files is the easiest pass in the world to write by accident.
  assert_eq "AC19 CONTROL [$name]: the run produced labels (an empty extraction pins nothing)" \
    "$([[ -s "$got" ]] && echo ok || echo "extracted nothing from $out")" "ok"
  assert_eq "AC19 CONTROL [$name]: the pinned set exists and is non-empty" \
    "$([[ -s "$pin" ]] && echo ok || echo "MISSING: ${pin#"$TESTS_DIR/"}")" "ok"
  assert_eq "AC19 [$name]: the suite reports failed=0" \
    "$(sed -n 's/^passed=[0-9]* failed=\([0-9]*\)$/\1/p' "$out" | tail -1)" "0"

  # THE DELETION GUARD, which is what AC19 actually asks for -- and it now answers with a NAME.
  missing="$(LC_ALL=C comm -23 "$pin" "$got" | tr '\n' '|')"
  assert_eq "AC19 [$name]: no pinned assertion was DELETED" "$missing" ""
  # THE OTHER SIDE, which is what the DRIFT ALARM was standing in for: an addition is not a
  # failure of the suite, it is a prompt to read what was added and re-pin. The refresh command
  # is in the comment above this block.
  extra="$(LC_ALL=C comm -13 "$pin" "$got" | tr '\n' '|')"
  assert_eq "AC19 [$name]: and nothing was ADDED without the pin being re-read" "$extra" ""
}

pin_labels "$GATE_SUITE"
pin_labels "$TELEM_SUITE"

# NON-ZERO CONTROLS, IN BOTH DIRECTIONS, on a copy of a real pin. Without them the two empty
# differences above are equally satisfied by a comparison that cannot tell any two sets apart --
# which is the failure mode the count had, restated in a different instrument.
REAL_PIN="$LABELS_DIR/test-gate-pre-phase4.labels"
REAL_GOT="$SCRATCH/test-gate-pre-phase4.sh.labels"
DELETED_ONE="$SCRATCH/pin-minus-one.txt"
LC_ALL=C sort "$REAL_PIN" | tail -n +2 > "$DELETED_ONE"
FIRST_LABEL="$(head -1 "$REAL_PIN")"
assert_eq "CONTROL: the mutated pin really lost exactly one line" \
  "$(( $(grep -c . "$REAL_PIN") - $(grep -c . "$DELETED_ONE") ))" "1"
assert_contains "CONTROL: an ADDED assertion is reported by name, not as a delta" \
  "$(LC_ALL=C comm -13 "$DELETED_ONE" "$REAL_GOT")" "$FIRST_LABEL"
ADDED_ONE="$SCRATCH/pin-plus-one.txt"
{ cat "$REAL_PIN"; printf 'zzz an assertion the suite no longer emits\n'; } | LC_ALL=C sort > "$ADDED_ONE"
assert_contains "CONTROL: and a DELETED assertion is reported by name too" \
  "$(LC_ALL=C comm -23 "$ADDED_ONE" "$REAL_GOT")" "zzz an assertion the suite no longer emits"
# ...and the same comparison is SILENT on the unmutated pair, so the two controls above are
# discriminations rather than a comparison that reports everything.
assert_eq "CONTROL: and it reports nothing at all when the two sets agree" \
  "$(LC_ALL=C comm -3 "$REAL_PIN" "$REAL_GOT")" ""

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
# There are TWO count words in that lead paragraph ("Three changes ... there are three things
# to know"). Both must move, or the section contradicts itself one sentence later.
#
# THIS CHECK WAS VACUOUS FOR EVERY RELEASE ABOVE SEVEN, and that is why it is written this way
# now. The vocabulary was `one|two|three|four|five|six|seven` and the bullet->word map was a
# ten-element array, so once the section passed nine, `WORD_FOR` returned "?" and the scan
# matched no word at all: an empty set minus "?" is empty, and the assertion reported green over
# a population of ZERO. Measured on the shipped 0.27.0 README -- 20 bullets, lead word "Twenty",
# words matched: none. It only reddened when a later count word happened to CONTAIN a vocabulary
# token ("Twenty-five" -> "five"), which is a tripwire nobody designed.
#
# The parse is compound-aware and returns NUMBERS, so the comparison is against $BULLETS itself
# rather than against a spelling. The anti-vacuity control below is the half that was missing:
# a lead paragraph the parser reads NOTHING out of must be a failure, not a pass.
COUNT_NUMS=$(printf '%s\n' "$UPGRADE" | sed -n '1,4p' | tr '\n' ' ' | xargs -0 node "$TESTS_DIR/fixtures/count-words.mjs")
assert_eq "AC29 CONTROL: the lead paragraph actually yields a spelled count (an unparsed lead is not a pass)" \
  "$([[ -n "$COUNT_NUMS" ]] && echo found || echo "NOTHING PARSED: the assertion below would range over an empty set")" "found"
assert_eq "AC29: every count word in the lead paragraph matches the bullet count" \
  "$COUNT_NUMS" "$BULLETS"
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

suite "AC30: no commit subject anywhere in history collides with R17's frozen delimiters"

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

# THE POPULATION IS FULL HISTORY, NEVER A RANGE AGAINST A MOVING REF (#37).
#
# This block used to ask its question twice: once of `git log <moving-ref>..HEAD`, and once of
# full history. The first half was the very defect #37 ratchets against -- it broke `main` at
# #32's merge, was patched in #36 with a control that read "the population was real, OR is
# subsumed on the integration branch", and that control could not fail: its `elif` re-ran the
# identical command whose emptiness had already put it there, so an empty range answered `ok`
# and a non-empty one answered `ok`. Both halves of a two-sided control cannot be the same side.
#
# What is left is the half that was always doing the work, and it is STRICTLY STRONGER. A
# delimiter is a commit subject, so over full history it matches its own commit exactly once. If
# a new commit's subject contained one as a substring -- the collision that would silently shift
# which sha `head -1` returns for a frozen anchor -- that delimiter would resolve to 2. That
# holds on a branch, on `main`, after a rebase merge, and on a pull_request build whose HEAD is a
# merge commit this branch never authored. The range-based half could only ever see a branch it
# had not landed yet.
ALL_SUBJECTS=$(git -C "$REPO_ROOT" log --format=%s)
assert_eq "AC30 CONTROL: full history was actually read (an empty log reaches nothing, forever)" \
  "$([[ "$(printf '%s\n' "$ALL_SUBJECTS" | grep -c .)" -ge 10 ]] && echo ok || echo "read nothing")" "ok"

AMBIGUOUS=""
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  n=$(printf '%s\n' "$ALL_SUBJECTS" | grep -cF "$d" | tr -d ' ')
  [[ "$n" == "1" ]] || AMBIGUOUS="$AMBIGUOUS[$d => $n]"
done <<< "$DELIMS"
assert_eq "AC30: every frozen delimiter still resolves to exactly one commit, over FULL history" \
  "$AMBIGUOUS" ""

# NON-ZERO CONTROL for the resolver itself. Without it, the empty result above is equally
# satisfied by a counter that answers 1 to everything -- and "every delimiter is unique" is a
# claim about discrimination, so the discrimination is what has to be shown. `chore(` is a
# conventional-commit prefix this repo writes constantly, so it resolves to many; a string no
# subject carries resolves to none. Both are computed, neither is a pinned integer.
assert_eq "CONTROL: the same resolver reports MANY for a substring many subjects carry" \
  "$([[ "$(printf '%s\n' "$ALL_SUBJECTS" | grep -cF 'chore(' | tr -d ' ')" -gt 1 ]] && echo many || echo "not many")" \
  "many"
assert_eq "CONTROL: and NONE for a substring no subject carries" \
  "$(printf '%s\n' "$ALL_SUBJECTS" | grep -cF 'zzz-no-commit-subject-contains-this' | tr -d ' ')" "0"

finish
