#!/usr/bin/env bash
# voice-lint.mjs — the first thing in this plugin that actually READS voice.md's rules.
#
# Two layers, same split as the validator's suite:
#   (1) The script's own --self-test, WIRED IN rather than re-implemented. It covers the pure
#       lint over text + moment.
#   (2) The PROCESS contract the self-test cannot reach: the stdin payload, the transcript
#       walk, the phase-derived trigger, and the fail-open guarantees.
#
# The property that matters most here is the one that decides whether this control survives
# contact with real use: it must be SILENT on every stop that is not a pipeline voice moment.
# voice.md bans em dashes "anywhere, ever"; a lint enforcing that on ordinary conversation gets
# disabled within a day, and a disabled control is a no-op with extra steps. Several cases
# below exist only to prove the silence.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

LINT="$SCRIPTS_DIR/voice-lint.mjs"
ISSUE=4244

make_temp_project "$ISSUE" || exit 90

TRANSCRIPT="$TEMP_PROJECT/transcript.jsonl"

# write_transcript <text> — one assistant turn carrying <text>
write_transcript() {
  node -e '
    const fs=require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      type:"assistant", message:{content:[{type:"text", text:process.argv[2]}]}
    })+"\n");
  ' "$TRANSCRIPT" "$1"
}

set_phase() { printf '{"current_phase":"%s"}' "$1" > "$TEMP_ISSUE_DIR/status.json"; }

# lint [extra-payload-json] -> RC, ERR
lint() {
  local extra="${1:-}"
  local payload="{\"cwd\":\"$TEMP_PROJECT\",\"transcript_path\":\"$TRANSCRIPT\"$extra}"
  local errf="$TEMP_PROJECT/err.txt"
  printf '%s' "$payload" \
    | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" \
        CLAUDE_PIPELINE_ACTIVE_ISSUE="$ISSUE" node "$LINT" ) 2>"$errf" >/dev/null
  RC=$?
  ERR=$(cat "$errf")
}

GOOD_DECISION='Here is the situation in plain language.

### I need a decision

**What I am asking:** pick one.'

# ---------------------------------------------------------------------------
suite "voice-lint: the pure lint (script self-test, wired in not copied)"

SELFTEST_OUT=$(node "$LINT" --self-test 2>&1)
SELFTEST_RC=$?
assert_eq "the bundled --self-test passes" "$SELFTEST_RC" "0"
assert_contains "and it actually ran its cases (22)" "$SELFTEST_OUT" "22 passed"

# ---------------------------------------------------------------------------
suite "voice-lint: silent everywhere it is not a voice moment"

# THE CASE THIS CONTROL LIVES OR DIES ON. An ordinary turn, mid-implementation, full of em
# dashes. If this ever blocks, the lint is unusable and will be turned off.
set_phase "3-impl"
write_transcript "Refactored the parser — it now handles the nested case — and tests pass."
lint
assert_eq "a NON-voice phase exits 0 even with em dashes" "$RC" "0"
assert_eq "a NON-voice phase says nothing" "$ERR" ""

set_phase "2-review"
write_transcript "Dispatched three reviewers."
lint
assert_eq "another non-voice phase is silent too" "$RC" "0"

rm -f "$TEMP_ISSUE_DIR/status.json"
write_transcript "No pipeline running here — just chatting."
lint
assert_eq "no status.json at all exits 0" "$RC" "0"
assert_eq "no status.json says nothing" "$ERR" ""

# ---------------------------------------------------------------------------
suite "voice-lint: it bites at a real voice moment"

set_phase "2.5-design-owner-decision"
write_transcript "I picked approach B because it is cleaner. Moving on to implementation."
lint
assert_eq "a decision moment with no decision block exits 2" "$RC" "2"
assert_contains "and names the phase" "$ERR" "2.5-design-owner-decision"
assert_contains "and names the missing block" "$ERR" "I need a decision"
assert_contains "and points at voice.md" "$ERR" "voice.md"
assert_contains "and offers the documented bypass" "$ERR" "CLAUDE_HOOK_STOP_SKIP=1"

# CONTROL: the same phase, with the block present, must pass. Without this the case above
# proves only that the lint blocks at this phase, not that it discriminates.
write_transcript "$GOOD_DECISION"
lint
assert_eq "CONTROL: the same moment WITH the block exits 0" "$RC" "0"
assert_eq "CONTROL: and says nothing" "$ERR" ""

