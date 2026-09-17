#!/usr/bin/env bash
# phase3-exit.mjs (#164 row 6): the mis-tier tripwire and both pre-Phase-4 gates in one call,
# with the halt state written by the script. Every exit code is observed on a fixture repo, the
# status write is read back, and the indeterminate cases are asserted NOT to read as clean.
# test-mis-tier-tripwire.sh runs the same call through the prose's own bash block across shells.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

PX="$SCRIPTS_DIR/phase3-exit.mjs"
make_temp_project 17 || exit 90

# repo <name> <tier> <report-files-json> <changed-path>... -> echoes the repo dir
repo() {
  local name="$1" tier="$2" files="$3"; shift 3
  local dir="$TEMP_PROJECT/r-$name" p
  mkdir -p "$dir/.pipeline/17"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  for p in "$@"; do
    mkdir -p "$dir/$(dirname "$p")"
    printf 'x\n' > "$dir/$p"
    git -C "$dir" add -- "$p"
  done
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m change
  printf '{"issue_number":17,"risk_tier":"%s","acceptance_criteria":["AC1: the thing works"]}' "$tier" > "$dir/.pipeline/17/spec.json"
  printf '{"issue_number":17,"branch":"b","commits":[{"sha":"abc1234","message":"m","files_changed":%s}],"checks_passed":{"typecheck":true,"test":true,"lint":true},"completed_at":"2026-01-01T00:00:00Z","requirement_checks":[{"requirement_index":0,"requirement_text":"AC1 the thing works","status":"PASS","notes":"fixture"}]}' "$files" > "$dir/.pipeline/17/impl-report.json"
  printf '{"issue_number":17,"current_phase":"3-impl","flags":[]}' > "$dir/.pipeline/17/status.json"
  printf '%s' "$dir"
}
run() { # <repo> [extra args] -> RC OUT
  local r="$1"; shift
  OUT="$( cd "$r" && CLAUDE_PROJECT_DIR="$r" node "$PX" --issue 17 --worktree "$r" --artifact-dir "$r/.pipeline/17" --status "$r/.pipeline/17/status.json" "$@" 2>&1 )"
  RC=$?
}
phase_of() { node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).current_phase)' "$1/.pipeline/17/status.json"; }
flags_of() { node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).flags.map(f=>f.summary).join(" | "))' "$1/.pipeline/17/status.json"; }

suite "phase3-exit: exit 0 on a clean diff and clean gates, nothing written"

R_CLEAN=$(repo clean standard '["lib/a.txt"]' lib/a.txt)
run "$R_CLEAN"
assert_eq "clean exits 0" "$RC" "0"
assert_contains "both gates are reported" "$OUT" "PASS: gate-pre-phase4"
assert_contains "the frontend gate SKIPs on a non-frontend diff" "$OUT" "SKIP: gate-pre-phase4-frontend"
assert_contains "the result line says clean" "$OUT" "RESULT: clean (exit 0)"
assert_eq "status.json is left at 3-impl" "$(phase_of "$R_CLEAN")" "3-impl"

suite "phase3-exit: exit 3 on a tripwire HIT while the gates are clean"

R_HIT=$(repo hit standard '["lib/a.txt"]' db/migrations/0042.sql lib/a.txt)
run "$R_HIT"
assert_eq "a migration in a standard diff exits 3" "$RC" "3"
assert_contains "prints the HIT" "$OUT" "HIT: MIS-TIER: data-layer path in a standard diff: db/migrations/0042.sql"
assert_contains "the gates still ran and passed" "$OUT" "PASS: gate-pre-phase4"
assert_eq "status.json records 3-impl-tripwire" "$(phase_of "$R_HIT")" "3-impl-tripwire"
assert_contains "with a flags entry" "$(flags_of "$R_HIT")" "3-impl-tripwire: tripwire hit"

R_ARCH=$(repo arch architectural '["lib/a.txt"]' db/migrations/0042.sql)
run "$R_ARCH"
assert_eq "CONTROL: the same migration at architectural tier exits 0" "$RC" "0"
assert_contains "and the tripwire says SKIP" "$OUT" "SKIP: tripwire (architectural tier"

suite "phase3-exit: exit 3 on a diff touching pipeline.config.json (#76)"

