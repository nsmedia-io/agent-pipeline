#!/usr/bin/env node
/**
 * voice-lint.mjs — Stop-hook check that voice.md was actually honored.
 *
 * WHY THIS EXISTS. voice.md is referenced twelve times in pipeline.md and four in phase.md,
 * and until this script nothing read it. That is evidence.md rule 19 exactly: a written
 * expectation no code reads is a comment. The orchestrator was asked to remember both WHEN a
 * voice moment occurs and WHAT shape it takes, at the end of a long run, with nothing checking
 * either. The trigger half is the more interesting failure: status.json has always known which
 * phase it is in, so "is this a voice moment" never needed to be a judgment call at all. This
 * script derives it.
 *
 * SCOPE, deliberately narrow. It lints ONLY when the active pipeline's current_phase is a
 * known voice moment. Ordinary conversational turns are never linted. That matters because
 * voice.md bans em dashes "anywhere, ever", and a lint that enforced it on every message in
 * every session would be switched off within a day — which is the failure mode that makes a
 * control worthless (evidence.md: ask what your control REFUSES).
 *
 * WHAT IT CANNOT DO. It checks for the SHAPE of voice mode, never the quality. A report can
 * carry every required marker and still be written for a machine. The markers are a floor, not
 * a grade, and the analogy rules, the "explain it twice" rule, and the jargon-gloss rule are
 * not machine-checkable at all. Treat a pass as "the owner-facing scaffolding is present".
 *
 * WHAT IT DOES NOT GOVERN, and this is the important half: agent-to-agent traffic. voice.md
 * exists so the OWNER can be brought up to speed when a long-running session needs a decision
 * they have no context for. It is not a house style, and specialists talking to each other
 * should stay dense and technical: table names, line numbers, CVE severities, raw verdicts.
 * This lint runs on the Stop hook ONLY, never SubagentStop, so it structurally cannot reach a
 * subagent's shard or reply. Nothing here should ever be pushed down into an agent prompt.
 *
 * THE LIMIT THAT WAS CLOSED, kept here because the failure is instructive: a phase not in
 * VOICE_MOMENTS is not linted, so an unrecognised phase passes silently rather than loudly.
 * The first version of this table was written from memory and invented four phases that no
 * checkpoint writes, which meant those checks could never fire while the REAL completion report
 * and live-verification halt went uncovered. tests/test-voice-lint.sh now derives the phase set
 * from pipeline.md itself and fails when a phase is neither a listed moment nor explicitly
 * declared non-voice, so the table is pinned to configuration rather than to recollection.
 *
 * FAIL-OPEN by contract, exactly like validate-pipeline-artifact.mjs: any missing input,
 * unreadable transcript, unparseable payload or thrown error exits 0 silently. A voice lint
 * that wedges a legitimate stop is worse than no voice lint.
 *
 * ===========================================================================================
 * TURN SCOPING (#56): THE OBLIGATION IS SCOPED TO THE TURN THAT PRODUCED THE RECORD
 * ===========================================================================================
 *
 * THE DEFECT, IN ONE SENTENCE. The decision to impose voice.md's shape came from ONE input, the
 * current_phase of whichever .pipeline/<issue>/status.json is newest by mtime, and a phase
 * carries no notion of WHEN and no notion of WHOSE. So `5-archived` is terminal and graded every
 * later message in the session as the completion report (the in-run half), and when the current
 * run's record was REMOVED at archival the mtime scan fell through to some other lane's parked
 * record and graded this session's message against a run this session does not own (the
 * cross-run half, reproduced live).
 *
 * THE FIX, AS AN OUTCOME PROPERTY RATHER THAN A MECHANISM: no message is refused on account of a
 * record that has not been touched since the last OWNER-AUTHORED turn began. Nothing is
 * remembered; both halves are DERIVED from inputs the Stop hook already has. The predicate is
 * phase-INDEPENDENT, so 5-archived, halted-error and the whole <phase>-error family inherit it.
 *
 * THE GOVERNING DIRECTION, and everything below is subordinate to it: THIS CHANGE MUST NEVER BE
 * THE REASON FOR SILENCE. An unresolvable boundary never suppresses a refusal the old code would
 * have produced. Where a record's provenance cannot be POSITIVELY established the boundary does
 * not advance, which leaves the record looking fresh, which leaves the lint loud. The one input
 * that was already silent (an unreadable or wholly unparseable transcript, which exits 0 because
 * there is no assistant text to grade) STAYS silent deliberately: that path predates #56, sits
 * ahead of every boundary question in run(), and making it refuse would be a NEW false-refusal
 * class fired by a malformed hook payload.
 *
 * WHERE `origin` LIVES, stated plainly because the misreading is fatal and looks like success.
 * `origin` is a RECORD-LEVEL object, a sibling of type / isSidechain / isMeta / timestamp /
 * message. It is NOT message.origin. Measured over 1,817 transcript files and 398,088 records
 * (main-session and subagent, 2026-08-22): 2,742 record-level origin objects and ZERO under
 * message, in every client version observed. An implementation reading record.message?.origin
 * ?.kind finds zero human turns on every transcript ever written, the unresolvable-boundary
 * fallback fires every time, and the change ships as a PERMANENT, TOTAL, SILENT no-op that looks
 * exactly like the control working.
 *
 * THE origin.kind VALUE SPACE IS OPEN, NOT AN ENUM, and it is deliberately not a table in this
 * file. Census over every project under ~/.claude/projects on one machine, clients 2.1.85 to
 * 2.1.237, taken 2026-08-22: `human` 977, `task-notification` 1,396, `coordinator` 342 (found
 * only on a second pass, in subagent transcripts), `peer` 31. That is what one machine has SEEN,
 * not what the vendor may write. isHumanTurnRecord only ever tests for `human`, so an unlisted
 * future value is excluded exactly like every listed value except `human`, and no code here
 * validates against the list. A frozen four-value constant would be dead surface that a reader
 * could mistake for a validated enum, which is this file's own recorded defect (the first
 * VOICE_MOMENTS table was written from memory and invented four phases nothing writes).
 *
 * THE BOUNDARY IS THE LAST HUMAN RECORD IN FILE POSITION, not the maximum human timestamp, and
 * that is a DIRECTION CHOICE made in advance of an observation rather than an accident of the
 * loop. The two differ only under a chronological inversion; a running max is later-or-equal to
 * the last-in-position value, a later boundary silences more, and silence is the one thing this
 * change may never cause. Measured: 0 inversions in 971 human records, so no fixture can
 * currently falsify the choice, and asserting it with a test that cannot fail would be worse
 * than writing it down. PROMOTION CONDITION: a corpus that produces an inversion.
 *
 * THE RULING ON `updated_at` (it may only WIDEN freshness, never narrow it). recordMs is
 * max(mtimeMs, Date.parse(updated_at) where that is finite); an absent, non-string or
 * unparseable updated_at contributes nothing and cannot poison the comparison. MEASURED BASIS:
 * mtime is the record's write time exactly when nothing has touched the file since, and a
 * CHECKOUT timestamp otherwise -- across 9 live records the three written in place by the
 * orchestrator agree with updated_at to under a second while six disagree by 3.0 hours to 13.7
 * days. And updated_at cannot be trusted alone: it appears ONCE in commands/pipeline.md against
 * 33 occurrences of current_phase, so its refresh is a writer convention restated at 1 of 33
 * write sites, and preferring it would trade a loud failure for a silent one. WHAT max() BOUNDS
 * AND WHAT IT DOES NOT, in one sentence, because the half-truth shipped twice in review: it
 * bounds an mtime moved BACKWARDS while the bytes were freshly written (residual iii-a), and it
 * does NOT bound an mtime-PRESERVING RESTORE (residual iii-b), because updated_at is file
 * CONTENT and travels with the copy, leaving both terms stale together. The widening term has
 * NO observed input: 0 of 9 live records carry an updated_at later than their mtime.
 *
 * ctime WAS CONSIDERED AND IS REJECTED, recorded so it is not re-proposed cold. ctime does read
 * fresh after cp -p, tar -x and rsync -a alike, so it would close (iii-b). But ctime is set by
 * ANY inode change including the utimesSync that is the sanctioned way to stale a fixture, so a
 * ctime-inclusive composition would force every deliberately-stale fixture in the suite to be
 * rebuilt by write-ordering against real elapsed time (~1.1 s per fixture, measured), trading a
 * deterministic cross-platform stamp for a wall-clock-dependent suite. The objection is FIXTURE
 * COST, not impossibility; an earlier draft claimed such fixtures "cannot be built at all" and
 * that was false.
 *
 * RESIDUAL LIMITS, in label order, each with its FAIL DIRECTION and its expiry. Half of them are
 * places this fix does not reach; naming them is what stops a future reader treating R1's
 * absolute phrasing as universal.
 *
 *   (i)    A mid-turn operation that rewrites a FOREIGN status.json's mtime (a git checkout,
 *          clone, worktree add or sync) makes that record look fresh and capture the turn.
 *          DIRECTION: FALSE REFUSAL, which is exactly today's behaviour. The sibling module's
 *          tie-abstention does not cover it: measured on this APFS worktree, four bulk-written
 *          records share one wall-clock second and differ only at sub-millisecond resolution
 *          across a ~2 ms spread, so resolveStatus picks a strict winner rather than abstaining.
 *          EXPIRY: a record identity that survives a checkout.
 *   (ii)   The owner sends a message BETWEEN the archive checkpoint and the completion report,
 *          so the report is no longer in the same turn and the genuine moment goes unchecked.
 *          DIRECTION: SILENCE. This is the one true positive the fix trades away and it is the
 *          accepted cost. EXPIRY: a signal that ties a message to the checkpoint that provoked
 *          it rather than to the turn it lands in.
 *   (iii-a) An NTP step backwards or an explicit utimes, with the BYTES freshly written. Such a
 *          record still carries a recent updated_at, so max() reads it fresh and the lint fires.
 *          BOUNDED by the composition above. DIRECTION: none left open.
 *   (iii-b) OPEN, AND BOUNDED BY NOTHING SHIPPED HERE: an mtime-PRESERVING RESTORE (cp -p,
 *          rsync -a, tar -x). Both terms of the max() are stale together, so a record placed in
 *          THIS turn reads 72.00 hours old (measured, identically, for all three tools; the
 *          non-preserving control, a plain cp, reads 0.00 h). DIRECTION: SILENCE, a missed
 *          check. EXPIRY: a mechanism that dates the record by something a verbatim copy cannot
 *          carry. THE ENVIRONMENT is an operator's shell restoring a tree, which is an
 *          environment no check in this repo runs in, so a green CI run is not evidence that
 *          this class is closed.
 *   (iv)   THE IRREDUCIBLE ONE. The predicate TRUSTS THE VENDOR'S OWN PROVENANCE LABEL. If a
 *          client ever stamps a harness-injected record origin.kind 'human', that record
 *          advances the boundary and the control goes silent with no error anywhere. DIRECTION:
 *          SILENCE. This is the declared expected survivor of the drift battery rather than
 *          something papered over. EXPIRY: re-run the origin.kind census over a fresh corpus and
 *          check that no non-owner class carries 'human'.
 *   (v)    A same-machine cross-session message is EXCLUDED TWICE OVER rather than bounded: all
 *          31 observed carry BOTH origin.kind 'peer' AND isMeta true. sessionId is NOT a third
 *          guard, and that is measured rather than assumed: all 31 are stamped with the
 *          RECEIVING session's own id, so an equality test cannot see them. DIRECTION: none left
 *          open by a drift in EITHER label alone, because the two exclusions are independent.
 *          WHAT IS NOT CLOSED, and this sentence is corrected at #91 because the line it replaces
 *          read "no residual EXPIRY applies" and that OVERCLAIMED: isMeta is a vendor-controlled
 *          label exactly as origin.kind is, so this class sits INSIDE (iv)'s already-declared
 *          scope rather than outside it. Two independent guards make the class robust to either
 *          label drifting alone; they do not take it out of the vendor's hands. EXPIRY: (iv)'s,
 *          and no separate one -- re-run the origin.kind census over a fresh corpus, and check
 *          isMeta on the peer class in the same pass.
 *   (vi)   On clients predating the origin field the predicate finds no human turn, the boundary
 *          is unresolvable, and the lint fires unconditionally, which is today's behaviour.
 *          Measured: 8 of 84 transcripts (9.5%) contain no origin.kind 'human' record at all,
 *          all on clients 2.1.170 and older; on 2.1.209 and newer the predicate catches 968 of
 *          968 owner records. DIRECTION: a LOUD no-op, not a disarm. The line main() attaches to
 *          a refusal with an unresolved boundary is what makes that condition VISIBLE, because a
 *          loud failure is a nuisance nobody reports as a bug.
 *   (vii)  A turn the owner did not START does not advance the boundary, so a record written
 *          after the last owner message still reads fresh and that turn's message is still
 *          graded. The boundary advances only on an owner-TYPED record, so an auto-compaction
 *          continuation, a task-completion notice handing control back, a queued message, a
 *          session resume or a peer message all leave it where it was. DIRECTION: FALSE
 *          REFUSAL, i.e. exactly today's behaviour, so a COVERAGE LIMIT and not a regression.
 *          THE BOUND is tighter than "the bug is still live": it bites only in the WINDOW
 *          between a status write and the NEXT owner-typed message, because that message moves
 *          the boundary past the record permanently. Population, not a rate: of 2,572 assistant
 *          episodes, 1,562 (60.7%) are not owner-started once voice-lint's own refusals are
 *          excluded, but the residual only fires where such a turn ALSO follows a voice-moment
 *          status write inside that window, and this corpus carries no status.json history to
 *          join against. EXPIRY: a structural "a new turn began" signal independent of
 *          authorship, at which point the boundary can advance on turn starts without reopening
 *          the self-disarm.
 *   (viii) THE SHAPE CHECK REFUSES BEFORE THE TRANSCRIPT IS READ. phaseShapeFailure returns a
 *          refusal ahead of every boundary question, so a STALE or FOREIGN record whose
 *          current_phase violates status.schema.json's pattern still refuses this session's
 *          message. The outcome property above is therefore true WITH AN EXCEPTION. DIRECTION:
 *          FALSE REFUSAL, i.e. today's behaviour, so a coverage limit like (vii). It is NOT
 *          closed by moving the gate earlier: the boundary scan is bound to sit AFTER the two
 *          unusable-transcript returns so no unusable input acquires new behaviour, and hoisting
 *          the freshness check would make the shape-failure path pay a transcript read it does
 *          not pay today. EXPIRY: a freshness signal available before the record's phase is
 *          validated.
 *   (ix)   A STAT FAILURE ON THE MTIME-SCAN BRANCH NOW SILENCES A REFUSAL IT USED TO PRODUCE. The
 *          scan drops a candidate it cannot read at EITHER of two adjacent lines -- the
 *          `if (!existsSync(f)) continue;` guard and the `catch { continue; }` just below it --
 *          and #56 changes neither; what it inverts is what dropping COSTS. Before, dropping this
 *          session's own record left some FOREIGN record resolved and the lint refused loudly
 *          against it; now the surviving candidate is BY CONSTRUCTION older than the turn
 *          boundary, so the refusal is silenced instead. Measured, one variable moved, one
 *          fixture (dir 99 = this session's fresh 5-archived record, dir 7 = a foreign 72 h-stale
 *          4-review-complete, no env signal, an em-dash message, statSync forced to throw EACCES
 *          on 99/status.json alone): stat ok -> exit 2 naming 5-archived; stat throws -> exit 0
 *          with ZERO bytes on stderr; the same throw against the pre-#56 code -> exit 2 naming
 *          4-review-complete. DIRECTION: SILENCE.
 *          SCOPE, and the distinction carries most of the severity: the LIKELY cause is an ENOENT
 *          race against the archival unlink, where silence is #56's intended and correct outcome;
 *          the exposure is the narrower EACCES/EPERM/EIO class, where the record EXISTS and
 *          cannot be read. WHICH OF THE TWO LINES DROPS IT DEPENDS ON THE FAULT, so a fix applied
 *          to one alone leaves the other silent: a TRANSIENT failure takes the catch, while a
 *          PERSISTENT permission fault takes existsSync, which returns FALSE rather than throwing
 *          when the containing directory is unsearchable -- statSync never runs and the catch is
 *          never reached. Measured with no shim of any kind, uid 501, chmod 000 on the issue
 *          directory: existsSync false, statSync EACCES, readFileSync EACCES, readdir still
 *          enumerating, and end to end exit 0 with ZERO bytes on stderr -- the same outcome as
 *          the shimmed measurement above, against exit 2 / 479 bytes for that fixture with the
 *          directory readable. NOT closed by handing the unstattable candidate POSITIVE_INFINITY
 *          the way statMs does on the named-signal branch: it would then WIN, readJson would fail
 *          on that same unreadable file, status would be null and run() would fail open silently
 *          anyway, which trades one silence for another -- and on the PERSISTENT half it is not
 *          even that but a plain no-op, still exit 0 / zero bytes with that fix applied
 *          (measured), because the catch it edits never runs. WHAT THE LOUD ALTERNATIVE REFUSES,
 *          which is why it is not taken: forcing a refusal whenever any candidate was dropped
 *          makes an unreadable FOREIGN lane's status.json (a root-owned file left by a container
 *          run) refuse every message in this session, i.e. correct work refused on account of a
 *          run this session does not own. EXPIRY, and it is NOT the discrimination: telling an
 *          unreadable record from an absent one is available today and costs about four lines
 *          (drop existsSync, let statSync throw, branch on err.code). What is missing is
 *          ATTRIBUTION -- the signal this scan uses to decide whose record a candidate is IS that
 *          record's own mtime, which is exactly what the failure withholds, so a dropped
 *          candidate cannot be told from a foreign lane's. The containing directory's mtime is
 *          not the substitute it looks like: still takeable at mode 000, but it moves when an
 *          entry is created, removed or renamed and NOT when status.json is rewritten in place
 *          (both measured), so it dates a different event than the record write the scan grades.
 *          EXPIRY is therefore a way to attribute an UNREADABLE candidate to a session, at which
 *          point the EACCES/EPERM/EIO half can go loud without the ENOENT half following it.
 *          PINNED in tests/test-voice-lint.sh, with its two one-variable controls, so the
 *          asymmetry sits on the record rather than being rediscovered.
 *
 * WHAT THE SELF-DISARM WAS, kept because the shape of the mistake is more instructive than the
 * fix. Deciding "has a person weighed in" by SUBTRACTING known machine spellings from the set of
 * user records is the wrong side of the transformation: it inherits every future spelling the
 * vendor adds, and it admitted voice-lint's OWN blocking refusal record, so the control disarmed
 * itself the instant it first fired and the identical bad message passed on resend.
 */

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMain as isMainScript } from "./lib.mjs";
// IMPORTED, never restated. This file used to declare its own /^\d+$/, which silently exempted
// `exp-<slug>` experiment runs from the voice check: the pattern did not match, resolveStatus
// found no active issue, and the lint went quiet on exactly the runs nobody is watching. That
// is the same defect, in the same shape, that widening the validator's own pattern fixed for
// artifact validation, and that AC17 in test-gate-phase-entry.sh pins for the phase-entry
// guard ("exp-<slug> runs are GUARDED, not exempt"). Sharing the constant is what stops a
// third copy from drifting away again.
import { ISSUE_DIR_RE } from "./validate-pipeline-artifact.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

