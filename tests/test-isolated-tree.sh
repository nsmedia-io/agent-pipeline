#!/usr/bin/env bash
# isolated-tree.mjs: does a Phase 4 panelist's own tree qualify as isolated (#164 row 11).
#
# shared/tracked-write-isolation.md carried these checks as commands a panelist ran by hand. Each
# block below builds the tree shapes that prose measured (a detached worktree, a pinned and an
# unpinned clone, a copy of a linked worktree, a git-less copy, a tracked subdirectory, an empty
# repository) and requires the script to admit exactly the first and the pinned clone. The reach
# walk is driven twice: live on this host, and over injected modes so its rule is checked on any
# host, Windows included. The last block holds the removed prose absent.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

IT="$SCRIPTS_DIR/isolated-tree.mjs"
gitq() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

make_temp_project 1 || exit 90
chmod 700 "$TEMP_PROJECT"
REPO="$TEMP_PROJECT/repo"
gitq init -q "$REPO"
mkdir -p "$REPO/sub"
printf 'a\n' > "$REPO/a.txt"
printf 'b\n' > "$REPO/sub/b.txt"
gitq -C "$REPO" add a.txt sub/b.txt
gitq -C "$REPO" commit -q -m init
DISPATCH="$TEMP_PROJECT/dispatch"
gitq -C "$REPO" worktree add -q -b feat/1-x "$DISPATCH" main
SHA="$(git -C "$DISPATCH" rev-parse HEAD)"

# Where this host can measure reach, a tree under the 0700 temp dir qualifies. On Windows the walk
# is UNMEASURED and refuses, so the qualifying cells expect 2 there and check the other lines.
QUAL_RC=0
[[ "$PIPELINE_ON_WINDOWS" == "1" ]] && QUAL_RC=2

# chk <tree> [sha] -> RC, OUT
chk() {
  node "$IT" check "$1" --dispatch "$DISPATCH" --sha "${2:-$SHA}" >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
}
fails() { printf '%s\n' "$OUT" | grep '^FAIL' | sed 's/^FAIL \([a-z]*\):.*/\1/' | grep -v '^reach$' | tr '\n' ' ' | sed 's/ *$//'; }

suite "isolated-tree check: the two mechanisms the rule admits"

DET="$TEMP_PROJECT/iso-detached"
gitq -C "$DISPATCH" worktree add -q --detach "$DET" "$SHA"
chk "$DET"
assert_eq "git worktree add --detach <sha> qualifies on this host (0; 2 on Windows, reach UNMEASURED)" "$RC" "$QUAL_RC"
assert_eq "and fails no check but reach" "$(fails)" ""
assert_contains "it prints the registry name to record instead of the path" "$OUT" "REGISTRY_NAME=iso-detached"

gitq -C "$DISPATCH" commit -q --allow-empty -m "a checkpoint commit after the reviewed sha"
CLONE="$TEMP_PROJECT/iso-clone"
git clone -q --no-hardlinks "$DISPATCH" "$CLONE" 2>/dev/null
chk "$CLONE"
assert_eq "an UNPINNED clone taken after the tip moved does not qualify (2)" "$RC" "2"
assert_eq "  and the only failed check is the sha" "$(fails)" "sha"
git -C "$CLONE" checkout -q --detach "$SHA" 2>/dev/null
chk "$CLONE"
assert_eq "the same clone pinned with checkout --detach <sha> qualifies (0; 2 on Windows)" "$RC" "$QUAL_RC"
assert_eq "  and fails no check but reach" "$(fails)" ""

suite "isolated-tree check: the shapes the rule refuses"

COPY="$TEMP_PROJECT/iso-copy"
cp -R "$DISPATCH" "$COPY"
chk "$COPY"
assert_eq "a cp of the LINKED dispatch worktree (its .git is a file) does not qualify (2)" "$RC" "2"
assert_contains "  because it resolves to the dispatch gitdir" "$(fails)" "gitdir"

GITLESS="$TEMP_PROJECT/iso-gitless"
mkdir -p "$GITLESS"
cp "$REPO/a.txt" "$GITLESS/"
chk "$GITLESS"
assert_eq "a git-less copy does not qualify (2)" "$RC" "2"
assert_contains "  and fails the gitdir check outright, not half of it" "$OUT" "FAIL gitdir: git rev-parse --absolute-git-dir did not exit 0"
assert_contains "  and the tracked check" "$(fails)" "tracked"

chk "$DISPATCH/sub"
assert_eq "a tracked subdirectory of the dispatch tree does not qualify (2)" "$RC" "2"
assert_contains "  on the gitdir" "$(fails)" "gitdir"
assert_contains "  and on being inside the repository" "$(fails)" "outside"

EMPTY="$TEMP_PROJECT/iso-empty"
gitq init -q "$EMPTY"
chk "$EMPTY"
assert_eq "a repository with no tracked files does not qualify (2)" "$RC" "2"
assert_contains "  on the tracked count" "$OUT" "FAIL tracked: git ls-files lists 0 tracked files"