R_CFG=$(repo cfg standard '["lib/a.txt"]' pipeline.config.json)
run "$R_CFG"
assert_eq "a standard diff touching pipeline.config.json exits 3" "$RC" "3"
assert_contains "and names the path trigger" "$OUT" "the diff touches pipeline.config.json"
R_CFG2=$(repo cfg2 standard '["lib/a.txt"]' infra/main.tf)
printf '%s' '{"architecturalTriggers":{"paths":["infra/**"]}}' > "$R_CFG2/pipeline.config.json"
run "$R_CFG2"
assert_eq "a config path trigger in the diff exits 3 too" "$RC" "3"
R_CFG3=$(repo cfg3 standard '["lib/a.txt"]' infra/main.tf)
run "$R_CFG3"
assert_eq "CONTROL: the same path with no config trigger exits 0" "$RC" "0"

suite "phase3-exit: the config is read from the worktree it diffs, the project dir only as a fallback"

# The orchestrator runs this from its own checkout while the diff lives in the worktree, so the
# two can carry different configs. The worktree's is the one the change is being judged under.
new_tmpdir || exit 90
ELSEWHERE="$NEW_TMPDIR"
TRIG='{"architecturalTriggers":{"paths":["infra/**"]}}'
elsewhere_run() { # <repo> -> RC OUT, with the project dir pointed away from the worktree
  OUT="$( cd "$ELSEWHERE" && CLAUDE_PROJECT_DIR="$ELSEWHERE" node "$PX" --worktree "$1" --artifact-dir "$1/.pipeline/17" 2>&1 )"
  RC=$?
}
R_WT=$(repo wtcfg standard '["lib/a.txt"]' infra/main.tf)
printf '%s' "$TRIG" > "$R_WT/pipeline.config.json"
rm -f "$ELSEWHERE/pipeline.config.json"
elsewhere_run "$R_WT"
assert_eq "a trigger in the worktree's config fires with no config in the project dir (exit 3)" "$RC" "3"
R_FB=$(repo fbcfg standard '["lib/a.txt"]' infra/main.tf)
printf '%s' "$TRIG" > "$ELSEWHERE/pipeline.config.json"
elsewhere_run "$R_FB"
assert_eq "with no worktree config the project dir's is the fallback (exit 3)" "$RC" "3"
R_WIN=$(repo wincfg standard '["lib/a.txt"]' infra/main.tf)
printf '%s' '{}' > "$R_WIN/pipeline.config.json"
elsewhere_run "$R_WIN"
assert_eq "CONTROL: a worktree config wins over the project dir's, even when it adds nothing (exit 0)" "$RC" "0"
R_NEST=$(repo nestcfg standard '["lib/a.txt"]' packages/app/pipeline.config.json)
run "$R_NEST"
assert_eq "a pipeline.config.json at any depth in the diff exits 3 (#76)" "$RC" "3"

suite "phase3-exit: exit 2 when a gate refuses, with the state naming which"

R_GATE=$(repo gate standard '["lib/a.txt"]' lib/a.txt)
printf '{"issue_number":17,"risk_tier":"standard","acceptance_criteria":["AC9: nobody covers this"]}' > "$R_GATE/.pipeline/17/spec.json"
run "$R_GATE"
assert_eq "an uncovered criterion exits 2" "$RC" "2"
assert_contains "and says which gate" "$OUT" "FAIL: gate-pre-phase4 (exit 1)"
assert_eq "status.json records 3-impl-gate-failed" "$(phase_of "$R_GATE")" "3-impl-gate-failed"

R_FE=$(repo fe standard '["src/components/Button.tsx"]' lib/a.txt)
run "$R_FE"
assert_eq "a frontend change with no design evidence exits 2" "$RC" "2"
assert_contains "and the frontend gate is the one that failed" "$OUT" "FAIL: gate-pre-phase4-frontend"
assert_eq "status.json records 3-impl-frontend-gate-failed" "$(phase_of "$R_FE")" "3-impl-frontend-gate-failed"

suite "phase3-exit: exit 4 INDETERMINATE, never clean"

R_EMPTY=$(repo empty standard '["lib/a.txt"]')
run "$R_EMPTY"
assert_eq "an empty diff exits 4" "$RC" "4"
assert_contains "and says why" "$OUT" "3-impl-tripwire-indeterminate: empty path list"
assert_eq "status.json records 3-impl-tripwire-indeterminate" "$(phase_of "$R_EMPTY")" "3-impl-tripwire-indeterminate"

