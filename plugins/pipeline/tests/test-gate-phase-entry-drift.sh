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
# insufficient: status.schema.json:13's own description blesses `3-scope-drift-adjudication`
# and `3-impl-verification-unverified`, and pipeline.md writes NEITHER. A vocabulary in this
# repo has already rotted, in the one file a prose-derived test does not read.

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
    let sets;
    if (setsArg === "MODULE") {
      const m = await import(guardPath);
      sets = { ENTRY: m.ENTRY, EXIT: m.EXIT, UNGUARDED: m.UNGUARDED, TERMINAL: m.TERMINAL };
    } else {
      sets = JSON.parse(setsArg);
    }
    const md = readFileSync(mdPath, "utf8");
    // The STRICT form, matching tests/test-voice-lint.sh:225-239. A looser pattern picks up
    // `0-setup` from the Phase 0 JSON block, so the two checks would disagree about their own
    // population.
    const literals = [...new Set([...md.matchAll(/current_phase: *"([^"]*)"/g)].map((m) => m[1]))]
      .filter((p) => p !== "<phase>-error");
    const names = ["ENTRY", "EXIT", "UNGUARDED", "TERMINAL"];
    const counts = {}; const seen = new Map(); const dupes = [];
    for (const n of names) {
      const arr = Array.isArray(sets[n]) ? sets[n] : [];
      counts[n] = arr.length;
      for (const p of arr) {
        if (seen.has(p)) dupes.push(p + " in " + seen.get(p) + " and " + n);
        else seen.set(p, n);
      }
    }
    const unassigned = literals.filter((p) => !seen.has(p));
    const notInMd = [...seen.keys()].filter((p) => !literals.includes(p));
    process.stdout.write(JSON.stringify({
      literalCount: literals.length, counts, dupes, unassigned, notInMd,
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

REPORT="$(derive MODULE)"

# ---------------------------------------------------------------------------
suite "AC18(vi): VACUITY CONTROL -- the derivation found a population at all"
# ---------------------------------------------------------------------------
LIT_N="$(num "$REPORT" literalCount)"
assert_eq "the pipeline.md derivation found at least 20 current_phase literals" \
  "$([[ "${LIT_N:-0}" -ge 20 ]] && echo enough || echo "ONLY ${LIT_N:-<no-report>}")" "enough"
assert_eq "and exactly the 25 concrete ones (26 distinct minus the <phase>-error template)" \
  "${LIT_N:-<no-report>}" "25"

# ---------------------------------------------------------------------------
suite "AC18(i): the four sets PARTITION the 25 literals"
# ---------------------------------------------------------------------------
# A partition is strictly stronger than a union check, and it is what makes 'decided' tellable
# from 'forgot' in BOTH directions: a literal in two sets fails, and a literal in none fails.
assert_eq "the sets are pairwise DISJOINT" "$(field "$REPORT" dupes)" ""
assert_eq "every pipeline.md literal is assigned to exactly one set" "$(field "$REPORT" unassigned)" ""
assert_eq "and no set names a phase pipeline.md does not write" "$(field "$REPORT" notInMd)" ""

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
suite "AC18(ii): |ENTRY| is pinned to pipeline.md's 'Checkpoint first' sites"
# ---------------------------------------------------------------------------
CP_N="$(grep -o 'Checkpoint first' "$PIPELINE_MD" | wc -l | tr -d ' ')"
assert_eq "pipeline.md has 8 'Checkpoint first' occurrences (grep -o | wc -l, never grep -c)" "$CP_N" "8"
assert_eq "and |ENTRY| equals that count" "$(num "$REPORT" ENTRY)" "$CP_N"

# Each literal at a Checkpoint-first site must BE an entry key. The count agreeing while the
# membership does not is the exact drift a count-only check misses.
CP_MISSING=""
while IFS= read -r line; do
  lit="$(printf '%s' "$line" | sed -n 's/.*current_phase: *"\([^"]*\)".*/\1/p')"
  [[ -n "$lit" ]] || { CP_MISSING="$CP_MISSING <no-literal-on-line>"; continue; }
  node --input-type=module -e '
    const m = await import(process.argv[1]);
    process.exit(m.ENTRY.includes(process.argv[2]) ? 0 : 1);
  ' "$GUARD" "$lit" 2>/dev/null || CP_MISSING="$CP_MISSING $lit"
done < <(grep 'Checkpoint first' "$PIPELINE_MD")
assert_eq "every phase literal at a 'Checkpoint first' site IS an ENTRY key" "${CP_MISSING# }" ""

# ---------------------------------------------------------------------------
suite "AC18(iii): every <phase>-complete literal pipeline.md writes is an EXIT key"
# ---------------------------------------------------------------------------
assert_eq "|EXIT| is 7" "$(num "$REPORT" EXIT)" "7"
COMPLETE_MISSING=""
while IFS= read -r lit; do
  [[ -n "$lit" ]] || continue
  node --input-type=module -e '
    const m = await import(process.argv[1]);
    process.exit(m.EXIT.includes(process.argv[2]) ? 0 : 1);
  ' "$GUARD" "$lit" 2>/dev/null || COMPLETE_MISSING="$COMPLETE_MISSING $lit"
done < <(grep -o 'current_phase: *"[^"]*-complete"' "$PIPELINE_MD" | sed -n 's/.*"\([^"]*\)"/\1/p' | sort -u)
assert_eq "no -complete literal is missing from EXIT" "${COMPLETE_MISSING# }" ""

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

finish
