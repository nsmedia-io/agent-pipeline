#!/usr/bin/env bash
# gate-phase-entry.mjs -- the drift tests, and the prose the guard is pinned to.
#
# WHY THESE ARE IMPORTS AND SET OPERATIONS, NOT GREPS. voice-lint.mjs records what the
# alternative cost: its first phase table was written from memory, invented four phases nothing
# writes and missed two real ones, and its drift test is `grep -q "\"$phase\"" "$LINT_SRC"` --
# a substring grep that a phase named in a COMMENT satisfies and that cannot tell a table key
# from a mention. The guard is a module, so this suite IMPORTS it and asserts set membership
# over its exported sets. Counting uses `grep -o ... | wc -l`, never `grep -c`, which counts
# LINES and would silently lower a count if two occurrences shared one.
#
# AND WHY THERE IS A SECOND GROUND TRUTH (in the sibling suite, AC19). Prose alone is provably
# insufficient, and this repo paid for the lesson: until #42, status.schema.json:13's own
# description named `3-scope-drift-adjudication` and `3-impl-verification-unverified`, which
# pipeline.md wrote NEITHER of, and omitted six literals it did write. A vocabulary in this repo
# HAD rotted, in the one file no prose-derived test read. That list is corrected and now carries
# a set-equality test of its own (test-status-schema-contract.sh), so it is history rather than
# live evidence -- but the argument it paid for stands: a hand-maintained second copy of a
# vocabulary rots silently unless something compares it to the first.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

GUARD="$SCRIPTS_DIR/gate-phase-entry.mjs"
PIPELINE_MD="$PLUGIN_ROOT/commands/pipeline.md"
PHASE_MD="$PLUGIN_ROOT/commands/phase.md"
STOP_SH="$HOOKS_DIR/stop.sh"

# derive <sets-json-or-MODULE> -> a JSON report over the pipeline.md ground truth.
# Passing MODULE reads the four sets from the guard's exports; passing a JSON object of the
# same shape runs the IDENTICAL derivation over a synthetic assignment, which is what makes
# AC18(vii)'s detectability control a control rather than a claim.
derive() {
  node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const [mdPath, guardPath, setsArg] = process.argv.slice(1);
    const names = ["ENTRY", "EXIT", "UNGUARDED", "TERMINAL", "PRELUDE"];
    let sets;
    if (setsArg === "MODULE") {
      const m = await import(guardPath);
      sets = {};
      for (const n of names) sets[n] = m[n];
    } else {
      sets = JSON.parse(setsArg);
    }
    const md = readFileSync(mdPath, "utf8");
    // THE WIDE FORM, and it is the ONE extraction this suite performs (#53 R1/AC1). It claims
    // BOTH quoting styles the writer uses -- the bare `current_phase: "..."` and the JSON
    // `"current_phase": "..."` -- because the population of a coverage check must equal its
    // SUBJECT. The strict form this replaced claimed only the first, so this suite derived 25
    // concrete literals from a file that writes 26, and `0-setup` was invisible to the
    // assertion AND to the control, which ranged over the same narrowed set: a phase the
    // pattern cannot see is not an unaccounted phase, it is not a phase at all.
    // THE RULE NOW IN FORCE: the derivation matches the WRITER, and the bare-word TRI-PARTITION
    // below is what holds it to that -- every occurrence of the bare word `current_phase` is
    // forced into a named bucket, so no future assignment spelling can leave the population in
    // silence. The sibling copy in the voice-lint suite pins the SAME label set; re-derive both
    // with `git grep -n "THE WIDE FORM" -- plugins/pipeline/tests`. No line range is cited into
    // another shipped file: a coordinate pin rots the moment its subject is edited (#68).
    const literals = [...new Set([...md.matchAll(/"?current_phase"?: *"([^"]*)"/g)].map((m) => m[1]))]
      .filter((p) => p !== "<phase>-error");
    const counts = {}; const seen = new Map(); const dupes = [];
    const shapes = []; const emptyCells = [];
    for (const n of names) {
      const v = sets[n];
      shapes.push(n + "=" + (v === undefined ? "ABSENT"
        : Array.isArray(v) ? "Array" : v instanceof Set ? "Set" : typeof v));
      // The pre-existing idiom, left as it is by scope. It is CORRECT for an Array cell and
      // silently yields an EMPTY population for a Set one, which is why `emptyCells` below
      // exists: notInMd is computed FROM these cells, so an empty cell makes it green having
      // compared nothing.
      const arr = Array.isArray(sets[n]) ? sets[n] : [];
      counts[n] = arr.length;
      if (!Array.isArray(v) || v.length === 0) emptyCells.push(n);
      for (const p of arr) {
        if (seen.has(p)) dupes.push(p + " in " + seen.get(p) + " and " + n);
        else seen.set(p, n);
      }
    }
    const unassigned = literals.filter((p) => !seen.has(p));
    const notInMd = [...seen.keys()].filter((p) => !literals.includes(p));
    // AC9: the `-complete` sub-derivation is taken from the SAME single extraction above,
    // never a second narrow grep of its own.
    const complete = literals.filter((p) => p.endsWith("-complete")).sort();
    const exitArr = Array.isArray(sets.EXIT) ? sets.EXIT : [];
    process.stdout.write(JSON.stringify({
      literalCount: literals.length,
      literals: [...literals].sort().join(","),
      shapes: shapes.join(" "),
      preludeMembers: (Array.isArray(sets.PRELUDE) ? [...sets.PRELUDE].sort() : []).join(","),
      completeLiterals: complete.join(","),
      counts, dupes, unassigned, notInMd, emptyCells,
      completeNotInExit: complete.filter((p) => !exitArr.includes(p)),
    }));
  ' "$PIPELINE_MD" "$GUARD" "${1:-MODULE}" 2>/dev/null
}

# field/num return an explicit <no-report> marker rather than an empty string when the report
# itself is missing. Without that, every "expected: (empty)" assertion below passes VACUOUSLY
# the moment the derivation cannot run -- which is precisely the state this contract is
# authored in. An absence assertion that cannot tell "nothing wrong" from "nothing measured"
# is not an assertion.
field() {
  [[ -n "$1" ]] || { printf '<no-report>'; return; }
  case "$1" in *"\"$2\":"*) ;; *) printf '<no-field:%s>' "$2"; return ;; esac
  printf '%s' "$1" | sed -n "s/.*\"$2\":\\[\\([^]]*\\)\\].*/\\1/p"
}
num()   { printf '%s' "$1" | sed -n "s/.*\"$2\":\\([0-9]*\\).*/\\1/p"; }
# strfield: the STRING-valued siblings of field(). Same <no-report>/<no-field> discipline, for
# the same reason -- a label-set assertion whose report never arrived must say so rather than
# compare "" against "".
strfield() {
  [[ -n "$1" ]] || { printf '<no-report>'; return; }
  case "$1" in *"\"$2\":"*) ;; *) printf '<no-field:%s>' "$2"; return ;; esac
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p"
}