write_transcript "$GOOD_DECISION — with an em dash"
lint
assert_eq "an em dash at a voice moment exits 2" "$RC" "2"
assert_contains "and quotes the rule" "$ERR" "em dash"

write_transcript "$GOOD_DECISION

As discussed, this is the same shape as before."
lint
assert_eq "a banned phrase at a voice moment exits 2" "$RC" "2"
assert_contains "and explains why it is banned" "$ERR" "assumes the owner was in the thread"

set_phase "1-ba-open-questions"
write_transcript "BA raised a question about scope. I went with the recommendation."
lint
assert_eq "the open-questions gate is a voice moment too" "$RC" "2"

set_phase "5-archived"
write_transcript "### Done

**Blast radius:** Contained
**Reversibility:** Undo button
**Confidence:** Solid"
lint
assert_eq "a completion report with no replication block exits 2" "$RC" "2"
assert_contains "and names the missing section" "$ERR" "See it yourself"

set_phase "5-archived"
write_transcript "### Done

### See it yourself

Open the page.

**Blast radius:** Contained
**Reversibility:** Undo button
**Confidence:** Solid"
lint
assert_eq "CONTROL: a complete report with scales + replication exits 0" "$RC" "0"

# ---------------------------------------------------------------------------
suite "voice-lint: fail-OPEN guarantees (a voice lint must never wedge a stop)"

set_phase "2.5-design-owner-decision"
write_transcript "no block here"

lint ',"stop_hook_active":true'
assert_eq "stop_hook_active short-circuits (no double-block loop)" "$RC" "0"

printf '%s' 'not json at all' \
  | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$LINT" ) 2>/dev/null >/dev/null
assert_eq "a garbled payload exits 0" "$?" "0"

printf '%s' '{}' \
  | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$LINT" ) 2>/dev/null >/dev/null
assert_eq "an empty payload exits 0" "$?" "0"

printf '{"cwd":"%s","transcript_path":"/nope/missing.jsonl"}' "$TEMP_PROJECT" \
  | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" \
      CLAUDE_PIPELINE_ACTIVE_ISSUE="$ISSUE" node "$LINT" ) 2>/dev/null >/dev/null
assert_eq "an unreadable transcript exits 0" "$?" "0"

printf 'garbage not jsonl\n{"type":"assistant"}\n' > "$TRANSCRIPT"
lint
assert_eq "an unparseable transcript exits 0" "$RC" "0"

# A well-formed but unlisted phase passes silently. That is the residual limit, and the drift
# suite below is what keeps it from mattering: a phase can only reach this state by existing in
# pipeline.md and being absent from BOTH tables, which the drift check fails on.
set_phase "3-invented-phase"
write_transcript "no block, em dashes — everywhere"
lint
assert_eq "RESIDUAL LIMIT: a well-formed unlisted phase is not linted" "$RC" "0"

# ---------------------------------------------------------------------------
suite "voice-lint: status.json current_phase shape (nothing else validates this file)"

# status.json is written by the ORCHESTRATOR, so SubagentStop never sees it; it is in no
# AGENT_RULES entry; and the schema walker does not implement `pattern`. Its one constraint has
# never been enforced anywhere. It matters here because a malformed phase matches no table entry
# and would make the voice check go SILENT instead of loud.
set_phase "Phase_Three"
write_transcript "anything at all"
lint
assert_eq "a malformed current_phase exits 2" "$RC" "2"
assert_contains "and quotes the offending value" "$ERR" "Phase_Three"
assert_contains "and names the schema it violates" "$ERR" "status.schema.json"
assert_contains "and says why silence would be the alternative" "$ERR" "silently disables"

# CONTROL: the shape check must accept every phase string the orchestrator legitimately writes,
# or it would block every run rather than the malformed ones. The message used here satisfies
# EVERY moment type at once (decision block, all three scales, replication block), so a non-zero
# result can only come from the phase shape and never from the voice rules. An earlier version
# of this loop compared $RC to $RC and could not fail; this one can.
ALL_SHAPES='### I need a decision

**What I am asking:** pick one.

### See it yourself

Open the page.

**Blast radius:** Contained
**Reversibility:** Undo button
**Confidence:** Solid'