// current_phase -> what voice.md requires of the message that accompanies it.
//
// Keys are matched EXACTLY against status.current_phase and every one is a string pipeline.md
// actually writes. That is not a stylistic note: the first version of this table invented four
// keys ("5-complete", "5-pr-ready", "4-request-changes", "3-live-verification-required") that
// no phase ever writes, so those checks could never fire, while the real completion report
// ("5-archived") and the real live-verification halt ("3-impl-live-verify-unverified") went
// uncovered. A table asserted from memory rather than derived from the source is the exact
// defect this plugin keeps re-learning. tests/test-voice-lint.sh now parses every
// `current_phase: "..."` out of pipeline.md and fails when one is neither listed here nor
// explicitly declared non-voice, so the table cannot drift from the orchestrator again.
// EXPORTED so tests/test-voice-lint.sh can assert SET MEMBERSHIP over the table itself. The
// check it replaces was `grep -q "\"$phase\"" voice-lint.mjs`, a substring grep over this
// source that a phase named in a COMMENT satisfies and that cannot tell a table key from a
// mention.
//
// NEITHER TABLE IS FROZEN, and that is a ruling rather than an omission. Measured:
// `Object.freeze(new Set(["a"]))` reports `Object.isFrozen === true` and then accepts
// `.add("b")` with size going 1 -> 2, because a Set's members are not own properties. Freezing
// the Set would report a protection it does not provide, and freezing only the object half
// would leave a reader assuming both were covered.
export const VOICE_MOMENTS = {
  "1-ba-open-questions": { decision: true, label: "a blocking open question" },
  "1-ba-rework-required": { scales: true, label: "a veto rework halt" },
  "2.5-design-owner-decision": { decision: true, label: "the design-lock" },
  "3-impl-live-verify-unverified": { scales: true, label: "the live-verification halt" },
  "4-veto-rework-required": { scales: true, label: "a SecOps veto" },
  "4-review-complete": { scales: true, label: "the panel result handed to the owner" },
  "5-archived": { scales: true, replication: true, label: "the completion report" },
};

