#!/usr/bin/env bash
# merge-ready.mjs: the merge preconditions (#164 row 15).
#
# The CI-green precondition and the deferral merge guard were prose: "verify the PR head SHA
# matches the reviewed HEAD and CI is green" and "confirm each deferral is written in the
# ledger". These cells drive the decision with gh injected (the PR is remote state) and with a
# real git worktree HEAD and a real directory-mode deferral ledger.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

MR="$SCRIPTS_DIR/merge-ready.mjs"
VERDICT="$PLUGIN_ROOT/orchestrator/phase-4-verdict.md"

make_temp_project 88 || exit 90
PROJ="$TEMP_PROJECT"
git -c init.defaultBranch=main init -q "$PROJ/wt"
gc() { git -C "$PROJ/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"; git -C "$PROJ/wt" rev-parse HEAD; }
OLD="$(gc "first round")"
SHA="$(gc reviewed)"
NOTES="$(gc "chore: apply Phase 4 panel notes for #88")"
LATER="$(gc "unreviewed change")"
git -C "$PROJ/wt" -c init.defaultBranch=main branch -q side "$OLD"
git -C "$PROJ/wt" checkout -q side
SIDE="$(gc "a divergent line")"
git -C "$PROJ/wt" checkout -q -
PEER="$PROJ/peer-review.json"
# A delta round: qa re-reviewed the fix commit, secops's approval stands on the first round.
peer() { printf '{"qa":{"verdict":"APPROVE","reviewed_sha":"%s"},"secops":{"verdict":"APPROVE","reviewed_commit":"%s"}%s}' "$1" "$2" "${3:+,$3}" > "$PEER"; }
peer "$SHA" "${OLD:0:7}"
printf '{"deferralTracker":"directory","deferralDir":"ledger"}' > "$PROJ/pipeline.config.json"
mkdir -p "$PROJ/ledger"
printf '# deferred\n' > "$PROJ/ledger/88-one.md"
REPORT="$PROJ/impl-report.json"
report() { printf '{"issue_number":88,"pr_url":"https://github.com/acme/app/pull/5"%s}' "${1:+,$1}" > "$REPORT"; }

# mr <gh-json|FAIL> <args...> -> RC, OUT, ERR. gh is injected; git and the ledger are real.
mr() {
  local gh="$1"; shift
  MOD="$MR" GH="$gh" node --input-type=module -e '
    const m = await import(process.env.MOD);
    const exec = (cmd, args, cwd) => {
      if (cmd === "gh") {
        if (process.env.GH === "FAIL") return { ran: true, status: 1, stdout: "", stderr: "gh: HTTP 401" };
        return { ran: true, status: 0, stdout: process.env.GH, stderr: "" };
      }
      return m.run(cmd, args, cwd);
    };
    let o = "", e = "";
    const code = m.main(process.argv.slice(1), { exec, out: (s) => (o += s), err: (s) => (e += s) });
    process.stdout.write(o); process.stderr.write(e); process.exit(code);
  ' -- "$@" >"$PROJ/o" 2>"$PROJ/e"
  RC=$?
  OUT=$(cat "$PROJ/o")
  ERR=$(cat "$PROJ/e")
}
ARGS=(--issue 88 --worktree "$PROJ/wt" --impl-report "$REPORT" --peer-review "$PEER" --root "$PROJ")
GREEN="[{\"__typename\":\"CheckRun\",\"name\":\"tests\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"},{\"__typename\":\"StatusContext\",\"context\":\"lint\",\"state\":\"SUCCESS\"},{\"__typename\":\"CheckRun\",\"name\":\"optional\",\"status\":\"COMPLETED\",\"conclusion\":\"SKIPPED\"}]"
pr() { printf '{"headRefOid":"%s","statusCheckRollup":%s}' "$1" "$2"; }

# THE FIXTURE, READ ONCE HERE SO EACH CELL BELOW CAN STAY SHORT. The worktree holds five commits:
# the first panel round, the commit the panel reviewed, the orchestrator notes commit on top of it,
# a later commit nobody reviewed, and a side branch forked from the first round. The panel record
# is a delta round: QA recorded the reviewed commit and SecOps still stands on the first round, so
# the script has to pick the newest recorded commit rather than the first one it reads. The ledger
# is a real directory-mode ledger with one entry, and only the PR state is injected, because that
# is the one input that lives on a remote. Every cell is one call and one or two assertions.
suite "merge-ready: ready"

report '"deferred":[{"what":"w","reason":"r","tracker_ref":"ledger/88-one.md"}]'
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "reviewed head, green CI, a verifying deferral ref: exit 0" "$RC" "0"
assert_contains "and it says READY" "$OUT" "READY: #88"

# THE HEAD RULE. Ready means the PR head is the commit the panel reviewed, or that commit plus only
# the orchestrator notes commits. A head past it, behind it, on another line of history, or with
# no recorded commit at all is not ready, and the failure direction is always toward not ready:
# a record the script cannot read never falls back to the worktree HEAD, which is the shape the
# review found, since the worktree HEAD moves with every commit made after the panel ran.
suite "merge-ready: the PR head against the commit the panel recorded"

mr "$(pr 0123456789abcdef0123456789abcdef01234567 "$GREEN")" "${ARGS[@]}"
assert_eq "a PR head that is not the reviewed commit: exit 2" "$RC" "2"
assert_contains "and names both commits" "$OUT" "PR head 0123456789ab is not the reviewed commit ${SHA:0:12}"
mr "$(pr "$LATER" "$GREEN")" "${ARGS[@]}"
assert_eq "REGRESSION: a PR head equal to the worktree HEAD but past the reviewed commit: exit 2" "$RC" "2"
mr "$(pr "$NOTES" "$GREEN")" "${ARGS[@]}"
assert_eq "a PR head that adds only the orchestrator's panel-notes commit: exit 0" "$RC" "0"
mr "$(pr "$OLD" "$GREEN")" "${ARGS[@]}"
assert_eq "the reviewed commit is the newest recorded one, not the first round's: exit 2 on the older head" "$RC" "2"
peer "$SHA" "$SIDE"
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "recorded commits that are not one line of history: exit 2" "$RC" "2"
assert_contains "and says so" "$OUT" "not one line of history"
printf '{"qa":{"verdict":"APPROVE"}}' > "$PEER"
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "no reviewed commit recorded: exit 2, never the worktree HEAD instead" "$RC" "2"
assert_contains "and says nothing was recorded" "$OUT" "recorded no reviewed commit"
peer "deadbeefdeadbeef" "$SHA"
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "a recorded commit that does not resolve: exit 2" "$RC" "2"
peer "$SHA" "${OLD:0:7}"
report ''
printf '{"issue_number":88}' > "$REPORT"
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "no PR url anywhere: exit 2" "$RC" "2"
assert_contains "and says so" "$OUT" "no PR url"
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}" --pr-url https://github.com/acme/app/pull/5
assert_eq "--pr-url supplies it: exit 0" "$RC" "0"
report ''
mr FAIL "${ARGS[@]}"
assert_eq "gh unable to read the PR: exit 2, never ready by default" "$RC" "2"
assert_contains "and carries gh's words" "$OUT" "HTTP 401"

