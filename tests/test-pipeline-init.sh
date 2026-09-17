#!/usr/bin/env bash
# pipeline-init.mjs: /pipeline Phase 0 and the argument parse as one command (#164 row 16).
#
# Phase 0 was six prose steps plus the argument parse in the core. Each block below builds a real
# repository with a bare origin and drives one exit: no config (2), a dirty tree (3), a fresh ask,
# --issue writing the 0-setup record through checkpoint.mjs, --issue and --resume reading an
# existing record, a failed fetch, and the stdin form that keeps a pasted ask out of shell words.
# The last block holds the removed prose absent from phase-0-setup.md and the core.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

PI="$SCRIPTS_DIR/pipeline-init.mjs"
gitq() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

make_temp_project 1 || exit 90
ORIGIN="$TEMP_PROJECT/origin.git"
REPO="$TEMP_PROJECT/repo"
gitq init -q --bare "$ORIGIN"
gitq init -q "$REPO"
printf 'a\n' > "$REPO/a.txt"
gitq -C "$REPO" add a.txt
gitq -C "$REPO" commit -q -m init
gitq -C "$REPO" remote add origin "$ORIGIN"
gitq -C "$REPO" push -q origin main
# The adopting-project ignore rules, so a written record is the only untracked artifact.
printf '.pipeline/*\n!.pipeline/*/\n.pipeline/*/*\n!.pipeline/*/status.json\n' > "$REPO/.gitignore"

