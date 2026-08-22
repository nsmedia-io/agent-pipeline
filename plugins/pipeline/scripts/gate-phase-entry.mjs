#!/usr/bin/env node
/**
 * The phase-entry guard: decides whether the run recorded in `.pipeline/<issue>/status.json`
 * is allowed to be where it says it is.
 *
 *   node gate-phase-entry.mjs [--root <project-root>]
 *
 * Prints ONE line of JSON on a decision -- {"decision","reason","issue_dir"} -- and exits 2 on
 * `refused`, 0 on `granted` and `not-applicable`. A tooling failure prints NOTHING and exits 0.
 *
 * WHAT IT IS. A turn-boundary consistency gate, wired into hooks/stop.sh. It prevents a turn
 * from ENDING in a state whose prerequisites are absent, and forces the orchestrator to either
 * do the missed work or say in writing that it skipped it.
 *
 * WHAT IT IS NOT (verbatim from the spec's guarantee_and_threat_model, because a stated limit
 * that gets paraphrased is how a limit becomes a guarantee):
 * A pre-dispatch airlock. It CANNOT prevent a phase being skipped mid-turn; the phase's absence is detected when the turn tries to end. The cost of a skip is therefore the wasted work in that turn, not zero. Work already done in this turn is not undone.
 *
 * WHOSE RUN IT JUDGES, AND THE LIMITATION IT INHERITS. The active issue is resolved through
 * validate-pipeline-artifact.mjs's activeIssueDir seam. That seam's top-priority `active_issue`
 * marker is populated from a SubagentStop payload, NOT the Stop payload, so from this hook the
 * active issue will almost always resolve through the mtime fallback: the newest status.json
 * among the issue dirs. Two consequences are load-bearing and neither is hypothetical:
 *   - The Stop hook is PROJECT-scoped, not run-scoped, so without a recency ceiling an
 *     abandoned run parked at a guarded phase would refuse every turn in that project forever.
 *     Hence the in-flight predicate below (R6). Its 24h / no-final-verdict window is a SECOND
 *     copy of the one pipeline-status.mjs holds in its `stuck` filter, not a shared symbol: see
 *     the drift note above `inFlight`, which is where that duplication lives and where #74
 *     tracks it.
 *   - An explicit signal (CLAUDE_PIPELINE_ACTIVE_ISSUE / PIPELINE_ACTIVE_ISSUE) must not be
 *     able to NARROW the subject: pointing it at a satisfied dir would be the env-var opt-out
 *     the design rejected, and it would leave no trace in the archived record. So both the
 *     signal-named dir and the mtime-derived dir are evaluated, and EITHER may refuse (R6b).
 *   - A TIE in that mtime fallback resolves to NO subject, and this guard then falls silent.
 *     Stated as a limitation rather than left to be discovered, because it is a DISARM VECTOR
 *     that nobody has to choose: a fresh `git clone` writes every tracked status.json inside a
 *     single coarse-clock tick on Linux, so all of them share one mtime and the seam abstains
 *     (#27). The alternative was judging a run on a dir picked by readdirSync order, which is
 *     what this used to do -- and which made the subject a property of the filesystem rather
 *     than of the tree. Abstaining is the accepted trade: this guard would rather judge nothing
 *     than judge a run the session does not own. It lands on the fail-open tooling branch R11
 *     already declares ("no resolvable active issue"), so the fail-direction split is unchanged.
 *     Pinned in tests/test-gate-phase-entry.sh with a tie-breaking control (re-derive with
 *     `git grep -n 'an mtime tie is DETERMINISTIC' plugins/pipeline/tests/`, one hit). Cited by
 *     the cell's own text, not by an AC number: this said "AC14 cell (c)" and no cell of that
 *     letter exists anywhere in the AC12-AC14 range, so the label named nothing.
 *
 * FAIL-DIRECTION SPLIT (R11), which is a contract change to a hook that declares itself
 * fail-open, so it is stated in both places. The DECISION is fail-CLOSED: a recognised phase
 * whose prerequisite is absent refuses. The TOOLING is fail-OPEN: node absent, this file
 * absent, status.json absent or unparseable, no resolvable active issue, or any thrown error
 * exits 0 in silence. The events are in different environments, which is the whole reason the
 * split is legitimate: a skipped phase happens inside the agent session and is discretion; a
 * missing Node install happens in the operator's environment and is not. Because that
 * fail-open is permanently invisible, hooks/session-start.sh reports it once per session.
 *
 * VOCABULARY. This module declares NO phase list and NO phase-shape regex of its own. Event
 * labels resolve through the shared phaseKey/KNOWN_PHASES resolver, and every token in every
 * satisfying set below is asserted by the drift suite to be a member of the imported
 * KNOWN_PHASES. Prefix / startsWith comparison is forbidden by name: `"2.5"` shares a leading
 * character with `"2"`, so a prefix rule lets a recorded 2.5-design skip clear the Phase 2
 * review gate it never ran.
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

import { isMain } from "./lib.mjs";
import { KNOWN_TIERS } from "./dispatch-model.mjs";
import { phaseKey } from "./pipeline-telemetry.mjs";
import { activeIssueDir } from "./validate-pipeline-artifact.mjs";

/**
 * The 15 guarded rows: the 8 phases pipeline.md checkpoints into ("Checkpoint first:") and the
 * 7 `<phase>-complete` literals it parks at. Each row carries its own prerequisite file and its
 * own SATISFYING TOKEN SET -- the tokens that, seen in events[], stand in for that file.
 *
 * TWO EXCLUSIONS ARE LOAD-BEARING, and each closes a hole traced on real records.
 *   - `2.5-design` satisfies on {2}, NOT {2, 2.5}. Its own token must not appear, or the
 *     recorded 2.5-design SKIPPED entry in .pipeline/17 would self-grant the phase it skipped.
 *   - `4-review` and `3-impl-complete` satisfy on {3, 3b} and EXCLUDE 3a. An events[] carrying
 *     only 3a-qa-tests means QA authored the contract and Dev was never dispatched; granting
 *     there would declare a run panel-ready when the implementation step never ran.
 *
 * `content` marks a row whose prerequisite is not satisfied by mere presence. Such a row is
 * strictly weaker through events[] than through the file, because an event attests DISPATCH,
 * never APPROVAL, and that asymmetry is stated rather than defended against.
 *
 * `also` is a SECOND requirement on the same row, carrying its own file, its own token set and
 * its own optional `content`. It is checked only after the primary one passes, so a refusal
 * never names two files at once and the message keeps its single-route shape. THE ARITY IS TWO,
 * and the ceiling is defended rather than assumed: a third requirement written as a nested
 * `also.also` would be both invisible to `satisfyingTokens` and inert on the decision path -- a
 * written requirement silently not enforced, the guard claiming more than it knows -- so the
 * table's key sets are asserted as a shape (re-derive with `git grep -n 'rowShapes'
 * plugins/pipeline/tests/test-gate-phase-entry.sh`). An `also` on a `byTier` cell is legal and
 * fully live on both paths; measured, not assumed. Nothing needs one today.
 */