# THE CI RULE. Every check on the PR head must have finished green. Skipped counts as green, a
# running check does not, and no checks at all is refused by default because a CI that has not
# registered yet looks exactly like no CI. Only the config key lifts that one refusal, only as a
# real boolean, and never for a failing check.
suite "merge-ready: CI on the head"

mr "$(pr "$SHA" '[{"__typename":"CheckRun","name":"tests","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","context":"lint","state":"SUCCESS"}]')" "${ARGS[@]}"
assert_eq "a failing check: exit 2" "$RC" "2"
assert_contains "and names it" "$OUT" "CI is failing on the PR head: tests"
mr "$(pr "$SHA" '[{"__typename":"CheckRun","name":"tests","status":"IN_PROGRESS","conclusion":""}]')" "${ARGS[@]}"
assert_eq "a check still running: exit 2" "$RC" "2"
assert_contains "and says it has not finished" "$OUT" "CI has not finished on the PR head: tests"
mr "$(pr "$SHA" '[{"__typename":"StatusContext","context":"deploy","state":"ERROR"}]')" "${ARGS[@]}"
assert_eq "a StatusContext in ERROR: exit 2" "$RC" "2"
mr "$(pr "$SHA" '[]')" "${ARGS[@]}"
assert_eq "no checks at all: exit 2 (CI may not have registered)" "$RC" "2"
assert_contains "and names the config key" "$OUT" "ciRequiredForMerge"
mr "$(pr "$SHA" '[]')" "${ARGS[@]}" --no-ci
assert_eq "there is no per-call --no-ci override (usage, 1)" "$RC" "1"
printf '{"deferralTracker":"directory","deferralDir":"ledger","ciRequiredForMerge":false}' > "$PROJ/pipeline.config.json"
mr "$(pr "$SHA" '[]')" "${ARGS[@]}"
assert_eq "no checks with ciRequiredForMerge: false: exit 0" "$RC" "0"
mr "$(pr "$SHA" '[{"__typename":"CheckRun","name":"tests","status":"COMPLETED","conclusion":"FAILURE"}]')" "${ARGS[@]}"
assert_eq "CONTROL: ciRequiredForMerge: false does not excuse a FAILING check" "$RC" "2"
printf '{"deferralTracker":"directory","deferralDir":"ledger","ciRequiredForMerge":"false"}' > "$PROJ/pipeline.config.json"
mr "$(pr "$SHA" '[]')" "${ARGS[@]}"
assert_eq "only the boolean false lifts it; the string \"false\" does not: exit 2" "$RC" "2"
printf '{"deferralTracker":"directory","deferralDir":"ledger"}' > "$PROJ/pipeline.config.json"

# THE LEDGER RULE. Every deferral the run recorded must resolve in the ledger: the report entries,
# the older observations shape, each ref passed on the command line, and each ref a panel shard
# carries. The last cell of this block asks for three failures at once and requires all three to
# be printed, so an owner fixes them in one pass instead of one per run.
suite "merge-ready: every deferral ref verifies"

