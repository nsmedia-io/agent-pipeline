# Evidence discipline

The standing rules for what counts as having checked something. `voice.md` governs how the
orchestrator talks to the owner; this file governs what any agent is allowed to claim it verified.

Every rule here was paid for. The origin notes are not decoration: a rule without its founding
example gets rounded off to a platitude within two runs, and the platitude does not catch anything.

The whole file reduces to one sentence. **A check that cannot fail has not passed.**

---

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

## Reviewers who RUN tests need isolation, not just reviewers who plant mutations

The existing rule covers mutation-planting. It is too narrow. Three reviewers dispatched into one
worktree produced 74 failures across 6 files, every one `table 'main.organizations' does not exist` —
a schema-teardown collision between two concurrent vitest processes sharing one `test.db`. None of
the failing files was touched by the diff under review.

The cost is not just wasted runs. One reviewer began investigating whether the change under review
had reordered the suite; another wrote a provisional pessimistic verdict; a third recorded its own
result as contaminated and refused to report either number. All three were reasoning about the
orchestrator's mistake as though it were a property of the diff.

**The rule.** Any reviewer that RUNS a suite — not only one that mutates — gets `isolation:
"worktree"` when the project's tests share state (one test database, one fixture store, one port).
If isolation is unavailable, dispatch them SERIALLY. And when contamination is discovered, tell every
running reviewer the window and the files, so they can discard rather than attribute: the failure
mode is a reviewer confidently explaining your own interference.

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

**Restore a planted mutation from GIT, never from memory, and commit before you start.** A mutation
battery edits the code under test and puts it back N times; the putting-back is where the work gets
destroyed.

- **From memory is not a restore.** One agent ran `git checkout` to revert a planted mutation and
  discarded its own uncommitted fix along with it. It re-applied from context and proved the rebuild
  byte-identical, which is luck, not method: the general case has no such proof and the loss is
  silent.
- **An untracked file survives `git checkout`.** A mutation planted in a file the battery itself
  created is not reverted by it, so it sits in the tree waiting for a later `git commit -a` to ship
  it. **Commit the implementation before the first mutation** so `checkout` owns every file. One agent
  did exactly this, deliberately, and said why.
- **An interrupted battery leaves a planted defect in the tree.** This is the concrete reason mutating
  reviewers need worktree isolation: three of them sharing one tree corrupted each other's evidence,
  and one watched a gate sit disabled mid-review because a neighbour had disabled it.

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

## 3b. A battery where every mutation reddens cannot tell coverage from a rubber stamp

Keep a mutation you expect to **survive**, documented as expected and with its reason recorded.

This is rule 2 turned inward. A zero result needs a non-zero control, and a mutation battery reporting
"all red" is exactly a zero result about your own harness — it is indistinguishable from a harness that
reddens indiscriminately.

Origin, and it is the strongest possible one: an agent's battery reported every mutation caught. The
reading was correct-looking and wrong. Its substitution had collapsed a `\\` to a single backslash, so
one mutation silently became a **copy of an earlier one** and was "caught" by that one's tests. The
harness bug **produced the expected answer**. The only instrument that could have exposed it was a
mutation expected to survive — and when the agent added one, the real result appeared.

Two conditions, both cheap:

- **Prove the mutation you applied is the mutation you meant.** Print the changed line and check it —
  a character count of the thing you were editing is enough. Prefer literal string replacement over a
  regex, and avoid stacking a shell-escaping layer under it.
- **Document the survivor as expected, with its reason and its issue.** Otherwise the next reader
  takes it for an unfixed hole of unknown severity, and the control becomes a worry.

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

## 18. A mutation battery can only mutate the code its fixtures reach

Rule 3 says mutate the assertion, and its second costume says a fixture must actually construct the
collision. Both are about **one** discriminator. This is the same failure at the next size up: when a
criterion governs a **compound predicate**, a fixture set can satisfy every clause of the criterion,
pass every named mutation, hold a verified non-zero control, and still never enter the branch that is
broken.

