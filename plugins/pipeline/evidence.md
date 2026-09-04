# Evidence discipline

The standing rules for what counts as having checked something. `voice.md` governs how the
orchestrator talks to the owner; this file governs what any agent is allowed to claim it verified.

Every rule here was paid for. The origin notes are not decoration: a rule without its founding
example gets rounded off to a platitude within two runs, and the platitude does not catch anything.

The whole file reduces to one sentence. **A check that cannot fail has not passed.**

---

**This file is the core, and every agent reads it at every tier.** The rules that belong to
CONTROL SURFACES live in `evidence-controls.md` and are read in addition, not instead, when
either holds: the tier is architectural, or the diff touches a control surface (auth, session,
authorization, crypto, secrets, webhook verification, a data-access policy, a migration, CI or
deploy config, or this pipeline's own hooks, gates and scripts). Rule numbers are shared across
the two files, so "rule 18" means the same rule wherever it is cited. The split exists because
the controls rules were learned building gates that check gates, and applied to a product
feature they produce edge cases nobody will ever hit: the mutation battery is right for a
tokenizer in a security hook and wrong for a layout change.

---

## Materiality: what blocks, and what ships as a note

A review finding has TWO axes, and the second one used to be missing. Severity says how bad it
would be. Materiality says whether it happens, and what it costs to undo if it does. A finding
that is severe and hypothetical is a note. A finding that is severe and reachable in normal use
is a block. The rule is the one a careful colleague applies before refusing a merge, written
down so six reviewers apply it the same way.

**Every concern carries three ratings, and a blocking-severity concern without them is treated
as blocking and reported as unrated, so an omission never buys a pass.**

- `likelihood`: `normal-use` (a user following the documented flow hits it), `edge-case`
  (unusual but legitimate input or timing), `adversarial` (needs an attacker or deliberately
  crafted input), `hypothetical` (needs a future edit, a config nobody has, or an environment
  the project does not run in).
- `reversibility`: `undo-button` (a revert), `some-cleanup` (a revert plus a data fix or a
  redeploy), `one-way-door` (a customer saw it, data is gone, a secret left the building).
- `harm`: `data-or-security`, `user-visible`, `internal`, `cosmetic`.

**What blocks.** Severity `blocker`, `critical` or `high`, AND one of: likelihood `normal-use`
or `edge-case`; or likelihood `adversarial` with reversibility `one-way-door` or harm
`data-or-security`. Nothing `hypothetical` blocks. Nothing at `major`, `medium`, `low`, `nit` or
`info` blocks. `scripts/materiality.mjs` is the code form and `merge-peer-review.mjs` applies it
to every shard, so a `REQUEST_CHANGES` with no blocking concern is recorded as
`APPROVE_WITH_NOTES` with the returned verdict kept beside it, and an `APPROVE` carrying a
blocking concern is recorded as `REQUEST_CHANGES`.

**At most two blocking concerns per reviewer.** Rank by user harm and keep the top two; the rest
are notes. A reviewer that returns five blockers has not ranked, and the run cannot fix five
things in one round anyway.

**Notes ship.** A note with a `suggested_patch` (a unified diff or an exact replacement for a
local, obviously-correct fix) is applied by the orchestrator in the same turn, explicit-path
staged, one commit, no Dev dispatch and no panel re-run. A note without one is filed as a
follow-up issue with its evidence, before merge, so it is never silently dropped. Neither
delays the merge.

**The veto is narrow.** A SecOps `VETO` sends the spec back to BA for redesign, which is the
most expensive loop in the pipeline, so it stands only on a named `veto_ground` from the
enumerated surfaces (`auth`, `authorization`, `session`, `crypto`, `secrets`, `injection`,
`webhook-verification`, `data-access-policy`, `migration`, `pii-exposure`, `compliance`). A
`VETO` without one is a `REQUEST_CHANGES`: it still refuses the merge, it does not reopen the
design.

**The test for a finding before you write it down:** would you stop a colleague's merge for
this, today, on this project? If the honest answer is "no, but I would mention it", it is a
note, and the honest rating says so.

(Origin: the archive of this repo. First-pass approval on 4 of 11 runs; Phase 4 the largest
single consumer of run time; a fix to a shell tokenizer in a dev-only hook that ran 7.6 hours
across three spec revisions, two vetoes and four spawned follow-up issues, every finding in it
real and none of them reachable by a user of any product this pipeline builds.)


## A machine-readable claim and a human-readable caveat can disagree, and only one is checked

`gate-pre-phase4-frontend.mjs` reads `raw.token_lint_pass === true` and `raw.axe_pass === true` from
the impl-report. On two consecutive issues in one repo, Dev set both to `true` and wrote an honest
adjacent note saying **no token-lint script and no axe package exist anywhere in the project.** The
note was accurate. The boolean was what the gate read.

Nobody lied. The disclosure and the assertion lived in the same object and said different things, and
the machine consumed the one that could not carry the caveat.

Design caught it both times by looking for the tool rather than reading the field — grepping
`package.json`, every workspace manifest, the lockfile and the ESLint configs, finding nothing, and
recording `token_lint: "n/a"` / `axe.status: "not-run"` instead of inheriting `true`. Its own words:
*a claim I didn't witness, not a run.*

**The rule.** A gate must be satisfied by a COMMAND AND ITS OUTPUT, never by a self-declared boolean.
Where the tool does not exist, the honest value is "not-run", and a gate that cannot distinguish
"not-run" from "passed" is not a gate. If you are the author, do not set a pass flag for a check you
did not execute, however good your substitute was — write the substitute in the note and leave the
flag false.

## An artifact nobody can read is not the durable half of a fix

`.pipeline/` is gitignored in most projects that use this pipeline. So an implementation report, a
review shard and a spec are all invisible to the next reader of the repository.

Twice in one day a correction was written into an implementation report and treated as the
deliverable. One of those was to a report that had ALREADY been corrected at its own Phase 4 — the
stale claim the new issue existed to fix had moved on, while the same false sentence sat in a
`printablePath` doc comment in TRACKED CODE, where the next reader actually meets it.

**The rule.** If a fix is a correction to a claim, the correction lands in tracked code — a comment,
a test name, a doc under `docs/` — or it has not landed. An artifact may RECORD the reasoning; it can
never BE the fix. Before accepting "corrected in the impl-report", ask whether `git grep` would find
it.

## A property over a possibly-empty set is not a check

The commonest defect this pipeline finds, and the one it keeps re-introducing **inside its own
remedies**, is a criterion that ranges over a collection that can be empty. `for every X in S, assert
P(X)` is vacuously true when `S` is `∅`, exits 0, and is indistinguishable from a real pass.

One issue produced six instances in four review rounds, three of them in the fix for the previous one:

- A credential-leak guard asserted "every committed fixture contains no credential rows". The same
  round preferred a GENERATOR over a committed binary — making the committed set empty, so the
  property passed without looking.
- Its replacement asserted `|committed ∪ generated| > 0`, which the generated side satisfies alone,
  so it still said nothing about the committed side — the only side that reaches git history.
- A mount-closure criterion asserted over `docker compose config --services`, which silently omits
  profile-gated services. The one service the criterion was written about was profile-gated.
- The same command exits non-zero without a full env. Swallowed, the service set is empty and
  "no service mounts the data dir" is vacuously true.
- A runbook-command extractor that lifts zero commands executes nothing and passes green.
- A host-side-invocation scan whose count was PINNED to a number: the cheapest way to make a correct
  scanner return that number is to narrow the pattern until it does, and the narrowing drops exactly
  the sites nobody knew about. **A pinned count with the answer pre-printed is a target.**

**The rule.** Before a criterion asserts a property over a set, it must assert the set is non-empty
and of the expected shape, and that whatever produced the set actually ran. Derive counts; never
pin them. And when you write the guard against this, ask what THAT guard fails to bind before you
adopt it — three of the six above were introduced by the fix for the one before.

## A number carries the population it was measured on

The second commonest class here. A figure is correct for one grain and gets quoted for another,
where it is wrong and still plausible. Four instances in one week:

- A vendor's 12-month TRAILING AVERAGE read as a per-month value, so 12 of 16 client-facing cards
  named the wrong peak month.
- A per-task price for one API endpoint applied to a different endpoint's workload — 7.75x apart —
  producing a cost figure 8x too high inside the very issue filed to correct stale cost figures.
- "N of 20" used for two different quantities in one file; a reviewer conflated them and nearly
  replaced a correct number with a wrong one.
- "integrity_check costs 0.64s on the live file" where the measurement was taken on a 343MB COPY and
  the live file is 505MB, stated two paragraphs from the sentence that said so.

**The rule.** A number in an artifact carries its population, its window and its units, or it does
not appear. When you quote a figure from another artifact, re-derive it or say you did not.

## Capture the status of the command, not the pipeline

`cmd 2>&1 | head; echo rc=$?` reports `head`'s status. So does `cmd | tail`, and so does any check
whose liveness gate is written that way — a gate that cannot fail, guarding a gate that cannot fail.
Observed three times in one session's shell work and once inside an acceptance criterion whose whole
job was proving a renderer had run. Capture directly, or use `${PIPESTATUS[0]}` (bash) / `$pipestatus`
(zsh) and be aware they differ.

## 1. A skip is not a pass

Every `continue`, every early `return`, every `if (!x) continue` inside a verification loop is a
place where "we checked and it was fine" and "we never checked" produce the **same output**.

This is the single most common defect this pipeline finds, and it is most dangerous inside the
gates themselves.

Found in one review pass, in four different gates:

- A pagination gate returned clean on empty input: twelve pages parsed, thirteen headings on them,
  none checked, exit 0, verdict SEND.
- A tenancy scanner had seven inputs that silently returned zero sites, under a header promising
  "Every unresolvable input THROWS... It never skips."
- A scope self-assertion compared a constant to a literal copy of itself, never to the filesystem,
  so a new top-level directory was simply never scanned.
- A trust gate did `if (!presence) continue`, silently disabling itself for any section whose id had
  been renamed.

**How to satisfy it.** When both halves of a comparison come from the same run, a mismatch means the
WIRING broke, not that there was nothing to check. Fail loudly, or at absolute minimum report the
skipped count, so "0 issues" can never be printed by a run where 0 checks executed.

A `beforeAll` that throws turns N tests into N **skips**. A suite that reports `13 skipped` and exits
0 is this defect wearing a test runner's clothes. Make the absence of a dependency fail each test on
its own, for its own reason.

## 2. A zero result needs a non-zero control

**Never report "0 problems found" until you have watched that same check report non-zero.** If you
have not seen it go red, you have measured nothing, and your zero is indistinguishable from a broken
harness.

In one session this failed four times to a single agent verifying a single fix, every time producing
a clean-looking `0`: a regex that never matched; the "corrected" regex, still never matching; reading
two result fields that did not exist on the returned object (both coerced to empty, and the printed
`?` was read past); and hand-built input objects keyed differently from what the checker reads. Only
the fifth run, using the real constructor and the real field names, reproduced the known failure.

**The tell to watch for in your own output:** a field printing as `?`, `undefined`, or a suspiciously
round `0` next to a result you wanted. Read the whole line before believing the number in it. A
*count* of matches is not the matches: `grep -c` returning 6 "colour literals" was six issue
references in comments, because `#162` is valid hex. Read the matches.

**And never read a suite's exit code through a pipe.** `pnpm test | tail` gives you tail's 0.

## 6. Ask what your proposed control REFUSES, not only what it catches

Before holding a condition or demanding a guardrail, check it against real inputs and name the
**correct work** it rejects.

A security reviewer required a bid ceiling denominated per day. Reproduced against the live account,
that ceiling would have refused both of the client's shipped campaign templates at the budgets they
actually run, as a hard failure at draft time. Its own words afterwards: its fail-direction rule,
turned on its author.

Two corollaries:

- **A bound with large headroom never fires on a realistic mistake.** A ceiling twenty times above
  any real value is not a control; it is a comment that throws.
- **Gates fail in both directions.** A gate that blocks correct work gets switched off by the
  operator, which costs more than having no gate. A refusal whose remedy is impossible ("run the sync
  that would fix this" when no such sync exists) is that failure in its purest form. Check both
  directions before trusting one.

## 7. The ship-or-block line for a residual

**A control a LIVE INPUT can defeat is a gap. A control only a FUTURE EDIT can defeat is a ratchet.**

A strip rule was un-anchored and applied to the first match only, so a name containing the pattern it
searched for consumed the rule and the identifier survived. The mitigations offered were "not a
security issue" and "nothing live trips it" — both of which had been equally true of the original
defect one round earlier. The trigger was a name typed into a third-party UI: no deploy, no error, no
failing test, and it lands in the next customer-facing document.

> I will not grade the identical defect two ways one round apart.

**The sharper test, when even that is ambiguous:** did the control ever stand between the
trigger-holder and the harm? If the same actor can produce the same outcome by another route the
control never covered, the residual is not what protects anyone, and it ships.

**And when reachability does not separate two defects, direction does.** Two gaps in one file were
both defeatable only by a future edit, so the rule above graded them the same — yet one had already
shipped a bug and the other could not. The separator was which way each one failed.

One mutation *lowered* a computed count, which let a hostile input match a page it should not have
and steal that page's numbers into a client report: it made the system **claim more than it knew**.
The other could only *raise* the same count, and a higher count can only produce more refusals: it
made the system **claim less than it knew**. The first is a defect that ships a falsehood; the second
is a defect that ships a silence.

**Ask what a defect lets the system SAY, not only who can trigger it.** Over-claiming closes now;
over-refusing can be filed, with the cost stated — an honest input silently refusing itself reads to
a user as "no data" on something that has data, which is not free, only cheaper.

## 8. Falsify the explanation, not just the code

When an author explains why something passes, test the explanation.

Two test cases were accepted on a stated rationale about which input positions were vulnerable.
Driving fourteen inputs through the real schema overturned it: all three positions behaved
identically, and two of the three tests were passing for an unrelated reason. They would have
survived any mutation of the code they claimed to cover.

The rule the reviewer wrote afterwards, against itself: *I should have falsified the explanation
rather than accepted it.*

**A comment is a claim.** When a comment asserts a property, either the code earns the sentence or
the sentence comes out. Prefer a repair that makes a wrong value **unconstructible** over one that
adds a check someone must remember.

## 10. Deferring is an action, not a decision

"Routed to the follow-up issue" is not a deferral. **Writing it in the follow-up issue is the
deferral.** Until then it lives in a review artifact nobody reads again and it evaporates.

This was claimed across three consecutive review rounds on one pull request, by three different
agents, and none of the items had been written anywhere. It was caught only because a reviewer
checked the issue rather than the claim.

**How to satisfy it.** Every deferred item is recorded in the tracker with its evidence, its
reasoning, and the file:line it lives at, BEFORE the change that deferred it merges. A deferral
recorded only in a test comment or a pull request body is buried on merge. If the reason it was
deferred is interesting, that reasoning is the most valuable part; record it, because the next person
will otherwise re-derive it and reach the other conclusion.

## 11. Numbers about live systems carry provenance or a warning label

Stale figures propagate through an entire panel without resistance, because every downstream agent
repeats them faithfully.

A live budget figure was wrong by a factor of three for eleven days. It entered a dispatch, then a
spec, then acceptance criteria, then a code comment shipped in a pull request, and six independent
reviewers reproduced it without challenge. The one agent that eventually read the production
warehouse caught it.

**When you state live state, cite how and when you read it, or mark it unverified.** When you receive
live state in a prompt, treat it as unverified until you check it, and check it whenever it is
load-bearing for a refusal or a threshold. Memory files and prior artifacts are point-in-time
observations, not current state.

**A number needs its window and its grain, not only its timestamp.** A freshly-read, correctly-run
query still produces a wrong figure if it sums two tables that answer different questions. "79 rows,
466 impressions" went into an issue as the acceptance target; it was a page-level table (10 rows, 382
impressions) added to a query-by-page matrix (69 and 84). A developer chasing 466 drops the grain
filter and ships a double-count of a single page — the defect written into the criterion meant to
prevent it.

**And the correction inherits the burden.** In the same issue, the justification for rejecting a
broader matching rule cited an over-matching host at "31 days, 68 impressions". That was an
**all-time** figure; inside the window that actually applied it was 4 rows and 5 impressions. The
decision was right and its evidence was fifteen times overstated, so the next person who checks "68"
concludes the concern was fabricated and reverses a correct call. A wrong number replaced by another
wrong number is the same defect one round later, living inside its own fix.

## 13. A turn budget is a deadline, so bank findings as you go

Agents have a hard turn limit. An agent that saves its write-up for the end loses **the entire pass**
every time it misjudges that budget, and it cannot see the budget running out.

This happened repeatedly in one session, twice to a binding verdict that would have blocked a merge,
and once to an investigation that had already found its answer and reported nothing.

**A stub is not a checkpoint. Commit to a VERDICT early, then revise it.** This rule was already in
force, and three agents in one night still lost an entire pass — one at 71 tool calls, one at 91, one
at 86 — because each honoured the letter of it. They wrote a placeholder artifact first, exactly as
instructed, then investigated until the budget ended, and the placeholder said nothing.

Writing the *file* early protects the file. What gets lost is the **judgement**, and that is the only
part nobody else can reconstruct. One of the three had already found two blockers; they survived only
because it happened to summarise them in its reply.

So the checkpoint is a **verdict with its current reason**, written as soon as you have one and
rewritten as it changes — not a scaffold you intend to fill in. If you would be embarrassed to be cut
off right now, you are already past the point where you should have written one down.

**Write the artifact first and update it as you go.** An interim verdict you revise beats a perfect
one that never lands. When the deliverable IS the analysis, keep a running version and append after
each substantive step.

**And when you run out, name what you did not reach.** A partial matrix presented as complete is
worse than an honest one: the next reader treats unrun mutations as passed. Say "these eight were not
run" and the work stays useful. In the same session an agent listed its eight unreached mutations,
the next agent ran all of them plus four more, and two closed a question that had been unverified in
both directions.

Raising the budget is a fix for the symptom; incremental reporting is the fix that survives a harder
question.

## 14. Run the command, do not read it

A command written into a runbook, a review, or an acceptance criterion **gets executed by someone**.
Reading it proves nothing about whether it runs.

Four separate non-running commands surfaced in one session:

- A drain query naming the Prisma model instead of the mapped table: errored and printed nothing,
  which is byte-identical to the answer the operator ran it to obtain.
- A verification step missing its credential wrapper, which exited with the script's own
  **"the platform is down"** code. An operator following the instructions sees what looks exactly
  like a production outage.
- A compose line whose shell variable was eaten by interpolation, rendering `exit= ` with the value
  gone — **and the test written to check it matched the broken output and passed on the bug.**
- A deploy step describing a manual migration that does not exist and walks the operator into a
  database-locked error.

**Reviewers: execute every command in the artifact you are reviewing, in a shell as close to the
operator's as you can get.** One reviewer rendered the compose file, extracted the exact line, and
ran it inside the real container image against the real shell, confirming both the success and the
failure record. That is the standard.

**Authors: a document containing a command needs a test that RUNS it**, not one that matches its
text. And never copy a command from another agent's artifact — re-derive it from the repository at
the reviewed commit. One broken drain query propagated verbatim into a reviewer's own deploy
sequence, inside the review whose subject was that deploy.

## 24. A spec with two copies has two states, and agents read the one nobody updates

An artifact and its human-facing render are two copies of one document. Rulings get made in the place
a human is looking, which is the render, and every downstream agent reads the artifact. The
divergence is silent because both copies are individually well formed and nothing compares them.

Origin: a spec was reworked across four review rounds. `spec.json` was left at round 3 while the
tracker issue body was regenerated at round 4, so exactly two criteria differed: a corrected capacity
figure, and a ruling that a copy-inspection rule had to be narrowed. That narrowing had been decided,
argued and published where the owner would see it. Every agent dispatched afterwards read the
artifact, found no such ruling, and implemented nothing. It surfaced two rounds later when a reviewer
searched the artifact for the ruling's own terms and got zero hits, and it was then re-derived from
scratch as a new criterion. The cost was not the edit. It was two rounds of agents building on a spec
that was missing a decision everyone believed had been made.

The failure is directional, and that is what lets it survive: a human reading the render sees the
current state and has no reason to doubt it, while an agent reading the artifact sees a coherent
earlier state and has no reason to doubt that either. Neither party is looking at something wrong.

**How to satisfy it.**

- ONE copy is the source. The artifact is the source and the render is a projection of it. A ruling
  made anywhere else is not made until it is written back, and "I stated it in my summary to the
  orchestrator" is not written back.
- The check is mechanical and cheap: render the artifact's criteria and diff them against the
  published body at each phase transition. Two well formed copies of one document will never tell you
  they disagree.
- Any role that rules on scope mid-run writes that ruling into the artifact in the same turn it makes
  it. A ruling that lives only in a report reaches nobody who acts on it.
- Reviewers: when a spec cites a decision you cannot find in the artifact, that is a finding, not a
  failed search.

## 25. A claim about what the product does is a measurement, not a premise

The grounding gate makes a fail-direction directive cite the field's real persisted shape. The same
discipline is missing one axis over. A reviewer ruling on what a product may CLAIM is asserting
something about what the product DOES, and that assertion is checkable in the code that implements
it.

Origin: a reviewer flagged customer-facing copy describing a capability as a compliance violation, on
the reading that the product did not do the thing described. The product did. The vision prompt
defined the event mechanically, a dedicated flag carried it, and the dispatcher emitted it, all in
tracked code and all reachable in one grep. The false premise then hardened. It became an acceptance
criterion; the criterion demanded the offending string not survive; and the implementation satisfied
that by deleting the whole control, which removed a live customer alert's only off switch while the
alert kept sending. Three roles acted correctly on one unverified assertion.

The direction is what makes it expensive. A guardrail built on a false premise about the product is
not merely useless. It is enforced, it propagates into criteria, and each downstream role treats it
as settled precisely because the role upstream did.

**How to satisfy it.**

- Before ruling that copy overstates a capability, establish what the capability IS from the code
  that implements it, and cite that. A prompt, a flag, a dispatcher or a schema defines the thing
  being claimed; one of them is findable.
- The distinction that usually decides these is prediction versus observation. A product may describe
  what it recorded. It may not predict what will happen to a person. Both live in the same sentence
  and a bare term list cannot tell them apart, which is why such a list rejects a denial of a claim
  as readily as the claim itself.
- A guardrail that would refuse the product's own accurate vocabulary is refusing correct work, which
  rule 6 already forbids. Run it over the shipped strings before proposing it, not after.
- Orchestrators especially: your assertion about the product becomes an input to other roles' work.
  Verify it, or label it a claim and invite contradiction.

## Applying this

**Authors** state, for every mechanism they ship, its **vacuous form**: the specific circumstance
under which it reports success without having looked.

**Reviewers** do not accept a green result as evidence. Reproduce it, mutate it, and confirm the
harness is alive before believing any zero. When a fix is proposed for a defect you found, the
question is not "does this fix it" but "what does this fix introduce" — in one three-round
remediation, every single round introduced a new defect while closing the last one.

**The orchestrator** verifies rather than relays. An agent's report of a passing gate is a claim; the
gate's output on your own run is evidence. Confirm the two match before merging on either.

**And it holds its OWN actions to that standard, because nothing else here does.** Every role in this
pipeline is reviewed by another role except the one that dispatches them. Gate overrides, merge
sequencing, artifact handling and the facts an orchestrator supplies to agents are unreviewed by
construction, and they are supplied with exactly the authority of a finding. This is the same
asymmetry the Librarian carried until its own claims were brought under the rule it applied to
everyone else's.

Recorded in one architectural run: an orchestrator measured a row count at the wrong grain and passed
it to three agents as verified ground truth, where it became an acceptance criterion before a
reviewer re-derived it at the reader's grain and found the defect unreachable; it re-seeded a stale
artifact during a crash recovery and let a role review against it; it committed its own checkpoints
onto a feature branch twice while reporting they had gone elsewhere; and it merged two pull requests
back to back, so the first one's CI was cancelled and its deploy never ran while both merges showed
green. Agents caught the errors that touched their surfaces. Nothing caught the rest.

So: record every consequential action in `status.json` flags with the evidence that supports it,
state supplied facts as claims and invite contradiction, and when you override a gate, say so in the
panel dispatch and name the property you verified by hand, so a reviewer rules on the override rather
than inheriting it. An orchestrator that never reports an error of its own is not running clean; it
is the only role whose errors have nowhere to surface.