// Phases that are deliberately NOT voice moments: internal checkpoints the owner never sees.
// Listed explicitly so the drift test can tell "decided this is silent" from "forgot about it".
export const NON_VOICE_PHASES = new Set([
  // The run's setup step. MECHANISM: pipeline.md's Phase 0 holds exactly one full-voice
  // owner-facing decision block, the dirty-worktree halt at step 1, and it runs BEFORE step 5
  // writes `current_phase: "0-setup"`, so a turn cannot end at this phase in that halt.
  // EXPIRY, stated generally rather than as the single reversal that suggests it: this
  // declaration is wrong the moment ANY full-voice owner-facing decision block comes to sit
  // between the step that writes `0-setup` and the next `Checkpoint first` write. Re-derive
  // with `grep -n 'full voice\|decision block\|Checkpoint first\|current_phase' on
  // commands/pipeline.md and read what falls between the two.
  //
  // #80's RULING, AND IT IS A DECISION RATHER THAN A DEFERRAL: the Phase 0 step-1 halt is
  // DELIBERATELY OUT OF THIS LINT'S SCOPE. Said here, in the derivation, rather than achieved by
  // accident of ordering -- which is what #80 was filed to end.
  //
  // THE GAP, MEASURED at 317b9f2 with an em dash planted in a step-1-shaped dirty-worktree halt
  // and the decision block omitted. No `.pipeline` at all (a fresh ask, which is step 1's own
  // state): rc 0, ZERO bytes. A record already sitting at `0-setup` (i.e. after step 5): rc 0,
  // ZERO bytes. The IDENTICAL message at `5-archived`: rc 2 with FIVE named failures, which is
  // the non-zero control that makes the two zeros silence rather than a lint that stopped
  // firing. A `--resume` is SILENT TOO, and that CORRECTS #80's issue body, which predates #56
  // and says the prior phase is graded as the wrong moment: #56's turn boundary reads the prior
  // session's record as stale, so nothing is graded at all. Measured on a resume transcript
  // carrying a real owner-typed record: a 3-day-old record at `4-review-complete` -> rc 0 / zero
  // bytes, and the same record with a fresh mtime -> rc 2 with four named failures. So the gap
  // is uniformly SILENCE, on all three paths, and never a mis-grading.
  //
  // WHY IT IS NOT COVERED, and "cheapest" is not the reason. This lint has exactly ONE input --
  // the phase record -- and at step 1 that input does not exist yet. Every way of manufacturing
  // one before step 5 is a shape this repo has already paid for:
  //   - WRITE A RECORD FIRST (#80's option 1). `.gitignore` re-includes
  //     `<state-dir>/*/status.json`, so the new file is untracked AND not ignored, and step 1's
  //     own `git status --short` reports it. Measured in a scratch repo carrying this repo's
  //     `.gitignore`: clean tree -> 0 bytes of status output; after writing the record -> `?? `
  //     naming the state dir. The dirty-worktree halt would fire on the pipeline's OWN artifact,
  //     in the one branch whose entire point is that uncommitted work is not the pipeline's to
  //     touch. It also has no issue number to name a directory with on a fresh ask, and a
  //     fabricated one enters the mtime scan every other lane in the checkout resolves against.
  //   - BE TOLD THE MOMENT (#80's option 2). That reinstates the judgment call this file's own
  //     header exists to remove ("is this a voice moment" never needed to be a judgment call at
  //     all), and it hands the trigger to the party being graded: an orchestrator that forgets to
  //     set the signal -- which is the exact failure this lint exists to catch -- buys silence by
  //     forgetting. Same shape as WHAT THE SELF-DISARM WAS at the foot of this file.
  //   - READ THE MESSAGE. Deciding the moment from the text being graded is circular: a message
  //     that omits the decision block also omits whatever the trigger would key on.
  // There is no honest structural signal before step 5, so this halt is NOT COVERED HERE, on
  // purpose. Treat Phase 0 step 1 as owner-facing text this control does not read.
  //
  // WHAT FAILS IF THE ORDERING CHANGES, which is the half a ruling ALONE would not buy and the
  // reason #80 could not be closed with a sentence. tests/test-voice-lint.sh's "#80" suite
  // asserts, off commands/pipeline.md itself, the two premises this declaration rests on:
  //   (a) the step-1 halt line -- the ONE line carrying `git status --short`, a full-voice marker
  //       and a decision-block marker together -- sits BEFORE the `0-setup` write; and
  //   (b) the WINDOW between that write and the next `Checkpoint first` holds NO owner-facing
  //       full-voice marker at all.
  // Each marker in that table is separately asserted to be LIVE elsewhere in pipeline.md, so a
  // marker that stops matching reddens as a dead table entry instead of quietly becoming a hole
  // (which is #53's own defect, one level in). Reorder Phase 0, or insert an owner-decision block
  // into that window, and both cells go red naming this line.
  "0-setup",
  "0.5-map", "0.5-map-complete",
  "1-ba", "1-ba-complete",
  "2-constraints", "2-constraints-complete",
  "2-review", "2-review-complete",
  "2.5-design", "2.5-design-complete",
  "3-impl", "3-impl-complete", "3-impl-tripwire",
  // The tripwire could not be EVALUATED (the surface module is absent, unloadable, or exited
  // non-zero). It loops back to BA exactly as a tripwire hit does, so it is the same internal
  // checkpoint as its sibling above, not an owner-facing moment.
  "3-impl-tripwire-indeterminate",
  "3-impl-gate-failed", "3-impl-frontend-gate-failed",
  "4-review",
  "5-archive",
]);

