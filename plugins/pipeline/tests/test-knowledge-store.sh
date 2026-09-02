#!/usr/bin/env bash
# knowledge-store.mjs — the file-based knowledge store CLI.
#
# EVERY invocation below passes --root into a per-case temp dir. knowledge/ is NOT gitignored
# and this repo is public: a case that forgot --root would commit test docs into the real
# store, and run.sh executes as the Stop-hook checkCommand at every dirty-tree turn end.
#
# The suite also pins the module-entrypoint guard (AC11). session-start.sh:84 invokes this CLI
# for warmup context and treats no-output as an empty store, so a guard that fails to fire
# degrades SILENTLY: no error, no exit code, just a session that quietly lost its context.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

STORE="$SCRIPTS_DIR/knowledge-store.mjs"

make_temp_project || exit 90
ROOT="$TEMP_PROJECT/root"
LC="$ROOT/knowledge/living-context"
IA="$ROOT/knowledge/issue-archive"
mkdir -p "$LC" "$IA"

JGET="$TEMP_PROJECT/jget.mjs"
cat > "$JGET" <<'EOF'
import { readFileSync } from "node:fs";
const [file, dotted] = process.argv.slice(2);
let cur = JSON.parse(readFileSync(file, "utf8"));
for (const k of dotted.split(".")) cur = cur == null ? undefined : cur[k];
console.log(typeof cur === "object" ? JSON.stringify(cur) : String(cur));
EOF
jget() { node "$JGET" "$1" "$2"; }

# ks <args...> -> RC, OUT, ERR. --root is always inside the temp tree.
ks() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$TEMP_PROJECT" && node "$STORE" "$@" --root "$ROOT" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

cat > "$LC/testing--conventions.json" <<'EOF'
{"title":"Testing conventions","status":"current","domain":"testing",
 "tags":["fixtures","harness"],"content":"How this project writes suites.","last_updated":"2026-01-01T00:00:00Z"}
EOF
cat > "$LC/deploy--runbook.json" <<'EOF'
{"title":"Deployment runbook","status":"current","domain":"devops",
 "tags":["release"],"content":"testing testing testing happens before release.","last_updated":"2026-01-01T00:00:00Z"}
EOF
cat > "$LC/schema--pelican.json" <<'EOF'
{"title":"Pelican schema","status":"superseded","domain":"data",
 "tags":["pelican"],"content":"The pelican table shape.","last_updated":"2026-01-01T00:00:00Z"}
EOF
cat > "$IA/77.json" <<'EOF'
{"issue_number":77,"archived_at":"2026-01-01T00:00:00Z","status":"superseded",
 "spec":{"title":"Pelican rollout"}}
EOF

suite "knowledge-store: --search"

ks --search "testing"
assert_eq "a search exits 0" "$RC" "0"
assert_contains "it matches a title" "$OUT" "Testing conventions"
assert_contains "it matches body content" "$OUT" "Deployment runbook"
# A title hit is the stronger signal: the doc whose TITLE names the term must come first, or a
# passing search buries the canonical doc under every passing mention of the word.
assert_contains "a title hit outranks a body hit" "$(printf '%s' "$OUT" | head -1)" "Testing conventions"

ks --search "TESTING"
assert_contains "search is case-insensitive on the query" "$OUT" "Testing conventions"

ks --search "harness"
assert_contains "search matches tags" "$OUT" "Testing conventions"

ks --search "zzzznomatch"
assert_contains "no matches says so rather than failing" "$OUT" "No matches"
assert_eq "no matches still exits 0" "$RC" "0"

ks --search "pelican"
assert_not_contains "a superseded doc is hidden from search" "$OUT" "Pelican schema"

# An archive doc has no current/superseded lifecycle: it is history, and history stays
# searchable. This fixture carries status "superseded" precisely so the archive branch is
# proven to win over the status filter rather than merely coinciding with it.
ks --search "pelican" --collection issue-archive
assert_contains "an archive doc is NOT hidden by the status filter" "$OUT" "Pelican rollout"