const PREREQUISITES = {
  "0.5-map": { file: null, tokens: [] },
  // The `tiers` key survives for the REWORK RE-ENTRY only: a second visit to this checkpoint can
  // find a tier already in the field, and there the row applies normally. It cannot police a
  // first visit, because the checkpoint is written before the dispatch that returns the tier --
  // which is why the map obligation is now ALSO stated at `2-review`, where the routing itself is
  // the tier evidence. Do not delete this key: commands/pipeline.md publishes a re-derivation
  // command asserting exactly one hit, and it is this one.
  "1-ba": { file: "map.json", tokens: ["0.5"], tiers: ["architectural"] },
  "2-constraints": { file: "spec.json", tokens: ["1"], content: "ba-approved" },
  "2-review": {
    file: "spec.json",
    tokens: ["1"],
    content: "ba-approved",
    also: { file: "map.json", tokens: ["0.5"] },
  },
  "2.5-design": { file: "review.json", tokens: ["2"] },
  "3-impl": {
    byTier: {
      trivial: { file: "spec.json", tokens: ["1"] },
      standard: { file: "constraints.md", tokens: ["2"], content: "non-empty" },
      architectural: { file: "design.json", tokens: ["2.5"] },
    },
  },
  "4-review": { file: "impl-report.json", tokens: ["3", "3b"] },
  "5-archive": { file: "peer-review.json", tokens: ["4"] },
  "0.5-map-complete": { file: "map.json", tokens: ["0.5"] },
  "1-ba-complete": { file: "spec.json", tokens: ["1"] },
  "2-constraints-complete": { file: "constraints.md", tokens: ["2"] },
  "2-review-complete": { file: "review.json", tokens: ["2"] },
  "2.5-design-complete": { file: "design.json", tokens: ["2.5"] },
  "3-impl-complete": { file: "impl-report.json", tokens: ["3", "3b"] },
  "4-review-complete": { file: "peer-review.json", tokens: ["4"] },
};

const GUARDED = Object.keys(PREREQUISITES);

/** The entry/exit split is DERIVED from the one table, so the two cannot drift apart. */
export const ENTRY = GUARDED.filter((p) => !p.endsWith("-complete"));
export const EXIT = GUARDED.filter((p) => p.endsWith("-complete"));

/**
 * Phases that are explicitly NOT guarded: a run parked in a halt, a tripwire, an open-questions
 * pause or a rework state has already stopped, and refusing its turn would trap the owner in
 * the state the halt exists to surface.
 */
export const UNGUARDED = [
  "1-ba-open-questions",
  "1-ba-rework-required",
  "2.5-design-owner-decision",
  "3-impl-frontend-gate-failed",
  "3-impl-gate-failed",
  "3-impl-live-verify-unverified",
  "3-impl-tripwire",
  "3-impl-tripwire-indeterminate",
  "4-veto-rework-required",
];

/**
 * The terminal literal pipeline.md writes. The runtime terminal check below is wider than this
 * set on purpose (it also covers `halted-error`, any `<phase>-error` instantiation, and any
 * record carrying `completed_at`), but only the pipeline.md literal belongs in the set the
 * drift suite partitions.
 */
export const TERMINAL = ["5-archived"];

export const IN_FLIGHT_MS = 24 * 60 * 60 * 1000;