/** An `<phase>-error` / `halted-error` checkpoint: always owner-facing, shape-checked lightly. */
function errorMoment(phase) {
  return /-error$/.test(phase) ? { label: "a halted run" } : null;
}

// voice.md, "Language rules": these phrases all assume the reader was in the thread.
const BANNED_PHRASES = ["as discussed", "as noted above", "per the spec", "as you know"];

// Attached to a refusal when no owner-typed record could be found in the transcript, so the
// turn-scoping check could not run and this refusal was decided the old way.
//
// WHY IT EXISTS. The fail direction for an unresolvable boundary is LOUD, and a loud failure is a
// nuisance nobody reports as a bug, so a fix that has degraded to a permanent no-op -- on a client
// predating the origin field (8 of 84 transcripts), or under any future vendor change -- looks
// exactly like the control working. Naming the condition where output already happens costs
// nothing on the runs where it does not apply.
//
// A FIXED LITERAL, and that is a requirement rather than a style: no byte of the transcript may
// appear in it, per the standing rule that nothing from the transcript reaches stderr.
const BOUNDARY_UNRESOLVED_LINE =
  "Note: no owner-typed message was recognisable in this transcript, so this refusal was NOT scoped to the current turn. That is the documented fallback (an older client, or a changed transcript format), not a second failure, but if you see this line routinely the turn check has quietly stopped working.";

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

