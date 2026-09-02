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
# narrowing in either copy reddens in that copy.
#
# THE DUPLICATION IS A KNOWN RESIDUAL AND CLOSURE IS TRACKED, so this comment is a pointer and
# not a shrug: HANDOFF C (a single Lane-1 derivation helper consumed by both suites) is recorded
# in the deferral ledger posted as a comment on issue #53. Its BINDING CONSTRAINT is recorded
# there too and is repeated here because it is the part a future implementer will get wrong: a
# shared helper returns the EXTRACTION from pipeline.md and NEVER an asserted set. Lane 2
# asserts 27 because it ADDS `halted-error` under a stated rule of its own, so a helper that
# returned the asserted set would make Lane 2 refuse correct work. Every occurrence of the BARE WORD
# `current_phase` is CLAIMED (inside a span this suite's shipped derivation matched), EXCLUDED
# (inside NO span of a pattern strictly WIDER than the claim pattern) or UNCLASSIFIED (a real
# assignment the derivation misses). UNCLASSIFIED must be EMPTY and is reported BY NAME.
#
# The EXCLUDED bucket is a sorted occurrence-text MULTISET, asserted; its SIZE is only reported.
# Never `sort -u`: three of the seven excluded LINES carry two occurrences each with identical
# text, so a set would turn 10 entries into 7 and re-open the bypass. Line numbers are REPORTED
# beside the entries and never asserted -- pipeline.md is edited by a lane that does not own this
# suite, and a coordinate pin is #68's shape.
# ===========================================================================================
tripart() {
  node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const md = readFileSync(process.argv[1], "utf8");
    const CLAIM = /"?current_phase"?: *"([^"]*)"/g;
    // WIDER IS A FLOOR, NOT A TOTAL, and it has misses of its own. Measured over four spellings:
    // a bracket-index assignment, a markdown-bold key, and a YAML block scalar are matched by
    // NEITHER pattern, so all three land in EXCLUDED and read as prose; only the
    // single-quoted-value form with an = separator lands in UNCLASSIFIED where it belongs.
    // Three misses out of four tested. Do not read a green UNCLASSIFIED as "no spelling can
    // escape": what bounds the damage is the BARE-WORD population, because a missed spelling is
    // still COUNTED and still has to be named in the excluded list somebody reads.
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
#
# THE FINGERPRINT IS NON-INJECTIVE, and pipeline.md already contains a colliding pair. Measured
# at this commit: lines 270 and 284 are both 107 trimmed characters and agree for the first 99,
# differing only at `SecOps` versus `DevOps` -- past the 72-character cut, so they share one
# fingerprint. Neither carries `current_phase`, so the collision is LATENT rather than live.
# What it costs is stated in the assertion label below rather than left to be inferred: two
# occurrences that share a fingerprint can be exchanged invisibly, so this cell catches an
# ADDITION or a REMOVAL and not every conceivable swap.
# ONE ENTRY CARRIES AN APOSTROPHE, spliced as '\''. The pinned block is a single-quoted shell
# literal, and #110's prose is the first pinned occurrence to contain a `'` -- without the splice
# the assignment terminates mid-entry and the file stops parsing. Future pipeline.md edits will
# hit this again, so the splice is the fixture's limitation being handled, not the prose bending.
EXCLUDED_MULTISET_10='1253|**Rows 2 and 3 loop back for remediation, and the write that DOES the lo
133|- **User interrupts mid-phase**: status.json preserves position. `/pipel
285|- If starts with `--resume <issue>`: set `ISSUE=<issue>`, read `.pipelin
285|- If starts with `--resume <issue>`: set `ISSUE=<issue>`, read `.pipelin
397|Nothing is lost by clearing. The panel'\''s result is durable in `events[]`
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
assert_eq "and the EXCLUDED bucket's MEMBERSHIP is asserted -- the sorted occurrence-text MULTISET, so an occurrence cannot be ADDED to or REMOVED from this bucket at constant bucket sizes. NARROWED deliberately from \"cannot move between buckets\": the key is a length-plus-72-character FINGERPRINT and it is non-injective (pipeline.md already holds a colliding pair, see above), so a swap BETWEEN two occurrences sharing one fingerprint is invisible here. The add/remove form is what this cell supports; the bucket-swap fixture that exercises it lives in the drift suite, which carries the full fixture matrix, and not in this copy" \
  "$(tp_exfp "$TP_REAL")" "$EXCLUDED_MULTISET_10"
assert_eq "MULTISET, NOT A SET: \`sort -u\` collapses those 10 entries to 7, which is measured here rather than asserted absent by inspection" \
  "$(tp_exfp "$TP_REAL" | sort -u | grep -c . | tr -d ' ')/$(tp_exfp "$TP_REAL" | grep -c . | tr -d ' ')" "7/10"

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

# =============================================================================================
# #80 -- THE RULING THAT PHASE 0 STEP 1 IS OUT OF SCOPE, AND THE ORDERING THAT RULING RESTS ON
# =============================================================================================
# THE GAP THIS GUARDS, measured before it was written. Phase 0 step 1 halts to the owner in full
# voice with a decision block if the worktree is dirty, and step 5 is what first writes a phase
# record. voice-lint derives its moment FROM that record, so at step 1 there is nothing to derive
# from. Measured with an em dash planted in a step-1-shaped halt: no state dir at all -> rc 0 and
# ZERO bytes; a record already at `0-setup` -> rc 0 and ZERO bytes; the IDENTICAL message at
# `5-archived` -> rc 2 with five named failures. The cells above already pin the second and third
# of those. A resume is silent too rather than mis-graded, because #56 reads the prior session
# record as stale.
#
# `0-setup` IS DECLARED NON-VOICE PARTLY BECAUSE OF THAT ORDERING, so the declaration carries an
# expiry that nothing could see: move the halt after the record write, or add ANY owner-facing
# full-voice block between that write and the next `Checkpoint first`, and the declaration is
# wrong while every test stays green. #80's ruling is that the halt stays OUT OF SCOPE (the
# reasoning is in voice-lint.mjs beside the `0-setup` entry and in Phase 0 of commands/pipeline.md
# beside the halt itself). This suite is the other half: a ruling with no failing assertion behind
# it documents a gap instead of protecting one.
#
# THE MARKER TABLE IS ITS OWN CONTROL. Each entry is asserted LIVE somewhere in pipeline.md, so a
# phrase that falls out of use reddens as a dead table entry rather than quietly becoming a hole
# in the window scan -- which is #53's own defect (a population narrower than its subject) one
# level in. The fixture matrix below drives MUTATED COPIES of pipeline.md through the identical
# probe, and it carries a NEGATIVE cell: the same inserted block placed OUTSIDE the window must
# leave the report green, or this scan would only prove that it fires on anything.
# ---------------------------------------------------------------------------------------------

# p0_window <pipeline.md path> -> a KEY=value report, consumed with the `vl` accessor above.
p0_window() {
  node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const lines = readFileSync(process.argv[1], "utf8").split("\n");
    const MARKERS = [
      ["full-voice",       /full[ -]voice/i],
      ["decision-block",   /decision block/i],
      ["surface-to-owner", /surface to the owner/i],
      ["return-to-owner",  /return to the owner/i],
      ["await-the-owner",  /awaits? the owner/i],
    ];
    // The step-1 halt, identified by the conjunction that makes it that halt and not prose about
    // it: the worktree command it runs, plus both owner-facing markers.
    const isHalt = (l) =>
      /git status --short/.test(l) && /full[ -]voice/i.test(l) && /decision block/i.test(l);
    // The ruling paragraph, anchored on the issue number rather than on any of its wording, so a
    // rewrite of the prose does not read as a stray owner-decision block.
    const isRuling = (l) => /#80/.test(l);
    const find = (re, from) => { for (let i = from; i < lines.length; i++) if (re.test(lines[i])) return i; return -1; };
    const phase0 = find(/^## Phase 0: Setup\s*$/, 0);
    const setupWrites = lines.filter((l) => /"current_phase": "0-setup"/.test(l)).length;
    const setup = find(/"current_phase": "0-setup"/, 0);
    const cp = setup < 0 ? -1 : find(/Checkpoint first/, setup + 1);
    const marks = (a, b) => {
      const hits = [];
      for (let i = a; i < b; i++) for (const [name, re] of MARKERS) if (re.test(lines[i])) hits.push((i + 1) + ":" + name);
      return hits;
    };
    const haltLines = [], rulingLines = [];
    lines.forEach((l, i) => { if (isHalt(l)) haltLines.push(i + 1); });
    if (phase0 >= 0 && setup > phase0) for (let i = phase0; i < setup; i++) if (isRuling(lines[i])) rulingLines.push(i + 1);
    const fileHits = MARKERS.map(([n, re]) => n + ":" + lines.filter((l) => re.test(l)).length);
    const dead = MARKERS.filter(([, re]) => !lines.some((l) => re.test(l))).map(([n]) => n);
    const window = setup >= 0 && cp > setup ? marks(setup, cp) : ["WINDOW-UNRESOLVABLE"];
    const stray = phase0 >= 0 && setup > phase0
      ? marks(phase0, setup).filter((h) => { const i = Number(h.split(":")[0]) - 1; return !isHalt(lines[i]) && !isRuling(lines[i]); })
      : ["PREWINDOW-UNRESOLVABLE"];
    const out = [];
    out.push("PHASE0=" + (phase0 >= 0 ? "found" : "ABSENT"));
    out.push("SETUPWRITES=" + setupWrites);
    out.push("CPAFTER=" + (cp > setup && setup >= 0 ? "found" : "ABSENT"));
    out.push("WINDOWLINES=" + (cp > setup && setup >= 0 ? cp - setup : 0));
    out.push("HALTLINES=" + haltLines.join(","));
    out.push("HALTBEFORE=" + (haltLines.length === 1 && setup >= 0 ? (haltLines[0] - 1 < setup ? "yes" : "NO") : "na"));
    out.push("RULINGLINES=" + rulingLines.join(","));
    out.push("FILEHITS=" + fileHits.join(","));
    out.push("DEAD=" + dead.join(","));
    out.push("WINDOWHITS=" + window.join(" "));
    out.push("PREWINDOWSTRAY=" + stray.join(" "));
    process.stdout.write(out.join("\n"));
  ' "$1" 2>&1
}

# p80_count <comma-list> -> how many entries. `awk -F, '{print NF}'` reads ZERO records on an
# empty string and prints NOTHING, so a deleted halt would compare "" against "0" and the cell
# would redden for the wrong reason -- or, with the expectation written as "", pass vacuously.
p80_count() {
  [[ -n "$1" ]] || { printf '0'; return; }
  printf '%s' "$1" | tr ',' '\n' | grep -c . | tr -d ' '
}

# ---------------------------------------------------------------------------
suite "#80 AC1: the premises the \`0-setup\` non-voice ruling rests on, off pipeline.md itself"
# ---------------------------------------------------------------------------
P80="$(p0_window "$PIPELINE_MD")"
assert_eq "PREMISE: the probe resolved Phase 0, exactly ONE \`0-setup\` write, and a following \`Checkpoint first\` -- without all three the window is undefined and every cell below would range over nothing" \
  "$(vl "$P80" PHASE0)/$(vl "$P80" SETUPWRITES)/$(vl "$P80" CPAFTER)" "found/1/found"
assert_eq "PREMISE: the step-1 halt is present and UNIQUE -- exactly one line carries the worktree command together with both owner-facing markers. A deletion or a second copy is named here rather than silently emptying the ordering cell below" \
  "$(p80_count "$(vl "$P80" HALTLINES)")" "1"
assert_eq "PREMISE: exactly one ruling paragraph sits in Phase 0 above the write, anchored on the issue number rather than on its wording, so criterion (c) can tell it from a newly added owner-decision block. Delete the ruling and this reddens instead of (c) quietly absolving a stray" \
  "$(p80_count "$(vl "$P80" RULINGLINES)")" "1"
assert_eq "ANTI-VACUITY on the marker table, per entry rather than in aggregate: NO marker is dead. A whole-table check passes while one row silently matches nothing, which is exactly how a population gets narrower than its subject" \
  "$(vl "$P80" DEAD)" ""
record "REPORTED, not asserted: whole-file marker hits are $(vl "$P80" FILEHITS), and the guarded window spans $(vl "$P80" WINDOWLINES) lines. Counts move on ordinary prose edits; the SETS below are what is asserted"

assert_eq "#80 THE CRITERION (a): the step-1 halt sits BEFORE the \`0-setup\` write, which is the whole reason a turn cannot END at that phase in that halt" \
  "$(vl "$P80" HALTBEFORE)" "yes"
assert_eq "#80 THE CRITERION (b): the window between the \`0-setup\` write and the next \`Checkpoint first\` carries NO owner-facing full-voice marker. This is the expiry condition written in voice-lint.mjs beside the \`0-setup\` entry, and until now nothing evaluated it" \
  "$(vl "$P80" WINDOWHITS)" ""
assert_eq "#80 THE CRITERION (c): and the region ABOVE the write carries no owner-facing marker other than the step-1 halt and the ruling that declares it out of scope. A second unreachable halt would not break (a) or (b), but it would widen what \"out of scope\" covers without the ruling saying so" \
  "$(vl "$P80" PREWINDOWSTRAY)" ""

# ---------------------------------------------------------------------------
suite "#80 AC2: the fixture matrix -- each criterion reddens under its own edit, and only it"
# ---------------------------------------------------------------------------
# Mutations are applied to COPIES in a temp dir, never to the checkout: run.sh is this project
# checkCommand and the Stop hook executes it at live turn ends, so a suite that edited the real
# pipeline.md would ship a planted defect if it were interrupted between mutation and restore.
new_tmpdir || exit 90
P80_DIR="$NEW_TMPDIR"
P80_BLOCK='**A new owner-facing halt.** Surface to the owner in **full voice mode** with a decision block before continuing.'

# M1 -- the reorder the ruling expires on: the step-1 halt moves BELOW the record write.
node --input-type=module -e '
  import { readFileSync, writeFileSync } from "node:fs";
  const [src, dst] = process.argv.slice(1);
  const lines = readFileSync(src, "utf8").split("\n");
  const h = lines.findIndex((l) => /git status --short/.test(l) && /full[ -]voice/i.test(l) && /decision block/i.test(l));
  const [halt] = lines.splice(h, 1);
  const w = lines.findIndex((l) => /"current_phase": "0-setup"/.test(l));
  lines.splice(w + 2, 0, "", halt);
  writeFileSync(dst, lines.join("\n"));
' "$PIPELINE_MD" "$P80_DIR/m1.md"
P80_M1="$(p0_window "$P80_DIR/m1.md")"
assert_eq "M1 REORDER: with the step-1 halt moved BELOW the \`0-setup\` write, criterion (a) reddens" \
  "$(vl "$P80_M1" HALTBEFORE)" "NO"
assert_contains "M1: and criterion (b) reddens too, naming the moved line -- the two cells are not one cell wearing two labels, they fail together here and separately in M2 and M4" \
  "$(vl "$P80_M1" WINDOWHITS)" ":full-voice"

# M2 -- an owner-decision block INSERTED into the window, the other expiry #53's ruling rests on.
node --input-type=module -e '
  import { readFileSync, writeFileSync } from "node:fs";
  const [src, dst, block] = process.argv.slice(1);
  const lines = readFileSync(src, "utf8").split("\n");
  const w = lines.findIndex((l) => /"current_phase": "0-setup"/.test(l));
  const cp = lines.findIndex((l, i) => i > w && /Checkpoint first/.test(l));
  lines.splice(cp - 1, 0, "", block);
  writeFileSync(dst, lines.join("\n"));
' "$PIPELINE_MD" "$P80_DIR/m2.md" "$P80_BLOCK"
P80_M2="$(p0_window "$P80_DIR/m2.md")"
assert_contains "M2 INSERTION: an owner-decision block placed inside the window reddens criterion (b), naming its line and marker" \
  "$(vl "$P80_M2" WINDOWHITS)" ":full-voice"
assert_eq "  DISCRIMINATION: and criterion (a) is UNMOVED by it, so (b) is not reading (a) second-hand" \
  "$(vl "$P80_M2" HALTBEFORE)" "yes"

# M3 -- THE NEGATIVE CELL. The identical block, placed OUTSIDE the window, must change nothing.
# Without this the scan would prove only that it fires, never that it discriminates by position.
node --input-type=module -e '
  import { readFileSync, writeFileSync } from "node:fs";
  const [src, dst, block] = process.argv.slice(1);
  const lines = readFileSync(src, "utf8").split("\n");
  const w = lines.findIndex((l) => /"current_phase": "0-setup"/.test(l));
  const cp = lines.findIndex((l, i) => i > w && /Checkpoint first/.test(l));
  lines.splice(cp + 2, 0, "", block);
  writeFileSync(dst, lines.join("\n"));
' "$PIPELINE_MD" "$P80_DIR/m3.md" "$P80_BLOCK"
P80_M3="$(p0_window "$P80_DIR/m3.md")"
assert_eq "M3 NEGATIVE CONTROL: the BYTE-IDENTICAL block placed just PAST the next \`Checkpoint first\` leaves the window clean. That phase records its own label before the block runs, so it is not this ruling to make" \
  "$(vl "$P80_M3" WINDOWHITS)" ""
assert_eq "  and leaves (a) and (c) alone as well, so M2's red is positional and not merely textual" \
  "$(vl "$P80_M3" HALTBEFORE)/$(vl "$P80_M3" PREWINDOWSTRAY)" "yes/"

# M4 -- the halt DELETED. The premise cell must catch this, or (a) would pass over an empty set.
node --input-type=module -e '
  import { readFileSync, writeFileSync } from "node:fs";
  const [src, dst] = process.argv.slice(1);
  const lines = readFileSync(src, "utf8").split("\n")
    .filter((l) => !(/git status --short/.test(l) && /full[ -]voice/i.test(l) && /decision block/i.test(l)));
  writeFileSync(dst, lines.join("\n"));
' "$PIPELINE_MD" "$P80_DIR/m4.md"
P80_M4="$(p0_window "$P80_DIR/m4.md")"
assert_eq "M4 DELETION: with the halt removed, the uniqueness premise reddens (0 lines) and criterion (a) reports \`na\` rather than \`yes\`, so an absent halt can never read as an ordering that was checked" \
  "$(p80_count "$(vl "$P80_M4" HALTLINES)")/$(vl "$P80_M4" HALTBEFORE)" "0/na"

# M5 -- a marker RETIRED by a prose rename. The per-entry liveness cell must name it.
node --input-type=module -e '
  import { readFileSync, writeFileSync } from "node:fs";
  const [src, dst] = process.argv.slice(1);
  writeFileSync(dst, readFileSync(src, "utf8").replace(/decision block/gi, "call block"));
' "$PIPELINE_MD" "$P80_DIR/m5.md"
P80_M5="$(p0_window "$P80_DIR/m5.md")"
assert_eq "M5 RETIRED MARKER: renaming one phrase out of pipeline.md makes its table row match nothing, and the liveness cell NAMES that row. Without this, the window scan would go on passing over a vocabulary that no longer describes the file" \
  "$(vl "$P80_M5" DEAD)" "decision-block"

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

# ###########################################################################################
# #56 -- SCOPE THE VOICE OBLIGATION TO THE TURN THAT PRODUCED THE RECORD
# ###########################################################################################
#
# THE DEFECT, IN ONE SENTENCE. voice-lint decides whether to impose voice.md's shape from one
# input, the current_phase of whichever .pipeline/<issue>/status.json is newest by mtime, and a
# phase carries no notion of WHEN and no notion of WHOSE. So `5-archived` is terminal and grades
# every later message in the session as the completion report (the IN-RUN half), and when the
# current run's record is REMOVED at archival the mtime scan falls through to some other lane's
# parked record and grades this session's message against a run this session does not own (the
# CROSS-RUN half, which is the sharper one and was reproduced live).
#
# THE FIX, AS AN OUTCOME PROPERTY RATHER THAN A MECHANISM: no message may be refused on account
# of a record that has not been touched since the last OWNER-AUTHORED turn began. The state is
# not remembered, it is DERIVED -- the Stop payload already names the transcript and the
# transcript already carries the turn boundary.
#
# THE THREE THINGS THESE CELLS EXIST TO STOP, because each of them ships green:
#
#   1. THE NESTING MISREADING. `origin` is a RECORD-LEVEL object, a sibling of type / isSidechain
#      / isMeta / timestamp / message. It is NOT message.origin. Measured over 1,817 transcript
#      files and 398,088 records: 2,742 record-level origin objects, ZERO under message, in every
#      client version. An implementer who reads record.message?.origin?.kind -- the natural
#      misreading, because origin.kind is listed right after message.role and shares its rhythm --
#      finds ZERO human turns on every transcript ever written, the unresolvable-boundary
#      fallback fires every time, and the change ships as a PERMANENT, TOTAL, SILENT no-op that
#      looks exactly like the control working. The drift battery cannot see it (a permanently
#      loud predicate passes every drift cell trivially, because loud is what those cells
#      assert). The nesting-discrimination PAIR is what catches it, and a fixture that hand-wrote
#      `origin` at the wrong level would CANCEL the implementation's error, which is why every
#      owner record below is CAPTURED from a live transcript instead.
#
#   2. THE SELF-DISARM. Deciding "has a person weighed in" by SUBTRACTING known machine spellings
#      from the set of user records is the wrong side of the transformation: it inherits every
#      future spelling the vendor adds, and it admitted voice-lint's OWN blocking refusal, so the
#      control disarmed itself the instant it first fired and the identical bad message passed on
#      resend. A human turn is therefore identified POSITIVELY, and where provenance cannot be
#      established the boundary does not advance, which leaves the lint loud.
#
#   3. SILENCE AS A TOOLING FAILURE. This change must NEVER be the reason for silence. Every
#      unresolvable boundary -- no owner-authored record, an absent or unparseable timestamp, an
#      unrecognised record shape, a client predating the origin field -- leaves behaviour exactly
#      as it is today. The one input that is already silent today (an unreadable transcript, which
#      exits 0 because there is no assistant text to grade) STAYS silent, deliberately, and is
#      asserted as a pair against a readable-but-defective control so the cell cannot pass by
#      everything going quiet.
#
# WHAT IS GREEN TODAY AND WHAT IS RED. Roughly half of these cells assert PRESERVATION (today's
# behaviour, kept) and are green against the shipped module; they exist to redden under a named
# mutation, and each carries that mutation in its label. The other half assert the new behaviour
# and are red until it exists. A cell that is green today is not a cell that checks nothing --
# but a reader auditing this block should be able to tell which is which from the label, and if
# one cannot, that is a defect in the label.

VL56_SUITE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
VL56_FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures/voice-lint-56" && pwd)"
VL56_BUILD_MJS="$VL56_FIX_DIR/build.mjs"
VL56_CLASSIFY_MJS="$VL56_FIX_DIR/classify.mjs"
VL56_AC9_MJS="$VL56_FIX_DIR/ac9-divergence.mjs"
VL56_PRELOAD_CJS="$VL56_FIX_DIR/preload.cjs"
VL56_READPROBE_MJS="$VL56_FIX_DIR/read-probe.mjs"
VL56_HYGIENE_MJS="$VL56_FIX_DIR/hygiene-scan.mjs"
VL56_VALIDATOR="$SCRIPTS_DIR/validate-pipeline-artifact.mjs"

# ---- the clock, taken ONCE ------------------------------------------------------------------
# Every anchor below is derived from one Date.now(), so no cell can drift against another by the
# time the suite takes to run. The names are the ones the spec's own measured table uses.
eval "$(node -e '
  const now = Date.now(), M = 60000, H = 3600000;
  process.stdout.write([
    "VL56_NOW=" + now,
    "VL56_OWNER_MS=" + (now - 60 * M),   // the turn boundary: the last owner-typed record
    "VL56_STALE_MS=" + (now - 72 * H),   // a record written long before that boundary
    "VL56_FRESH_MS=" + (now - 30 * M),   // a record written AFTER that boundary, i.e. this turn
    "VL56_PREWRITE_MS=" + (now - 45 * M), // a record between the boundary and the status write
    "VL56_INJECT_MS=" + (now - 10 * M),  // a record injected after the status write
    "VL56_LATER_MS=" + (now - 5 * M),
  ].join("\n"));
')"

# JSON-encode one shell string (quotes included), so a fixture message with newlines, quotes or
# an em dash in it survives the trip into a spec without a hand-rolled escape.
vl56_q() { node -e 'process.stdout.write(JSON.stringify(String(process.argv[1])))' "$1"; }

VL56_DEFECTIVE_REPORT='### Done

We archived the run.'
VL56_COMPLETE_REPORT='### Done

### See it yourself

Open the page.

**Blast radius:** Contained
**Reversibility:** Undo button
**Confidence:** Solid'
VL56_ORDINARY='Refactored the parser and the tests pass.'
VL56_REWRITE_EM_DASH="$VL56_COMPLETE_REPORT

On reflection — a rewrite in the same turn."
# Two distinctive strings that exist ONLY in a transcript. R10's added line is a FIXED LITERAL:
# no byte of the transcript may appear in it, which is the standing property that nothing from
# the transcript reaches stderr. A marker is how that is checked rather than assumed.
VL56_MARKER_A='ZZ56MARKERALPHA7419ZZ'
VL56_MARKER_B='ZZ56MARKERBRAVO8265ZZ'

Q_DEFECT="$(vl56_q "$VL56_DEFECTIVE_REPORT")"
Q_COMPLETE="$(vl56_q "$VL56_COMPLETE_REPORT")"
Q_ORDINARY="$(vl56_q "$VL56_ORDINARY")"
Q_REWRITE="$(vl56_q "$VL56_REWRITE_EM_DASH")"
Q_DEFECT_A="$(vl56_q "$VL56_DEFECTIVE_REPORT

$VL56_MARKER_A")"
Q_DEFECT_B="$(vl56_q "$VL56_DEFECTIVE_REPORT

$VL56_MARKER_B")"

# ---- the LEDGERS ----------------------------------------------------------------------------
# Two files that accumulate across every cell in this block and are asserted once at the end.
# A per-cell assertion of either would be 120 lines of noise; a single end assertion over a
# population that is REPORTED non-empty is the same guarantee without it.
new_tmpdir || exit 90
VL56_LEDGER_DIR="$NEW_TMPDIR"
VL56_STAMP_LOG="$VL56_LEDGER_DIR/stamps"   # every mtime stamp's read-back drift (R8)
VL56_RC_LOG="$VL56_LEDGER_DIR/rcs"         # every exit code this block observed (AC11)
: > "$VL56_STAMP_LOG"
: > "$VL56_RC_LOG"

# ---- fixture helpers ------------------------------------------------------------------------

# A fresh, registered project root plus its transcript path.
vl56_project() {
  new_tmpdir || exit 90
  VL56_PROJECT="$NEW_TMPDIR"
  VL56_TRANSCRIPT="$VL56_PROJECT/transcript.jsonl"
}

# vl56_fixture <dirs-json> <records-json> [global-ops-json]
# ONE shared builder for every cell, which is what makes "AC1 and AC2 differ ONLY in the mtime"
# a structural fact instead of a promise. Every stamp it applies is read back and its drift
# recorded, so a stamp that silently no-ops is named where it happened rather than reddening a
# distant cell for the wrong reason.
vl56_fixture() {
  vl56_project
  local ops=""
  [[ -n "${3:-}" ]] && ops=',"globalOps":'"$3"
  VL56_BUILD_OUT="$(node "$VL56_BUILD_MJS" "$VL56_PROJECT" \
    '{"dirs":'"$1"',"transcript":"'"$VL56_TRANSCRIPT"'","records":'"$2"''"$ops"'}' 2>&1)"
  printf '%s\n' "$VL56_BUILD_OUT" | grep -o 'deltaMs=[0-9]*' >> "$VL56_STAMP_LOG"
  case "$VL56_BUILD_OUT" in
    *BUILT*) ;;
    *) printf 'FIXTURE BUILD FAILED: %s\n' "$VL56_BUILD_OUT" >&2 ;;
  esac
}

# vl56_lint <transcript-path | @absent> <signal> [extra-payload-json]
#   signal: none | claude=<name> | plain=<name>
# Sets RC and ERR, exactly like the suite's own lint(). The environment is scoped around the
# CHILD PROCESS and never around the assertion, per the harness's uncounted-assertion guard.
vl56_lint() {
  local tr="$1" signal="$2" extra="${3:-}"
  local payload errf="$VL56_PROJECT/err.txt"
  if [[ "$tr" == "@absent" ]]; then
    payload='{"cwd":"'"$VL56_PROJECT"'"'"$extra"'}'
  else
    payload='{"cwd":"'"$VL56_PROJECT"'","transcript_path":"'"$tr"'"'"$extra"'}'
  fi
  local -a envargs
  envargs=(env -u CLAUDE_PIPELINE_ACTIVE_ISSUE -u PIPELINE_ACTIVE_ISSUE "CLAUDE_PROJECT_DIR=$VL56_PROJECT")
  case "$signal" in
    none) ;;
    claude=*) envargs+=("CLAUDE_PIPELINE_ACTIVE_ISSUE=${signal#claude=}") ;;
    plain=*)  envargs+=("PIPELINE_ACTIVE_ISSUE=${signal#plain=}") ;;
  esac
  # Two optional KEY=VALUE slots, appended one at a time rather than splatted from an array, so
  # a value containing a space cannot silently become two arguments. Used only by the AC18
  # read-counter and the stat-guard cell.
  [[ -n "${VL56_ENV1:-}" ]] && envargs+=("$VL56_ENV1")
  [[ -n "${VL56_ENV2:-}" ]] && envargs+=("$VL56_ENV2")
  printf '%s' "$payload" \
    | ( cd "$VL56_PROJECT" && "${envargs[@]}" node ${VL56_NODE_ARGS:-} "$LINT" ) 2>"$errf" >/dev/null
  RC=$?
  ERR=$(cat "$errf")
  printf '%s\n' "$RC" >> "$VL56_RC_LOG"
}

# The two fixture shapes almost every cell is built from, named so a reader can see at a glance
# which cells share a builder.
vl56_dirs()  { printf '[{"name":"%s","phase":"%s","mtimeMs":%s%s}]' "$1" "$2" "$3" "${4:-}"; }
vl56_owner() { printf '{"k":"owner_string","ts":%s}' "${1:-$VL56_OWNER_MS}"; }
vl56_asst()  { printf '{"k":"assistant","text":%s}' "$1"; }

# CLASSIFY <captured-class> [ops-json] -> the shipped isHumanTurnRecord's verdict on that record
vl56_classify() {
  node "$VL56_CLASSIFY_MJS" "$LINT" "$1" "${2:-[]}" 2>&1 | sed -n 's/^CLASSIFY=//p'
}

# ---------------------------------------------------------------------------------------------
suite "#56 PREMISES: the captured fixtures, asserted as present-tense facts before anything is concluded from them"
# ---------------------------------------------------------------------------------------------
# A captured fixture beats a hand-written one -- a hand-copied fixture restates the contract
# instead of observing it, so it tracks whoever last remembered to update it -- and it STILL
# ROTS. Every field the cells below lean on is pinned here, so a vendor change to a record shape
# reddens with the field named instead of quietly satisfying whatever cell that record sits in.
VL56_FACTS="$(node "$VL56_BUILD_MJS" --facts 2>&1)"
vl56f() {
  case "$VL56_FACTS" in
    *"$1="*) printf '%s' "$VL56_FACTS" | sed -n "s/^$1=//p" ;;
    *) printf '<no-fact:%s>' "$1" ;;
  esac
}

assert_eq "PREMISE: all seven provenance classes R5 rules on were captured, none hand-written" \
  "$(vl56f CLASSES)" \
  "auto_compaction,cross_session_peer,owner_image_array,owner_string,task_notification,tool_result,voice_lint_refusal"

# THE PIN THAT MATTERS MOST. AC1, AC8's control, AC13 and AC15 all work by SILENCING a cell, and
# a hand-written owner record carrying `origin` at the wrong nesting level would make every one
# of them pass for the wrong reason under an implementation that reads it at that same wrong
# level -- the fixture's error and the implementation's error cancelling, suite green, control
# dead in production. These two lines are what stop that.
assert_eq "PREMISE: the captured owner record carries origin.kind 'human' at RECORD level (a sibling of type/isSidechain/isMeta/timestamp/message), which is where R5 says it lives and where 2,742 of 2,742 observed origin objects are" \
  "$(vl56f owner_string.recordLevelOriginKind)" '"human"'
assert_eq "  and it carries NOTHING under message.origin -- 0 of 398,088 records anywhere do, in any client version, so an implementation reading record.message?.origin?.kind finds no human turn on any transcript ever written" \
  "$(vl56f owner_string.messageLevelOrigin)" "undefined"
assert_eq "  and the image-array owner record says the same, so AC15's two content shapes cannot differ in their nesting" \
  "$(vl56f owner_image_array.recordLevelOriginKind)/$(vl56f owner_image_array.messageLevelOrigin)" '"human"/undefined'

assert_eq "PREMISE: the captured owner record is type 'user', role 'user', isSidechain false, isMeta ABSENT -- the shape R5's six clauses are conjoined over" \
  "$(vl56f owner_string.type)/$(vl56f owner_string.role)/$(vl56f owner_string.isSidechain)/$(vl56f owner_string.isMeta)" \
  "user/user/false/undefined"
assert_eq "PREMISE: 957 of 969 owner records carry STRING content and 12 carry array[image,text]; ZERO carry a text-only array, so the two captures here are the two shapes that occur and not a shape that never does" \
  "$(vl56f owner_string.contentShape)/$(vl56f owner_image_array.contentShape)" \
  "string/array[image+text]"

# The four non-owner classes, each pinned by the field that excludes it. R7(v): the cross-session
# message is excluded TWICE OVER (origin.kind 'peer' AND isMeta true), and this is where that
# depth is visible rather than asserted.
assert_eq "PREMISE: the background task-completion notice carries origin.kind 'task-notification' (1,377 of 1,377 do, with ZERO carrying an absent origin, in every client version observed)" \
  "$(vl56f task_notification.recordLevelOriginKind)" '"task-notification"'
assert_eq "PREMISE: the cross-session message is excluded TWICE OVER -- origin.kind 'peer' AND isMeta true (31 of 31 carry both). sessionId is NOT a third guard: all 31 are stamped with the RECEIVING session's own id, so an equality test cannot see them" \
  "$(vl56f cross_session_peer.recordLevelOriginKind)/$(vl56f cross_session_peer.isMeta)" '"peer"/true'
assert_eq "PREMISE: voice-lint's OWN Stop-hook refusal record -- the self-disarm, and the thing that vetoed the first design -- carries isMeta true and NO origin field at all, so it is excluded by the isMeta clause AND by the positive-origin requirement" \
  "$(vl56f voice_lint_refusal.isMeta)/$(vl56f voice_lint_refusal.recordLevelOriginKind)/$(vl56f voice_lint_refusal.type)/$(vl56f voice_lint_refusal.isSidechain)/$(vl56f voice_lint_refusal.contentShape)" \
  "true/undefined/user/false/string"
assert_eq "PREMISE: the auto-compaction continuation carries NO origin and NO isMeta, so ONLY the positive-origin requirement excludes it -- which is why it is one of the two declared survivors of the relabel drift below" \
  "$(vl56f auto_compaction.recordLevelOriginKind)/$(vl56f auto_compaction.isMeta)" "undefined/undefined"
assert_eq "PREMISE: the tool-result-bearing user record carries no origin, and the predicate reaches that verdict WITHOUT reading message content at all (which is what stops a renamed block type disarming it)" \
  "$(vl56f tool_result.recordLevelOriginKind)/$(vl56f tool_result.contentShape)" "undefined/array[tool_result]"

record "REPORTED, never asserted: the captures were taken $(vl56f CAPTURED_AT) from client versions owner=$(vl56f owner_string.clientVersion) task=$(vl56f task_notification.clientVersion) peer=$(vl56f cross_session_peer.clientVersion) refusal=$(vl56f voice_lint_refusal.clientVersion). Re-derive with fixtures/voice-lint-56/capture.py"

# ---------------------------------------------------------------------------------------------
suite "#56 R5/AC8: the predicate itself, driven directly -- one record in, one verdict out"
# ---------------------------------------------------------------------------------------------
# WHY THE CLASSIFIER IS DRIVEN DIRECTLY AND NOT ONLY THROUGH EXIT CODES. A process exit code is
# moved by four other things (the phase table, the shape check, the transcript read, lintVoice),
# so a cell that only reads rc cannot say WHICH of them moved. Both Phase-2 reviewers could only
# verify the nesting pair by building their own reference predicate; design.json exports
# isHumanTurnRecord so the SHIPPED one can be driven instead. Every cell below is a behavioural
# claim about one record, and the process-level cells further down are what prove the classifier
# is actually wired into the decision rather than exported and unused.

assert_eq "the captured OWNER record is a human turn" "$(vl56_classify owner_string)" "true"
assert_eq "and so is the owner record whose content is an array carrying an image block -- CONTENT IS NOT READ, deliberately: reading it is what produced two of the three silent drift classes, and it would reject the 12 measured owner messages that carry an image" \
  "$(vl56_classify owner_image_array)" "true"

# THE NESTING-DISCRIMINATION PAIR. The only thing in this spec that catches the misreading that
# ships as a permanent silent no-op. Both halves must move, in OPPOSITE directions, under
# record.message?.origin?.kind -- which is why a single cell would not do.
assert_eq "NESTING PAIR, half 1: the captured owner record with \`origin\` at RECORD level IS a human turn" \
  "$(vl56_classify owner_string)" "true"
assert_eq "NESTING PAIR, half 2: the SAME record with its \`origin\` object RELOCATED under \`message\` is NOT a human turn -- a relocated origin is not a recognised provenance. Under record.message?.origin?.kind BOTH halves invert at once (true->false and false->true), which is the signature this pair exists to produce" \
  "$(vl56_classify owner_string '[["mv","origin","message.origin"]]')" "false"

assert_eq "an owner record with origin.kind DELETED is not a human turn (identification is POSITIVE: absence is not permission)" \
  "$(vl56_classify owner_string '[["del","origin.kind"]]')" "false"
assert_eq "and an UNLISTED origin.kind is excluded exactly like every listed value except 'human' -- the value space is OPEN, not a validated enum ('coordinator' was found only after the first census, in subagent transcripts)" \
  "$(vl56_classify owner_string '[["set","origin.kind","coordinator"]]')" "false"

# The four harness-injected classes that defeated the first design, asserted PER CLASS because a
# fixture for one witnesses nothing about another.
assert_eq "a background task-completion notice is NOT a human turn (1,377 of 1,377 carry origin.kind 'task-notification')" \
  "$(vl56_classify task_notification)" "false"
assert_eq "an auto-compaction continuation is NOT a human turn (22 of 22 carry no origin at all)" \
  "$(vl56_classify auto_compaction)" "false"
assert_eq "a cross-session message from another process on this machine is NOT a human turn" \
  "$(vl56_classify cross_session_peer)" "false"
assert_eq "THE SELF-DISARM: voice-lint's OWN Stop-hook refusal record is NOT a human turn. Under the first design it WAS, so the control disarmed itself the instant it first fired and the identical bad message passed on resend" \
  "$(vl56_classify voice_lint_refusal)" "false"
assert_eq "a tool-result-bearing user record is NOT a human turn" \
  "$(vl56_classify tool_result)" "false"

# --- the isMeta clause, promoted from DECLARED SURVIVOR to ASSERTED CATCH ---------------------
# Against unrelabelled captures, dropping isMeta reddens nothing, because origin.kind has already
# excluded every capturable record before that clause is consulted. Crossed with the vendor-relabel
# drift, it becomes falsifiable on fixtures this suite already builds -- no fabricated shape
# required. This is the compound-predicate rule turned on the test suite itself: a battery can
# only mutate the code its fixtures REACH, so the fixture MATRIX is what separates a real survivor
# from an unexercised one.
assert_eq "isMeta IS LOAD-BEARING, cell 1: a Stop-hook refusal record RELABELLED origin.kind 'human' is STILL not a human turn, because isMeta true excludes it independently of origin. Drop the isMeta clause and this flips to true, reopening the self-disarm" \
  "$(vl56_classify voice_lint_refusal '[["set","origin.kind","human"]]')" "false"
assert_eq "isMeta IS LOAD-BEARING, cell 2: a cross-session peer message RELABELLED origin.kind 'human' is STILL not a human turn, for the same reason. This is what 'excluded twice over' buys, and it is why isMeta must not be deleted as redundant" \
  "$(vl56_classify cross_session_peer '[["set","origin.kind","human"]]')" "false"

# --- THE DECLARED EXPECTED SURVIVORS ---------------------------------------------------------
# A battery in which every mutation reddens cannot tell coverage from a rubber stamp: "all red"
# is a zero result about the instrument. These two are the honest cost of positive identification
# and they are asserted in the direction that documents them.
assert_eq "DECLARED SURVIVOR (residual iv), and it is EXPECTED: a task-completion notice RELABELLED origin.kind 'human' IS admitted, because positive identification necessarily trusts the vendor's own provenance label. It carries no isMeta, so nothing excludes it independently. EXPIRY: if this cell ever returns false, either a structural discriminator has appeared that the predicate should now use, or the fixture no longer constructs the relabel, and this control needs a new subject. Re-derive by re-running the origin.kind census over a fresh corpus and checking that no non-owner class carries 'human'" \
  "$(vl56_classify task_notification '[["set","origin.kind","human"]]')" "true"
assert_eq "DECLARED SURVIVOR (residual iv), second class: an auto-compaction continuation RELABELLED origin.kind 'human' is likewise admitted, and for the same reason -- 0 of 22 carry isMeta. Same expiry as the cell above" \
  "$(vl56_classify auto_compaction '[["set","origin.kind","human"]]')" "true"
record "THE CLAUSE BATTERY'S SURVIVOR ACCOUNTING, run rather than reasoned, because a battery in which every mutation reddens cannot tell coverage from a rubber stamp. Dropping each of the six clauses from a reference predicate and running this whole suite: type, origin.kind, isMeta and the timestamp parse are each CAUGHT above; message.role is CAUGHT too, by the absent-message cell below and by the drift battery's own message.role row, which is a stronger result than the spec predicted and needed no fabricated record to get; isSidechain is the ONE genuine survivor -- dropping it reddens nothing at all. Its reason, measured: 0 of 28,992 main-session user records carry isSidechain true, so the only fixture that could falsify it is a fabricated origin.kind-'human'-plus-isSidechain-true record, a shape that occurs 0 times in 398,088 records. Manufacturing a collision that never occurs to make a battery look complete is the rubber stamp these controls exist to prevent, so the clause stays as defence in depth and stays declared. If a future corpus ever produces such a record, that is the signal to promote it from survivor to asserted catch, and to change this line"

# --- R11: a malformed-but-parseable record is NOT a human turn, and never a THROW -------------
# main() wraps run() in a blanket catch that exits 0 on any uncaught exception, which is
# fail-OPEN and the exact inversion of this change's governing property. The sibling module
# shipped precisely this defect and it was graded the most serious thing in that review. Each
# shape is asserted alone, because a whole-function guard would hide a dead branch.
assert_eq "R11: a JSON line that parses to null is not a human turn (and does not throw)" \
  "$(vl56_classify @literal 'null')" "false"
assert_eq "R11: a JSON line that parses to a NUMBER is not a human turn" \
  "$(vl56_classify @literal '42')" "false"
assert_eq "R11: a JSON line that parses to a STRING is not a human turn" \
  "$(vl56_classify @literal '"just a string"')" "false"
assert_eq "R11: a JSON line that parses to an ARRAY is not a human turn" \
  "$(vl56_classify @literal '[]')" "false"
assert_eq "R11: an owner record with \`message\` absent entirely is not a human turn" \
  "$(vl56_classify owner_string '[["del","message"]]')" "false"
assert_eq "R11: an owner record whose \`origin\` is a STRING rather than an object is not a human turn" \
  "$(vl56_classify owner_string '[["set","origin","not-an-object"]]')" "false"
assert_eq "R11: an owner record whose message.content is a BARE STRING is still a human turn -- the predicate reads no content, so this must not throw and must not narrow. 957 of 969 production owner records have exactly this shape, so an implementation that reintroduced Array.isArray(content) here would turn the whole fix into a permanent loud no-op" \
  "$(vl56_classify owner_string '[["set","message.content","a bare string"]]')" "true"
assert_eq "R11: an owner record whose isSidechain is the STRING \"false\" is still a human turn -- it is not the boolean true, so it narrows nothing. The claim here is that a non-boolean does not THROW, not that it is rejected" \
  "$(vl56_classify owner_string '[["set","isSidechain","false"]]')" "true"

# --- the timestamp clause ---------------------------------------------------------------------
assert_eq "an owner record with NO timestamp is not a human turn -- an unresolvable boundary must leave the lint loud, never silence it" \
  "$(vl56_classify owner_string '[["del","timestamp"]]')" "false"
assert_eq "an owner record whose timestamp will not parse is not a human turn" \
  "$(vl56_classify owner_string '[["set","timestamp","the day before yesterday"]]')" "false"
assert_eq "an owner record whose timestamp is a NUMBER rather than a string is not a human turn (R5 requires a string Date.parse yields a finite value for; Date.parse(12345) is NaN but a number is not the specified type either)" \
  "$(vl56_classify owner_string '[["set","timestamp",1787000000000]]')" "false"

# ---------------------------------------------------------------------------------------------
suite "#56 AC1/AC2: the CROSS-RUN capture, silenced -- and its one-variable non-zero control"
# ---------------------------------------------------------------------------------------------
# THE EVENT THIS REPRODUCES, which is the sharper half of the defect and not the one the issue
# describes: when the current run's record is REMOVED at archival, the mtime scan falls through
# to the next-newest status.json, which is some other lane's parked record, and grades this
# session's message against a run this session does not own. Measured live: one lane's record was
# removed at ~13:20, which made a FOREIGN lane's record (mtime 08:23, current_phase
# 4-review-complete) the strict newest until a new run dir was written at 13:52, and a message in
# that window was refused for missing the panel-result scales.
#
# THE FIXTURE MATRIX IS LOAD-BEARING: the project holds NO record of the session's own, so the
# fallback is FORCED to the foreign dir. A fixture that also carried the session's own fresh
# record would test nothing about cross-run capture. And BOTH the mtime and updated_at are stale,
# or the max() composition keeps the record fresh and the cell tests the wrong thing.
VL56_CROSSRUN_RECORDS='['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"']'

vl56_fixture "$(vl56_dirs 40 4-review-complete "$VL56_STALE_MS" ',"updated_at":'"$VL56_STALE_MS")" \
             "$VL56_CROSSRUN_RECORDS"
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC1: a FOREIGN lane's record at 4-review-complete, untouched since before the last owner-typed turn began, no longer refuses this session's message: exit 0" "$RC" "0"
assert_eq "AC1: and ZERO bytes on stderr. Reproduced red at 587a4aa: rc 2, stderr naming 4-review-complete and two missing scales" "$ERR" ""

vl56_fixture "$(vl56_dirs 40 4-review-complete "$VL56_FRESH_MS" ',"updated_at":'"$VL56_STALE_MS")" \
             "$VL56_CROSSRUN_RECORDS"
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC2 NON-ZERO CONTROL, ONE VARIABLE MOVED: the identical project, transcript and message with that same record's mtime moved to AFTER the boundary exits 2 -- so AC1 is silence and not a lint that stopped firing. Mutation: invert the comparison and this pair SWAPS rather than both reddening" "$RC" "2"
assert_contains "AC2: and names the phase it refused on" "$ERR" "4-review-complete"

# ---------------------------------------------------------------------------------------------
suite "#56 AC3: IN-RUN staleness, silenced -- and the predicate is PHASE-INDEPENDENT"
# ---------------------------------------------------------------------------------------------
# 5-archived is terminal, so once a run archives, current_phase states a true fact forever and
# every later message in the session is graded as the completion report. The issue records three
# consecutive instances of exactly this.
VL56_INRUN_RECORDS='['"$(vl56_owner)"','"$(vl56_asst "$Q_ORDINARY")"']'

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_STALE_MS")" "$VL56_INRUN_RECORDS"
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC3a: the session's OWN record at 5-archived, stale relative to the boundary, no longer grades an ordinary later message as the completion report: exit 0" "$RC" "0"
assert_eq "AC3a: and says nothing at all" "$ERR" ""

# THE MESSAGE HERE IS NOT THE ONE ABOVE, AND THAT IS NOT A STYLE CHOICE. errorMoment returns a
# moment carrying ONLY a label -- no decision block, no scales, no replication block -- so the
# only rules that can fire at an -error phase are the em dash and the banned phrases. With the
# ordinary message this cell would exit 0 today for a reason that has nothing to do with
# freshness, i.e. it would pass before the fix exists and go on passing after it, checking
# nothing. An em dash is what gives it something to be silenced FROM.
VL56_ERRMOMENT_RECORDS='['"$(vl56_owner)"','"$(vl56_asst "$(vl56_q "Halted — the migration failed and I stopped here.")")"']'
vl56_fixture "$(vl56_dirs 4244 halted-error "$VL56_FRESH_MS")" "$VL56_ERRMOMENT_RECORDS"
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC3b PREMISE, asserted before the cell below is read as evidence: at halted-error a FRESH record and an em-dashed message DO refuse, so the -error family reaches a moment at all and the next cell has something to be silenced from" "$RC" "2"
vl56_fixture "$(vl56_dirs 4244 halted-error "$VL56_STALE_MS")" "$VL56_ERRMOMENT_RECORDS"
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC3b: the same message at halted-error with the record stale exits 0. halted-error reaches its moment through errorMoment rather than through the VOICE_MOMENTS table, so this is what makes the predicate's phase-independence load-bearing: restrict the predicate to VOICE_MOMENTS keys and this reddens while AC3a stays green" "$RC" "0"

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" "$VL56_INRUN_RECORDS"
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC3 NON-ZERO CONTROL on the same builder: the identical fixture with the record written AFTER the boundary still exits 2, so AC3's silence is not this builder producing quiet fixtures" "$RC" "2"

# ---------------------------------------------------------------------------------------------
suite "#56 AC4/AC5: the TRUE POSITIVE is preserved, including a rewrite later in the same turn"
# ---------------------------------------------------------------------------------------------
# THE FIXTURE MATRIX, AND THIS CRITERION IS WORTHLESS WITHOUT IT: the transcript must carry
# tool_result-bearing user records BOTH BEFORE AND AFTER the status write. Without an
# after-the-write tool result every fixture sits in the one cell where "last owner-typed record"
# and "last user record of any kind" agree, and the criterion passes the mutation it exists to
# catch.
VL56_TRUEPOS_TAIL='{"k":"tool_result","ts":'"$VL56_PREWRITE_MS"'},{"k":"tool_result","ts":'"$VL56_INJECT_MS"'}'

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" \
  '['"$(vl56_owner)"','"$VL56_TRUEPOS_TAIL"','"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC4: a record written IN this turn, at 5-archived, with a report missing the replication block, still exits 2. Mutation: derive the boundary from the last user record of ANY kind and this goes silent, because a tool result sits after the write" "$RC" "2"
assert_contains "AC4: and names the missing section" "$ERR" "See it yourself"

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" \
  '['"$(vl56_owner)"','"$VL56_TRUEPOS_TAIL"','"$(vl56_asst "$Q_DEFECT")"','"$(vl56_asst "$Q_REWRITE")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC5: a SECOND assistant text later in the SAME turn is graded too -- the moment is scoped to the turn, not consumed by the first message after the write. Mutation: consume on first fire and this goes silent" "$RC" "2"
assert_contains "AC5: and the second message is what is graded, quoting the rule the rewrite broke" "$ERR" "em dash"
record "REPORTED: AC5's fixture cannot witness the PRODUCTION failure it is named for, because it carries no intervening refusal record. Under the first design voice-lint's own refusal ended the turn before the rewrite arrived, and this synthetic fixture stayed green anyway. The cell that makes AC5 mean in production what it means here is AC13"

# ---------------------------------------------------------------------------------------------
suite "#56 AC5b: WHICH assistant record is graded -- the accept condition is the JOINED STRING, not the block count"
# ---------------------------------------------------------------------------------------------
# A PHASE-4 GAP CLOSED, not a criterion carried down from the spec, and it is recorded as such so
# nobody reads it as an eighteenth AC. scanTranscript accepts an assistant record when the JOINED
# text is non-blank (`joined.trim() !== ""`), which is byte-for-byte the pre-#56 condition.
# Paraphrasing that as "a non-empty ARRAY of text blocks" survived ALL 257 cells of this suite:
# measured at 573bb38, the paraphrase reports passed=257 failed=0 while changing behaviour on the
# fixture below from rc 2 (1,217 bytes of stderr) to rc 0 (ZERO bytes). Found by Dev's own
# 11-mutation battery against the shipped module, escalated rather than closed by editing this
# file, and independently re-run at Phase 4 before this cell was written.
#
# WHY IT IS A CELL AND NOT A DECLARED RESIDUAL. The paraphrase's fail DIRECTION is SILENCE, which
# the module header's governing rule forbids outright ("THIS CHANGE MUST NEVER BE THE REASON FOR
# SILENCE"). Every other silence-direction residual in this spec that could actually be BUILT got
# pinned rather than declared -- AC16(d) is the precedent -- and the declared-residual idiom is
# reserved for classes no fixture can construct (the chronological inversion; the operator's
# restore shell). This one is three records.
#
# THIS IS NOT A VENDOR-DRIFT CELL, and the population says so: measured over 1,867 transcript
# files and 225,136 assistant records, ZERO carry a text block whose joined text is blank. So
# nothing is broken in production today, no fixture here can be CAPTURED, and this record is
# hand-built by necessity rather than by preference. What the cell defends against is an EDIT:
# the header calls scanTranscript's two-responsibility fusion "the wart" and names de-fusion as a
# likely future refactor, and that refactor is the event this cell is watching for. Edits are
# certain in a way vendor shapes are not.
#
# ASSERTED AS A PAIR THAT DISCRIMINATES rather than one that merely agrees. Both halves exit 2
# today, so "both went silent" cannot pass them; under the paraphrase the with-the-blank-record
# half flips to 0 while its twin stays at 2, which is what makes the pair a separator instead of
# two restatements of one fact.
VL56_BLANK_TEXT="$(printf '   \n  ')"

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" \
  '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"','"$(vl56_asst "$(vl56_q "$VL56_BLANK_TEXT")")"']'
# ANTI-VACUITY, and this cell is worthless without it: the whole criterion turns on the fixture
# actually constructing the ONE input on which the two conditions disagree -- a text-block array
# that is NON-EMPTY as an array while its joined text trims to nothing. A fixture that quietly
# built an empty content array, or dropped the blank block, would satisfy the pair below while
# witnessing nothing, and it would do so silently.
VL56_AC5B_SHAPE="$(node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => l.trim() !== "");
  const last = JSON.parse(lines[lines.length - 1]);
  const blocks = (last?.message?.content || []).filter((c) => c && c.type === "text" && typeof c.text === "string");
  process.stdout.write("type=" + last?.type + "/blocks=" + blocks.length + "/joinedTrimmed=" + JSON.stringify(blocks.map((c) => c.text).join("\n").trim()));
' "$VL56_TRANSCRIPT" 2>&1)"
assert_eq "AC5b PREMISE: the LAST record really is an assistant record carrying a non-empty array of text blocks whose JOINED text trims to empty -- the exact and only input on which 'non-blank joined string' and 'non-empty block array' disagree" \
  "$VL56_AC5B_SHAPE" 'type=assistant/blocks=1/joinedTrimmed=""'

vl56_lint "$VL56_TRANSCRIPT" none
VL56_AC5B_WITH="$RC"
VL56_AC5B_WITH_ERR="$ERR"

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" \
  '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
VL56_AC5B_WITHOUT="$RC"

assert_eq "AC5b: a trailing assistant record whose only text block is WHITESPACE is SKIPPED, so the earlier real report is still the message that gets graded -- and the identical transcript without that record reaches the same verdict. Mutation: accept on a non-empty ARRAY of text blocks instead of a non-blank JOINED string and the with-the-record half flips to 0 while its twin stays at 2, which no other cell in this suite can see" \
  "with=$VL56_AC5B_WITH/without=$VL56_AC5B_WITHOUT" "with=2/without=2"
assert_contains "AC5b: and the refusal names the section the EARLIER report is missing, which is what proves that report is what got graded rather than the blank record somehow satisfying the lint" \
  "$VL56_AC5B_WITH_ERR" "See it yourself"

# ---------------------------------------------------------------------------------------------
suite "#56 AC10: the freshness predicate applies on the EXPLICIT-SIGNAL branch too"
# ---------------------------------------------------------------------------------------------
# Measured at this checkout: 0 files under plugins/ assign CLAUDE_PIPELINE_ACTIVE_ISSUE outside
# tests/, out of 32 grep hits, so the mtime fallback is the live path today. The branch must not
# become a second behaviour anyway: an explicit signal must not be able to re-open the in-run
# false positive.
vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_STALE_MS")" "$VL56_INRUN_RECORDS"
vl56_lint "$VL56_TRANSCRIPT" claude=4244
assert_eq "AC10: a dir named by CLAUDE_PIPELINE_ACTIVE_ISSUE whose record is stale relative to the boundary exits 0. Mutation: apply the predicate only on the mtime-fallback branch and this flips to 2" "$RC" "0"
assert_eq "AC10: and says nothing" "$ERR" ""

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" "$VL56_INRUN_RECORDS"
vl56_lint "$VL56_TRANSCRIPT" claude=4244
assert_eq "AC10 CONTROL: the same dir named, record fresh, exits 2" "$RC" "2"

# ---------------------------------------------------------------------------------------------
suite "#56 AC8: no non-owner record class advances the turn boundary, asserted PER CLASS"
# ---------------------------------------------------------------------------------------------
# Shared fixture shape: a FRESH record at 5-archived, a defective report, and ONE injected record
# timestamped AFTER the status write. Each class is asserted alone, because a fixture for one
# witnesses nothing about another. The PAIRED CONTROL is what stops the whole suite passing by
# both sides going silent: a GENUINE owner message in that same position exits 0, because a real
# person speaking between the checkpoint and the report does end the turn.
vl56_ac8() {  # <injected-record-json> -> RC/ERR
  vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" \
    '['"$(vl56_owner)"','"$1"','"$(vl56_asst "$Q_DEFECT")"']'
  vl56_lint "$VL56_TRANSCRIPT" none
}

# (a) HAND-BUILT and labelled as such: 0 of 28,992 main-session user records carry isSidechain
#     true, so no capture of this shape exists. It is here to stop the NEW code path introducing
#     an exposure, not because one was measured.
vl56_ac8 '{"k":"literal","value":{"type":"user","isSidechain":true,"timestamp":"'"$(node -e 'process.stdout.write(new Date(Number(process.argv[1])).toISOString())' "$VL56_INJECT_MS")"'","message":{"role":"user","content":"a sidechain user record"}}}'
assert_eq "AC8(a) HAND-BUILT: a user-role record with isSidechain true does not advance the boundary, so the stale-report refusal still fires: exit 2" "$RC" "2"

vl56_ac8 '{"k":"task_notification","ts":'"$VL56_INJECT_MS"'}'
assert_eq "AC8(b) CAPTURED: a background task-completion notice does not advance the boundary: exit 2. These are 1,377 of the 1,668 harness-injected records the first design wrongly admitted" "$RC" "2"

vl56_ac8 '{"k":"auto_compaction","ts":'"$VL56_INJECT_MS"'}'
assert_eq "AC8(c) CAPTURED: an auto-compaction continuation does not advance the boundary: exit 2" "$RC" "2"

vl56_ac8 '{"k":"cross_session_peer","ts":'"$VL56_INJECT_MS"'}'
assert_eq "AC8(d) CAPTURED: a cross-session message from another process on this machine does not advance the boundary: exit 2" "$RC" "2"

vl56_ac8 '{"k":"voice_lint_refusal","ts":'"$VL56_INJECT_MS"'}'
assert_eq "AC8(e) CAPTURED, and this one is the self-disarm: voice-lint's OWN Stop-hook refusal record does not advance the boundary: exit 2. See the AC13 pair" "$RC" "2"

vl56_ac8 '{"k":"tool_result","ts":'"$VL56_INJECT_MS"'}'
assert_eq "AC8 extra: a tool-result-bearing user record does not advance it either" "$RC" "2"

vl56_ac8 "$(vl56_owner "$VL56_INJECT_MS")"
assert_eq "AC8 PAIRED CONTROL, and it is what stops every cell above passing by both sides going silent: a GENUINE captured owner message in that same position DOES end the turn, so the archived record reads stale and the lint goes quiet: exit 0. This is residual (ii), the one true positive the fix trades away, and it is the accepted cost" "$RC" "0"
assert_eq "AC8 PAIRED CONTROL: and it says nothing" "$ERR" ""

# --- AC8(f): THE NESTING-DISCRIMINATION PAIR, at process level ---------------------------------
# THE POSITION PREMISE IS PART OF THIS CELL AND IS RESTATED HERE RATHER THAN INHERITED, because
# it decides whether the pair discriminates at all. Both halves sit at the INJECTED position,
# timestamped AFTER the status write. Measured: with them BEFORE the write, all four cells of the
# 2x2 return 2 under both the correct and the wrong implementation, and the pair witnesses
# nothing.
vl56_ac8 "$(vl56_owner "$VL56_INJECT_MS")"
assert_eq "AC8(f) half 1, the correctly-placed control: a captured owner record with origin at RECORD level, at the injected position, silences the stale-report refusal: exit 0" "$RC" "0"

vl56_ac8 '{"k":"owner_string","ts":'"$VL56_INJECT_MS"',"ops":[["mv","origin","message.origin"]]}'
assert_eq "AC8(f) half 2: the SAME captured record with its origin object RELOCATED under message is not a recognised human turn, so the refusal still fires: exit 2. Under record.message?.origin?.kind BOTH halves invert at once (0->2 and 2->0), which is the signature this pair exists to produce and which a single cell could not give. This is the highest-value mutation in the spec: it is the only one whose survival means a permanently silent control, and it reddens NOTHING in the drift battery, because a predicate that finds no human turn anywhere passes every drift cell trivially" "$RC" "2"

# ---------------------------------------------------------------------------------------------
suite "#56 AC13: THE SELF-DISARM IS CLOSED, asserted as a pair"
# ---------------------------------------------------------------------------------------------
# THE CRITICAL PHASE-2 FINDING. Under the first design this cell exited 0: voice-lint's own
# refusal record was admitted as a human turn, so the control disarmed itself the instant it
# first fired and the identical bad message passed on resend. Asserted as a PAIR so the cell
# cannot pass by both sides going silent.
vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" \
  '['"$(vl56_owner)"',{"k":"voice_lint_refusal","ts":'"$VL56_INJECT_MS"'},'"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
VL56_AC13_WITH="$RC"
vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" \
  '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
VL56_AC13_WITHOUT="$RC"
assert_eq "AC13: a transcript in which voice-lint's own refusal record sits between the status write and the message under test yields the SAME verdict as the identical transcript with that record removed -- 2 in both. Mutation: drop the isMeta clause and the with-the-record half flips to 0 while its twin stays at 2, so the PAIR separates rather than both moving" \
  "with=$VL56_AC13_WITH/without=$VL56_AC13_WITHOUT" "with=2/without=2"

# ---------------------------------------------------------------------------------------------
suite "#56 AC15: CONTENT SHAPE IS NOT READ, asserted where it costs something"
# ---------------------------------------------------------------------------------------------
# These cells work by SILENCING a stale-record cell that would otherwise fire, so an
# implementation that recognises only one content shape, or that reintroduces a content test,
# reddens here rather than passing by fallback. Both owner records are CAPTURED and both were
# pinned above as carrying origin.kind at RECORD level -- without that pin, a hand-written record
# with origin nested under message would fail to silence and be read as a content-shape failure,
# pointing a reader at the content test rather than at the nesting.
vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_STALE_MS")" \
  '[{"k":"owner_string","ts":'"$VL56_OWNER_MS"'},'"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC15a: an owner record whose message.content is a bare STRING advances the boundary and silences the stale record: exit 0. 957 of 969 production owner records have this shape, so reintroducing Array.isArray(content) turns the whole fix into a permanent LOUD no-op" "$RC" "0"

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_STALE_MS")" \
  '[{"k":"owner_image_array","ts":'"$VL56_OWNER_MS"'},'"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC15b: an owner record whose content is an ARRAY carrying an image block alongside text does the same: exit 0. 12 production owner records have this shape and ZERO have a text-only array, so a fixture built only from text-block arrays would sit in a cell that never occurs" "$RC" "0"

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_STALE_MS")" \
  '[{"k":"task_notification","ts":'"$VL56_OWNER_MS"'},'"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC15 NON-ZERO CONTROL on the same builder: a NON-owner record in that same position does NOT silence the stale record, so the two cells above are the predicate discriminating and not this fixture shape being quiet: exit 2" "$RC" "2"

# ---------------------------------------------------------------------------------------------
suite "#56 AC16: the updated_at composition only WIDENS, and the residual it does NOT close is pinned beside it"
# ---------------------------------------------------------------------------------------------
# `updated_at` sits in status.schema.json's `required` set beside current_phase, in the same UTC
# ISO grain as the transcript timestamps, and all 9 live records carry it. The ruling: mtime stays
# the primary reference and updated_at may only WIDEN freshness, never narrow it. The basis is
# measured -- mtime is the record's write time exactly when nothing has touched the file since
# and a CHECKOUT timestamp otherwise (three orchestrator in-place writes agree with updated_at to
# under a second; six disagree by 3 hours to 13.7 days) -- and updated_at cannot be trusted alone,
# because its refresh is a writer convention restated at 1 of 33 write sites in pipeline.md.
#
# THE FULL CROSS PRODUCT IS THE POINT. A single cell of a max() cannot distinguish it from either
# operand alone, and the {mtime stale} x {updated_at stale} corner is exactly where an earlier
# draft could assert the composition, pass every cell it wrote, and still be wrong about what the
# composition bounds.
vl56_ac16() {  # <mtimeMs> <updated_at-json-or-empty> -> RC
  local extra=""
  [[ -n "${2:-}" ]] && extra=',"updated_at":'"$2"
  vl56_fixture "$(vl56_dirs 4244 5-archived "$1" "$extra")" \
    '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"']'
  vl56_lint "$VL56_TRANSCRIPT" none
}

vl56_ac16 "$VL56_STALE_MS" "$VL56_FRESH_MS"
assert_eq "AC16(a): mtime STALE but updated_at FRESH exits 2. This witnesses that the composition is a MAX and not either operand alone -- NOTHING MORE. It cannot witness the restore class, because 'mtime stale, updated_at fresh' is a combination none of cp -p, tar -x or rsync -a can produce and that 0 of 9 live records exhibit. Mutation: replace max() with mtime alone and this flips to 0" "$RC" "2"

vl56_ac16 "$VL56_FRESH_MS" "$VL56_STALE_MS"
VL56_AC16_B="$RC"
assert_eq "AC16(b): mtime FRESH but updated_at STALE still exits 2, because updated_at can never NARROW. Mutation: replace max() with updated_at alone and this flips to 0, which is the narrowing the ruling forbids" "$RC" "2"

vl56_ac16 "$VL56_FRESH_MS" ""
assert_eq "AC16(c1): an ABSENT updated_at behaves exactly as mtime alone would -- asserted against cell (b)'s OWN result rather than against a remembered value" "$RC" "$VL56_AC16_B"
vl56_ac16 "$VL56_FRESH_MS" '12345'
assert_eq "AC16(c2): a NON-STRING updated_at contributes nothing and cannot poison the comparison" "$RC" "$VL56_AC16_B"
vl56_ac16 "$VL56_FRESH_MS" '"the fourteenth of never"'
assert_eq "AC16(c3): an UNPARSEABLE updated_at contributes nothing either" "$RC" "$VL56_AC16_B"
vl56_ac16 "$VL56_STALE_MS" ""
assert_eq "AC16(c4): and with the mtime stale and updated_at absent the record reads stale, tracking mtime alone exactly as specified: exit 0" "$RC" "0"

# --- (d) THE DECLARED OPEN RESIDUAL --------------------------------------------------------
vl56_ac16 "$VL56_STALE_MS" "$VL56_STALE_MS"
assert_eq "AC16(d) DECLARED OPEN RESIDUAL (iii-b), DIRECTION: SILENCE, a missed check -- not a false refusal. THE RESTORE SIGNATURE, mtime and updated_at stale TOGETHER, exits 0. An mtime-preserving restore (cp -p, rsync -a, tar -x) carries the old updated_at along with the old mtime because updated_at is file CONTENT, so BOTH terms of the max() are stale together and a record placed in THIS turn still reads 72.00 hours old (measured, identically, for all three tools; the non-preserving control, a plain cp, reads 0.00h). EXPIRY, and read it before assuming this is a bug: if this cell ever exits 2, either a mechanism now dates the record by something a verbatim copy cannot carry, or the fixture no longer constructs the restore signature -- and this cell needs a new subject or deletion. THE ENVIRONMENT is an operator's shell restoring a tree, which is an environment no check in this repo ever runs in, so a green CI run is not evidence that the class is closed" "$RC" "0"

vl56_ac16 "$VL56_FRESH_MS" "$VL56_STALE_MS"
assert_eq "AC16(d) ONE-VARIABLE CONTROL: the identical fixture with only the mtime moved FORWARD exits 2, so (d)'s silence is genuine and not a lint that stopped firing for an unrelated reason" "$RC" "2"
record "REPORTED, so a reader does not count (d) as coverage of the restore class: its INPUT is structurally identical to AC3's stale cell, and its value is the LABEL and the EXPIRY, not new coverage. The signature is built with utimesSync plus a stale updated_at written into the content and NEVER by shelling out to cp -p, rsync or tar -- that pair is the restore's whole signature in the two fields the predicate reads, and shelling out would reintroduce the touch -t portability ban in another costume (rsync is not verified present on ubuntu-latest, and BSD and GNU cp differ). ctime DOES differ between a restored record and an untouched stale one, and ctime is rejected as a mechanism for a separate measured reason: utimesSync leaves ctime fresh, so a ctime-inclusive composition would force every stale fixture in this suite to be rebuilt by write-ordering against ~1.1s of real elapsed time"

# ---------------------------------------------------------------------------------------------
suite "#91: the TURN-BOUNDARY TIE resolves toward REFUSING, the opposite way from AC9(e)'s mtime tie"
# ---------------------------------------------------------------------------------------------
# WHAT THIS BLOCK EXISTS FOR. run()'s turn-scoping comparison is `recordFreshnessMs(...) <
# humanTurnMs`, and mutating that `<` to `<=` SURVIVED this whole suite -- a live coverage hole
# found reviewing #56 and filed as #91. The direction is not a detail: `<` keeps an exactly-tied
# record IN the turn and therefore LOUD, `<=` reads it stale and SILENCES a refusal the pre-#56
# code produced, which is the one thing the module's governing direction forbids of its own new
# suppressor. resolveStatus's mtime tie resolves the other way (AC9(e): abstain to null) and that
# is deliberate, because it ties between TWO CANDIDATE RECORDS where picking either means picking
# by readdir order; this comparison has one record and one boundary and nothing arbitrary to
# refuse. Both halves are now pinned, so a future reader finds a ruling instead of an asymmetry.
#
# THE TIE IS CONSTRUCTED THROUGH updated_at AND NOT THROUGH mtime, deliberately and by
# measurement: utimesSync-stamped mtimes read back with a fractional millisecond on APFS (the
# STAMP ledger at the end of this block records every drift), so an mtime tie against a
# whole-millisecond parsed timestamp is not constructible here. updated_at is an ISO string on
# both sides of the comparison, so `Date.parse` lands on the same integer and the tie is EXACT
# -- and the cell below asserts that exactness as a premise rather than assuming it, because a
# fixture that missed by one millisecond would exercise `>` and pass while proving nothing.

