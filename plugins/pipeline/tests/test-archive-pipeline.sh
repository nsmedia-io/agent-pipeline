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

suite "archive-pipeline: absolute paths do not survive the archival boundary"

# THE LEAK THIS EXISTS FOR. tasks.json and impl-report.json both carry worktree_path, both are
# folded into knowledge/issue-archive/<n>.json verbatim, and that file is COMMITTED -- so a
# contributor's home directory reached a public tree, twice, in one archive. status.schema.json
# had the right prohibition on the wrong file: it covers status.json, which no longer carries
# the field, while the two artifacts that do carry it had no rule at all.
RED="$TEMP_PROJECT/redact"
mkdir -p "$RED"
REDROOT="$TEMP_PROJECT/redroot"
mkdir -p "$REDROOT"
cat > "$RED/tasks.json" <<EOF
{"issue_number":34,
 "worktree_path":"$REDROOT/.claude/worktrees/34-phase3-20260820-094843",
 "elsewhere":"/Users/someone/other-checkout/.pipeline/34",
 "relative_path":".claude/worktrees/34-phase3-20260820-094843",
 "tasks":[{"id":"T1","files_touched":["$REDROOT/plugins/pipeline/scripts/x.mjs"]}]}
EOF
cat > "$RED/impl-report.json" <<EOF
{"issue_number":34,
 "a_key_nobody_listed":"/home/ci-runner/work/agent-pipeline",
 "windows_shaped":"C:\\\\Users\\\\someone\\\\repo",
 "notes":"reproduce with: cd $REDROOT/.claude/worktrees/34-phase3-20260820-094843 && bash run.sh",
 "foreign_home_note":"the run was in /Users/someone/other-checkout and then moved",
 "$REDROOT/keyed/by/path":"a value under a path-shaped KEY"}
EOF
ap --issue 34 --from "$RED" --root "$REDROOT"
assert_eq "the archive still exits 0" "$RC" "0"
ARC="$REDROOT/knowledge/issue-archive/34.json"

# UNDER THE REPO ROOT -> REPO-RELATIVE. The information survives; the machine it was on does not.
assert_eq "a worktree_path under the repo root becomes repo-relative" \
  "$(jget "$ARC" tasks.worktree_path)" ".claude/worktrees/34-phase3-20260820-094843"
# OUTSIDE IT -> A MARKER, and the KEY IS STILL THERE. Dropping the key would leave a reader
# unable to tell whether a path was redacted or was never written.
assert_eq "an absolute path outside the repo root becomes a marker, not a deletion" \
  "$(jget "$ARC" tasks.elsewhere)" "<redacted-absolute-path>"
# BY SHAPE, NOT BY KEY NAME. `worktree_path` is the key that leaked once; a redactor that keys
# on that name is a blocklist of one, and the next leak arrives under a name nobody listed.
assert_eq "BY SHAPE: an absolute path under a key no rule mentions is redacted too" \
  "$(jget "$ARC" impl-report.a_key_nobody_listed)" "<redacted-absolute-path>"
assert_contains "BY SHAPE: and one buried in an array, at depth, under a third key" \
  "$(jget "$ARC" tasks.tasks)" "plugins/pipeline/scripts/x.mjs"
assert_not_contains "with no trace of the root it was rewritten from" \
  "$(jget "$ARC" tasks.tasks)" "$REDROOT"
assert_not_contains "an absolute path embedded MID-STRING in a note does not survive either" \
  "$(jget "$ARC" impl-report.notes)" "$REDROOT"
assert_contains "and the surrounding prose does survive, so the note is still readable" \
  "$(jget "$ARC" impl-report.notes)" "reproduce with: cd .claude/worktrees/34-phase3-20260820-094843 && bash run.sh"
# A FIXTURE PER CELL OF THE RULE, not one representative fixture. The mid-string case above sits
# under the repo root, so on its own it exercises only the root arm of the embedded pattern and
# a mutation to the home arm would land in a branch nothing runs. This is the home arm, and it
# is the leak in its most common disguise: a home directory quoted inside a sentence.
assert_eq "a foreign home directory embedded in prose is redacted, and only that span" \
  "$(jget "$ARC" impl-report.foreign_home_note)" "the run was in <redacted-absolute-path> and then moved"