/**
 * An unusable risk_tier resolves to the STRICTEST row, never the loosest. That default is right
 * for a `byTier` row, which is only reached at a phase where BA has already returned a tier,
 * and it is WRONG for a row that exists at one tier BECAUSE its prerequisite is not producible
 * at the others: the 1-ba checkpoint is written before BA runs, so the risk_tier at 1-ba is
 * whatever an EARLIER write left there, never the output of the BA dispatch this checkpoint
 * precedes -- and when no earlier write set it, resolving that ABSENCE to the strictest row
 * demands an artifact the other two tiers are told not to produce. STATED WITHOUT A UNIVERSAL
 * on purpose. Two earlier versions of this sentence each asserted one -- "at 1-ba the risk_tier
 * is necessarily absent", then the same claim scoped "on the first visit" -- and the committed
 * corpus falsified both, because ABSENCE is one shape here and not the shape. Phase 0.5 is
 * itself GATED BY TIER (re-derive with `git grep -n 'Gate by risk tier'
 * plugins/pipeline/commands/pipeline.md`, one hit, whose map dispatch interpolates the tier), so
 * a record whose 0.5-map has run reaches its FIRST 1-ba checkpoint with a tier already in the
 * field; a rework re-entry is a second and rarer route to the same shape, since the
 * durable-checkpoint convention re-writes the phase before EACH BA dispatch. Read the earliest
 * 1-ba state of each committed record with `git log --reverse --format=%h --
 * .pipeline/<n>/status.json`: .pipeline/34 arrives with no tier and an empty events[], while
 * .pipeline/exp-airlock and .pipeline/exp-claims both arrive carrying `architectural` with
 * 0.5-map already recorded. Whichever shape it is, a tier that IS present is read normally and
 * the row applies -- which is what the architectural cell of this family asserts. So the
 * tiers-restricted path -- and only that path -- takes a separate DETERMINATION signal,
 * computed from the RAW field at the call site and passed to `appliesAtTier`; a row carrying a
 * `tiers` key does not apply when the tier is undetermined. Re-derive the ordering claim with
 * `git grep -n 'current_phase: "1-ba"' -- plugins/pipeline/commands/pipeline.md`, which returns
 * exactly one hit, the Phase 1 mandate -- NOT `git grep -n 'Checkpoint first'`, which returns
 * one hit per phase and so cannot answer the question it is being asked. That one hit is one
 * MANDATE, not one VISIT: it is obeyed before every BA dispatch, so counting the hits does not
 * count the times the record sits at this phase. Reading it the other way is what made both of
 * the since-deleted `necessarily` versions named above look true.
 *
 * WHAT THIS COSTS AT `1-ba`, stated accurately because the comfortable version of the sentence
 * is false the moment it is written: `1-ba` is the only row carrying a tier restriction
 * (re-derive with `git grep -n 'tiers: \[' plugins/pipeline/scripts/gate-phase-entry.mjs`), and
 * on the path pipeline.md mandates that row's map.json obligation cannot police a first visit at
 * any tier. A row gated on a resolved tier cannot fire while the tier is still absent, and where
 * a tier IS in the field this early it is there BECAUSE 0.5 ran -- the same run whose `0.5` event
 * satisfies the row. So on the mandated path the row either does not apply or is already
 * satisfied when it does. (The corpus above is the evidence: the two records that arrive at
 * `1-ba` carrying `architectural` carry `0.5-map` in events[] as well.) What was traded away is
 * an UNDISCRIMINATING refusal -- the row used to refuse trivial, standard and architectural alike
 * at `1-ba` -- and what was bought is the removal of a first-turn refusal that teaches its
 * operator to reach for this guard's widest disarm. The key is kept, and the rework re-entry is
 * the one thing it still does.
 *
 * WHERE THE OBLIGATION IS ENFORCED INSTEAD (#61): the map.json requirement now lives on the
 * 2-review row, as a SECOND requirement beside that row's existing ba-approved spec.json check
 * rather than in place of it -- swapping would have deleted the only ba-approved gate an
 * architectural run ever reaches. That row takes no tier restriction of any kind, and does not
 * need one, because the PHASE NAME is the tier evidence and a strictly better one than the
 * record's own field: `risk_tier` is optional in status.schema.json and no script writes it,
 * while `current_phase` is written by the orchestrator following pipeline.md's routing.
 *
 * WHY THAT ROW, on two measured properties, each cited by a command rather than by a number that
 * would rot. ROUTING: pipeline.md mandates a checkpoint into `2-review` on the architectural
 * route only, and mandates no checkpoint into any `<phase>-complete` literal -- re-derive the
 * pair with `git grep -c 'Checkpoint first.*current_phase: "2-review"'
 * plugins/pipeline/commands/pipeline.md` and the same command with `1-ba-complete`, which must
 * return 1 and 0. The naive `git grep -c 'current_phase: "2-review"'` does NOT discriminate: it
 * returns 1 for this row and 1 for every `-complete` literal too, so it answers the same for the
 * row that was chosen and the row that was rejected. OCCUPANCY: five of the fifteen guarded rows
 * have never been a persisted `current_phase` in any commit of any ref, and all five are
 * `-complete` literals the orchestrator passes THROUGH in a single write; a requirement sited on
 * one of those is unreachable in production however green its tests are. Take that census, never
 * quote a stored count -- every run checkpoints into the corpus being counted, so the figure
 * decays between readings while the ZEROES do not:
 * `git log --all --format=%H | while read s; do git ls-tree -r --name-only $s | grep -E
 * '^\.pipeline/[^/]+/status\.json$' | while read f; do echo "$(git rev-parse $s:$f)|$f|$(git
 * show $s:$f | grep -o '"current_phase": *"[^"]*"')"; done; done | sort -u`.
 *
 * THE SECOND COST, accepted: a typo'd risk_tier turns a tiers-restricted row OFF rather than
 * ON. That does not contradict the strictest default above; it is the same rule one function
 * down, where `inFlight` refuses to hold a project's turns open on a record it cannot DATE. A
 * record it cannot TIER is the same shape. Note the precedent's limit: pipeline-status.mjs's
 * `resolveTier` renders an ABSENT tier as `-` but passes a MALFORMED one through verbatim
 * (re-derive with `git grep -n 'function resolveTier' plugins/pipeline/scripts/pipeline-status.mjs`),
 * so it supports the absent half of this rule only. Treating a typo as undetermined is a new
 * judgement, and it rests on the trade above rather than on a borrowed precedent.
 *
 * A THIRD instance of the same fail-open DIRECTION -- third in THIS header's sequence of costs,
 * which is not the numbering of the inventory below -- deliberate rather than overlooked: a
 * record this guard cannot VALIDATE as concluded is taken at its word. `completed_at` is never
 * parsed, so `"TBD"` reads as finished, and `final_verdict` is truthy-tested rather than against
 * status.schema.json's closed enum, so `"pending"` reads as concluded.
 *
 * THE ABSTENTION INVENTORY, so whoever adds the NEXT way for this guard to say nothing sees the
 * existing ones together. MEMBERSHIP, stated because an inventory with no membership rule
 * cannot be checked for completeness: abstentions that are SILENT, or that skip a row this
 * guard RECOGNISES. The terminal, not-in-flight and UNGUARDED declines are scope rules -- this
 * guard deciding a record is not its subject -- and are documented at their own sites, not
 * here; so is the paragraph directly above, which takes a record at its word about being
 * concluded. (1) Tooling fail-open: an unreadable or non-object record returns null and the
 * caller renders silence -- rc 0 and empty stdout, which an rc-only reader cannot tell from a
 * pass. (2) An mtime tie resolves to NO active issue rather than to readdir order (re-derive
 * with `git log --oneline --grep 'mtime tie'`). (3) This undetermined-tier row-off, which since
 * #61 skips only the `1-ba` rework re-entry check and no longer decides whether the map
 * obligation is enforced at all -- the count of abstaining rows is unchanged, what changed is
 * what the abstention costs. The set is asserted on the OUTCOME rather than on this sentence
 * (re-derive with `git grep -n 'exactly ONE guarded row abstains'
 * plugins/pipeline/tests/test-gate-phase-entry.sh`), because an inventory is prose and prose
 * cannot fail.
 *
 * Split, because the conjunction claimed the wrong thing: (3) is the only one that names itself
 * in its own OUTPUT. (2) is silent, but it IS pinned, with a tie-breaking control (re-derive
 * with `git grep -n 'an mtime tie is DETERMINISTIC' plugins/pipeline/tests/`). (1) is neither.
 * And "its own output" means stdout, which is not the operator's experience: hooks/stop.sh runs
 * this guard with stdout discarded and branches only on rc 2, so NO not-applicable route --
 * including (3) -- is visible through the Stop hook (re-derive with
 * `git grep -n 'GATE_ERR=' plugins/pipeline/hooks/stop.sh`, one hit, which is the invocation
 * itself; `2>&1 >/dev/null` also matches the voice-lint call and so does not discriminate).
 * Add the next abstention to
 * this list on the day it is written, not after it has hidden something.
 *
 * EVERY CITATION ABOVE IS BY QUOTED TEXT OR SYMBOL PLUS A COMMAND THAT RE-DERIVES IT, never by
 * line number, and each command must DISCRIMINATE -- one that returns eight hits answers
 * nothing. This is not house style: three line citations drifted inside this one issue's own
 * record -- pipeline.md's `1-ba` checkpoint mandate, which was cited 30 lines above where it
 * then sat; the knowledge store's citation of this file's `halted-error` line, which had
 * already moved once and which THIS VERY COMMENT then moved again; and a test token cited one
 * line off. All three measured at 2ec6dd7, and NO destination is restated here, because the
 * destination is the part that rots: publishing a fresh coordinate in the sentence that warns
 * about coordinates is how the second of those three got its third wrong value. This comment
 * is permanent and defended by a test, so a stale coordinate would rot inside a defended
 * artifact.
 */