vl91_tie() {  # <updated_at ms> -> RC, with the mtime held far stale so updated_at decides
  vl56_ac16 "$VL56_STALE_MS" "$1"
}

vl91_tie "$VL56_OWNER_MS"
VL91_TIE_RC="$RC"
VL91_TIE_PROBE="$(node -e '
  const { readFileSync } = require("node:fs");
  const [statusFile, transcript] = process.argv.slice(1);
  const stated = Date.parse(JSON.parse(readFileSync(statusFile, "utf8")).updated_at);
  const owner = readFileSync(transcript, "utf8").split("\n").filter(Boolean)
    .map((l) => JSON.parse(l))
    .filter((r) => r && r.origin && r.origin.kind === "human").pop();
  if (!owner) { process.stdout.write("NO_OWNER_RECORD"); }
  else {
    const boundary = Date.parse(owner.timestamp);
    process.stdout.write(stated === boundary ? "EXACT" : "OFF_BY_" + (stated - boundary));
  }
' "$VL56_PROJECT/.pipeline/4244/status.json" "$VL56_TRANSCRIPT" 2>&1)"
assert_eq "#91 PREMISE: the fixture really constructs an EXACT tie -- the record's updated_at and the owner record's timestamp parse to the same integer millisecond. Without this the cell below could pass by being one ms LATE, which exercises the strictly-greater path and witnesses nothing about the tie" \
  "$VL91_TIE_PROBE" "EXACT"