# THE PINNED LABEL SET (#33, and #53 AC1). Never a bare count: a count is discharged by editing
# one digit, and the edit that absorbs a legitimate new phase is the same edit that absorbs a
# phase nobody declared -- which is exactly how `literalCount == 25` shipped green over a writer
# that writes 26. Derived ONCE by RUNNING the extraction above and pasted, so a new literal
# forces the editor to paste the LABEL. The voice-lint suite pins this identical list, so a
# narrowing in either copy reddens in that copy.
PHASE_LITERALS_26='0-setup,0.5-map,0.5-map-complete,1-ba,1-ba-complete,1-ba-open-questions,1-ba-rework-required,2-constraints,2-constraints-complete,2-review,2-review-complete,2.5-design,2.5-design-complete,2.5-design-owner-decision,3-impl,3-impl-complete,3-impl-frontend-gate-failed,3-impl-gate-failed,3-impl-live-verify-unverified,3-impl-tripwire,3-impl-tripwire-indeterminate,4-review,4-review-complete,4-veto-rework-required,5-archive,5-archived'
COMPLETE_LITERALS_7='0.5-map-complete,1-ba-complete,2-constraints-complete,2-review-complete,2.5-design-complete,3-impl-complete,4-review-complete'

REPORT="$(derive MODULE)"

# ---------------------------------------------------------------------------
suite "AC18(vi): VACUITY CONTROL -- the derivation found a population at all"
# ---------------------------------------------------------------------------
LIT_N="$(num "$REPORT" literalCount)"
assert_eq "the pipeline.md derivation found at least 20 current_phase literals" \
  "$([[ "${LIT_N:-0}" -ge 20 ]] && echo enough || echo "ONLY ${LIT_N:-<no-report>}")" "enough"
# THE SET, not the count (#53 AC1). `literalCount == 25` sat here and was green over a
# 25-literal population derived from a 26-literal file, because assertion and control ranged
# over the same narrowed set. The count survives only as the vacuity floor above.
assert_eq "and the derived label SET is exactly the 26 concrete literals pipeline.md writes, \`0-setup\` among them" \
  "$(strfield "$REPORT" literals)" "$PHASE_LITERALS_26"

# ---------------------------------------------------------------------------
suite "AC18(i)/#53 AC6: the partition cells cover the 26 literals, in both directions"
# ---------------------------------------------------------------------------
# A partition is strictly stronger than a union check, and it is what makes 'decided' tellable
# from 'forgot' in BOTH directions: a literal in two sets fails, and a literal in none fails.
assert_eq "the sets are pairwise DISJOINT" "$(field "$REPORT" dupes)" ""
assert_eq "every pipeline.md literal is assigned to exactly one set" "$(field "$REPORT" unassigned)" ""
assert_eq "and no set names a phase pipeline.md does not write" "$(field "$REPORT" notInMd)" ""

# --- the SHAPE of what the partition read, asserted BEFORE anything is concluded from it -----
#
# #53 AC4(iii)/R4(b). `notInMd` and the disjointness walk are computed FROM these cells, so an
# ABSENT cell (a mistyped export name), an EMPTY cell, or a Set where an Array is expected makes
# them green having compared nothing. MEASURED, and the reason this sits here rather than at the
# diagonals: with every cell emptied, `notInMd` is [] and GREEN, while `unassigned` names all 26
# literals and is loudly RED -- so the vacuity lives in the table-as-population direction ONLY,
# and this is where the assertion belongs. The two cells below are the ones that NAME it.
assert_eq "every partition cell reads back as a NON-EMPTY Array (an ABSENT, empty or Set-shaped cell makes notInMd green having compared nothing)" \
  "$(field "$REPORT" emptyCells)" ""
assert_eq "and the guard exports a fifth cell PRELUDE that this partition READS BY NAME -- a mistyped export resolves to ABSENT here, with the typo named, instead of to an unrelated red elsewhere" \
  "$(strfield "$REPORT" shapes)" "ENTRY=Array EXIT=Array UNGUARDED=Array TERMINAL=Array PRELUDE=Array"