ks --search "testing" --domain testing
assert_contains "--domain keeps the matching domain" "$OUT" "Testing conventions"
assert_not_contains "--domain drops the others" "$OUT" "Deployment runbook"

ks --search "testing" --collection nonsense
assert_eq "an unknown --collection exits 1" "$RC" "1"
assert_contains "and prints the usage text" "$ERR" "Usage:"

ks --search
assert_eq "--search with no terms exits 1" "$RC" "1"
assert_contains "and says what is missing" "$ERR" "requires quoted terms"

suite "knowledge-store: --write"

printf '%s' '{"status":"current","content":"no title here"}' > "$TEMP_PROJECT/no-title.json"
ks --write --file "$TEMP_PROJECT/no-title.json"
assert_eq "a doc with no title is rejected" "$RC" "1"
assert_contains "and says which field" "$ERR" 'missing a "title"'

printf '%s' '{"title":"No status","content":"x"}' > "$TEMP_PROJECT/no-status.json"
ks --write --file "$TEMP_PROJECT/no-status.json"
assert_eq "a doc with no status is rejected" "$RC" "1"
assert_contains "and says which field" "$ERR" 'missing a "status"'

ks --write --file "$TEMP_PROJECT/does-not-exist.json"
assert_eq "an unreadable source file is rejected" "$RC" "1"

printf '%s' '{"title":"Courier roster","status":"current","domain":"data","content":"roster rules"}' \
  > "$TEMP_PROJECT/courier--roster.json"
ks --write --file "$TEMP_PROJECT/courier--roster.json"
assert_eq "a valid doc is written" "$RC" "0"
assert_contains "the write is reported" "$OUT" "Wrote"
assert_eq "it lands in living-context" \
  "$([[ -f "$LC/courier--roster.json" ]] && echo written || echo missing)" "written"
assert_not_contains "last_updated is stamped when absent" "$(jget "$LC/courier--roster.json" last_updated)" "undefined"

ks --write --file "$TEMP_PROJECT/courier--roster.json" --supersede testing--conventions
assert_eq "--supersede exits 0" "$RC" "0"
assert_contains "the supersede is reported" "$OUT" "Superseded"
assert_eq "the named doc is flipped to superseded" "$(jget "$LC/testing--conventions.json" status)" "superseded"
assert_not_contains "and re-stamped" "$(jget "$LC/testing--conventions.json" last_updated)" "2026-01-01T00:00:00Z"

ks --write --file "$TEMP_PROJECT/courier--roster.json" --supersede nothing-here
assert_eq "--supersede on an unknown slug exits 1" "$RC" "1"

suite "knowledge-store: --write honours --collection (#83)"

# The parser ACCEPTED --collection on the write path and cmdWrite then discarded it, passing
# "living-context" unconditionally, so knowledge/decisions/ -- a destination the Librarian's own
# contract names (agents/librarian.md, "Record standalone decisions") -- was unreachable by the
# one script that is supposed to be the store's sole writer. On #53's Phase 5 the decision entry
# was hand-written instead, which puts that whole class of entry outside this script's validation.
#
# The decisions dir is created HERE rather than left to the first write, so the fixtures do not
# depend on the behaviour under test to have a directory to land in: a thrown setup and a
# behaviour under test to have a directory to land in: a thrown setup and a passing case are
# hard to tell apart from the transcript.
DEC="$ROOT/knowledge/decisions"
mkdir -p "$DEC"
printf '%s' '{"title":"Ferry cadence decision","status":"current","domain":"ops","content":"Ferries run hourly."}' \
  > "$TEMP_PROJECT/ferry-cadence.json"

ks --write --file "$TEMP_PROJECT/ferry-cadence.json" --collection decisions
assert_eq "--write --collection decisions exits 0" "$RC" "0"
# BOTH halves, because they fail for different reasons. The first is the flag doing its job; the
# second is the flag being the ONLY thing that decides, so a write that fanned out to every
# collection could not pass a one-sided check.
assert_eq "the doc lands in the named collection" \
  "$([[ -f "$DEC/ferry-cadence.json" ]] && echo written || echo missing)" "written"