report '"deferred":[{"what":"w","reason":"r","tracker_ref":"ledger/88-missing.md"}]'
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "a deferred ref naming no ledger file: exit 2" "$RC" "2"
assert_contains "and names the entry" "$OUT" "deferred[0] is not in the deferral ledger"
report '"deferred":[{"what":"w","reason":"r"}]'
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "a deferred entry with no ref: exit 2" "$RC" "2"
report '"scope_drift":{"observations_reported_not_fixed":[{"observation":"o","tracker_ref":"routed to #9"}]}'
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "the legacy observations shape is read too: exit 2" "$RC" "2"
assert_contains "and named" "$OUT" "scope_drift.observations_reported_not_fixed[0]"
report ''
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}" --ref ledger/88-one.md --ref ledger/nope.md
assert_eq "a --ref that does not verify: exit 2" "$RC" "2"
assert_contains "and it is the second one" "$OUT" "--ref[1] is not in the deferral ledger"
peer "$SHA" "$SHA" '"dba":{"verdict":"APPROVE_WITH_NOTES","concerns":[{"id":"dba-1","tracker_ref":"ledger/88-gone.md"}]}'
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "a deferral ref recorded in a panel shard that does not verify: exit 2" "$RC" "2"
assert_contains "and names where in peer-review.json" "$OUT" "peer-review dba.concerns[0].tracker_ref"
peer "$SHA" "$SHA" '"dba":{"verdict":"APPROVE_WITH_NOTES","concerns":[{"id":"dba-1","tracker_ref":"ledger/88-one.md"}]}'
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "CONTROL: the same shard ref naming a real ledger file: exit 0" "$RC" "0"
peer "$SHA" "${OLD:0:7}"
mr "$(pr 0123456789abcdef0123456789abcdef01234567 '[]')" "${ARGS[@]}" --ref ledger/nope.md
assert_contains "every failure is reported, not just the first (head)" "$OUT" "is not the reviewed commit"
assert_contains "every failure is reported, not just the first (CI)" "$OUT" "no CI checks"
assert_contains "every failure is reported, not just the first (ledger)" "$OUT" "--ref[0]"

# USAGE. A missing input or a report for another issue is exit 1, which the prose treats as a halt
# and never as not ready, so a typo cannot be read as a merge decision either way.
suite "merge-ready: usage"

mr "$(pr "$SHA" "$GREEN")" --issue 88 --worktree "$PROJ/wt" --peer-review "$PEER"
assert_eq "no --impl-report: exit 1" "$RC" "1"
mr "$(pr "$SHA" "$GREEN")" --issue 88 --worktree "$PROJ/wt" --impl-report "$REPORT"
assert_eq "no --peer-review: exit 1" "$RC" "1"
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}" --what
assert_eq "an unknown flag: exit 1" "$RC" "1"
mr "$(pr "$SHA" "$GREEN")" --issue 99 --worktree "$PROJ/wt" --impl-report "$REPORT" --peer-review "$PEER" --root "$PROJ"
assert_eq "an impl-report for a different issue: exit 1" "$RC" "1"
( cd "$PROJ" && node "$MR" --issue 88 ) >/dev/null 2>&1
assert_eq "the CLI entrypoint runs and refuses a partial invocation (1)" "$?" "1"

# THE PROSE. The orchestrator only runs what the verdict file tells it to run, so the call, its exit
# handling and the deferral rule are pinned there, and the hand-run instructions it replaced are
# pinned absent so the two cannot drift back into disagreeing.
suite "the prose calls the script, and the removed prose stays removed"

V="$(cat "$VERDICT")"
assert_contains "phase-4-verdict.md runs merge-ready.mjs before presenting the PR" "$V" 'scripts/merge-ready.mjs" --issue <issue> --worktree "$WORKTREE_PATH" --impl-report "$ARTIFACT_DIR/impl-report.json" --peer-review "$ARTIFACT_DIR/peer-review.json"'
assert_contains "and says only exit 0 is ready" "$V" "**Only exit 0 is ready.**"
assert_contains "and halts on any other exit" "$V" "Any other exit: halt and show the owner the output."
assert_contains "and names the config key rather than a per-call override" "$V" "there is no per-call override"
assert_not_contains "and never tells the orchestrator to pass --no-ci" "$V" "--no-ci"
assert_contains "the collect-and-confirm deferral rule survives" "$V" "collect every item any panel shard or remediation round marked deferred"
assert_contains "and passes recorded deferral refs to it" "$V" "Pass the ref it prints to \`merge-ready.mjs\` as \`--ref\`"
assert_not_contains "the hand-run CI-green check is gone" "$V" "the PR head SHA matches the reviewed HEAD, and the CI conclusion on that head is green"
assert_not_contains "the hand-run ledger verify instruction is gone" "$V" "answers whether a ref resolves"
assert_not_contains "the claim-checking restatement is gone" "$V" "Check the issue, not the claim"

finish
