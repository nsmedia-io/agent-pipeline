#!/usr/bin/env bash
# check-merged.mjs: the Phase 5 merge check (#164 row 30).
#
# THE BUG. The prose ran `git log origin/main --oneline | grep -q "#<issue>"`. `#12` matched inside
# `#123`, so issue 12 read as merged once 123 landed, and a squash merge whose subject carried
# only the PR number read as not merged. The first cells below run that old command on the same
# fixture, so the regression cells are shown to separate the two behaviours rather than assumed to.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

CM="$SCRIPTS_DIR/check-merged.mjs"
PHASE5="$PLUGIN_ROOT/orchestrator/phase-5-archive.md"

make_temp_project 12 || exit 90
ORIGIN="$TEMP_PROJECT/origin.git"
WORK="$TEMP_PROJECT/work"
gitq() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

gitq init -q --bare "$ORIGIN"
gitq init -q "$WORK"
gitq -C "$WORK" checkout -q -b main
gitq -C "$WORK" commit -q --allow-empty -m "init"
gitq -C "$WORK" commit -q --allow-empty -m "feat: the other change (#123)"
gitq -C "$WORK" remote add origin "$ORIGIN"
gitq -C "$WORK" push -q origin main
# A merged-by-merge branch whose commits never name an issue.
gitq -C "$WORK" checkout -q -b merged-branch
gitq -C "$WORK" commit -q --allow-empty -m "work with no reference"
gitq -C "$WORK" checkout -q main
gitq -C "$WORK" merge -q --no-ff -m "Merge merged-branch" merged-branch
# A squash-merged branch: its head never becomes an ancestor, and the subject carries no issue ref.
gitq -C "$WORK" checkout -q -b squashed-branch
gitq -C "$WORK" commit -q --allow-empty -m "squash me"
gitq -C "$WORK" checkout -q main
gitq -C "$WORK" commit -q --allow-empty -m "Squashed change (#77)"
gitq -C "$WORK" push -q origin main merged-branch squashed-branch

# cm <args...> -> RC, OUT, ERR (run from the clone)
cm() {
  ( cd "$WORK" && node "$CM" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}
old_check() {
  ( cd "$WORK" && git log origin/main --oneline | grep -q "#$1" && echo "merged" || echo "not merged" )
}

suite "check-merged: the old grep's two defects, measured on this fixture"

assert_eq "CONTROL (old behaviour): the old grep reads issue 12 as merged because #123 landed" "$(old_check 12)" "merged"
cm --issue 12 --no-fetch
assert_eq "REGRESSION: #12 inside #123 is not a merge; with no PR and no branch the answer is cannot tell (3)" "$RC" "3"
assert_contains "and it says so" "$OUT" "CANNOT TELL"
assert_contains "and names why nothing matched" "$ERR" "no commit subject on origin/main references #12"

assert_eq "CONTROL (old behaviour): the old grep reads the squash-merged branch as not merged" "$(old_check 45)" "not merged"

suite "check-merged: the git evidence"

cm --issue 123 --no-fetch
assert_eq "a whole #123 reference in a subject is merged (0)" "$RC" "0"
assert_contains "and names the evidence" "$OUT" "references #123"

cm --issue 12 --branch merged-branch --no-fetch
assert_eq "a branch whose head is an ancestor of origin/main is merged (0), with no issue ref anywhere" "$RC" "0"
assert_contains "and names the branch" "$OUT" "merged-branch"

cm --issue 45 --branch squashed-branch --no-fetch
assert_eq "a squashed branch with no ref and no PR is cannot tell (3), never not merged" "$RC" "3"
assert_contains "and says a squash reads this way" "$ERR" "squash merge also reads this way"

mkdir -p "$WORK/.pipeline/12"
printf '{"issue_number":12,"branch":"merged-branch"}' > "$WORK/.pipeline/12/status.json"
cm --issue 12 --no-fetch
assert_eq "the branch comes from .pipeline/<issue>/status.json when --branch is absent" "$RC" "0"

cm --issue 12
assert_eq "with fetch on (the default) against a real remote, the answer is the same" "$RC" "0"

cm
assert_eq "no --issue is usage (1)" "$RC" "1"
cm --issue 12 --bogus
assert_eq "an unknown flag is usage (1)" "$RC" "1"

suite "check-merged: the PR evidence (gh injected)"

# pr <gh-json|FAIL> <issue> [branch] -> "code|how"
pr() {
  MOD="$CM" GH="$1" ISSUE="$2" BR="${3:-}" WORKDIR="$WORK" node --input-type=module -e '
    const m = await import(process.env.MOD);
    const exec = (cmd, args) => {
      if (cmd === "gh") {
        if (process.env.GH === "FAIL") return { ran: true, status: 1, stdout: "", stderr: "HTTP 401: auth" };
        return { ran: true, status: 0, stdout: process.env.GH, stderr: "" };
      }
      return m.run(cmd, args, process.env.WORKDIR);
    };
    const r = m.checkMerged({ issue: process.env.ISSUE, prUrl: "https://github.com/acme/app/pull/9", branch: process.env.BR, fetch: false, exec });
    console.log(`${r.code}|${r.how}|${r.notes.join(";")}`);
  '
}

R="$(pr '{"mergedAt":"2026-09-01T00:00:00Z","state":"MERGED"}' 45 squashed-branch)"
assert_eq "REGRESSION: a squash merge without the ref is merged (0) when the PR says mergedAt" "${R%%|*}" "0"
R="$(pr '{"mergedAt":null,"state":"OPEN"}' 123)"
assert_eq "an OPEN PR is not merged (2), even when a subject elsewhere matches" "${R%%|*}" "2"
R="$(pr '{"mergedAt":null,"state":"CLOSED"}' 45)"
assert_eq "a CLOSED unmerged PR is not merged (2)" "${R%%|*}" "2"
R="$(pr FAIL 123)"
assert_eq "gh unable to answer falls through to git evidence (0 via #123)" "${R%%|*}" "0"
assert_contains "and the gh failure is noted, not swallowed" "$R" "gh could not read"
R="$(pr FAIL 45 squashed-branch)"
assert_eq "gh unable to answer and no git evidence is cannot tell (3)" "${R%%|*}" "3"
R="$(pr 'not json' 45)"
assert_eq "unparseable gh output is not an answer (3)" "${R%%|*}" "3"

suite "check-merged: the prose calls the script, and the grep stays removed"

P5="$(cat "$PHASE5")"
assert_contains "phase-5-archive.md calls check-merged.mjs" "$P5" 'scripts/check-merged.mjs" --issue <issue>'
assert_not_contains "the substring grep is gone" "$P5" 'grep -q "#<issue>"'
assert_not_contains "the git log merge check is gone" "$P5" "git log origin/main --oneline"

finish
