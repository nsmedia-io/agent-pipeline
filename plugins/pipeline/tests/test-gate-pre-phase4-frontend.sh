#!/usr/bin/env bash
# gate-pre-phase4-frontend.mjs — fail-CLOSED, self-SKIPPING frontend visual-verification gate.
#
# Two properties are worth more than the rest and are pinned first:
#   FAIL DIRECTION. Absence of the TRIGGER (no frontend file in the diff) is a clean skip;
#   absence of the EVIDENCE on a frontend diff is a halt. Getting these backwards produces
#   either a gate that halts every backend PR or a gate that quietly never fires.
#   CONTAINMENT. A recorded screenshot path must live under .pipeline/<issue>/, which is
#   gitignored. A path that escapes that tree is a committable-PII vector.
#
# Hermeticity: CLAUDE_PROJECT_DIR and cwd both point at a temp project root, so the gate
# resolves .pipeline/<issue>/ inside the temp tree and never reads this checkout's own.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

GATE="$SCRIPTS_DIR/gate-pre-phase4-frontend.mjs"
ISSUE=4242

make_temp_project "$ISSUE" || exit 90

# gate <args...> -> sets RC, OUT (stdout), ERR (stderr)
gate() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$GATE" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

# write_evidence <json> -> path to a standalone evidence file
write_evidence() {
  printf '%s' "$1" > "$TEMP_PROJECT/evidence.json"
  printf '%s' "$TEMP_PROJECT/evidence.json"
}

# shot_evidence <screenshot-path> -> evidence that is complete EXCEPT for the path under test,
# so any failure is attributable to containment and not to missing evidence.
shot_evidence() {
  write_evidence "{\"verdict\":\"APPROVE\",\"lint_pass\":true,\"a11y_pass\":true,\"screenshots\":[\"$1\"]}"
}

FRONTEND_PATH="app/components/Button.tsx"
BACKEND_PATH="scripts/tool.mjs"

suite "frontend gate: fail direction (the trigger, not the evidence)"

gate --issue "$ISSUE" --changed "$BACKEND_PATH"
assert_eq "no frontend path in the diff exits 0" "$RC" "0"
assert_contains "no frontend path prints an explicit SKIP" "$OUT" "SKIP: no frontend surface in the diff"

# The skip must survive a TOTAL absence of evidence (this issue dir holds no design shard and
# no impl-report at all): absence of the trigger is never read as missing evidence. That
# inversion is what turns a self-skipping gate into one that blocks every backend PR.
assert_eq "the skip path reports no failure at all" "$ERR" ""

gate --issue "$ISSUE" --changed "$FRONTEND_PATH"
assert_eq "a frontend diff with no evidence halts" "$RC" "1"
assert_contains "the halt names the missing verdict" "$ERR" "no design_review verdict recorded"
assert_contains "the halt names the missing lint pass" "$ERR" "lint_pass !== true"
assert_contains "the halt names the missing a11y pass" "$ERR" "a11y_pass !== true"

EV=$(write_evidence '{"verdict":"APPROVE","lint_pass":true,"a11y_pass":true}')
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "verdict + lint_pass + a11y_pass exits 0" "$RC" "0"
assert_contains "a passing gate says so" "$OUT" "OK: frontend visual-verification gate passed."

# Each fact is individually required: a partial record must not pass.
EV=$(write_evidence '{"verdict":"APPROVE","lint_pass":true}')
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a missing a11y pass alone still halts" "$RC" "1"
assert_contains "and names only the missing fact" "$ERR" "a11y_pass !== true"

EV=$(write_evidence '{"lint_pass":true,"a11y_pass":true}')
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a missing design verdict alone still halts" "$RC" "1"
assert_contains "and names the missing verdict" "$ERR" "no design_review verdict recorded"

suite "frontend gate: legacy evidence aliases"

EV=$(write_evidence '{"verdict":"APPROVE","token_lint":"pass","axe":{"status":"pass"}}')
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "legacy token_lint/axe aliases are accepted" "$RC" "0"

EV=$(write_evidence '{"verdict":"APPROVE","token_lint_pass":true,"axe_pass":true}')
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "legacy *_pass booleans are accepted" "$RC" "0"

EV=$(write_evidence '{"verdict":"APPROVE","lint":"pass","a11y":{"status":"pass"}}')
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "generic lint/a11y object forms are accepted" "$RC" "0"

suite "frontend gate: evidence resolution and I/O halts"

gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$TEMP_PROJECT/does-not-exist.json"
assert_eq "an explicitly named evidence file that is missing halts" "$RC" "1"
assert_contains "the halt names the missing evidence" "$ERR" "not found"