for good in "3-impl" "2.5-design-owner-decision" "0.5-map" "halted-error" "5-archived" "4-review-complete"; do
  set_phase "$good"
  write_transcript "$ALL_SHAPES"
  lint
  assert_eq "CONTROL: '$good' passes the shape check" "$RC" "0"
done

# ---------------------------------------------------------------------------
suite "voice-lint: the table cannot drift from pipeline.md (config-derived)"
# ---------------------------------------------------------------------------
# The first VOICE_MOMENTS table was written from memory and invented FOUR phases no checkpoint
# writes, so those checks could never fire while the real completion report went uncovered.
# This derives the truth from pipeline.md rather than trusting the table, per evidence.md rule
# 19: build the expected set from CONFIGURATION, not from what has been observed.
#
# TWO THINGS CHANGED HERE, AND BOTH WERE DEFECTS RATHER THAN STYLE (#53).
#
#   1. THE POPULATION WAS NARROWER THAN ITS SUBJECT. The derivation matched `current_phase: "x"`
#      only, while pipeline.md ALSO writes the JSON form `"current_phase": "x"`. So this suite
#      derived 25 concrete literals from a file that writes 26, asserted that all 25 were
#      accounted for, and printed `found 26` as its reassurance -- assertion and control ranging
#      over the same narrowed set. `0-setup` was in neither voice table and in no partition cell
#      of the phase-entry guard, and nothing here could see it, because a phase the pattern
#      cannot see is not an unaccounted phase, it is not a phase at all.
#
#   2. THE ACCOUNTING WAS A SUBSTRING GREP OVER THE SOURCE. `grep -q "\"$phase\"" "$LINT_SRC"`
#      is satisfied by a phase named in a COMMENT and cannot tell a table key from a mention --
#      the exact shape the sibling drift suite's own header names as what it exists to replace.
#      It is now SET MEMBERSHIP over the module's exported tables, which is what makes the
#      negative cell below (declared in a comment, absent from the table -> RED) possible at all.
#
# THE WIDE FORM is the ONE extraction this suite performs; re-derive both copies with
# `git grep -n "THE WIDE FORM" -- plugins/pipeline/tests`.
PIPELINE_MD="$PLUGIN_ROOT/commands/pipeline.md"
LINT_SRC="$SCRIPTS_DIR/voice-lint.mjs"

# THE PINNED LABEL SET (#33). Identical to the drift suite's, on purpose: two copies of the wide
# pattern remain in Lane 1 and this is what makes them check each other -- a narrowing in either
# copy reddens in that copy. Never a bare count: a count is discharged by editing one digit.
PHASE_LITERALS_26='0-setup,0.5-map,0.5-map-complete,1-ba,1-ba-complete,1-ba-open-questions,1-ba-rework-required,2-constraints,2-constraints-complete,2-review,2-review-complete,2.5-design,2.5-design-complete,2.5-design-owner-decision,3-impl,3-impl-complete,3-impl-frontend-gate-failed,3-impl-gate-failed,3-impl-live-verify-unverified,3-impl-tripwire,3-impl-tripwire-indeterminate,4-review,4-review-complete,4-veto-rework-required,5-archive,5-archived'