assert_eq "PRELUDE declares exactly \`0-setup\`: the run's setup step, which is a real occupied phase and belongs in no other cell (a PREREQUISITES row is refused by AC18(ii) below, and UNGUARDED's own reason -- \"a halt or rework state\" -- is not true of it)" \
  "$(strfield "$REPORT" preludeMembers)" "0-setup"

# --- and the CONTROL that proves those two cells are the ones doing that work ----------------
CTRL_EMPTY='{"ENTRY":[],"EXIT":[],"UNGUARDED":[],"TERMINAL":[],"PRELUDE":[]}'
CTRL_EMPTY_REPORT="$(derive "$CTRL_EMPTY")"
assert_eq "TABLE-AS-POPULATION VACUITY, measured: with every cell EMPTIED, \`notInMd\` is still empty and still GREEN -- the diagonal cannot see an empty table" \
  "$(field "$CTRL_EMPTY_REPORT" notInMd)" ""
assert_contains "  and the shape-and-non-emptiness cell above is what DOES see it, naming every empty cell" \
  "$(field "$CTRL_EMPTY_REPORT" emptyCells)" "PRELUDE"
assert_contains "  PAIRED, so this is not a one-sided reading: the OTHER direction is not blind either -- an emptied table makes \`unassigned\` name all 26 literals, loudly" \
  "$(field "$CTRL_EMPTY_REPORT" unassigned)" "0-setup"
CTRL_MISTYPED='{"ENTRY":["3-impl"],"EXIT":["3-impl-complete"],"UNGUARDED":["3-impl-tripwire"],"TERMINAL":["5-archived"],"PRELUDEE":["0-setup"]}'
assert_contains "  and a MISTYPED fifth-cell name is diagnosed as an ABSENT cell rather than left for a reader to infer from an unrelated \`unassigned\` red" \
  "$(strfield "$(derive "$CTRL_MISTYPED")" shapes)" "PRELUDE=ABSENT"

# ---------------------------------------------------------------------------
suite "AC18(vii): DETECTABILITY CONTROL -- the same derivation reports a planted miss"
# ---------------------------------------------------------------------------
# Without this, three green assertions above are indistinguishable from a derivation that
# reports nothing at all. The control runs the SAME code over a deliberately broken assignment.
CTRL_MISS='{"ENTRY":["0.5-map","1-ba","2-constraints","2-review","2.5-design","3-impl","4-review"],"EXIT":["0.5-map-complete","1-ba-complete","2-constraints-complete","2-review-complete","2.5-design-complete","3-impl-complete","4-review-complete"],"UNGUARDED":["1-ba-open-questions","1-ba-rework-required","2.5-design-owner-decision","3-impl-frontend-gate-failed","3-impl-gate-failed","3-impl-live-verify-unverified","3-impl-tripwire","3-impl-tripwire-indeterminate","4-veto-rework-required"],"TERMINAL":["5-archived"]}'
CTRL_REPORT="$(derive "$CTRL_MISS")"
assert_contains "a literal placed in NO set is reported as unassigned" \
  "$(field "$CTRL_REPORT" unassigned)" "5-archive"
CTRL_DUPE='{"ENTRY":["3-impl"],"EXIT":["3-impl"],"UNGUARDED":[],"TERMINAL":[]}'
assert_contains "a literal placed in TWO sets fails disjointness" \
  "$(field "$(derive "$CTRL_DUPE")" dupes)" "3-impl"

# ---------------------------------------------------------------------------
suite "AC18(ii)/#53 AC8: ENTRY equals the SET of phases pipeline.md checkpoints into"
# ---------------------------------------------------------------------------
# BOTH DIRECTIONS, EACH REPORTED BY NAME, and asserted as a SET rather than as a count. The
# count assertion that stood here (`8 'Checkpoint first' occurrences` == `|ENTRY|`) is now a
# `record`: pipeline.md already describes loop-backs re-entering Phases 2 and 3, so a SECOND
# Checkpoint-first site for an EXISTING phase takes the occurrence count to 9 while ENTRY
# correctly stays 8 -- measured on a copy, the count assertion goes RED on a correct table
# while the set assertion stays GREEN in both directions.
#
# THIS IS THE ASSERTION THAT REFUSES A `PREREQUISITES` ROW FOR `0-setup` (#53 R4). ENTRY is
# DERIVED from PREREQUISITES keys, and `0-setup` is written at no Checkpoint-first site, so a
# planted row surfaces here as `entryNotCp: ["0-setup"]` rather than being absorbed.
#
# The Checkpoint-first literals come out of the SAME wide pattern the derivation uses (#53 R1's
# third strict copy, folded in), and a Checkpoint-first line yielding NO literal is identified
# by its LINE NUMBER AND ITS TEXT -- not by a constant `<no-literal-on-line>` placeholder, which
# collapses N such lines into N indistinguishable tokens a reader cannot locate.
CP_REPORT="$(node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const [mdPath, guardPath] = process.argv.slice(1);
  const md = readFileSync(mdPath, "utf8");
  const WIDE = /"?current_phase"?: *"([^"]*)"/g;
  const sites = []; const noLit = []; const lits = new Set();
  md.split("\n").forEach((l, i) => {
    if (!l.includes("Checkpoint first")) return;
    sites.push(i + 1);
    const found = [...l.matchAll(WIDE)].map((m) => m[1]);
    if (found.length === 0) noLit.push((i + 1) + ": " + l.trim().replace(/\s+/g, " ").slice(0, 90));
    for (const f of found) lits.add(f);
  });
  const m = await import(guardPath);
  const entry = Array.isArray(m.ENTRY) ? [...m.ENTRY] : [];
  const cp = [...lits].sort();
  process.stdout.write(JSON.stringify({
    siteCount: sites.length,
    cpSet: cp.join(","),
    entrySet: entry.slice().sort().join(","),
    cpNotEntry: cp.filter((x) => !entry.includes(x)),
    entryNotCp: entry.filter((x) => !lits.has(x)),
    noLiteralSites: noLit,
  }));
