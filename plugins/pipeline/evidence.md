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

## 9. Deferring is an action, not a decision

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

## 10. Your artifact is read by an operator, not just by a reviewer

Commands you write into a review, a runbook, or a report get run.

A drain procedure was added to an ops document with the wrong table name. It errored and printed
nothing, which is byte-identical to the output an operator runs it to obtain, and the surrounding
paragraph primed exactly that misreading. The test guarding it asserted six textual properties of the
paragraph and never executed the SQL. It then propagated verbatim into a reviewer's own deploy
sequence, **inside the review whose subject was that deploy**.

**Re-derive commands from the repository at the reviewed commit. Never copy them from another
agent's artifact.** And if a document contains a command, the test for that document must RUN it, not
match it.

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