printf '%s' '{"verdict": }' > "$TEMP_PROJECT/bad.json"
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$TEMP_PROJECT/bad.json"
assert_eq "an unparseable evidence file halts" "$RC" "1"
assert_contains "the halt says the evidence is not valid JSON" "$ERR" "not valid JSON"

# The impl-report design_gate fallback (Dev's Phase-3 visual-build loop) is the last resort in
# the resolution chain; a gate that ignored it would halt on legitimately recorded evidence.
# Each resolution case gets its OWN issue dir so no case has to delete another's fixture.
mkdir -p "$TEMP_PROJECT/.pipeline/4243"
cat > "$TEMP_PROJECT/.pipeline/4243/impl-report.json" <<'EOF'
{"design_gate":{"verdict":"APPROVE","lint_pass":true,"a11y_pass":true}}
EOF
gate --issue 4243 --changed "$FRONTEND_PATH"
assert_eq "impl-report design_gate is accepted as evidence" "$RC" "0"

# The Phase 4 Design shard outranks the impl-report fallback: here the shard passes while the
# sibling impl-report records nothing, so a gate reading the wrong source would halt.
mkdir -p "$TEMP_PROJECT/.pipeline/4244"
cat > "$TEMP_PROJECT/.pipeline/4244/peer-review.design_review.json" <<'EOF'
{"verdict":"APPROVE","lint_pass":true,"a11y_pass":true}
EOF
printf '%s' '{"design_gate":{"verdict":"APPROVE"}}' > "$TEMP_PROJECT/.pipeline/4244/impl-report.json"
gate --issue 4244 --changed "$FRONTEND_PATH"
assert_eq "the peer-review Design shard outranks the impl-report fallback" "$RC" "0"

# ...and the Phase 2 review shard is used when no panel shard exists yet.
mkdir -p "$TEMP_PROJECT/.pipeline/4245"
cat > "$TEMP_PROJECT/.pipeline/4245/review.design_review.json" <<'EOF'
{"verdict":"APPROVE","lint_pass":true,"a11y_pass":true}
EOF
gate --issue 4245 --changed "$FRONTEND_PATH"
assert_eq "the Phase 2 review Design shard is accepted as evidence" "$RC" "0"

suite "frontend gate: an undeterminable change list HALTS, never skips"

# THE fail-open this section exists for: with no --changed paths the impl-report is the only
# source for what the diff touched, and an ABSENT one used to leave the list empty, so
# diffTouchesFrontend([]) was false and the gate printed SKIP and exited 0. A control designed to
# halt no-opped into a pass in exactly the state where design evidence is most likely absent.
# "I could not determine what changed" is a different state from "nothing frontend changed", and
# only the second may pass. Reproduced against a real run by SecOps.
gate --issue 4250
assert_eq "an --issue whose dir holds no impl-report halts" "$RC" "1"
assert_contains "the halt names the missing report" "$ERR" "not found"
assert_not_contains "and it does NOT report the legitimate skip" "$OUT" "SKIP"

gate --impl-report "$TEMP_PROJECT/nowhere/impl-report.json"
assert_eq "an --impl-report path with no file there halts" "$RC" "1"
assert_not_contains "and it does NOT report the legitimate skip" "$OUT" "SKIP"

printf '%s' '{ not json' > "$TEMP_PROJECT/impl-unparseable.json"
gate --impl-report "$TEMP_PROJECT/impl-unparseable.json"
assert_eq "an unparseable impl-report halts" "$RC" "1"
assert_contains "the halt says the report is not valid JSON" "$ERR" "not valid JSON"

# A report that PARSES but records no file list anywhere is the same defect one layer in:
# files_changed is optional per commit, so deriving [] from it and skipping would be the same
# no-op reached by a different route.
printf '%s' '{"commits":[{"sha":"a","message":"m"}]}' > "$TEMP_PROJECT/impl-fileless.json"
gate --impl-report "$TEMP_PROJECT/impl-fileless.json"
assert_eq "an impl-report recording no file list halts" "$RC" "1"
assert_contains "the halt says the change list is undeterminable" "$ERR" "cannot determine"
assert_not_contains "and it does NOT report the legitimate skip" "$OUT" "SKIP"

gate
assert_eq "no --changed and nothing to resolve a report from halts" "$RC" "1"
assert_contains "the halt says so plainly" "$ERR" "cannot determine the changed-path list"