# vl_account [phase-to-DROP-from-the-tables] -> a KEY=value report, or "" if the import produced
# nothing. The drop argument runs the IDENTICAL accounting over a deliberately holed table, which
# is what makes the negative cell a control rather than a claim.
#
# THE MODULE PATH IS argv[1], DELIBERATELY. That is the shipped import idiom in this repo (the
# drift suite passes the module it is importing as argv[1] at four call sites), and it is the
# ORDER that triggers the hazard: `isMain` compares the BASENAME of process.argv[1], so with the
# module path there the module SELF-RUNS its CLI on import, main() executes, and the eval body
# NEVER RUNS -- rc 0, no output, and every membership assertion below reads a green nothing.
# Reordering the arguments would hide that, and would leave the landmine armed for whoever next
# writes the idiom the natural way. gate-phase-entry.mjs already ships the fix; see the control
# immediately below the premise.
#
# `</dev/null` is not decoration: if the import self-runs the CLI, that CLI reads stdin.
vl_account() {
  node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const [lintPath, mdPath, drop] = process.argv.slice(1);
    const m = await import(lintPath);
    const vm = m.VOICE_MOMENTS, nv = m.NON_VOICE_PHASES;
    const kind = (v) => v === undefined ? "ABSENT"
      : v instanceof Set ? "Set" : Array.isArray(v) ? "Array" : typeof v;
    const nvList = nv instanceof Set ? [...nv] : Array.isArray(nv) ? [...nv] : [];
    const vmKeys = vm && typeof vm === "object" && !Array.isArray(vm) ? Object.keys(vm) : [];
    const declared = new Set([...nvList, ...vmKeys].filter((p) => p !== drop));
    const md = readFileSync(mdPath, "utf8");
    const literals = [...new Set([...md.matchAll(/"?current_phase"?: *"([^"]*)"/g)].map((x) => x[1]))]
      .filter((p) => p !== "<phase>-error");
    const out = [];
    out.push("VMKIND=" + kind(vm));
    out.push("NVKIND=" + kind(nv));
    out.push("VMKEYS=" + vmKeys.slice().sort().join(","));
    out.push("NVSIZE=" + nvList.length);
    // The drift suite consumes an exported cell through `Array.isArray(x) ? x : []`. Applied to
    // a Set that yields length 0 -- a green zero, not an error. Measured here against the REAL
    // exported value rather than asserted about an inline fixture.
    out.push("ARRAYIDIOMSIZE=" + (Array.isArray(nv) ? nv.length : 0));
    out.push("LITERALS=" + literals.slice().sort().join(","));
    out.push("UNACCOUNTED=" + literals.filter((p) => !declared.has(p)).sort().join(","));
    out.push("OVERLAP=" + vmKeys.filter((k) => nvList.includes(k)).sort().join(","));
    out.push("NV_HAS_0SETUP=" + (nvList.includes("0-setup") ? "yes" : "no"));
    out.push("VM_HAS_0SETUP=" + (vmKeys.includes("0-setup") ? "yes" : "no"));
    out.push("NV_HAS_3IMPL=" + (nvList.includes("3-impl") ? "yes" : "no"));
    out.push("VM_HAS_5ARCHIVED=" + (vmKeys.includes("5-archived") ? "yes" : "no"));
    process.stdout.write(out.join("\n"));
  ' "$LINT_SRC" "$PIPELINE_MD" "${1:-}" </dev/null 2>/dev/null
}

# vl <report> <KEY> -> the value, or an explicit marker. An absence assertion that cannot tell
# "nothing wrong" from "nothing measured" is not an assertion.
vl() {
  [[ -n "$1" ]] || { printf '<no-report>'; return; }
  case "$1" in *"$2="*) ;; *) printf '<no-field:%s>' "$2"; return ;; esac
  printf '%s' "$1" | sed -n "s/^$2=//p"
}

VL_RAW="$(vl_account)"
case "$VL_RAW" in
  VMKIND=*) VL_STATE="ok" ;;
  "")       VL_STATE="THE EVAL BODY NEVER RAN. Importing voice-lint.mjs SELF-RUNS its CLI (isMainScript compares the BASENAME of argv[1], and argv[1] here is the module path), so main() executes, the import never returns a value this program can read, and every membership assertion below would read a GREEN NOTHING. gate-phase-entry.mjs already ships the fix and a comment describing this exact hazard: an \`evalEntry\` test over process.execArgv, ANDed with isMain. voice-lint.mjs carries no such guard, and the exports are unusable without it" ;;
  *)        VL_STATE="the import returned something other than a report: $VL_RAW" ;;
esac

# --- THE PREMISE, asserted BEFORE anything is concluded from the tables ----------------------
assert_eq "PREMISE: voice-lint.mjs's tables can be IMPORTED without the module self-running its CLI" \
  "$VL_STATE" "ok"
assert_eq "  POSITIVE CONTROL on the idiom, so a red premise reads as \"voice-lint.mjs lacks the guard\" and not as \"this import style does not work\": the SIBLING module, which ships an \`evalEntry\` test beside its isMain check, returns its exports through the byte-identical call" \
  "$(node --input-type=module -e 'const m = await import(process.argv[1]); process.stdout.write(Array.isArray(m.ENTRY) && m.ENTRY.length > 0 ? "exports-readable" : "EMPTY")' "$SCRIPTS_DIR/gate-phase-entry.mjs" </dev/null 2>/dev/null)" \
  "exports-readable"
assert_eq "  and both tables read back in the SHAPE this suite consumes them in -- VOICE_MOMENTS an object, NON_VOICE_PHASES a Set. A renamed or ABSENT export is named here rather than producing an empty population three assertions later" \
  "$(vl "$VL_RAW" VMKIND)/$(vl "$VL_RAW" NVKIND)" "object/Set"
