#!/usr/bin/env bash
# The status.json CORPUS helper (issue #30, commit D).
#
# BEHAVIOURAL CONTRACT, authored at Phase 3a before the implementation exists.
#
# THE DEFECT. test-pipeline-telemetry.sh builds its corpus from `git ls-files` at three sites,
# so it cannot see a genuinely UNTRACKED in-flight record -- which is precisely where an
# absolute path actually gets written. The workaround adopted for that (committing one status
# record per issue) makes the suite's red/green a function of how far the run under review has
# itself progressed: the suite measured 95/1 and then 96/0 AT THE SAME COMMIT with nothing in
# plugins/ changed, because the corpus walk reads PATHS from `git ls-files` but CONTENT from
# disk, and this pipeline's own Phase 2 checkpoint appended an event to a record it walks.
#
# TWO CONSEQUENCES, and this file asserts both:
#   1. The population must be the UNION of the tracked set and an on-disk enumeration. Union
#      ONLY: it can widen the population, never narrow it (spec D2).
#   2. Anything asserted over the LIVE corpus is a function of the run under review, so the
#      partition property is asserted over CRAFTED fixtures in a temp `.pipeline` directory and
#      the live figure is REPORTED, never pinned (spec D6).
#
# ------------------------------------------------------------------------------------------
# TESTABILITY REQUIREMENT, flagged as such rather than smuggled in. AC27 asks for the helper to
# be "asserted by driving the helper with each pattern against a temp tree", and AC17 asks for
# five crafted cells against the in-flight predicate. A bash function buried mid-suite cannot
# be driven from another file, so this contract names the seam:
#
#   test-pipeline-telemetry.sh carries ONE marker-delimited block, in the idiom the agent
#   constraint checklists already use:
#
#       # --- BEGIN corpus helper (issue #30 D1) ---
#       ...
#       # --- END corpus helper ---
#
#   defining exactly two functions, which this file extracts and evals:
#
#     corpus_files <repo-root> <pattern> [<pattern>...]
#         Prints, one per line and deduplicated, every path matching ANY of the patterns,
#         relative to <repo-root>, as the UNION of `git ls-files` and an on-disk enumeration
#         for the SAME patterns. Patterns are globs, e.g. `.pipeline/*/status.json`.
#
#     in_flight_short <status-file>
#         Exit 0 when the record is a SHORT IN-FLIGHT record, exit non-zero otherwise. The
#         predicate is D7's, all three conjuncts: carries a current_phase AND
#         Array.isArray(events) AND events.length < 2. The middle conjunct is load-bearing --
#         tooShort's live definition is `!Array.isArray(events) || events.length < 2`, so
#         "has fewer than 2 events" restates half that definition back at itself and can
#         essentially never fail, while a MALFORMED record with a current_phase but NO events
#         array would satisfy it. An unreadable file must still exit non-zero.
#
# If Dev wants a different signature, that is a conversation with QA, not a test to weaken.
# ------------------------------------------------------------------------------------------

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"
SUITE="$PLUGIN_DIR/tests/test-pipeline-telemetry.sh"
TELEMETRY="$SCRIPTS_DIR/pipeline-telemetry.mjs"

BEGIN_MARK='# --- BEGIN corpus helper (issue #30 D1) ---'
END_MARK='# --- END corpus helper ---'

suite "AC15: ONE corpus-build helper, and the three former build sites all call it"

# Restated from "grep -c 'git ls-files' outside the helper is 0", which is UNSATISFIABLE:
# five occurrences exist and two of them stay on purpose -- :409 is a comment, and :548 is the
# archive-count pin that D3 keeps deliberately (it is a stated-not-assumed present-tense fact
# that is SUPPOSED to redden the day the first archive lands, and it is not a corpus build).
BEGIN_COUNT=$(grep -cF "$BEGIN_MARK" "$SUITE" | tr -d ' ')
END_COUNT=$(grep -cF "$END_MARK" "$SUITE" | tr -d ' ')
assert_eq "AC15: exactly one corpus-helper block is defined" "$BEGIN_COUNT" "1"
assert_eq "AC15: and it is closed exactly once" "$END_COUNT" "1"

