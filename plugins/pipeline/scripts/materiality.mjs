#!/usr/bin/env node
/**
 * Materiality: what a review finding is allowed to BLOCK on, decided by code rather than by
 * the reviewer's mood.
 *
 * WHY THE RULE WAS REWRITTEN (review convergence). The 0.40.0 rule blocked any
 * blocker/critical/high concern rated normal-use or edge-case, whatever it cost, and let a
 * VETO or a REQUEST_REFACTOR through untouched. Measured on one consumer: a single tooling
 * issue ran 21 spec revisions and 8 Phase 4 panel rounds with six reviewers, and produced 79
 * acceptance criteria, a 676-assertion prover and 35 follow-up issues. Every finding was real;
 * almost none could have cost a user anything. A rule that asks only "is it real?" never
 * converges, because a careful reviewer can always find a real edge case.
 *
 * So a concern now carries a FOURTH rating, `merge_class`, saying what merging the defect would
 * actually cost: wrong-pass (a gate or test reports green on a real failure), money, data-loss,
 * security-exposure, or none. The rule:
 *
 *   A concern BLOCKS only if ALL of:
 *     - severity is blocker, critical or high;
 *     - merge_class is not none;
 *     - likelihood is normal-use (cost_class product-money: also edge-case;
 *       merge_class security-exposure: also adversarial, since an exposure is by definition
 *       reached by someone acting outside the documented flow);
 *     - cost_class tooling: merge_class is wrong-pass or security-exposure (a tooling change
 *       cannot lose a customer's money or data, so those two classes are the ones it can cost).
 *   Everything else is a NOTE.
 *
 * THE CAP IS ENFORCED, not reported. At most BLOCKING_CAP concerns per reviewer stay blockers,
 * ranked by harm (data-or-security, money, user-visible, internal, cosmetic) and then by severity;
 * the rest are DEMOTED to notes and their ids listed in materiality.demoted_ids.
 *
 * VETO AND REQUEST_REFACTOR OBEY THE SAME TEST. A VETO stands only from SecOps, on a valid
 * veto_ground, carrying at least one blocking concern; otherwise it reads as REQUEST_CHANGES,
 * which does not return the spec to BA. A REQUEST_CHANGES or REQUEST_REFACTOR with no blocking
 * concern reads as APPROVE_WITH_NOTES. An APPROVE carrying a blocking concern reads as
 * REQUEST_CHANGES (a reviewer who rates a finding as blocking and approves has contradicted
 * itself, and the safe reading is the finding).
 *
 * UNRATED IS A NOTE NOW, AND SAYS SO. A concern missing severity, likelihood, harm or
 * merge_class (every shard written before this change) is read as a note and listed in
 * materiality.unrated_ids with a visible note. The previous fail-closed reading is what let a
 * legacy artifact hold a run open; the schema now requires the ratings, so a new shard cannot
 * omit them without the SubagentStop validator saying so.
 *
 * merge-peer-review.mjs applies normalizeBlock to every shard it folds, so the rubric in
 * commands/pipeline.md reads materiality.blocks_merge and the NORMALIZED verdict. The verdict
 * the reviewer actually returned is preserved beside it as verdict_as_returned whenever the two
 * differ, so the archive shows both the finding and the ruling on it.
 */

import { isMain } from "./lib.mjs";

export const LIKELIHOODS = ["normal-use", "edge-case", "adversarial", "hypothetical"];
export const REVERSIBILITIES = ["undo-button", "some-cleanup", "one-way-door"];
/** Ordered worst first: the cap keeps blockers from the front of this list. */
export const HARMS = ["data-or-security", "money", "user-visible", "internal", "cosmetic"];
/** schemas/definitions.schema.json#/definitions/mergeClass carries the same list. */
export const MERGE_CLASSES = ["wrong-pass", "money", "data-loss", "security-exposure", "none"];
export const COST_CLASSES = ["product-money", "product", "tooling"];
/** What a record with no cost_class reads as. */
export const DEFAULT_COST_CLASS = "product";

/** The severities that CAN block. Everything else (major, medium, low, nit, info) is a note. */
export const BLOCKING_SEVERITIES = ["blocker", "critical", "high"];

/**
 * The surfaces on which a SecOps VETO stands. schemas/definitions.schema.json#/definitions/
 * vetoGround carries the same list, and tests/test-materiality.sh asserts they agree.
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

/** At most this many blocking concerns per reviewer. Past the cap, the rest are demoted to notes. */
export const BLOCKING_CAP = 2;