function normalizeTier(tier) {
  return KNOWN_TIERS.includes(tier) ? tier : "architectural";
}

function rowFor(phase, tier) {
  const raw = PREREQUISITES[phase];
  if (!raw) return null;
  if (raw.byTier) return raw.byTier[tier] || raw.byTier.architectural;
  return raw;
}

/**
 * A row that only exists at some tiers. `tierDetermined` has NO DEFAULT and must be derived
 * from the RAW `status.risk_tier`, never from `normalizeTier`'s output: that output is a member
 * of KNOWN_TIERS for every input, so deriving it there is always true and silently restores the
 * behaviour this parameter exists to change.
 */
function appliesAtTier(phase, tier, tierDetermined) {
  const raw = PREREQUISITES[phase];
  if (!raw || !raw.tiers) return true;
  if (!tierDetermined) return false;
  return raw.tiers.includes(tier);
}

/**
 * The row's satisfying token set. Empty for a phase with no prerequisite and for any phase that
 * is not a guarded row, so a caller cannot read "no tokens" as "any token will do".
 *
 * The UNION over both halves of a two-requirement row, because this is the only surface through
 * which the drift suite enumerates what the guard will accept: a token the decision path honours
 * but this function does not return is invisible to the one check that exists to catch strays.
 * The union is a REPORTING surface and is never fed back into `eventsSatisfy` -- each half is
 * matched against its OWN tokens, or a `1-ba` event would stand in for the map.
 */