assert_eq "and NOT in the default collection" \
  "$([[ -f "$LC/ferry-cadence.json" ]] && echo leaked || echo contained)" "contained"
assert_contains "the reported path names the collection" "$OUT" "$DEC/ferry-cadence.json"

# --supersede has to resolve in the SAME collection the write targets. A supersede still pinned
# to living-context retires the wrong document whenever a slug exists in both, which is the
# louder half of this defect: the twin below is `current` in both collections on purpose, so a
# supersede that reads the wrong directory flips a doc that should not have been touched.
printf '%s' '{"title":"Ferry cadence v0","status":"current","content":"Ferries ran twice daily."}' \
  > "$DEC/ferry-cadence-v0.json"
printf '%s' '{"title":"Ferry cadence v0 (living-context twin)","status":"current","content":"Not the target."}' \
  > "$LC/ferry-cadence-v0.json"
ks --write --file "$TEMP_PROJECT/ferry-cadence.json" --collection decisions --supersede ferry-cadence-v0
assert_eq "--supersede inside a non-default collection exits 0" "$RC" "0"
assert_eq "it flips the doc in THAT collection" "$(jget "$DEC/ferry-cadence-v0.json" status)" "superseded"
assert_eq "and leaves the same-named doc in living-context alone" \
  "$(jget "$LC/ferry-cadence-v0.json" status)" "current"

# The refusal names the directory it actually searched. Pinned because it is what an operator
# navigates by: a message hardcoded to "living-context" while the write targeted `decisions`
# sends whoever is debugging a failed supersede to the wrong folder. Caught this as a surviving
# mutation -- re-pinning the message to the literal left the whole suite green.
ks --write --file "$TEMP_PROJECT/ferry-cadence.json" --collection decisions --supersede nothing-here
assert_eq "--supersede on an unknown slug in a named collection exits 1" "$RC" "1"
assert_contains "and the refusal names the collection it searched" "$ERR" "no decisions file"

# Honouring the value means validating it, on the same allowlist the read paths already use.
ks --write --file "$TEMP_PROJECT/ferry-cadence.json" --collection nonsense
assert_eq "an unknown --collection on write exits 1" "$RC" "1"
assert_contains "and says which collection" "$ERR" "unknown --collection"

# The allowlist is also what closes the traversal the read paths never had: collectionDir joins
# the value straight into the path, so an unvalidated --collection writes wherever the `..` run
# lands. $ROOT/knowledge/../../escaped resolves to $TEMP_PROJECT/escaped.
#
# NOT RED ON THE OLD DEFECT, deliberately. Against the pre-#83 code the flag was discarded, so
# this wrote harmlessly into living-context and the containment half passed. It reddens on the
# WRONG FIX -- honouring --collection without validating it -- which is the only way this line
# can now be reached. Verified by planting exactly that: dropping the COLLECTIONS check turns
# both assertions below red while every other case in this suite stays green.
ks --write --file "$TEMP_PROJECT/ferry-cadence.json" --collection ../../escaped
assert_eq "a traversing --collection is refused" "$RC" "1"
assert_eq "and writes nothing outside knowledge/" \
  "$([[ -e "$TEMP_PROJECT/escaped" ]] && echo escaped || echo contained)" "contained"

suite "knowledge-store: --archive-issue"

ART="$TEMP_PROJECT/artifacts"
mkdir -p "$ART"
printf '%s' '{"title":"Spec"}' > "$ART/spec.json"
printf '%s' '{"dba":{"verdict":"APPROVE"}}' > "$ART/peer-review.json"
ks --archive-issue 88 --from "$ART"
assert_eq "an archive exits 0" "$RC" "0"
assert_contains "it reports the resolved output path" "$OUT" "$IA/88.json"
assert_contains "it reports which artifacts were found" "$OUT" "artifacts: spec, peer-review"
assert_eq "the archive folds in each present artifact" "$(jget "$IA/88.json" spec.title)" "Spec"
assert_eq "and stamps the issue number" "$(jget "$IA/88.json" issue_number)" "88"

