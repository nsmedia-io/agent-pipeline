#!/usr/bin/env bash
# knowledge-store.mjs --verify-commit, --lint and --drift-claims (#164 row 17).
#
# The Librarian used to verify its own commit, lint the store and collect drift claims by reading
# prose steps and running git and globs by hand. Its recorded failure was a report claiming
# updates that were never committed. These cells run the three commands against a scratch git
# repository and a scratch store, for every exit code, and pin that the prose now calls them.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

STORE="$SCRIPTS_DIR/knowledge-store.mjs"
LIB="$PLUGIN_ROOT/agents/librarian.md"

make_temp_project || exit 90
REPO="$TEMP_PROJECT/repo"
mkdir -p "$REPO/knowledge/living-context"

ks() {
  ( cd "$REPO" && node "$STORE" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}
g() { git -C "$REPO" "$@" >/dev/null 2>&1; }

# THE REPOSITORY. One commit that touches two knowledge files and one that touches code only, so
# the newest commit touching knowledge/ is not HEAD. The verify command has to find the knowledge
# commit rather than read HEAD, and has to refuse a file that commit did not touch.
suite "knowledge-store --verify-commit"

g init -q
g config user.email t@example.com
g config user.name t
g config commit.gpgsign false
printf '{"title":"a"}\n' > "$REPO/knowledge/living-context/data--a.json"
printf '{"title":"b"}\n' > "$REPO/knowledge/living-context/data--b.json"
printf '{"title":"c"}\n' > "$REPO/knowledge/living-context/data--c.json"
g add knowledge/living-context/data--c.json
g commit -q -m base
g add knowledge
g commit -q -m "docs(knowledge): refresh"
KSHA="$(git -C "$REPO" rev-parse HEAD)"
printf 'x\n' > "$REPO/code.txt"
g add code.txt
g commit -q -m code

ks --verify-commit --files knowledge/living-context/data--a.json knowledge/living-context/data--b.json
assert_eq "a clean store whose last knowledge commit touches both claimed files: exit 0" "$RC" "0"
assert_contains "and it prints that commit, not HEAD" "$OUT" "COMMIT: $KSHA"
assert_contains "and how many files it verified" "$OUT" "files verified: 2"

ks --verify-commit --files knowledge/living-context/data--a.json knowledge/living-context/data--c.json
assert_eq "a claimed file the last knowledge commit did not touch: exit 2" "$RC" "2"
assert_contains "and it names that file" "$OUT" "knowledge/living-context/data--c.json"
assert_not_contains "and not the one it did touch" "$OUT" "NOT IN ${KSHA:0:12}: knowledge/living-context/data--a.json"

printf '{"title":"a2"}\n' > "$REPO/knowledge/living-context/data--a.json"
ks --verify-commit --files knowledge/living-context/data--a.json
assert_eq "an uncommitted edit under knowledge/: exit 2 even though the commit touched the file" "$RC" "2"
assert_contains "and it names the dirty path" "$OUT" "DIRTY:"
g checkout -- knowledge/living-context/data--a.json

# NO COMMIT AND NO REPOSITORY. A repository whose commits never touched knowledge/ is a failure,
# never a pass on an empty list, and a directory git cannot read is a usage error, not a verdict.
suite "knowledge-store --verify-commit: nothing to stand on"

EMPTY="$TEMP_PROJECT/empty"
mkdir -p "$EMPTY/knowledge"
git -C "$EMPTY" init -q >/dev/null 2>&1
printf %s r > "$EMPTY/README"
git -C "$EMPTY" add README >/dev/null 2>&1
git -C "$EMPTY" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q -m readme >/dev/null 2>&1
( cd "$EMPTY" && node "$STORE" --verify-commit --files knowledge/x.json ) >"$TEMP_PROJECT/o" 2>&1
RC=$?
assert_eq "a repository with commits, none touching knowledge/: exit 2" "$RC" "2"
assert_contains "and it says so" "$(cat "$TEMP_PROJECT/o")" "NO COMMIT"
NOGIT="$TEMP_PROJECT/nogit"
mkdir -p "$NOGIT"
( cd "$NOGIT" && GIT_CEILING_DIRECTORIES="$TEMP_PROJECT" node "$STORE" --verify-commit --files knowledge/x.json ) >/dev/null 2>&1
assert_eq "not a git repository: exit 1" "$?" "1"
ks --verify-commit
assert_eq "no --files: exit 1" "$RC" "1"

# THE LINT. A fixed store with one of each finding and one clean control file. Stale is measured
# against the real clock with dates far enough apart that the day boundary cannot flip a cell.
suite "knowledge-store --lint"

LC="$REPO/knowledge/living-context"
rm -f "$LC"/*.json
RECENT="$(node -e 'console.log(new Date(Date.now()-5*86400000).toISOString())')"
printf '{"title":"Clean","domain":"data","status":"current","last_updated":"%s"}' "$RECENT" > "$LC/data--clean.json"
ks --lint
assert_eq "one fresh, correctly prefixed file: exit 0" "$RC" "0"
assert_contains "and the scanned count is printed on the clean path" "$OUT" "SCANNED: 1 living-context file(s); PROBLEMS: 0"

printf '{"title":"Old","domain":"api","status":"current","last_updated":"2020-01-01T00:00:00Z"}' > "$LC/api--old.json"
ks --lint
assert_eq "a current file last updated in 2020: exit 2" "$RC" "2"
assert_contains "and it is named STALE" "$OUT" "STALE: api--old.json"
ks --lint --stale-days 100000
assert_eq "CONTROL: the same file under a 100000-day window: exit 0" "$RC" "0"
printf '{"title":"Old","domain":"api","status":"superseded","last_updated":"2020-01-01T00:00:00Z"}' > "$LC/api--old.json"
ks --lint
assert_eq "a superseded file is history, not stale: exit 0" "$RC" "0"

printf '{"title":"clean ","domain":"data","status":"current","last_updated":"%s"}' "$RECENT" > "$LC/data--clean-two.json"
ks --lint
assert_eq "two current files sharing a title (case and space aside): exit 2" "$RC" "2"
assert_contains "and both are named" "$OUT" "DUPLICATE: data--clean-two.json, data--clean.json"
printf '{"title":"Clean","domain":"data","status":"superseded","last_updated":"%s"}' "$RECENT" > "$LC/data--clean-two.json"
ks --lint
assert_eq "CONTROL: the same title on a superseded file is not a duplicate" "$RC" "0"

printf '{"title":"Wrong","domain":"api","status":"current","last_updated":"%s"}' "$RECENT" > "$LC/data--wrong.json"
ks --lint
assert_contains "a data-- file whose domain is api is named" "$OUT" 'PREFIX: data--wrong.json: prefix "data" differs from domain "api"'
assert_eq "and exits 2" "$RC" "2"
rm -f "$LC/data--wrong.json"
ks --lint --stale-days soon
assert_eq "a non-integer --stale-days: exit 1" "$RC" "1"

# THE CLAIMS. Claims sit at the top of a spec, under a role in a merged peer review, and in a
# shard; an unrelated file carrying the same key is not a claim source. A missing directory is a
# usage error, so an empty list always means a directory that was read.
suite "knowledge-store --drift-claims"

AD="$TEMP_PROJECT/artifacts"
mkdir -p "$AD"
printf '{"knowledge_drift_claims":[{"file":"data--a.json","claim":"stale"}]}' > "$AD/spec.json"
printf '{"dba":{"verdict":"APPROVE","knowledge_drift_claims":[{"file":"data--b.json","claim":"wrong"}]}}' > "$AD/peer-review.json"
printf '{"knowledge_drift_claims":[{"file":"api--c.json","claim":"gone"}]}' > "$AD/review.devops.json"
printf '{"knowledge_drift_claims":[{"file":"never","claim":"not a source"}]}' > "$AD/tasks.json"
ks --drift-claims "$AD"
assert_eq "a directory with claims: exit 0" "$RC" "0"
assert_eq "all three claims, and not the one in tasks.json" \
  "$(printf '%s' "$OUT" | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j.claims.map(c=>c.claim.file).sort().join(","))')" \
  "api--c.json,data--a.json,data--b.json"
assert_contains "the nested claim carries its path under the role" "$OUT" '".dba.knowledge_drift_claims[0]"'
ks --drift-claims "$TEMP_PROJECT/nope"
assert_eq "a missing directory: exit 1" "$RC" "1"

# THE PROSE. The Librarian's hand steps are gone and the calls replace them.
suite "librarian.md calls the commands"

assert_contains "duty 6 runs --verify-commit" "$(cat "$LIB")" "knowledge-store.mjs\" --verify-commit --files"
assert_contains "the weekly check runs --lint" "$(cat "$LIB")" "knowledge-store.mjs\" --lint"
assert_contains "duty 9 runs --drift-claims" "$(cat "$LIB")" "knowledge-store.mjs\" --drift-claims"
assert_not_contains "the hand porcelain check is gone" "$(cat "$LIB")" "git status --porcelain knowledge/"
assert_not_contains "the hand log check is gone" "$(cat "$LIB")" "git log -1 --name-only -- knowledge/"
assert_not_contains "the hand staleness step is gone" "$(cat "$LIB")" "Flag entries older than 60 days"

finish