/** Test-cost thresholds at cost_class tooling (a note, never a block). */
export const TEST_COST_ASSERTIONS = 100;
export const TEST_COST_SECONDS = 30;

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

export function normCostClass(v) {
  const c = lower(v);
  return COST_CLASSES.includes(c) ? c : DEFAULT_COST_CLASS;
}

/** The id a concern is known by: its own `id`, or <role>-<1-based index>. */
export function concernId(concern, role, index) {
  if (concern && typeof concern === "object" && typeof concern.id === "string" && concern.id.trim() !== "") {
    return concern.id.trim();
  }
  return `${role || "role"}-${index + 1}`;
}

/**
 * Rate one concern under a cost class. Returns { blocking, unrated, reason }. Pure; never throws
 * on a malformed concern (a non-object is a note with a reason saying so, because a crash here
 * would take the merge down and a missing merge is a missing review).
 */
export function rateConcern(c, costClass = DEFAULT_COST_CLASS) {
  if (!c || typeof c !== "object" || Array.isArray(c)) {
    return { blocking: false, unrated: false, reason: "not a concern object; ignored" };
  }
  const cc = normCostClass(costClass);
  const sev = lower(c.severity);
  const lk = lower(c.likelihood);
  const hm = lower(c.harm);
  const mc = lower(c.merge_class);
  const sevKnown = sev !== "";
  const rated = sevKnown && LIKELIHOODS.includes(lk) && HARMS.includes(hm) && MERGE_CLASSES.includes(mc);
  if (!rated) {
    const missing = [
      !sevKnown && "severity",
      !LIKELIHOODS.includes(lk) && "likelihood",
      !HARMS.includes(hm) && "harm",
      !MERGE_CLASSES.includes(mc) && "merge_class",
    ].filter(Boolean);
    return {
      blocking: false,
      unrated: true,
      reason: `UNRATED (no valid ${missing.join(", ")}): read as a note, never as a blocker. Rate it if it should block.`,
    };
  }
  if (!BLOCKING_SEVERITIES.includes(sev)) {
    return { blocking: false, unrated: false, reason: `severity ${sev} is a note, not a block` };
  }
  if (mc === "none") {
    return { blocking: false, unrated: false, reason: "merge_class none: real, but merging it costs no money, data, security or a false green" };
  }
  if (cc === "tooling" && mc !== "wrong-pass" && mc !== "security-exposure") {
    return { blocking: false, unrated: false, reason: `cost_class tooling blocks only on wrong-pass or security-exposure, not ${mc}` };
  }
  const likelihoodBlocks =
    lk === "normal-use" ||
    (lk === "edge-case" && cc === "product-money") ||
    (lk === "adversarial" && mc === "security-exposure");
  if (!likelihoodBlocks) {
    return { blocking: false, unrated: false, reason: `likelihood ${lk} does not block ${mc} at cost_class ${cc}` };
  }
  return { blocking: true, unrated: false, reason: `${lk} ${mc} at severity ${sev} (cost_class ${cc})` };
}

/**
 * The order the cap keeps blockers in, worst first. merge_class leads because it is the rating
 * that decided the concern blocks at all; harm is a second, more subjective rating, and a
 * critical normal-use data-loss concern with a mis-rated harm must not be demoted behind a
 * lesser one.
 */
export const MERGE_CLASS_RANK = ["wrong-pass", "money", "data-loss", "security-exposure"];

function mergeClassRank(c) {
  const i = MERGE_CLASS_RANK.indexOf(lower(c && c.merge_class));
  return i === -1 ? MERGE_CLASS_RANK.length : i;
}
function harmRank(c) {
  const i = HARMS.indexOf(lower(c && c.harm));
  return i === -1 ? HARMS.length : i;
}
function severityRank(c) {
  const i = BLOCKING_SEVERITIES.indexOf(lower(c && c.severity));
  // blocker and critical rank together above high.
  return i === -1 ? 9 : i <= 1 ? 0 : 1;
}

/**
 * Rank the blocking concerns and split them at the cap. `entries` is [{ concern, id, index }].
 * Ranked by merge_class, then harm, then severity; stable, so ties keep the reviewer's order.
 */
export function applyCap(entries, cap = BLOCKING_CAP) {
  const ranked = [...entries].sort(
    (a, b) =>
      mergeClassRank(a.concern) - mergeClassRank(b.concern) ||
      harmRank(a.concern) - harmRank(b.concern) ||
      severityRank(a.concern) - severityRank(b.concern) ||
      a.index - b.index,
  );
  return { kept: ranked.slice(0, cap), demoted: ranked.slice(cap) };
}

