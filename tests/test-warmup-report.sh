#!/usr/bin/env bash
# warmup-report.mjs: the facts /warmup reports (#164 row 26).
#
# warmup.md used to hold shell recipes for steps 1 and 3 that named origin/main outright, although
# integrationBranch is a config key, plus a role-to-domain table that seven agent files repeated.
# The fixture below is a repository whose integration branch is "trunk", with one worktree whose
# branch was merged, one whose branch has no commits of its own, and one whose directory is gone.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

WR="$SCRIPTS_DIR/warmup-report.mjs"
WARMUP="$PLUGIN_ROOT/commands/warmup.md"

make_temp_project 1 || exit 90
ORIGIN="$TEMP_PROJECT/origin.git"
WORK="$TEMP_PROJECT/work"
gitq() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=trunk "$@"; }

gitq init -q --bare "$ORIGIN"
gitq init -q "$WORK"
gitq -C "$WORK" checkout -q -b trunk
printf '{"integrationBranch":"trunk"}\n' > "$WORK/pipeline.config.json"
gitq -C "$WORK" add pipeline.config.json
gitq -C "$WORK" commit -q -m "init"
gitq -C "$WORK" remote add origin "$ORIGIN"
gitq -C "$WORK" branch done-branch
gitq -C "$WORK" branch fresh-branch
gitq -C "$WORK" branch gone-branch
gitq -C "$WORK" worktree add -q "$TEMP_PROJECT/wt-done" done-branch
gitq -C "$TEMP_PROJECT/wt-done" commit -q --allow-empty -m "the merged work"
gitq -C "$WORK" merge -q --no-ff -m "Merge done-branch" done-branch
gitq -C "$WORK" worktree add -q "$TEMP_PROJECT/wt-fresh" fresh-branch
gitq -C "$WORK" worktree add -q "$TEMP_PROJECT/wt-gone" gone-branch
mv "$TEMP_PROJECT/wt-gone" "$TEMP_PROJECT/wt-moved-away"
gitq -C "$WORK" push -q origin trunk
gitq -C "$WORK" commit -q --allow-empty -m "local only"

# A stand-in gh on PATH, so the in-flight lines are tested without a network or a login.
FAKEBIN="$TEMP_PROJECT/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'SH'
#!/bin/sh
case "$1 $2" in
  "pr list") echo '[{"number":5,"title":"older pr","isDraft":false,"headRefName":"a","updatedAt":"2026-01-01T00:00:00Z"},{"number":6,"title":"newer pr","isDraft":true,"headRefName":"b","updatedAt":"2026-02-01T00:00:00Z"}]' ;;
  "issue list") echo '[{"number":9,"title":"an open issue","updatedAt":"2026-01-01T00:00:00Z"}]' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

# Run the report from a directory; sets OUT and RC.
wr() {
  local dir="$1"
  shift
  OUT="$(cd "$dir" && PATH="$FAKEBIN:$PATH" node "$WR" --no-fetch "$@" 2>&1)"
  RC=$?
}

suite "warmup-report: git state against the configured integration branch"

wr "$WORK"
assert_eq "exits 0" "$RC" "0"
assert_contains "reads the integration branch from config" "$OUT" "INTEGRATION-BRANCH: trunk (pipeline.config.json integrationBranch)"
assert_contains "drift is against origin/trunk, not origin/main" "$OUT" "DRIFT: ahead 1, behind 0 vs origin/trunk"
assert_contains "the main checkout is not a worktree" "$OUT" "IN-WORKTREE: no"
assert_contains "counts every registered worktree" "$OUT" "WORKTREES: 4 registered"
assert_contains "names the merged worktree" "$OUT" "MERGED-WORKTREE: "
assert_contains "by its branch" "$(printf '%s\n' "$OUT" | grep MERGED-WORKTREE)" "done-branch was merged into origin/trunk"
assert_not_contains "a branch with no commits of its own is not called merged" "$(printf '%s\n' "$OUT" | grep MERGED-WORKTREE)" "fresh-branch"
assert_contains "a worktree whose directory is gone is reported" "$OUT" "GONE-WORKTREE: "
wr "$TEMP_PROJECT/wt-fresh"
assert_contains "inside a worktree it says so" "$OUT" "IN-WORKTREE: yes"
printf '{}\n' > "$WORK/pipeline.config.json"
wr "$WORK"
assert_contains "with no integrationBranch set, main is the default" "$OUT" "INTEGRATION-BRANCH: main (default)"
assert_contains "and a missing origin/main is said, not skipped" "$OUT" "DRIFT: unknown (origin/main does not resolve)"
printf '{"integrationBranch":"trunk"}\n' > "$WORK/pipeline.config.json"

