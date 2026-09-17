#!/usr/bin/env bash
# What a status.json record MEANS about whether a run is live. Two defects, opposite ends of the
# same question, fixed together because fixing one leaves the class open.
#
#   #110  a record can re-enter a GUARDED phase carrying the PREVIOUS round's `final_verdict`, so
#         "has a final_verdict" stops meaning "concluded" and starts meaning "concluded at some
#         point in its history". Every control that reads the field as a conclusion is blind for
#         the whole remediation window.
#   #74   the in-flight window is spelled in more than one place, and one spelling reads the FILE
#         MTIME where the guard reads `updated_at`. That is a grain mismatch, not a second copy of
#         a number, and a fresh clone makes the two disagree on almost every record.
#
# WHAT THIS SUITE READS. The corpus cells below scan the WORKING TREE only -- the checked-out
# `.pipeline/*/status.json` and `knowledge/issue-archive/*.json`. Committed HISTORY is deliberately
# out of scope and is NOT migrated: those blobs are the audit trail of what the orchestrator
# actually wrote, and blob d83bfc0 of .pipeline/19/status.json is the evidence that reproduced
# #110 in the first place. Nothing in this tree reads a historical blob under the new convention.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The orchestrator prose is a core plus per-phase files; pins read all of it (harness.sh).
pipeline_md_concat "$PLUGIN_ROOT" || exit 90
PIPELINE_MD="$PIPELINE_MD_CONCAT"
PHASE_MD="$PLUGIN_ROOT/commands/phase.md"
GUARD="$SCRIPTS_DIR/gate-phase-entry.mjs"

make_temp_project || exit 90

# scan_stale_verdict <root> <scope: pipeline|archive> -> "<count> :: <named hits>"
#
# "Concluded" is the phase set that legitimately co-occurs with a verdict: `4-review-complete`, any
# `5-*`, or a non-empty `completed_at`. Anything else carrying a verdict is the #110 shape.
#
# THE TWO SCOPES ARE SEPARATE BECAUSE THEIR OWNERS ARE. `.pipeline/*/status.json` is what
# commands/pipeline.md writes, which is what this change fixes, so its count must be zero and stay
# zero. `knowledge/issue-archive/*.json` is the knowledge store, which only the Librarian may
# write; a fix cannot reach in there, so that count is PINNED to the population that exists rather
# than asserted to zero. Pinned, not excluded: a NEW archived record in this state reddens.
scan_stale_verdict() {
  node -e '
    const fs = require("node:fs"), path = require("node:path");
    const root = process.argv[1], scope = process.argv[2];
    const files = [];
    if (scope === "pipeline") {
      const walk = (d) => {
        let ents = [];
        try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
        for (const e of ents) {
          const p = path.join(d, e.name);
          if (e.isDirectory()) walk(p);
          else if (e.name === "status.json") files.push(p);
        }
      };
      walk(path.join(root, ".pipeline"));
    } else {
      const ka = path.join(root, "knowledge", "issue-archive");
      try { for (const f of fs.readdirSync(ka)) if (f.endsWith(".json")) files.push(path.join(ka, f)); } catch {}
    }
    let hits = 0;
    const named = [];
    for (const f of files) {
      let r;
      try { r = JSON.parse(fs.readFileSync(f, "utf8")); } catch { continue; }
      const st = scope === "archive" ? (r.status ?? r.final_status ?? r) : r;
      if (!st || typeof st !== "object" || !st.final_verdict) continue;
      const ph = String(st.current_phase ?? "");
      const concluded = ph === "4-review-complete" || ph.startsWith("5-") || Boolean(st.completed_at);
      if (!concluded) { hits++; named.push(path.relative(root, f) + " @ " + ph + " / " + st.final_verdict); }
    }
    named.sort();
    process.stdout.write(hits + (named.length ? " :: " + named.join("; ") : ""));
  ' "$1" "$2"
}

# ================================================================================================
suite "#110: no checked-out .pipeline record carries a verdict at a non-concluded phase"
# ================================================================================================

SCAN="$(scan_stale_verdict "$REPO_ROOT" pipeline)"
record ".pipeline working-tree scan: $SCAN"
assert_eq "ZERO checked-out .pipeline records are in the #110 state (final_verdict attached at a phase that is not a conclusion)" \
  "${SCAN%% *}" "0"

