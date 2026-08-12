# Evidence discipline

The standing rules for what counts as having checked something. `voice.md` governs how the
orchestrator talks to the owner; this file governs what any agent is allowed to claim it verified.

Every rule here was paid for. The origin notes are not decoration: a rule without its founding
example gets rounded off to a platitude within two runs, and the platitude does not catch anything.

The whole file reduces to one sentence. **A check that cannot fail has not passed.**

---

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

## 3. Mutation-test the assertion, not just the code

Planting a defect the check should catch, and confirming it catches it, is the only way to know a
test is load-bearing.

Run it in both directions:

- **Plant the defect.** Swap two counts in the function under test and watch the suite go red. If it
  stays green, the test is decorative. In one review, flipping a constant, deleting a regex anchor,
  and removing a CSS rule all left 43/43 green, which is how three tests were exposed as ornamental.
- **Run a control you expect to red.** This proves the harness is alive before you trust any of its
  greens.

**Mutate each entry of a table separately, not the function as a whole.** A two-entry rule table can
carry one dead entry and still pass a whole-function mutation. That distinction caught a live defect
one round after a whole-function mutation had "confirmed" the same code.

**A mutation that survives once is where the next one hides.** When a planted mutation unexpectedly
lives, do not move on: work out which input family exposes it, add that case, and kill it.

**Beware the cache.** A green run with `Cached: N cached, N total` is a replay, not a run. Force it.
And beware the probe that poisons itself: a cache-invalidation check using an identical edit for
every file will hit entries its own earlier pass wrote, and report everything cached. A unique edit
per run is what makes it decidable.

## 4. Every control needs a positive control that fires in the environment it protects

**Name the event. Name the environment where that event occurs. If they differ, the control is in
the wrong place.**

A check proven to bite in CI proves nothing about a production event CI cannot witness. Three
controls specced in one week could never fire where they mattered:

- A CI test meant to red the build when a second API principal exists. The principal is created by a
  **secrets-manager edit**, an event no committed test can observe. The antecedent is false forever,
  the suite stays green, and the trigger gets crossed in production. The fix was a boot-time guard
  that refuses to start.
- A token registry read from config: present in tests, present in local dev, **absent in production**,
  because the compose file forwards only declared keys.
- An acceptance criterion whose verification command was a task runner invocation that returned a
  cache hit, never ran, and wrote no log. An operator diffing the empty output reads "no diff".

**Put this to reviewers, not to authors.** A spec field gets filled in; a review question gets
argued. "Where does this fire?" as a form field is answered "in CI" truthfully and uselessly.

## 5. No test spans the seam

When two components share a contract carried in a **string or format**, and each side pins its own
half with a hand-written fixture, the contract itself is asserted by nobody. Both suites are green.
Both are honest about their own side. The proposition connecting them has no test at all.

Origin: one package derived an approval summary; another parsed that string back apart to build a
title. Adding a required identifier to the sentence landed in the one position the parser forbade.
The parser fell back to passing the whole raw sentence through, and internal machine identifiers
rendered into a customer-facing PDF. It passed 1,915 tests on one side and 255 on the other.

> One side pins the string and never renders it; the other pins the renderer and never derives a
> string.

**And why the fixtures did not save it:** a hand-copied fixture is a **restatement** of the contract,
not an **observation** of it, so it tracks the copier's attention rather than the code. The diff
refreshed the one fixture whose format had visibly changed and left three others frozen in a shape
that could no longer occur.

**How to satisfy it.** Write at least one test that **derives the value exactly as production does
and feeds it through the consumer's real code path**, asserting on the rendered output. Not a
fixture. Then confirm the cache invalidation covers every file that test imports across the boundary,
or a warm cache replays green over the very format change it exists to catch.

**When a fixture is unavoidable, capture it from the real system and give it a rot detector.** A
captured fixture beats a hand-written one, because it records what the system *did* rather than what
its author believed. But it still freezes, and a suite built on a stale capture goes on passing
confidently about a world that no longer exists. So pin one assertion to a fact the capture asserts
about the **present** — a count, a distribution, a known-failing case — that must hold both before
and after the change. Origin: a contract carried a permanently-passing leg asserting that under the
CURRENT behaviour exactly 2 of 16 inputs resolve. Its author's note is the rule: *if it ever reports
16, the capture has rotted and the other 25 tests are proving nothing.*

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