export function satisfyingTokens(phase, tier) {
  const row = rowFor(phase, normalizeTier(tier));
  if (!row) return [];
  const own = Array.isArray(row.tokens) ? row.tokens : [];
  const also = row.also && Array.isArray(row.also.tokens) ? row.also.tokens : [];
  return [...own, ...also];
}

/**
 * Every key set in the rule table above, one entry per position, tagged with WHICH POSITION it
 * occupies. The PERMITTED key sets deliberately live in the test and not here: a table that
 * published its own permitted keys would be graded against its own opinion, and the thing worth
 * catching is a key nobody taught the walk to read.
 *
 * FOUR KINDS, NOT TWO, because the same key name means different things depending on where it is
 * written, and a check total over NAMES is not total over POSITIONS. Each kind is named for the
 * set of readers that reach it:
 *   - `row`        a plain top-level row. Every reader reaches it.
 *   - `dispatcher` a top-level row carrying `byTier`. `rowFor` returns the CELL, so `file`,
 *                  `tokens`, `content` and `also` written here are never read -- and a `file`
 *                  written here is a requirement the guard grants without checking.
 *   - `cell`       a `byTier` cell. `appliesAtTier` reads `tiers` off the RAW top-level row, so
 *                  a `tiers` written on a cell is never read.
 *   - `also`       a second-requirement sub-row. Its arity ceiling is two, so a nested `also`
 *                  here is the third requirement nothing enforces.
 * Every inert position named above was driven through the CLI rather than reasoned about, and
 * `tiers` on a DISPATCHER is the one key that survives that test: it IS read, so it stays in the
 * dispatcher's permitted set. Excluding a key the guard honours is the same error pointed the
 * other way.
 *
 * EACH ENTRY CARRIES ITS RAW POSITION OBJECT as `node`, because a key set cannot see a SIBLING
 * relation: `tokens` and `content` are read only inside `checkOne`, which a vacuous primary
 * skips, so they mean nothing unless the `file` beside them is truthy -- and `{ file: null,
 * tokens: [] }` and `{ file: null, tokens: ["0.5"] }` have the IDENTICAL key set. The raw object
 * is published rather than a verdict about it for the same reason the permitted sets live in the
 * test: a table that graded its own values would be graded against its own opinion.
 */
export function rowShapes() {
  const out = [];
  // The kind is a property of the POSITION, not of the contents: a `byTier` nested inside a cell
  // is tagged `cell` and its `byTier` key is a stray, which is what it deserves -- it disarms the
  // row it is written on. Tagging by contents would re-admit it as another dispatcher.
  const walk = (at, kind, obj) => {
    out.push({ path: at, kind, keys: Object.keys(obj).sort(), node: obj });
    if (obj.byTier) {
      for (const [cellTier, cell] of Object.entries(obj.byTier)) {
        walk(`${at}.byTier.${cellTier}`, "cell", cell);
      }
    }
    if (obj.also) walk(`${at}.also`, "also", obj.also);
  };
  for (const [phase, raw] of Object.entries(PREREQUISITES)) {
    walk(phase, raw.byTier ? "dispatcher" : "row", raw);
  }
  return out;
}

function contentSatisfies(artifactPath, row) {
  if (row.content === "ba-approved") {
    try {
      const doc = JSON.parse(readFileSync(artifactPath, "utf8"));
      return typeof doc.ba_approved_at === "string" && doc.ba_approved_at.trim() !== "";
    } catch {
      return false;
    }
  }
  if (row.content === "non-empty") {
    try {
      return readFileSync(artifactPath, "utf8").trim() !== "";
    } catch {
      return false;
    }
  }
  return true;
}

/**
 * Path (b): an events[] entry whose RESOLVED token is a member of the row's set.
 *
 * No verdict is required. events[].verdict is optional in the schema and a committed record
 * carries six verdict-less events, so a verdict-keyed rule would reject a schema-valid record;
 * and the artifact an event stands in for exists whatever the verdict said, because a review
 * that demanded changes still ran. The ONE exception is a recorded SKIP, which is the deviation
 * hatch and costs a written reason -- without the note the hatch is free, and a free hatch is
 * not a hatch. A noteless skip only disqualifies THAT entry; another entry may still satisfy.
 */