/**
 * The issue dir this session owns, as { status, dir, mtimeMs }, or null.
 *
 * RESOLUTION ORDER, unchanged: explicit signal, then STRICT newest mtime, then null. A TIE at
 * the newest mtime resolves to null rather than to either candidate -- see activeIssueDir in
 * validate-pipeline-artifact.mjs for why (#27: readdirSync order is hash order on ext4 and
 * insertion order on APFS, so a tie picked the subject by filesystem) -- and the issue-dir
 * VOCABULARY is the validator's exported ISSUE_DIR_RE imported above rather than a second copy
 * that could drift from it.
 *
 * IT DOES NOT MIRROR THE VALIDATOR, and the older claim here that it did was already false. The
 * two agree on the newest-mtime FALLBACK branch and DIVERGE on the named-signal branch, in four
 * measured ways: this function falls through when the named RECORD is missing or unparseable
 * while activeIssueDir falls through only when the DIRECTORY is absent, and run() passes only
 * the CLAUDE_PIPELINE_ACTIVE_ISSUE spelling while activeIssueName also reads input.active_issue
 * and the bare PIPELINE_ACTIVE_ISSUE. tests/test-voice-lint.sh carries the divergence as an
 * asserted 9-run table, each cell naming its own cause, rather than as a mirror claim nobody
 * re-derived.
 *
 * THE RETURN IS A WRAPPER, and only the wrapper is new: the caller needs the record's mtime to
 * date it against the turn boundary, and needs the SELECTED DIR because that is the outcome the
 * divergence table compares (the two derivations return different types, so comparing their
 * return values directly would be vacuous). Precedence, the strict-mtime winner and the tie
 * abstention are byte-for-byte what they were.
 *
 * THE WRAPPER IS BEHAVIOUR-PRESERVING ONLY BECAUSE THIS EXPORT HAS ONE PRODUCTION IMPORTER, and
 * a second one expires that premise (#91). This used to return a bare `null` where it now
 * returns `{ status, dir, mtimeMs }`, and the two are NOT interchangeable in general, because
 * `status` may itself be null: the fallback branch hands back `readJson(newest)`, which is null
 * when the newest record is unparseable. So `resolveStatus(...) === null` is true on the FOUR
 * no-record paths (no .pipeline dir, an unreadable .pipeline dir, an mtime tie, no candidate at
 * all) and FALSE on an unparseable record, while "there is no usable phase" is true on all five.
 * run() is written for exactly that -- it reads `resolved?.status?.current_phase` and treats a
 * falsy phase as no phase -- so the difference is invisible TO IT and to nothing else. A new
 * importer writing `if (!resolveStatus(...)) return;` silently treats a record it COULD NOT READ
 * as a record it read, which is a fail-open path that looks like a guard. Test the field you
 * mean: check `.status`, or `.status?.current_phase`, never the wrapper's truthiness.
 *
 * THE MTIME TIE HERE ABSTAINS AND run()'s TURN-BOUNDARY TIE REFUSES, i.e. the two resolve
 * OPPOSITE WAYS, deliberately. The ruling and its reasoning sit at the comparison in run(); this
 * pointer exists because #91 was filed by a reader who found the asymmetry and no statement of
 * it. AC9(e) in tests/test-voice-lint.sh pins this half, the #91 cells pin the other.
 */
