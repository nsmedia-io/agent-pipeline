#!/usr/bin/env bash
# The PreToolUse hook refuses DESTRUCTIVE GIT for subagents (0.42.x, B2).
#
# WHY. A subagent's working tree is shared with the orchestrator that dispatched it, and often with
# other agents. `git stash`, `git reset --hard`, `git checkout -- <paths>` / `git checkout .`,
# `git restore` of worktree paths and `git clean` discard uncommitted work there, and what they
# discard may not be the caller's. The staging gate allowed all of them ("not a staging verb").
#
# WHAT IS PINNED, in both directions:
#   - every refused form is DENIED for a subagent, at a Phase 4 record, at a Phase 3 record, and in a
#     project with no .pipeline at all (the rule asks no run-ownership question);
#   - the SAME command from the main session (no agent_id) is NOT denied;
#   - the read-only and index-only neighbours are NOT denied;
#   - the deny names the form, says why, and names what to do instead;
#   - THE DENY DOES NOT RUN THE COMMAND IT REFUSES. An early draft printed the refusal inside a
#     double-quoted string holding backquoted git commands, and the shell executed `git stash` in
#     the caller's tree while printing "git stash is refused". The last suite drives the hook in a
#     scratch repository with an uncommitted change and asserts the change survives.
#
# The entry point is read from hooks.json through the shared fixture driver, like the #106 suites.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
require_node

make_temp_project 106 || exit 90
GATE_SCRATCH="$TEMP_PROJECT"
gate_cache_declaration

P4="$TEMP_PROJECT/p4"
gate_inflight_status "$P4/.pipeline/106/status.json" "4-review"
P3="$TEMP_PROJECT/p3"
gate_inflight_status "$P3/.pipeline/106/status.json" "3-impl"
NOPIPE="$TEMP_PROJECT/no-pipeline"
mkdir -p "$NOPIPE"

# verdict <root> <command> [payload key=value ...] -> deny|none|...
verdict() {
  local root="$1" cmd="$2"; shift 2
  gate_reset_env "$root"
  run_gate "$(gate_payload "$cmd" "$@")"
  printf '%s' "$GATE_DECISION"
}
sub()  { verdict "$1" "$2" agent_id=sub-dg-1 agent_type=pipeline:qa; }
main() { verdict "$1" "$2" agent_id=__ABSENT__; }

REFUSED=(
  'git stash'
  'git stash push -u'
  'git stash -u'
  'git stash pop'
  'git stash drop'
  'git stash clear'
  'git reset --hard'
  'git reset --hard HEAD~1'
  'git checkout -- .'
  'git checkout -- plugins/pipeline/agents/qa.md'
  'git checkout HEAD -- src/a.ts'
  'git checkout .'
  'git restore .'
  'git restore src/a.ts'
  'git restore --worktree src/a.ts'
  'git restore --staged --worktree src/a.ts'
  'git restore -SW src/a.ts'
  'git restore --source=HEAD~1 src/a.ts'
  'git clean -fd'
  'git clean -n'
  'git -C sub stash'
  'cd sub && git reset --hard'
  'git log --oneline -1; git stash'
  'git add -A && git reset --hard'
)

# ===============================================================================================
suite "each destructive form is DENIED for a subagent, at any phase and with no run at all"
# ===============================================================================================
for c in "${REFUSED[@]}"; do
  assert_eq "DENY (subagent, Phase 4 record): $c" "$(sub "$P4" "$c")" "deny"
  assert_eq "DENY (subagent, Phase 3 record): $c" "$(sub "$P3" "$c")" "deny"
  assert_eq "DENY (subagent, no .pipeline): $c" "$(sub "$NOPIPE" "$c")" "deny"
done

# ===============================================================================================
suite "the SAME commands from the main session are NOT denied"
# ===============================================================================================
# The origin term is the one the staging gate uses (agent_id presence). This is the control that
# fails if the new rule forgot it: every row above would still deny, and so would these.
for c in "${REFUSED[@]}"; do
  assert_eq "ALLOW (main session): $c" "$(main "$P4" "$c")" "none"
done

# ===============================================================================================
suite "the read-only and index-only neighbours are NOT denied for a subagent"
# ===============================================================================================
ALLOWED=(
  'git stash list'
  'git stash show -p'
  'git reset'
  'git reset HEAD~1'
  'git reset --soft HEAD~1'
  'git checkout main'
  'git checkout -b feat/x'
  'git restore --staged src/a.ts'
  'git restore -S src/a.ts'
  'git show HEAD:src/a.ts > src/a.ts'
  'git status --porcelain'
  'git diff'
  'echo git stash'
  'git commit -m "git stash and git reset --hard are refused now"'
  "grep -n 'git clean' README.md"
)
for c in "${ALLOWED[@]}"; do
  assert_eq "ALLOW (subagent): $c" "$(sub "$P3" "$c")" "none"
done

# ===============================================================================================
suite "the deny says what was refused, why, and what to do instead"
# ===============================================================================================
gate_reset_env "$P3"
run_gate "$(gate_payload 'git checkout -- src/a.ts' agent_id=sub-dg-2 agent_type=pipeline:dev)"
assert_eq "the deny is a PreToolUse permissionDecision" "$GATE_DECISION" "deny"
assert_contains "it names the refused form" "$GATE_REASON" '`git checkout -- <paths>`'
assert_contains "it says WHY: the tree is shared and the loss is unrecoverable" "$GATE_REASON" "cannot be recovered"
assert_contains "it names the explicit-path commit alternative" "$GATE_REASON" 'git add <path>'
assert_contains "it names the one-file restore that replaces qa.md's old checkout" "$GATE_REASON" 'git show HEAD:<path> > <path>'
assert_contains "it says the reset decision belongs to the orchestrator" "$GATE_REASON" "orchestrator"
assert_contains "stderr carries the attribution line" "$GATE_ERR" "refused destructive git for a subagent (git checkout -- <paths>)"

# The operator disarm that covers the staging gate covers this rule too, and nothing else does.
gate_reset_env "$P3"
GATE_EXTRA_ENV=("CLAUDE_HOOK_PRETOOLUSE_SKIP=1")
run_gate "$(gate_payload 'git stash' agent_id=sub-dg-3 agent_type=pipeline:qa)"
assert_eq "the operator-set disarm lets it through" "$GATE_DECISION" "none"

# ===============================================================================================
suite "THE DENY DOES NOT EXECUTE WHAT IT REFUSES"
# ===============================================================================================
new_tmpdir || exit 90
SCRATCH_REPO="$NEW_TMPDIR"
git -C "$SCRATCH_REPO" init -q
printf 'committed\n' > "$SCRATCH_REPO/f.txt"
git -C "$SCRATCH_REPO" add f.txt
git -C "$SCRATCH_REPO" -c user.email=t@t -c user.name=t commit -q -m init
printf 'UNCOMMITTED WORK\n' > "$SCRATCH_REPO/f.txt"
for c in 'git stash' 'git reset --hard' 'git checkout -- f.txt' 'git clean -fd' 'git restore f.txt'; do
  gate_reset_env "$SCRATCH_REPO"
  run_gate "$(gate_payload "$c" agent_id=sub-dg-4 agent_type=pipeline:qa)"
  assert_eq "DENY in a real repository: $c" "$GATE_DECISION" "deny"
done
assert_eq "the uncommitted change SURVIVED five refusals (the hook ran none of them)" \
  "$(cat "$SCRATCH_REPO/f.txt")" "UNCOMMITTED WORK"
assert_eq "and no stash entry was created" "$(git -C "$SCRATCH_REPO" stash list | grep -c .)" "0"

finish
