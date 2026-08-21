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
#
# --root IS AS MUCH THE SUBJECT OF THIS BLOCK AS THE PATH FORM IS (#67). Both cells ran with no
# --root at all, so the CLI defaulted its root to THE INVOKER'S cwd, and the string they matched
# -- "Knowledge store is empty." -- was produced by there being no knowledge/ directory beside
# whoever ran the suite, not by main() having fired. run.sh cds into tests/, which holds no
# store, so CI was green; run this same file from the repo root, which holds a real one, and
# both cells failed with the live store's contents in the diff (measured: 21 passed, 2 failed).
# A cell whose verdict is decided by the caller's working directory is not measuring the guard.
#
# The root is now a store THIS FILE builds and fills, and the cells match a title that only a
# run of main() over that root can print. An absent store cannot produce it, a guard that never
# fires prints nothing at all, and no cwd anywhere on the machine can supply it. The three
# controls underneath are what make that a measurement rather than a claim.
#
# The `--root`-less shape also matters beyond this assertion, which is why it is worth removing
# rather than working around: knowledge/ is NOT gitignored and this repo is public, run.sh is
# the Stop-hook checkCommand at every dirty-tree turn end, and a `--list` that inherits the
# caller's cwd is one copy-paste away from a `--write` that lands test documents in the tracked
# store during a live pipeline run. test-knowledge-store.sh's header states that rule as prose,
# and every invocation in this directory now carries --root.
#
# WHAT IS STILL ONLY PROSE, stated rather than quietly left: nothing ENFORCES that rule. A scan
# over the suites was considered and rejected as half a guard -- most invocations here name the
# CLI through a `$STORE` variable, which no pattern match over a single line can resolve, so the
# scan would have been green while blind to the commonest spelling. The enforcing version belongs
# in knowledge-store.mjs, which would refuse a WRITE whose root resolved to the checkout with no
# --root given, and that file is not this lane's to edit.
PROBE_ROOT="$d/probe-root"
mkdir -p "$PROBE_ROOT/knowledge/living-context"
cat > "$PROBE_ROOT/knowledge/living-context/probe--entrypoint.json" <<'EOF'
{"title":"ENTRYPOINT-PROBE-MARKER","status":"current","domain":"testing",
 "tags":["probe"],"content":"Only a run of main() over this root can print the title above.",
 "last_updated":"2026-01-01T00:00:00Z"}
EOF

mkdir -p "$d/real" && cp "$d/lib.mjs" "$d/knowledge-store.mjs" "$d/real/" && ln -s real "$d/link"
out=$( node "$d/link/knowledge-store.mjs" --list --collection living-context --root "$PROBE_ROOT" 2>&1 )
assert_contains "invoked through a symlinked directory" "$out" "ENTRYPOINT-PROBE-MARKER"

mkdir -p "$d/has space" && cp "$d/lib.mjs" "$d/knowledge-store.mjs" "$d/has space/"
out=$( node "$d/has space/knowledge-store.mjs" --list --collection living-context --root "$PROBE_ROOT" 2>&1 )
assert_contains "invoked through a path containing a space" "$out" "ENTRYPOINT-PROBE-MARKER"

# CONTROL 1: THE CWD NO LONGER DECIDES. This is #67 itself, run rather than described. The same
# invocation is made from two directories that differ in exactly the property that used to flip
# the verdict -- one holds a real knowledge store, one holds none -- and the two must agree.
REPO_ROOT="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel 2>/dev/null || printf '')"
assert_eq "CONTROL: the repo root really does hold a knowledge store (else the next cell proves nothing)" \
  "$([[ -n "$REPO_ROOT" && -d "$REPO_ROOT/knowledge" ]] && echo holds || echo "NO STORE at ${REPO_ROOT:-<unresolved>}")" \
  "holds"
FROM_REPO=$( cd "$REPO_ROOT" && node "$d/link/knowledge-store.mjs" --list --collection living-context --root "$PROBE_ROOT" 2>&1 )
FROM_TMP=$(  cd "$d"         && node "$d/link/knowledge-store.mjs" --list --collection living-context --root "$PROBE_ROOT" 2>&1 )
assert_eq "CONTROL: run from a cwd WITH a store and from one WITHOUT, the output is identical" \
  "$FROM_REPO" "$FROM_TMP"
assert_contains "  and it is the probe root's content in both, not the caller's" \
  "$FROM_REPO" "ENTRYPOINT-PROBE-MARKER"

# CONTROL 2: THE MARKER IS NOT FREE. A guard that never fires prints nothing, so the cells above
# would be equally satisfied by a harness that always printed. Through the SAME symlinked
# directory, an IMPORT of the same module must produce no store output at all.
printf 'import { archiveIssue } from "%s/link/knowledge-store.mjs";\nconsole.log("link-importer-ok", typeof archiveIssue);\n' "$d" > "$d/link-importer.mjs"
LINK_IMPORT=$( cd "$d" && node "$d/link-importer.mjs" 2>&1 )
assert_contains "CONTROL: importing through the symlink still exposes the exports" \
  "$LINK_IMPORT" "link-importer-ok function"
assert_not_contains "CONTROL: and prints no store, so the marker above came from main() running" \
  "$LINK_IMPORT" "ENTRYPOINT-PROBE-MARKER"

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