export function resolveStatus(projectDir, envIssue) {
  const base = path.join(projectDir, ".pipeline");
  if (!existsSync(base)) return null;
  if (envIssue && ISSUE_DIR_RE.test(envIssue)) {
    const f = path.join(base, envIssue, "status.json");
    const s = readJson(f);
    // The stat is GUARDED and its failure direction is the ruling, not a detail: this branch did
    // readJson only, so taking an mtime here adds a throw site whose exception would land in
    // main()'s blanket catch and exit 0 SILENTLY, which is this control's exact inversion. A
    // tooling failure in new code may only ever make the record read maximally fresh, which
    // leaves the lint loud.
    if (s) return { status: s, dir: path.dirname(f), mtimeMs: statMs(f) };
  }
  let newest = null;
  let newestMs = -1;
  let tiedAtNewest = false;
  let entries;
  try {
    entries = readdirSync(base, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const d of entries) {
    if (!d.isDirectory() || !ISSUE_DIR_RE.test(d.name)) continue;
    const f = path.join(base, d.name, "status.json");
    // Dropping the candidate here is residual (ix) too, DIRECTION: SILENCE. This is the line a
    // PERSISTENT permission fault takes -- existsSync returns false, so the catch below never runs.
    if (!existsSync(f)) continue;
    let ms;
    try {
      ms = statSync(f).mtimeMs;
    } catch {
      // Dropping the candidate is residual (ix), DIRECTION: SILENCE. Declared, not fixed; read
      // it before "fixing" this to POSITIVE_INFINITY the way statMs does.
      continue;
    }
    if (ms > newestMs) {
      newestMs = ms;
      newest = f;
      tiedAtNewest = false;
    } else if (ms === newestMs) {
      tiedAtNewest = true;
    }
  }
  // A tie is the absence of a signal, not a weaker one: abstain rather than let readdir order
  // decide whose run gets voice-checked. The caller treats a null status as "no phase", which
  // is already its fail-open path.
  if (tiedAtNewest) return null;
  if (!newest) return null;
  return { status: readJson(newest), dir: path.dirname(newest), mtimeMs: newestMs };
}

/** A file's mtime, or POSITIVE_INFINITY when it cannot be taken. See resolveStatus for why. */
function statMs(file) {
  try {
    return statSync(file).mtimeMs;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

/**
 * Was this record TYPED BY THE OWNER? Six clauses, all positive, all ANDed.
 *
 * IDENTIFICATION IS POSITIVE, NEVER BY EXCLUSION, and that is the whole design rather than a
 * preference. Subtracting known machine spellings from the set of user records inherits every
 * future spelling the vendor adds, and it admitted this script's own refusal record, which
 * disarmed the control the instant it first fired. So a record the owner did not type must not
 * advance the boundary, and where provenance cannot be POSITIVELY established the boundary does
 * not advance at all, which keeps the lint loud.
 *
 * NO MESSAGE CONTENT IS READ, and that is a ruling. Reading content produced two of the three
 * silent drift classes found in review (a renamed tool_result block type; tool results relocated
 * out of message.content[]), and dropping the read removes both at once. It also stops the
 * predicate rejecting the 12 measured owner messages whose content is an array carrying an image
 * block, and the 957 of 969 whose content is a bare string.
 *
 * `origin` IS RECORD-LEVEL, never message.origin. See the header: the misreading finds zero
 * human turns on every transcript ever written and ships as a silent no-op.
 *
 * EVERY ACCESS IS GUARDED and a malformed-but-parseable record is FALSE rather than a throw: a
 * throw from here reaches main()'s blanket catch and exits 0 silently, which is fail-OPEN and
 * the exact inversion of this control's direction.
 *
 * EXPORTED so the suite can drive one record in and read one verdict out. A process exit code is
 * moved by four other things (the phase table, the shape check, the transcript read, lintVoice),
 * so a cell reading only rc cannot say which of them moved.
 */
export function isHumanTurnRecord(record) {
  return (
    record !== null &&
    typeof record === "object" &&
    record.type === "user" &&
    record.isSidechain !== true &&
    record.isMeta !== true &&
    record.message?.role === "user" &&
    record.origin?.kind === "human" &&
    typeof record.timestamp === "string" &&
    Number.isFinite(Date.parse(record.timestamp))
  );
}

/** How fresh a status record reads. updated_at may only WIDEN this; see the header's ruling. */
function recordFreshnessMs(mtimeMs, updatedAt) {
  const stated = typeof updatedAt === "string" ? Date.parse(updatedAt) : NaN;
  return Number.isFinite(stated) ? Math.max(mtimeMs, stated) : mtimeMs;
}

/**
 * ONE reverse pass over a Claude Code JSONL transcript, yielding both things the Stop hook needs:
 * { text, humanTurnMs }.
 *
 *   text        the last assistant text block, or "" if none was found
 *   humanTurnMs the timestamp of the last owner-typed record IN FILE POSITION, or null when no
 *               such record is recognisable (see the header for why position and not max)
 *
 * ONE READ AND ONE TRAVERSAL, DELIBERATELY, AND THE FUSION IS THE WART. A second pass for the
 * boundary would double a cost measured at 620 ms on the largest transcript on this machine
 * (69.8 MB, 26,460 records), and a Stop hook slow enough to be timed out by the harness is a
 * silent disarm in the same direction as everything else here. The price is one function with
 * two responsibilities, paid knowingly.
 *
 * A READ FAILURE RETURNS { text: "", humanTurnMs: null }, which is the pre-#56 behaviour
 * unchanged: run() returns on the empty text before any boundary question is asked, so an
 * unreadable transcript stays silent rather than acquiring a new refusal.
 */
export function scanTranscript(transcriptPath) {
  let raw;
  try {
    raw = readFileSync(transcriptPath, "utf8");
  } catch {
    return { text: "", humanTurnMs: null };
  }
  const lines = raw.split("\n").filter((l) => l.trim() !== "");
  let text = "";
  let humanTurnMs = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    let rec;
    try {
      rec = JSON.parse(lines[i]);
    } catch {
      continue;
    }
    if (text === "" && rec?.type === "assistant") {
      const content = rec?.message?.content;
      if (Array.isArray(content)) {
        const joined = content
          .filter((c) => c && c.type === "text" && typeof c.text === "string")
          .map((c) => c.text)
          .join("\n");
        // The JOINED string is what has to be non-blank, not the block count. A record whose only
        // text block is whitespace is SKIPPED, exactly as before, and the two conditions pick
        // different messages on that input.
        if (joined.trim() !== "") text = joined;
      }
    }
    if (humanTurnMs === null && isHumanTurnRecord(rec)) humanTurnMs = Date.parse(rec.timestamp);
    if (text !== "" && humanTurnMs !== null) break;
  }
  return { text, humanTurnMs };
}

/**
 * The lint itself, pure and exported so the self-test can drive it without a transcript.
 * Returns an array of human-readable failures; empty means the shape is present.
 */
export function lintVoice(text, moment) {
  const failures = [];
  if (!moment || typeof text !== "string" || text.trim() === "") return failures;

  if (moment.decision && !/^###\s+I need a decision\s*$/m.test(text)) {
    failures.push(
      `this is ${moment.label}, which voice.md says ends with the decision block, and there is no "### I need a decision" heading`,
    );
  }
  if (moment.scales) {
    for (const scale of ["Blast radius", "Reversibility", "Confidence"]) {
      if (!new RegExp(`\\*\\*${scale}:\\*\\*`).test(text)) {
        failures.push(
          `this is ${moment.label}, which carries the rating scales, and "**${scale}:**" is missing`,
        );
      }
    }
  }
  if (moment.replication && !/^###\s+See it yourself\s*$/m.test(text)) {
    failures.push(
      `this is ${moment.label}, and the "### See it yourself" replication block is missing; voice.md calls these steps not optional`,
    );
  }
  // An em dash is the one language rule with no judgment in it: voice.md bans it outright.
  if (/—/.test(text)) {
    failures.push('voice.md bans the em dash outright ("anywhere, ever"); use a comma, colon, or parentheses');
  }
  const lower = text.toLowerCase();
  for (const phrase of BANNED_PHRASES) {
    if (lower.includes(phrase)) {
      failures.push(`"${phrase}" assumes the owner was in the thread; voice.md says they were not`);
    }
  }
  return failures;
}

/**
 * status.json's current_phase, checked for SHAPE against the pattern in status.schema.json.
 *
 * Nothing else validates this file. status.json is written by the ORCHESTRATOR, not a subagent,
 * so SubagentStop never sees it, and it appears in no AGENT_RULES entry; the schema walker does
 * not implement `pattern` either, so its one constraint has never been enforced anywhere. That
 * matters here specifically: a malformed phase matches no entry in VOICE_MOMENTS, and this
 * whole check would go SILENT rather than loud. So the guard lives beside the thing it
 * protects. The pattern is read from the schema rather than copied, so the two cannot drift.
 */
function phaseShapeFailure(phase, scriptDir) {
  let pattern;
  try {
    const schema = JSON.parse(
      readFileSync(path.resolve(scriptDir, "..", "schemas", "status.schema.json"), "utf8"),
    );
    pattern = schema?.properties?.current_phase?.pattern;
  } catch {
    return null; // no schema readable: fail open
  }
  if (!pattern) return null;
  let re;
  try {
    re = new RegExp(pattern);
  } catch {
    return null;
  }
  if (re.test(phase)) return null;
  return `status.json current_phase "${phase}" does not match status.schema.json's pattern ${pattern}. Nothing else validates this file, and a malformed phase silently disables the voice check rather than failing it.`;
}

export function run(payload, projectDir, scriptDir = SCRIPT_DIR) {
  // Already inside a stop-hook continuation: never block twice, or a stubborn message loops.
  if (payload?.stop_hook_active) return { failures: [], phase: null };
  const resolved = resolveStatus(projectDir, process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE);
  const phase = resolved?.status?.current_phase;
  if (!phase) return { failures: [], phase: null };
  const shapeFailure = phaseShapeFailure(phase, scriptDir);
  if (shapeFailure) return { failures: [shapeFailure], phase };
  const moment = VOICE_MOMENTS[phase] || errorMoment(phase);
  if (!moment) return { failures: [], phase }; // a declared non-voice checkpoint
  const transcript = payload?.transcript_path;
  if (!transcript) return { failures: [], phase };
  const { text, humanTurnMs } = scanTranscript(transcript);
  if (text.trim() === "") return { failures: [], phase };
  // TURN SCOPING, and it sits HERE for two reasons. It is downstream of resolution, so it applies
  // identically to both resolution branches and there is no second behaviour to keep in sync. And
  // it is downstream of the two unusable-transcript returns above, so no input that is silent
  // today acquires a new refusal. A null boundary skips the block entirely: an unresolvable
  // boundary can never silence a refusal this code would otherwise have produced.
  //
  // THE TIE IS RULED ON, AND IT RESOLVES THE OPPOSITE WAY FROM resolveStatus's MTIME TIE. The
  // asymmetry is deliberate and #91 filed it because nothing here said so. THE TWO ARE DIFFERENT
  // QUESTIONS, which is why matching them would be the mistake. resolveStatus ties BETWEEN TWO
  // CANDIDATE RECORDS, where picking either means picking by readdirSync order -- hash order on
  // ext4, insertion order on APFS (#27) -- so it abstains rather than let the filesystem decide
  // whose run gets voice-checked. This compares ONE record against ONE boundary: there is no
  // second candidate and nothing arbitrary to refuse, and equality means the record was touched
  // at the instant the turn began. So the turn window is CLOSED AT ITS LEFT END -- a record is
  // in-turn when recordFreshnessMs >= humanTurnMs -- and one dated exactly at the boundary is IN
  // the turn.
  //
  // WHY STRICT `<` AND NOT `<=`, in this file's own terms: this comparison is the ONLY new
  // suppressor #56 added, and the governing direction above says this change must never be the
  // reason for silence. `<=` would make an exactly-tied record read stale and silence a refusal
  // the pre-#56 code produced, on an input whose ordering is not established. resolveStatus's
  // abstention is not the counter-example it looks like: it predates #56 and is byte-for-byte
  // what it was, so its silence is not this change's silence.
  //
  // REACHABILITY, MEASURED, because a direction nobody can reach is a comment and this one is
  // pinned by tests. mtimeMs is fractional here (12 of 12 live .pipeline records) while a parsed
  // transcript timestamp is a whole millisecond, so the tie is reachable only through the
  // updated_at term -- and 10 of those 12 records write updated_at at WHOLE-SECOND grain, while
  // 0 of 523 observed origin.kind 'human' timestamps land on a whole second. OBSERVED TIES:
  // ZERO. The direction is pinned anyway, at the cost of three cells, because a vendor
  // coarsening either clock makes ties common overnight and this line would then decide silence.
  if (humanTurnMs !== null && recordFreshnessMs(resolved.mtimeMs, resolved.status?.updated_at) < humanTurnMs) {
    return { failures: [], phase };
  }
  return { failures: lintVoice(text, moment), phase, moment, boundaryUnresolved: humanTurnMs === null };
}

function main() {
  let payload = null;
  try {
    payload = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    process.exit(0);
  }
  let result;
  try {
    result = run(payload, payload?.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd());
  } catch {
    process.exit(0); // fail open, always
  }
  if (!result.failures.length) process.exit(0);
  const lines = [
    `Stop hook: this message accompanies pipeline phase "${result.phase}", which voice.md treats as a full voice mode moment, and the required shape is not there.`,
    "",
    ...result.failures.map((f) => `- ${f}`),
    // ATTACHED TO A REFUSAL THAT ALREADY EXISTS, never a refusal of its own, and that holds
    // STRUCTURALLY rather than by convention: it sits after the exit-0 guard above and outside
    // the failures.map, so it cannot create a refusal and cannot change the named-failure count.
    ...(result.boundaryUnresolved ? ["", BOUNDARY_UNRESOLVED_LINE] : []),
    "",
    "Read ${CLAUDE_PLUGIN_ROOT}/voice.md and rewrite the message for someone who did not read the diff.",
    "This checks SHAPE only; a message can pass this and still be written for a machine.",
    "To bypass for a one-off: CLAUDE_HOOK_STOP_SKIP=1",
  ];
  process.stderr.write(lines.join("\n") + "\n");
  process.exit(2);
}

// ---- self-test -----------------------------------------------------------
function selfTest() {
  let pass = 0;
  let fail = 0;
  const check = (name, actual, expected) => {
    if (actual === expected) {
      pass++;
      console.log(`  ok   ${name}`);
    } else {
      fail++;
      console.log(`  FAIL ${name}\n       expected ${expected}, got ${actual}`);
    }
  };
  const has = (t, m) => lintVoice(t, m).length > 0;

  const DECISION = VOICE_MOMENTS["2.5-design-owner-decision"];
  const REPORT = VOICE_MOMENTS["5-archived"];

  const goodDecision = "Some prose.\n\n### I need a decision\n\nWhat I'm asking: pick one.";
  check("decision moment with the block passes", has(goodDecision, DECISION), false);
  check("decision moment without the block fails", has("Some prose, no block.", DECISION), true);
  check("a near-miss heading does not satisfy it", has("### I need a decision now", DECISION), true);

  const goodReport =
    "### Done\n\n### See it yourself\n\nsteps\n\n**Blast radius:** Contained\n**Reversibility:** Undo button\n**Confidence:** Solid";
  check("completion report with scales + replication passes", has(goodReport, REPORT), false);
  check(
    "completion report missing Confidence fails",
    lintVoice(goodReport.replace("**Confidence:** Solid", ""), REPORT).some((f) => f.includes("Confidence")),
    true,
  );
  check(
    "completion report missing See it yourself fails",
    lintVoice(goodReport.replace("### See it yourself", "### Try it"), REPORT).some((f) =>
      f.includes("See it yourself"),
    ),
    true,
  );

  check("an em dash fails", has(`${goodDecision}—here`, DECISION), true);
  check("a hyphen does not fail", has(`${goodDecision} well-formed`, DECISION), false);
  check("an en dash does not fail", has(`${goodDecision} 1–2`, DECISION), false);
  check("a banned phrase fails", has(`${goodDecision} As discussed, this is fine.`, DECISION), true);
  check(
    "the banned-phrase check is case-insensitive",
    has(`${goodDecision} AS YOU KNOW, this is fine.`, DECISION),
    true,
  );

  // Non-zero control on the instrument: a moment of null must never produce failures, or the
  // "not a voice moment" path would be blocking silently.
  check("a null moment lints nothing", lintVoice(goodDecision, null).length, 0);
  check("empty text lints nothing", lintVoice("", DECISION).length, 0);

  // Every key must be a phase pipeline.md actually writes. The bash suite proves that against
  // the file; this asserts the two halves of the partition never overlap, which would make a
  // phase both a voice moment and declared silent.
  for (const k of Object.keys(VOICE_MOMENTS)) {
    check(`"${k}" is not also declared non-voice`, NON_VOICE_PHASES.has(k), false);
  }
  check("an -error phase resolves to a moment", errorMoment("3-error") !== null, true);
  check("a normal phase does not", errorMoment("3-impl") !== null, false);

  console.log(`\nself-test: ${pass} passed, ${fail} failed`);
  return fail === 0;
}

// Self-run ONLY as a real CLI entry, copied from gate-phase-entry.mjs, which ships this guard
// and the comment describing the hazard. isMainScript compares the BASENAME of argv[1], and a
// test that imports this module passes the module's own path there -- without the execArgv
// test, `await import()` SELF-RUNS main(), the importing eval body never executes, and every
// assertion built on the exports above reads a green nothing. Measured before it was added:
// a marker printed BEFORE the import appears and the one after it never does, rc 0.
const evalEntry = process.execArgv.some(
  (a) => a === "-e" || a === "--eval" || a === "--input-type=module" || /^--eval=/.test(a),
);
if (isMainScript("voice-lint.mjs") && !evalEntry) {
  if (process.argv.includes("--self-test")) process.exit(selfTest() ? 0 : 1);
  main();
}