# pi <args...> -> RC, OUT (the JSON), ERR, run from the repository root.
pi() {
  ( cd "$REPO" && node "$PI" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e" </dev/null
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}
# jf <js expression over r> -> its value from the last JSON output
jf() { J="$OUT" node -e 'const r = JSON.parse(process.env.J); const v = eval(process.argv[1]); console.log(typeof v === "object" ? JSON.stringify(v) : String(v));' "$1"; }
# jp <field>: a path field with forward slashes, prefixed abs: or rel:. The separator is normalised
# inside node because Git Bash rewrites a "/" argument into a Windows path before node sees it.
jp() { J="$OUT" node -e 'const r = JSON.parse(process.env.J); const p = String(r[process.argv[1]]); console.log((require("path").isAbsolute(p) ? "abs:" : "rel:") + p.split(String.fromCharCode(92)).join(String.fromCharCode(47)));' "$1"; }
commit_all() { gitq -C "$REPO" add -A && gitq -C "$REPO" commit -q -m "$1"; }

suite "pipeline-init: the two halts"

commit_all "ignore rules"
pi --no-fetch
assert_eq "no pipeline.config.json is HALT exit 2" "$RC" "2"
assert_eq "  and the JSON names the halt" "$(jf r.halt)" "no-config"
assert_contains "  and the remedy" "$(jf r.error)" "pipeline.config.example.json"

printf '{"integrationBranch":"main"}\n' > "$REPO/pipeline.config.json"
pi --issue 12 --no-fetch
assert_eq "config present but uncommitted is a dirty tree: HALT exit 3" "$RC" "3"
assert_eq "  and the JSON names the halt" "$(jf r.halt)" "dirty"
assert_contains "  with the git status --short lines" "$(jf 'r.dirty.join(";")')" "?? pipeline.config.json"
assert_eq "  and the dirty check ran BEFORE any record was written" "$([[ -e "$REPO/.pipeline/12/status.json" ]] && echo written || echo absent)" "absent"
commit_all "config"

suite "pipeline-init: a fresh ask"

pi --no-fetch add a widget --experiment
assert_eq "a clean fresh ask exits 0" "$RC" "0"
assert_eq "mode is fresh with no issue" "$(jf r.mode)/$(jf r.issue)" "fresh/null"
assert_eq "--experiment sets experiment_mode" "$(jf r.experiment_mode)" "true"
assert_eq "and is stripped from the ask text" "$(jf r.ask_text)" "add a widget"
assert_eq "nothing is written for a fresh ask" "$(jf r.record)" "none"
assert_eq "the skeleton is returned at 0-setup" "$(jf r.status.current_phase)" "0-setup"
assert_eq "pipeline_base is absolute" "$(jp pipeline_base | cut -c1-4)" "abs:"
assert_contains "  and is <toplevel>/.pipeline" "$(jp pipeline_base)" "repo/.pipeline"
pi --no-fetch fix it --dry-run
assert_eq "--dry-run is the same modifier" "$(jf r.experiment_mode)/$(jf r.ask_text)" "true/fix it"

suite "pipeline-init: --issue writes the 0-setup record through checkpoint.mjs"

pi --issue 12 --no-fetch ship the thing
assert_eq "--issue with no record exits 0" "$RC" "0"
assert_eq "record is written" "$(jf r.record)" "written"
REC="$REPO/.pipeline/12/status.json"
recf() { node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(String(eval(process.argv[2])));' "$REC" "$1"; }
assert_eq "at current_phase 0-setup" "$(recf s.current_phase)" "0-setup"
assert_eq "issue_number is the integer" "$(recf s.issue_number)" "12"
assert_eq "schema_version and both round counters are initialised by checkpoint.mjs" "$(recf '[s.schema_version, s.fix_rounds, s.spec_revisions].join(",")')" "2,0,0"
assert_eq "telemetry is refreshed" "$(recf 'typeof s.telemetry')" "object"
assert_eq "branch and ask_text are recorded" "$(recf 's.branch + "|" + s.ask_text')" "main|ship the thing"
assert_eq "events and flags start empty" "$(recf 's.events.length + s.flags.length')" "0"
node "$SCRIPTS_DIR/check-status-record.mjs" "$REC" >/dev/null 2>&1
assert_eq "the written record passes check-status-record.mjs" "$?" "0"
commit_all "record"

node "$SCRIPTS_DIR/checkpoint.mjs" enter 1-ba --status "$REC" --exit-verdict DONE >/dev/null 2>&1
commit_all "checkpoint 1-ba"
pi --issue 12 --no-fetch
assert_eq "--issue with an existing record exits 0" "$RC" "0"
assert_eq "  leaves it alone and reports its phase" "$(jf r.record)/$(jf r.resume_phase)" "existing/1-ba"
assert_eq "  (the record is unchanged)" "$(recf s.current_phase)" "1-ba"

suite "pipeline-init: --resume"

pi --resume 12 --no-fetch
assert_eq "--resume with a record exits 0" "$RC" "0"
assert_eq "resume_phase is the record's ENTRY marker" "$(jf r.resume_phase)" "1-ba"
assert_contains "artifact_dir is <base>/12" "$(jp artifact_dir)" "repo/.pipeline/12"
pi --resume 99 --no-fetch
assert_eq "--resume with no record is 1" "$RC" "1"
assert_contains "  naming the missing record" "$(jf r.error)" "no record"
printf 'not json' > "$REPO/.pipeline/12/tasks.json"
mkdir -p "$REPO/.pipeline/13" && printf '{broken' > "$REPO/.pipeline/13/status.json"
commit_all "a broken record"
pi --resume 13 --no-fetch
assert_eq "--resume on an unreadable record is 1" "$RC" "1"

suite "pipeline-init: fetch"

pi --no-fetch x
assert_eq "--no-fetch runs no fetch" "$(jf r.fetch.ran)" "false"
pi x
assert_eq "the default fetches origin/<integrationBranch> and exits 0" "$RC/$(jf r.fetch.ok)/$(jf r.fetch.ref)" "0/true/origin/main"
printf '{"integrationBranch":"trunk"}\n' > "$REPO/pipeline.config.json"
commit_all "trunk"
pi x
assert_eq "a failed fetch (origin has no trunk) does not halt: exit 0" "$RC" "0"
assert_eq "  fetch.ok is false and the ref is the configured branch" "$(jf r.fetch.ok)/$(jf r.fetch.ref)" "false/origin/trunk"
assert_contains "  and a warning says Phase 2 would read a stale base" "$(jf 'r.warnings.join(";")')" "possibly stale origin/trunk"

suite "pipeline-init: the stdin argument and the ask text"

( cd "$REPO" && printf -- '--issue 21 --no-fetch "quoted" $HOME `id` --dry-run\n' | node "$PI" --argument-stdin ) >"$TEMP_PROJECT/o" 2>&1
RC=$?; OUT=$(cat "$TEMP_PROJECT/o")
assert_eq "--argument-stdin parses the whole argument from stdin (0)" "$RC" "0"
assert_eq "  issue, mode and modifier come from stdin" "$(jf r.mode)/$(jf r.issue)/$(jf r.experiment_mode)" "issue/21/true"
assert_eq "  and shell metacharacters stay literal text, never expanded" "$(jf r.ask_text)" '"quoted" $HOME `id`'
rm -rf "$REPO/.pipeline/21"

pi --no-fetch use key AKIAIOSFODNN7EXAMPLE now
assert_eq "an ask carrying a credential shape still exits 0" "$RC" "0"
assert_eq "  but ask_text is omitted" "$(jf r.ask_text)" "null"
assert_contains "  and a warning says why" "$(jf 'r.warnings.join(";")')" "credential shape"
LONG="$(printf 'w%.0s' $(seq 1 300))"
pi --no-fetch "$LONG"
assert_eq "ask_text is capped at 200 characters" "$(jf 'r.ask_text.length')" "200"

suite "pipeline-init: usage"

pi --issue 1 --resume 1
assert_eq "--issue and --resume together are usage (1)" "$RC" "1"
pi --issue ../x
assert_eq "an issue that is not one path segment is usage (1)" "$RC" "1"
pi --bogus
assert_eq "an unknown flag is usage (1)" "$RC" "1"
( cd "$TEMP_PROJECT" && node "$PI" --no-fetch ) >"$TEMP_PROJECT/o" 2>&1
assert_eq "outside a git repository is 1" "$?" "1"

suite "pipeline-init: the removed prose stays removed"

P0="$(cat "$PLUGIN_ROOT/orchestrator/phase-0-setup.md")"
CORE="$(cat "$PLUGIN_ROOT/commands/pipeline.md")"
assert_contains "phase-0-setup.md calls pipeline-init.mjs" "$P0" 'scripts/pipeline-init.mjs" --argument-stdin'
assert_not_contains "the hand config test is gone" "$P0" 'test -f "$(git rev-parse --show-toplevel)/pipeline.config.json"'
assert_not_contains "the hand fetch is gone" "$P0" 'Run `git fetch origin main`'
assert_not_contains "the hand-written status.json skeleton is gone" "$P0" '"started_at": "<iso-now>"'
assert_contains "the #80 ruling stays beside the dirty-tree halt" "$P0" "a ruling (#80)"
assert_not_contains "the core's hand argument parse is gone" "$CORE" 'If starts with `--resume <issue>`'
assert_not_contains "the core's hand modifier strip is gone" "$CORE" 'strip the flag from the ask text'
assert_contains "the core names the script that parses it" "$CORE" 'scripts/pipeline-init.mjs'

finish
