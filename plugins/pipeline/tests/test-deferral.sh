#!/usr/bin/env bash
# scripts/deferral.mjs -- the tracker-agnostic deferral ledger (0.41.0).
#
# WHAT IT IS FOR. evidence.md rule 10 says deferring is an action: an item routed to a follow-up
# is not deferred until it is WRITTEN somewhere durable. The pipeline has always said that and
# always spelled the destination `gh issue create`, which assumes GitHub and a working `gh`. A
# project on GitLab, on a private tracker, or on nothing at all had no legal way to satisfy a
# rule the panel enforces, so the rule degraded into prose the moment it left this repo.
#
# WHAT THIS SUITE PINS, and the shape of every cell is the same: BOTH DIRECTIONS. A refusal that
# only ever gets tested on its refusing path can be "fixed" into accepting everything without a
# single red test, and an acceptance that is never watched refuse is indistinguishable from a
# function that returns true.
#
# THE REMOTE-TRACKER CELLS CONTROL THEIR OWN PATH, and that is load-bearing rather than tidy.
# Whether `gh` or `glab` happens to be installed on the machine running this suite is not a
# property of the code under test, and a cell that reads "the CLI is absent" on a CI runner and
# "the CLI is present" on the author's laptop is two different tests wearing one label -- the
# shrinking-population defect #47 filed. So those cells run node by ABSOLUTE PATH with PATH set
# to a scratch bin this suite owns, and put exactly the tool they mean into it: nothing (absent),
# or a stub that answers the way a real one would for the case under test. The stub proves the
# BRANCH SELECTION, never the tracker: what a real `gh issue view` returns for a real issue is a
# live integration and is not claimed here.
#
# Hermeticity: every case builds its own project root under a registered temp dir and runs the
# script with cwd AND CLAUDE_PROJECT_DIR pinned there, so pipeline.config.json and the ledger
# both resolve inside the temp tree and never touch this checkout's own.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

DEFERRAL="$SCRIPTS_DIR/deferral.mjs"

make_temp_project || exit 90

# new_project <name> <config-json> -> PROJ, with the config written
new_project() {
  PROJ="$TEMP_PROJECT/$1"
  mkdir -p "$PROJ"
  printf '%s' "$2" > "$PROJ/pipeline.config.json"
}

# run <args...> -> RC, OUT (stdout), ERR (stderr)
run() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" node "$DEFERRAL" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

# The scratch bin the remote-tracker cells run against. node is reached by absolute path so the
# child needs nothing else on PATH, which is what makes "the CLI is absent" a fact this suite
# constructs rather than a fact about the host.
NODE_BIN="$(command -v node)"
new_tmpdir || exit 90
SCRATCH_BIN="$NEW_TMPDIR"

# plant_cli <name> <exit-status> <output>  -- or remove it when <exit-status> is "none"
plant_cli() {
  local name="$1" status="$2" out="${3:-}"
  if [[ "$status" == "none" ]]; then rm -f "$SCRATCH_BIN/$name"; return 0; fi
  {
    printf '#!/bin/sh\n'
    printf 'if [ "$1" = "--version" ]; then echo "%s 0.0.0-stub"; exit 0; fi\n' "$name"
    printf 'printf %%s "%s"\n' "$out"
    printf 'exit %s\n' "$status"
  } > "$SCRATCH_BIN/$name"
  chmod +x "$SCRATCH_BIN/$name"
}

# run_isolated <args...> -- like run(), with PATH holding ONLY this suite's scratch bin.
run_isolated() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" PATH="$SCRATCH_BIN" "$NODE_BIN" "$DEFERRAL" "$@" ) \
    >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

DIR_CFG='{"deferralTracker":"directory","deferralDir":"knowledge/deferred"}'

# ---------------------------------------------------------------------------
suite "deferral: the instrument itself"
# ---------------------------------------------------------------------------
assert_eq "scripts/deferral.mjs is present" \
  "$([[ -f "$DEFERRAL" ]] && echo present || echo "ABSENT: $DEFERRAL")" "present"