chk "$TEMP_PROJECT/iso-missing"
assert_eq "a tree that does not exist does not qualify (2)" "$RC" "2"
chk "$DET" "not-a-sha"
assert_eq "a --sha that is not hex does not qualify (2)" "$RC" "2"
chk "$DET" "0000000000000000000000000000000000000000"
assert_eq "a --sha naming no commit does not qualify (2)" "$RC" "2"

suite "isolated-tree reach: the ancestor walk, over injected modes"

# walk <leaf-mode> <parent-mode> <root-mode> [platform] -> "safe|measured"
walk() {
  MOD="$IT" LEAF="$1" PAR="$2" ROOT="$3" PLAT="${4:-linux}" node --input-type=module -e '
    const m = await import(process.env.MOD);
    const modes = { "/a/b": process.env.LEAF, "/a": process.env.PAR, "/": process.env.ROOT };
    const r = m.walkReach("/a/b", { platform: process.env.PLAT, real: (p) => "/a/b",
      stat: (p) => ({ mode: parseInt(modes[p.replace(/\\/g, "/")] || modes["/"], 8) }) });
    console.log(`${r.safe}|${r.measured}`);
  '
}
assert_eq "every component grants other-execute: UNSAFE" "$(walk 755 755 755)" "false|true"
assert_eq "one ancestor denying other-execute carries the whole chain: SAFE" "$(walk 755 750 755)" "true|true"
assert_eq "the leaf denying other-read and other-execute: SAFE" "$(walk 770 755 755)" "true|true"
assert_eq "a mode-1777 ancestor denies nothing: UNSAFE" "$(walk 755 1777 755)" "false|true"
assert_eq "the leaf denying only other-read is not enough: UNSAFE" "$(walk 751 755 755)" "false|true"
assert_eq "on win32 the walk is UNMEASURED and refuses" "$(walk 700 700 700 win32)" "false|false"

suite "isolated-tree reach: live on this host"

node "$IT" reach "$TEMP_PROJECT" >"$TEMP_PROJECT/o" 2>&1
assert_eq "the 0700 temp dir reads SAFE (0; 2 on Windows)" "$?" "$QUAL_RC"
node "$IT" reach "$TEMP_PROJECT/not-there-yet" >"$TEMP_PROJECT/o" 2>&1
RC=$?
assert_eq "a path that does not exist yet is refused (2), never walked from the cwd" "$RC" "2"
assert_contains "  and named" "$(cat "$TEMP_PROJECT/o")" "does not exist"
if [[ "$PIPELINE_ON_WINDOWS" != "1" && "$TEMP_PROJECT" == /tmp/* ]]; then
  OPEN="$TEMP_PROJECT/open"
  mkdir -p "$OPEN"
  chmod 755 "$OPEN" "$TEMP_PROJECT"
  node "$IT" reach "$OPEN" >"$TEMP_PROJECT/o" 2>&1
  assert_eq "a 0755 chain under mode-1777 /tmp reads UNSAFE (2)" "$?" "2"
  chmod 700 "$TEMP_PROJECT"
else
  record "NOT RUN: the live UNSAFE cell needs a /tmp temp dir on a POSIX host; the injected cells above hold the rule"
fi

suite "isolated-tree: usage"

node "$IT" check "$DET" --sha "$SHA" >/dev/null 2>&1
assert_eq "check without --dispatch is usage (1)" "$?" "1"
node "$IT" reach >/dev/null 2>&1
assert_eq "reach without a path is usage (1)" "$?" "1"
node "$IT" check "$DET" --dispatch "$DISPATCH" --sha "$SHA" --bogus >/dev/null 2>&1
assert_eq "an unknown flag is usage (1)" "$?" "1"

suite "isolated-tree: the removed prose stays removed"

ISO="$(cat "$PLUGIN_ROOT/shared/tracked-write-isolation.md")"
PRE="$(cat "$PLUGIN_ROOT/orchestrator/phase-4-panel-preamble.md")"
assert_contains "the shared isolation file calls isolated-tree.mjs check" "$ISO" 'scripts/isolated-tree.mjs" check <tree> --dispatch'
assert_contains "and isolated-tree.mjs reach for a location" "$ISO" 'scripts/isolated-tree.mjs" reach <parent>'
assert_not_contains "the ls -ld ancestor loop is gone" "$ISO" 'while :; do ls -ld'
assert_not_contains "the hand comparison of --absolute-git-dir is gone" "$ISO" 'rev-parse --absolute-git-dir` DIFFERS'
assert_contains "the preamble calls the check" "$PRE" 'scripts/isolated-tree.mjs" check <isolated>'
assert_not_contains "the preamble's hand comparison is gone" "$PRE" 'rev-parse --absolute-git-dir` EXITS 0 and DIFFERS'

finish