# `git ls-files` OUTSIDE the helper block. The mutation this catches is "a call site builds its
# own corpus again", not "the string appears" -- which is why the count is 2 and not 0.
OUTSIDE=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0,b){inblk=1} index($0,e){inblk=0;next} !inblk && /git ls-files/{n++} END{print n+0}' "$SUITE")
assert_eq "AC15: the only \`git ls-files\` left outside the helper are the comment and the archive pin" \
  "$OUTSIDE" "2"
CALLS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0,b){inblk=1} index($0,e){inblk=0;next} !inblk && /corpus_files /{n++} END{print n+0}' "$SUITE")
assert_eq "AC15: and all three former build sites call the helper" \
  "$([[ "$CALLS" -ge 3 ]] && echo ok || echo "calls=$CALLS")" "ok"

# Extract and eval the helper block. Everything below drives the REAL helper; nothing below
# reimplements it, because a reimplementation would assert this file against itself.
HELPER_SRC="$TEMP_PROJECT/corpus-helper.sh"
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0,b){inblk=1;next} index($0,e){inblk=0} inblk{print}' "$SUITE" > "$HELPER_SRC"
if [[ -s "$HELPER_SRC" ]]; then
  # shellcheck disable=SC1090
  . "$HELPER_SRC"
fi
HAVE_HELPER=$(declare -f corpus_files >/dev/null 2>&1 && echo yes || echo no)
HAVE_PREDICATE=$(declare -f in_flight_short >/dev/null 2>&1 && echo yes || echo no)
assert_eq "AC15: \`corpus_files\` is defined by that block" "$HAVE_HELPER" "yes"
assert_eq "AC17: \`in_flight_short\` is defined by that block" "$HAVE_PREDICATE" "yes"

# Every case below needs the helper. Stub it so each assertion fails for its OWN reason with a
# message about the missing behaviour, rather than N of them dying on `command not found` --
# a contract that collapses into one error tells Dev nothing about which cell is unmet.
if [[ "$HAVE_HELPER" != "yes" ]]; then
  corpus_files() { printf 'CORPUS_HELPER_NOT_IMPLEMENTED\n'; return 0; }
fi
if [[ "$HAVE_PREDICATE" != "yes" ]]; then
  # It prints, so that while the predicate is absent ALL FIVE cells below fail for their own
  # reason. A stub that merely returned non-zero would leave the four REJECT cells green and
  # only the ACCEPT cell red, which is a contract that reports four passes for a predicate
  # that does not exist.
  in_flight_short() { printf 'IN_FLIGHT_PREDICATE_NOT_IMPLEMENTED'; return 1; }
fi

# ---- the temp tree every driven case runs against --------------------------------------
# A real git repo, so `git ls-files` has something to say and the TRACKED and ON-DISK halves
# are genuinely different sets. NOTHING here is written into the checkout.
new_tmpdir || exit 90
TREE="$NEW_TMPDIR"
git -C "$TREE" init -q
mkdir -p "$TREE/.pipeline/17" "$TREE/.pipeline/99" "$TREE/knowledge/issue-archive"
printf '%s' '{"current_phase":"5-archive","events":[{"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T00:00:00Z"},{"phase":"5-archive","verdict":"DONE","at":"2026-08-01T02:00:00Z"}]}' \
  > "$TREE/.pipeline/17/status.json"
printf '%s' '{"issue":17,"archived_at":"2026-08-01T03:00:00Z"}' \
  > "$TREE/knowledge/issue-archive/17.json"
git -C "$TREE" add -A -f >/dev/null 2>&1
git -C "$TREE" -c user.email=t@t -c user.name=t commit -q -m init
# The UNTRACKED in-flight record, written AFTER the commit. This is the record `git ls-files`
# structurally cannot see, and the one that actually carries an absolute path in real life.
printf '%s' '{"current_phase":"3-impl","worktree_path":"/Users/someone/x","events":[{"phase":"0.5-map","verdict":"OK","at":"2026-08-02T00:00:00Z"}]}' \
  > "$TREE/.pipeline/99/status.json"

PIPELINE_PATTERN='.pipeline/*/status.json'
ARCHIVE_PATTERN='knowledge/issue-archive/*.json'

suite "AC16: the union sees the UNTRACKED record -- the class-level control for #22"

