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
git -C "$PROJ/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m reviewed
SHA="$(git -C "$PROJ/wt" rev-parse HEAD)"
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
ARGS=(--issue 88 --worktree "$PROJ/wt" --impl-report "$REPORT" --root "$PROJ")
GREEN="[{\"__typename\":\"CheckRun\",\"name\":\"tests\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"},{\"__typename\":\"StatusContext\",\"context\":\"lint\",\"state\":\"SUCCESS\"},{\"__typename\":\"CheckRun\",\"name\":\"optional\",\"status\":\"COMPLETED\",\"conclusion\":\"SKIPPED\"}]"
pr() { printf '{"headRefOid":"%s","statusCheckRollup":%s}' "$1" "$2"; }

suite "merge-ready: ready"

report '"deferred":[{"what":"w","reason":"r","tracker_ref":"ledger/88-one.md"}]'
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}"
assert_eq "reviewed head, green CI, a verifying deferral ref: exit 0" "$RC" "0"
assert_contains "and it says READY" "$OUT" "READY: #88"

suite "merge-ready: the PR head"

mr "$(pr 0123456789abcdef0123456789abcdef01234567 "$GREEN")" "${ARGS[@]}"
assert_eq "a PR head that is not the reviewed commit: exit 2" "$RC" "2"
assert_contains "and names both commits" "$OUT" "PR head 0123456789ab is not the reviewed commit ${SHA:0:12}"
mr "$(pr "$SHA" "$GREEN")" --issue 88 --worktree "$PROJ/not-a-repo" --impl-report "$REPORT" --root "$PROJ"
assert_eq "a worktree whose HEAD cannot be read: exit 2" "$RC" "2"
assert_contains "and says there is no reviewed commit" "$OUT" "no reviewed commit"
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
assert_contains "and names the --no-ci remedy" "$OUT" "--no-ci"
mr "$(pr "$SHA" '[]')" "${ARGS[@]}" --no-ci
assert_eq "no checks with --no-ci: exit 0" "$RC" "0"
mr "$(pr "$SHA" '[{"__typename":"CheckRun","name":"tests","status":"COMPLETED","conclusion":"FAILURE"}]')" "${ARGS[@]}" --no-ci
assert_eq "CONTROL: --no-ci does not excuse a FAILING check" "$RC" "2"

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
mr "$(pr 0123456789abcdef0123456789abcdef01234567 '[]')" "${ARGS[@]}" --ref ledger/nope.md
assert_contains "every failure is reported, not just the first (head)" "$OUT" "is not the reviewed commit"
assert_contains "every failure is reported, not just the first (CI)" "$OUT" "no CI checks"
assert_contains "every failure is reported, not just the first (ledger)" "$OUT" "--ref[0]"

suite "merge-ready: usage"

mr "$(pr "$SHA" "$GREEN")" --issue 88 --worktree "$PROJ/wt"
assert_eq "no --impl-report: exit 1" "$RC" "1"
mr "$(pr "$SHA" "$GREEN")" "${ARGS[@]}" --what
assert_eq "an unknown flag: exit 1" "$RC" "1"
mr "$(pr "$SHA" "$GREEN")" --issue 99 --worktree "$PROJ/wt" --impl-report "$REPORT" --root "$PROJ"
assert_eq "an impl-report for a different issue: exit 1" "$RC" "1"
( cd "$PROJ" && node "$MR" --issue 88 ) >/dev/null 2>&1
assert_eq "the CLI entrypoint runs and refuses a partial invocation (1)" "$?" "1"

suite "the prose calls the script, and the removed prose stays removed"

V="$(cat "$VERDICT")"
assert_contains "phase-4-verdict.md runs merge-ready.mjs before presenting the PR" "$V" 'scripts/merge-ready.mjs" --issue <issue> --worktree "$WORKTREE_PATH" --impl-report "$ARTIFACT_DIR/impl-report.json"'
assert_contains "and passes recorded deferral refs to it" "$V" "Pass the ref it prints to \`merge-ready.mjs\` as \`--ref\`"
assert_not_contains "the hand-run CI-green check is gone" "$V" "the PR head SHA matches the reviewed HEAD, and the CI conclusion on that head is green"
assert_not_contains "the hand-run ledger verify instruction is gone" "$V" "answers whether a ref resolves"
assert_not_contains "the claim-checking restatement is gone" "$V" "Check the issue, not the claim"

finish