assert_eq "#91(a) THE TIE ITSELF: a record dated EXACTLY at the turn boundary is IN the turn and still gets graded: exit 2. The turn window is CLOSED AT ITS LEFT END: in-turn means recordFreshnessMs >= humanTurnMs. MUTATION THIS CELL EXISTS FOR: change run()'s \`<\` to \`<=\` and this flips to 0 -- and nothing else in this suite moves, which is what made the mutation survivable before #91" \
  "$VL91_TIE_RC" "2"

vl91_tie "$((VL56_OWNER_MS - 1))"
assert_eq "#91(b) THE DISCRIMINATING TWIN, ONE MILLISECOND MOVED: the same fixture with updated_at one ms BEFORE the boundary reads stale and goes silent: exit 0. Paired with (a) this is what makes (a) a statement about the TIE rather than about a record that is fresh by a wide margin" \
  "$RC" "0"

vl91_tie "$((VL56_OWNER_MS + 1))"
assert_eq "#91(c) and one millisecond AFTER the boundary is loud again: exit 2. The three cells bracket the comparison, so a mutation to \`>\`, \`<=\` or \`>=\` reddens at least one of them" \
  "$RC" "2"

record "REPORTED, so the direction is not read as a live-bug fix: no behaviour changed at #91, only the ruling was written down and pinned. OBSERVED TIES IN PRODUCTION: ZERO. Measured on this machine, re-derivable: 12 of 12 live status.json records under this repo's own pipeline state dir carry a fractional-millisecond mtime while a parsed transcript timestamp is a whole one, so the mtime term cannot tie; 10 of those 12 records write updated_at at WHOLE-SECOND grain, and 0 of 523 observed origin.kind 'human' timestamps land on a whole second, so the updated_at term does not tie either today. The cells cost three fixtures and hold the direction against a vendor coarsening either clock, at which point this line decides between loud and silent on a common input"