suite "warmup-report: in-flight work"

wr "$WORK"
assert_contains "open PRs are listed newest first" "$(printf '%s\n' "$OUT" | grep '^PR:' | head -1)" "#6 draft newer pr (b)"
assert_contains "open issues are listed" "$OUT" "ISSUE: #9 an open issue"
assert_contains "with a count" "$OUT" "IN-FLIGHT: 2 open PR(s), 1 open issue(s)"
wr "$WORK" --no-gh
assert_not_contains "--no-gh asks nothing of gh" "$OUT" "IN-FLIGHT"
BADBIN="$TEMP_PROJECT/badbin"
mkdir -p "$BADBIN"
printf '#!/bin/sh\necho "gh: not logged in" >&2\nexit 4\n' > "$BADBIN/gh"
chmod +x "$BADBIN/gh"
OUT="$(cd "$WORK" && PATH="$BADBIN:$PATH" node "$WR" --no-fetch 2>&1)"
assert_contains "a gh that fails is reported with its reason, not skipped" "$OUT" "IN-FLIGHT: unknown (gh: gh: not logged in)"

suite "warmup-report: role domains, the table the agent files used to repeat"

printf '%s\n' '{"impacted_domains":["api","data"]}' > "$TEMP_PROJECT/spec.json"
dom() { wr "$WORK" --no-gh "$@"; printf '%s\n' "$OUT" | sed -n 's/^DOMAINS: //p'; }
assert_eq "BA sweeps all domains" "$(dom --role ba)" "data api frontend infrastructure security compliance architecture testing (all domains)"
assert_eq "DBA sweeps data" "$(dom --role dba)" "data (the dba domains)"
assert_eq "SecOps sweeps security and compliance" "$(dom --role secops)" "security compliance (the secops domains)"
assert_eq "DevOps sweeps infrastructure" "$(dom --role devops)" "infrastructure (the devops domains)"
assert_eq "QA sweeps testing" "$(dom --role qa)" "testing (the qa domains)"
assert_eq "Design sweeps frontend, under its agent name too" "$(dom --role pipeline:design_review)" "frontend (the design domains)"
assert_eq "Librarian sweeps all domains" "$(dom --role librarian)" "data api frontend infrastructure security compliance architecture testing (all domains)"
assert_eq "Dev sweeps the spec's impacted domains" "$(dom --role dev --spec "$TEMP_PROJECT/spec.json")" "api data (spec impacted_domains)"
assert_contains "Dev with no spec falls back to all domains" "$(dom --role dev)" "(all domains (no spec impacted_domains resolved))"
wr "$WORK" --role nobody
assert_eq "an unknown role exits 1" "$RC" "1"
wr "$TEMP_PROJECT"
assert_eq "outside a git checkout exits 1" "$RC" "1"

suite "warmup-report: the prose it replaced stays removed"

assert_eq "warmup.md no longer hardcodes origin/main" "$(grep -c 'origin/main' "$WARMUP" | tr -d ' ')" "0"
assert_eq "warmup.md no longer carries the role-domain table" "$(grep -c '^| Role | Warmup domains |' "$WARMUP" | tr -d ' ')" "0"
assert_eq "warmup.md no longer carries the gh recipes" "$(grep -c 'gh pr list' "$WARMUP" | tr -d ' ')" "0"
assert_contains "warmup.md runs the report" "$(cat "$WARMUP")" 'scripts/warmup-report.mjs"'
COPIES=0
for f in ba dba dev devops qa secops librarian; do
  grep -q 'warmup-report.mjs --role' "$PLUGIN_ROOT/agents/$f.md" && COPIES=$((COPIES + 1))
done
assert_eq "all seven agent scope lines point at the report" "$COPIES" "7"
assert_eq "no agent file restates its warmup domains" \
  "$(grep -hcE 'Default warmup domain scope( \([A-Za-z]+\))?:\**( `[a-z]+`|,? all domains)' "$PLUGIN_ROOT"/agents/*.md | awk '{ s += $1 } END { print s }')" "0"

finish