R_NOREF=$(repo noref standard '["lib/a.txt"]' lib/a.txt)
git -C "$R_NOREF" update-ref -d refs/remotes/origin/main
run "$R_NOREF"
assert_eq "a repo with no origin/main exits 4, not 0" "$RC" "4"
assert_contains "and names git's exit status" "$OUT" "git diff --name-only -z exited"
run "$R_NOREF" --base HEAD~1
assert_eq "CONTROL: the same repo with a base that exists exits 0" "$RC" "0"

new_tmpdir || exit 90
BROKEN="$NEW_TMPDIR/scripts"
mkdir -p "$BROKEN"
cp "$SCRIPTS_DIR"/*.mjs "$SCRIPTS_DIR"/*.json "$BROKEN/" 2>/dev/null
cp -R "$SCRIPTS_DIR/../schemas" "$NEW_TMPDIR/schemas"
printf 'throw new Error("unloadable");\n' > "$BROKEN/tier-floor.mjs"
R_BROKEN=$(repo broken standard '["lib/a.txt"]' db/migrations/0042.sql)
OUT="$( cd "$R_BROKEN" && CLAUDE_PROJECT_DIR="$R_BROKEN" node "$BROKEN/phase3-exit.mjs" --worktree "$R_BROKEN" --artifact-dir "$R_BROKEN/.pipeline/17" 2>&1 )"
RC=$?
assert_eq "a surface module that throws at import exits 4, even on a diff that would have hit" "$RC" "4"
assert_not_contains "and reports no HIT it could not have evaluated" "$OUT" "HIT:"

suite "phase3-exit: a NOTE is recorded in flags; an unwritable status does not change the verdict"

R_NOTE=$(repo note standard '["lib/a.txt"]' lib/a.txt)
run "$R_NOTE"
assert_contains "a repo whose tree matches no migration glob prints the NOTE" "$OUT" "NOTE: TRIPWIRE-NOTE:"
assert_contains "and records it in flags" "$(flags_of "$R_NOTE")" "tripwire NOTE"
assert_eq "and the NOTE alone does not halt" "$RC" "0"
rm -f "$R_HIT/.pipeline/17/status.json"
run "$R_HIT"
assert_eq "with status.json absent a hit still exits 3" "$RC" "3"
assert_contains "and says the status was not written" "$OUT" "STATUS NOT WRITTEN"

suite "phase3-exit: the prose it replaced stays removed"

MD_FILES=("$PLUGIN_ROOT"/orchestrator/*.md "$PLUGIN_ROOT"/commands/*.md "$PLUGIN_ROOT"/agents/*.md)
assert_eq "no orchestrator, command or agent file carries the inline tripwire program" \
  "$(grep -l -e 'tripwireReport(' -e 'TRIPWIRE_RC' "${MD_FILES[@]}" 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "no Phase 3 prompt or dev.md repeats the two gate commands" \
  "$(grep -l 'gate-pre-phase4.mjs" --issue' "$PLUGIN_ROOT/orchestrator/phase-3-impl.md" "$PLUGIN_ROOT/orchestrator/phase-3-architectural.md" "$PLUGIN_ROOT/agents/dev.md" 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "all three call phase3-exit.mjs instead" \
  "$(grep -l 'scripts/phase3-exit.mjs' "$PLUGIN_ROOT/orchestrator/phase-3-impl.md" "$PLUGIN_ROOT/orchestrator/phase-3-architectural.md" "$PLUGIN_ROOT/agents/dev.md" | wc -l | tr -d ' ')" "3"
assert_eq "the gate file carries one bash block" \
  "$(grep -c '^```bash$' "$PLUGIN_ROOT/orchestrator/phase-3-4-gate.md" | tr -d ' ')" "1"
printf 'const r=m.tripwireReport(paths)\n' > "$TEMP_PROJECT/probe.md"
assert_eq "CONTROL: the absence grep finds a planted copy" \
  "$(grep -l -e 'tripwireReport(' -e 'TRIPWIRE_RC' "$TEMP_PROJECT/probe.md" | wc -l | tr -d ' ')" "1"

finish