new_project instrument "$DIR_CFG"
run
assert_eq "no command prints usage and exits non-zero" "$RC" "1"
assert_contains "the usage names all three commands" "$ERR" "record"
assert_contains "...verify" "$ERR" "verify"
assert_contains "...list" "$ERR" "list"
run --not-a-flag
assert_eq "an unknown flag is a usage error, not a silently-ignored one" "$RC" "1"

# ---------------------------------------------------------------------------
suite "deferral, directory mode: record writes a readable ledger entry"
# ---------------------------------------------------------------------------
new_project record-dir "$DIR_CFG"
printf 'The retry backoff on the notify path is still linear.\n' > "$PROJ/body.md"
run record --issue 847 --title "Notify retry backoff is linear" --body-file body.md \
  --reason "needs the queue owner's call on the redelivery budget" \
  --evidence "packages/notify/src/send.ts:88"
assert_eq "record exits 0" "$RC" "0"
REF="$OUT"
assert_eq "and prints a repo-relative path as the ref" \
  "$([[ "$REF" == knowledge/deferred/847-* ]] && echo relative || echo "GOT: $REF")" "relative"
assert_eq "which is a file that actually exists" \
  "$([[ -f "$PROJ/$REF" ]] && echo present || echo "NOT ON DISK: $REF")" "present"

LEDGER="$(cat "$PROJ/$REF")"
assert_contains "the entry carries the title in frontmatter" "$LEDGER" 'title: "Notify retry backoff is linear"'
assert_contains "and the source issue" "$LEDGER" 'source_issue: "847"'
assert_contains "and opens as status: open" "$LEDGER" "status: open"
assert_contains "and names the tracker it was written by" "$LEDGER" "tracker: directory"
assert_contains "the body survives" "$LEDGER" "The retry backoff on the notify path is still linear."
# The REASON is the half evidence.md rule 10 calls the most valuable, so it is asserted
# separately from the body rather than assumed to have travelled with it.
assert_contains "the reason is recorded under its own heading" "$LEDGER" "Why it was deferred"
assert_contains "...with the reason itself" "$LEDGER" "needs the queue owner's call"
assert_contains "the evidence is recorded too" "$LEDGER" "packages/notify/src/send.ts:88"

# A title of pure punctuation still yields a filename. Not an exotic input: a note lifted from a
# reviewer's shard routinely opens with a symbol.
run record --issue 847 --title "?!" --body-file body.md
assert_eq "a title with no alphanumerics still records" "$RC" "0"
assert_eq "...under a non-empty slug" \
  "$([[ "$OUT" == knowledge/deferred/847-*.md ]] && echo named || echo "GOT: $OUT")" "named"

run record --issue 847 --title "no body given"
assert_eq "record with no body is refused" "$RC" "1"
assert_contains "and says which argument is missing" "$ERR" "body-file"
run record --title "no issue given" --body-file body.md
assert_eq "record with no issue is refused" "$RC" "1"

# The issue id reaches record from argv and is interpolated into a FILENAME. slugify() sanitizes
# the title; nothing sanitized this, so a path-shaped id would have written the ledger entry
# outside the ledger -- which is the defect this script exists to prevent, wearing a path.
run record --issue "../../escape" --title "Escaping id" --body-file body.md
assert_eq "a path-shaped --issue is refused" "$RC" "1"
assert_contains "and says the id must be a single path segment" "$ERR" "single path segment"
assert_eq "and nothing was written outside the ledger" \
  "$([[ -e "$TEMP_PROJECT/escape-escaping-id.md" ]] && echo "ESCAPED" || echo contained)" "contained"

# ---------------------------------------------------------------------------
suite "deferral, directory mode: list"
# ---------------------------------------------------------------------------
new_project list-dir "$DIR_CFG"
run list
assert_eq "an empty ledger lists cleanly, exit 0" "$RC" "0"
assert_contains "and says so rather than printing nothing at all" "$OUT" "no deferrals recorded"

printf 'x\n' > "$PROJ/body.md"
run record --issue 12 --title "First deferral" --body-file body.md
run record --issue 13 --title "Second deferral" --body-file body.md
run list
assert_eq "list exits 0 with entries" "$RC" "0"
assert_contains "and names the first entry's title" "$OUT" "First deferral"
assert_contains "and the second's" "$OUT" "Second deferral"
assert_contains "and each entry's status" "$OUT" "[open]"
assert_eq "one line per entry" "$(printf '%s\n' "$OUT" | grep -c 'knowledge/deferred/' | tr -d ' ')" "2"