function eventsSatisfy(events, tokens) {
  if (!Array.isArray(events) || tokens.length === 0) return false;
  for (const event of events) {
    if (!event || typeof event !== "object") continue;
    const token = phaseKey(event.phase);
    if (token === null || !tokens.includes(token)) continue;
    if (event.verdict === "SKIPPED") {
      const note = typeof event.note === "string" ? event.note.trim() : "";
      if (note === "") continue;
    }
    return true;
  }
  return false;
}

/**
 * Two sources, in priority order: the artifact, then the record.
 *
 * A PRESENT artifact decides the row by itself, including when its CONTENT fails the row's
 * condition -- events[] are not consulted to rescue it. Otherwise the `content` column would be
 * dead on any real run: a dispatch event for the phase is always present by the time its
 * artifact is, so an unapproved spec.json would be waved through by the event that recorded the
 * BA dispatch. The events path exists for the fresh checkout, where the artifact is absent
 * because everything except status.json is gitignored, and there it is knowingly weaker.
 *
 * Returns WHICH SOURCE decided as well as the outcome, because the two refusals need different
 * messages: telling an operator that a file they are looking at is not present, and telling them
 * to re-run the phase that already produced it, are both false on a content failure. It also
 * returns WHICH HALF decided, so the message names the file that actually failed.
 */
function checkOne(issueDir, subRow, events) {
  const artifactPath = path.join(issueDir, subRow.file);
  if (existsSync(artifactPath)) {
    return { ok: contentSatisfies(artifactPath, subRow), artifact: "present" };
  }
  return { ok: eventsSatisfy(events, subRow.tokens), artifact: "absent" };
}

/**
 * PRIMARY FIRST, and the short circuit is load-bearing for the MESSAGE rather than for the
 * decision: a row is satisfied only when both halves are, in either order, so the ba-approved
 * obligation cannot be swapped away by re-ordering. What the ordering buys is that a doubly
 * failing row names ONE file, which is the single-route shape the refusal template and its test
 * both depend on. The cost is that an operator who fails both halves at once returns for a
 * second refusal after fixing the first; both refusals are correct and both are actionable.
 *
 * A VACUOUS PRIMARY IS A VALUE, NEVER AN EARLY RETURN. A row with no `file` owes nothing on its
 * primary half, and it is tempting to answer `ok` and stop -- but stopping there skips `also`
 * entirely, so a second requirement written on such a row would be reported by
 * `satisfyingTokens` and never enforced: the guard claiming more than it knows, which is the
 * one failure this row's own arity ceiling exists to prevent. The fall-through makes that a fact
 * about THIS FUNCTION for `also`, whatever the table later holds.
 *
 * IT DOES NOT EXTEND TO THE OTHER TWO FIELDS, and reading it as if it did is how the same defect
 * survives one key over. `tokens` and `content` are read only inside `checkOne`, which a vacuous
 * primary still skips, so on a `file: null` row they are consulted by NO reader on the decision
 * path -- while `satisfyingTokens` reports the tokens to the drift suite regardless. That today
 * harms nothing IS a fact about the table's current contents (`0.5-map` carries `tokens: []`),
 * and it is the shape walk that keeps it one: it refuses a falsy `file` sitting beside a live
 * `tokens` or `content`. Do not add that pair here -- a table graded by its own reader is graded
 * against its own opinion.
 */
function prerequisiteSatisfied(issueDir, row, events) {
  const primary = row.file ? checkOne(issueDir, row, events) : { ok: true, artifact: "none" };
  if (!primary.ok) return { ...primary, file: row.file, content: row.content || null };
  if (row.also) {
    const secondary = checkOne(issueDir, row.also, events);
    if (!secondary.ok) {
      return { ...secondary, file: row.also.file, content: row.also.content || null };
    }
  }
  return {
    ok: true,
    artifact: primary.artifact,
    file: row.file || null,
    content: row.content || null,
  };
}

/**
 * A run is IN FLIGHT when it was updated under 24h ago and carries no final verdict. A record
 * with no readable `updated_at` is not in flight: the guard cannot date it, and a control that
 * cannot date a record must not hold a project's turns open on it.
 *
 * DRIFT RISK, LIVE AND UNRESOLVED, TRACKED IN #74. The window below is this module's OWN
 * literal. pipeline-status.mjs holds an independent copy of the same number in its `stuck`
 * filter, to call a run "possibly stuck", and on the AGE term those two comparisons are
 * complements. Neither predicate is the negation of the other even so, and the DATABILITY term
 * is where they part -- not in agreement, as an earlier draft of this comment had it. This
 * guard dates a record from its OWN `updated_at` and abstains when that will not parse;
 * pipeline-status.mjs substitutes the status.json FILE MTIME for an ABSENT or NULL one first
 * (`updated_at: status?.updated_at ?? mtime`). So a record carrying no `updated_at` at all is
 * NOT in flight here and IS listed "possibly stuck" there as soon as the file is a day old.
 * Measured, not reasoned. An unparseable STRING is the one undatable spelling the two still
 * agree on, because `??` does not fire on it.
 *
 * They also DATE the field differently -- `Date.parse` here, `new Date(...).getTime()` there --
 * which agree on the ISO strings status.schema.json requires and diverge on anything else.
 * `updated_at: 12345` reads here as the year 12345, so the record is permanently in flight,
 * while pipeline-status.mjs never classifies it at all: it throws on the number before its
 * filter is reached. Nothing in this tree pins either spelling.
 *
 * That mtime-for-updated_at substitution is the same grain mismatch #74 records against
 * session-start.sh, in a second module #74 does not yet count. No symbol is shared either, so
 * the numbers agree only for as long as nobody moves one of them, and nothing in this tree
 * fails if one does.
 */