# ---------------------------------------------------------------------------------------------
suite "#56 AC7: NO DISARM VECTOR -- every removed input leaves behaviour EXACTLY AS TODAY"
# ---------------------------------------------------------------------------------------------
# THE GOVERNING PROPERTY, stated so the two directions in this suite do not read as a
# contradiction: THIS CHANGE MUST NEVER BE THE REASON FOR SILENCE. For the three inputs where
# today's code produces a refusal, that means the lint fires. For an unreadable or wholly
# unparseable transcript, today's behaviour is ALREADY silence -- lastAssistantText catches the
# read failure and returns "", and run() returns before any boundary question is asked -- and
# this change preserves it DELIBERATELY, as preservation and not as a change. Making that input
# exit 2 would be a NEW false-refusal class fired by a malformed hook payload, on an input
# carrying no voice content at all.
vl56_ac7() {  # <records-json> -> RC/ERR, always with a FRESH record so the record is never the reason for silence
  vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" "$1"
  vl56_lint "$VL56_TRANSCRIPT" none
}

vl56_ac7 '[{"k":"owner_string","ts":'"$VL56_OWNER_MS"',"ops":[["del","timestamp"]]},'"$(vl56_asst "$Q_DEFECT")"']'
assert_eq "AC7(1) INPUT REMOVED: an owner record whose timestamp field is ABSENT leaves the boundary unresolvable, and an unresolvable boundary must never suppress a refusal today's code would have produced: exit 2" "$RC" "2"