## 9. A ratchet only bites on the axis it is keyed on

An exhaustiveness check over enum A does not constrain a change that extends member B. Before you
rely on "the compiler will stop the next person", confirm the change you are protecting against
actually moves the axis the check is keyed on.

Origin, caught one issue later by the agent authoring the next contract. A rule table was declared
`Record<OutboundWriteKind, Rule | null>`, exhaustive over three write kinds, and was described to the
owner as a forcing function: the next feature could not ship without deciding its entry. But that
feature added new **members to one kind's payload**, not a new kind. It compiled cleanly. The
forcing function was keyed on a different axis than the change moved, and nobody would have been
stopped.

It fired again one issue later, on a different axis, and this time a reviewer checked before relying
on it: a scanner enforcing tenant scoping covered the operations `findUnique` / `findFirst` /
`update` / `delete` / `upsert` and anchored on an `id` key. A new client-facing read using `findMany`
and `aggregate`, whose where clause never carried an `id`, was invisible to it. Not an exemption
anyone granted — just an axis the ratchet was never keyed on, leaving the tenant predicate on that
read guarded by nothing mechanical at all.

**The second half is worse, and generalises further: a `replace` that does not match is a silent
no-op.** The same table's rule hard-coded the exact shape of the sentence it stripped. A change that
legitimately extends that sentence makes the pattern stop matching, the sanitiser quietly does
nothing, and the unsanitised value ships — with a green typecheck, past the very table that was
supposed to be the ratchet.

**Any sanitiser whose pattern encodes the CURRENT shape of its input fails open when the input
changes.** Assert that it DID something (the input contained X, the output does not, the output is
shorter), never that it merely ran or merely compiles.

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

## 12. A test can pass because of the order its file runs in

A shared fixture store plus a test runner that orders files by size means a test asserting an
**absence** can pass because the thing it looks for has not been created yet.

Origin: a test asserted a particular organisation was absent from a filtered result. It passed. But
that organisation is seeded by a different test file, which the sequencer runs **after** this one
(largest-first, one shared database). The intent was never exercised once. Remove the filtering it
guards and it stays green.

**Any assertion of the form `not.toContain` / `toHaveLength(0)` / `toBeNull` over a shared store is
suspect.** Ask what creates the thing you are asserting is absent, and when. If the answer is
"another file", the test proves nothing.

**How to satisfy it.** Seed the thing you expect to be filtered out **inside the test that asserts
it is filtered**, so the assertion runs against a store that provably contained it. Then confirm the
test fails when the filtering is removed — an absence test that cannot fail is the purest form of
[[a check that cannot fail has not passed]].

**The same defect wears a second costume: a fixture that never constructs the collision.** A tenancy
criterion seeded two tenants "holding the same path under a **different host**" to prove a tenant
filter was load-bearing. But the match key **was** host-plus-path, so the two seeds were already
distinct keys, the filter never had to separate anything, and the leg stayed green under its own
named mutation. A test for a discriminator needs two things that genuinely **must** be
discriminated. Ask what your fixture makes collide, not what it contains.

## 13. A turn budget is a deadline, so bank findings as you go

Agents have a hard turn limit. An agent that saves its write-up for the end loses **the entire pass**
every time it misjudges that budget, and it cannot see the budget running out.

This happened repeatedly in one session, twice to a binding verdict that would have blocked a merge,
and once to an investigation that had already found its answer and reported nothing.

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

## 15. Your own change is a hostile input to your own spec

A spec is written one requirement at a time, and every requirement can be individually correct while
the **set** is inconsistent. The inconsistency does not announce itself. It surfaces later as an
acceptance criterion that passes without doing anything.

Two shapes, both found in a single review round on one spec.

**A requirement whose outcome another requirement's approach cannot construct.** Requirement 7
demanded a three-way discriminator with a middle bucket: "this key exists, but has no rows in the
window". Requirement 9's implementation note recommended a **date-bounded** fetch filtered in memory.
Under a date-bounded read, that middle bucket and "no such key anywhere" are indistinguishable **by
construction** — nothing in the fetched set can separate them. The criterion would have passed with
the buckets silently merged, and no live input would ever have exposed it, because the middle bucket
had zero live instances.