assert_eq "  ANTI-VACUITY, by LABEL and not by a count floor: both tables are non-empty, witnessed by a member each that this change does not touch" \
  "$(vl "$VL_RAW" NV_HAS_3IMPL)/$(vl "$VL_RAW" VM_HAS_5ARCHIVED)" "yes/yes"
assert_eq "  MEASURED CONTROL for the cell above: the drift suite's \`Array.isArray(x) ? x : []\` idiom, applied to the REAL exported Set, yields a population of size 0 while the Set itself is non-empty. That green zero is what the shape assertion exists to refuse" \
  "$(vl "$VL_RAW" ARRAYIDIOMSIZE)/$([[ "$(vl "$VL_RAW" NVSIZE)" == "0" ]] && echo EMPTY || echo non-empty)" "0/non-empty"

# --- the accounting itself -------------------------------------------------------------------
assert_eq "every phase pipeline.md writes is accounted for in voice-lint.mjs's own tables (SET MEMBERSHIP, never a source grep)" \
  "$(vl "$VL_RAW" UNACCOUNTED)" ""
assert_eq "\`0-setup\` is declared NON-VOICE and is in no voice-moment table" \
  "$(vl "$VL_RAW" NV_HAS_0SETUP)/$(vl "$VL_RAW" VM_HAS_0SETUP)" "yes/no"
assert_eq "and the two halves of the partition do not overlap -- the module's own self-test asserts this too, but that loop iterates VOICE_MOMENTS' keys and asks NON_VOICE_PHASES.has(k), so an EMPTY or renamed table satisfies it having checked nothing. Its non-emptiness premise is the cell above" \
  "$(vl "$VL_RAW" OVERLAP)" ""

# --- DISCRIMINATION, negative: a phase in a COMMENT is not a phase in a TABLE ----------------
# The old check was `grep -q "\"$phase\"" "$LINT_SRC"`, which a comment satisfies. This pair is
# what proves the replacement reads the TABLE: with `0-setup` dropped from the tables and the
# LITERAL STRING still present in the source, the accounting still reports it unaccounted.
VL_DROPPED="$(vl_account 0-setup)"
assert_contains "DISCRIMINATION: with \`0-setup\` removed from the tables, the accounting names it" \
  "$(vl "$VL_DROPPED" UNACCOUNTED)" "0-setup"
assert_eq "  and it does so WHILE the string \"0-setup\" is present in voice-lint.mjs's source, which is what the retired substring grep would have read as \"accounted for\"" \
  "$([[ "$(grep -c '"0-setup"' "$LINT_SRC" | tr -d ' ')" == "0" ]] && echo "ABSENT FROM SOURCE: this cell cannot discriminate" || echo present)" "present"
assert_eq "  CONTROL on the injection itself: dropping a phase the tables never held moves nothing, so the cell above reports a real removal rather than the drop argument reddening everything" \
  "$(vl "$(vl_account 9-does-not-exist)" UNACCOUNTED)" ""