# THE ARCHIVE POPULATION, PINNED RATHER THAN EXCLUDED. knowledge/issue-archive/43.json is a run
# ARCHIVED at `current_phase: "3-impl"` with `final_verdict: "REQUEST_CHANGES"` and
# `review_rounds: 4` -- a second, independent reproduction of #110, found by this scanner and not
# by reading the code, and the one that proved the fix had to sit at the LOOPBACK and not only at
# the `4-review` re-entry: that record never reached a `4-review` re-entry. It is left as
# HISTORICAL. It records what the orchestrator wrote, the knowledge store is the Librarian's to
# write, and rewriting it would delete the evidence. The count is pinned so a NEW one reddens.
ASCAN="$(scan_stale_verdict "$REPO_ROOT" archive)"
record "knowledge/issue-archive scan: $ASCAN"
assert_eq "the archive's stale-verdict population is EXACTLY the one known historical record. If this reddens with a HIGHER count a run archived in the stale state after the fix landed, which means the loopback clearing rule is not being followed; if it reddens with a LOWER count the Librarian corrected 43.json and this pin should be retired, not re-pointed" \
  "$ASCAN" "1 :: knowledge/issue-archive/43.json @ 3-impl / REQUEST_CHANGES"

# NON-ZERO CONTROL. A zero from a scanner that cannot find anything is not a result. Plant exactly
# the historical shape -- .pipeline/19 as of blob d83bfc0 -- and require the SAME scanner to see it.
mkdir -p "$TEMP_PROJECT/planted/.pipeline/19"
cat > "$TEMP_PROJECT/planted/.pipeline/19/status.json" <<'JSON'
{
  "issue_number": 19,
  "current_phase": "4-review",
  "updated_at": "2026-08-23T01:00:19Z",
  "final_verdict": "REQUEST_CHANGES",
  "review_rounds": 2,
  "peer_review_verdict_counts": {"approve": 0, "approve_with_notes": 4, "request_changes": 2, "request_refactor": 0, "veto": 0},
  "events": []
}
JSON
PLANTED="$(scan_stale_verdict "$TEMP_PROJECT/planted" pipeline)"
record "planted-corpus scan: $PLANTED"
assert_eq "NON-ZERO CONTROL: the same scanner finds the real historical shape when it is present" \
  "${PLANTED%% *}" "1"
assert_contains "and names it, so a future hit is diagnosable without re-deriving the scan" \
  "$PLANTED" ".pipeline/19/status.json @ 4-review / REQUEST_CHANGES"

# DISCRIMINATION, not merely firing: the scanner must NOT flag the same verdict at a phase that IS
# a conclusion. Without this, a scanner that flags every final_verdict passes the cell above.
mkdir -p "$TEMP_PROJECT/planted-ok/.pipeline/19"
cat > "$TEMP_PROJECT/planted-ok/.pipeline/19/status.json" <<'JSON'
{"current_phase": "4-review-complete", "updated_at": "2026-08-23T01:00:19Z", "final_verdict": "REQUEST_CHANGES", "events": []}
JSON
assert_eq "DISCRIMINATION: the identical verdict at 4-review-complete is NOT a hit" \
  "$(scan_stale_verdict "$TEMP_PROJECT/planted-ok" pipeline)" "0"

# ...and the LOOPBACK shape specifically, which is archive 43's and which the issue's own stated
# fix (clear on re-entry to `4-review`) would not have caught. Pinned as its own cell so a
# narrowing of the rule back to `4-review` alone reddens here rather than passing.
mkdir -p "$TEMP_PROJECT/planted-loopback/.pipeline/43"
cat > "$TEMP_PROJECT/planted-loopback/.pipeline/43/status.json" <<'JSON'
{"current_phase": "3-impl", "updated_at": "2026-08-21T01:06:34Z", "final_verdict": "REQUEST_CHANGES", "review_rounds": 4, "events": []}
JSON
assert_contains "the LOOPBACK shape (a fix round at 3-impl still carrying the verdict) is a hit too -- 3-impl is a GUARDED phase, and gate-phase-entry.mjs:697 measures that a final_verdict there takes the guard rc 2 to rc 0 for the rest of the run" \
  "$(scan_stale_verdict "$TEMP_PROJECT/planted-loopback" pipeline)" "1 :: .pipeline/43/status.json @ 3-impl / REQUEST_CHANGES"