function inFlight(status, now) {
  if (status.final_verdict) return false;
  const updated = Date.parse(status.updated_at);
  if (!Number.isFinite(updated)) return false;
  return now - updated <= IN_FLIGHT_MS;
}

function isTerminal(phase, status) {
  if (status.completed_at) return true;
  if (TERMINAL.includes(phase)) return true;
  if (phase === "halted-error") return true;
  return /-error$/.test(phase);
}

/**
 * The decision for ONE issue dir. Returns null for a tooling failure (unreadable record), which
 * the caller renders as silence rather than as a decision.
 */
function decideForDir(issueDir, now) {
  const name = path.basename(issueDir);
  let status;
  try {
    status = JSON.parse(readFileSync(path.join(issueDir, "status.json"), "utf8"));
  } catch {
    return null;
  }
  if (!status || typeof status !== "object" || Array.isArray(status)) return null;

  const decided = (decision, reason) => ({ decision, reason, issue_dir: name });
  const phase = typeof status.current_phase === "string" ? status.current_phase : "";
  const at = `.pipeline/${name} at \`${phase}\``;

  if (isTerminal(phase, status)) return decided("not-applicable", `${at} is finished.`);
  if (UNGUARDED.includes(phase)) {
    return decided("not-applicable", `${at} is a halt or rework state, which is never guarded.`);
  }
  // Fail-OPEN on vocabulary, fail-CLOSED on sequence. An unrecognised phase is a gap in this
  // table's knowledge, not an orchestrator exercising discretion, and status.schema.json blesses
  // at least two phases pipeline.md never writes -- deny-by-default would refuse every turn in a
  // project holding one of those records.
  if (!GUARDED.includes(phase)) {
    return decided("not-applicable", `${at}, which is not a guarded phase.`);
  }
  if (!inFlight(status, now)) {
    return decided("not-applicable", `${at} is not in flight (stale or already concluded).`);
  }

  // The RAW field, before normalizeTier resolves every unusable value to the strictest row.
  const tierDetermined = KNOWN_TIERS.includes(status.risk_tier);
  const tier = normalizeTier(status.risk_tier);
  if (!appliesAtTier(phase, tier, tierDetermined)) {
    // The undetermined wording interpolates `at` and nothing else. `status.risk_tier` is the one
    // unbounded record value in scope here, this is the first branch that has neither vetted it
    // against KNOWN_TIERS nor normalized it away, and the file it comes from is committed and
    // archived verbatim -- the same reason ask_text, events[].note and error are never echoed.
    return decided(
      "not-applicable",
      tierDetermined
        ? `${at} is not a guarded phase at the ${tier} tier.`
        : `${at} carries no determined risk_tier, so a tier-restricted row does not apply.`,
    );
  }

  const row = rowFor(phase, tier);
  const prereq = prerequisiteSatisfied(issueDir, row, status.events);
  if (prereq.ok) {
    return decided("granted", `${at}: its prerequisite is satisfied.`);
  }
  // The FAILING half's file and content, not the row's: a row can hold two requirements, and a
  // message naming the half that passed would send the operator after a file already in front of
  // them. Both values are table literals either way, so nothing from status.json reaches stderr.
  const reason =
    prereq.artifact === "present"
      ? `${at} (${tier}) has a \`${prereq.file}\` that does not satisfy this row, and a present artifact is not rescued by events[].`
      : `${at} (${tier}) has no \`${prereq.file}\` and no events[] entry recording that phase closing.`;
  return {
    ...decided("refused", reason),
    phase,
    file: prereq.file,
    tier,
    artifact: prereq.artifact,
    content: prereq.content,
  };
}

/**
 * The stderr message on a refusal. FIXED TEMPLATE, four bounded values, no passthrough: the
 * phase and the filename come from the table above, and the dir name matched the issue-dir
 * shape. status.json's free-text fields (ask_text, events[].note, error) are NEVER interpolated
 * -- the schema itself says ask_text "must never carry a secret" because the file is committed,
 * i.e. it treats that field as one that can receive a pasted token before anyone notices, and
 * stderr is fed straight back into the transcript.
 */
const CONTENT_DIAGNOSIS = {
  "ba-approved": "carries no `ba_approved_at`",
  "non-empty": "is empty",
};

const CONTENT_REPAIR = {
  "ba-approved": "Record BA's approval: set `ba_approved_at` in",
  "non-empty": "Write the content that phase produces into",
};