# ===========================================================================================
# #53 -- THE FORM-COVERAGE CONTROL: a population no assignment spelling can leave
#
# The second copy of the tri-partition (the drift suite carries the first, with the full fixture
# matrix). Two copies of the wide pattern remain in Lane 1; each carries this control, so a
# narrowing in either copy reddens in that copy. Every occurrence of the BARE WORD
# `current_phase` is CLAIMED (inside a span this suite's shipped derivation matched), EXCLUDED
# (inside NO span of a pattern strictly WIDER than the claim pattern) or UNCLASSIFIED (a real
# assignment the derivation misses). UNCLASSIFIED must be EMPTY and is reported BY NAME.
#
# The EXCLUDED bucket is a sorted occurrence-text MULTISET, asserted; its SIZE is only reported.
# Never `sort -u`: three of the five excluded LINES carry two occurrences each with identical
# text, so a set would turn 8 entries into 5 and re-open the bypass. Line numbers are REPORTED
# beside the entries and never asserted -- pipeline.md is edited by a lane that does not own this
# suite, and a coordinate pin is #68's shape.
# ===========================================================================================
tripart() {
  node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const md = readFileSync(process.argv[1], "utf8");
    const CLAIM = /"?current_phase"?: *"([^"]*)"/g;
    const WIDER = /["\x27`]?current_phase["\x27`]?\s*[:=]\s*(?:"[^"]*"|\x27[^\x27]*\x27|`[^`]*`|[A-Za-z0-9._<>-]+)/g;
    const spans = (re) => [...md.matchAll(re)].map((m) => [m.index, m.index + m[0].length, m[0]]);
    const claimSpans = spans(CLAIM), widerSpans = spans(WIDER);
    const within = (i, ss) => ss.find(([a, b]) => i >= a && i < b);
    const lines = md.split("\n");
    const starts = []; { let o = 0; for (const l of lines) { starts.push(o); o += l.length + 1; } }
    const lineOf = (i) => { let lo = 0, hi = starts.length - 1;
      while (lo < hi) { const m = (lo + hi + 1) >> 1; if (starts[m] <= i) lo = m; else hi = m - 1; } return lo; };
    const claimed = [], excluded = [], unclassified = [];
    for (const m of md.matchAll(/current_phase/g)) {
      const i = m.index, li = lineOf(i), text = lines[li];
      if (within(i, claimSpans)) { claimed.push({ li, text }); continue; }
      const w = within(i, widerSpans);
      if (!w) excluded.push({ li, text }); else unclassified.push({ li, span: w[2] });
    }
    const out = [];
    out.push("TOTAL=" + [...md.matchAll(/current_phase/g)].length);
    out.push("CLAIMED=" + claimed.length);
    out.push("EXCLUDED=" + excluded.length);
    out.push("UNCLASSIFIED=" + unclassified.length);
    out.push("LITERALS=" + [...new Set([...md.matchAll(CLAIM)].map((m) => m[1]))]
      .filter((p) => p !== "<phase>-error").sort().join(","));
    out.push("EXLINES=" + excluded.map((e) => e.li + 1).join(","));
    out.push("UNNAMED=" + unclassified.map((e) => (e.li + 1) + ":" + e.span.replace(/\s+/g, " ")).join(" ;; "));
    out.push("--EXFP--");
    for (const line of excluded.map((e) => e.text.trim().length + "|" + e.text.trim().slice(0, 72)).sort()) out.push(line);
    process.stdout.write(out.join("\n"));
  ' "$1" 2>&1
}
tp_exfp() { printf '%s' "$1" | sed -n '/^--EXFP--$/,$p' | sed '1d'; }

# NOT a heredoc inside a $( ) capture: /bin/bash 3.2.57 scans a command substitution for its
# closing paren WITHOUT honouring quoted-heredoc rules, so the UNPAIRED backtick left by a
# 72-character truncation makes the whole file un-parseable.
EXCLUDED_MULTISET_8='133|- **User interrupts mid-phase**: status.json preserves position. `/pipel
285|- If starts with `--resume <issue>`: set `ISSUE=<issue>`, read `.pipelin
285|- If starts with `--resume <issue>`: set `ISSUE=<issue>`, read `.pipelin
461|**`events[]` entries are EXIT markers and `current_phase` is an ENTRY ma
461|**`events[]` entries are EXIT markers and `current_phase` is an ENTRY ma
479|`status.json` is the `/pipeline --resume <issue>` checkpoint, so it must
479|`status.json` is the `/pipeline --resume <issue>` checkpoint, so it must
89|# Run BEFORE entering each phase, after setting current_phase to the pha'

# ---------------------------------------------------------------------------
suite "#53 AC2: every bare-word occurrence lands in exactly one named bucket"
# ---------------------------------------------------------------------------
TP_REAL="$(tripart "$PIPELINE_MD")"
record "REPORTED, never asserted: pipeline.md holds $(vl "$TP_REAL" TOTAL) bare-word \`current_phase\` occurrences, $(vl "$TP_REAL" CLAIMED) CLAIMED and $(vl "$TP_REAL" EXCLUDED) EXCLUDED, at lines $(vl "$TP_REAL" EXLINES). Grain is OCCURRENCES, not distinct literals"
assert_eq "the three buckets ACCOUNT FOR every bare-word occurrence" \
  "$(( $(vl "$TP_REAL" CLAIMED) + $(vl "$TP_REAL" EXCLUDED) + $(vl "$TP_REAL" UNCLASSIFIED) ))" \
  "$(vl "$TP_REAL" TOTAL)"