/**
 * The consolidation note QA's test_cost earns at cost_class tooling, or null. Numbers only in,
 * one sentence out. A missing or partial measurement is null: this is a note, and a note that
 * fires on absent data is noise.
 */
export function testCostNote(testCost, costClass) {
  if (normCostClass(costClass) !== "tooling" || !testCost || typeof testCost !== "object") return null;
  const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
  const a0 = num(testCost.assertions_before);
  const a1 = num(testCost.assertions_after);
  const s0 = num(testCost.prepush_seconds_before);
  const s1 = num(testCost.prepush_seconds_after);
  const parts = [];
  if (a0 !== null && a1 !== null && a1 - a0 > TEST_COST_ASSERTIONS) parts.push(`${a1 - a0} assertions (over ${TEST_COST_ASSERTIONS})`);
  if (s0 !== null && s1 !== null && s1 - s0 > TEST_COST_SECONDS) parts.push(`${Math.round((s1 - s0) * 10) / 10} s of pre-push time (over ${TEST_COST_SECONDS} s)`);
  if (parts.length === 0) return null;
  return `TEST COST: this tooling change adds ${parts.join(" and ")}; propose consolidating the new checks into fewer, table-driven cases. A note, not a blocker.`;
}

/**
 * Normalize one reviewer block. Returns a NEW object; the input is not mutated. A block with
 * no string verdict is returned as-is (the merge halts on it separately).
 *
 * opts.costClass: the run's cost_class (status.json). Absent reads as product.
 */
export function normalizeBlock(block, role, opts = {}) {
  if (!block || typeof block !== "object" || Array.isArray(block)) return block;
  const current = normVerdict(block.verdict);
  if (!current) return block;
  const costClass = normCostClass(opts.costClass);

  // THE INCOMING materiality RECORD IS NEVER TRUSTED. It is recomputed from the concerns on every
  // pass: a record carried over from an earlier pass, or written by hand, would let a shard whose
  // verdict or concerns changed since keep a blocks_merge:false it no longer earns (the review
  // repro: a normalized block edited to REQUEST_CHANGES with a normal-use data-loss blocker
  // re-normalized to blocks_merge:false).
  //
  // IDEMPOTENCE without trust: when the block records verdict_as_returned, the ruling is
  // recomputed from THAT verdict too, and used when it reproduces the verdict the block now
  // carries, so a re-merge keeps the first pass's notes. The rating itself comes from the
  // concerns either way, so the choice changes only which explanation is recorded.
  const fromCurrent = rule(block, current, role, costClass);
  const asReturned = normVerdict(block.verdict_as_returned);
  const fromReturned = asReturned && asReturned !== current ? rule(block, asReturned, role, costClass) : null;
  const r = fromReturned && fromReturned.effective === current ? fromReturned : fromCurrent;

  const out = { ...block, verdict: r.effective };
  if (r === fromReturned) {
    out.verdict_as_returned = block.verdict_as_returned;
  } else if (r.effective !== String(block.verdict).trim().toUpperCase()) {
    out.verdict_as_returned = block.verdict;
  } else {
    delete out.verdict_as_returned;
  }
  out.materiality = r.materiality;
  return out;
}