vl56_ac7 '[{"k":"owner_string","ts":'"$VL56_OWNER_MS"',"ops":[["set","timestamp","last Tuesday-ish"]]},'"$(vl56_asst "$Q_DEFECT")"']'
assert_eq "AC7(2) INPUT REMOVED: an owner record whose timestamp will not parse: exit 2. Asserted separately from (1) so a whole-function mutation cannot hide a dead branch" "$RC" "2"

vl56_ac7 '[{"k":"tool_result","ts":'"$VL56_PREWRITE_MS"'},{"k":"tool_result","ts":'"$VL56_INJECT_MS"'},'"$(vl56_asst "$Q_DEFECT")"']'
assert_eq "AC7(3) INPUT REMOVED: a transcript of TOOL RESULTS ONLY, with no owner-authored record anywhere: exit 2" "$RC" "2"

# --- the three routes an unusable transcript takes, which are THREE and not two ---------------
# (4) and (5) reach lastAssistantText's catch by different routes; (6) never calls it at all,
# taking run()'s own `if (!transcript)` return. That third route is precisely the one a malformed
# hook payload takes, and it is what constrains WHERE the boundary scan may be placed: anything
# inserted before it changes this input's behaviour.
vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"']'
VL56_AC7_DIR="$VL56_PROJECT"
vl56_lint "$VL56_PROJECT/does-not-exist.jsonl" none
assert_eq "AC7(4) UNREADABLE, spelling 1 (the path does not exist): exit 0. Today's behaviour, preserved deliberately -- there is no message to grade, so there is nothing to refuse. Mutation, and it is the misreading this cell exists to catch: make 'no human turn resolvable' CONTRIBUTE a failure rather than attach a line to a refusal that already exists, and this flips from 0 to 2" "$RC" "0"
assert_eq "AC7(4): and ZERO bytes" "$ERR" ""

cp "$VL56_TRANSCRIPT" "$VL56_PROJECT/locked.jsonl"
chmod 000 "$VL56_PROJECT/locked.jsonl"
vl56_lint "$VL56_PROJECT/locked.jsonl" none
VL56_AC7_MODE000="$RC"
chmod 600 "$VL56_PROJECT/locked.jsonl"
assert_eq "AC7(5) UNREADABLE, spelling 2 (the path exists at mode 000): exit 0. Both spellings get their own cell because they arrive at the same catch by different routes and a fixture using only one witnesses nothing about the other" "$VL56_AC7_MODE000" "0"

vl56_lint "@absent" none
assert_eq "AC7(6) THE THIRD ROUTE: transcript_path ABSENT FROM THE PAYLOAD ENTIRELY exits 0 without lastAssistantText ever being called. This is the route a malformed hook payload takes, and a malformed hook payload must not be able to make this hook block" "$RC" "0"

vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC7 PAIRED CONTROL for (4), (5) and (6), on the IDENTICAL project dir and the IDENTICAL fresh record: a READABLE-but-defective transcript exits 2. Without it the three cells above could pass by everything going silent" "$RC" "2"