Origin: a fail-closed rule read

```js
if (webPaidIdentityMissing || (profileIdentityMissing && rivalCount === 0 && !ownAd))
  state = "identity-withheld";
```

Every fixture written for that criterion had `rivalCount === 0`, so all of them exercised the left
disjunct, which closes unconditionally. The right disjunct — a profile gap **with** a finding already
earned — never ran once. Three mutations were planted, all caught. The battery was honest. Rendered
against the real corpus the page **declared the advertiser names withheld and then printed them**,
naming the client as his own competitor on three searches, because a second renderer keyed on a
different field than the first. It reached a client-facing document past 23 acceptance criteria and 90
tests, and the trigger was one endpoint returning empty — what a 404 yields, which a stale build
produces on its own.

**Reading the assertions could never have found it. The assertions were correct. The fixture
population was the limit.**

**How to satisfy it.**

- Where a criterion governs a compound predicate, the criterion names a **fixture matrix** over the
  cross product of its terms, not a representative fixture. State the cells. A cell nobody wrote is a
  branch nobody ran.
- Where two consumers share a population, assert the **partition property over the whole artifact** —
  every item lands in exactly one group — rather than checking each consumer. No per-consumer check
  can see two consumers disagreeing about a predicate, and the whole-artifact form also catches a
  third consumer added later. This is rule 5 applied to a state machine.
- Make the trigger fixture the **real** failure mode, not a blanked field, so the test documents how
  the thing actually happens.
- The membership check can only find the shape it scans for. When one consumer is a list item and
  another is a prose sentence, one property cannot reach both; say so rather than letting the coverage
  read as complete.

**Sibling, and it is counter-intuitive: a control added to make another control falsifiable can blind
it.** A reviewer required an exact-match twin in a fixture so a near-miss identity check could assert
all outcomes in one render. Correct in itself. But the twin `"Acme Pest Control LLC"` *contains* the
near miss `"Acme Pest Control"`, so a `toContain` on the near miss was satisfied by the twin and could
never separate them. Check for this whenever a reviewer requires an **addition to a fixture** rather
than a change to an assertion. Fix by pinning the set exactly, and keep the twin.

**Corollary for rule 3b.** A documented expected survivor that survives because the assertion cannot
see the difference is not a survivor, it is an unfalsifiable clause wearing the label. Before
recording one, confirm the assertion can distinguish the case at all.

---

## 19. A check that reads what ran cannot see what never ran

Rule 1 says a skip is not a pass. This is the version that hides for a month, because there is no
skip to notice: **a stage that never started leaves no record, and the absence of a record is
indistinguishable from the absence of an obligation.**

Origin: a client sat half-onboarded for a month with zero rank checks, zero competitors and zero
backlinks. Three independent checks passed the entire time, and each was correct about its own
question:

| check | why it passed |
| --- | --- |
| health prober | judges runs as stale / stuck / failed. A collector that never ran has no run to judge. |
| preflight row counts | printed `[EMPTY]`, and empty is not a failure |
| trust gate | means "data exists but rendered empty". No data existed, so nothing mismatched. |

Every one asks *did what ran, run correctly*. None asks *did everything that should run, run at
all*. The documentation even said a young client **should** have empty sections, so never-ran and
legitimately-empty were the same observation.

**The expectation already existed in prose.** An archetype table stated the client's configuration
as "Full". Nothing ever compared that claim to the world. **A written expectation that no code reads
is a comment.**

**How to satisfy it.**

- For any mechanism that judges records, ask what it does when the record set is EMPTY. If the answer
  is "passes", it needs a companion that knows the expected set independently.
- Derive "expected" from **configuration, not from history**. Inferring what a thing should do from
  what it has done makes an incomplete thing look like a smaller complete thing, and the check agrees
  with the gap it exists to find.
- Build the expected set from names **actually observed in the system**, never from names you believe
  exist. A matrix that expects something the code never emits fails forever and gets switched off.
