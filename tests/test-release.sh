#!/usr/bin/env bash
# scripts/release.mjs: tag and publish a release from plugin.json, the CHANGELOG and git history.
#
# Releases 0.1.0 to 0.46.0 had no tag and no GitHub release until a hand backfill on 2026-09-17.
# These cells build a throwaway repo with a bare origin and a gh stub that records its arguments,
# then check the refusals, the commit the tag lands on, the notes, the latest flag and a re-run.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

REL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/release.mjs"

make_temp_project 0 || exit 90
ORIGIN="$TEMP_PROJECT/origin.git"
WORK="$TEMP_PROJECT/work"
GH_LOG="$TEMP_PROJECT/gh.log"
GH_STUB="$TEMP_PROJECT/gh-stub.mjs"
gitq() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# The stub appends each call to gh.log. `release view` fails unless GH_STUB_EXISTS is set, the way
# gh fails for a release that does not exist yet.
cat > "$GH_STUB" <<'EOF'
import { appendFileSync, readFileSync } from "node:fs";
const args = process.argv.slice(2);
let line = args.join(" ");
const i = args.indexOf("--notes-file");
if (i >= 0) line += "\nNOTES<<\n" + readFileSync(args[i + 1], "utf8") + "\n>>NOTES";
appendFileSync(process.env.GH_LOG, line + "\n");
if (args[0] === "release" && args[1] === "view" && !process.env.GH_STUB_EXISTS) process.exit(1);
EOF

# set_version <version> writes both manifests at that version.
set_version() {
  mkdir -p "$WORK/plugins/pipeline/.claude-plugin" "$WORK/.claude-plugin"
  printf '{"name":"pipeline","version":"%s"}\n' "$1" > "$WORK/plugins/pipeline/.claude-plugin/plugin.json"
  printf '{"metadata":{"version":"%s"},"plugins":[{"name":"pipeline","version":"%s"}]}\n' "$1" "$1" \
    > "$WORK/.claude-plugin/marketplace.json"
}

gitq init -q --bare "$ORIGIN"
gitq init -q "$WORK"
gitq -C "$WORK" checkout -q -b main
gitq -C "$WORK" remote add origin "$ORIGIN"
mkdir -p "$WORK/plugins/pipeline"
printf '# Changelog\n\n## 0.2.0 (2026-09-17)\n\nSecond release body.\n\n## 0.1.0 (2026-09-01)\n\nFirst release body.\n' \
  > "$WORK/plugins/pipeline/CHANGELOG.md"
set_version 0.1.0
gitq -C "$WORK" add -A && gitq -C "$WORK" commit -q -m "0.1.0: first"
gitq -C "$WORK" tag -a v0.1.0 -m "agent-pipeline 0.1.0"
gitq -C "$WORK" push -q origin main v0.1.0
set_version 0.2.0
gitq -C "$WORK" add -A && gitq -C "$WORK" commit -q -m "0.2.0: second"
RELEASE_COMMIT=$(git -C "$WORK" rev-parse HEAD)
# A later commit on main that does not touch plugin.json must not move the tag.
gitq -C "$WORK" commit -q --allow-empty -m "docs: after the release"
gitq -C "$WORK" push -q origin main

