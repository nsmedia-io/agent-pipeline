/**
 * The in-flight / datability predicate, in a LEAF module.
 *
 * WHY IT IS A LEAF AND NOT A FUNCTION IN EITHER CONSUMER. gate-phase-entry.mjs already imports
 * activeIssueDir from validate-pipeline-artifact.mjs, so an edge back the other way closes a
 * cycle. Measured on the real 16-module graph before this file existed: importing the guard's
 * IN_FLIGHT_MS into validate-pipeline-artifact.mjs and
 * using it at module scope made `node gate-phase-entry.mjs` exit 1 with
 * `ReferenceError: Cannot access 'IN_FLIGHT_MS' before initialization` on stderr, while entering
 * the identical cycle from the validator was invisible. gate-phase-entry's try/catch wraps main(),
 * not module evaluation, and its stop.sh caller reads stderr there as a refusal - so the cycle
 * would have converted a fail-open tooling gap into a phase REFUSAL. This module imports from
 * neither participant, and both import from it.
 *
 * THE THREE ANSWERS ARE SEPARATE ON PURPOSE. The phase-entry guard, the PreToolUse gate and the
 * `pipeline-status.mjs` reporter are deliberately given DIFFERENT readings of a record whose
 * `updated_at` will not parse:
 *   - the guard EXCLUDES it (an undatable record is not evidence a run is live, and the guard
 *     refuses turns);
 *   - the gate COUNTS it as a candidate (so it can never shrink a candidate set to one) while
 *     refusing to let it be the resolved OWNER (so an arbitrarily old abandoned run can never
 *     author a deny);
 *   - the reporter calls it NEITHER in flight NOR stuck, because "this run has not moved in a
 *     day" is a claim about elapsed time and an undatable record supports no such claim.
 * No consumer may re-derive another's answer from a single boolean, so `concluded`, `datable`
 * and `recent` are returned as three observations rather than folded into one.
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
 * that needs no dating.
 *
 * THAT ORDER IS ONLY SOUND BECAUSE #110 IS NOW FIXED, and this comment is where the dependency
 * is recorded. It used to be unsound: a delta round re-entered `4-review` carrying the PREVIOUS
 * round's `final_verdict`, so `concluded` was true of a run that was demonstrably live, and every
 * consumer here inherited that. Reproduced on real committed history rather than reasoned -- blob
 * `d83bfc0` of `.pipeline/19/status.json`, `current_phase: "4-review"`, `final_verdict:
 * "REQUEST_CHANGES"`, `review_rounds: 2`. `commands/pipeline.md` now clears `final_verdict` and
 * `peer_review_verdict_counts` in the same checkpoint write that enters `4-review`, so the field's
 * presence means "this run concluded" and not "this run concluded at some point in its history".
 * If that instruction is ever removed, this ordering silently goes back to excluding live runs.
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
    // pipeline-status.mjs's reading, and the reason that module no longer spells 24h itself
    // (#74 s1). NOT the negation of `inFlight`: the complement of a conjunction is satisfied by
    // an undatable record and by a concluded one, and neither is "stuck". A run is stuck when it
    // is datable, has NOT concluded, and is NOT recent -- all three, which is what makes this
    // share the `ceilingMs` term with `inFlight` instead of restating it.
    stuck: !concluded && datable && !recent,
  };
}