- Distinguish **never ran** from **ran and never produced**. Both are incomplete; only the first is
  invisible. A first version of this check matched one verdict spelling out of twelve and reported a
  client "complete" while four of its stages had failed every time they ran. That is rule 16 (your
  enumeration is itself a check) inside the very tool written to enforce this rule.

## 20. A control anchored to a live defect has a shelf life

Rule 2 prefers a **live** defect to a planted one as your non-zero control, and that is still right:
a planted control proves the check finds what you designed it to find, and says nothing about the
kind nobody designed around. But a live defect is a moving part of the system, and the correct
outcome for a defect is that somebody fixes it.

Origin: a control asserted that a class was emitted into a stylesheet that styled nothing, using a
real shipped defect as its subject. A different change fixed that defect, which was the right thing
to do, and the control silently lost the thing it was measuring. It failed loudly only because its
author had written the expiry into the assertion message itself:

```js
expect(css.includes(".paid-row"),
  "the premise: paid-row is emitted and styled nowhere. If this is false the precedent was " +
  "fixed and this control needs a new subject").toBe(false);
```

**How to satisfy it.**

- Anchor to a live defect, and **write its expiry condition into the assertion message**. Without
  that sentence the control either goes green for the wrong reason or fails with a message nobody can
  act on.
- When you re-anchor, make the replacement **discriminate** rather than merely fire. A check that
  reported every case would also "find" the defect while proving nothing. Pin a positive and a
  negative and require exactly the negative back.
- Assert the premises rather than assuming them, so a rename cannot leave the control comparing two
  cases that are both negative and calling that a discrimination.
- The tell that this is happening: a check fails immediately after an **unrelated** fix lands.

## 21. A threshold on a rendered measurement measures the runner

Rule 11 says numbers about live systems carry provenance. This is its environment half: **a
measurement taken from a rendering engine is a fact about the machine that rendered it**, and a
threshold tuned on one machine is a claim about that host until proven otherwise.

Origin: a visual contract gated "at least **3.00x** fewer pixels per record". On the author's machine
the gated table measured 3.30x and passed. The first CI run measured **2.94x** and failed, on the
same commit, with nothing changed. A per-family fingerprint printed each run located it exactly:

| family | author machine | CI |
| --- | --- | --- |
| mono | 328.7px | 328.7px (identical) |
| sans | 265.8px | 256.0px (3.7%) |
| **serif** | **257.4px** | **232.9px (9.5%)** |

Serif was the family the wrapped prose used, and that prose **was** the unstable term's height. The
one family that moved was the one the measurement depended on.

**The asymmetry is the fix.** The new layout measured within 0.4% on both machines; the old one swung
11%. All the instability lived in the term the change **deletes**.

**How to satisfy it.**

- **A ratio against an artifact you are removing is not a durable invariant.** Once it ships, the
  denominator exists only in a fixture, and the gate measures something no reader will ever see.
- Gate the term that will still exist, **absolutely**, and set it by a stated rule rather than by
  whatever passes. Report the ratio; it is the number that says what changed. It is not a gate.
- **Print an environment fingerprint every run**, so a swing is attributable instead of mysterious.
- **Assert the probe, do not print it.** A probe that only ever prints is a zero result about the
  harness. Force a known-wrong environment and require the run to FAIL with a calibration message,
  otherwise a runner-image bump silently recalibrates every threshold downstream.
- Any constant in the formula is itself a measurement. This one was taken from an adjacent element
  three times before anyone measured it in place, and it was wrong by 3px in the forgiving direction.
  Measure it off the render every run and assert the constant against it.
- **Agreement is not corroboration when it shares an environment.** Three reviewers agreed on the
  threshold to two decimals. They were not confirming each other; they were running the same
  unexamined setup. Treat "it passed locally and two people agreed" as one observation.

---

## 22. A classifier validated only on a corpus its own author derived is circular

Rule 3b says a battery where every mutation reddens cannot tell coverage from a rubber stamp. This
is the version that bites when the artifact under test IS a rule: **a corpus assembled by the person
who wrote the rule contains the cases that person already thought of, which is precisely the set the
rule was built to handle.** The fixtures do not test the rule, they restate it.

