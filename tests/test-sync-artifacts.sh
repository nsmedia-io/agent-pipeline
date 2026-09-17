#!/usr/bin/env bash
# sync-artifacts.mjs and artifact-ownership.mjs: the Phase 4 artifact sync (#164 row 14).
#
# Before this the ownership split was a bash `case` in phase-4-verdict.md, mirrored by hand in
# knowledge-store.mjs's WORKTREE_PRODUCED. Now both read one module. The first cells run the
# removed bash block on the same fixture and require the script to leave the identical tree.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

SA="$SCRIPTS_DIR/sync-artifacts.mjs"
OWN="$SCRIPTS_DIR/artifact-ownership.mjs"
VERDICT="$PLUGIN_ROOT/orchestrator/phase-4-verdict.md"

make_temp_project 77 || exit 90

# fixture <src> <dst>: a worktree dir with every ownership class, and a canonical dir holding
# an authoritative seed and a stale produced artifact.
fixture() {
  local src="$1" dst="$2" n
  mkdir -p "$src/sub" "$dst"
  for n in spec review review.dba status map tasks impl-report peer-review peer-review.secops design; do
    printf '{"side":"worktree","name":"%s"}' "$n" > "$src/$n.json"
  done
  printf '# worktree constraints' > "$src/constraints.md"
  printf 'nested' > "$src/sub/ignored.json"
  printf '{"side":"canonical","name":"spec"}' > "$dst/spec.json"
  printf '{"side":"canonical-stale","name":"impl-report"}' > "$dst/impl-report.json"
  printf '{"side":"canonical","name":"design"}' > "$dst/design.json"
}
old_block() {  # the removed prose block, verbatim apart from its two inputs
  local SRC="$1" DST="$2" f b
  if [ -d "$SRC" ] && [ "$SRC" != "$DST" ]; then
    mkdir -p "$DST"
    for f in "$SRC"/*; do
      [ -f "$f" ] || continue
      b="$(basename "$f")"
      case "$b" in
        spec.json|review.json|review.*.json|constraints.md|status.json)
          cp -n "$f" "$DST/" 2>/dev/null || true ;;
        map.json|tasks.json|impl-report.json|peer-review.json|peer-review.*.json)
          cp -f "$f" "$DST/" 2>/dev/null || true ;;
        *)
          cp -n "$f" "$DST/" 2>/dev/null || true
          printf 'sync: %s matches no ownership rule; copied no-clobber. Classify it above.\n' "$b" ;;
      esac
    done
  fi
}
tree() {  # name=content per file, sorted
  local d="$1" f
  for f in "$d"/*; do [ -f "$f" ] && printf '%s=%s\n' "$(basename "$f")" "$(cat "$f")"; done
  [ -d "$d/sub" ] && printf 'SUBDIR PRESENT\n'
  return 0
}
sa() {
  ( cd "$TEMP_PROJECT" && node "$SA" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}

suite "sync-artifacts: the same result as the removed bash block"

fixture "$TEMP_PROJECT/wt-old" "$TEMP_PROJECT/canon-old"
old_block "$TEMP_PROJECT/wt-old" "$TEMP_PROJECT/canon-old" > /dev/null
fixture "$TEMP_PROJECT/wt" "$TEMP_PROJECT/canon"
sa --from "$TEMP_PROJECT/wt" --to "$TEMP_PROJECT/canon"
assert_eq "a sync exits 0" "$RC" "0"
assert_eq "the canonical tree is identical to what the old bash block left" "$(tree "$TEMP_PROJECT/canon")" "$(tree "$TEMP_PROJECT/canon-old")"
C="$(tree "$TEMP_PROJECT/canon")"
assert_contains "a seeded file with a canonical copy is NOT overwritten" "$C" 'spec.json={"side":"canonical","name":"spec"}'
assert_contains "a produced file overwrites a stale canonical copy" "$C" 'impl-report.json={"side":"worktree","name":"impl-report"}'
assert_contains "a produced shard is copied" "$C" 'peer-review.secops.json={"side":"worktree"'
assert_contains "a seeded shard absent from canonical is copied" "$C" 'review.dba.json={"side":"worktree"'
assert_contains "an unclassified file with a canonical copy is kept" "$C" 'design.json={"side":"canonical","name":"design"}'
assert_not_contains "a subdirectory is not descended into" "$C" "SUBDIR PRESENT"
assert_contains "the unclassified file is named" "$OUT" "UNCLASSIFIED design.json"
assert_not_contains "and no classified file is" "$OUT" "UNCLASSIFIED spec.json"

printf '{"side":"worktree-newer","name":"map"}' > "$TEMP_PROJECT/wt/map.json"
sa --from "$TEMP_PROJECT/wt" --to "$TEMP_PROJECT/canon"
assert_eq "the second sync (before Phase 5) exits 0" "$RC" "0"
assert_contains "and carries a produced artifact written after the first" "$(cat "$TEMP_PROJECT/canon/map.json")" "worktree-newer"

suite "sync-artifacts: no-ops, failures and usage"

sa --from "$TEMP_PROJECT/no-such-dir" --to "$TEMP_PROJECT/canon"
assert_eq "an absent --from is a no-op (0)" "$RC" "0"
assert_contains "and says so" "$OUT" "nothing to sync"
sa --from "$TEMP_PROJECT/canon" --to "$TEMP_PROJECT/canon"
assert_eq "the same directory is a no-op (0)" "$RC" "0"
assert_contains "and says so" "$OUT" "same directory"

fixture "$TEMP_PROJECT/wt2" "$TEMP_PROJECT/canon2"
rm -f "$TEMP_PROJECT/canon2/impl-report.json"
mkdir -p "$TEMP_PROJECT/canon2/impl-report.json"
sa --from "$TEMP_PROJECT/wt2" --to "$TEMP_PROJECT/canon2"
assert_eq "a produced artifact that cannot be copied exits 1, not swallowed" "$RC" "1"
assert_contains "and names it" "$ERR" "FAILED impl-report.json"
assert_contains "and the rest still synced" "$(cat "$TEMP_PROJECT/canon2/tasks.json")" "worktree"

sa --from "$TEMP_PROJECT/wt"
assert_eq "no --to is usage (1)" "$RC" "1"
sa --from a --to b --force
assert_eq "an unknown flag is usage (1)" "$RC" "1"

suite "artifact-ownership: one list, read by both the sync and the archive"

CLS="$(MOD="$OWN" node --input-type=module -e '
  const m = await import(process.env.MOD);
  const names = ["spec.json","review.json","review.devops.json","status.json","constraints.md","map.json","tasks.json","impl-report.json","peer-review.json","peer-review.qa.json","design.json","notes.txt"];
  console.log(names.map((n) => `${n}:${m.ownershipOf(n)}`).join(" "));
  console.log("produced-stems:" + m.WORKTREE_PRODUCED.map((s) => m.ownershipOf(`${s}.json`)).join(","));
')"
assert_eq "every artifact classifies as the old case statement did" "$(printf '%s' "$CLS" | head -1)" \
  "spec.json:seeded review.json:seeded review.devops.json:seeded status.json:seeded constraints.md:seeded map.json:produced tasks.json:produced impl-report.json:produced peer-review.json:produced peer-review.qa.json:produced design.json:null notes.txt:null"
assert_eq "every WORKTREE_PRODUCED stem the archive checks is one the sync forces" "$(printf '%s' "$CLS" | tail -1)" "produced-stems:produced,produced,produced,produced"
KS="$(cat "$SCRIPTS_DIR/knowledge-store.mjs")"
assert_contains "knowledge-store.mjs imports WORKTREE_PRODUCED from the shared module" "$KS" 'import { WORKTREE_PRODUCED } from "./artifact-ownership.mjs";'
assert_not_contains "and no longer carries its own copy" "$KS" "const WORKTREE_PRODUCED ="

suite "the prose calls the script, and the bash block stays removed"

V="$(cat "$VERDICT")"
assert_contains "phase-4-verdict.md runs sync-artifacts.mjs" "$V" 'scripts/sync-artifacts.mjs" --from "$ARTIFACT_DIR" --to "$PIPELINE_BASE/<issue>"'
assert_contains "the run-twice rule survives" "$V" "Run it twice"
assert_contains "the heading knowledge-store's refusal names survives" "$V" "### Sync Phase 3 artifacts to the orchestrator pipeline directory"
assert_not_contains "the cp -n copy is gone" "$V" "cp -n"
assert_not_contains "the ownership case statement is gone" "$V" "spec.json|review.json|review.*.json"

finish