assert_eq "UNCLASSIFIED is EMPTY: no assignment the WIDER pattern can see is missed by the derivation this suite ships" \
  "$(vl "$TP_REAL" UNNAMED)" ""
# AC1, asserted OFF THE TRI-PARTITION rather than off the module report, deliberately: this is a
# property of pipeline.md and of the pattern, and it must be able to go red independently of
# whether the module's tables can be imported at all.
assert_eq "the derived label SET is exactly the 26 concrete literals pipeline.md writes, \`0-setup\` among them -- and it is the SAME sorted list the drift suite pins, so a narrowing in either copy reddens in that copy" \
  "$(vl "$TP_REAL" LITERALS)" "$PHASE_LITERALS_26"
assert_eq "and the EXCLUDED bucket's MEMBERSHIP is asserted -- the sorted occurrence-text MULTISET, so an occurrence cannot move between buckets at constant bucket sizes" \
  "$(tp_exfp "$TP_REAL")" "$EXCLUDED_MULTISET_8"
assert_eq "MULTISET, NOT A SET: \`sort -u\` collapses those 8 entries to 5, which is measured here rather than asserted absent by inspection" \
  "$(tp_exfp "$TP_REAL" | sort -u | grep -c . | tr -d ' ')/$(tp_exfp "$TP_REAL" | grep -c . | tr -d ' ')" "5/8"

# ---------------------------------------------------------------------------
suite "#53 AC13: RUNTIME NEUTRALITY -- what the lint says is byte-unchanged by this change"
# ---------------------------------------------------------------------------
# R6 exports a table `run()` does not read, and the cheapest wrong next step is to start reading
# it and make the unrecognised-phase branch LOUD, converting a documented fail-open into a
# refusal of the first turn of every pipeline run.
#
# THREE CELLS, AND THE THIRD IS THE ONLY ONE THAT DISCRIMINATES. Once `0-setup` is DECLARED it
# takes the quiet path under BOTH the correct and the broken implementation, so a matrix of
# {`0-setup`, `5-archived`} sits entirely in the branch that works and the broken branch never
# runs. The silent class is narrower than "unrecognised": `9-invented` is SHAPE-INVALID and
# exits 2, and `halted-error` is shape-VALID but error-suffixed and also exits 2. The class is
# {shape-valid AND undeclared AND not error-suffixed}, and `3-impl-nonesuch` is its witness.
#
# Byte counts of a NON-ZERO result are deliberately not pinned: two readers measured 913 and 914
# for the same cell, because the number is message-dependent. ZERO bytes is pinned; a non-zero
# result is pinned by its NAMED-FAILURE count.
named_failures() { printf '%s\n' "$1" | grep -c '^- ' | tr -d ' '; }
EM_DASH_NO_BLOCKS="Refactored the parser — it now handles the nested case — and tests pass."

set_phase "0-setup"
write_transcript "$EM_DASH_NO_BLOCKS"
lint
assert_eq "(1) at \`0-setup\` the lint is SILENT: exit 0" "$RC" "0"
assert_eq "    and says nothing at all -- ZERO bytes, em dashes and all" "$ERR" ""

set_phase "3-impl-nonesuch"
write_transcript "$EM_DASH_NO_BLOCKS"
lint
assert_eq "(3) THE DISCRIMINATING CELL: a SHAPE-VALID phase this change leaves UNDECLARED still exits 0 -- the documented fail-open. This is the cell that goes red if run() starts consulting the newly exported NON_VOICE_PHASES" "$RC" "0"
assert_eq "    and it too says nothing -- ZERO bytes" "$ERR" ""

set_phase "5-archived"
write_transcript "$EM_DASH_NO_BLOCKS"
lint
assert_eq "(2) NON-ZERO CONTROL: the identical message at a declared voice moment exits 2, so cells (1) and (3) are silence and not a lint that stopped firing" "$RC" "2"
assert_eq "    with its five NAMED failures (the count, never the byte length: two readers measured 913 and 914 for this same message)" \
  "$(named_failures "$ERR")" "5"

set_phase "halted-error"
write_transcript "$EM_DASH_NO_BLOCKS"
lint
assert_eq "    NARROWING, so the silent class is not read as \"unrecognised\": \`halted-error\` is shape-VALID and still exits 2, because errorMoment matches /-error\$/" "$RC" "2"