Origin: a claim-scanner shipped with the note "validated against all 18 fixtures", and its own
specification prescribed the regex rather than the property. Two reviewers, working independently
with different probe strings, each found bypasses. The decisive one was a ONE-WORD variant of the
exact string the whole change existed to retire: the scanner caught `Safety flag detected on this
clip.` and passed `Safety flag detected on this motion clip.` None of the 18 fixtures mixed a
sanctioned token with a banned claim in one sentence, because the author did not conceive of that
shape, which is the same reason the rule failed on it.

Then it recurred inside the remediation. The tightened rule was validated against 33 fixtures and
shipped with a residual that survived: a coordinated subject (`Safety flags and motion were
detected.`) still evaded it. Found the same way, by someone who had not written the rule.

**The corpus grows from the rule's inverse, not from its examples.** Ask what this rule must catch
that it might not, and derive cases from the failure mode rather than from the intent. A fixture set
enumerating the strings you wrote the rule for measures your memory, not the rule's reach.

**How to satisfy it.**

- The set of cases a classifier is validated on must include entries authored by someone other than
  the rule's author, or the validation records that it does not and the number of fixtures is
  reported as a count and never as a coverage claim.
- State the corpus's blind spot in the same breath as its size. "33 fixtures, none of which
  coordinate a sanctioned noun with a banned one" is evidence; "33 fixtures, all passing" is a
  restatement of the rule.
- A residual that survives is documented as a pinned limit inside the rule's own suite, with the
  named design change that would close it, rather than as a backlog item. A limit nobody can find
  is indistinguishable from a limit nobody knows about.

## 23. A claim that code never runs is a measurement, not a reading

Rule 14 says run the command, do not read it. The same failure wears a second costume, and this one
narrows scope rather than breaking a runbook: **an assertion that some code is unreachable, dead, or
excluded gets used to justify NOT fixing it, and it is almost always derived by reading configuration
instead of by running anything.**

Origin: three stale file references surfaced from one corpus move. Two failed loudly. The third was
left unfixed on the reading that its test project excluded files of that name, so it "never runs".
That reading was correct about the file it was read from and wrong about the world: a SECOND project
config existed specifically to include those files under a different runtime, and the package's test
script ran both. The claim propagated through three roles without anyone executing it. When it was
finally run, it failed immediately, and fixing it restored 24 tests that had silently stopped
executing altogether.

The same session produced the benign twin, which is why the rule is about evidence and not about
suspicion: a planted mutation that produced NO failure correctly established that a branch really
was unreachable, because a guard upstream made it so. That is a demonstration. The difference
between the two is not confidence, it is whether anything ran.

**How to satisfy it.**

- "This never runs" is satisfied by running it and showing the absence, never by citing the config
  that appears to prevent it. Config is one input to a behavior; there can always be another.
- Before concluding a path is dead, ask what would EXECUTE it and enumerate those entry points from
  the system rather than from the file in front of you. A second config, a second script target, a
  different runner, or a filter that is narrower than it looks are all ordinary.
- A plant that fails to fire is a RESULT and gets reported as one. It is the cheapest available
  proof of unreachability, and discarding it as a nuisance throws away the only demonstration in
  reach.
- Reviewers: an unreachability claim used to narrow scope carries the same burden as a claim used to
  widen it. Absence of a caller is not absence of a call.

## Applying this

**Authors** state, for every mechanism they ship, its **vacuous form**: the specific circumstance
under which it reports success without having looked.

**Reviewers** do not accept a green result as evidence. Reproduce it, mutate it, and confirm the
harness is alive before believing any zero. When a fix is proposed for a defect you found, the
question is not "does this fix it" but "what does this fix introduce" — in one three-round
remediation, every single round introduced a new defect while closing the last one.

**The orchestrator** verifies rather than relays. An agent's report of a passing gate is a claim; the
gate's output on your own run is evidence. Confirm the two match before merging on either.
