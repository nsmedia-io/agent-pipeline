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