# The Windows arm, for the same reason: it is unreachable from a POSIX fixture tree otherwise,
# and the AC34 walk reddens on this shape, so a redactor blind to it ships a suite that cannot
# go green on a Windows-authored artifact.
assert_eq "a Windows drive-rooted path is redacted rather than passed through" \
  "$(jget "$ARC" impl-report.windows_shaped)" "<redacted-absolute-path>"
# THE SURVIVING MUTATION, named so this battery is not a rubber stamp. Five mutations to the
# redactor redden cells here (kill the relativize branch; narrow the value predicate to
# /Users/; stop redacting keys; drop the home arm of the embedded pattern; drop the embedded
# pass). One SURVIVES: narrowing DRIVE_VALUE's separator class from [\\/] to [\\] changes
# nothing, because the fixture above is the backslash spelling and no fixture uses `C:/x`.
# Left standing on purpose. A battery in which every mutation reddens cannot tell coverage
# from a harness that always fires, and closing this one buys a SPELLING of a class already
# covered rather than a class. If a redactor change ever makes the two spellings behave
# differently, this note is the place to add the twin.
assert_contains "a path-shaped KEY is redacted on the same predicate as a value" \
  "$(cat "$ARC")" '"keyed/by/path"'
# CONTROL, and the suite is a rubber stamp without it: a redactor that blanked every string
# would pass every cell above. A path that was never absolute is copied through untouched.
assert_eq "CONTROL: an already-relative path is recorded verbatim" \
  "$(jget "$ARC" tasks.relative_path)" ".claude/worktrees/34-phase3-20260820-094843"