# ================================================================================================
suite "#110: the write that keeps it zero is a command, and the command clears"
# ================================================================================================
#
# The cell above is a fact about today's tree. It stays true only because every write that enters
# a remediation window clears the field. Since #164 that write is scripts/checkpoint.mjs, so the
# clear is RUN here, on both clearing points, and the prose is pinned to call the command at the
# two places the orchestrator makes those writes (and the manual /phase path).
CKPT="$SCRIPTS_DIR/checkpoint.mjs"
CL_DIR="$TEMP_PROJECT/clear110/.pipeline/43"; mkdir -p "$CL_DIR"
cl_status() { printf '{"current_phase":"%s","started_at":"2026-08-21T00:00:00Z","updated_at":"2026-08-21T01:06:34Z","branch":"b","final_verdict":"REQUEST_CHANGES","peer_review_verdict_counts":{"approve":1},"review_rounds":4,"events":[]}' "$1" > "$CL_DIR/status.json"; }
cl_field() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(s[process.argv[2]]))' "$CL_DIR/status.json" "$1"; }
cl_status 3-impl-complete
( cd "$TEMP_PROJECT" && node "$CKPT" enter 4-review --status "$CL_DIR/status.json" ) >/dev/null 2>&1
assert_eq "the 4-review re-entry write clears final_verdict and peer_review_verdict_counts in the SAME write" \
  "$(cl_field final_verdict)/$(cl_field peer_review_verdict_counts)/$(cl_field current_phase)" 'null/null/"4-review"'
cl_status 4-review-complete
( cd "$TEMP_PROJECT" && node "$CKPT" enter 3-impl --loopback --status "$CL_DIR/status.json" ) >/dev/null 2>&1
assert_eq "the LOOPBACK write (archive 43's shape: a fix round at 3-impl) clears them too, the earlier and broader point" \
  "$(cl_field final_verdict)/$(cl_field peer_review_verdict_counts)/$(cl_field current_phase)" 'null/null/"3-impl"'
cl_status 4-review-complete
( cd "$TEMP_PROJECT" && node "$CKPT" enter 3-impl --status "$CL_DIR/status.json" ) >/dev/null 2>&1
assert_eq "CONTROL: a 3-impl entry that is NOT a loop-back (and not 4-review) leaves the verdict, so the clear is keyed, not blanket" \
  "$(cl_field final_verdict)" '"REQUEST_CHANGES"'

CHECKPOINT_LINE="$(grep -n 'Checkpoint first.*current_phase: "4-review"' "$PIPELINE_MD" | head -1 | cut -d: -f1)"
assert_eq "the Phase 4 checkpoint line is still present" \
  "$([[ -n "$CHECKPOINT_LINE" ]] && echo present || echo ABSENT)" "present"
assert_contains "and it is the checkpoint.mjs enter 4-review call" \
  "$(sed -n "${CHECKPOINT_LINE:-1}p" "$PIPELINE_MD")" "checkpoint.mjs enter 4-review"
DELTA_LINE="$(grep -n 'Delta re-run' "$PHASE_MD" | head -1 | cut -d: -f1)"
assert_contains "the MANUAL delta re-run enters the round through the same command, so it cannot reintroduce the state" \
  "$(sed -n "${DELTA_LINE:-1}p" "$PHASE_MD")" 'checkpoint.mjs" enter 4-review'
assert_contains "and the verdict step loops back through --loopback" "$(cat "$PIPELINE_MD")" "checkpoint.mjs enter 3-impl --loopback"
assert_not_contains "the hand-applied clearing paragraph is gone from the rubric" "$(cat "$PIPELINE_MD")" "Rows 2 and 3 loop back for remediation, and the write that DOES the looping back"

# ================================================================================================
suite "#110: the 4-review-complete row is unreachable, and that is stated rather than implied"
# ================================================================================================
#
# gate-phase-entry.mjs's PREREQUISITES table has a "4-review-complete" row. The guard only ever
# evaluates a record `inFlight` admits, which requires NO final_verdict -- and pipeline.md writes
# that phase literal in the SAME update as `final_verdict`. So the row cannot fire. Measured over
# the committed corpus rather than reasoned: all 7 records ever committed at that phase carry a
# verdict, 0 do not. The row is KEPT (it is the exit half of an entry/exit pair the GUARDED
# derivation reads) and the deadness is documented at the row.
assert_contains "the guard still carries the 4-review-complete row" \
  "$(grep -c '"4-review-complete": { file: "peer-review.json"' "$GUARD" | tr -d ' ')" "1"