function refusalMessage(result) {
  const dir = `.pipeline/${result.issue_dir}`;
  // A refusal on a PRESENT artifact must not send the operator after a missing file. Both of the
  // absent-case lines are false there -- the file is in front of them, and re-running the phase
  // that produced it changes nothing -- and this is the text a blocked turn reads.
  const present = result.artifact === "present";
  const diagnosis = present
    ? `Its prerequisite \`${result.file}\` IS present in ${dir}, but it ${CONTENT_DIAGNOSIS[result.content] || "does not satisfy this row"}. A present artifact settles the row on its own; events[] are not consulted to rescue it, or the event that recorded the phase being DISPATCHED would stand in for its approval.`
    : `Its prerequisite \`${result.file}\` is not present in ${dir}, and no events[] entry records that phase closing.`;
  const route1 = present
    ? `  1. ${CONTENT_REPAIR[result.content] || "Supply the content this row requires in"} ${dir}/${result.file}, then commit it.`
    : `  1. Run the phase that produces \`${result.file}\`, then append its events[] entry and commit ${dir}/status.json.`;
  return [
    `Phase-entry guard: this turn cannot end with ${dir} recorded at \`${result.phase}\`.`,
    diagnosis,
    `Work already done in this turn is not undone; only the turn boundary is blocked.`,
    `Ways to clear it:`,
    route1,
    `  2. If the skip was deliberate, record it: append an events[] entry for the phase you skipped with "verdict": "SKIPPED" and a non-empty "note" saying why.`,
    // The guard only holds turns for a run it can still see in flight, so concluding an abandoned
    // one clears it and refuses nothing. Without this route the in-flight predicate's own escape
    // hatch was undocumented at the only moment anyone needs it.
    //
    // It is also the WIDEST and CHEAPEST disarm this guard has, and naming it here is what made
    // that worth stating. Route 2 clears ONE row and costs a written note that stays in the
    // committed record; route 3 clears every remaining row of the run at once, at zero cost, and
    // records no reason. Measured: a refusing record at `3-impl` given a `final_verdict` goes
    // rc 2 -> 0, and every later phase of that run is not-applicable thereafter. That is the same
    // affirmative-act class as back-dating `updated_at` past the in-flight ceiling, disclosed in
    // the spec's guarantee_and_threat_model.does_not_stop rather than defended against -- the
    // capability is the in-flight predicate's, not this message's. Hence "YOURS": the one thing
    // the text can do is stop reading as a licence to conclude somebody else's run.
    `  3. If this run is YOURS and is over, conclude it: give ${dir}/status.json a \`final_verdict\`, a \`completed_at\`, or \`"current_phase": "5-archived"\`. A run this guard cannot see in flight is never refused.`,
    `A /phase re-run that did the work records it the same way, as a \`<phase-token>-rerun\` event (e.g. \`1-ba-rerun\`); the bare \`phase-rerun\` label resolves to no phase and clears nothing.`,
  ].join("\n");
}

/**
 * A sentinel the issue-dir shape rejects, so activeIssueDir's signal branch fails over to its
 * mtime derivation. It is passed as the payload field rather than by unsetting the environment,
 * because the point is to ask ONE resolver two questions -- "who does the signal name" and "who
 * is newest" -- without a second scan that could answer differently.
 */
const MTIME_ONLY = "!";

function candidateDirs(pipelineDir) {
  const dirs = [];
  for (const dir of [
    activeIssueDir(pipelineDir, {}),
    activeIssueDir(pipelineDir, { active_issue: MTIME_ONLY }),
  ]) {
    if (dir && !dirs.includes(dir)) dirs.push(dir);
  }
  return dirs;
}

function parseRoot(argv) {
  const i = argv.indexOf("--root");
  if (i !== -1 && argv[i + 1]) return argv[i + 1];
  return process.env.CLAUDE_PROJECT_DIR || process.cwd();
}

function main() {
  const pipelineDir = path.join(parseRoot(process.argv.slice(2)), ".pipeline");
  if (!existsSync(pipelineDir)) return;

  const now = Date.now();
  const results = [];
  for (const dir of candidateDirs(pipelineDir)) {
    const result = decideForDir(dir, now);
    if (result) results.push(result);
  }
  if (results.length === 0) return; // no resolvable, readable active issue: silence

  // EITHER dir may refuse. That is what stops the explicit signal from being strictly more
  // permissive than leaving it unset, which is the env-var opt-out this design rejected.
  const chosen =
    results.find((r) => r.decision === "refused") ||
    results.find((r) => r.decision === "granted") ||
    results[0];

  process.stdout.write(
    `${JSON.stringify({
      decision: chosen.decision,
      reason: chosen.reason,
      issue_dir: chosen.issue_dir,
    })}\n`,
  );
  if (chosen.decision === "refused") {
    process.stderr.write(`${refusalMessage(chosen)}\n`);
    process.exitCode = 2;
  }
}

// Self-run ONLY as a real CLI entry. isMain compares the basename of argv[1], and the drift
// suite passes THIS module's path as argv[1] to an eval script that imports it -- self-running
// there would print a decision into the middle of that suite's own report and could exit(2)
// mid-import, turning a test of the exported sets into a test of the caller's .pipeline tree.
const evalEntry = process.execArgv.some(
  (a) => a === "-e" || a === "--eval" || a === "--input-type=module" || /^--eval=/.test(a),
);
if (isMain("gate-phase-entry.mjs") && !evalEntry) {
  try {
    main();
  } catch {
    // Fail-OPEN on tooling: a guard that crashes must never wedge a turn, and it must not
    // announce the crash either, because stderr here is read as a refusal.
    process.exitCode = 0;
  }
}
