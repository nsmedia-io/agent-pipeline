#!/usr/bin/env bash
# #106 internal unit: the in-flight CEILING is declared in two modules, and they must agree.
#
# WHY TWO DECLARATIONS EXIST AT ALL. scripts/gate-phase-entry.mjs owns the authoritative one --
# tests/test-gate-phase-entry.sh's #63-A2 pins its EXACT SOURCE TEXT and the ceiling-rewrite
# mutation at #63's "shifted-boundary control" edits that very line, so folding it into a
# re-export from the leaf would leave that mutation driving the SHIPPED number while reporting
# that it drove a rewritten one. scripts/run-candidates.mjs carries a second declaration as the
# default for callers that have no guard to ask, and importing the guard's copy back into the
# leaf would close the cycle the leaf exists to avoid.
#
# So the duplication is structural, and this file is what keeps it honest: a drift between the
# two reddens here instead of quietly giving the PreToolUse gate and the phase-entry guard two
# different windows. It asserts the VALUE (read by importing each module) and the SOURCE TEXT
# (read by grep), because either alone passes a defect the other catches: two modules can agree
# on a value while one is written as a magic number, and two identical strings prove nothing if
# one of them is not the declaration actually exported.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

GUARD="$SCRIPTS_DIR/gate-phase-entry.mjs"
LEAF="$SCRIPTS_DIR/run-candidates.mjs"

suite "#106 the leaf and the guard declare the same in-flight ceiling"

read_export() { # <file>
  node --input-type=module -e "
    const m = await import('file://$1');
    process.stdout.write(String(m.IN_FLIGHT_MS));" 2>/dev/null
}

GUARD_VALUE="$(read_export "$GUARD")"
LEAF_VALUE="$(read_export "$LEAF")"

assert_eq "VACUITY: the guard's exported ceiling reads as a positive integer (an empty read makes the equality below meaningless)" \
  "$(node -e 'const n=Number(process.argv[1]); process.stdout.write(Number.isInteger(n)&&n>0?"ok":"NOT-A-POSITIVE-INTEGER: "+process.argv[1])' "${GUARD_VALUE:-}" 2>/dev/null)" \
  "ok"
assert_eq "the leaf's exported ceiling equals the guard's" "$LEAF_VALUE" "$GUARD_VALUE"

GUARD_TEXT="$(grep -c '^export const IN_FLIGHT_MS = 24 \* 60 \* 60 \* 1000;$' "$GUARD" | tr -d ' ')"
LEAF_TEXT="$(grep -c '^export const IN_FLIGHT_MS = 24 \* 60 \* 60 \* 1000;$' "$LEAF" | tr -d ' ')"
assert_eq "the guard declares it exactly once, in the source text #63-A2 pins" "$GUARD_TEXT" "1"
assert_eq "and the leaf's declaration is the same source text, so a reformat of one is visible here" "$LEAF_TEXT" "1"

# NON-ZERO CONTROL. The grep must be able to report a MISS, or the two 1s above are a statement
# about a pattern that matches anything.
PLANTED="$TMPDIR/pretooluse-ceiling-control.$$"
printf 'export const IN_FLIGHT_MS = 2 * 60 * 60 * 1000;\n' > "$PLANTED"
assert_eq "NON-ZERO CONTROL: the same grep reports 0 against a rewritten ceiling" \
  "$(grep -c '^export const IN_FLIGHT_MS = 24 \* 60 \* 60 \* 1000;$' "$PLANTED" | tr -d ' ')" "0"
rm -f "$PLANTED"

suite "#106 the leaf's two answers are genuinely different observations"

# R5 gives the guard and the gate deliberately OPPOSITE readings of an undatable record. If the
# leaf ever folded them into one boolean, this row is what says so.
OBS="$(node --input-type=module -e "
  const { inFlightObservations } = await import('file://$LEAF');
  const now = Date.now();
  const cells = [
    ['fresh', { updated_at: new Date(now - 60000).toISOString() }],
    ['stale', { updated_at: new Date(now - 48 * 3600 * 1000).toISOString() }],
    ['undatable', { updated_at: 'nope' }],
    ['concluded', { updated_at: new Date(now - 60000).toISOString(), final_verdict: 'APPROVE' }],
  ];
  process.stdout.write(cells.map(([n, s]) => {
    const o = inFlightObservations(s, now);
    return n + '=' + (o.inFlight ? 'F' : 'f') + (o.candidate ? 'C' : 'c');
  }).join(' '));" 2>/dev/null)"
record "leaf observations (F/f = inFlight, C/c = candidate): $OBS"
assert_eq "fresh: in flight for the guard AND a candidate for the gate" \
  "$(printf '%s' "$OBS" | tr ' ' '\n' | grep '^fresh=' | cut -d= -f2)" "FC"
assert_eq "stale: neither" \
  "$(printf '%s' "$OBS" | tr ' ' '\n' | grep '^stale=' | cut -d= -f2)" "fc"
assert_eq "undatable: NOT in flight for the guard, but IS a candidate for the gate -- the one cell the two readings deliberately disagree on" \
  "$(printf '%s' "$OBS" | tr ' ' '\n' | grep '^undatable=' | cut -d= -f2)" "fC"
assert_eq "concluded: excluded from both, whatever its date says" \
  "$(printf '%s' "$OBS" | tr ' ' '\n' | grep '^concluded=' | cut -d= -f2)" "fc"

finish