' "$PIPELINE_MD" "$GUARD" 2>/dev/null)"

CP_ENTRY_SET_8='0.5-map,1-ba,2-constraints,2-review,2.5-design,3-impl,4-review,5-archive'
record "REPORTED, not asserted: pipeline.md holds $(num "$CP_REPORT" siteCount) 'Checkpoint first' occurrences (grep -o | wc -l semantics, never grep -c). A second site for an EXISTING phase is legitimate and moves this number without moving the set"
assert_eq "the SET of phases pipeline.md checkpoints into is the eight it names" \
  "$(strfield "$CP_REPORT" cpSet)" "$CP_ENTRY_SET_8"
assert_eq "and the guard's exported ENTRY set is the same eight" \
  "$(strfield "$CP_REPORT" entrySet)" "$CP_ENTRY_SET_8"
assert_eq "  direction 1, by name: every Checkpoint-first phase IS an ENTRY key" \
  "$(field "$CP_REPORT" cpNotEntry)" ""
assert_eq "  direction 2, by name: and ENTRY names no phase pipeline.md never checkpoints into -- this is what refuses a PREREQUISITES row for \`0-setup\`, which is written at no Checkpoint-first site" \
  "$(field "$CP_REPORT" entryNotCp)" ""
assert_eq "  a Checkpoint-first line yielding NO literal is reported by LINE and TEXT, never as an anonymous placeholder" \
  "$(field "$CP_REPORT" noLiteralSites)" ""

# ---------------------------------------------------------------------------
suite "AC18(iii)/#53 AC9: every <phase>-complete literal pipeline.md writes is an EXIT key"
# ---------------------------------------------------------------------------
# The `-complete` sub-derivation is taken from the SAME single wide extraction (#53 R1's fourth
# strict copy, folded in). A form fix with an empty residual: strict and wide both yield the
# same seven, which is why the criterion pins the SET rather than the number 7.
assert_eq "|EXIT| is 7" "$(num "$REPORT" EXIT)" "7"
assert_eq "and the -complete label SET the wide derivation yields is unchanged by the widening" \
  "$(strfield "$REPORT" completeLiterals)" "$COMPLETE_LITERALS_7"
assert_eq "no -complete literal is missing from EXIT" "$(field "$REPORT" completeNotInExit)" ""

# ---------------------------------------------------------------------------
suite "AC18(iv): the satisfying token sets REFERENCE the registry, they do not restate it"
# ---------------------------------------------------------------------------
# This is what keeps the phase-vocabulary table count at three. Every token in every row's set,
# at every tier, must be a member of the IMPORTED KNOWN_PHASES -- imported, never grepped.
TOKEN_REPORT="$(node --input-type=module -e '
  const g = await import(process.argv[1]);
  const { KNOWN_PHASES } = await import(process.argv[2]);
  const tiers = ["trivial", "standard", "architectural"];
  const strays = []; let tokens = 0;
  for (const phase of [...g.ENTRY, ...g.EXIT]) {
    for (const tier of tiers) {
      const set = g.satisfyingTokens(phase, tier);
      if (!Array.isArray(set)) { strays.push(phase + "@" + tier + ":not-an-array"); continue; }
      for (const t of set) {
        tokens++;
        if (!KNOWN_PHASES.includes(t)) strays.push(phase + "@" + tier + ":" + t);
      }
    }
  }
  process.stdout.write(JSON.stringify({ tokens, strays }));
' "$GUARD" "$SCRIPTS_DIR/dispatch-model.mjs" 2>/dev/null)"
assert_eq "every satisfying token is a member of the imported KNOWN_PHASES" \
  "$(field "$TOKEN_REPORT" strays)" ""
TOK_N="$(num "$TOKEN_REPORT" tokens)"
assert_eq "VACUITY CONTROL: the walk actually saw tokens (>=15)" \
  "$([[ "${TOK_N:-0}" -ge 15 ]] && echo enough || echo "ONLY ${TOK_N:-<no-report>}")" "enough"

# ---------------------------------------------------------------------------
suite "AC18(v): the guard declares no fourth vocabulary and no shape regex of its own"
# ---------------------------------------------------------------------------
assert_eq "the module exports no KNOWN_PHASES of its own" \
  "$(node --input-type=module -e 'const m=await import(process.argv[1]);process.stdout.write(m.KNOWN_PHASES===undefined?"absent":"DECLARED")' "$GUARD" 2>/dev/null || printf '<import-failed>')" \
  "absent"