UNION=$(corpus_files "$TREE" "$PIPELINE_PATTERN" | sort)
assert_contains "AC16: the untracked in-flight record is in the corpus" \
  "$UNION" ".pipeline/99/status.json"
assert_contains "AC16 CONTROL: and the tracked record is still there (union, never replace)" \
  "$UNION" ".pipeline/17/status.json"
# The absolute path is the thing the AC34 walk exists to catch, and it lives in the file only
# the union can reach. Asserted through the corpus rather than by reading the file directly:
# a hit that does not come via the corpus proves nothing about the walk.
HITS=$(for f in $UNION; do grep -l '/Users/someone/x' "$TREE/$f" 2>/dev/null; done | wc -l | tr -d ' ')
assert_eq "AC16: an absolute path in the untracked record is reported as a hit" "$HITS" "1"
# THE NON-ZERO CONTROL IN THE OTHER DIRECTION. Without it, a walk that reported every file as
# a hit would satisfy the assertion above.
CLEAN_HITS=$(for f in $UNION; do grep -l '/Users/nobody/y' "$TREE/$f" 2>/dev/null; done | wc -l | tr -d ' ')
assert_eq "AC16 CONTROL: a string no record contains is reported zero times" "$CLEAN_HITS" "0"

suite "AC18: on a fresh clone the helper returns exactly the tracked set"

# The widening must be LOCAL-ONLY, so CI's population is unchanged. Asserted directly against
# the fresh-clone CONDITION (nothing on disk beyond the tracked set) rather than by running a
# clone, which would be slow and would still not pin the property.
rm -f "$TREE/.pipeline/99/status.json"
rmdir "$TREE/.pipeline/99" 2>/dev/null
TRACKED=$( (cd "$TREE" && git ls-files) | grep -E '(^|/)\.pipeline/[^/]+/status\.json$' | sort)
FRESH=$(corpus_files "$TREE" "$PIPELINE_PATTERN" | sort)
assert_eq "AC18: with nothing untracked on disk, the helper equals \`git ls-files\`" "$FRESH" "$TRACKED"
assert_eq "AC18 CONTROL: and that comparison was not two empty sets" \
  "$([[ -n "$TRACKED" ]] && echo ok || echo empty)" "ok"

# THE CELL THAT DISCRIMINATES A UNION FROM ITS TWO HALVES, and the reason it has to exist.
# Everything above measures the fresh-clone condition, where "tracked" and "on disk" are the
# SAME SET BY CONSTRUCTION -- so a genuine union, a `git ls-files`-only reader and an on-disk-
# only reader are indistinguishable there, and the named mutation "drop the tracked half"
# survived the whole suite. The population that separates them is the one where the two halves
# DISAGREE, in both directions at once, and it needs its own tree: manufacturing the
# disagreement in $TREE would change what every cell above and below measures.
new_tmpdir || exit 90
DTREE="$NEW_TMPDIR"
git -C "$DTREE" init -q
mkdir -p "$DTREE/.pipeline/tracked-gone" "$DTREE/.pipeline/on-disk-only" "$DTREE/.pipeline/both"
REC='{"current_phase":"3-impl","events":[]}'
printf '%s' "$REC" > "$DTREE/.pipeline/tracked-gone/status.json"
printf '%s' "$REC" > "$DTREE/.pipeline/both/status.json"
git -C "$DTREE" add -A -f >/dev/null 2>&1
git -C "$DTREE" -c user.email=t@t -c user.name=t commit -q -m init
# Direction 1: TRACKED, then removed from disk. Only the index knows it.
rm -f "$DTREE/.pipeline/tracked-gone/status.json"
# Direction 2: ON DISK, never added. Only the filesystem knows it.
printf '%s' "$REC" > "$DTREE/.pipeline/on-disk-only/status.json"
# Direction 3: in BOTH halves, which is what makes the union a union and not a concatenation.

DISC=$(corpus_files "$DTREE" "$PIPELINE_PATTERN" | sort)
assert_contains "AC18(union-a): a TRACKED record deleted from disk is still in the corpus -- an on-disk-only reader loses it" \
  "$DISC" ".pipeline/tracked-gone/status.json"
