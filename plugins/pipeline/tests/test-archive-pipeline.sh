#!/usr/bin/env bash
# archive-pipeline.mjs — the Phase 5 wrapper that folds a finished run's .pipeline/<n>/*.json
# into knowledge/issue-archive/<n>.json.
#
# It is a thin re-dispatch of knowledge-store.mjs's archiveIssue, and the last case here pins
# exactly that: identical stdout for identical input. The two entry points are documented as
# interchangeable, so a divergence would be a silent contract break for whichever of the two a
# given project happens to call.
#
# Every invocation passes --root into the temp tree: knowledge/ is not gitignored here.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

ARCHIVE="$SCRIPTS_DIR/archive-pipeline.mjs"
STORE="$SCRIPTS_DIR/knowledge-store.mjs"

make_temp_project || exit 90
ROOT="$TEMP_PROJECT/root"
IA="$ROOT/knowledge/issue-archive"
mkdir -p "$ROOT"

JGET="$TEMP_PROJECT/jget.mjs"
cat > "$JGET" <<'EOF'
import { readFileSync } from "node:fs";
const [file, dotted] = process.argv.slice(2);
let cur = JSON.parse(readFileSync(file, "utf8"));
for (const k of dotted.split(".")) cur = cur == null ? undefined : cur[k];
console.log(typeof cur === "object" ? JSON.stringify(cur) : String(cur));
EOF
jget() { node "$JGET" "$1" "$2"; }

# ap <args...> -> RC, OUT, ERR
ap() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$TEMP_PROJECT" && node "$ARCHIVE" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

ART="$TEMP_PROJECT/artifacts"
mkdir -p "$ART"
printf '%s' '{"title":"Courier roster rotation"}' > "$ART/spec.json"
printf '%s' '{"issue_number":88,"branch":"feat/x"}' > "$ART/impl-report.json"
printf '%s' '{"current_phase":"5"}' > "$ART/status.json"

suite "archive-pipeline: argv contract"

ap --root "$ROOT"
assert_eq "a missing --issue exits 1" "$RC" "1"
assert_contains "and prints the usage line" "$ERR" "Usage: archive-pipeline.mjs --issue"

ap --issue --root "$ROOT"
assert_eq "a valueless --issue exits 1" "$RC" "1"

suite "archive-pipeline: --from an explicit artifact dir"

ap --issue 88 --from "$ART" --root "$ROOT"
assert_eq "an archive exits 0" "$RC" "0"
assert_contains "it prints the resolved output path" "$OUT" "$IA/88.json"
assert_contains "it prints the found list" "$OUT" "artifacts: spec, impl-report, status"
assert_eq "the archive carries the spec" "$(jget "$IA/88.json" spec.title)" "Courier roster rotation"
assert_eq "the archive carries the impl-report" "$(jget "$IA/88.json" impl-report.branch)" "feat/x"
assert_eq "the archive stamps the issue number" "$(jget "$IA/88.json" issue_number)" "88"

# Phase 5 can be re-run (a rework loop, a resumed pipeline). The overwrite must be idempotent
# rather than erroring or appending a second archive.
ap --issue 88 --from "$ART" --root "$ROOT"
assert_eq "re-archiving the same issue is idempotent" "$RC" "0"
assert_eq "and still carries the spec" "$(jget "$IA/88.json" spec.title)" "Courier roster rotation"

suite "archive-pipeline: the default source dir is <root>/.pipeline/<issue>"

mkdir -p "$ROOT/.pipeline/99"
printf '%s' '{"title":"Resolved from the default dir"}' > "$ROOT/.pipeline/99/spec.json"
ap --issue 99 --root "$ROOT"
assert_eq "no --from resolves <root>/.pipeline/<issue>" "$RC" "0"
assert_eq "and archives what it found there" "$(jget "$IA/99.json" spec.title)" "Resolved from the default dir"

suite "archive-pipeline: error paths"

ap --issue 100 --from "$TEMP_PROJECT/nope" --root "$ROOT"
assert_eq "an absent source dir exits 1" "$RC" "1"
assert_contains "and reports an Error" "$ERR" "Error:"
assert_contains "naming the missing dir" "$ERR" "artifact dir not found"

EMPTY="$TEMP_PROJECT/empty"
mkdir -p "$EMPTY"
ap --issue 101 --from "$EMPTY" --root "$ROOT"
assert_eq "an artifact-less source dir exits 1" "$RC" "1"
assert_contains "and reports an Error" "$ERR" "Error:"
assert_contains "naming the reason" "$ERR" "no pipeline artifacts found"

# A file where a directory is expected: statSync succeeds but isDirectory() is false, which is
# the branch a bare existsSync check would miss.
printf '%s' 'not a dir' > "$TEMP_PROJECT/afile"
ap --issue 102 --from "$TEMP_PROJECT/afile" --root "$ROOT"
assert_eq "a non-directory source exits 1" "$RC" "1"

suite "archive-pipeline: it is a thin re-dispatch, not a second implementation"

ROOT_A="$TEMP_PROJECT/root-a"
ROOT_B="$TEMP_PROJECT/root-b"
mkdir -p "$ROOT_A" "$ROOT_B"
WRAPPER_OUT=$( cd "$TEMP_PROJECT" && node "$ARCHIVE" --issue 88 --from "$ART" --root "$ROOT_A" 2>&1 )
STORE_OUT=$( cd "$TEMP_PROJECT" && node "$STORE" --archive-issue 88 --from "$ART" --root "$ROOT_B" 2>&1 )
# Normalize only the root, which is the one input deliberately made to differ.
WRAPPER_NORM=${WRAPPER_OUT//$ROOT_A/<root>}
STORE_NORM=${STORE_OUT//$ROOT_B/<root>}
assert_eq "the wrapper's stdout matches knowledge-store --archive-issue byte for byte" \
  "$WRAPPER_NORM" "$STORE_NORM"
assert_eq "and both write the same archive payload" \
  "$(jget "$ROOT_A/knowledge/issue-archive/88.json" spec.title)" \
  "$(jget "$ROOT_B/knowledge/issue-archive/88.json" spec.title)"

finish