/** One ruling of a block's concerns from a given returned verdict. Pure. */
function rule(block, raw, role, costClass) {
  const concerns = Array.isArray(block.concerns) ? block.concerns : [];
  const rated = concerns.map((c, index) => ({
    concern: c,
    index,
    id: concernId(c, role, index),
    positional: !(c && typeof c === "object" && typeof c.id === "string" && c.id.trim() !== ""),
    rating: rateConcern(c, costClass),
  }));
  const { kept, demoted } = applyCap(rated.filter((x) => x.rating.blocking));
  const blocking = kept.length;
  const unratedIds = rated.filter((x) => x.rating.unrated).map((x) => x.id);
  const positionalIds = rated.filter((x) => x.positional && x.rating.blocking).map((x) => x.id);
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
        `VETO without a veto_ground in [${VETO_GROUNDS.join(", ")}] reads as REQUEST_CHANGES: it does not send the spec back to BA.`,
      );
    } else if (blocking === 0) {
      effective = "REQUEST_CHANGES";
      notes.push(
        `VETO on ${ground} carries no BLOCKING concern under the materiality rule, so it reads as REQUEST_CHANGES and does not send the spec back to BA.`,
      );
    }
  }

  if ((effective === "REQUEST_CHANGES" || effective === "REQUEST_REFACTOR") && blocking === 0) {
    notes.push(
      concerns.length === 0
        ? `${effective} with no concerns at all reads as APPROVE_WITH_NOTES.`
        : `${effective} with no BLOCKING concern reads as APPROVE_WITH_NOTES: every concern is a note under the materiality rule (cost_class ${costClass}).`,
    );
    effective = "APPROVE_WITH_NOTES";
  }

  if ((effective === "APPROVE" || effective === "APPROVE_WITH_NOTES") && blocking > 0) {
    effective = "REQUEST_CHANGES";
    notes.push(`${raw} carrying ${blocking} blocking concern(s) reads as REQUEST_CHANGES (fail closed).`);
  }

  if (unratedIds.length > 0) {
    notes.push(
      `UNRATED: ${unratedIds.join(", ")} carry no valid severity, likelihood, harm or merge_class and were read as notes; a concern must be rated to block.`,
    );
  }
  if (demoted.length > 0) {
    notes.push(
      `${blocking + demoted.length} blocking concerns exceed the cap of ${BLOCKING_CAP}: kept ${kept.map((k) => k.id).join(", ")} (worst merge_class, then harm, first) and demoted ${demoted.map((d) => d.id).join(", ")} to notes; the demoted ids stay listed to this role on the next delta round.`,
    );
  }
  if (positionalIds.length > 0) {
    notes.push(
      `POSITIONAL ID: ${positionalIds.join(", ")} block but carry no \`id\`, so they are named by position and can drift if a later shard reorders its concerns (a legacy shard; the schema requires an id on every blocker/critical/high concern).`,
    );
  }
  const costNote = lower(role) === "qa" ? testCostNote(block.test_cost, costClass) : null;
  if (costNote) notes.push(costNote);

  const openIds = VERDICTS_THAT_BLOCK.includes(effective) ? kept.map((k) => k.id) : [];
  return {
    effective,
    materiality: {
      cost_class: costClass,
      blocking_concerns: blocking,
      open_blocker_ids: openIds,
      demoted_ids: demoted.map((d) => d.id),
      positional_ids: positionalIds,
      unrated_concerns: unratedIds.length,
      unrated_ids: unratedIds,
      over_cap: demoted.length > 0,
      blocks_merge: openIds.length > 0,
      notes,
    },
  };
}

/** True when a merged block refuses the merge, reading a legacy record the safe way. */
function blockRefuses(block) {
  if (!block || typeof block !== "object") return false;
  const m = block.materiality;
  if (m && typeof m === "object") {
    if (m.blocks_merge === true) return true;
    if (Array.isArray(m.open_blocker_ids) && m.open_blocker_ids.length > 0) return true;
    return false;
  }
  // No materiality record at all: a block that never went through this normalizer. Its verdict
  // word is the only evidence, and a blocking word is read as blocking.
  return VERDICTS_THAT_BLOCK.includes(normVerdict(block.verdict));
}

/**
 * The roles that must be reseated on a delta round: every role whose merged block refuses the
 * merge. That includes a LEGACY block carrying blocks_merge:true with no open_blocker_ids, and
 * a block with no materiality record whose verdict blocks: an empty seed there would silently
 * drop the objector (commands/pipeline.md "Delta re-review").
 */
export function openBlockerRoles(peerReview) {
  if (!peerReview || typeof peerReview !== "object") return [];
  const out = [];
  for (const [role, block] of Object.entries(peerReview)) {
    if (block && typeof block === "object" && !Array.isArray(block) && typeof block.verdict === "string" && blockRefuses(block)) out.push(role);
  }
  return out;
}

/**
 * Every open and demoted blocker in a merged peer-review.json, as [{ role, id, demoted }]. A
 * seated role whose record names no ids (a legacy block) yields one entry with id null.
 */
export function openBlockers(peerReview) {
  const out = [];
  for (const role of openBlockerRoles(peerReview)) {
    const m = peerReview[role].materiality || {};
    const open = Array.isArray(m.open_blocker_ids) ? m.open_blocker_ids : [];
    const demoted = Array.isArray(m.demoted_ids) ? m.demoted_ids : [];
    for (const id of open) out.push({ role, id, demoted: false });
    for (const id of demoted) out.push({ role, id, demoted: true });
    if (open.length === 0) out.push({ role, id: null, demoted: false });
  }
  return out;
}

/**
 * The final verdict the rubric computes, from the materiality records rather than from the
 * verdict words: blocks_merge decides whether the merge is refused, and the effective verdict
 * only says which loop it takes. Exposed so the rubric has a code form a test can pin.
 */
