/**
 * The in-flight / datability predicate, in a LEAF module.
 *
 * WHY IT IS A LEAF AND NOT A FUNCTION IN EITHER CONSUMER. gate-phase-entry.mjs already imports
 * activeIssueDir from validate-pipeline-artifact.mjs, so an edge back the other way closes a
 * cycle. Measured on the real 16-module graph before this file existed: adding
 * `import { IN_FLIGHT_MS } from "./gate-phase-entry.mjs"` to validate-pipeline-artifact.mjs and
 * using it at module scope made `node gate-phase-entry.mjs` exit 1 with
 * `ReferenceError: Cannot access 'IN_FLIGHT_MS' before initialization` on stderr, while entering
 * the identical cycle from the validator was invisible. gate-phase-entry's try/catch wraps main(),
 * not module evaluation, and its stop.sh caller reads stderr there as a refusal - so the cycle
 * would have converted a fail-open tooling gap into a phase REFUSAL. This module imports from
 * neither participant, and both import from it.
 *
 * THE TWO ANSWERS ARE SEPARATE ON PURPOSE. The phase-entry guard and the PreToolUse gate are
 * deliberately given OPPOSITE readings of a record whose `updated_at` will not parse:
 *   - the guard EXCLUDES it (an undatable record is not evidence a run is live, and the guard
 *     refuses turns);
 *   - the gate COUNTS it as a candidate (so it can never shrink a candidate set to one) while
 *     refusing to let it be the resolved OWNER (so an arbitrarily old abandoned run can never
 *     author a deny).
 * Neither consumer may re-derive the other's answer from a single boolean, so `concluded`,
 * `datable` and `recent` are returned as three observations rather than folded into one.
 */

/**
 * THE CEILING IS DECLARED TWICE ON PURPOSE, AND THE SECOND SPELLING IS PINNED.
 * gate-phase-entry.mjs owns the authoritative declaration (`export const IN_FLIGHT_MS = 24 * 60 *
 * 60 * 1000;`), because tests/test-gate-phase-entry.sh's #63-A2 pins that EXACT SOURCE TEXT and
 * its ceiling-rewrite mutation edits that line; folding it into a re-export leaves that mutation
 * driving the shipped number while claiming to drive a rewritten one. Importing it back the other
 * way would close the cycle this module exists to avoid. So the guard passes its own constant in
 * explicitly and never reads the copy below, and the copy below exists only as the default for
 * callers that have no guard to ask. tests/test-pretooluse-inflight-ceiling.sh asserts the two
 * declarations carry the same value expression, so a drift reddens instead of going unnoticed.
 */
export const IN_FLIGHT_MS = 24 * 60 * 60 * 1000;

/**
 * Three observations about one status record, plus the two derived verdicts its consumers want.
 *
 * `concluded` is evaluated FIRST and excludes unconditionally: a `final_verdict` is a statement
 * that needs no dating. It is usually, but not always, a statement that the run is over - a delta
 * round re-enters `4-review` while the prior round's verdict is still attached - and the cost of
 * that order is named where it lands: such a run is excluded, so a gate that consumes this
 * ABSTAINS where it would otherwise deny. That is a silence, never a refusal of correct work.
 * The lifecycle defect underneath is #110 and is not fixed here.
 */
export function inFlightObservations(status, now = Date.now(), ceilingMs = IN_FLIGHT_MS) {
  const record = status && typeof status === "object" ? status : {};
  const concluded = Boolean(record.final_verdict);
  const parsed = Date.parse(record.updated_at);
  const datable = Number.isFinite(parsed);
  const recent = datable && now - parsed <= ceilingMs;
  return {
    concluded,
    datable,
    recent,
    // The phase-entry guard's reading: a record it can date, has not concluded, and that is recent.
    inFlight: !concluded && datable && recent,
    // The PreToolUse gate's reading: everything the guard admits, PLUS the records it cannot date.
    candidate: !concluded && (recent || !datable),
  };
}