# --- R11's behavioural witness: structurally unexpected but PARSEABLE records ------------------
# main() wraps run() in a blanket catch that exits 0 on ANY uncaught exception. A throw from the
# new scan therefore lands in a fail-OPEN path, which is this change's exact inversion, and the
# sibling module shipped precisely that defect. Each shape is asserted alone.
vl56_ac7 '[{"k":"owner_string","ts":'"$VL56_OWNER_MS"',"ops":[["set","message.content","a bare string where an array is expected"]]},'"$(vl56_asst "$Q_DEFECT")"']'
assert_eq "AC7 R11(a): message.content a BARE STRING where an array is expected: exit 2, never a silent exit 0 via the outer catch" "$RC" "2"
vl56_ac7 '[{"k":"owner_string","ts":'"$VL56_OWNER_MS"',"ops":[["del","message"]]},'"$(vl56_asst "$Q_DEFECT")"']'
assert_eq "AC7 R11(b): the message object ABSENT entirely: exit 2" "$RC" "2"
vl56_ac7 '[{"k":"owner_string","ts":'"$VL56_OWNER_MS"',"ops":[["set","isSidechain",7]]},'"$(vl56_asst "$Q_DEFECT")"']'
assert_eq "AC7 R11(c): isSidechain present as a NON-BOOLEAN: exit 2" "$RC" "2"
vl56_ac7 '[{"k":"owner_string","ts":'"$VL56_OWNER_MS"',"ops":[["set","origin","a string, not an object"]]},'"$(vl56_asst "$Q_DEFECT")"']'
assert_eq "AC7 R11(d): origin present as a NON-OBJECT: exit 2" "$RC" "2"
vl56_ac7 '[{"k":"raw","line":"42"},{"k":"raw","line":"\"a bare string line\""},{"k":"raw","line":"null"},{"k":"raw","line":"[]"},'"$(vl56_asst "$Q_DEFECT")"']'
assert_eq "AC7 R11(e): JSON lines that parse to a NUMBER, a STRING, null and an ARRAY -- parseable, and none of them an object: exit 2. Mutation: remove one optional-chain guard from the scan and a malformed record throws into the outer catch, flipping this to 0" "$RC" "2"

# ---------------------------------------------------------------------------------------------
suite "#56 AC14: VENDOR-DRIFT BATTERY -- one field per cell, and it carries its own controls"
# ---------------------------------------------------------------------------------------------
# The transcript format belongs to the vendor, not to us. The question this battery answers is
# not "does the predicate keep working" but "WHICH WAY does it fail when a field it reads is
# renamed" -- and the only acceptable answer is LOUD, because a silently disarmed voice check is
# the defect class this whole issue is about, one size up. The first design went SILENT in every
# drift row.
#
# THE BATTERY IS RUN IN TWO COLUMNS, and the second is the one that discriminates.
#   Column A, record FRESH: every drift class must still exit 2. This is mostly loud by
#     construction, and it earns its place by catching a drift that makes the scan THROW (which
#     lands in the fail-open catch) or that accidentally admits a LATER record.
#   Column B, record STALE: the undrifted baseline exits 0. A drift in a field the predicate
#     READS makes the boundary unresolvable and flips it to 2; a drift in a field the predicate
#     deliberately does NOT read must leave it at 0. That is a battery that can return both
#     answers on one builder rather than an instrument that reddens indiscriminately.
VL56_DRIFT_RECORDS='['"$(vl56_owner)"',{"k":"voice_lint_refusal","ts":'"$VL56_INJECT_MS"'},{"k":"task_notification","ts":'"$VL56_INJECT_MS"'},{"k":"cross_session_peer","ts":'"$VL56_INJECT_MS"'},{"k":"auto_compaction","ts":'"$VL56_INJECT_MS"'},{"k":"tool_result","ts":'"$VL56_INJECT_MS"'},'"$(vl56_asst "$Q_DEFECT")"']'

vl56_drift() {  # <mtimeMs> <globalOps-json>
  vl56_fixture "$(vl56_dirs 4244 5-archived "$1")" "$VL56_DRIFT_RECORDS" "$2"
  vl56_lint "$VL56_TRANSCRIPT" none
}

# --- Column B baseline: the NON-ZERO CONTROL on the whole battery ------------------------------
vl56_drift "$VL56_STALE_MS" '[]'
assert_eq "AC14 CONTROL, column B baseline: with NO drift and a stale record the lint is SILENT (exit 0). Without this cell an all-loud battery cannot tell coverage from an instrument that reddens indiscriminately, which is a zero result about the harness rather than about the code" "$RC" "0"
vl56_drift "$VL56_FRESH_MS" '[]'
assert_eq "AC14 CONTROL, column A baseline: the same fixture with a fresh record is LOUD (exit 2)" "$RC" "2"

vl56_drift_pair() {  # <label> <ops> <expected-A> <expected-B> <why-B>
  vl56_drift "$VL56_FRESH_MS" "$2"
  assert_eq "AC14 column A [$1], record FRESH: still LOUD" "$RC" "$3"
  vl56_drift "$VL56_STALE_MS" "$2"
  assert_eq "AC14 column B [$1], record STALE: expected $4 -- $5" "$RC" "$4"
}

vl56_drift_pair "the 'user' type VALUE renamed" \
  '[["set","type","user-message"]]' 2 2 "a field the predicate READS, so the boundary becomes unresolvable and the lint goes loud"
vl56_drift_pair "message.role renamed" \
  '[["mv","message.role","message.sender"]]' 2 2 "a field the predicate READS"
vl56_drift_pair "the origin KEY renamed" \
  '[["mv","origin","provenance"]]' 2 2 "a field the predicate READS"
vl56_drift_pair "the origin.kind KEY renamed" \
  '[["mv","origin.kind","origin.category"]]' 2 2 "a field the predicate READS"
vl56_drift_pair "the 'human' VALUE itself renamed" \
  '[["set","origin.kind","person"]]' 2 2 "the VALUE is what is tested for, so renaming it is the same class as renaming the key"
vl56_drift_pair "the timestamp KEY renamed" \
  '[["mv","timestamp","occurred_at"]]' 2 2 "a field the predicate READS"

vl56_drift_pair "the isSidechain KEY renamed" \
  '[["mv","isSidechain","is_sidechain"]]' 2 0 "UNOBSERVABLE, and labelled rather than forced: the clause is 'isSidechain !== true', which an ABSENT field satisfies, so renaming it cannot change any verdict. It stays as defence in depth against a shape not yet observed (0 of 28,992 main-session user records carry it true)"
vl56_drift_pair "the isMeta KEY renamed" \
  '[["mv","isMeta","is_meta"]]' 2 0 "UNOBSERVABLE ON THIS FIXTURE for the same reason, since the OWNER record carries no isMeta at all. The clause is NOT dead weight: the relabel cross below is where it becomes falsifiable, and dropping it there reopens the self-disarm"

# --- the two classes the predicate deliberately NO LONGER reads --------------------------------
# Reading message content is what produced two of the three silent drift classes in the first
# design, and dropping the content read removes both at once. These two cells assert that
# removal behaviourally.
vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" \
  '['"$(vl56_owner)"',{"k":"tool_result","ts":'"$VL56_INJECT_MS"',"ops":[["set","message.content.0.type","tool_output"]]},'"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC14(9) a RENAMED tool_result block type: exit 2. Under an exclusion predicate that recognised tool results by their block type, the renamed record would be admitted as a human turn at a LATER timestamp than the write and the lint would go SILENT. Positive identification never looks at the block type at all" "$RC" "2"

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_STALE_MS")" \
  '[{"k":"owner_string","ts":'"$VL56_OWNER_MS"',"ops":[["mv","message.content","content"]]},'"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC14(10) CONTENT RELOCATED OUT of message.content[]: the verdict does not move, because the predicate reads no content -- exit 0, the same as the undrifted baseline. Mutation: reintroduce any content test and this flips to 2, which is the drift class that would otherwise turn the fix into a permanent loud no-op" "$RC" "0"

# --- THE RELABEL CROSS: the declared expected survivor, and the isMeta witness -----------------
vl56_relabel() {  # <captured-class>
  vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" \
    '['"$(vl56_owner)"',{"k":"'"$1"'","ts":'"$VL56_INJECT_MS"',"ops":[["set","origin.kind","human"]]},'"$(vl56_asst "$Q_DEFECT")"']'
  vl56_lint "$VL56_TRANSCRIPT" none
}
vl56_relabel task_notification
assert_eq "AC14 DECLARED EXPECTED SURVIVOR (residual iv): under a vendor relabel that stamps a background task notice origin.kind 'human', the predicate goes SILENT -- exit 0. Positive identification necessarily trusts the label it identifies on, and this is the honest cost. EXPIRY, in this message rather than in a comment nobody reads: if this cell ever exits 2, either a structural discriminator has appeared that the predicate should now use, or the fixture no longer constructs the relabel, and this control needs a new subject. Re-derive by re-running the origin.kind census over a fresh corpus" "$RC" "0"
vl56_relabel auto_compaction
assert_eq "AC14 DECLARED EXPECTED SURVIVOR, second class: an auto-compaction continuation under the same relabel also goes silent, for the same reason -- 0 of 22 carry isMeta, so nothing excludes it independently of origin. Same expiry" "$RC" "0"
vl56_relabel voice_lint_refusal
assert_eq "AC14 THE isMeta WITNESS: voice-lint's OWN refusal record under the SAME relabel stays LOUD -- exit 2 -- because isMeta true excludes it independently of origin. This is what 'excluded twice over' buys, and it is the cell that stops a reader deleting the isMeta clause as redundant and reopening the self-disarm. An earlier draft of this survivor record named this record as one of the two that go silent, which was backwards on the single most consequential pair in the whole design" "$RC" "2"
vl56_relabel cross_session_peer
assert_eq "AC14 THE isMeta WITNESS, second class: a cross-session peer message under the same relabel also stays LOUD, because 31 of 31 carry isMeta true" "$RC" "2"
vl56_ac8 "$(vl56_owner "$VL56_INJECT_MS")"
assert_eq "AC14 DISCRIMINATING CONTROL for the relabel cross: a GENUINE owner record in the same position exits 0, so the two survivors above are the predicate trusting a label and not this fixture position being quiet" "$RC" "0"

# ---------------------------------------------------------------------------------------------
suite "#56 AC17/R10: the no-op condition is VISIBLE, and the line is a discriminator not a constant"
# ---------------------------------------------------------------------------------------------
# WHY THIS LINE EXISTS AT ALL. The fail direction here is LOUD, and a loud failure is a nuisance
# nobody reports as a bug. So a fix that has silently degraded to a permanent no-op -- on a client
# predating the origin field (8 of 84 transcripts, 9.5%), or under any future vendor change --
# looks exactly like the control working. When the lint refuses AND no human turn was resolvable,
# the refusal carries one additional fixed line saying so, at the moment output already happens.
#
# THE LINE IS NOT PINNED BY ITS TEXT, deliberately: pinning a literal nobody has written yet
# would be a test of the implementer's phrasing rather than of the behaviour. What is pinned is
# every property the requirement actually states -- it appears only when the boundary is
# unresolvable, it ATTACHES to a refusal and never CREATES one, it is a fixed literal, and no
# byte of the transcript reaches it.
vl56_ac17() {  # <records-json> -> RC/ERR
  vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" "$1"
  vl56_lint "$VL56_TRANSCRIPT" none
}
vl56_extra_lines() {  # lines present in $1 and absent from $2
  printf '%s\n' "$1" | grep -Fxv -f <(printf '%s\n' "$2")
}

vl56_ac17 '[{"k":"tool_result","ts":'"$VL56_PREWRITE_MS"'},'"$(vl56_asst "$Q_DEFECT_A")"']'
VL56_R10_UNRESOLVED_RC="$RC"; VL56_R10_UNRESOLVED="$ERR"
vl56_ac17 '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT_A")"']'
VL56_R10_RESOLVED_RC="$RC"; VL56_R10_RESOLVED="$ERR"
vl56_ac17 '[{"k":"tool_result","ts":'"$VL56_PREWRITE_MS"'},'"$(vl56_asst "$Q_DEFECT_B")"']'
VL56_R10_UNRESOLVED_B="$ERR"

VL56_R10_EXTRA="$(vl56_extra_lines "$VL56_R10_UNRESOLVED" "$VL56_R10_RESOLVED")"
VL56_R10_EXTRA_B="$(vl56_extra_lines "$VL56_R10_UNRESOLVED_B" "$VL56_R10_RESOLVED")"

assert_eq "AC17 PREMISE: both halves of the pair are REFUSALS on the identical dir with the identical fresh record and the identical defective message, so the only difference between their outputs is the boundary" \
  "$VL56_R10_UNRESOLVED_RC/$VL56_R10_RESOLVED_RC" "2/2"
assert_eq "AC17: a refusal produced with NO resolvable human turn carries EXACTLY ONE line the resolved refusal does not, so the fallback is named at the moment output already happens" \
  "$(printf '%s\n' "$VL56_R10_EXTRA" | grep -c . | tr -d ' ')" "1"
assert_eq "AC17 DISCRIMINATION: the resolved refusal carries NOTHING the unresolved one does not, so the line is an addition and not a swap" \
  "$(vl56_extra_lines "$VL56_R10_RESOLVED" "$VL56_R10_UNRESOLVED" | grep -c . | tr -d ' ')" "0"
assert_eq "AC17 R10 NEVER CREATES A REFUSAL, asserted structurally: the added line is not a named-failure bullet, and the named-failure COUNT is identical on both halves. Mutation: push the line onto the failures array instead and this reddens, along with the pre-existing exact-count cell above in this same file" \
  "$(named_failures "$VL56_R10_UNRESOLVED")/$(named_failures "$VL56_R10_RESOLVED")" \
  "$(named_failures "$VL56_R10_RESOLVED")/$(named_failures "$VL56_R10_RESOLVED")"
assert_eq "AC17 FIXED LITERAL: the added line is BYTE-IDENTICAL across two runs whose transcripts differ, which is what 'fixed literal' means operationally" \
  "$VL56_R10_EXTRA" "$VL56_R10_EXTRA_B"
assert_not_contains "AC17: and no byte of the transcript reaches stderr -- a marker string present only in the transcript appears nowhere in the refusal" \
  "$VL56_R10_UNRESOLVED" "$VL56_MARKER_A"
assert_not_contains "AC17: nor does the second marker, on the run whose transcript carries it" \
  "$VL56_R10_UNRESOLVED_B" "$VL56_MARKER_B"
record "REPORTED, not asserted: the R10 line as emitted is [$VL56_R10_EXTRA]. Its WORDING is the implementer's, and pinning it here would make this a test of phrasing; what is asserted above is every property the requirement states about it"

# ---------------------------------------------------------------------------------------------
suite "#56 AC18: the transcript is opened ONCE per invocation, with a control on the instrument"
# ---------------------------------------------------------------------------------------------
# A Stop hook slow enough to be timed out by the harness is a silent disarm in the same direction
# as everything else in this review, and a second full read + split + reverse JSON.parse doubles
# a cost measured at 620 ms on the largest transcript on this machine (69.8 MB, 26,460 records).
#
# THE INSTRUMENT NEEDS ITS OWN CONTROL BEFORE ANY COUNT IS TRUSTED. A counter that is never
# incremented reports 1 for a run that never opened the file at all -- or 0, which reads like a
# broken fixture rather than like a broken instrument. Measured while writing this: patching
# fs.readFileSync IN PROCESS and then `await import()`ing the module does NOT reach a module that
# did `import { readFileSync } from "node:fs"`; it reports a happy zero. A CJS preload does. The
# probe below is what says which of those two this harness is doing.
VL56_COUNT_FILE="$VL56_LEDGER_DIR/readcount"
vl56_count_probe() {  # <times> -> the observed count
  rm -f "$VL56_COUNT_FILE"
  env "VL56_COUNT_PATH=$VL56_TRANSCRIPT" "VL56_COUNT_OUT=$VL56_COUNT_FILE" \
    node -r "$VL56_PRELOAD_CJS" "$VL56_READPROBE_MJS" "$VL56_TRANSCRIPT" "$1" >/dev/null 2>&1
  [[ -f "$VL56_COUNT_FILE" ]] && tr -d ' \n' < "$VL56_COUNT_FILE" || printf '<no-count-file>'
}

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_STALE_MS")" \
  '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"']'
assert_eq "AC18 INSTRUMENT CONTROL, the deliberate 2: a probe module that reads the transcript TWICE through the same \`import { readFileSync } from \"node:fs\"\` idiom voice-lint uses is counted as 2. Without this cell, an 'exactly 1' below is indistinguishable from a counter that never incremented" \
  "$(vl56_count_probe 2)" "2"