assert_contains "AC18(union-b): an UNTRACKED on-disk record is in the corpus -- a \`git ls-files\`-only reader loses it" \
  "$DISC" ".pipeline/on-disk-only/status.json"
assert_contains "AC18(union-c) CONTROL: the record in both halves is present" \
  "$DISC" ".pipeline/both/status.json"
# ...exactly once. `sort -u` is what makes that true today; a concatenation would still satisfy
# all three assertions above, and would then double-count every record in the live corpus.
assert_eq "AC18(union-c): and appears exactly ONCE, so the union is deduplicated not concatenated" \
  "$(printf '%s\n' "$DISC" | grep -cF '.pipeline/both/status.json' | tr -d ' ')" "1"
# THE NON-ZERO CONTROL FOR THIS TREE. Without it, a helper that printed every path it could
# think of would satisfy all four assertions above; with it, the corpus is pinned to exactly
# the three records that exist in either half.
assert_eq "AC18 CONTROL: and the corpus for this tree is those three records and nothing else" \
  "$(printf '%s\n' "$DISC" | grep -c 'status\.json' | tr -d ' ')" "3"
# Restore the untracked record for the pattern cases below.
mkdir -p "$TREE/.pipeline/99"
printf '%s' '{"current_phase":"3-impl","worktree_path":"/Users/someone/x","events":[{"phase":"0.5-map","verdict":"OK","at":"2026-08-02T00:00:00Z"}]}' \
  > "$TREE/.pipeline/99/status.json"

suite "AC27: the helper is parameterised by PATTERN, in both directions"

# ONE un-parameterised helper is wrong in BOTH directions, which is why the argument is the
# criterion and not an implementation detail:
#   * on the `.pipeline`-only pattern it silently drops the knowledge/issue-archive half of the
#     AC34 population -- a coverage NARROWING inside the requirement that fixes coverage
#     narrowing;
#   * on a blind union it feeds archive JSONs into the AC16b partition walk, where they parse
#     fine, carry no events, land in tooShort, and redden AC17's in-flight property for an
#     unrelated reason the day the first archive lands.
# knowledge/issue-archive/ is EMPTY in this repo, so a live-corpus assertion here would be a
# zero over an empty population. The temp tree is what makes this falsifiable today.
BOTH=$(corpus_files "$TREE" "$PIPELINE_PATTERN" "$ARCHIVE_PATTERN" | sort)
assert_contains "AC27: the AC34 pattern set reaches the .pipeline record" "$BOTH" ".pipeline/17/status.json"
assert_contains "AC27: and the knowledge/issue-archive record" "$BOTH" "knowledge/issue-archive/17.json"

ONLY_PIPELINE=$(corpus_files "$TREE" "$PIPELINE_PATTERN" | sort)
assert_contains "AC27: the AC16b/worktree_path pattern still reaches the .pipeline record" \
  "$ONLY_PIPELINE" ".pipeline/17/status.json"
assert_not_contains "AC27: and does NOT drag the archive JSON into the partition walk" \
  "$ONLY_PIPELINE" "knowledge/issue-archive/17.json"

suite "AC17: the in-flight partition property, over five CRAFTED cells"

# NOT over the live corpus. r1 leaned on .pipeline/exp-claims/status.json having 1 event; the
# committed copy has 1 and the working-tree copy has 2, because this very run appended one. The
# run under review mutates the evidence the review depends on, so every cell below is crafted.
mkdir -p "$TREE/.pipeline/c-a" "$TREE/.pipeline/c-b" "$TREE/.pipeline/c-c" "$TREE/.pipeline/c-d" "$TREE/.pipeline/c-e"
printf '%s' '{"current_phase":"3-impl","events":[{"phase":"3-impl","verdict":"OK","at":"2026-08-01T00:00:00Z"}]}' > "$TREE/.pipeline/c-a/status.json"
printf '%s' '{"events":[{"phase":"3-impl","verdict":"OK","at":"2026-08-01T00:00:00Z"}]}'                          > "$TREE/.pipeline/c-b/status.json"
printf '%s' '{"current_phase":"3-impl"}'                                                                          > "$TREE/.pipeline/c-c/status.json"
printf '%s' '{"current_phase":"3-impl","events":[ this is not json'                                               > "$TREE/.pipeline/c-d/status.json"
printf '%s' '{"current_phase":"5-archive","events":[{"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T00:00:00Z"},{"phase":"5-archive","verdict":"DONE","at":"2026-08-01T02:00:00Z"}]}' > "$TREE/.pipeline/c-e/status.json"