# The source check strips comments FIRST. If a phrase in a comment can redden this, the
# assertion is a source grep and has regressed to the shape this suite exists to replace.
SRC_REPORT="$(node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const raw = readFileSync(process.argv[1], "utf8");
  const code = raw.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^[ \t]*\/\/.*$/gm, "");
  const hits = [];
  if (/\bstartsWith\s*\(/.test(code)) hits.push("startsWith");
  if (/const\s+KNOWN_PHASES\s*=/.test(code)) hits.push("local KNOWN_PHASES");
  if (/\/\^?\(?\[0-5\]/.test(code)) hits.push("phase-shape regex");
  process.stdout.write(JSON.stringify({ hits, codeLen: code.length }));
' "$GUARD" 2>/dev/null)"
assert_eq "no startsWith, no local KNOWN_PHASES, no [0-5] shape regex in the guard's CODE" \
  "$(field "$SRC_REPORT" hits)" ""
CODE_N="$(num "$SRC_REPORT" codeLen)"
assert_eq "VACUITY CONTROL: the source check read real code, not an empty string" \
  "$([[ "${CODE_N:-0}" -ge 500 ]] && echo enough || echo "ONLY ${CODE_N:-<no-report>}")" "enough"

# ---------------------------------------------------------------------------
suite "R5/AC4/AC29: ONE shared resolver, importable, with no fourth table behind it"
# ---------------------------------------------------------------------------
# WHERE it lives is Dev's call (exported from pipeline-telemetry.mjs, or relocated to lib.mjs);
# that ONE exists and both call sites use it is the contract. phaseKey's own docstring records
# what a shape regex cost: 3a-/3b- labels matched nothing and 4,088,488 ms, 39% of one run's
# lead time, was silently discarded.
RESOLVER_REPORT="$(node --input-type=module -e '
  const cands = process.argv.slice(1);
  let fn = null, from = null;
  for (const c of cands) {
    try { const m = await import(c); if (typeof m.phaseKey === "function") { fn = m.phaseKey; from = c; break; } } catch {}
  }
  if (!fn) { process.stdout.write(JSON.stringify({ from: null, results: {} })); process.exit(0); }
  const cases = ["3b-dev", "3a-qa-tests", "2.5-design", "1-ba-rerun", "phase-rerun", "9-nope"];
  const results = {}; for (const c of cases) results[c] = String(fn(c));
  process.stdout.write(JSON.stringify({ from, results }));
' "$SCRIPTS_DIR/lib.mjs" "$SCRIPTS_DIR/pipeline-telemetry.mjs" 2>/dev/null)"
assert_contains "phaseKey is importable from lib.mjs or pipeline-telemetry.mjs" "$RESOLVER_REPORT" '"from":"'
assert_contains "  it reads the suffixed label 3b-dev as token 3b" "$RESOLVER_REPORT" '"3b-dev":"3b"'
assert_contains "  and 3a-qa-tests as token 3a (distinct from 3b, which is why AC6 can exist)" "$RESOLVER_REPORT" '"3a-qa-tests":"3a"'
assert_contains "  and 2.5-design as token 2.5" "$RESOLVER_REPORT" '"2.5-design":"2.5"'
assert_contains "  and the R15 label 1-ba-rerun as token 1" "$RESOLVER_REPORT" '"1-ba-rerun":"1"'
assert_contains "  while the bare 'phase-rerun' still resolves to null (do NOT special-case it)" "$RESOLVER_REPORT" '"phase-rerun":"null"'
assert_contains "  and an unknown leading token resolves to null" "$RESOLVER_REPORT" '"9-nope":"null"'

# ---------------------------------------------------------------------------
suite "AC20 (prose half): resume semantics stated once, in the re-enter form"
# ---------------------------------------------------------------------------
# Under the 'phase after current_phase' reading, a run interrupted mid-Phase-3 resumes at
# Phase 4 having never finished Phase 3 -- the exact failure this issue exists to stop.
assert_not_contains "the 'continue from the phase after current_phase' wording is gone" \
  "$(cat "$PIPELINE_MD")" 'continue from the phase after'
assert_contains "and the re-enter-the-same-phase statement is present" \
  "$(cat "$PIPELINE_MD")" 're-enters that same phase from the top'

# ---------------------------------------------------------------------------
suite "AC30 (prose half): the exit event and the next entry checkpoint are ONE write"
# ---------------------------------------------------------------------------
# Checkpoint-first-then-append is fully compliant with pipeline.md as written and leaves a
# window in which the record says 'entering 3-impl' with neither design.json nor a closing
# event. The Stop hook fires at the turn boundary, and a turn very commonly ends right after a
# checkpoint commit, so the window is not hypothetical at this seam.
assert_contains "the convention states the two are a single write" \
  "$(cat "$PIPELINE_MD")" 'ONE write'
assert_contains "  and names which two things it joins" \
  "$(cat "$PIPELINE_MD")" 'exit event'

# ---------------------------------------------------------------------------
suite "AC29 (prose half): /phase appends a token-prefixed rerun label"
# ---------------------------------------------------------------------------
assert_not_contains "the phase-less 'phase-rerun' literal is no longer instructed" \
  "$(cat "$PHASE_MD")" '"phase-rerun"'
assert_contains "and a token-prefixed <phase-token>-rerun label is" \
  "$(cat "$PHASE_MD")" '<phase-token>-rerun'
# The owner ruling made after the spec was written: the guard DOES apply to /phase re-runs, so
# the line promising the opposite gets corrected rather than left contradicting the code.
assert_not_contains "phase.md no longer promises the opposite of what the guard does" \
  "$(cat "$PHASE_MD")" 'Do not block on order'

# ---------------------------------------------------------------------------
suite "AC31: the header carries the guarantee's LIMIT, verbatim, where an implementer reads it"
# ---------------------------------------------------------------------------
# Verbatim, not a keyword grep: a paraphrase is exactly how a stated limit becomes a stated
# guarantee. The text is embedded here rather than read from spec.json because spec.json is
# gitignored -- status.json is the only tracked per-issue artifact -- so a run-time read would
# be a false red on any fresh checkout.
WHAT_IT_IS_NOT="A pre-dispatch airlock. It CANNOT prevent a phase being skipped mid-turn; the phase's absence is detected when the turn tries to end. The cost of a skip is therefore the wasted work in that turn, not zero. Work already done in this turn is not undone."
GUARD_SRC="$(cat "$GUARD" 2>/dev/null || printf '<guard-absent>')"
assert_contains "the script header carries what_it_is_not VERBATIM" "$GUARD_SRC" "$WHAT_IT_IS_NOT"
assert_contains "  and names the inherited active-issue limitation (SubagentStop payload)" "$GUARD_SRC" "SubagentStop"
assert_contains "  and that the active issue therefore resolves by the mtime fallback" "$GUARD_SRC" "mtime fallback"

STOP_SRC="$(cat "$STOP_SH")"
assert_contains "stop.sh's opt-out comment names the variable it is about" "$STOP_SRC" "CLAUDE_HOOK_STOP_SKIP bypasses"
assert_contains "  and says the phase-entry guard is NOT bypassed" "$STOP_SRC" "NOT the phase-entry guard"
assert_not_contains "  and the bare 'Opt-out for one-off iterations.' comment is corrected, not kept" \
  "$STOP_SRC" "# Opt-out for one-off iterations."

# ===========================================================================================
# #53 -- THE FORM-COVERAGE CONTROL: a population no assignment spelling can leave
#
# WHY A THIRD RULE IS NOT THE ANSWER. Replacing one pattern with a wider pattern does not close
# the class, it moves the boundary. The class closes only when the coverage control's POPULATION
# is something no assignment spelling can escape -- the BARE WORD `current_phase` -- with every
# occurrence forced into a NAMED bucket:
#   CLAIMED      = matched by the derivation this suite SHIPS (derive() above).
#   EXCLUDED     = not matched even by a pattern STRICTLY WIDER than the claim pattern.
#   UNCLASSIFIED = matched by the wider pattern but not by the shipped one, i.e. a REAL
#                  assignment the derivation misses. Must be EMPTY, and is reported BY NAME.
#
# THE EXCLUSION RULE IS THE NEGATION OF THE WIDER PATTERN, NOT AN INDEPENDENTLY SPELLED THIRD
# RULE. That is what makes the claim rule and the exclusion rule structurally unable to disagree
# about what an assignment operator is -- the disagreement that lets `current_phase = "0-setup"`
# be claimed by neither and excluded by a hand-written rule, silently.
#
# THE EXCLUDED BUCKET IS A SORTED MULTISET, ASSERTED; ITS SIZE IS ONLY REPORTED.
#   - MULTISET, never `sort -u`: three of the five excluded LINES carry TWO occurrences each
#     with IDENTICAL text (measured, per line: 2/2/2/1/1), so `sort -u` turns 8 entries into 5
#     and a mutation removing one of a duplicated pair leaves the asserted list unchanged.
#   - SIZE REPORTED, NOT ASSERTED (#33): a pinned 8 is discharged by editing one digit, and the
#     edit that absorbs a legitimate new prose mention is the same edit that absorbs a SWALLOWED
#     ASSIGNMENT. The failure direction is CLAIM-MORE: after the digit is bumped the report
#     reads `0 UNCLASSIFIED, all accounted for` while a live assignment sits in EXCLUDED.
#   - KEYED ON TEXT, WITH THE LINE NUMBER REPORTED AND NOT ASSERTED: pipeline.md is edited by a
#     lane that does not own this suite, and a coordinate pin reddens on any insertion above the
#     last excluded site -- churn that trains an editor to re-paste without reading (#68).
#   - THE KEY IS A TEXT FINGERPRINT, `<trimmed length>|<first 72 trimmed characters>`, and the
#     grain is deliberate: the three duplicated LINES yield IDENTICAL entries, so `sort -u`
#     still collapses 8 to 5 and the multiset property still bites, while the assertion stays
#     readable. Any edit to an excluded occurrence's line changes its length or its prefix and
#     forces the editor to paste the occurrence rather than increment a digit.
# ===========================================================================================

# tripart <md-path> [wider|sameline] -> a line-oriented report.
# The `sameline` rule is NOT shippable and is here only as the NON-ZERO CONTROL that separates
# the two candidate exclusion rules; see the ghost cells below.
tripart() {
  node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const [mdPath, rule] = process.argv.slice(1);
    const md = readFileSync(mdPath, "utf8");
    const CLAIM = /"?current_phase"?: *"([^"]*)"/g;
    // STRICTLY WIDER than CLAIM: key optionally quoted with ", \x27 or a backtick; separator
    // [:=]; whitespace around it that MAY SPAN NEWLINES; value quoted three ways or a bare
    // token. Written with \x27 rather than a literal quote so the whole program survives the
    // single-quoted shell string it lives in.
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
      const isExcluded = rule === "sameline"
        ? !/^current_phase["\x27`]?[ \t]*[:=]/.test(md.slice(i, starts[li] + text.length))
        : !within(i, widerSpans);
      if (isExcluded) excluded.push({ li, text });
      else { const w = within(i, widerSpans); unclassified.push({ li, span: w ? w[2] : text }); }
    }
    const fp = (e) => e.text.trim().length + "|" + e.text.trim().slice(0, 72);
    const out = [];
    out.push("TOTAL=" + [...md.matchAll(/current_phase/g)].length);
    out.push("CLAIMED=" + claimed.length);
    out.push("EXCLUDED=" + excluded.length);
    out.push("UNCLASSIFIED=" + unclassified.length);
    out.push("EXLINES=" + excluded.map((e) => e.li + 1).join(","));
    out.push("UNNAMED=" + unclassified.map((e) => (e.li + 1) + ":" + e.span.replace(/\s+/g, " ")).join(" ;; "));
    out.push("--EXFP--");
    for (const line of excluded.map(fp).sort()) out.push(line);
    process.stdout.write(out.join("\n"));
  ' "$1" "${2:-wider}" 2>&1
}