ROW_LINE="$(grep -n '"4-review-complete": { file: "peer-review.json"' "$GUARD" | head -1 | cut -d: -f1)"
assert_contains "and the 16 lines above it say it is unreachable, so a reader of the table is not left believing this phase is guarded" \
  "$(sed -n "$(( ${ROW_LINE:-17} - 16 )),${ROW_LINE:-1}p" "$GUARD")" "UNREACHABLE"

# THE PREMISE OF THAT DEADNESS, RUN. record-verdict.mjs writes current_phase 4-review-complete and
# final_verdict in ONE write. If this fails, the writes were split, the guard's 4-review-complete
# row is now REACHABLE, and the 'structurally unreachable' comment above it must be rewritten --
# this cell is not asking you to put it back.
PV_DIR="$TEMP_PROJECT/postverdict/.pipeline/7"; mkdir -p "$PV_DIR"
printf '{"current_phase":"4-review","started_at":"x","updated_at":"x","branch":"b","panel_roles":["qa"],"events":[]}' > "$PV_DIR/status.json"
printf '{"qa":{"verdict":"APPROVE"}}' > "$PV_DIR/peer-review.json"
( cd "$TEMP_PROJECT" && node "$SCRIPTS_DIR/record-verdict.mjs" --status "$PV_DIR/status.json" --peer-review "$PV_DIR/peer-review.json" ) >/dev/null 2>&1
assert_eq "PREMISE: record-verdict.mjs writes current_phase 4-review-complete and final_verdict in ONE update. If this fails, the writes were split, the guard's 4-review-complete row is now REACHABLE, and the 'structurally unreachable' comment above it must be rewritten -- this cell is not asking you to put it back" \
  "$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(s.current_phase+"/"+s.final_verdict)' "$PV_DIR/status.json")" "4-review-complete/APPROVE"
assert_contains "and the prose writes that phase through it" "$(cat "$PIPELINE_MD")" 'current_phase: "4-review-complete"'

# ================================================================================================
suite "#74 s2: the session-start notice dates a run by updated_at, not by the file's mtime"
# ================================================================================================
#
# MEASURED, in a fresh `git clone --no-hardlinks` pinned at 856a5d0: all 6 notice-eligible records
# had mtime age 0.00h (checkout time) while their `updated_at` ages spanned 9.99h to 341.49h, so
# the notice fired on 6 and the phase-entry guard called 5 of those 6 not in flight -- 83%
# disagreement, all of it in the CLAIM-MORE direction. A clone rewrites every mtime, so mtime is a
# property of the CHECKOUT; `updated_at` is the run's own claim about itself.
#
# The notice only runs when the guard is DISARMED, so the fixture is a hooks/ directory with no
# ../scripts/ sibling -- which is one of the two real disarm causes, not a stand-in for it.
new_tmpdir || exit 90
FAKE_PLUGIN="$NEW_TMPDIR/plugin"
mkdir -p "$FAKE_PLUGIN/hooks"
cp "$HOOKS_DIR/session-start.sh" "$FAKE_PLUGIN/hooks/"
cp "$HOOKS_DIR/lib.sh" "$FAKE_PLUGIN/hooks/"
FAKE_HOOK="$FAKE_PLUGIN/hooks/session-start.sh"

NOTICE_TEXT="NOTICE: a pipeline run is in flight"

# notice_for <issue> <status-json> [<mtime-stamp>] -> hook stdout
notice_for() {
  local issue="$1" json="$2" stamp="${3:-}"
  NREPO=$(make_repo)
  mkdir -p "$NREPO/.pipeline/$issue"
  printf '%s' "$json" > "$NREPO/.pipeline/$issue/status.json"
  [[ -n "$stamp" ]] && touch -t "$stamp" "$NREPO/.pipeline/$issue/status.json"
  CLAUDE_PROJECT_DIR="$NREPO" CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" bash "$FAKE_HOOK" 2>/dev/null
}

# Sanity: the fixture really does disarm the guard. Without this the cells below could all be
# measuring "the block never ran", which looks exactly like "the block ran and stayed silent".
assert_eq "FIXTURE PRECONDITION: the fake plugin root has no scripts/gate-phase-entry.mjs, so the notice block is actually entered" \
  "$([[ -f "$FAKE_PLUGIN/scripts/gate-phase-entry.mjs" ]] && echo "PRESENT -- the notice block is skipped and every cell below is vacuous" || echo absent)" \
  "absent"

