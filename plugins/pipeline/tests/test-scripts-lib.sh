#!/usr/bin/env bash
# scripts/lib.mjs: the shared entrypoint guard and path-segment check.
#
# This file exists because the guard was previously copied into five scripts in three forms,
# two of which failed SILENTLY (main() never ran, nothing printed, exit 0). Both shipped. The
# cases below pin the properties that make the shared form safe, in both directions.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

require_node
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)}"

suite "isMain: runs directly, stays quiet on import"

new_tmpdir; d="$NEW_TMPDIR"
cp "$SCRIPTS_DIR"/lib.mjs "$SCRIPTS_DIR"/knowledge-store.mjs "$d/"

out=$( cd "$d" && node ./knowledge-store.mjs --list --collection living-context 2>&1 ); rc=$?
assert_eq "a direct run executes main()" "$rc" "0"
assert_contains "and produces its normal output" "$out" "Knowledge store is empty."

# The failure this whole helper exists to prevent: a guard that never fires prints NOTHING
# and still exits 0, which a caller cannot distinguish from success. Assert non-empty.
[[ -n "$out" ]] && silent=no || silent=yes
assert_eq "a direct run is never silent" "$silent" "no"

printf 'import { archiveIssue } from "./knowledge-store.mjs";\nconsole.log("imported-ok", typeof archiveIssue);\n' > "$d/importer.mjs"
out=$( cd "$d" && node ./importer.mjs 2>&1 )
assert_contains "an import exposes the exports" "$out" "imported-ok function"
assert_not_contains "and does NOT run main()" "$out" "Knowledge store is empty."

suite "isMain: basename, not suffix"

# The suffix form this replaced also matched any file whose name merely ENDED with the
# script's name, so an importer called test-knowledge-store.mjs ran main() mid-import.
printf 'import { archiveIssue } from "./knowledge-store.mjs";\nconsole.log("suffix-importer-ok", typeof archiveIssue);\n' > "$d/test-knowledge-store.mjs"
out=$( cd "$d" && node ./test-knowledge-store.mjs 2>&1 )
assert_contains "an importer whose name ENDS with the script name still imports" "$out" "suffix-importer-ok function"
assert_not_contains "and does not run main() (the suffix form did)" "$out" "Knowledge store is empty."

suite "isMain: path form does not matter"

# argv[1] keeps the path as invoked while import.meta.url is realpathed, so the two disagree
# through a symlink. On macOS /tmp is itself a symlink, making that routine, not exotic.
# Deliberately NOT canonicalized here: pwd -P would resolve the link away and measure nothing.
mkdir -p "$d/real" && cp "$d/lib.mjs" "$d/knowledge-store.mjs" "$d/real/" && ln -s real "$d/link"
out=$( node "$d/link/knowledge-store.mjs" --list --collection living-context 2>&1 )
assert_contains "invoked through a symlinked directory" "$out" "Knowledge store is empty."

mkdir -p "$d/has space" && cp "$d/lib.mjs" "$d/knowledge-store.mjs" "$d/has space/"
out=$( node "$d/has space/knowledge-store.mjs" --list --collection living-context 2>&1 )
assert_contains "invoked through a path containing a space" "$out" "Knowledge store is empty."

suite "assertPathSegment: refuses anything that could escape a join"

seg_probe() { ( cd "$d" && node --input-type=module -e "
import { assertPathSegment } from '$d/lib.mjs';
try { assertPathSegment(process.argv[1], 'issue'); console.log('ACCEPTED'); }
catch (e) { console.log('REFUSED', e.message); }
" "$1" 2>&1 ); }

assert_contains "a plain numeric id is accepted"      "$(seg_probe '847')"            "ACCEPTED"
assert_contains "an exp- slug is accepted"            "$(seg_probe 'exp-a-b-c')"      "ACCEPTED"
assert_contains "a parent traversal is refused"       "$(seg_probe '../../escaped')"  "REFUSED"
assert_contains "a bare .. is refused"                "$(seg_probe '..')"             "REFUSED"
assert_contains "a forward slash is refused"          "$(seg_probe 'a/b')"            "REFUSED"
assert_contains "a backslash is refused"              "$(seg_probe 'a\b')"            "REFUSED"
assert_contains "an empty id is refused"              "$(seg_probe '')"               "REFUSED"
assert_contains "a bare dot is refused"               "$(seg_probe '.')"              "REFUSED"
assert_contains "the refusal names the field"         "$(seg_probe '../x')"           "issue must be"

suite "archiveIssue: the traversal is closed end to end"

new_tmpdir; a="$NEW_TMPDIR"
mkdir -p "$a/from" "$a/root"
printf '{"title":"t","problem":"p"}\n' > "$a/from/spec.json"
out=$( cd "$a" && node "$SCRIPTS_DIR/knowledge-store.mjs" --archive-issue '../../escaped' --from "$a/from" --root "$a/root" 2>&1 ); rc=$?
assert_eq "a traversing issue id exits non-zero" "$rc" "1"
assert_contains "and says why" "$out" "single path segment"
[[ -e "$a/escaped.json" || -e "$a/../escaped.json" ]] && esc=yes || esc=no
assert_eq "and wrote nothing outside the archive dir" "$esc" "no"

out=$( cd "$a" && node "$SCRIPTS_DIR/knowledge-store.mjs" --archive-issue '847' --from "$a/from" --root "$a/root" 2>&1 )
assert_contains "a legitimate id still archives" "$out" "847.json"
[[ -f "$a/root/knowledge/issue-archive/847.json" ]] && wrote=yes || wrote=no
assert_eq "and lands inside the archive dir" "$wrote" "yes"

finish