# tp <report> <KEY> -> the value; tp_exfp <report> -> the sorted excluded fingerprint multiset.
tp()      { printf '%s' "$1" | sed -n "s/^$2=//p"; }
tp_exfp() { printf '%s' "$1" | sed -n '/^--EXFP--$/,$p' | sed '1d'; }

TP_REAL="$(tripart "$PIPELINE_MD" wider)"

# ---------------------------------------------------------------------------
suite "#53 AC2: every bare-word occurrence lands in exactly one named bucket"
# ---------------------------------------------------------------------------
record "REPORTED, never asserted: pipeline.md holds $(tp "$TP_REAL" TOTAL) bare-word \`current_phase\` occurrences, $(tp "$TP_REAL" CLAIMED) CLAIMED and $(tp "$TP_REAL" EXCLUDED) EXCLUDED, the excluded ones at lines $(tp "$TP_REAL" EXLINES). Grain is OCCURRENCES, not distinct literals: do not subtract these from the 26"
assert_eq "the three buckets ACCOUNT FOR every bare-word occurrence (a lost occurrence is the defect this control exists to make impossible)" \
  "$(( $(tp "$TP_REAL" CLAIMED) + $(tp "$TP_REAL" EXCLUDED) + $(tp "$TP_REAL" UNCLASSIFIED) ))" \
  "$(tp "$TP_REAL" TOTAL)"