# CONTROLS. The halts above must not have been bought by making the gate refuse everything:
# a CONCLUSIVE change list with no frontend surface still skips, and a real frontend diff with
# real evidence still passes. If either of these goes red the gate is stuck closed and blocks
# every backend PR, which is the failure mode on the other side of this fix.
mkdir -p "$TEMP_PROJECT/.pipeline/4251"
cat > "$TEMP_PROJECT/.pipeline/4251/impl-report.json" <<'EOF'
{"commits":[{"sha":"a","message":"m","files_changed":["scripts/tool.mjs"]}]}
EOF
gate --issue 4251
assert_eq "a conclusive backend-only report still skips" "$RC" "0"
assert_contains "and says why it skipped" "$OUT" "SKIP: no frontend surface in the diff"

mkdir -p "$TEMP_PROJECT/.pipeline/4252"
cat > "$TEMP_PROJECT/.pipeline/4252/impl-report.json" <<'EOF'
{"commits":[{"sha":"a","message":"m","files_changed":["app/components/Button.tsx"]}],
 "design_gate":{"verdict":"APPROVE","lint_pass":true,"a11y_pass":true}}
EOF
gate --issue 4252
assert_eq "a conclusive frontend report with full evidence still passes" "$RC" "0"
assert_contains "and says the gate passed" "$OUT" "OK: frontend visual-verification gate passed."

# A delete-only diff stays CONCLUSIVE (files_removed is a recorded file list) and the deletion
# exemption still empties the changed set, so it skips rather than halting. This is the case a
# naive "empty derived list means undeterminable" rule would false-halt.
mkdir -p "$TEMP_PROJECT/.pipeline/4253"
cat > "$TEMP_PROJECT/.pipeline/4253/impl-report.json" <<'EOF'
{"commits":[{"sha":"a","message":"m","files_changed":["app/components/Gone.tsx"],
             "files_removed":["app/components/Gone.tsx"]}]}
EOF
gate --issue 4253
assert_eq "a delete-only frontend diff is conclusive and skips" "$RC" "0"

suite "frontend gate: screenshot containment (AC18)"

# A legitimate screenshot inside the gitignored issue tree passes. This is the control that
# keeps the containment rule from being satisfied by refusing everything.
EV=$(shot_evidence ".pipeline/$ISSUE/home.png")
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a screenshot inside .pipeline/<issue>/ passes" "$RC" "0"

# Regression controls: these two were already refused before the containment fix, so they pin
# that the fix did not change the paths that already worked.
EV=$(shot_evidence "assets/leak.png")
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a plain outside path is refused" "$RC" "1"
assert_contains "the refusal names the offending path" "$ERR" "assets/leak.png"

EV=$(shot_evidence "/etc/passwd.png")
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "an absolute path is refused" "$RC" "1"
assert_contains "the absolute-path refusal names the path" "$ERR" "/etc/passwd.png"

EV=$(shot_evidence "$(printf '.pipeline/../../../../etc/passwd.png')")
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a traversal out of .pipeline/ is refused" "$RC" "1"
assert_contains "the traversal refusal names the offending path" "$ERR" "../../../../etc/passwd.png"

# A `..` segment is refused even when it happens to resolve back inside the issue tree. The
# rule is deterministic and string-only on purpose: the gate must not stat the filesystem,
# because it routinely runs outside the implementation worktree where the file does not exist.
EV=$(shot_evidence ".pipeline/$ISSUE/../$ISSUE/home.png")
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a .. segment that resolves back inside is still refused" "$RC" "1"

# Backslash normalization happens BEFORE the containment check, so a Windows-style traversal
# cannot slip past a check that only understands forward slashes.
EV=$(write_evidence '{"verdict":"APPROVE","lint_pass":true,"a11y_pass":true,"screenshots":[".pipeline\\..\\..\\x.png"]}')
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a backslash traversal is refused" "$RC" "1"

# The discriminator between a `..` SEGMENT check and a naive `..` SUBSTRING check. A substring
# check would refuse this legitimate filename and false-HALT the panel; only the segment rule
# accepts it. Every other case in this section behaves identically under both implementations.
EV=$(shot_evidence ".pipeline/$ISSUE/shot..png")
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a filename containing .. (not a segment) still passes" "$RC" "0"

EV=$(shot_evidence ".pipeline/$ISSUE/..hidden/s.png")
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a dir name beginning with .. (not a segment) still passes" "$RC" "0"

# A non-string entry is refused rather than coerced: a number or object here means the shard
# was written wrong, and coercion would let a non-path through the containment check.
EV=$(write_evidence '{"verdict":"APPROVE","lint_pass":true,"a11y_pass":true,"screenshots":[42]}')
gate --issue "$ISSUE" --changed "$FRONTEND_PATH" --evidence "$EV"
assert_eq "a non-string screenshot entry is refused" "$RC" "1"
assert_contains "the non-string refusal says so" "$ERR" "not a string path"

finish