EMPTY="$TEMP_PROJECT/empty-artifacts"
mkdir -p "$EMPTY"
ks --archive-issue 89 --from "$EMPTY"
assert_eq "an artifact-less source dir exits 1" "$RC" "1"
assert_contains "and says so" "$ERR" "no pipeline artifacts found"

ks --archive-issue 90 --from "$TEMP_PROJECT/not-a-dir"
assert_eq "an absent source dir exits 1" "$RC" "1"
assert_contains "and says so" "$ERR" "artifact dir not found"

ks --archive-issue 91
assert_eq "--archive-issue with no --from exits 1" "$RC" "1"

suite "knowledge-store: --list and the no-command path"

ks --list
assert_eq "--list exits 0" "$RC" "0"
assert_contains "it prints the living-context collection" "$OUT" "# living-context"
assert_contains "it prints the issue-archive collection" "$OUT" "# issue-archive"
assert_contains "it lists a doc by title" "$OUT" "Courier roster"

# The read half of #83, asserted rather than assumed: --list and --search were audited as
# already honouring --collection, and this is the observation that says so. It doubles as the
# end-to-end proof that a doc written to a non-default collection is discoverable from it.
ks --list --collection decisions
assert_eq "--list --collection decisions exits 0" "$RC" "0"
assert_contains "the read path honours --collection" "$OUT" "# decisions"
assert_contains "and finds the doc written to it" "$OUT" "Ferry cadence decision"
assert_not_contains "without listing the default collection" "$OUT" "# living-context"

ks --search "ferries" --collection decisions
assert_contains "--search honours --collection too" "$OUT" "Ferry cadence decision"

EMPTYROOT="$TEMP_PROJECT/empty-root"
mkdir -p "$EMPTYROOT"
( cd "$TEMP_PROJECT" && node "$STORE" --list --root "$EMPTYROOT" ) > "$TEMP_PROJECT/out.txt" 2>&1
assert_contains "an empty store says so" "$(cat "$TEMP_PROJECT/out.txt")" "Knowledge store is empty."

ks
assert_eq "no command exits 1" "$RC" "1"
assert_contains "and prints the usage text" "$ERR" "Usage:"

suite "knowledge-store: the module-entrypoint guard (AC11)"

# The bug: `import.meta.url === \`file://\${process.argv[1]}\`` compares a URL-ENCODED module
# URL against a raw filesystem path, so any character needing percent-encoding (a space is the
# common one) makes the comparison false and main() never runs -- no output, exit 0.
# session-start.sh:84 reads that silence as "the store is empty" and drops the warmup context.
# EVERY path-comparing form of this guard has that same silent no-op, differing only in which
# input trips it, so the shipped guard compares the script NAME instead:
#     process.argv[1].endsWith("knowledge-store.mjs")
# as gate-pre-phase4.mjs:328, gate-pre-phase4-frontend.mjs:252 and
# validate-pipeline-artifact.mjs:1029 already do. The spaced-path cases below cover the
# percent-encoding trigger; the symlink cases after them cover the realpath trigger.
SPACED="$TEMP_PROJECT/plugin dir with spaces"
PLAIN="$TEMP_PROJECT/plugindir"
mkdir -p "$SPACED" "$PLAIN"
cp "$STORE" "$SPACED/knowledge-store.mjs" && cp "$(dirname "$STORE")/lib.mjs" "$SPACED/"
cp "$STORE" "$PLAIN/knowledge-store.mjs" && cp "$(dirname "$STORE")/lib.mjs" "$PLAIN/"

# Control: the same copy under a space-free path. If this one ever fails, the harness (not the
# guard) is broken, and the case below would be measuring the wrong thing.
CONTROL_OUT=$( cd "$TEMP_PROJECT" && node "$PLAIN/knowledge-store.mjs" --list --root "$EMPTYROOT" 2>&1 )
assert_contains "control: the CLI works from a space-free path" "$CONTROL_OUT" "Knowledge store is empty."

SPACED_OUT=$( cd "$SPACED" && node "$SPACED/knowledge-store.mjs" --list --root "$EMPTYROOT" 2>&1 )
assert_contains "the CLI still runs from a path containing a space" "$SPACED_OUT" "Knowledge store is empty."

