#!/usr/bin/env node
/**
 * Materiality: what a review finding is allowed to BLOCK on, decided by code rather than by
 * the reviewer's mood.
 *
 * Before this module, any single REQUEST_CHANGES from any panel role looped the run, and a
 * concern's severity was the only axis it carried. Six opus reviewers at high effort, each
 * told to surface the strongest flaw they could find, never converge to zero findings; they
 * converge by budget exhaustion. Measured on this repo's own archive: first-pass approval on
 * 4 of 11 runs, Phase 4 the largest single consumer of active run time, and a shell-tokenizer
 * fix that spent 7.6 hours and spawned four follow-up issues, every finding in it real.
 *
 * The rule (the same one a careful colleague applies before blocking a merge):
 *
 *   A concern BLOCKS only if its severity is blocker/critical/high AND it is reachable in
 *   practice or expensive to undo:
 *     - likelihood normal-use or edge-case            -> blocks
 *     - likelihood adversarial                        -> blocks only if reversibility is a
 *                                                        one-way-door OR harm is data-or-security
 *     - likelihood hypothetical                       -> never blocks (a future edit, a config
 *                                                        nobody has, an environment the project
 *                                                        does not run in)
 *   Everything else is a NOTE. Notes ship. Notes with a suggested_patch are applied by the
 *   orchestrator in the same turn; notes without one are filed as follow-up issues.
 *
 * FAIL DIRECTION. A blocking-severity concern that carries NO rating is treated as blocking
 * and reported as unrated: the contracts require the three fields, and an omission must not
 * quietly buy a pass. A VETO stands only on a named veto_ground from the enumerated security
 * surfaces; a VETO without one is a REQUEST_CHANGES, which still refuses the merge but does
 * not send the spec back to BA for redesign. An APPROVE that carries a blocking concern is
 * a REQUEST_CHANGES, because a reviewer who rates a finding as reachable and severe and then
 * approves has contradicted itself, and the safe reading is the finding.
 *
 * merge-peer-review.mjs applies normalizeBlock to every shard it folds, so the rubric in
 * commands/pipeline.md reads the NORMALIZED verdict. The verdict the reviewer actually
 * returned is preserved beside it as verdict_as_returned whenever the two differ, so the
 * archive shows both the finding and the ruling on it.
 */

export const LIKELIHOODS = ["normal-use", "edge-case", "adversarial", "hypothetical"];
export const REVERSIBILITIES = ["undo-button", "some-cleanup", "one-way-door"];
export const HARMS = ["data-or-security", "user-visible", "internal", "cosmetic"];

/** The severities that CAN block. Everything else (major, medium, low, nit, info) is a note. */
export const BLOCKING_SEVERITIES = ["blocker", "critical", "high"];

/**
 * The surfaces on which a SecOps VETO stands. A VETO is the one verdict that sends a spec back
 * to BA for redesign rather than to Dev for a fix, so it is reserved for the surfaces where a
 * wrong design is unrecoverable. Anywhere else, SecOps blocks with REQUEST_CHANGES like any
 * other role, subject to the same materiality rule.
 */
export const VETO_GROUNDS = [
  "auth",
  "authorization",
  "session",
  "crypto",
  "secrets",
  "injection",
  "webhook-verification",
  "data-access-policy",
  "migration",
  "pii-exposure",
  "compliance",
];

/** At most this many blocking concerns per reviewer. Over the cap is reported, never dropped. */
export const BLOCKING_CAP = 2;

const VERDICTS_THAT_BLOCK = ["REQUEST_CHANGES", "REQUEST_REFACTOR", "VETO"];

function lower(v) {
  return typeof v === "string" ? v.trim().toLowerCase() : "";
}

export function normVerdict(v) {
  if (typeof v !== "string") return null;
  const u = v.trim().toUpperCase();
  if (u === "") return null;
  if (u === "APPROVE_WITH_NITS") return "APPROVE_WITH_NOTES";
  return u;
}

/**
 * Rate one concern. Returns { blocking, unrated, reason }. Pure; never throws on a malformed
 * concern (a non-object is a note with a reason saying so, because a crash here would take the
 * merge down and a missing merge is a missing review).
 */