# `in_flight_short` communicates by EXIT STATUS ONLY and prints nothing; anything it does print
# is surfaced here verbatim so a stub or a debug line cannot masquerade as a verdict.
cell() {
  local out rc
  out=$(in_flight_short "$TREE/.pipeline/$1/status.json" 2>&1); rc=$?
  if [[ -n "$out" ]]; then printf '%s' "$out"
  elif [[ "$rc" -eq 0 ]]; then echo accepted
  else echo rejected; fi
}

assert_eq "AC17(a): 1 event + current_phase + events array => ACCEPTED as in-flight" "$(cell c-a)" "accepted"
assert_eq "AC17(b): 1 event but NO current_phase => rejected" "$(cell c-b)" "rejected"
# The cell r1 omitted. Without the Array.isArray conjunct a malformed record with a
# current_phase and no events array at all satisfies the predicate and is silently excused.
assert_eq "AC17(c): NO events array at all, with a current_phase => rejected" "$(cell c-c)" "rejected"
assert_eq "AC17(d): unreadable JSON => rejected" "$(cell c-d)" "rejected"
# THE CONTROL. If this reddens under any of the four AC17 mutations, the property has become
# "accept everything" and the other four cells prove nothing.
assert_eq "AC17(e) CONTROL: a >=2-event record is partitioned normally, not counted short" "$(cell c-e)" "rejected"

# THE LIVE FIGURE IS REPORTED, NEVER PINNED. Printing it keeps the number visible to a reader
# without making this suite's colour a function of the run under review's own progress.
LIVE_SHORT=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  in_flight_short "$REPO_ROOT/$f" >/dev/null 2>&1 && LIVE_SHORT=$((LIVE_SHORT + 1))
done < <(corpus_files "$REPO_ROOT" "$PIPELINE_PATTERN")
printf '  note  live corpus in-flight short records: %s (REPORTED, never pinned)\n' "$LIVE_SHORT"

suite "AC28: untimed is a PROPERTY over the widened population, not an absolute count"

# `untimed == 1` was an absolute count over a population D is about to widen, and it survived
# the widening only by luck: the newly-included .pipeline/30/status.json happens to have
# parseable timestamps. Re-expressed as a self-balancing property that NAMES the record which
# carries it, so a zero is still loud.
CARRIER=".pipeline/exp-script-test-coverage/status.json"
# Pinned on the assertion's own LABEL, which is the literal that exists today at :458 -- a
# shape regex over "untimed" and "1" would match the surrounding prose and pass vacuously.
assert_eq "AC28: the absolute \`untimed == 1\` pin is gone from the suite" \
  "$(grep -cF 'and there is exactly one such record in this corpus today' "$SUITE" | tr -d ' ')" "0"
assert_eq "AC28: the suite NAMES the record that carries the non-zero untimed count" \
  "$([[ "$(grep -cF "exp-script-test-coverage" "$SUITE" | tr -d ' ')" -ge 1 ]] && echo ok || echo no)" "ok"
# The present-tense fact that record is named FOR. Asserted live, so a stale name fails loudly
# rather than passing confidently about a world that no longer exists.
assert_eq "AC28 CONTROL: that record really does carry untimed events today" \
  "$(MOD="$TELEMETRY" R="$REPO_ROOT/$CARRIER" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const m = await import(process.env.MOD);
     console.log(m.telemetry(JSON.parse(readFileSync(process.env.R,"utf8"))).untimed_events > 0 ? "yes" : "no");
   ')" "yes"
# D4 keeps the accounting identity, which is already immune to the widening: it balances
# against ${#CORPUS_FILES[@]} rather than against an absolute number. Pinned on its label so a
# refactor that quietly drops it is caught -- it is the assertion that stops "checked and fine"
# and "never checked" from looking the same at the three `continue` branches.
assert_eq "AC28: the accounting identity survives the widening" \
  "$(grep -cF 'every corpus file is accounted for by one of the counters: none fell through' "$SUITE" | tr -d ' ')" "1"

finish