FRESH_ISO=$(node -e 'console.log(new Date(Date.now() - 2*3600*1000).toISOString().replace(/\.\d+Z$/, "Z"))')
STALE_ISO=$(node -e 'console.log(new Date(Date.now() - 72*3600*1000).toISOString().replace(/\.\d+Z$/, "Z"))')

# THE FRESH-CLONE SHAPE, and the regression this fix is about: stale by its own claim, brand-new
# file mtime. The old predicate fired here; the guard would have abstained.
OUT="$(notice_for 901 "{\"current_phase\":\"3-impl\",\"updated_at\":\"$STALE_ISO\"}")"
assert_not_contains "a record 72h stale by updated_at is SILENT even though its file mtime is seconds old (the fresh-clone shape: 5 of 6 records in the measured clone)" \
  "$OUT" "$NOTICE_TEXT"

# NON-ZERO CONTROL, the other direction: the notice must still be able to fire.
OUT="$(notice_for 902 "{\"current_phase\":\"3-impl\",\"updated_at\":\"$FRESH_ISO\"}")"
assert_contains "NON-ZERO CONTROL: a record 2h old by updated_at DOES fire the notice" \
  "$OUT" "$NOTICE_TEXT"

# WHAT THE NEW PREDICATE NEWLY SURFACES, asserted rather than claimed in a comment: a record whose
# file is ancient but whose own claim is recent. `find -mtime -1` missed this; the guard does not,
# because it reads the same column.
OUT="$(notice_for 903 "{\"current_phase\":\"3-impl\",\"updated_at\":\"$FRESH_ISO\"}" "202001010000.00")"
assert_contains "NEWLY SURFACED: a recent updated_at fires the notice even when the FILE mtime is years old, which the mtime test missed" \
  "$OUT" "$NOTICE_TEXT"

# THE DEGRADED PATH IS THE OLD PATH. A record whose updated_at is absent or is not the UTC-Z shape
# the string compare is exact for falls back to the mtime approximation rather than to silence:
# this is a warning about a disarmed safety control, so a superset beats a subset.
OUT="$(notice_for 904 '{"current_phase":"3-impl"}')"
assert_contains "FALLBACK: a record with NO updated_at still fires on the mtime approximation (a fresh file), so the disarm is never announced less than it used to be" \
  "$OUT" "$NOTICE_TEXT"
OUT="$(notice_for 905 '{"current_phase":"3-impl","updated_at":"not-a-date"}' "202001010000.00")"
assert_not_contains "FALLBACK DISCRIMINATES: an unparseable updated_at with an ANCIENT file mtime stays silent, so the fallback is the mtime test and not an unconditional fire" \
  "$OUT" "$NOTICE_TEXT"

# The existing exclusions still hold on the new path. A concluded or phase-5 record must not fire
# however fresh its claim is -- these are the filters the notice shares with the guard.
OUT="$(notice_for 906 "{\"current_phase\":\"3-impl\",\"updated_at\":\"$FRESH_ISO\",\"final_verdict\":\"APPROVE\"}")"
assert_not_contains "a fresh record carrying a final_verdict is still excluded" "$OUT" "$NOTICE_TEXT"
OUT="$(notice_for 907 "{\"current_phase\":\"5-archived\",\"updated_at\":\"$FRESH_ISO\"}")"
assert_not_contains "a fresh record at a phase-5 label is still excluded" "$OUT" "$NOTICE_TEXT"

# ENVIRONMENT FINGERPRINT, ASSERTED not printed. This suite's predicate depends on `date` producing
# a cutoff, and the two dialects are tried in order (BSD first: BSD's -d means "set DST", so the GNU
# spelling would MISPARSE rather than fail on macOS). If neither works the hook degrades to mtime
# and every updated_at cell above would be measuring the fallback instead of the fix.
CUTOFF_PROBE="$(date -u -v-1d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)"
record "cutoff probe on this runner: ${CUTOFF_PROBE:-<neither date dialect produced one>}"
assert_eq "PROBE: this runner's date produces a 24h cutoff, so the cells above exercised the updated_at path and not the mtime fallback" \
  "$([[ "$CUTOFF_PROBE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] && echo produced || echo "NOT PRODUCED: ${CUTOFF_PROBE:-empty}")" \
  "produced"

finish
