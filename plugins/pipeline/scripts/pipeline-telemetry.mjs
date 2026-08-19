#!/usr/bin/env node
/**
 * Two derived, NUMBERS-ONLY records for status.json.
 *
 *   telemetry(status)      per-phase elapsed, total lead time, and the review-round count.
 *   effectiveConfig(cfg)   the surface globs and per-role models that were actually LIVE,
 *                          so a narrowing is auditable after the fact rather than
 *                          reconstructable only from a config file that may have changed.
 *
 * WHY NUMBERS ONLY: status.json is committed and archived VERBATIM into the knowledge store.
 * A free-text note, a filesystem path, a command string or a branch-derived label written
 * here is a leak with a long half-life, so nothing in this module emits one. The single
 * non-numeric value it can produce is the literal rejection token below, which exists to
 * REPLACE a string that would otherwise have been recorded.
 *
 * The two migration sets are recorded as DISTINCT NAMED ENTRIES on purpose. Recording one
 * "migrationGlobs" value would reproduce the ambiguity this whole change removes: an auditor
 * reading it later cannot tell which set was live for which control, and the two genuinely
 * differ (the gate's REPLACES, the tripwire's UNIONS).
 */

import {
  dataLayerGlobs,
  infraGlobs,
  migrationGlobsForGate,
  migrationGlobsForTripwire,
} from "./data-layer-surface.mjs";
import {
  ALLOWED_MODELS,
  KNOWN_PHASES,
  KNOWN_ROLES,
  PINNED_ROLES,
  resolve as resolveModel,
} from "./dispatch-model.mjs";

/**
 * An adopter's absolute glob is unusual but legal, and it compiles fine, so without this it
 * would write an absolute filesystem path into a file that is archived verbatim into a
 * committed tree: the exact leak the prohibition in status.schema.json forbids, arriving
 * through the field added to make narrowing auditable.
 */
export const ABSOLUTE_GLOB_TOKEN = "<absolute-glob-rejected>";