# ---------------------------------------------------------------------------
suite "deferral, directory mode: verify ACCEPTS what record wrote"
# ---------------------------------------------------------------------------
# The acceptance half, and it comes first: every exit-2 cell below is only meaningful once this
# one has been watched pass. A verify that refused everything would satisfy all of them.
new_project verify-accept "$DIR_CFG"
printf 'x\n' > "$PROJ/body.md"
run record --issue 99 --title "A real deferral" --body-file body.md
GOOD_REF="$OUT"
run verify "$GOOD_REF"
assert_eq "the ref record printed verifies, exit 0" "$RC" "0"
assert_contains "and says what it resolved" "$OUT" "OK:"
run verify "$(basename "$GOOD_REF")"
assert_eq "the bare filename verifies too (both spellings a writer types)" "$RC" "0"
run verify "./$GOOD_REF"
assert_eq "a leading ./ verifies" "$RC" "0"

# ---------------------------------------------------------------------------
suite "deferral, directory mode: verify REFUSES, with exit 2, on each shape"
# ---------------------------------------------------------------------------
# Exit 2 is the "this cannot be a deferral in this configuration" code the gate reads. It is
# asserted per shape rather than once, because these are four different rules and a single
# always-refuse implementation would satisfy any one of them alone.
run verify ""
assert_eq "an empty ref exits 2" "$RC" "2"
assert_contains "and says no ref was recorded" "$ERR" "no tracker_ref recorded"

run verify "we agreed to handle this later"
assert_eq "a bare sentence exits 2" "$RC" "2"

run verify "knowledge/deferred/never-written.md"
assert_eq "a file under the dir that does not exist exits 2" "$RC" "2"
assert_contains "and says the file is not there" "$ERR" "names no file"

run verify "../../etc/passwd"
assert_eq "a path outside the ledger dir exits 2" "$RC" "2"
assert_contains "and says it is outside deferralDir" "$ERR" "not inside the configured deferralDir"

# A path that EXISTS but sits outside the ledger is the discriminator between a containment
# check and a mere existence check. Without this cell, `existsSync` alone would pass every case
# above.
printf 'x\n' > "$PROJ/outside.md"
run verify "outside.md"
assert_eq "an existing file OUTSIDE the ledger dir is still refused" "$RC" "2"

# In directory mode an issue reference is not a ledger entry, however well-formed. Refusing it
# is what stops "#412" standing in for a deferral in a project that has no tracker to hold it.
run verify "#412"
assert_eq "a #n issue ref is refused in directory mode" "$RC" "2"
assert_contains "and says what the ref should have been" "$ERR" "must be a file under"
run verify "https://github.com/acme/app/issues/412"
assert_eq "an issue URL is refused in directory mode too" "$RC" "2"

# ---------------------------------------------------------------------------
suite "deferral, directory mode: deferralDir is honoured, and cannot escape the repo"
# ---------------------------------------------------------------------------
new_project custom-dir '{"deferralTracker":"directory","deferralDir":"docs/deferred"}'
printf 'x\n' > "$PROJ/body.md"
run record --issue 5 --title "Relocated" --body-file body.md
assert_eq "a configured deferralDir is where the entry lands" \
  "$([[ "$OUT" == docs/deferred/5-relocated.md ]] && echo honoured || echo "GOT: $OUT")" "honoured"
run verify "docs/deferred/5-relocated.md"
assert_eq "...and verify reads the same directory" "$RC" "0"
run verify "knowledge/deferred/5-relocated.md"
assert_eq "...while the DEFAULT directory is no longer accepted, so the key is really read" "$RC" "2"

# This key names a directory the pipeline WRITES COMMITTED FILES into, so a config edit must not
# be able to place them outside the repository. The refusal is a fall back to the default, not a
# throw: a bad value must not wedge a run.
new_project escaping-dir '{"deferralTracker":"directory","deferralDir":"../../../tmp/escape"}'
printf 'x\n' > "$PROJ/body.md"
run record --issue 6 --title "Escapes" --body-file body.md
assert_eq "an escaping deferralDir does not wedge the run" "$RC" "0"
assert_eq "...and the entry lands under the DEFAULT dir instead of outside the repo" \
  "$([[ "$OUT" == knowledge/deferred/6-escapes.md ]] && echo contained || echo "GOT: $OUT")" "contained"