export function rateConcern(c) {
  if (!c || typeof c !== "object" || Array.isArray(c)) {
    return { blocking: false, unrated: false, reason: "not a concern object; ignored" };
  }
  const sev = lower(c.severity);
  if (!BLOCKING_SEVERITIES.includes(sev)) {
    return { blocking: false, unrated: false, reason: `severity ${sev || "(none)"} is a note, not a block` };
  }
  const lk = lower(c.likelihood);
  const rv = lower(c.reversibility);
  const hm = lower(c.harm);
  const rated = LIKELIHOODS.includes(lk) && REVERSIBILITIES.includes(rv) && HARMS.includes(hm);
  if (!rated) {
    return {
      blocking: true,
      unrated: true,
      reason:
        "UNRATED: a blocking-severity concern with no valid likelihood/reversibility/harm is treated as blocking (fail closed). Rate it.",
    };
  }
  if (lk === "hypothetical") {
    return { blocking: false, unrated: false, reason: "hypothetical: needs a future edit, a config nobody has, or an environment the project does not run in" };
  }
  if (lk === "normal-use" || lk === "edge-case") {
    return { blocking: true, unrated: false, reason: `${lk} at severity ${sev}` };
  }
  // adversarial
  if (rv === "one-way-door" || hm === "data-or-security") {
    return { blocking: true, unrated: false, reason: `adversarial but ${rv === "one-way-door" ? "irreversible" : "data-or-security harm"}` };
  }
  return { blocking: false, unrated: false, reason: "adversarial-only, reversible, no data or security harm: a note" };
}

/**
 * Normalize one reviewer block. Returns a NEW object; the input is not mutated. A block with
 * no string verdict is returned as-is (the merge halts on it separately).
 */
export function normalizeBlock(block, role) {
  if (!block || typeof block !== "object" || Array.isArray(block)) return block;
  const raw = normVerdict(block.verdict);
  if (!raw) return block;

  const concerns = Array.isArray(block.concerns) ? block.concerns : [];
  const ratings = concerns.map(rateConcern);
  const blocking = ratings.filter((r) => r.blocking).length;
  const unrated = ratings.filter((r) => r.unrated).length;
  const notes = [];
  let effective = raw;

  if (effective === "VETO") {
    const ground = lower(block.veto_ground);
    if (lower(role) !== "secops") {
      effective = "REQUEST_CHANGES";
      notes.push(`VETO is SecOps's verdict alone; from ${role || "an unnamed role"} it reads as REQUEST_CHANGES.`);
    } else if (!VETO_GROUNDS.includes(ground)) {
      effective = "REQUEST_CHANGES";
      notes.push(
        `VETO without a veto_ground in [${VETO_GROUNDS.join(", ")}] reads as REQUEST_CHANGES: it still refuses the merge, it does not send the spec back to BA.`,
      );
    }
  }

  if (effective === "REQUEST_CHANGES" && blocking === 0) {
    effective = "APPROVE_WITH_NOTES";
    notes.push(
      concerns.length === 0
        ? "REQUEST_CHANGES with no concerns at all reads as APPROVE_WITH_NOTES."
        : "REQUEST_CHANGES with no BLOCKING concern reads as APPROVE_WITH_NOTES: every concern is a note under the materiality rule.",
    );
  }

  if ((effective === "APPROVE" || effective === "APPROVE_WITH_NOTES") && blocking > 0) {
    effective = "REQUEST_CHANGES";
    notes.push(`${raw} carrying ${blocking} blocking concern(s) reads as REQUEST_CHANGES (fail closed).`);
  }

  if (unrated > 0) {
    notes.push(`${unrated} blocking-severity concern(s) carry no rating and were treated as blocking; the contract requires likelihood, reversibility and harm on every concern.`);
  }
  if (blocking > BLOCKING_CAP) {
    notes.push(`${blocking} blocking concerns exceeds the cap of ${BLOCKING_CAP}; none were dropped, but the reviewer was asked to rank and keep the top ${BLOCKING_CAP}.`);
  }

  const out = { ...block, verdict: effective };
  // Compared to the verdict AS WRITTEN (so a legacy APPROVE_WITH_NITS is recorded as having
  // been returned), and only set when it changed; a re-run on an already-normalized block
  // finds the two equal and keeps whatever verdict_as_returned the first pass recorded.
  if (effective !== String(block.verdict).trim().toUpperCase()) out.verdict_as_returned = block.verdict;
  // IDEMPOTENT: a block that was already normalized (it carries a materiality record and this
  // pass changed nothing) keeps that record, notes included. Recomputing would drop the notes
  // that explain the first pass's ruling, and a delta-round re-merge must not re-rule.
  const unchanged = effective === raw && block.materiality && typeof block.materiality === "object";
  out.materiality = unchanged
    ? block.materiality
    : {
        blocking_concerns: blocking,
        unrated_concerns: unrated,
        over_cap: blocking > BLOCKING_CAP,
        blocks_merge: VERDICTS_THAT_BLOCK.includes(effective),
        notes,
      };
  return out;
}