function isAbsoluteGlob(g) {
  return typeof g === "string" && (/^\//.test(g) || /^[A-Za-z]:\\/.test(g));
}

function sanitizeGlobs(globs) {
  return (globs || [])
    .filter((g) => typeof g === "string")
    .map((g) => (isAbsoluteGlob(g) ? ABSOLUTE_GLOB_TOKEN : g));
}

/**
 * @returns {{migration_globs_tripwire: string[], migration_globs_gate: string[],
 *            data_layer_globs: string[], infra_globs: string[],
 *            models: Record<string,string>, rejected_absolute_globs: number}}
 */
export function effectiveConfig(cfg) {
  const config = cfg && typeof cfg === "object" && !Array.isArray(cfg) ? cfg : {};
  const sets = {
    migration_globs_tripwire: migrationGlobsForTripwire(config),
    migration_globs_gate: migrationGlobsForGate(config),
    data_layer_globs: dataLayerGlobs(config),
    infra_globs: infraGlobs(config),
  };
  let rejected = 0;
  const out = {};
  for (const [name, globs] of Object.entries(sets)) {
    rejected += globs.filter(isAbsoluteGlob).length;
    out[name] = sanitizeGlobs(globs);
  }
  // The effective per-role model, restricted to the allowlist by construction: a pinned role
  // has no entry at all, because no key is emitted for it and the audit record must say the
  // same thing the dispatch did.
  const models = {};
  for (const role of KNOWN_ROLES) {
    if (PINNED_ROLES[role]) continue;
    const { model } = resolveModel({ role, tier: "architectural", phase: "4", cfg: config });
    if (model && ALLOWED_MODELS.includes(model)) models[role] = model;
  }
  out.models = models;
  out.rejected_absolute_globs = rejected;
  return out;
}

function parseTime(v) {
  if (typeof v !== "string") return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
}

/**
 * The leading phase LABEL of an event, e.g. "4-review-complete" -> "4", "3a-qa-tests" -> "3a".
 *
 * Resolved against KNOWN_PHASES rather than against a shape regex, and that is the whole
 * repair: the previous `/^([0-5](?:\.5)?)-/` could not read a suffixed label, so the two
 * implementation phases this pipeline actually writes ("3a-qa-tests", "3b-dev") matched
 * nothing and were dropped by the caller's `continue`. On this change's own run that silently
 * discarded 4,088,488 ms -- 39% of the total lead time, and the single longest phase in it.
 *
 * A label whose leading token is not in KNOWN_PHASES returns null, and the caller does NOT
 * drop its time: it lands in `unattributed_ms`, which is a number a reader can see. Adding a
 * phase to KNOWN_PHASES is what teaches this function to attribute it, so the declaration and
 * the accounting cannot drift apart.
 */
function phaseKey(phase) {
  if (typeof phase !== "string") return null;
  const dash = phase.indexOf("-");
  const token = dash === -1 ? phase : phase.slice(0, dash);
  return KNOWN_PHASES.includes(token) ? token : null;
}

/**
 * Per-phase elapsed time from the events[] the orchestrator already writes.
 *
 * `review_rounds` is an EXPLICIT counter rather than an inference, and that is not a
 * preference: events[] items carry only `phase` and `at`, with no round field, so a round
 * count cannot be derived from them. When the caller has not maintained the counter, the
 * number of times the run ENTERED phase 4 is the honest floor, and it is reported as such.
 *
 * THE PARTITION PROPERTY, which is what makes an unreadable label loud instead of silent:
 *
 *     sum(phase_elapsed_ms) + unattributed_ms === total_lead_time_ms
 *
 * It holds by construction, not by coincidence. Every consecutive pair of timed events
 * contributes its delta to exactly ONE of the two sides, and consecutive deltas telescope to
 * last - first, which is the definition of total_lead_time_ms. So time that no phase key can
 * absorb -- an unrecognized label, or a boundary whose timestamps run backwards -- shows up as
 * a non-zero `unattributed_ms` rather than evaporating. `unattributed_ms` is negative only
 * when events[] is out of order, which is itself the signal.
 *
 * AND THE PARTITION'S OWN BLIND SPOT, WHICH IS WHY `untimed_events` EXISTS. Every number above
 * is computed over `timed`, INCLUDING the denominator: an event whose `at` is unparseable (or
 * whose `phase` is not a string) is dropped from the numerator and from `total_lead_time_ms`
 * alike, so the partition still balances and reports `unattributed_ms: 0`. It is a true
 * statement about a population that quietly lost a member. `[1-ba@00:00, 3a@"not-a-date",
 * 5-archive@02:00]` balanced perfectly while an event vanished. The drop CANNOT be folded into
 * `unattributed_ms` -- an event with no timestamp contributes no duration to attribute, so
 * there is no millisecond figure to carry -- so it is reported as its own COUNT instead. A
 * reader who sees `untimed_events > 0` knows the balance below it covers fewer events than the
 * record contains, which is exactly what the old shape could not say.
 *
 * @returns {{phase_elapsed_ms: Record<string, number>, total_lead_time_ms: number|null,
 *            unattributed_ms: number, unattributed_events: number, untimed_events: number,
 *            review_rounds: number, events_counted: number}}
 */
export function telemetry(status) {
  const s = status && typeof status === "object" ? status : {};
  const events = Array.isArray(s.events) ? s.events : [];
  const timed = events
    .map((e) => ({ phase: e && e.phase, at: parseTime(e && e.at) }))
    .filter((e) => typeof e.phase === "string" && e.at !== null);
  const untimed_events = events.length - timed.length;

  const phase_elapsed_ms = {};
  let unattributed_ms = 0;
  let unattributed_events = 0;
  for (let i = 0; i < timed.length - 1; i++) {
    const key = phaseKey(timed[i].phase);
    const delta = timed[i + 1].at - timed[i].at;
    // A negative delta is not a duration, so it is never credited to a phase; it is carried
    // in the unattributed bucket so the partition still balances and stays inspectable.
    if (key !== null && delta >= 0) {
      phase_elapsed_ms[key] = (phase_elapsed_ms[key] || 0) + delta;
    } else {
      unattributed_ms += delta;
      unattributed_events++;
    }
  }

  const total_lead_time_ms =
    timed.length >= 2 ? timed[timed.length - 1].at - timed[0].at : null;

  const entries = timed.filter((e) => /^4-review$/.test(e.phase)).length;
  const review_rounds = Number.isInteger(s.review_rounds) ? s.review_rounds : entries;

  return {
    phase_elapsed_ms,
    total_lead_time_ms,
    unattributed_ms,
    unattributed_events,
    untimed_events,
    review_rounds,
    events_counted: timed.length,
  };
}