# rel <args...> -> RC, OUT, ERR (run from the clone, gh stubbed)
rel() {
  ( cd "$WORK" && GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t RELEASE_GH="$GH_STUB" GH_LOG="$GH_LOG" \
      GITHUB_REPOSITORY=o/r node "$REL" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}

suite "release: dry run changes nothing"

rel --dry-run
assert_eq "a dry run exits 0" "$RC" "0"
assert_contains "and names the tag, the release commit, the previous tag and latest" "$OUT" \
  "v0.2.0 at ${RELEASE_COMMIT:0:7} (previous v0.1.0, latest true)"
assert_contains "and prints this version's CHANGELOG section" "$OUT" "Second release body."
assert_not_contains "and not the older section" "$OUT" "First release body."
assert_contains "and a compare link from the previous tag" "$OUT" "https://github.com/o/r/compare/v0.1.0...v0.2.0"
assert_eq "and creates no tag" "$(git -C "$WORK" tag --list v0.2.0)" ""
assert_eq "and never calls gh" "$(cat "$GH_LOG" 2>/dev/null)" ""

suite "release: tag, push and publish"

rel
assert_eq "a release exits 0" "$RC" "0"
assert_eq "the tag lands on the commit that bumped the version, not HEAD" \
  "$(git -C "$WORK" rev-list -n 1 v0.2.0)" "$RELEASE_COMMIT"
assert_eq "the tag is annotated" "$(git -C "$WORK" cat-file -t v0.2.0)" "tag"
assert_eq "the tag is pushed to origin" "$(git -C "$ORIGIN" rev-list -n 1 v0.2.0)" "$RELEASE_COMMIT"
GH_CALLS=$(cat "$GH_LOG")
assert_contains "gh creates the release against the pushed tag, marked latest" "$GH_CALLS" \
  "release create v0.2.0 --verify-tag --title agent-pipeline 0.2.0 --notes-file"
assert_contains "with --latest=true" "$GH_CALLS" "--latest=true"
assert_contains "and the notes are the CHANGELOG section" "$GH_CALLS" "Second release body."

suite "release: running again"

: > "$GH_LOG"
GH_STUB_EXISTS=1 rel
assert_eq "an existing tag and release exit 0" "$RC" "0"
assert_contains "and say there is nothing to do" "$OUT" "release already exists"
assert_not_contains "and never create a second release" "$(cat "$GH_LOG")" "release create"

: > "$GH_LOG"
rel
assert_eq "an existing tag with no release (a half-finished run) still publishes" "$RC" "0"
assert_contains "and creates the release" "$(cat "$GH_LOG")" "release create v0.2.0"

suite "release: latest is false for an older version"

# Tag a higher version on a side commit, then release 0.2.0 again from a fresh tag state.
git -C "$WORK" tag -d v0.2.0 >/dev/null
git -C "$ORIGIN" tag -d v0.2.0 >/dev/null
gitq -C "$WORK" tag -a v0.9.0 -m "agent-pipeline 0.9.0" HEAD
: > "$GH_LOG"
rel
assert_eq "an older version still releases" "$RC" "0"
assert_contains "but is not marked latest" "$(cat "$GH_LOG")" "--latest=false"
assert_contains "and compares against the highest lower tag" "$(cat "$GH_LOG")" "compare/v0.1.0...v0.2.0"
git -C "$WORK" tag -d v0.9.0 >/dev/null

suite "release: refusals"

gitq -C "$WORK" tag -f -a v0.2.0 -m moved HEAD >/dev/null
rel --dry-run
assert_eq "a tag on a different commit refuses (1)" "$RC" "1"
assert_contains "and says to resolve it by hand" "$ERR" "resolve it by hand"
git -C "$WORK" tag -d v0.2.0 >/dev/null

printf '{"metadata":{"version":"0.1.0"},"plugins":[{"name":"pipeline","version":"0.2.0"}]}\n' \
  > "$WORK/.claude-plugin/marketplace.json"
rel --dry-run
assert_eq "manifests that disagree refuse (1)" "$RC" "1"
assert_contains "and name the fix" "$ERR" "sync-manifests.mjs"
set_version 0.2.0

set_version 0.3.0
gitq -C "$WORK" add -A && gitq -C "$WORK" commit -q -m "0.3.0: no changelog"
rel --dry-run
assert_eq "a version with no CHANGELOG section refuses (1)" "$RC" "1"
assert_contains "and names the missing heading" "$ERR" '"## 0.3.0"'

printf '\n## 0.3.0 (2026-09-18)\n\nThird.\n' >> "$WORK/plugins/pipeline/CHANGELOG.md"
set_version 0.4.0
printf '\n## 0.4.0\n\nFourth.\n' >> "$WORK/plugins/pipeline/CHANGELOG.md"
rel --dry-run
assert_eq "a version only in the working tree, never committed, refuses (1)" "$RC" "1"
assert_contains "and says it never landed" "$ERR" "never committed"

finish