new_project absolute-dir '{"deferralTracker":"directory","deferralDir":"/tmp/absolute-escape"}'
printf 'x\n' > "$PROJ/body.md"
run record --issue 7 --title "Absolute" --body-file body.md
assert_eq "an absolute deferralDir also falls back to the default" \
  "$([[ "$OUT" == knowledge/deferred/7-absolute.md ]] && echo contained || echo "GOT: $OUT")" "contained"

# ---------------------------------------------------------------------------
suite "deferral, remote trackers: the FORMAT rule, in both directions"
# ---------------------------------------------------------------------------
# Format is decided before existence and without any CLI, so these cells run with an EMPTY
# scratch bin. The point of running them isolated anyway is that the branch under test is then
# the same branch on every host.
new_project remote-github '{"deferralTracker":"github"}'
plant_cli gh none
plant_cli glab none
run_isolated verify "#412"
assert_eq "a #n ref is accepted on github" "$RC" "0"
run_isolated verify "https://github.com/acme/app/issues/412"
assert_eq "a github issue URL is accepted" "$RC" "0"
run_isolated verify "https://gitlab.com/group/proj/-/issues/9"
assert_eq "a gitlab-shaped URL is accepted on format alone" "$RC" "0"
run_isolated verify "routed to the follow-up issue"
assert_eq "a bare sentence is refused, exit 2" "$RC" "2"
assert_contains "and names the shapes it wanted" "$ERR" '"#<n>" or an issue URL'
run_isolated verify "https://github.com/acme/app/pull/412"
assert_eq "a PULL request URL is refused: a PR is not where a deferral is written" "$RC" "2"
run_isolated verify ""
assert_eq "an empty ref is refused on a remote tracker too" "$RC" "2"

run_isolated list
assert_eq "list on a remote tracker exits 0" "$RC" "0"
assert_contains "and says the ledger is remote rather than pretending to read one" "$OUT" "REMOTE"

# ---------------------------------------------------------------------------
suite "deferral, remote trackers: THE FAIL DIRECTION when existence cannot be established"
# ---------------------------------------------------------------------------
# This is the property that matters most, because verify is a GATE input. Three states, and only
# ONE of them may refuse: the ref really is not there. "I could not ask" is a different state
# from "I asked and it is not there", and conflating them halts a panel on correctly-recorded
# deferrals wherever the CLI is missing or unauthenticated.

# (1) CLI ABSENT -> accept, and SAY the check did not happen. An acceptance that does not
# announce its own blindness is worse than one that halts, because nothing downstream can tell.
plant_cli gh none
run_isolated verify "#412"
assert_eq "CLI absent: a well-formed ref is ACCEPTED" "$RC" "0"
assert_contains "...and the acceptance announces itself" "$OUT" "WARNING"
assert_contains "...naming what it could not do" "$OUT" "existence was NOT checked"
assert_contains "...and naming the tool it wanted" "$OUT" "gh"
# Without this the "accept when you cannot ask" rule would accept anything at all.
run_isolated verify "not a ref at all"
assert_eq "CONTROL: an absent CLI still refuses a MALFORMED ref" "$RC" "2"

# (2) CLI PRESENT and the issue RESOLVES -> accept, silently. The stub stands in for the tracker
# and proves only which branch ran.
plant_cli gh 0 "Issue #412: something"
run_isolated verify "#412"
assert_eq "CLI present, issue resolves: accepted" "$RC" "0"
assert_not_contains "...with NO blindness warning, because the check actually ran" "$OUT" "WARNING"

# (3) CLI PRESENT and the issue is NOT FOUND -> refuse. This is the one cell that catches the
# defect the whole ledger exists for: a tracker_ref that names an issue nobody ever created.
plant_cli gh 1 "GraphQL: Could not resolve to an Issue with the number 412."
run_isolated verify "#412"
assert_eq "CLI present, issue does NOT exist: REFUSED, exit 2" "$RC" "2"
assert_contains "and the refusal says the tracker denied it" "$ERR" "does not exist"