assert_eq "UNCLASSIFIED is EMPTY: no assignment the WIDER pattern can see is missed by the derivation this suite ships" \
  "$(tp "$TP_REAL" UNNAMED)" ""

# THE EXCLUDED MULTISET. Captured by RUNNING the extraction above and pasted; eight entries, of
# which three pairs are identical by construction (one line, two occurrences).
# NOT a heredoc inside a $( ) capture: /bin/bash 3.2.57 scans a command substitution for its
# closing paren WITHOUT honouring quoted-heredoc rules, so the UNPAIRED backtick left by a
# 72-character truncation makes the whole file un-parseable. A multi-line single-quoted
# assignment has no such hazard, and single quotes cannot appear in these eight lines.
EXCLUDED_MULTISET_8='133|- **User interrupts mid-phase**: status.json preserves position. `/pipel
285|- If starts with `--resume <issue>`: set `ISSUE=<issue>`, read `.pipelin
285|- If starts with `--resume <issue>`: set `ISSUE=<issue>`, read `.pipelin
461|**`events[]` entries are EXIT markers and `current_phase` is an ENTRY ma
461|**`events[]` entries are EXIT markers and `current_phase` is an ENTRY ma
479|`status.json` is the `/pipeline --resume <issue>` checkpoint, so it must
479|`status.json` is the `/pipeline --resume <issue>` checkpoint, so it must
89|# Run BEFORE entering each phase, after setting current_phase to the pha'
assert_eq "and the EXCLUDED bucket's MEMBERSHIP is what is asserted -- the sorted occurrence-text MULTISET, so an occurrence cannot move between buckets at constant bucket sizes" \
  "$(tp_exfp "$TP_REAL")" "$EXCLUDED_MULTISET_8"
assert_eq "MULTISET, NOT A SET: three of the five excluded LINES carry two occurrences each with identical text, so \`sort -u\` would collapse 8 entries to 5 and re-open the bypass. This cell measures that collapse rather than asserting it is absent by inspection" \
  "$(tp_exfp "$TP_REAL" | sort -u | grep -c . | tr -d ' ')/$(tp_exfp "$TP_REAL" | grep -c . | tr -d ' ')" "5/8"

# ---------------------------------------------------------------------------
suite "#53 AC3(i): the SYNTHETIC fixture -- six unclaimed assignment forms, each NAMED"
# ---------------------------------------------------------------------------
new_tmpdir || exit 90
FIX_DIR="$NEW_TMPDIR"
cat > "$FIX_DIR/seven-forms.md" <<'SYN'
  "current_phase": "json-form",
current_phase: 'single-quoted'
current_phase: `backticked`
current_phase
  : "newline-split"
current_phase: bare-token
status.current_phase = "equals-form"
current_phase   : "wide-gap-before-colon"
Prose: the orchestrator writes current_phase before each phase begins.
SYN
TP_SYN="$(tripart "$FIX_DIR/seven-forms.md" wider)"
assert_eq "eight bare-word occurrences partition as 1 CLAIMED + 1 EXCLUDED + 6 UNCLASSIFIED" \
  "$(tp "$TP_SYN" CLAIMED)/$(tp "$TP_SYN" EXCLUDED)/$(tp "$TP_SYN" UNCLASSIFIED)" "1/1/6"