set_phase "9-invented"
write_transcript "$EM_DASH_NO_BLOCKS"
lint
assert_eq "    and \`9-invented\` exits 2 for a different reason again -- it is SHAPE-INVALID against status.schema.json's pattern" "$RC" "2"
assert_contains "    naming the schema rather than a voice rule, which is what makes it a different cell from (3)" "$ERR" "status.schema.json"

rm -f "$TEMP_ISSUE_DIR/status.json"

# ---------------------------------------------------------------------------
suite "voice-lint: exp-<slug> runs are LINTED, not exempt"
# ---------------------------------------------------------------------------
# voice-lint.mjs used to declare its OWN issue-dir pattern, /^\d+$/, so resolveStatus could not
# see an experiment run at all: no active issue, no phase, no lint. The control went quiet on
# exactly the runs nobody is watching, and it did so silently -- the same defect shape, in a
# third copy of the same vocabulary, that widening the validator's pattern already fixed for
# artifact validation and that AC17 in test-gate-phase-entry.sh pins for the phase-entry guard
# ("exp-<slug> runs are GUARDED, not exempt"). The pattern is now IMPORTED from the validator,
# so these cases also stand as the behavioural witness that the import is wired up.
#
# This block deliberately runs LAST: it repoints TEMP_PROJECT/TEMP_ISSUE_DIR/TRANSCRIPT at a
# fresh root whose only issue dir is an exp- one, which would break the cases above if it ran
# before them.
EXP_SLUG="exp-two-owner-gates"
make_temp_project "$EXP_SLUG" || exit 90
TRANSCRIPT="$TEMP_PROJECT/transcript.jsonl"

# NO active-issue signal, because that is the shape production runs in: the Stop payload does
# not carry one, so the mtime scan is the branch that has to admit an exp- dir. Both signal
# names are unset around the CHILD, never around the assertion.
exp_lint_nosignal() {
  local errf="$TEMP_PROJECT/err.txt"
  printf '%s' "{\"cwd\":\"$TEMP_PROJECT\",\"transcript_path\":\"$TRANSCRIPT\"}" \
    | ( cd "$TEMP_PROJECT" && env -u CLAUDE_PIPELINE_ACTIVE_ISSUE -u PIPELINE_ACTIVE_ISSUE \
        CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$LINT" ) 2>"$errf" >/dev/null
  RC=$?
  ERR=$(cat "$errf")
}

# The OTHER branch: the explicit signal is regex-tested against the same vocabulary, so a
# numeric-only pattern rejected an exp- signal too. Widening one branch and not the other would
# pass every case above.
exp_lint_signal() {
  local errf="$TEMP_PROJECT/err.txt"
  printf '%s' "{\"cwd\":\"$TEMP_PROJECT\",\"transcript_path\":\"$TRANSCRIPT\"}" \
    | ( cd "$TEMP_PROJECT" && env CLAUDE_PIPELINE_ACTIVE_ISSUE="$EXP_SLUG" \
        CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$LINT" ) 2>"$errf" >/dev/null
  RC=$?
  ERR=$(cat "$errf")
}

set_phase "2.5-design-owner-decision"
write_transcript "I picked approach B because it is cleaner. Moving on to implementation."
exp_lint_nosignal
assert_eq "an exp- run at a decision moment is LINTED (mtime path) and exits 2" "$RC" "2"
assert_contains "and names the phase" "$ERR" "2.5-design-owner-decision"

exp_lint_signal
assert_eq "and the explicit-signal branch admits an exp- slug too" "$RC" "2"
assert_contains "and names the phase" "$ERR" "2.5-design-owner-decision"

# CONTROL, on the same exp- root: a compliant message is silent. Without it these cases would
# pass just as well against a lint that had started reddening everything, and "exp- is no
# longer exempt" would be indistinguishable from "exp- is now always refused".
write_transcript "$GOOD_DECISION"
exp_lint_nosignal
assert_eq "CONTROL: the same exp- moment WITH the decision block exits 0" "$RC" "0"
assert_eq "CONTROL: and says nothing" "$ERR" ""

# CONTROL: the exemption was phase-blind, so prove the lint still discriminates BY PHASE inside
# an exp- dir rather than simply biting on every exp- run it can now see.
set_phase "3-impl"
write_transcript "Refactored the parser — it now handles the nested case — and tests pass."
exp_lint_nosignal
assert_eq "CONTROL: a NON-voice phase in an exp- dir is still silent, em dashes and all" "$RC" "0"

finish
