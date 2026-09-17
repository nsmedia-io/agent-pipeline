#!/usr/bin/env bash
# worktree.mjs: find or create an issue's Phase 3 worktree and seed its artifact dir (#164 row 10).
#
# The lookup was prose in four files (phase-3-impl.md, qa.md, dev.md, phase.md). Each block below
# builds a real git repository with a bare origin, then drives the script against one shape: an
# existing worktree found by branch, one named by tasks.json, a stale tasks.json path, two matching
# worktrees, a branch checked out in the root checkout, and creation on a new or existing branch.
# The last block holds the removed prose absent from all four files.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

WT="$SCRIPTS_DIR/worktree.mjs"
gitq() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# norm <path>: one spelling for comparison. Git Bash prints /tmp/x, node on Windows prints C:\x.
norm() {
  if [[ "$PIPELINE_ON_WINDOWS" == "1" ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" | tr 'A-Z' 'a-z'
  else
    printf '%s' "$1"
  fi
}

# native <path>: how a tool on this host would write the path into tasks.json.
native() {
  if [[ "$PIPELINE_ON_WINDOWS" == "1" ]] && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

make_temp_project 5 || exit 90
ORIGIN="$TEMP_PROJECT/origin.git"
REPO="$TEMP_PROJECT/repo"
gitq init -q --bare "$ORIGIN"
gitq init -q "$REPO"
printf 'a\n' > "$REPO/a.txt"
gitq -C "$REPO" add a.txt
gitq -C "$REPO" commit -q -m init
gitq -C "$REPO" remote add origin "$ORIGIN"
gitq -C "$REPO" push -q origin main

# wt <args...> -> RC, OUT, ERR, run from the root checkout.
wt() {
  ( cd "$REPO" && node "$WT" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

# The canonical artifacts a Phase 3 worktree is seeded from.
SEED="$REPO/.pipeline/5"
mkdir -p "$SEED"
printf '{"v":"canonical-spec"}' > "$SEED/spec.json"
printf '# constraints' > "$SEED/constraints.md"
printf '{"v":"canonical-map"}' > "$SEED/map.json"

suite "worktree resolve: none, then one found by branch"

wt resolve --issue 5
assert_eq "no worktree for the issue is NONE (2)" "$RC" "2"
assert_contains "and says NONE on stdout" "$OUT" "NONE"
assert_contains "and names the rule it searched" "$ERR" "refs/heads/(fix|feat|chore)/5-*"

WT5="$TEMP_PROJECT/wt5"
gitq -C "$REPO" worktree add -q -b feat/5-widget "$WT5" main
wt resolve --issue 5
assert_eq "one worktree on feat/5-widget resolves (0)" "$RC" "0"
assert_eq "WORKTREE_PATH is that worktree, absolute" "$(norm "$(val WORKTREE_PATH)")" "$(norm "$WT5")"
assert_eq "ARTIFACT_DIR is <worktree>/.pipeline/5" "$(norm "$(val ARTIFACT_DIR)")" "$(norm "$WT5/.pipeline/5")"
assert_eq "SOURCE names the branch rule" "$(val SOURCE)" "worktree-list"
assert_eq "BRANCH is the matched branch" "$(val BRANCH)" "feat/5-widget"

wt resolve --issue 50
assert_eq "REGRESSION: issue 50 does not match feat/5-widget (the rule anchors on <n>-)" "$RC" "2"

suite "worktree resolve: seeding by ownership"

mkdir -p "$WT5/.pipeline/5"
printf '{"v":"stale-spec"}' > "$WT5/.pipeline/5/spec.json"
printf '{"v":"worktree-map"}' > "$WT5/.pipeline/5/map.json"
wt resolve --issue 5 --seed-from "$SEED"
assert_eq "resolve with --seed-from exits 0" "$RC" "0"
assert_eq "a SEEDED artifact (spec.json) is overwritten from the canonical copy" "$(cat "$WT5/.pipeline/5/spec.json")" '{"v":"canonical-spec"}'
assert_eq "any other artifact (map.json) already in the worktree is kept" "$(cat "$WT5/.pipeline/5/map.json")" '{"v":"worktree-map"}'
assert_eq "constraints.md is copied in" "$(cat "$WT5/.pipeline/5/constraints.md")" "# constraints"
assert_contains "the seed report names what was absent" "$OUT" "MISSING=review.json,design.json"
assert_contains "and what was kept" "$OUT" "KEPT=map.json"

suite "worktree resolve: tasks.json, stale paths, ambiguity, the root checkout"

WT5B="$TEMP_PROJECT/wt5b"
gitq -C "$REPO" worktree add -q -b fix/5-other "$WT5B" main
wt resolve --issue 5
assert_eq "two worktrees matching the rule are AMBIGUOUS (2)" "$RC" "2"
assert_contains "and say AMBIGUOUS" "$OUT" "AMBIGUOUS"
assert_contains "listing both candidates" "$ERR" "fix/5-other"
assert_contains "  (the second)" "$ERR" "feat/5-widget"

printf '{"worktree_path":"%s"}' "$(native "$WT5B")" > "$SEED/tasks.json"
wt resolve --issue 5
assert_eq "tasks.json worktree_path naming one of them resolves the ambiguity (0)" "$RC" "0"
assert_eq "to the tree it names" "$(norm "$(val WORKTREE_PATH)")" "$(norm "$WT5B")"
assert_eq "SOURCE says tasks.json" "$(val SOURCE)" "tasks.json"

printf '{"worktree_path":"%s/gone"}' "$(native "$TEMP_PROJECT")" > "$SEED/tasks.json"
wt resolve --issue 5
assert_eq "a STALE tasks.json path falls back to the rule, which is still ambiguous here (2)" "$RC" "2"
assert_contains "and the stale path is named" "$ERR" "stale"
rm -f "$SEED/tasks.json"

gitq -C "$REPO" worktree remove --force "$WT5B"
gitq -C "$REPO" branch -q -D fix/5-other
gitq -C "$REPO" checkout -q -b chore/9-root
wt resolve --issue 9
assert_eq "a branch checked out in the ROOT checkout never qualifies (2)" "$RC" "2"
assert_contains "and it says so" "$ERR" "root checkout"
wt create --issue 9
assert_eq "create refuses it too, rather than a second checkout of that branch (2)" "$RC" "2"
gitq -C "$REPO" checkout -q main

suite "worktree create: reuse, new branch, existing branch, ambiguous branches"

wt create --issue 5 --type feat --slug ignored
assert_eq "create reuses the existing worktree (0)" "$RC" "0"
assert_eq "the same tree resolve found" "$(norm "$(val WORKTREE_PATH)")" "$(norm "$WT5")"

wt create --issue 7
assert_eq "create with nothing to reuse and no --type/--slug is usage (1)" "$RC" "1"
wt create --issue 7 --type feature --slug x
assert_eq "an unknown --type is usage (1)" "$RC" "1"

wt create --issue 7 --type fix --slug null-guard --seed-from "$SEED"
assert_eq "create on a new branch exits 0" "$RC" "0"
NEW7="$(val WORKTREE_PATH)"
assert_eq "SOURCE says created" "$(val SOURCE)" "created"
assert_eq "on <type>/<issue>-<slug>" "$(val BRANCH)" "fix/7-null-guard"
assert_contains "under <root>/.claude/worktrees/<issue>-phase3-" "$(norm "$NEW7")" "$(norm "$REPO/.claude/worktrees/7-phase3-")"
assert_eq "the tree exists and is on that branch" "$(git -C "$NEW7" rev-parse --abbrev-ref HEAD 2>/dev/null)" "fix/7-null-guard"
assert_eq "based on origin/main" "$(git -C "$NEW7" rev-parse HEAD 2>/dev/null)" "$(git -C "$REPO" rev-parse origin/main)"
assert_eq "and seeded" "$(cat "$NEW7/.pipeline/7/spec.json" 2>/dev/null)" '{"v":"canonical-spec"}'
wt resolve --issue 7
assert_eq "resolve then finds what create made" "$(norm "$(val WORKTREE_PATH)")" "$(norm "$NEW7")"

# Called from INSIDE a worktree, the new tree still lands under the main worktree's root.
gitq -C "$REPO" branch -q feat/8-existing main
( cd "$WT5" && node "$WT" create --issue 8 ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
RC=$?; OUT=$(cat "$TEMP_PROJECT/o")
assert_eq "create on an existing branch with no worktree exits 0" "$RC" "0"
assert_eq "and reuses the branch instead of forking one" "$(val SOURCE)/$(val BRANCH)" "created-on-existing-branch/feat/8-existing"
assert_contains "run from inside a worktree, it still lands under the ROOT checkout" "$(norm "$(val WORKTREE_PATH)")" "$(norm "$REPO/.claude/worktrees/8-phase3-")"

gitq -C "$REPO" branch -q feat/6-one main
gitq -C "$REPO" branch -q chore/6-two main
wt create --issue 6
assert_eq "two local branches matching the rule are AMBIGUOUS (2)" "$RC" "2"
assert_contains "and both are named" "$ERR" "refs/heads/chore/6-two"
assert_eq "and nothing was created" "$(ls "$REPO/.claude/worktrees" 2>/dev/null | grep -c '^6-')" "0"

suite "worktree: a registered worktree whose directory is gone is STALE, never recreated"

# The review's reproduction: a worktree under the root checkout's .claude/worktrees is deleted by
# hand, so git still lists it (prunable). Resolving it used to exit 0, and recreating its artifact
# dir made a plain folder INSIDE the root checkout, where every git command ran against the root.
GONE="$REPO/.claude/worktrees/11-gone"
gitq -C "$REPO" worktree add -q -b feat/11-gone "$GONE" main
rm -r "$GONE"
wt resolve --issue 11 --seed-from "$SEED"
assert_eq "a prunable registration matching the rule is STALE (2)" "$RC" "2"
assert_contains "  and says STALE on stdout" "$OUT" "STALE"
assert_contains "  naming the remedy" "$ERR" "git worktree prune"
assert_contains "  and the entry" "$ERR" "feat/11-gone"
assert_eq "  and the directory is NOT recreated" "$([[ -e "$GONE" ]] && echo recreated || echo absent)" "absent"
printf '{"worktree_path":"%s"}' "$(native "$GONE")" > "$REPO/.pipeline/11-tasks.json"
mkdir -p "$REPO/.pipeline/11" && mv "$REPO/.pipeline/11-tasks.json" "$REPO/.pipeline/11/tasks.json"
wt resolve --issue 11
assert_eq "tasks.json naming the deleted tree does not rescue it (2)" "$RC" "2"
assert_contains "  and tasks.json's entry is reported as stale" "$ERR" "registered but STALE"
wt create --issue 11 --type feat --slug again
assert_eq "create refuses a stale registration too, rather than adding beside it (2)" "$RC" "2"
assert_eq "  and creates nothing" "$([[ -e "$GONE" ]] && echo recreated || echo absent)" "absent"

# The folder recreated as a PLAIN directory (the defect's own end state): it exists, git no longer
# calls it prunable, and git inside it answers for the root checkout. It is still not a worktree root.
mkdir -p "$GONE"
wt resolve --issue 11
assert_eq "a plain folder at a registered worktree path is not a worktree root: STALE (2)" "$RC" "2"
assert_eq "  and no artifact dir is written into it" "$([[ -e "$GONE/.pipeline" ]] && echo written || echo absent)" "absent"
rmdir "$GONE"
gitq -C "$REPO" worktree prune
rm -r "$REPO/.pipeline/11"
wt resolve --issue 11
assert_eq "after git worktree prune the stale entry is gone and the answer is NONE (2)" "$OUT" "NONE"

suite "worktree: usage"

wt resolve
assert_eq "no --issue is usage (1)" "$RC" "1"
wt resolve --issue ../x
assert_eq "an issue that is not one path segment is refused (1)" "$RC" "1"
wt frobnicate --issue 5
assert_eq "an unknown command is usage (1)" "$RC" "1"
( cd "$TEMP_PROJECT" && node "$WT" resolve --issue 5 ) >/dev/null 2>&1
assert_eq "outside a git repository is 1, not NONE" "$?" "1"

suite "worktree: the removed prose stays removed"

P3="$(cat "$PLUGIN_ROOT/orchestrator/phase-3-impl.md")"
QA="$(cat "$PLUGIN_ROOT/agents/qa.md")"
DEV="$(cat "$PLUGIN_ROOT/agents/dev.md")"
PH="$(cat "$PLUGIN_ROOT/commands/phase.md")"
assert_contains "phase-3-impl.md calls worktree.mjs create" "$P3" 'scripts/worktree.mjs" create --issue <issue>'
assert_not_contains "the hand-built timestamp is gone from phase-3-impl.md" "$P3" 'date +%Y%m%d-%H%M%S'
assert_not_contains "the cp seeding loop is gone" "$P3" 'for f in spec.json review.json constraints.md map.json design.json'
assert_contains "qa.md's standalone fallback calls worktree.mjs resolve" "$QA" 'scripts/worktree.mjs" resolve --issue <issue>'
assert_not_contains "qa.md's porcelain grep is gone" "$QA" 'git worktree list --porcelain | grep'
assert_contains "dev.md step 1 calls worktree.mjs create" "$DEV" 'scripts/worktree.mjs" create --issue <issue>'
assert_not_contains "dev.md's literal git worktree add is gone" "$DEV" 'git worktree add .claude/worktrees/'
assert_contains "phase.md Preflight calls worktree.mjs resolve" "$PH" 'scripts/worktree.mjs" resolve --issue <issue>'

finish