# CONTROL over the whole file rather than the fields this test happened to name: the archive is
# the artifact, and the claim is about all of it.
assert_eq "CONTROL: no string anywhere in the written archive starts with a POSIX root" \
  "$(node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const hits = [];
     (function walk(v, p) {
       if (typeof v === "string") { if (/^\//.test(v)) hits.push(p + "=" + v); return; }
       if (Array.isArray(v)) return v.forEach((x, i) => walk(x, p + "[" + i + "]"));
       if (v && typeof v === "object") return Object.entries(v).forEach(([k, x]) => { walk(k, p + ".<key>"); walk(x, p + "." + k); });
     })(JSON.parse(readFileSync(process.argv[1], "utf8")), "");
     console.log(hits.join(" "));
   ' "$ARC")" ""
# The count makes the redaction VISIBLE. A silent rewrite is one nobody notices stopping.
assert_contains "the run reports how many absolute paths it redacted" "$OUT" "absolute paths redacted: 8"
ap --issue 88 --from "$ART" --root "$REDROOT"
assert_contains "CONTROL: and reports zero for an archive that carried none" "$OUT" "absolute paths redacted: 0"

suite "archive-pipeline: redaction takes the PATH SPAN, not the whole value (#59)"

# THE FALSE POSITIVES THIS EXISTS FOR. The predicate PR #57 shipped replaced the ENTIRE value of
# any string merely BEGINNING with a slash, so two pieces of environment evidence in #34's
# archive were destroyed along with the paths they opened with -- neither of them a leak:
#
#   .peer-review.qa.isolation.mutation_worktree  "/tmp/qa-34-mutate (detached HEAD at d8686bc...)"
#   .peer-review.qa.environment.shell            "/bin/bash (system bash 3.2)..."
#
# That is exactly the class of evidence the Phase 4 preamble requires a reviewer to produce
# ("name the event, name the environment where it occurs"). QA complied and archival deleted the
# compliance. `/bin/bash` is also not a path anyone needs redacted, so the old predicate refused
# correct work in two directions -- the test this repo applies before adopting any guardrail.
#
# The fix narrows WHAT IS REPLACED, never WHAT IS MATCHED: the span still stops at the same
# whitespace-or-quote boundary the mid-string pass has always used, still fires by SHAPE and not
# by key name, and adds no system root to any blocklist. The planted-leak battery above is
# UNCHANGED and runs on its own tree, which is what makes "the guard was not weakened" checkable
# rather than asserted.
RED2="$TEMP_PROJECT/redact-span"
mkdir -p "$RED2"
REDROOT2="$TEMP_PROJECT/redroot-span"
mkdir -p "$REDROOT2"
cat > "$RED2/peer-review.json" <<EOF
{"issue_number":59,
 "mutation_worktree":"/tmp/qa-34-mutate (detached HEAD at d8686bc)",
 "shell":"/bin/bash (system bash 3.2)",
 "under_root_with_prose":"$REDROOT2/plugins/pipeline/scripts/x.mjs (line 42, after the fix)",
 "home_leading_prose":"/Users/someone/checkout ran the battery",
 "windows_with_prose":"C:\\\\Users\\\\someone\\\\repo (the CI box)",
 "bare_home":"/Users/someone/secret/home",
 "already_relative":"plugins/pipeline/scripts/x.mjs (line 42)"}
EOF
ap --issue 59 --from "$RED2" --root "$REDROOT2"
assert_eq "the archive exits 0" "$RC" "0"
ARC2="$REDROOT2/knowledge/issue-archive/59.json"

# THE TWO MEASURED FALSE POSITIVES, one cell each, quoting the values as they were recorded on
# #34. Both must keep the marker AND keep the sentence.
assert_eq "#59: a /tmp worktree keeps the prose that made it evidence" \
  "$(jget "$ARC2" peer-review.mutation_worktree)" "<redacted-absolute-path> (detached HEAD at d8686bc)"
assert_eq "#59: and a system binary keeps its version note" \
  "$(jget "$ARC2" peer-review.shell)" "<redacted-absolute-path> (system bash 3.2)"
# The RELATIVIZE arm of the same rule: under the repo root the path is not merely marked, it is
# rewritten -- and the prose after it still survives.
#
# NAMED SURVIVING MUTATION, so this battery is not read as a rubber stamp. Reverting the fix to
# the whole-value predicate reddens four cells here and leaves THIS one green, because
# path.relative() treats the trailing prose as more path segments and returns the same bytes by
# accident. The cell is kept because it is the only one asserting the relativize arm at all, and
# disclosed because it discriminates nothing on its own: the four cells around it are what prove
# the span rule, and this one proves the arm still exists.
assert_eq "#59: a leading path UNDER the repo root relativizes and keeps its trailing prose" \
  "$(jget "$ARC2" peer-review.under_root_with_prose)" "plugins/pipeline/scripts/x.mjs (line 42, after the fix)"
# THE LEAK ARM, in the shape that matters most: a home directory OPENING the value. The span is
# gone; the sentence is not. This is the cell that would redden if the fix had been "stop
# redacting values that carry prose".
assert_eq "#59: a home directory opening a sentence loses the path and only the path" \
  "$(jget "$ARC2" peer-review.home_leading_prose)" "<redacted-absolute-path> ran the battery"
assert_eq "#59: and the Windows drive arm behaves the same way" \
  "$(jget "$ARC2" peer-review.windows_with_prose)" "<redacted-absolute-path> (the CI box)"
# CONTROL: the span IS the whole value when the whole value is a path. Without this cell, "the
# span is narrower" is equally consistent with a redactor that stopped firing on bare paths.
assert_eq "CONTROL: a bare absolute path with no prose is still replaced in its entirety" \
  "$(jget "$ARC2" peer-review.bare_home)" "<redacted-absolute-path>"
assert_eq "CONTROL: a string that was never absolute is copied through untouched" \
  "$(jget "$ARC2" peer-review.already_relative)" "plugins/pipeline/scripts/x.mjs (line 42)"
# THE GUARD IS NOT WEAKENED, asserted over the whole file rather than the fields named above:
# no home directory survives anywhere, and no string still opens with a POSIX root.
assert_not_contains "#59: no home directory survives anywhere in the written archive" \
  "$(cat "$ARC2")" "/Users/someone"
assert_eq "#59: and no string anywhere in it still starts with a POSIX root" \
  "$(node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const hits = [];
     (function walk(v, p) {
       if (typeof v === "string") { if (/^\//.test(v)) hits.push(p + "=" + v); return; }
       if (Array.isArray(v)) return v.forEach((x, i) => walk(x, p + "[" + i + "]"));
       if (v && typeof v === "object") return Object.entries(v).forEach(([k, x]) => { walk(k, p + ".<key>"); walk(x, p + "." + k); });
     })(JSON.parse(readFileSync(process.argv[1], "utf8")), "");
     console.log(hits.join(" "));
   ' "$ARC2")" ""
# The count stays VISIBLE and stays EARNED: six strings changed, one per redacting cell above,
# and the untouched relative value is not among them. A span fix that quietly stopped rewriting
# one of the six would show up here even if its own cell were deleted.
assert_contains "#59: and the run still reports what it redacted" "$OUT" "absolute paths redacted: 6"

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