assert_eq "AC18 INSTRUMENT CONTROL, the deliberate 1: the same probe reading once is counted as 1, so the instrument discriminates rather than always reporting the number this cell wants" \
  "$(vl56_count_probe 1)" "1"

rm -f "$VL56_COUNT_FILE"
VL56_ENV1="VL56_COUNT_PATH=$VL56_TRANSCRIPT"
VL56_ENV2="VL56_COUNT_OUT=$VL56_COUNT_FILE"
VL56_NODE_ARGS="-r $VL56_PRELOAD_CJS"
vl56_lint "$VL56_TRANSCRIPT" none
VL56_NODE_ARGS=""; VL56_ENV1=""; VL56_ENV2=""
VL56_AC18_READS="$([[ -f "$VL56_COUNT_FILE" ]] && tr -d ' \n' < "$VL56_COUNT_FILE" || printf '<no-count-file>')"
assert_eq "AC18: on a fixture where BOTH derived values are needed -- a resolvable human turn AND a non-empty assistant text -- the transcript is opened exactly once AND the boundary is actually used (the stale record silences the lint). Asserted as ONE value on purpose: today's module already reads once, so 'reads=1' alone passes vacuously against an implementation that derives no boundary at all. Mutation: add a second readFileSync and this goes to reads=2" \
  "rc=$RC/reads=$VL56_AC18_READS" "rc=0/reads=1"

# ---------------------------------------------------------------------------------------------
suite "#56 the NEW stat throw site: a tooling failure in the new code must read fresh-and-LOUD"
# ---------------------------------------------------------------------------------------------
# The explicit-signal branch does readJson only today. Taking the record's mtime there adds a
# statSync that did not exist, and an UNGUARDED one is a throw site whose exception lands in
# main()'s blanket catch and exits 0 SILENTLY -- this change's exact inversion, and the same
# defect class the sibling module shipped and was graded hardest on. The optional-chaining
# requirement does not cover it, because that requirement is scoped to the transcript scan.
#
# The stat is forced to fail through a CJS preload rather than through file permissions, because
# a permission that stops statSync also stops readFileSync, and then the cell would be testing
# the pre-existing readJson failure instead of the new call.
vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_STALE_MS")" \
  '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" claude=4244
assert_eq "STAT GUARD, half 1 (the control): with the stat succeeding, the stale record silences the lint on the explicit-signal branch: exit 0" "$RC" "0"

VL56_ENV1="VL56_STAT_FAIL=status.json"
VL56_NODE_ARGS="-r $VL56_PRELOAD_CJS"
vl56_lint "$VL56_TRANSCRIPT" claude=4244
VL56_NODE_ARGS=""; VL56_ENV1=""
assert_eq "STAT GUARD, half 2: with statSync forced to throw on the resolved record, the SAME fixture exits 2. A stat failure may only ever make the record read maximally fresh, so the silencing branch cannot fire on a tooling failure. Mutation: leave the new statSync unguarded and the exception reaches main()'s blanket catch, flipping this to 0 -- silently, with no output anywhere" "$RC" "2"

# ---------------------------------------------------------------------------------------------
suite "#56 RESIDUAL (ix): the SAME stat failure on the mtime-SCAN branch is SILENT, and that is DECLARED"
# ---------------------------------------------------------------------------------------------
# The guard above covers the NAMED-SIGNAL branch only, and that is not the branch production takes:
# 0 files under plugins/ set CLAUDE_PIPELINE_ACTIVE_ISSUE outside tests, so the mtime SCAN is the
# live path. The scan drops an unstattable candidate (`catch { continue; }`), that line is
# unchanged by #56, and #56 INVERTS WHAT DROPPING COSTS: before, dropping this session's own record
# left a FOREIGN record resolved and the lint refused loudly against it; now the surviving
# candidate is BY CONSTRUCTION older than the turn boundary, so the refusal is SILENCED.
#
# THIS CELL ASSERTS THE DECLARED LIMITATION, NOT A FIX -- the AC16(d) idiom, for the same reason:
# no fix is shipped, so a cell asserting one would be asserting a world that does not exist.
# Residual (ix) in voice-lint.mjs's header carries the DIRECTION (SILENCE), the SCOPE (the likely
# cause of the throw is an ENOENT race against the archival unlink, where silence is the intended
# outcome; the exposure is the narrower EACCES/EPERM/EIO class, where the file EXISTS and cannot
# be stat'd) and the reason the loud alternative is refused (it would make an unreadable FOREIGN
# lane's status.json refuse every message in this session).
#
# THE STDERR BYTE COUNT IS READ FROM THE FILE, not from $ERR, because $ERR is a command
# substitution and strips trailing newlines -- a refusal of nothing but newlines would read as an
# empty string there and pass this cell for the wrong reason.
#
# WHAT THIS BLOCK CATCHES AND THE ONE MUTATION IT IS EXPECTED TO MISS, measured rather than
# predicted, because a battery where everything reddens cannot tell coverage from a rubber stamp:
#   CAUGHT, by 3 of the 4 cells -- the REJECTED fix, `catch { ms = Number.POSITIVE_INFINITY; }`
#   here. The primary cell flips to 2 and BOTH halves of control 2's discrimination redden, the
#   second naming 4-review-complete, which is the foreign lane the header says that fix would
#   start refusing on. The label's claim is falsified by the mutation rather than asserted.
#   CAUGHT, by control 2 -- `catch { break; }`, i.e. abandoning the scan instead of the candidate.
#   SURVIVES, and this is the DOCUMENTED EXPECTED SURVIVOR: `catch { newest = null; newestMs = -1;
#   tiedAtNewest = false; continue; }`, i.e. a stat failure that discards every candidate found so
#   far rather than the one that threw. All 267 cells stay green. THE REASON: these cells pin the
#   OUTCOME of a single-candidate failure, which is what residual (ix) declares, and not the drop's
#   BLAST RADIUS across the candidate set. In the cell that decides survival -- control 2, which
#   throws on 7 -- readdir returns 7 BEFORE 99, so the discard fires with nothing yet collected and
#   is a no-op; the primary cell is a silence under either behaviour. FALSIFYING IT needs a fixture
#   whose FRESH dir is scanned BEFORE the throwing one, so that the discard throws away a winner
#   already in hand.
#   THAT ORDER IS IMPOSABLE, AND WE CHOSE NOT TO IMPOSE IT -- the honest statement, because the
#   suite is not at the filesystem's mercy here: fixtures/voice-lint-56/preload.cjs already patches
#   fs for these very cells, and a readdirSync wrapper beside its statSync one is about ten lines.
#   Built and run rather than asserted: under a forced [99,7] the survivor DIES, control 2 flipping
#   rc 2 -> 0. Left open deliberately anyway, because closing it without declaring a replacement
#   survivor leaves an all-red battery, and a battery where every mutation reddens cannot tell real
#   coverage from a harness that reddens indiscriminately.
#   AND THE CELLS THEMSELVES DO NOT DEPEND ON THAT ORDER, which is the portability question that
#   actually matters, since CI is not this filesystem: against the SHIPPED module all three (ix)
#   scenarios are byte-identical under natural [7,99] and forced [99,7] (rc 2/479 B, rc 0/0 B,
#   rc 2/479 B). Only the survivor's justification was ever order-dependent.
VL56_IX_DIRS='[{"name":"99","phase":"5-archived","mtimeMs":'"$VL56_FRESH_MS"'},{"name":"7","phase":"4-review-complete","mtimeMs":'"$VL56_STALE_MS"'}]'
vl56_ix() {  # <path-substring statSync throws EACCES on> -> RC/ERR/VL56_IX_BYTES
  vl56_fixture "$VL56_IX_DIRS" '['"$(vl56_owner)"','"$(vl56_asst "$Q_REWRITE")"']'
  VL56_ENV1="VL56_STAT_FAIL=$1"
  VL56_NODE_ARGS="-r $VL56_PRELOAD_CJS"
  vl56_lint "$VL56_TRANSCRIPT" none
  VL56_NODE_ARGS=""; VL56_ENV1=""
  VL56_IX_BYTES="$(wc -c < "$VL56_PROJECT/err.txt" | tr -d ' ')"
}

vl56_ix "/99/status.json"
assert_eq "RESIDUAL (ix) DECLARED OPEN RESIDUAL, DIRECTION: SILENCE, a missed check on the session's OWN record. With statSync forced to throw EACCES on 99/status.json ALONE (99 = this session's fresh 5-archived record, 7 = a foreign 72h-stale 4-review-complete, no env signal, an em-dash message), 99 is dropped from the scan, stale 7 wins, and the refusal the same fixture produces with the stat working vanishes: exit 0, ZERO bytes on stderr. EXPIRY, and read residual (ix) before assuming this is a bug: if this cell ever exits 2, either the drop can now tell an unreadable record from an absent one, or the fixture stopped constructing the failure -- and this cell needs a new subject or deletion" \
  "rc=$RC/stderr_bytes=$VL56_IX_BYTES" "rc=0/stderr_bytes=0"

vl56_ix "/nosuchissuedir/status.json"
assert_eq "(ix) CONTROL 1, one variable moved and the PRELOAD STILL LOADED: with the forced failure aimed at a path no candidate has, the identical fixture exits 2. So (ix)'s silence is caused by the dropped stat and not by the preload's mere presence" "$RC" "2"
assert_contains "  and CONTROL 1's refusal names the session's OWN record, which is what (ix) suppresses" "$ERR" 'phase "5-archived"'

vl56_ix "/7/status.json"
assert_eq "(ix) CONTROL 2, the same failure aimed at the FOREIGN candidate: exit 2. Dropping a foreign lane's unreadable record is harmless today, and this is the pair that shows WHY the loud alternative is refused rather than merely asserting that it is. WHAT THIS CELL DOES NOT WITNESS, stated so its green is not read for more than it is worth: 99 wins on mtime whether or not 7 is dropped (it is 71.5 h fresher), so this exit 2 is indistinguishable from a run in which the forced throw never fired at all. That the throw fires is witnessed one cell up, by the PRIMARY cell's rc 2 -> 0 when the same failure is aimed at 99. What THIS cell is, and earns its place as, is a mutation detector: it reddens under both `catch { ms = POSITIVE_INFINITY; }` and `catch { break; }`" "$RC" "2"
assert_contains "  and CONTROL 2 still names 5-archived, i.e. this session's own record wins after the foreign one is dropped" "$ERR" 'phase "5-archived"'
assert_not_contains "  and CONTROL 2 never names the FOREIGN lane's phase -- which is exactly what the rejected fix (force an unstattable candidate to POSITIVE_INFINITY, as statMs does) would make it do: 7 would win with an infinite mtime and this session would be refused on account of a run it does not own" "$ERR" "4-review-complete"

record "REPORTED, because this suite cannot run another commit: the same forced throw on 99 measured against the PRE-#56 code exits 2 naming 4-review-complete, so (ix) is an INVERSION introduced by #56 rather than a limitation inherited from it. That contrast is a measurement, not a claim this suite can keep green"

# ---------------------------------------------------------------------------------------------
suite "#56 RESIDUAL (viii): the shape check refuses BEFORE the transcript is read, and that is declared"
# ---------------------------------------------------------------------------------------------
# R1's outcome property -- no message may be refused on account of an untouched record -- is true
# WITH AN EXCEPTION nobody wrote down until Phase 2.5. phaseShapeFailure returns a refusal before
# the transcript is ever opened, so a STALE or FOREIGN record whose current_phase violates
# status.schema.json's pattern still refuses this session's message. DIRECTION: FALSE REFUSAL,
# i.e. exactly today's behaviour, so this is a coverage limit and not a regression -- the same
# shape as the not-owner-started residual. It is NOT closed by moving the gate earlier: the
# boundary scan is bound to sit after the two unusable-transcript returns so that no unusable
# input acquires a new behaviour, and moving the freshness check above the shape check would make
# the shape-failure path pay a transcript read it does not pay today.
#
# EXPIRY: a freshness signal available before the record's phase is validated.
vl56_fixture "$(vl56_dirs 40 Phase_Three "$VL56_STALE_MS" ',"updated_at":'"$VL56_STALE_MS")" \
  '['"$(vl56_owner)"','"$(vl56_asst "$Q_ORDINARY")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "RESIDUAL (viii): a FOREIGN, stale record with a malformed current_phase still refuses this session's message: exit 2. Pinned so a future reader does not read R1's absolute phrasing and conclude the gate is universal" "$RC" "2"
assert_contains "RESIDUAL (viii): naming the schema it violates, which is what makes this a different refusal from a voice-rule one" "$ERR" "status.schema.json"
vl56_lint "@absent" none
assert_eq "RESIDUAL (viii), and this is what proves the refusal precedes the transcript read rather than merely coinciding with it: the identical fixture with NO transcript_path in the payload at all still exits 2" "$RC" "2"

# ---------------------------------------------------------------------------------------------
suite "#56 AC9: resolveStatus vs the validator's activeIssueDir is an ASSERTED DIVERGENCE TABLE"
# ---------------------------------------------------------------------------------------------
# The old claim in voice-lint.mjs's own header -- that its resolution MIRRORS the validator's --
# is already FALSE at this checkout, so a cell asserting it would pass without asserting
# anything. The two mirror on the newest-mtime FALLBACK branch and DIVERGE on the named-signal
# branch. NO BEHAVIOUR CHANGE IS ASKED FOR: this table pins today's behaviour on both sides.
#
# EVERY CELL CARRIES ITS MTIME-ORDERING PREMISE AS PART OF ITS INPUT, because two outcomes turn
# on it and leaving it to be an accident of the builder is how a cell comes to pass the mutation
# it exists to catch. Nine runs over six inputs: three inputs are run in BOTH arrangements.
#
# THE FIVE AGREEMENT CELLS ARE LOAD-BEARING, NOT FILLER. Without them the table is
# all-divergence and cannot tell a real divergence from a coincidence.
vl56_ac9() {  # <signal> -> the driver's report
  local -a e
  e=(env -u CLAUDE_PIPELINE_ACTIVE_ISSUE -u PIPELINE_ACTIVE_ISSUE)
  case "$1" in
    none) ;;
    claude=*) e+=("CLAUDE_PIPELINE_ACTIVE_ISSUE=${1#claude=}") ;;
    plain=*)  e+=("PIPELINE_ACTIVE_ISSUE=${1#plain=}") ;;
  esac
  "${e[@]}" node "$VL56_AC9_MJS" "$VL56_PROJECT" "$LINT" "$VL56_VALIDATOR" 2>&1
}
vl56_pair() { printf '%s' "$1" | sed -n 's/^VL=//p' | tr -d '\n'; printf '/'; printf '%s' "$1" | sed -n 's/^VAL=//p' | tr -d '\n'; }

VL56_T0="$VL56_NOW"; VL56_T1=$((VL56_NOW - 3600000)); VL56_T2=$((VL56_NOW - 7200000))

vl56_fixture '[{"name":"99","phase":"5-archived","mtimeMs":'"$VL56_T0"'},{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_T1"'}]' '[]'
assert_eq "AC9(a) AGREE, and this is the control that keeps the table from being all-divergence: 99 named and 99 IS the mtime winner, with a good record -> both select 99" \
  "$(vl56_pair "$(vl56_ac9 claude=99)")" "99/99"

vl56_fixture '[{"name":"99","status":"absent"},{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_T1"'}]' '[]'
assert_eq "AC9(b) DIVERGE. PREMISE: the named DIRECTORY exists but holds no status.json, and 7 is the only candidate. CAUSE: resolveStatus falls through when the RECORD is missing; activeIssueDir falls through only when the DIRECTORY is absent -> voice-lint 7, validator 99" \
  "$(vl56_pair "$(vl56_ac9 claude=99)")" "7/99"

vl56_fixture '[{"name":"99","status":"unparseable","mtimeMs":'"$VL56_T0"'},{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_T1"'}]' '[]'
assert_eq "AC9(c1) DIVERGE. PREMISE: the named record is UNPARSEABLE and is ALSO the strict mtime winner, so the scan picks it and it fails to parse a SECOND time -> voice-lint NULL, validator 99. Mutation: parse the named dir's record before the mtime scan rather than after and this flips to 99/99" \
  "$(vl56_pair "$(vl56_ac9 claude=99)")" "NULL/99"