# (4) CLI PRESENT and it cannot answer (auth, network, rate limit) -> accept with the warning,
# NOT a refusal. Same reasoning as (1) and it is a separate branch in the code, so it is a
# separate cell here: an expired token must not halt every panel in the project.
plant_cli gh 1 "error connecting to api.github.com: dial tcp: lookup failed"
run_isolated verify "#412"
assert_eq "CLI present but unable to answer: accepted, not refused" "$RC" "0"
assert_contains "...and it says the existence check did not happen" "$OUT" "existence was NOT checked"
assert_contains "...quoting what the tool said, so the operator can fix the real problem" \
  "$OUT" "dial tcp"

plant_cli gh none

# ---------------------------------------------------------------------------
suite "deferral: a missing CLI REFUSES the write rather than inventing a destination"
# ---------------------------------------------------------------------------
# The one place this script is deliberately louder than the rest of the plugin, which fails soft
# everywhere. A silent fallback to a file would leave the author believing the item is in their
# tracker when it is in an untracked path: a deferral you believe is filed and is not is worse
# than one that refused in the turn that caused it.
new_project record-nocli '{"deferralTracker":"gitlab"}'
printf 'x\n' > "$PROJ/body.md"
plant_cli glab none
run_isolated record --issue 3 --title "Would be lost" --body-file body.md
assert_eq "record refuses when the configured CLI is absent" "$RC" "1"
assert_contains "the refusal names the CLI" "$ERR" "glab"
assert_contains "and names the remedy that needs no CLI" "$ERR" '"deferralTracker": "directory"'
assert_eq "and NOTHING was written to the default ledger dir" \
  "$([[ -d "$PROJ/knowledge/deferred" ]] && echo "WROTE ANYWAY" || echo nothing)" "nothing"

# The other direction: with the CLI there and succeeding, record returns the URL the tool
# printed. Without this cell the refusal above could have been bought by never writing at all.
plant_cli glab 0 "https://gitlab.com/acme/app/-/issues/3"
run_isolated record --issue 3 --title "Filed for real" --body-file body.md
assert_eq "CONTROL: with the CLI present and succeeding, record exits 0" "$RC" "0"
assert_eq "...and prints the URL the tracker returned as the ref" \
  "$OUT" "https://gitlab.com/acme/app/-/issues/3"

# A CLI that succeeds but prints no URL leaves no ref to record, which must be a failure and not
# an empty string written into an artifact the gate will later read.
plant_cli glab 0 "Created."
run_isolated record --issue 3 --title "No URL back" --body-file body.md
assert_eq "a create that prints no URL is a failure, not an empty ref" "$RC" "1"
assert_contains "and says why" "$ERR" "no issue URL"

# A CLI that FAILS is reported with what it said, rather than swallowed.
plant_cli glab 1 "error: authentication required"
run_isolated record --issue 3 --title "Auth failure" --body-file body.md
assert_eq "a failing create is a failure" "$RC" "1"
assert_contains "and carries the tool's own words" "$ERR" "authentication required"
plant_cli glab none

# ---------------------------------------------------------------------------
suite "deferral: an unreadable or absent config takes the documented default"
# ---------------------------------------------------------------------------
# Same posture as every other knob in this plugin: a config typo must never wedge a run, and
# config-doctor.mjs is what tells the owner their value is unread.
new_project no-config '{}'
rm -f "$PROJ/pipeline.config.json"
run verify --no-existence-check "#5"
assert_eq "with no config at all the default tracker (github) applies" "$RC" "0"

new_project bad-json '{ not json'
run verify --no-existence-check "#5"
assert_eq "an unparseable config falls back to the default rather than throwing" "$RC" "0"

new_project bad-tracker '{"deferralTracker":"jira"}'
run verify --no-existence-check "#5"
assert_eq "an unknown tracker value falls back to the default" "$RC" "0"
run verify --no-existence-check "knowledge/deferred/x.md"
assert_eq "...which is github, not directory: the fallback is the DEFAULT, not the last mode" "$RC" "2"

finish