SPACED_SEARCH=$( cd "$SPACED" && node "$SPACED/knowledge-store.mjs" --search "courier" --root "$ROOT" 2>&1 )
assert_contains "and --search still returns results from a spaced path" "$SPACED_SEARCH" "Courier roster"

# The SYMLINK trigger of the same silent no-op. fileURLToPath(import.meta.url) returns the
# REALPATH while process.argv[1] keeps the path as invoked, so any path-comparing guard is
# false whenever a component is a link -- and plugin roots, dev-marketplace installs, and
# macOS /tmp and /var are routinely links. Under the librarian's `--write`, that silence means
# the doc is never written and the agent believes it landed.
#
# DELIBERATELY NOT CANONICALIZED. new_tmpdir runs `pwd -P`, which resolves links away; if this
# case reached the store through the resolved path it would measure nothing. The link is built
# here, inside the temp tree, and invoked through the link on purpose.
LINKED="$TEMP_PROJECT/linked-plugin-dir"
ln -s "$PLAIN" "$LINKED"

LINKED_OUT=$( cd "$TEMP_PROJECT" && node "$LINKED/knowledge-store.mjs" --list --root "$EMPTYROOT" 2>&1 )
assert_contains "the CLI still runs through a symlinked directory" "$LINKED_OUT" "Knowledge store is empty."

LINKED_SEARCH=$( cd "$LINKED" && node "$LINKED/knowledge-store.mjs" --search "courier" --root "$ROOT" 2>&1 )
assert_contains "and --search still returns results through a symlink" "$LINKED_SEARCH" "Courier roster"

# The other half of the guard: repairing it must not mean REMOVING it. archive-pipeline.mjs
# imports archiveIssue from this module, and an import that ran main() would print usage and
# exit 1 in the middle of the importer.
cat > "$TEMP_PROJECT/importer.mjs" <<EOF
const m = await import("$PLAIN/knowledge-store.mjs");
console.log("imported:" + typeof m.archiveIssue);
EOF
IMPORT_OUT=$( cd "$TEMP_PROJECT" && node "$TEMP_PROJECT/importer.mjs" 2>&1 )
IMPORT_RC=$?
assert_eq "importing the module exits 0" "$IMPORT_RC" "0"
assert_contains "importing exposes archiveIssue" "$IMPORT_OUT" "imported:function"
assert_not_contains "importing does NOT execute main()" "$IMPORT_OUT" "Usage:"
assert_not_contains "importing prints no store output" "$IMPORT_OUT" "Knowledge store is empty."

suite "knowledge-store: the archiveIssue traversal is closed"

# This was a recorded KNOWN COVERAGE BOUNDARY: archiveIssue joined the issue id into the
# output path unsanitized, so an id containing `..` escaped knowledge/issue-archive/ and wrote
# wherever the traversal landed. The boundary case asserted that exit-0 escape and instructed
# the next author to INVERT rather than delete it once the gap closed.
#
# The gap is now closed (assertPathSegment in scripts/lib.mjs), so these are the inverted
# assertions. Keeping the case is the point: it is the only thing that would notice if the
# sanitization were ever removed. Cross-checked by test-scripts-lib.sh at the unit level; this
# is the end-to-end half.
ESCAPE_ROOT="$TEMP_PROJECT/escape-root"
mkdir -p "$ESCAPE_ROOT"
( cd "$TEMP_PROJECT" && node "$STORE" --archive-issue '../../escaped' --from "$ART" --root "$ESCAPE_ROOT" ) \
  > "$TEMP_PROJECT/out.txt" 2>&1
ESCAPE_RC=$?
assert_eq "a traversing issue id is refused" "$ESCAPE_RC" "1"
assert_eq "and writes nothing outside knowledge/issue-archive/" \
  "$([[ -f "$ESCAPE_ROOT/escaped.json" ]] && echo escaped || echo contained)" "contained"
assert_contains "and the refusal explains itself" "$(cat "$TEMP_PROJECT/out.txt")" "single path segment"

finish