**An invariant that is true today, where your change is what repeals it.** A criterion asserted
"days equals total row count". That was true, and correctly observed: a unique constraint with three
empty discriminator columns made the table one row per (page, date) **under exact equality**. The
change under review replaced exact equality with a canonical union, after which 23 of 81 groups had
more rows than distinct dates — one homepage held 75 rows across 52 dates. Worse, the criterion's own
fixture seeded its three variants on three **different** dates, where the two counts agree either
way. It was vacuous against precisely the defect it was named for.

**How to satisfy it.** For each requirement, ask whether the approach this same document recommends
can actually construct the outcome it demands. For each invariant an acceptance criterion asserts,
**state why it holds**, then check whether the change repeals that reason. An invariant asserted
without its mechanism is a coincidence you have promoted to a test.

## 16. Your enumeration and your oracle are both checks that can fail

Two ways a verification pass reports a confident zero while proving nothing, both observed in one
afternoon on one fix.

**An attack table proves nothing about a class it does not contain.** A reviewer verified a proposed
security fix against eight bypass variants and reported "0 escapes". All eight were *authority*
hijacks — a hostile host. None was a *path* retarget, where the host stays correct and the path walks
backwards into a different page. The table could not have caught the surviving hole. Worse, the same
reviewer had **watched** a path retarget resolve one command earlier, noted it in passing, and then
built a table without it.

> When a fix rests on a proposition, test the **proposition** over a generated space, not a list of
> examples you thought of. Enumerate the *classes* first, and say which class each case belongs to;
> a table with two cases in each of four classes beats twelve cases in one.

**And your oracle can be wrong in the direction that flatters you.** The reviewer that later did this
properly ran a 2.36-million-candidate differential hunt — and caught its own oracle wrong **twice**,
both times in its own favour. Round two reported 49,058 survivors that were entirely a mis-modelling
of how the parser treats redundant slashes. Round three silently normalised the input before
comparing, which made an entire attack class invisible to its own check.

Note what did NOT save it: a non-zero control **passed** in both broken rounds. The control proves
the harness can fire. It says nothing about whether the oracle classifies correctly. When your check
is "did the output match what I expected", a wrong expectation is indistinguishable from a pass.

**How to satisfy it.** Run the harness against a deliberately broken subject and confirm the count is
not merely non-zero but the **right** non-zero. Then check a handful of individual verdicts by hand,
especially the ones that came out the way you hoped.

## 17. Guard where it landed, not how it was spelled

When a parser, normaliser, or decoder sits between the input and the effect, **no blocklist over the
input can be complete**, because the thing you are inspecting is not the thing that acts.

Origin: a guard refused a hostile URL by testing the raw string's second character. WHATWG URL
parsing's *first step* removes every ASCII tab and newline from the input, before the state machine
sees the leading slashes — so the guard read a string the parser never parsed, and a single tab
walked through it onto another host. The dot-segment guard failed the same way, because the parser
also honours percent-encoded spellings the literal comparison missed.

The fix that worked stated an **outcome property** instead: the resolved host must equal the expected
host, and the resolved path may not have fewer segments than the author wrote. That second one catches
encodings nobody enumerated, because it names *what retargeting does* rather than *how it is written*.

> A blocklist cannot enumerate what a parser normalises. A postcondition does not have to.

**The tell:** if closing a bypass means adding another spelling to a list, the control is on the wrong
side of the transformation. Move it after.

**Corollary, for judging a line that looks redundant.** One clause was provably dead: deleting it left
the whole suite green, and a 60,480-case fuzz found nothing that needed it. But the **reciprocal** was
also true — delete the *other* clause and every leg the first one covers stays green too. Each is the
sole guard against the other's regression, and neither can be pinned by a test, *by definition of
redundancy*. Before deleting a clause because nothing fails, delete its counterpart and see whether
the same argument acquits that one too. If it does, they are a pair, not a spare.

---

## Applying this

**Authors** state, for every mechanism they ship, its **vacuous form**: the specific circumstance
under which it reports success without having looked.

**Reviewers** do not accept a green result as evidence. Reproduce it, mutate it, and confirm the
harness is alive before believing any zero. When a fix is proposed for a defect you found, the
question is not "does this fix it" but "what does this fix introduce" — in one three-round
remediation, every single round introduced a new defect while closing the last one.

**The orchestrator** verifies rather than relays. An agent's report of a passing gate is a claim; the
gate's output on your own run is evidence. Confirm the two match before merging on either.