for form in single-quoted backticked newline-split bare-token equals-form wide-gap-before-colon; do
  assert_contains "  and the unclaimed \`$form\` assignment is named in UNCLASSIFIED rather than deleted by a pre-filter" \
    "$(tp "$TP_SYN" UNNAMED)" "$form"
done
assert_contains "  while the PROSE mention lands in EXCLUDED, so the two buckets do not swap" \
  "$(tp_exfp "$TP_SYN")" "Prose: the orchestrator writes current_phase"

# ---------------------------------------------------------------------------
suite "#53 AC3(ii): the GHOST fixture -- the cell that separates the two exclusion rules"
# ---------------------------------------------------------------------------
# A copy of the REAL pipeline.md with `current_phase` and `: "9-ghost"` on CONSECUTIVE LINES and
# one prose mention DELETED in the same edit. Bucket SIZES cannot separate the rules here, which
# is the whole point: only the fixture can.
node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
  const out = [];
  let dropped = 0;
  for (const l of lines) {
    if (!dropped && l.includes("User interrupts mid-phase") && l.includes("current_phase")) { dropped = 1; continue; }
    out.push(l);
  }
  if (!dropped) { console.error("GHOST FIXTURE: the prose mention this edit deletes was not found"); process.exit(1); }
  out.push("current_phase");
  out.push(": \"9-ghost\"");
  fs.writeFileSync(process.argv[2], out.join("\n"));
' "$PIPELINE_MD" "$FIX_DIR/ghost.md" 2>/dev/null
assert_eq "the ghost fixture was built (its edit deletes one prose mention and adds one newline-split assignment, so the bare-word total is UNCHANGED)" \
  "$(tp "$(tripart "$FIX_DIR/ghost.md" wider)" TOTAL)" "$(tp "$TP_REAL" TOTAL)"

TP_GHOST_WIDE="$(tripart "$FIX_DIR/ghost.md" wider)"
TP_GHOST_SAME="$(tripart "$FIX_DIR/ghost.md" sameline)"
TP_REAL_SAME="$(tripart "$PIPELINE_MD" sameline)"

assert_contains "THE SHIPPED RULE NAMES THE GHOST: a newline-split assignment the derivation cannot claim is reported in UNCLASSIFIED, by name" \
  "$(tp "$TP_GHOST_WIDE" UNNAMED)" "9-ghost"
assert_eq "  and the excluded MULTISET reddens by naming what MOVED (the deleted prose mention is gone from it)" \
  "$([[ "$(tp_exfp "$TP_GHOST_WIDE")" != "$(tp_exfp "$TP_REAL")" ]] && echo changed || echo "UNCHANGED: the multiset did not move")" "changed"
assert_eq "NON-ZERO CONTROL, and the reason the size CANNOT be the instrument: the SAME-LINE exclusion rule reports the ghost file as $(tp "$TP_GHOST_SAME" CLAIMED) CLAIMED + $(tp "$TP_GHOST_SAME" EXCLUDED) EXCLUDED + $(tp "$TP_GHOST_SAME" UNCLASSIFIED) UNCLASSIFIED -- fully green over a LIVE unclaimed assignment" \
  "$(tp "$TP_GHOST_SAME" UNCLASSIFIED)" "0"
assert_eq "  and under that rule the literal \`9-ghost\` appears in NO bucket's output at all" \
  "$(printf '%s' "$TP_GHOST_SAME" | grep -c '9-ghost' | tr -d ' ')" "0"
assert_eq "  the two rules are IDENTICAL on the unmodified file, which is why the FIXTURE and not the numbers is what separates them" \
  "$(tp "$TP_REAL_SAME" CLAIMED)/$(tp "$TP_REAL_SAME" EXCLUDED)/$(tp "$TP_REAL_SAME" UNCLASSIFIED)" \
  "$(tp "$TP_REAL" CLAIMED)/$(tp "$TP_REAL" EXCLUDED)/$(tp "$TP_REAL" UNCLASSIFIED)"

# ---------------------------------------------------------------------------
suite "#53 AC10: the comment ruling on the derivation cites a re-derivation, not a coordinate"
# ---------------------------------------------------------------------------
# The replaced comment ruled against the wide form BY NAME and cited an absolute line range into
# a different shipped file. Both halves were wrong: the rule was backwards, and the citation is
# #68's shape. `grep -o | wc -l` throughout, never `grep -c`, which counts LINES.
assert_eq "this suite cites no absolute line range into test-voice-lint.sh" \
  "$(grep -o 'test-voice-lint\.sh:[0-9]' "${BASH_SOURCE[0]}" | wc -l | tr -d ' ')" "0"
# ASSEMBLED, NEVER WRITTEN AS ONE TOKEN. This file is inside the population the grep above
# walks, so a control carrying the coordinate verbatim makes the zero un-reachable for a reason
# that has nothing to do with the subject -- the self-counting trap this repo has hit twice.
CTRL_COORD="tests/test-voice-lint""$(printf '%s' .sh:225-239)"
assert_eq "  NON-ZERO CONTROL on that instrument: the same pattern finds a coordinate when one is there, so the zero above is a measurement and not a pattern that never matches" \
  "$(printf '%s\n' "$CTRL_COORD" | grep -o 'test-voice-lint\.sh:[0-9]' | wc -l | tr -d ' ')" "1"
assert_contains "  and the comment now in force states the rule, and cites a re-derivation command" \
  "$(cat "${BASH_SOURCE[0]}")" 'git grep -n "THE WIDE FORM" -- plugins/pipeline/tests'

finish