vl56_fixture '[{"name":"99","status":"unparseable","mtimeMs":'"$VL56_T2"'},{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_T0"'}]' '[]'
assert_eq "AC9(c2) DIVERGE, the SAME input in the OTHER arrangement: the named record is unparseable and 7 is the winner -> voice-lint 7, validator 99. Both arrangements of (c) diverge, so its VERDICT is arrangement-independent and only voice-lint's return value moves -- which is exactly why the premise has to be written down rather than inferred from the verdict" \
  "$(vl56_pair "$(vl56_ac9 claude=99)")" "7/99"

vl56_fixture '[{"name":"99","phase":"5-archived","mtimeMs":'"$VL56_T2"'},{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_T0"'}]' '[]'
assert_eq "AC9(d1) DIVERGE. PREMISE: only PIPELINE_ACTIVE_ISSUE is set (no CLAUDE_ prefix) and 99 is NOT the mtime winner. CAUSE: activeIssueName reads input.active_issue, then CLAUDE_PIPELINE_ACTIVE_ISSUE, then PIPELINE_ACTIVE_ISSUE, while run() passes ONLY the CLAUDE_ spelling -> voice-lint 7, validator 99. Mutation: make resolveStatus read the bare spelling too and this cell reddens, which is correct -- the label says the divergence is the thing being pinned" \
  "$(vl56_pair "$(vl56_ac9 plain=99)")" "7/99"

vl56_fixture '[{"name":"99","phase":"5-archived","mtimeMs":'"$VL56_T0"'},{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_T2"'}]' '[]'
assert_eq "AC9(d2) AGREE, the SAME input in the OTHER arrangement, and here the arrangement flips the VERDICT rather than merely the value: 99 IS the mtime winner, so voice-lint takes it by a different route and the two agree. A (d) cell built on this arrangement would pass the mutation above without noticing" \
  "$(vl56_pair "$(vl56_ac9 plain=99)")" "99/99"

vl56_fixture '[{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_T1"'},{"name":"8","phase":"5-archived","mtimeMs":'"$VL56_T1"'}]' '[]'
assert_eq "AC9(e) AGREE: an mtime TIE with no signal -> BOTH abstain to NULL. A tie is the absence of a signal, not a weaker one, and letting readdir order decide would make 'which issue is active' a property of the filesystem" \
  "$(vl56_pair "$(vl56_ac9 none)")" "NULL/NULL"

vl56_fixture '[{"name":"exp-abc","phase":"5-archived","mtimeMs":'"$VL56_T0"'},{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_T1"'}]' '[]'
assert_eq "AC9(f1) AGREE: an exp-<slug> dir is admitted by BOTH derivations on the no-signal branch -> both select exp-abc. Experiment runs are GUARDED, not exempt" \
  "$(vl56_pair "$(vl56_ac9 none)")" "exp-abc/exp-abc"

vl56_fixture '[{"name":"exp-abc","phase":"5-archived","mtimeMs":'"$VL56_T2"'},{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_T0"'}]' '[]'
assert_eq "AC9(f2) AGREE: an exp-<slug> slug NAMED while 7 is the mtime winner -> both select exp-abc, so the named branch admits the same vocabulary the scan does" \
  "$(vl56_pair "$(vl56_ac9 claude=exp-abc)")" "exp-abc/exp-abc"

record "REPORTED, so the table's SHAPE is itself on the record: 9 runs over 6 inputs, 4 DIVERGE (b, c1, c2, d1) and 5 AGREE (a, d2, e, f1, f2). Each divergence carries its cause in its own label, so a future change that closes or widens one reddens a cell whose label explains why it existed"

# THE CALL SITE, OBSERVED THROUGH THE REAL CLI RATHER THAN REPRODUCED IN A DRIVER. Found by
# running the mutation battery over this contract before handing it over: the AC9 driver passes
# `process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE` to resolveStatus itself, which is a RESTATEMENT of
# run()'s choice of spelling rather than an observation of it -- so widening run() to read the
# bare PIPELINE_ACTIVE_ISSUE too left all nine AC9 cells green. That mutation is the one AC9(d1)
# names in its own label, and until this cell existed nothing could see it.
#
# PREMISE, carried inside the cell as AC9's own cells now carry theirs: 7 is the mtime winner and
# 99 is NOT, both records are fresh relative to the boundary so the lint fires either way, and
# the two dirs carry DIFFERENT phases so the refusal names which one was selected.
vl56_fixture '[{"name":"99","phase":"2.5-design-owner-decision","mtimeMs":'"$VL56_INJECT_MS"'},{"name":"7","phase":"5-archived","mtimeMs":'"$VL56_LATER_MS"'}]' \
  '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" plain=99
assert_contains "AC9 THE CALL SITE: with only the bare PIPELINE_ACTIVE_ISSUE set, run() ignores it and the refusal names the MTIME WINNER's phase" "$ERR" "5-archived"
assert_not_contains "AC9 THE CALL SITE, the discriminating half: and it does NOT name the phase of the dir the bare spelling pointed at. Mutation: widen run() to read PIPELINE_ACTIVE_ISSUE as well and BOTH halves flip at once" "$ERR" "2.5-design-owner-decision"

# ---------------------------------------------------------------------------------------------
suite "#56 AC6: every pre-existing verdict is unchanged, on BOTH resolution branches"
# ---------------------------------------------------------------------------------------------
# THE ANTI-VACUITY GUARD ON THE WHOLE CHANGE, and the measurement that says why it is replayed on
# two branches rather than one. Of the 65 assert_ lines already in this file, 56 follow the
# lint() helper, which unconditionally exports CLAUDE_PIPELINE_ACTIVE_ISSUE, and only 5 follow
# exp_lint_nosignal -- the ONLY pre-existing exercise of the mtime-fallback branch, which is the
# branch measured to be the only live path in production. Those 5 also all sit in one root
# holding a single issue dir, so none exercises multi-dir resolution or a stale record.
#
# SECOND, AND THIS IS THE DISJUNCT THE PRE-EXISTING CELLS CANNOT SEPARATE: set_phase() writes
# status.json at test time, so every pre-existing cell is BOTH fresh AND has no user record at
# all. The cell is satisfied twice over and cannot say which disjunct kept it green. The last
# cell in this suite makes the record STALE while the transcript still has no human turn, so
# "no usable human turn -> fire" is witnessed on its own.
#
# MUTATION: treat an unresolvable human-turn boundary as STALE, and every exit-2 row below flips
# to 0 at once, on BOTH branches. That is why this is asserted over the whole table twice rather
# than over a representative cell.
make_temp_project "$ISSUE" || exit 90
TRANSCRIPT="$TEMP_PROJECT/transcript.jsonl"

# The twin of this file's own lint(), differing in ONE thing: no active-issue signal, which is
# the shape production runs in.
lint_nosignal() {
  local extra="${1:-}"
  local payload="{\"cwd\":\"$TEMP_PROJECT\",\"transcript_path\":\"$TRANSCRIPT\"$extra}"
  local errf="$TEMP_PROJECT/err.txt"
  printf '%s' "$payload" \
    | ( cd "$TEMP_PROJECT" && env -u CLAUDE_PIPELINE_ACTIVE_ISSUE -u PIPELINE_ACTIVE_ISSUE \
        CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$LINT" ) 2>"$errf" >/dev/null
  RC=$?
  ERR=$(cat "$errf")
}

vl56_replay() {  # <phase> <message> <expected-rc> <label>
  set_phase "$1"
  write_transcript "$2"
  lint
  assert_eq "AC6 [signal branch] $4" "$RC" "$3"
  lint_nosignal
  assert_eq "AC6 [mtime-fallback branch, byte-identical fixture] $4" "$RC" "$3"
}

vl56_replay "3-impl" "Refactored the parser — it now handles the nested case — and tests pass." 0 \
  "a NON-voice phase is silent, em dashes and all. THE CASE THIS CONTROL LIVES OR DIES ON: if this ever blocks, the lint is unusable and gets turned off"
vl56_replay "2-review" "Dispatched three reviewers." 0 "another non-voice phase is silent too"
vl56_replay "2.5-design-owner-decision" "I picked approach B because it is cleaner. Moving on to implementation." 2 \
  "a decision moment with no decision block still exits 2"
vl56_replay "2.5-design-owner-decision" "$GOOD_DECISION" 0 "the same moment WITH the block still exits 0"
vl56_replay "2.5-design-owner-decision" "$GOOD_DECISION — with an em dash" 2 "an em dash at a voice moment still exits 2"
vl56_replay "1-ba-open-questions" "BA raised a question about scope. I went with the recommendation." 2 \
  "the open-questions gate is still a voice moment"
vl56_replay "5-archived" "### Done

**Blast radius:** Contained
**Reversibility:** Undo button
**Confidence:** Solid" 2 "a completion report with no replication block still exits 2"
vl56_replay "5-archived" "$ALL_SHAPES" 0 "a complete report still exits 0"
vl56_replay "Phase_Three" "anything at all" 2 "a malformed current_phase still exits 2"
vl56_replay "0-setup" "$EM_DASH_NO_BLOCKS" 0 "a DECLARED non-voice phase is still silent"
vl56_replay "3-impl-nonesuch" "$EM_DASH_NO_BLOCKS" 0 \
  "THE DISCRIMINATING ROW: a shape-VALID, UNDECLARED, non-error phase is still the documented fail-open"
vl56_replay "halted-error" "$EM_DASH_NO_BLOCKS" 2 "halted-error is shape-valid and still exits 2 through errorMoment"
vl56_replay "9-invented" "$EM_DASH_NO_BLOCKS" 2 "9-invented still exits 2 for a different reason again -- it is shape-INVALID"
vl56_replay "3-invented-phase" "no block, em dashes — everywhere" 0 \
  "RESIDUAL LIMIT: a well-formed unlisted phase is still not linted"

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_STALE_MS")" '['"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_eq "AC6 THE ISOLATED DISJUNCT: a STALE record whose transcript carries no human turn at all still exits 2. Every pre-existing cell satisfies its verdict twice over (fresh record AND no user record), so this is the only place 'no usable human turn -> fire' is witnessed on its own" "$RC" "2"

# ---------------------------------------------------------------------------------------------
suite "#56 AC11/AC12: the process contract, and the suite's own hygiene"
# ---------------------------------------------------------------------------------------------
assert_eq "AC11: across every cell in this block the ONLY exit codes observed are 0 and 2. Asserted as the SET, and as the code rather than 'non-zero': change the refusal code to 1 and stop.sh stops blocking while a non-zero assertion would stay green" \
  "$(sort -u "$VL56_RC_LOG" | tr '\n' ' ' | sed 's/ *$//')" "0 2"
record "REPORTED, so the cell above cannot be an assertion over an empty population: $(grep -c . "$VL56_RC_LOG" | tr -d ' ') exit codes were observed by this block"

vl56_fixture "$(vl56_dirs 4244 5-archived "$VL56_FRESH_MS")" '['"$(vl56_owner)"','"$(vl56_asst "$Q_DEFECT")"']'
vl56_lint "$VL56_TRANSCRIPT" none
assert_contains "AC11: a #56-shaped refusal still points at voice.md" "$ERR" "voice.md"
assert_contains "AC11: and still offers the documented bypass" "$ERR" "CLAUDE_HOOK_STOP_SKIP=1"
vl56_lint "$VL56_TRANSCRIPT" none ',"stop_hook_active":true'
assert_eq "AC11: stop_hook_active still short-circuits to 0 on a fixture that would otherwise refuse, so a stubborn message cannot loop" "$RC" "0"

VL56_SELFTEST_PINNED="$(grep -o 'it actually ran its cases ([0-9]*)' "$VL56_SUITE_FILE" | head -1 | tr -dc '0-9')"
VL56_SELFTEST_LIVE="$(node "$LINT" --self-test 2>&1 | sed -n 's/^self-test: \([0-9]*\) passed.*/\1/p')"
assert_eq "AC11: the self-test case count pinned in this file is RE-DERIVED from a run rather than incremented by hand, so adding a selfTest case without updating that literal is named here as well as at the assertion that carries it" \
  "$VL56_SELFTEST_PINNED" "$VL56_SELFTEST_LIVE"
record "REPORTED as a PHASE-4 DIFF OBLIGATION rather than asserted, because the only in-tree way to assert it is a range against a moving ref, which is the thing the cell below forbids: hooks/stop.sh and commands/pipeline.md must be untouched by this change, and status.schema.json, VOICE_MOMENTS, NON_VOICE_PHASES and gate-phase-entry.mjs with them"

# AC12: the POPULATION is the whole of this suite and its fixture helpers, and the assertion is
# the reported hit LIST rather than a count -- a cell added and another removed cannot cancel.
VL56_HYGIENE="$(node "$VL56_HYGIENE_MJS" "$VL56_SUITE_FILE" "$VL56_BUILD_MJS" "$VL56_CLASSIFY_MJS" \
  "$VL56_AC9_MJS" "$VL56_PRELOAD_CJS" "$VL56_READPROBE_MJS" "$VL56_HYGIENE_MJS" 2>&1)"
assert_eq "AC12: no cell in this suite, and no line of its fixture helpers, reads the repository's own pipeline state directory, resolves a range, or names the default remote branch ref. The hit LIST is asserted and not a count, so a cell added and another removed cannot cancel. The scanner is included in its OWN input list -- a scanner excluded from its own population is a scanner nobody checks" \
  "$VL56_HYGIENE" ""
# The bait is COMPOSED rather than written as a literal, or this line would itself be a hit and
# the cell above would redden on its own control. Same reason the scanner composes its patterns.
printf 'cat ./.%s/56/status.json\n%s diff %s/main\n' "pipeline" "git" "origin" > "$VL56_LEDGER_DIR/bait.sh"
assert_eq "AC12 CONTROL on the scanner, so an empty hit list is a FINDING and not an inert program: fed two bait lines it reports all three violation classes, by name and by line" \
  "$(node "$VL56_HYGIENE_MJS" "$VL56_LEDGER_DIR/bait.sh" 2>&1)" \
  "bait.sh:1:reads-an-unrooted-state-dir ;; bait.sh:2:names-a-moving-ref ;; bait.sh:2:resolves-a-range"

# ---------------------------------------------------------------------------------------------
suite "#56 R8: every mtime this block stamped was READ BACK and landed where it was aimed"
# ---------------------------------------------------------------------------------------------
# A stamp that silently no-ops leaves the record at "now" and reddens a distant cell for entirely
# the wrong reason -- pointing a reader at the predicate when the fault is in the fixture. The
# builder reads every stamp back; this is where the ledger of those read-backs is asserted.
#
# utimesSync, never `touch -t`: BSD touch on macOS has no `-d @<epoch>` form and GNU touch on
# ubuntu-latest does, so the obvious bash idiom is a fixture that passes in CI and fails on the
# author's machine; and `touch -t` takes a LOCAL-clock value while transcript timestamps are UTC
# ISO, so a fixture mixing the two measures the runner's timezone (a 13:41 local stamp produced a
# 17:41Z mtime on the author's machine).
VL56_STAMPS_TAKEN="$(grep -c . "$VL56_STAMP_LOG" | tr -d ' ')"
VL56_WORST_DRIFT="$(sed 's/deltaMs=//' "$VL56_STAMP_LOG" | sort -rn | head -1)"
record "REPORTED, so the assertion below cannot range over an empty population: $VL56_STAMPS_TAKEN mtime stamps were applied and read back by this block"
assert_eq "R8 ANTI-VACUITY: this block actually stamped mtimes, rather than asserting a clean ledger it never wrote to" \
  "$([[ "${VL56_STAMPS_TAKEN:-0}" -gt 40 ]] && echo "stamped" || echo "SUSPICIOUSLY FEW STAMPS: $VL56_STAMPS_TAKEN")" "stamped"
assert_eq "R8: the WORST read-back drift across every stamp this block applied is 0 ms. A tolerance is stated rather than assumed, and the measurement is reported above" \
  "$([[ "${VL56_WORST_DRIFT:-999}" -le 2 ]] && echo "within-2ms" || echo "DRIFTED $VL56_WORST_DRIFT ms")" "within-2ms"

finish