export function finalVerdict(peerReview, roles) {
  const blocks = (roles || []).map((r) => (peerReview && peerReview[r]) || null);
  const blocking = blocks.filter((b) => blockRefuses(b));
  const v = (b) => normVerdict(b && b.verdict);
  if (blocking.some((b) => v(b) === "VETO")) return "SECOPS_VETO";
  if (blocking.some((b) => v(b) === "REQUEST_REFACTOR")) return "REQUEST_REFACTOR";
  if (blocking.length > 0) return "REQUEST_CHANGES";
  if (blocks.some((b) => v(b) === "APPROVE_WITH_NOTES")) return "APPROVE_WITH_NOTES";
  if (blocks.length > 0 && blocks.every((b) => v(b) === "APPROVE")) return "APPROVE";
  return null;
}

/**
 * The blocking table for one cost class, DERIVED from rateConcern rather than restated, so the
 * printed rule and the applied rule are one function (#164 row 18). A row per merge_class that
 * can block, a column per likelihood; the cell is what a blocker/critical/high concern rated that
 * way does. Severity is not a column: below high nothing blocks at any cost class.
 */
export function explainTable(costClass) {
  const cc = normCostClass(costClass);
  const rows = MERGE_CLASSES.map((mc) => ({
    merge_class: mc,
    cells: LIKELIHOODS.map((lk) => (rateConcern({ severity: "high", likelihood: lk, harm: "internal", merge_class: mc }, cc).blocking ? "BLOCKS" : "note")),
  }));
  return { cost_class: cc, likelihoods: LIKELIHOODS, rows };
}

export function explainText(costClass) {
  const t = explainTable(costClass);
  const w = Math.max(...MERGE_CLASSES.map((m) => m.length));
  const lw = Math.max(...LIKELIHOODS.map((l) => l.length));
  const pad = (s, n) => s + " ".repeat(Math.max(0, n - s.length));
  const lines = [
    `Materiality at cost_class ${t.cost_class}: what a concern of severity ${BLOCKING_SEVERITIES.join(", ")} does.`,
    `${pad("merge_class", w)}  ${t.likelihoods.map((l) => pad(l, lw)).join("  ")}`,
    ...t.rows.map((r) => `${pad(r.merge_class, w)}  ${r.cells.map((c) => pad(c, lw)).join("  ")}`),
    `Any other severity (${["major", "medium", "low", "nit", "info"].join(", ")}) is a note. A concern missing severity, likelihood, harm or merge_class is an UNRATED note.`,
    `Cap: at most ${BLOCKING_CAP} blocking concerns per reviewer, ranked by merge_class (${MERGE_CLASS_RANK.join(", ")}), then harm (${HARMS.join(", ")}), then severity; the rest are demoted to notes and listed back on the next delta round.`,
    `Verdicts: REQUEST_CHANGES or REQUEST_REFACTOR with no blocking concern reads as APPROVE_WITH_NOTES; APPROVE carrying one reads as REQUEST_CHANGES. VETO stands only from SecOps, on a veto_ground in [${VETO_GROUNDS.join(", ")}], with a blocking concern; otherwise it reads as REQUEST_CHANGES.`,
  ];
  return lines.join("\n");
}

const USAGE = `usage: node materiality.mjs --explain <${COST_CLASSES.join(" | ")}> [--json]`;

export function cli(argv, { out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s) } = {}) {
  const i = argv.indexOf("--explain");
  const cc = i === -1 ? undefined : argv[i + 1];
  if (i === -1 || cc === undefined || cc.startsWith("--")) {
    err(`${USAGE}\n`);
    return 1;
  }
  if (!COST_CLASSES.includes(lower(cc))) {
    err(`unknown cost_class "${cc}"; one of ${COST_CLASSES.join(", ")}\n${USAGE}\n`);
    return 1;
  }
  out(argv.includes("--json") ? `${JSON.stringify(explainTable(cc), null, 2)}\n` : `${explainText(cc)}\n`);
  return 0;
}

// Self-run only as a real CLI entry: an eval that imports this module with its own path in argv[1]
// must not run the CLI (the hazard voice-lint.mjs documents at its foot).
const evalEntry = process.execArgv.some((x) => x === "-e" || x === "--eval" || x === "--input-type=module" || /^--eval=/.test(x));
if (isMain("materiality.mjs") && !evalEntry) process.exit(cli(process.argv.slice(2)));
