# QA battery record — issue #40

**This file carries TWO states.** Part I is the post-implementation
re-verification and the rulings QA made on it. Part II is the original Phase 3a
pre-implementation record, kept verbatim so the contract Dev implemented against
is still readable. Read Part I first.

---

# PART I — post-implementation (2026-08-21)

**Tree:** branch `claude/lane-4-a521bf`, 0 behind `origin/main`. Dev's four
implementation commits: `fa90898`, `2f74319`, `affb69d`, `bb986fb`.

**Result: 78 cells — 77 passed, 1 failed, 0 skipped; exit 1.** Full run,
`AC5.suite` included:

```
cells: 77 passed, 1 failed, 0 skipped
failing: AC15.52.replaced
```

Cell-count arithmetic against Phase 3a's 77: `+1` `H.jnode`, `-2` retired
(`AC15.52`, `AC15.59`), `+2` replacements (`AC15.52.replaced`,
`AC15.59.replaced`) = 78. Pass count went 27 → 77.

## Battery repairs made this pass, and why

### The three stuck cells were a harness defect, and it was the mirror of this issue's own subject

`R3.a`, `R3.rnc` and `AC6.typed` compared `jnode`'s output against the shell
literal `'"string"'`. The helper prints a JSON **string** value BARE:

```
$ jnode review.schema.json 'd...must_satisfy.type'
string          <- not "string"
```

So the comparison could never be equal, **for any input, in any document**.
Those three cells were not reading the schema; they were emitting a constant.
That is the always-fires form of the guardrail defect — a check whose output
does not depend on its subject is a zero result about the harness — and it is
worse than no check, because a reader takes the red for a finding and Dev burns
a pass chasing it. Dev was right to refuse to touch `verify-40.sh`, and right
about the diagnosis.

**Repair:** the three literals now read `'string'`. **Sweep:** all 12 `jnode`
call sites were reviewed. Exactly three carried the bug; the rest were already
correct and two of them (`AC6.notrequired` against `'none'`,
`AC10.addprops` against the `<undefined>` sentinel) were already corroborated by
controls that had fired.

**Prevention, because a convention nobody asserts is a comment:** a new cell
`H.jnode` asserts the helper's output contract against a synthetic fixture —
strings bare, numbers and arrays as JSON, `<undefined>` for an absent key,
`<error>` for an absent parent. The next author who mis-quotes a literal now has
a checked convention rather than a remembered one.

### Non-zero controls for the repaired cells — all fired

| control | cell | planted | result |
|---|---|---|---|
| `msreviewdrop` | `R3.a` | DELETE `must_satisfy` from review `agentBlock` concerns.items | **CONTROL-OK** |
| `msreviewtype` | `R3.a` | RETYPE `must_satisfy` `"string"` → `"number"` | **CONTROL-OK** |
| `mspeerdrop` | `AC6.typed` | DELETE `must_satisfy` from `panelVerdict` concerns.items | **CONTROL-OK** |
| `rncdrop` | `R3.rnc` | DELETE `rationale_not_checked` from 1 of its 3 subschemas | **CONTROL-OK** |

Two mutations per repaired assertion where the mechanism differs: deleting the
key makes `jnode` print `<error>`, retyping it makes `jnode` print `number`.
A cell that only caught the deletion would be riding the `<error>` path and
would say nothing about the type it claims to assert. Both redden.

**Full control battery after implementation: 17 CONTROL-OK, 2 CONTROL-N/A, 0
CONTROL-BROKEN** (was 7 OK / 5 N/A pre-implementation). The five that were N/A
for want of an implementation — `middleware`, `censusword`, `censusanchor`,
`censusanchor2`, `reposcope` — now all fire. The census controls in particular:
one word changed in one of the ten copies splits the hash groups, and a
truncated anchor produces the empty-extraction digest, exactly as the design
predicted and as `AC1.census`/`AC1.nonempty` were built to catch.

### A control-harness bug the controls found in themselves

`danglingsha` first reported CONTROL-BROKEN. The cause was not the cell: the
tracker group was guarded by `want 'AC15.*'`, which glob-matches the **literal
string** `AC15.*` against `$ONLY`, so `--only AC15.59.replaced` skipped the
whole group and the cell never ran. The guard now tests the selector
(`case "$ONLY" in AC15*|AC16*|'*')`). Recorded because a CONTROL-BROKEN caused
by the harness, not the cell, is exactly the reading that would have been taken
for a finding.

## Ruling on `AC15.59` — RETIRED, and replaced by the harm it was guarding

The criterion required a comment on #59 "naming commit `b279ffa`", so that
whichever redactor version merged second the comment stayed true. **The world
resolved the condition instead**, and the criterion's letter is now actively
harmful.

**Verified first-hand, not taken from Dev.** Through the real consumer path
(`archiveIssue` in `knowledge-store.mjs`, not a restatement of the regex), into
a throwaway root, **with a non-zero control**:

```
A  "/v1/public-feed must be unreachable without a server-validated bearer
    token, measured by an unauthenticated GET returning 401 before the
    handler runs."
   -> "<redacted-absolute-path> must be unreachable without a server-validated
       bearer token, measured by an unauthenticated GET returning 401 before
       the handler runs."                                    CLAIM SURVIVES

B  "/v1/public-feed"        (CONTROL: the value IS a bare path)
   -> "<redacted-absolute-path>"                             FULLY REPLACED

module-counted redactions: 2
```

Without B, A's survival is indistinguishable from a redactor that never fired.
`grep -n 'ABSOLUTE_VALUE\|LEADING_SPAN' plugins/pipeline/scripts/knowledge-store.mjs`
→ `LEADING_SPAN` at `:147`; `ABSOLUTE_VALUE` is gone. Dev's report is confirmed.

**And obeying the criterion would now ship the staleness it existed to prevent:**

```
$ git merge-base --is-ancestor b279ffa origin/main; echo $?
1                      # b279ffa is a real commit object but NOT an ancestor
$ git merge-base --is-ancestor e7c1bd2 origin/main; echo $?
0                      # e7c1bd2, the commit that actually merged
```

A comment naming `b279ffa` would ship an unresolvable reference.

**Replacement — `AC15.59.replaced`:** no added line in the diff may name a
commit a reader cannot resolve on `origin/main`. Every 7–40 char hex token in
the added lines is filtered to those git knows as commit objects, and each is
required to be an ancestor of `origin/main`. This is the generalised form of the
harm: it covers `b279ffa` and every future dangling SHA, and unlike a comment
assertion it cannot expire. Green today (the shipped text names no commit).

**Its control:** `danglingsha` feeds the real `b279ffa` through a named test
seam (`VERIFY40_EXTRA_SHA`, empty in every normal run, able only to ADD a
candidate and never to suppress a finding). Clean → GREEN; with the dangling SHA
→ RED, naming it. **CONTROL-OK.** Without this the cell's green would be a zero
result: it has never seen a SHA in the real tree.

## Ruling on `AC15.52` — RETIRED, replaced, and a gap filed rather than closed

R10(c) wanted #52 to carry the enumeration of every free-text field this change
adds to the committed-and-archived-verbatim surface, "so its eventual fix is
built against the current field set rather than a stale enumeration". #52 has
CLOSED with its own subject discharged. **There is no eventual fix for the
enumeration to inform**, and a comment on a closed issue is not the durable
record the criterion was buying.

The criterion's PURPOSE survives its letter: the exposure must be written where
the person exposed to it will read it. That is the field's own `description` —
which every reviewer opens and nobody has to remember to check. So the assertion
MOVES there.

**Replacement — `AC15.52.replaced`, two legs:**

1. every field this change adds or re-contracts to that surface carries the
   archived-verbatim exposure note, naming a credential class;
2. **the note does not OVERCLAIM** — it must not say or imply the exposure is
   handled (`automatically redacted`, `safe to paste`, `redacted for you`).

Leg 2 is the one that matters. Leg 1 alone would rubber-stamp a Dev-initiated
addition; leg 2 is what stops a warning growing into a false warranty, which is
the same failure mode AC7 exists to stop one paragraph over.

**Scope note, so this is not read as QA inventing a requirement:** R10(c)'s own
text names the enumeration as **two** fields — "which is TWO fields, not one,
because R3(b) makes `vulnerabilities[].remediation` compulsory". The cell
inherits that scope from the spec and merely relocates it from an issue comment
to the field description.

### THE ONE CELL STILL RED — and it is a real gap, not a battery defect

`AC15.52.replaced` fails on one of its three description sites:

```
| review.schema.json/remediation: no archived-verbatim exposure note
```

Dev added the sentence *"Because that copy is verbatim and public, never paste
credential material into this field."* to **both** `must_satisfy` descriptions
and **not** to `vulnerabilities[].remediation`. That is the worst of the three
to omit: `remediation` is the SecOps field, the one whose contract explicitly
invites describing a security fix, and the one whose 229-row live corpus is the
population the empty-string residual is drawn from. A reviewer writing how a
leaked secret must be rotated is precisely where a token gets pasted.

**Fix is one sentence** appended to that description. Both of its controls
(`creddrop`, `credover`) report CONTROL-N/A today because a control cannot
discriminate against an already-red cell; they become runnable the moment the
sentence lands, and Dev should re-run `--controls` then.

## Ruling on Dev's unprompted credential sentence — it warrants a cell, with a caveat in the cell

The sentence has no acceptance criterion behind it. It is nevertheless the right
addition and it is squarely inside R10(c)'s named scope, so it gets a cell
(`AC15.52.replaced` above) — pinning it so it cannot silently regress, and
bounding it so it cannot grow into a warranty.

**But it is a NORM, not a CONTROL, and the battery says so on every green run:**

```
NORM, NOT A CONTROL: no minLength, no pattern, no redaction of credential material.
A reviewer who pastes a token still validates clean and is still archived verbatim.
```

An unenforced prose instruction inside a change whose entire subject is
distrusting unenforced norms deserves to be labelled as one.

### GAP.52 — a class with no tracker home

Printed in the battery's MANUAL block on every run, at every exit code, because
retiring `AC15.52` must not retire the thing it protected:

#52 named a class — free-text reviewer fields committed and archived verbatim —
and closed with only its own subject discharged. This change mitigates its OWN
new fields. The pre-existing **`description`, `notes` and `location`** fields on
review and peer-review shards cross the identical boundary with **no mitigation
at all**, and with #52 closed that class is now tracked **nowhere**.

Orchestrator's call to re-file. **AC16 forbids this implementation opening an
issue, so Dev cannot fix this and must not be asked to.**

## Carried forward from Phase 3a, still open

- **F2 (`AC16.nonew`)** — now GREEN, and the reason is worth recording rather
  than pocketing. It is not green because anything about this change improved:
  #67 and #68, the two out-of-baseline issues, were **closed by another lane at
  `2026-08-21T21:22:27Z`**, after Phase 3a raised them and before this
  re-verification ran. The open set is now
  `3 19 21 25 38 40 44 53 56 61 63 66`, a subset of the baseline. **The
  criterion's weakness is unchanged**: AC16 compares against a set frozen at
  `ba_approved_at`, so in a multi-lane tree its colour tracks other lanes'
  tracker activity, not this implementation's. It went red for a reason that was
  not this change, and it went green for a reason that was not this change
  either. Route to BA: re-derive the baseline at Phase 3 start, or restate AC16
  as "no issue created after `<phase-3-start>` by this run".
  Also reported by the same cell and not a violation: #52, #54, #58 and #59 have
  closed since the baseline.
- **F1 (`AC5.rebased`)** — RESOLVED. `git rev-list --count HEAD..origin/main` is 0.
- **AC3's two-reader classification** and **AC13's loaded-text rendering** remain
  MANUAL and undischarged by any exit code of this battery. AC13 belongs to the
  orchestrator: re-load `/pipeline --issue 40` and report the rendered
  `surface_probe` line verbatim.

## Nit for the Phase 4 panel (not a cell)

`review.schema.json`'s `must_satisfy` description, part (f), reads *"nothing
about agentBlock's own required list, which this change does not touch."* That
is true of the **block-level** list `[verdict, reviewed_at, concerns, notes]`
and false of the **concerns.items** list, which this change edits. The sentence
is defensible on the first reading and misleading on the second. Low severity,
prose-only, no cell.


## Post-implementation battery output (verbatim)

Command: `bash .pipeline/40/verify-40.sh`, full run, nothing deferred.

```
=== verify-40.sh :: QA behavioural verification battery for #40
    repo : /Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf
    src  : /Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf
    head : bb986fb
    base : ad35fa84a287 (merge-base with origin/main)
    NOTE : this is a command, not a gate. Nothing runs it for you.

--- H.jnode -- the harness asserts its own output convention
                     | OK   a JSON string prints BARE (never quoted) -> [string]
                     | OK   a number prints JSON -> [7]
                     | OK   an array prints JSON -> [["x","y"]]
                     | OK   an absent key prints <undefined> -> [<undefined>]
                     | OK   an absent PARENT prints <error> -> [<error>]
PASS  [base:GREEN] H.jnode                    jnode prints strings bare; <undefined> and <error> are distinct sentinels

--- AC1 / AC8 -- the ten-copy census and the replicated passage
PASS  [base:GREEN] AC1.count                  agents/ holds exactly nine agent files (the census denominator)
                     | census (count hash):
                     | 10 29b8188e3d50c1941b0a3bf3a1faa3fbcc5baa29
PASS  [base:RED  ] AC1.census                 exactly one distinct block hash, with count 10
PASS  [base:RED  ] AC1.nonempty               no file extracts EMPTY (broken anchor / broken terminator)
PASS  [base:RED  ] AC1.verbatim               all ten copies are byte-identical to design.json canonical_block_text
PASS  [base:RED  ] AC1.placement              the block follows ## Identity in all nine agent files
PASS  [base:RED  ] AC1.tenth                  the tenth copy sits in the Phase 4 preamble (2 line(s) after the guardrail rule)
PASS  [base:RED  ] AC8.colocation             every copy carries the force clause in the same passage

--- AC2 -- the reconciliation of the two colliding rules, WITH its why
PASS  [base:RED  ] AC2.reconcile              both rules named, each with WHY it stays allowed

--- AC3 -- the discriminator, its exemptions, and its two named failure modes
PASS  [base:RED  ] AC3.exemptions             both exemptions stated; the non-binding field is named
PASS  [base:RED  ] AC3.identifier             every copy exhibits an externally-fixed IDENTIFIER example
PASS  [base:RED  ] AC3.form                   discriminator is the ask's FORM, not the bound's origin

--- R3 -- the typed home (the precondition AC4 exercises)
PASS  [base:RED  ] R3.a                       review agentBlock concerns.items.must_satisfy is a string
PASS  [base:RED  ] R3.a.req                   must_satisfy IS in that subschema required list
PASS  [base:RED  ] R3.b                       secops vulnerabilities.items required is exactly severity+description+remediation
PASS  [base:RED  ] R3.b.desc                  remediation gains a description (it had NONE at the base)
PASS  [base:RED  ] R3.rnc                     rationale_not_checked typed in all three subschemas, required in none

--- AC4 -- the location matrix, driven through the SHIPPED hook
                     | agent_type used in every AC4 cell: BARE (dba / secops). See #66.
PASS  [base:GREEN] H.harness                  CONTROL: the hook fires at all (invalid verdict blocks)
PASS  [base:GREEN] H.namespaced               KNOWN #66: the same fixture is INERT under pipeline:dba
PASS  [base:RED  ] AC4.dba.absent             concerns[] row without the property -> block naming it
PASS  [base:GREEN] AC4.dba.absent.ctl         NON-ZERO CONTROL: same shard is SILENT on the pre-change schemas
PASS  [base:GREEN] AC4.dba.present            concerns[] row WITH a non-empty property -> silent
PASS  [base:GREEN] AC4.dba.empty              DISCLOSED RESIDUAL: the empty string satisfies the field
PASS  [base:RED  ] AC4.secops.concerns        SecOps concerns[] row without the property -> block
PASS  [base:RED  ] AC4.secops.vuln            critical vuln with concerns:[] and no remediation -> block
PASS  [base:GREEN] AC4.secops.vuln.ctl        NON-ZERO CONTROL: same shard is SILENT on the pre-change schemas
PASS  [base:GREEN] AC4.secops.present         vulnerabilities[] row WITH a non-empty property -> silent
PASS  [base:GREEN] AC4.secops.empty           DISCLOSED RESIDUAL: empty remediation satisfies
PASS  [base:GREEN] AC4.compliance             VETO via compliance_flags:[{}] is SILENT after the change
PASS  [base:GREEN] AC4.compliance.base        and SILENT before it too (unchanged, not newly opened)
PASS  [base:GREEN] AC10.down.review           DOWN: new-contract concerns[] + undeclared keys pass the OLD agentBlock
PASS  [base:GREEN] AC10.down.secops           DOWN: vulnerabilities[] row with resolved/resolution passes the OLD secops block
PASS  [base:GREEN] AC10.down.peer             DOWN: new-contract panelVerdict passes the OLD peer-review schema
                     | mutated required -> ["severity","description"]
PASS  [base:GREEN] SURVIVOR.selftest          EXPECTED SURVIVOR: self-test blind to it (self-test: 68 passed, 0 failed)
PASS  [base:RED  ] SURVIVOR.discriminates     the mutation KILLS AC4.dba.absent while the self-test survives it

--- AC5 -- non-regression, the rebase precondition, and the path assertion
PASS  [base:GREEN] AC5.selftest               NON-REGRESSION (not coverage): self-test: 68 passed, 0 failed
PASS  [base:RED  ] AC5.rebased                HEAD carries origin/main (R11: line/suite claims are owed a re-measure otherwise)
PASS  [base:GREEN] AC5.paths                  no forbidden path in the diff (tests/ hooks/ scripts/ workflows status.schema.json)

--- AC6 / AC7 / AC10 -- the schema-side contract and the honesty record
PASS  [base:RED  ] AC6.typed                  peer-review panelVerdict concerns.items.must_satisfy is typed
PASS  [base:GREEN] AC6.notrequired            panelVerdict concerns.items gains NO required list
PASS  [base:RED  ] AC6.description            the unenforced-here reason is written where it is read
PASS  [base:GREEN] AC10.addprops              no additionalProperties on ANY of the three edited item subschemas
PASS  [base:RED  ] AC7.review.a               (a) three locations, compliance_flags named unreached
PASS  [base:RED  ] AC7.review.b               (b) deployment-mode record: window, population, re-derivation, #66
PASS  [base:RED  ] AC7.review.c               (c) fail-open degradations, naming the AGENT_RULES lookup miss
PASS  [base:RED  ] AC7.review.d               (d) empty-string residual with 17 of 229 and its split
PASS  [base:RED  ] AC7.review.e               (e) archive residual as the both-versions invariant + the check
PASS  [base:RED  ] AC7.review.f               (f) the neighbour limit
PASS  [base:RED  ] AC7.peer.a                 (a) three locations, compliance_flags named unreached
PASS  [base:RED  ] AC7.peer.b                 (b) deployment-mode record: window, population, re-derivation, #66
PASS  [base:RED  ] AC7.peer.c                 (c) fail-open degradations, naming the AGENT_RULES lookup miss
PASS  [base:RED  ] AC7.peer.d                 (d) empty-string residual with 17 of 229 and its split
PASS  [base:RED  ] AC7.peer.e                 (e) archive residual as the both-versions invariant + the check
PASS  [base:RED  ] AC7.peer.f                 (f) neighbour limit names the severity enum AND final_verdict
PASS  [base:RED  ] AC7.secops.desc            the secops-level description carries the three-location enumeration
PASS  [base:RED  ] AC7.noRepoScope            no repository-identity scoping in the shipped text
PASS  [base:RED  ] AC7.deployScope            the refusal is scoped by DEPLOYMENT MODE in all ten copies
PASS  [base:RED  ] AC7.diffLines              no repository-identity scoping in the 189 added lines

--- AC9 / AC11 -- the SecOps contract, at edit scope, and the untouched licences
PASS  [base:RED  ] AC9.middleware             the :169 mechanism string is gone
PASS  [base:RED  ] AC9.line29                 the :29 "be specific about the remediation" line is gone
PASS  [base:RED  ] AC9.veto                   the VETO template no longer asks for "Remediation: <specific action>"
PASS  [base:RED  ] AC9.veto.property          the VETO template asks what a correct fix must SATISFY
PASS  [base:RED  ] AC9.identifier             an externally-fixed IDENTIFIER example ships in the SecOps contract
PASS  [base:GREEN] AC9.editscope              the six inspection prompts survive verbatim (not bound by R1)
PASS  [base:GREEN] AC11.stdtier               the injected standard-tier block is byte-unchanged (17 lines)
PASS  [base:RED  ] AC11.additive              ba/dev/qa/librarian/art-director gain lines and delete none
PASS  [base:GREEN] AC11.qa                    QA's and Dev's mechanism licence (qa.md :181/:184) is not narrowed

--- AC12 / AC14 -- the surface_probe, raw reading and byte-identity
PASS  [base:GREEN] AC14.count                 commands/pipeline.md carries exactly two probe definitions
PASS  [base:GREEN] AC14.identical             the two definitions are byte-identical
PASS  [base:RED  ] AC9.brace                  both definitions pass the two arguments in brace form
PASS  [base:GREEN] AC12.nomatch               a genuine no-match exits 20 (not 1) from the raw reading
PASS  [base:GREEN] AC12.control               CONTROL: a data-layer path exits 0, so 20 above is a real no-match
PASS  [base:GREEN] AC14.suite                 test-panel-composition-fail-direction.sh passes UNMODIFIED

--- AC15 / AC16 -- the deferrals and the no-new-issue set comparison
                     | issue 38 is OPEN with 20 comment line(s)
PASS  [base:RED  ] AC15.38                    #38 carries the three case names, their file, and the #66 cross-ref
                     | review.schema.json/remediation: no archived-verbatim exposure note
FAIL  [base:RED  ] AC15.52.replaced           the archived-verbatim exposure is written on all three new/changed fields, and does not overclaim
                     | 0 commit-shaped token(s) in the added lines were resolved against origin/main
PASS  [base:GREEN] AC15.59.replaced           no added line names a commit a reader cannot resolve on origin/main
                     | closed since the baseline (NOT a violation, reported for the set comparison): 52 54 58 59
PASS  [base:GREEN] AC16.nonew                 the implementation opened NO new tracker issue

--- AC5.suite -- the whole shipped suite (SLOW: several minutes, run last)
                     | running plugins/pipeline/tests/run.sh ...
PASS  [base:GREEN] AC5.suite                  NON-REGRESSION (not coverage): tests/run.sh exits 0

--- SUMMARY
cells: 77 passed, 1 failed, 0 skipped
failing: AC15.52.replaced

MANUAL -- NOT DISCHARGED BY THIS BATTERY, AT ANY EXIT CODE:
  AC3.manual  Two readers, handed the shipped passage and these five asks, must
              classify all five identically. No script can run this cell.
                1 "the rate limit must be low enough that credential stuffing is
                   not economical, measured by <observation>"          -> IN
                2 "the token lifetime must be short enough that a leaked token
                   expires before a human can act on it, measured by ..." -> IN
                3 "the failed-login lockout threshold must be at most 6 attempts,
                   per the applicable card-data standard"              -> IN
                4 "the webhook signature must be verified with the provider's
                   HMAC-SHA256 scheme"                                 -> IN
                5 "the retry budget must be at most 3", no source named -> OUT
  GAP.52      A CLASS WITH NO TRACKER HOME, recorded here because retiring
              AC15.52 must not retire the thing it was protecting. #52 named a
              class -- free-text reviewer fields committed and archived
              VERBATIM -- and has CLOSED with only its own subject discharged.
              This change mitigates its OWN new fields with a sentence
              (AC15.52.replaced pins it). The PRE-EXISTING `description`,
              `notes` and `location` fields on review and peer-review shards
              cross the identical boundary with no mitigation at all, and with
              #52 closed that class is now tracked NOWHERE. Orchestrator's call
              to re-file: AC16 forbids this implementation opening an issue, so
              Dev cannot fix this and must not be asked to.
              AND THE MITIGATION IS A NORM, NOT A CONTROL: no minLength, no
              pattern, no redaction of credential material. A reviewer who
              pastes a token still validates clean and is still archived
              verbatim. Read the sentence as advice, never as a guard.
  AC13.manual The LOADED-TEXT reading of surface_probe. The substitution happens
              in the slash-command loader, not in a shell, so no repo-resident
              check can witness it. The orchestrator must re-load
              `/pipeline --issue 40` after the change and report the rendered
              definition line VERBATIM. Reporting that it was not observed is the
              correct outcome; claiming a pass without the rendering is not.
EXIT=1
```

---

# PART II — Phase 3a, pre-implementation

**Authored:** 2026-08-21, before any implementation existed.
**Worktree:** `/Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf`
**Branch:** `claude/lane-4-a521bf`  **Merge base with `origin/main`:** `a5a9a4e`
**Battery:** `.pipeline/40/verify-40.sh` (executable; gitignored by `.gitignore:23` `.pipeline/*/*`)

## What this is, and what it is not

It is a **command**, not a CI gate. Nothing runs it automatically, it is not
registered anywhere, and `plugins/pipeline/tests/run.sh` does not glob it. It
lives in a gitignored artifact directory because AC5 forbids this change adding
any file under `tests/`, `hooks/`, `.github/workflows/` or `scripts/`, and
`run.sh` globs `test-*.sh`, so even a correctly-named new file would auto-register
and redden three concurrent sessions' CI. It is strictly better than reviewer
eyes and strictly weaker than a test. **No file under `plugins/pipeline/` was
created, edited or mutated to produce this record.** `git status --porcelain` is
empty after a full `--controls` run.

Run it:

```
bash .pipeline/40/verify-40.sh                  # all cells (AC5.suite is slow, runs last)
bash .pipeline/40/verify-40.sh --only 'AC4.*'   # one cell or one glob
bash .pipeline/40/verify-40.sh --controls       # the non-zero control battery
```

Exit is 0 only when every cell PASSes and no cell SKIPs. **A SKIP never
contributes to a zero exit.** Every cell declares `[base:RED]` or `[base:GREEN]`:
`base:RED` means the implementation is absent so the cell must fail now;
`base:GREEN` means the cell already passes at the merge base and is a
NON-REGRESSION guard, not coverage. **A `base:GREEN` cell that fails is not
explained by a missing implementation** and the summary calls that out by name.

## Two vacuity bugs this battery had, and how they were found

Recorded because both are the exact defect class the change is about, and because
the second one caught the first.

1. **`AC1.census` passed on a tree containing none of the change.** The first
   draft asserted "exactly one distinct hash, with count 10". At the merge base
   all ten extractions are EMPTY, so the census printed `10
   da39a3ee5e6b4b0d3255bfef95601890afd80709` — one group, count 10 — and the
   cell went green. The design warned about precisely this for a *broken anchor*;
   it applies to the *absent block* just as hard. The empty-digest guard is now
   part of the assertion, and `AC1.nonempty` is kept as its own cell so a partial
   breakage (one file of ten) still has a dedicated name.
2. **`SURVIVOR.killed-by` was a silence asserted against a silence.** Its first
   draft asserted only that the mutated plugin goes silent — true at the merge
   base, where the unmutated plugin is silent too. It now asserts the
   DISCRIMINATION (unmutated BLOCKS, mutated is SILENT) and is `base:RED`.

The same guard was then applied preventively to `AC7.noRepoScope` (refuses to
pass while any of the ten extractions is empty, because an absence asserted over
an empty text is vacuous) and to `AC7.diffLines` (refuses to pass while the diff
adds zero lines under `plugins/pipeline`).

## Cell inventory and now-state (pre-implementation)

`RED now` = failing because the implementation is absent — that is the point.
`GREEN now` = a guard or a disclosed residual that legitimately passes at the
merge base. Do not read the GREEN column as coverage.

### RED now, and correctly so (48 cells)

| cell | what it observes |
|---|---|
| `AC1.census` | exactly one distinct block hash across the ten files, count 10, **and not the empty digest** |
| `AC1.nonempty` | no file extracts EMPTY (a broken anchor or terminator) |
| `AC1.verbatim` | all ten copies byte-identical to `design.json` `chosen_approach.canonical_block_text` |
| `AC1.placement` | in all nine agent files the first `## ` heading after `## Identity` IS the anchor |
| `AC1.tenth` | the tenth copy sits 1–5 lines after the guardrail-refuses line in the Phase 4 preamble |
| `AC8.colocation` | every copy names `concerns[]`, `vulnerabilities[]`, `compliance_flags[]`, `peer-review`, `#66` and the date, **in the extracted passage** |
| `AC2.reconcile` | both colliding rules named, each with its WHY (cost / reachability) |
| `AC3.exemptions` | the non-binding field is named; a `measured by` example ships |
| `AC3.identifier` | every copy exhibits an externally-fixed IDENTIFIER example |
| `AC3.form` | the ask's-FORM discriminator is present AND the over-refusing wording is absent |
| `R3.a` / `R3.a.req` | `must_satisfy` typed on review `agentBlock` concerns.items, and IN its required list |
| `R3.b` / `R3.b.desc` | secops `vulnerabilities.items.required` is exactly severity+description+remediation; `remediation` gains a description (it has NONE today) |
| `R3.rnc` | `rationale_not_checked` typed in all three subschemas, required in none |
| `AC4.dba.absent` | a `concerns[]` row without the property → `decision:block` naming it |
| `AC4.secops.concerns` | a SecOps `concerns[]` row without the property → block |
| `AC4.secops.vuln` | a **critical auth bypass with `concerns: []`** and no remediation → block |
| `SURVIVOR.discriminates` | the required-list mutation KILLS `AC4.dba.absent` while the self-test survives it |
| `AC5.rebased` | `git rev-list --count HEAD..origin/main` is 0 — **see the blocker below** |
| `AC6.typed` / `AC6.description` | `must_satisfy` typed on `panelVerdict`; the unenforced-here reason names #38, the self-test, the count and the file |
| `AC7.review.a`–`.f` (6) | the six honesty parts in `review.schema.json`'s `must_satisfy` description |
| `AC7.peer.a`–`.f` (6) | the same six in `peer-review.schema.json`, with (f) naming the severity enum AND `final_verdict` |
| `AC7.secops.desc` | the `#/properties/secops` sibling description carries the three-location enumeration |
| `AC7.noRepoScope` | no repository-identity scoping in the shipped text (guarded against vacuity) |
| `AC7.deployScope` | the positive twin: all ten copies scope by bare-names vs installed-plugin/namespaced |
| `AC7.diffLines` | the same prohibition over the diff's ADDED lines (guarded against vacuity) |
| `AC9.middleware` | `"Wrap with the global rate-limit middleware (10 req/min)."` is gone |
| `AC9.line29` | `"be specific about the remediation"` is gone |
| `AC9.veto` / `AC9.veto.property` | `Remediation: <specific action>.` is gone; the template asks what a fix must SATISFY |
| `AC9.identifier` | an externally-fixed IDENTIFIER example ships in the SecOps contract |
| `AC9.brace` | both `surface_probe` definitions pass the two arguments in brace form |
| `AC11.additive` | ba/dev/qa/librarian/art-director gain lines and **delete none** — the structural form of R8(a)'s "Dev's mechanism licence is not narrowed", which has no quotable line the way `qa.md:181/:184` do. Vacuity-guarded: an untouched file's zero deletions prove nothing |
| `AC15.38` / `AC15.52` / `AC15.59` | the three deferral comments, read from **comments only**, not the issue body |

### GREEN now — guards, controls and disclosed residuals (27 cells)

| cell | why it is green at the merge base |
|---|---|
| `AC1.count` | `agents/` holds exactly nine files: the census denominator |
| `H.harness` | **live non-zero control**: an invalid `verdict` DOES produce `decision:block` through the shipped hook, today. Without this, every SILENT result below would be a zero result about my sandbox |
| `H.namespaced` | **the environment assertion, not a printed note**: the same fixture is INERT under `pipeline:dba`. Known, tracked, out of scope (#66). This is why every AC4 cell uses a BARE agent type |
| `AC4.dba.absent.ctl`, `AC4.secops.vuln.ctl` | the same blocking fixtures are SILENT on the PRE-CHANGE schemas (read from git at the merge base), so a post-implementation block is attributable to the schema change |
| `AC4.dba.present`, `AC4.secops.present` | a non-empty property → silent |
| `AC4.dba.empty`, `AC4.secops.empty` | **DISCLOSED RESIDUAL, demonstrated not assumed**: the empty string satisfies the required field. The walker has no `minLength` |
| `AC4.compliance`, `AC4.compliance.base` | `{verdict: VETO, concerns: [], vulnerabilities: [], compliance_flags: [{}]}` is SILENT before AND after. The unguarded third channel |
| `AC10.down.review/.secops/.peer` | new-contract shards carrying undeclared keys (`id`, `title`, `evidence`, `must_fix_before_merge`, `ask`, `detail`, `proposed_anchor`, and `resolved`/`resolution` on a vulnerabilities row) validate clean against the PRE-CHANGE schemas |
| `AC10.addprops` | no `additionalProperties` on any of the three edited item subschemas |
| `SURVIVOR.selftest` | the documented **expected survivor** — see below |
| `AC5.selftest` | 68 passed / 0 failed. **NON-REGRESSION, NOT COVERAGE** |
| `AC5.paths` | no forbidden path in the diff |
| `AC5.suite` | `tests/run.sh` exits 0. **NON-REGRESSION, NOT COVERAGE** |
| `AC6.notrequired` | `panelVerdict` concerns.items has NO required list today; AC6 is satisfied by adding none |
| `AC9.editscope` | the six protected inspection prompts survive **verbatim, matched by text re-pinned from the merge base**, not by line number — every line number in `secops.md` shifts once the block is inserted |
| `AC11.stdtier` | the injected standard-tier constraints block is byte-unchanged, demonstrated by diffing the block |
| `AC11.qa` | `qa.md`'s two mechanism-licence lines survive verbatim |
| `AC12.nomatch` / `AC12.control` | a genuine no-match exits **20**, and a data-layer path exits **0**, from the raw reading of BOTH definitions |
| `AC14.count` / `AC14.identical` / `AC14.suite` | two definitions, byte-identical, and `test-panel-composition-fail-direction.sh` passes unmodified |

Totals: 77 cells. 27 green now, 49 red now (48 `base:RED` + `AC16.nonew`), 1
deferred by `--skip` in the listing below and observed PASS in a complete run.

### The documented EXPECTED SURVIVOR

`SURVIVOR.selftest`. Mutation: **remove `must_satisfy` from `agentBlock`'s
`required` list** in an isolated plugin copy. Observed:
`self-test: 68 passed, 0 failed` — unchanged. **This survival is expected and is
not an unfixed hole.** Reason: the self-test builds every review `agentBlock`
with `concerns: []`, so it never reaches the concern-item subschema, which is
exactly what AC5 says in words. The mutation is proved to have landed (the cell
prints `mutated required -> ["severity","description"]`), and the cell that DOES
die under it is asserted immediately beside it as `SURVIVOR.discriminates`.
Issue: #40 / AC5. Without this survivor the battery would be all-red, and an
all-red battery cannot distinguish real coverage from a harness that reddens
indiscriminately.

## Non-zero controls actually run

`bash .pipeline/40/verify-40.sh --controls`. Every plant lands in a throwaway
copy of `plugins/pipeline` under `$TMPDIR`; restoration is `rm -rf` of the copy,
**never `git checkout` of a tracked file**. Each control is two observations, not
one: the cell must be GREEN on the unmutated copy (otherwise it reports
`CONTROL-N/A` rather than a misleading OK) and RED on the mutated one.

| control | cell | planted | result |
|---|---|---|---|
| `addprops` | `AC10.addprops` | `additionalProperties: false` on `agentBlock` concerns.items | **CONTROL-OK** |
| `peerreq` | `AC6.notrequired` | a `required` list on `panelVerdict` concerns.items | **CONTROL-OK** |
| `brace` | `AC14.identical` | one trailing character on definition 2's body line (len 567→568) | **CONTROL-OK** |
| `probe20` | `AC12.nomatch` | `?0:20)` → `?0:1)` in both definitions (2 occurrences reported) | **CONTROL-OK** |
| `qanarrow` | `AC11.qa` | deleted `qa.md:184` | **CONTROL-OK** |
| `stdtier` | `AC11.stdtier` | deleted `secops.md:107` (the CORS/security-headers line) | **CONTROL-OK** |
| `inspection` | `AC9.editscope` | deleted `secops.md:55` (a protected inspection prompt) | **CONTROL-OK** |
| `middleware` | `AC9.middleware` | (restore the mechanism string) | CONTROL-N/A — cell already RED |
| `censusword` | `AC1.census` | one word in one of the ten copies | CONTROL-N/A — cell already RED |
| `censusanchor` | `AC1.nonempty` | truncate one anchor heading | CONTROL-N/A — cell already RED |
| `censusanchor2` | `AC1.census` | truncate one anchor heading | CONTROL-N/A — cell already RED |
| `reposcope` | `AC7.noRepoScope` | a repository-identity enforcement warranty | CONTROL-N/A — cell already RED |

**Seven controls fired for real, pre-implementation.** The five N/A rows are
honest rather than absent: a control cannot discriminate against a cell that is
already red, and each becomes runnable the moment Dev lands the corresponding
work. Dev must re-run `--controls` after implementing and record the five.

Two further live controls run on every normal invocation and both passed today:
`H.harness` (the shipped hook DOES emit `decision:block` on a fixture the current
schema already refuses) and `H.namespaced` (the same fixture is INERT under
`pipeline:dba`). The AC4 blocking cells each also carry a `.ctl` twin run against
the PRE-CHANGE plugin root built from git.

Controls that cannot be planted here, and why: the `AC4.*` blocking cells (their
control IS the pre-change plugin root, and it runs every time), `AC10.down.*`
(validated against schemas read from git at the merge base, so a worktree
mutation cannot reach them by construction), and `AC3.manual` / `AC13` (no
mechanical control exists).

## THREE FINDINGS THAT ARE NOT "THE IMPLEMENTATION IS ABSENT"

These are the `base:GREEN`-and-failing class, plus two spec/reality
contradictions. They are routed rather than worked around, and none of them was
softened out of the battery.

### F1 — BLOCKER for Dev's first step: the branch is not rebased, and `origin/main` has already moved the file the tenth copy lands in

`AC5.rebased` is RED. `git rev-list --count HEAD..origin/main` = **4**.
`origin/main` is `b2a192e`; the merge base is `a5a9a4e`. Between them,
`origin/main` changed **`plugins/pipeline/commands/pipeline.md`** (41 insertions,
4 deletions) and `plugins/pipeline/schemas/status.schema.json`. The two
`surface_probe` definitions have already moved from `:646/:842` to `:658/:854`.
R11 says in terms that a non-zero count means the line-number claims and the
suite-green claim are owed a re-measure before they are cited — and the design
pins `secops.md :29/:169/:192` and the pipeline.md insertion point (~`:746`) by
line number. **Rebase first, then re-pin, then implement.** Every text-anchored
cell in this battery is rebase-proof by construction; the design's line citations
are not.

### F2 — AC16's baseline is stale, not violated

`AC16.nonew` declares `base:GREEN` and FAILS today. Open issues not in the spec's
`ba_approved_at` baseline: **#67 and #68**, both created `2026-08-21T20:36Z` by
`nsmedia-io`, both about test files in other lanes
(`test-scripts-lib.sh` isMain cells; `test-telemetry-exit-attribution.sh` pinned
absolute path). Neither is attributable to this implementation. AC16 compares
against a set frozen at `ba_approved_at`, which a multi-lane tree falsifies on
its own. The cell prints each out-of-baseline issue's `createdAt`, author and
title so a reader can attribute it, and I have not weakened the assertion.
**Route to BA:** either re-derive the baseline at Phase 3 start, or restate AC16
as "no issue created after `<phase-3-start timestamp>` by this run".

Also reported by the same cell, and not a violation: **#52, #54, #58 and #59 have
closed since the baseline.**

### F3 — AC15 asks for comments on two issues that are now CLOSED with zero comments

`gh` at the merge base: **#38 is OPEN** (15 comment lines; a prior comment already
carries `panel major severity accepted` and names `validate-pipeline-artifact`,
so `AC15.38` is red only on the missing `#66` cross-reference — R10(b)'s half).
**#52 is CLOSED with zero comments. #59 is CLOSED with zero comments.** R10(c)
and R10(d) require a comment on each before merge, and AC15 verifies it by
running `gh issue view` directly. Commenting on a closed issue is possible but is
a different act from the one the spec describes, and #59's comment is the one
whose content has a stated merge-order shelf life. **Route to BA/orchestrator**
rather than letting Dev decide silently.

Note on how this was found: `gh issue view N --comments` prints **nothing** for
an issue with zero comments, and my first draft read that emptiness as "gh could
not reach the issue" and reported a SKIP — a real FAIL wearing a SKIP's costume.
It also prints the issue BODY, so a marker already in the body would have passed
a cell meant to observe a COMMENT. Both are fixed: the cells now read
`--json comments` and separately probe `--json state`, so an unreachable tracker
is distinguishable from an empty one, and the state is printed on every run.

## Acceptance criteria with no mechanical cell, and what covers them instead

Printed by the battery on every run, under `MANUAL`, at every exit code:

- **AC3's two-reader classification.** The battery asserts the *mechanical* half
  (both exemptions stated, an IDENTIFIER example present, the ask's-FORM
  discriminator present, the over-refusing wording `however abstractly it is
  phrased` absent). The criterion's binding half — two readers handed the shipped
  passage and the five asks classify all five identically — is a human
  observation and no script can make it. The five asks and their required
  classifications are printed verbatim so the observation is cheap to make.
- **AC13, the loaded-text reading of `surface_probe`.** The substitution happens
  in the slash-command loader, not in a shell, so no repo-resident check can
  witness it. Discharged only by the orchestrator re-loading `/pipeline --issue
  40` after the change and reporting the rendered definition line verbatim.
  Reporting that it was not observed is the correct outcome; claiming a pass
  without the rendering is not. `AC9.brace` covers the shipped bytes; it says
  nothing about the rendering.
- **AC9's "names no mechanism" and AC2's "states WHY", as meanings.** The cells
  assert presence and absence of specific strings — that the old mechanism
  strings are gone, that the new text names the observation vocabulary. Whether a
  replacement sentence is genuinely a *property* rather than a dressed-up
  mechanism is a human judgement and belongs to the Phase 4 panel.
- **AC7's six parts, as content.** The cells assert the MEASURED SPECIFICS are
  present (`2026-08-21`, `1638`, `subagent_type`, `#66`, `AGENT_RULES`, `17`,
  `229`, `ABSOLUTE_VALUE`, `LEADING_SPAN`, `knowledge-store.mjs`, `final_verdict`).
  That marker set is chosen deliberately: the design measured that this repo's
  drift mode is **loss of the specific measured clause under an unchanged
  heading** (3 of 9 existing shared blocks already show it), so the numbers are
  what a drifting copy loses first. A copy that keeps the numbers and mangles the
  prose around them still passes; that residual is a Phase 4 read.

## Pre-implementation battery output (verbatim)

Command: `bash .pipeline/40/verify-40.sh --skip 'AC5.suite'`, run at
`a5a9a4e`-based HEAD with no implementation present.

**Result: 77 cells — 27 passed, 49 failed, 1 deferred; exit 1.**

Of the 49 failures, 48 declare `base:RED` and are the contract Dev implements
against. **One declares `base:GREEN` and is the loud one: `AC16.nonew`** (finding
F2). `AC5.rebased` is among the 48 but is finding F1, not implementation work.

`AC5.suite` was deferred out of this listing only because
`plugins/pipeline/tests/run.sh` takes several minutes; it was observed
**PASS** in a complete run of the same battery against the same tree
(`PASS  [base:GREEN] AC5.suite   NON-REGRESSION (not coverage): tests/run.sh exits 0`).
`--skip` reports SKIP and keeps the exit non-zero on purpose: it defers a cell,
it never drops one.

Full verbatim transcript follows.

```
=== verify-40.sh :: QA behavioural verification battery for #40
    repo : /Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf
    src  : /Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf
    head : e315a12
    base : a5a9a4e85bc5 (merge-base with origin/main)
    NOTE : this is a command, not a gate. Nothing runs it for you.

--- AC1 / AC8 -- the ten-copy census and the replicated passage
PASS  [base:GREEN] AC1.count                  agents/ holds exactly nine agent files (the census denominator)
                     | census (count hash):
                     | 10 da39a3ee5e6b4b0d3255bfef95601890afd80709
FAIL  [base:RED  ] AC1.census                 exactly one distinct block hash, with count 10, and it is not the empty digest
                     | the single group IS the empty-extraction digest: nothing was extracted from any file
FAIL  [base:RED  ] AC1.nonempty               no file extracts EMPTY (broken anchor / broken terminator)
                     | expected: 0
                     | got     : 10
                     | differs from design.json canonical_block_text: plugins/pipeline/agents/art-director.md
                     |   1,15d0
                     |   < ## The property, not the fix (identical for every pipeline agent)
                     |   < 
                     |   < **Scope.** You may say anything about what must be TRUE of a correct fix and what that truth would COST. You may not say HOW to make it tr
                     | differs from design.json canonical_block_text: plugins/pipeline/agents/ba.md
                     |   1,15d0
                     |   < ## The property, not the fix (identical for every pipeline agent)
                     |   < 
                     |   < **Scope.** You may say anything about what must be TRUE of a correct fix and what that truth would COST. You may not say HOW to make it tr
                     | (further differing files suppressed; run --only AC1.verbatim per file)
FAIL  [base:RED  ] AC1.verbatim               all ten copies are byte-identical to design.json canonical_block_text
                     | expected: 0
                     | got     : 10
                     | art-director.md: next heading after Identity is: ## The distinction that gives you teeth
                     | ba.md: next heading after Identity is: ## Style
                     | dba.md: next heading after Identity is: ## Style
                     | design.md: next heading after Identity is: ## Style
                     | dev.md: next heading after Identity is: ## Style
                     | devops.md: next heading after Identity is: ## Style
                     | librarian.md: next heading after Identity is: ## Style
                     | qa.md: next heading after Identity is: ## Style
                     | secops.md: next heading after Identity is: ## Style
FAIL  [base:RED  ] AC1.placement              the block follows ## Identity in all nine agent files
                     | expected: 0
                     | got     : 9
FAIL  [base:RED  ] AC1.tenth                  the tenth copy sits in the Phase 4 preamble
                     | anchor heading absent from commands/pipeline.md
                     | plugins/pipeline/agents/art-director.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
                     | plugins/pipeline/agents/ba.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
                     | plugins/pipeline/agents/dba.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
                     | plugins/pipeline/agents/design.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
                     | plugins/pipeline/agents/dev.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
                     | plugins/pipeline/agents/devops.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
                     | plugins/pipeline/agents/librarian.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
                     | plugins/pipeline/agents/qa.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
                     | plugins/pipeline/agents/secops.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
                     | plugins/pipeline/commands/pipeline.md lacks: concerns[] vulnerabilities[] compliance_flags[] peer-review '#66' the-date
FAIL  [base:RED  ] AC8.colocation             every copy carries the force clause in the same passage
                     | expected: 0
                     | got     : 10

--- AC2 -- the reconciliation of the two colliding rules, WITH its why
                     | plugins/pipeline/agents/art-director.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
                     | plugins/pipeline/agents/ba.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
                     | plugins/pipeline/agents/dba.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
                     | plugins/pipeline/agents/design.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
                     | plugins/pipeline/agents/dev.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
                     | plugins/pipeline/agents/devops.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
                     | plugins/pipeline/agents/librarian.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
                     | plugins/pipeline/agents/qa.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
                     | plugins/pipeline/agents/secops.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
                     | plugins/pipeline/commands/pipeline.md lacks: guardrail-rule evidence.md cost(why-1) reachability(why-2)
FAIL  [base:RED  ] AC2.reconcile              both rules named, each with WHY it stays allowed
                     | expected: 0
                     | got     : 10

--- AC3 -- the discriminator, its exemptions, and its two named failure modes
                     | plugins/pipeline/agents/art-director.md lacks: non-binding-field measured-by-example
                     | plugins/pipeline/agents/ba.md lacks: non-binding-field measured-by-example
                     | plugins/pipeline/agents/dba.md lacks: non-binding-field measured-by-example
                     | plugins/pipeline/agents/design.md lacks: non-binding-field measured-by-example
                     | plugins/pipeline/agents/dev.md lacks: non-binding-field measured-by-example
                     | plugins/pipeline/agents/devops.md lacks: non-binding-field measured-by-example
                     | plugins/pipeline/agents/librarian.md lacks: non-binding-field measured-by-example
                     | plugins/pipeline/agents/qa.md lacks: non-binding-field measured-by-example
                     | plugins/pipeline/agents/secops.md lacks: non-binding-field measured-by-example
                     | plugins/pipeline/commands/pipeline.md lacks: non-binding-field measured-by-example
FAIL  [base:RED  ] AC3.exemptions             both exemptions stated; the non-binding field is named
                     | expected: 0
                     | got     : 10
                     | plugins/pipeline/agents/art-director.md carries no externally-fixed IDENTIFIER example
                     | plugins/pipeline/agents/ba.md carries no externally-fixed IDENTIFIER example
                     | plugins/pipeline/agents/dba.md carries no externally-fixed IDENTIFIER example
                     | plugins/pipeline/agents/design.md carries no externally-fixed IDENTIFIER example
                     | plugins/pipeline/agents/dev.md carries no externally-fixed IDENTIFIER example
                     | plugins/pipeline/agents/devops.md carries no externally-fixed IDENTIFIER example
                     | plugins/pipeline/agents/librarian.md carries no externally-fixed IDENTIFIER example
                     | plugins/pipeline/agents/qa.md carries no externally-fixed IDENTIFIER example
                     | plugins/pipeline/agents/secops.md carries no externally-fixed IDENTIFIER example
                     | plugins/pipeline/commands/pipeline.md carries no externally-fixed IDENTIFIER example
FAIL  [base:RED  ] AC3.identifier             every copy exhibits an externally-fixed IDENTIFIER example
                     | expected: 0
                     | got     : 10
                     | plugins/pipeline/agents/art-director.md states no ask's-FORM discriminator (absence check would be vacuous)
                     | plugins/pipeline/agents/ba.md states no ask's-FORM discriminator (absence check would be vacuous)
                     | plugins/pipeline/agents/dba.md states no ask's-FORM discriminator (absence check would be vacuous)
                     | plugins/pipeline/agents/design.md states no ask's-FORM discriminator (absence check would be vacuous)
                     | plugins/pipeline/agents/dev.md states no ask's-FORM discriminator (absence check would be vacuous)
                     | plugins/pipeline/agents/devops.md states no ask's-FORM discriminator (absence check would be vacuous)
                     | plugins/pipeline/agents/librarian.md states no ask's-FORM discriminator (absence check would be vacuous)
                     | plugins/pipeline/agents/qa.md states no ask's-FORM discriminator (absence check would be vacuous)
                     | plugins/pipeline/agents/secops.md states no ask's-FORM discriminator (absence check would be vacuous)
                     | plugins/pipeline/commands/pipeline.md states no ask's-FORM discriminator (absence check would be vacuous)
FAIL  [base:RED  ] AC3.form                   discriminator is the ask's FORM, not the bound's origin
                     | expected: 0
                     | got     : 10

--- R3 -- the typed home (the precondition AC4 exercises)
FAIL  [base:RED  ] R3.a                       review agentBlock concerns.items.must_satisfy is a string
                     | expected: "string"
                     | got     : <error>
FAIL  [base:RED  ] R3.a.req                   must_satisfy IS in that subschema required list
                     | expected: description,must_satisfy,severity
                     | got     : description,severity
FAIL  [base:RED  ] R3.b                       secops vulnerabilities.items required is exactly severity+description+remediation
                     | expected: description,remediation,severity
                     | got     : <error>
FAIL  [base:RED  ] R3.b.desc                  remediation gains a description (it had NONE at the base)
                     | description is 0 chars: <absent>
                     | review.schema.json d.definitions.agentBlock.properties.concerns.items: rationale_not_checked type is <error>
                     | review.schema.json d.properties.secops.allOf[1].properties.vulnerabilities.items: rationale_not_checked type is <error>
                     | peer-review.schema.json d.definitions.panelVerdict.properties.concerns.items: rationale_not_checked type is <error>
FAIL  [base:RED  ] R3.rnc                     rationale_not_checked typed in all three subschemas, required in none
                     | expected: 0
                     | got     : 3

--- AC4 -- the location matrix, driven through the SHIPPED hook
                     | agent_type used in every AC4 cell: BARE (dba / secops). See #66.
PASS  [base:GREEN] H.harness                  CONTROL: the hook fires at all (invalid verdict blocks)
PASS  [base:GREEN] H.namespaced               KNOWN #66: the same fixture is INERT under pipeline:dba
FAIL  [base:RED  ] AC4.dba.absent             concerns[] row without the property -> block naming it
                     | SILENT: the hook emitted nothing (no refusal)
PASS  [base:GREEN] AC4.dba.absent.ctl         NON-ZERO CONTROL: same shard is SILENT on the pre-change schemas
PASS  [base:GREEN] AC4.dba.present            concerns[] row WITH a non-empty property -> silent
PASS  [base:GREEN] AC4.dba.empty              DISCLOSED RESIDUAL: the empty string satisfies the field
FAIL  [base:RED  ] AC4.secops.concerns        SecOps concerns[] row without the property -> block
                     | SILENT: the hook emitted nothing (no refusal)
FAIL  [base:RED  ] AC4.secops.vuln            critical vuln with concerns:[] and no remediation -> block
                     | SILENT: the hook emitted nothing (no refusal)
PASS  [base:GREEN] AC4.secops.vuln.ctl        NON-ZERO CONTROL: same shard is SILENT on the pre-change schemas
PASS  [base:GREEN] AC4.secops.present         vulnerabilities[] row WITH a non-empty property -> silent
PASS  [base:GREEN] AC4.secops.empty           DISCLOSED RESIDUAL: empty remediation satisfies
PASS  [base:GREEN] AC4.compliance             VETO via compliance_flags:[{}] is SILENT after the change
PASS  [base:GREEN] AC4.compliance.base        and SILENT before it too (unchanged, not newly opened)
PASS  [base:GREEN] AC10.down.review           DOWN: new-contract concerns[] + undeclared keys pass the OLD agentBlock
PASS  [base:GREEN] AC10.down.secops           DOWN: vulnerabilities[] row with resolved/resolution passes the OLD secops block
PASS  [base:GREEN] AC10.down.peer             DOWN: new-contract panelVerdict passes the OLD peer-review schema
                     | mutated required -> ["severity","description"]
PASS  [base:GREEN] SURVIVOR.selftest          EXPECTED SURVIVOR: self-test blind to it (self-test: 68 passed, 0 failed)
FAIL  [base:RED  ] SURVIVOR.discriminates     the mutation KILLS AC4.dba.absent while the self-test survives it
                     | unmutated plugin: SILENT (want BLOCK)
                     | mutated   plugin: SILENT (want SILENT)

--- AC5 -- non-regression, the rebase precondition, and the path assertion
PASS  [base:GREEN] AC5.selftest               NON-REGRESSION (not coverage): self-test: 68 passed, 0 failed
FAIL  [base:RED  ] AC5.rebased                HEAD carries origin/main (R11: line/suite claims are owed a re-measure otherwise)
                     | expected: 0
                     | got     : 4
PASS  [base:GREEN] AC5.paths                  no forbidden path in the diff (tests/ hooks/ scripts/ workflows status.schema.json)

--- AC6 / AC7 / AC10 -- the schema-side contract and the honesty record
FAIL  [base:RED  ] AC6.typed                  peer-review panelVerdict concerns.items.must_satisfy is typed
                     | expected: "string"
                     | got     : <error>
PASS  [base:GREEN] AC6.notrequired            panelVerdict concerns.items gains NO required list
FAIL  [base:RED  ] AC6.description            the unenforced-here reason is written where it is read
                     | lacks: '#38' names-the-self-test the-68/65-count names-the-file
PASS  [base:GREEN] AC10.addprops              no additionalProperties on ANY of the three edited item subschemas
FAIL  [base:RED  ] AC7.review.a               (a) three locations, compliance_flags named unreached
                     | missing marker(s): compliance_flags vulnerabilities peer-review
FAIL  [base:RED  ] AC7.review.b               (b) deployment-mode record: window, population, re-derivation, #66
                     | missing marker(s): 2026-08-21 1638 subagent_type #66
FAIL  [base:RED  ] AC7.review.c               (c) fail-open degradations, naming the AGENT_RULES lookup miss
                     | missing marker(s): AGENT_RULES
FAIL  [base:RED  ] AC7.review.d               (d) empty-string residual with 17 of 229 and its split
                     | missing marker(s): 17 229
FAIL  [base:RED  ] AC7.review.e               (e) archive residual as the both-versions invariant + the check
                     | missing marker(s): ABSOLUTE_VALUE LEADING_SPAN knowledge-store.mjs
FAIL  [base:RED  ] AC7.review.f               (f) the neighbour limit
                     | missing marker(s): warrant
FAIL  [base:RED  ] AC7.peer.a                 (a) three locations, compliance_flags named unreached
                     | missing marker(s): compliance_flags vulnerabilities peer-review
FAIL  [base:RED  ] AC7.peer.b                 (b) deployment-mode record: window, population, re-derivation, #66
                     | missing marker(s): 2026-08-21 1638 subagent_type #66
FAIL  [base:RED  ] AC7.peer.c                 (c) fail-open degradations, naming the AGENT_RULES lookup miss
                     | missing marker(s): AGENT_RULES
FAIL  [base:RED  ] AC7.peer.d                 (d) empty-string residual with 17 of 229 and its split
                     | missing marker(s): 17 229
FAIL  [base:RED  ] AC7.peer.e                 (e) archive residual as the both-versions invariant + the check
                     | missing marker(s): ABSOLUTE_VALUE LEADING_SPAN knowledge-store.mjs
FAIL  [base:RED  ] AC7.peer.f                 (f) neighbour limit names the severity enum AND final_verdict
                     | missing marker(s): final_verdict severity
FAIL  [base:RED  ] AC7.secops.desc            the secops-level description carries the three-location enumeration
                     | len 0: <absent>
FAIL  [base:RED  ] AC7.noRepoScope            no repository-identity scoping in the shipped text
                     | 10 of 10 blocks are EMPTY: the absence check would be vacuous
                     | plugins/pipeline/agents/art-director.md lacks: bare-names namespaced installed-plugin
                     | plugins/pipeline/agents/ba.md lacks: bare-names namespaced installed-plugin
                     | plugins/pipeline/agents/dba.md lacks: bare-names namespaced installed-plugin
                     | plugins/pipeline/agents/design.md lacks: bare-names namespaced installed-plugin
                     | plugins/pipeline/agents/dev.md lacks: bare-names namespaced installed-plugin
                     | plugins/pipeline/agents/devops.md lacks: bare-names namespaced installed-plugin
                     | plugins/pipeline/agents/librarian.md lacks: bare-names namespaced installed-plugin
                     | plugins/pipeline/agents/qa.md lacks: bare-names namespaced installed-plugin
                     | plugins/pipeline/agents/secops.md lacks: bare-names namespaced installed-plugin
                     | plugins/pipeline/commands/pipeline.md lacks: bare-names namespaced installed-plugin
FAIL  [base:RED  ] AC7.deployScope            the refusal is scoped by DEPLOYMENT MODE in all ten copies
                     | expected: 0
                     | got     : 10
FAIL  [base:RED  ] AC7.diffLines              no added line scopes the refusal by repository identity
                     | the diff adds 0 lines under plugins/pipeline: an absence check over an empty diff is vacuous

--- AC9 / AC11 -- the SecOps contract, at edit scope, and the untouched licences
FAIL  [base:RED  ] AC9.middleware             the :169 mechanism string is gone
                     | present but must be gone: Wrap with the global rate-limit middleware (10 req/min).
                     | in: /Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf/plugins/pipeline/agents/secops.md
FAIL  [base:RED  ] AC9.line29                 the :29 "be specific about the remediation" line is gone
                     | present but must be gone: be specific about the remediation
                     | in: /Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf/plugins/pipeline/agents/secops.md
FAIL  [base:RED  ] AC9.veto                   the VETO template no longer asks for "Remediation: <specific action>"
                     | present but must be gone: Remediation: <specific action>.
                     | in: /Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf/plugins/pipeline/agents/secops.md
FAIL  [base:RED  ] AC9.veto.property          the VETO template asks what a correct fix must SATISFY
FAIL  [base:RED  ] AC9.identifier             an externally-fixed IDENTIFIER example ships in the SecOps contract
                     | no HMAC-SHA256 example in secops.md
PASS  [base:GREEN] AC9.editscope              the six inspection prompts survive verbatim (not bound by R1)
PASS  [base:GREEN] AC11.stdtier               the injected standard-tier block is byte-unchanged (17 lines)
                     | ba.md is untouched: 0 deletions is vacuous here
                     | dev.md is untouched: 0 deletions is vacuous here
                     | qa.md is untouched: 0 deletions is vacuous here
                     | librarian.md is untouched: 0 deletions is vacuous here
                     | art-director.md is untouched: 0 deletions is vacuous here
FAIL  [base:RED  ] AC11.additive              ba/dev/qa/librarian/art-director gain lines and delete none
                     | expected: 0
                     | got     : 5
PASS  [base:GREEN] AC11.qa                    QA's and Dev's mechanism licence (qa.md :181/:184) is not narrowed

--- AC12 / AC14 -- the surface_probe, raw reading and byte-identity
PASS  [base:GREEN] AC14.count                 commands/pipeline.md carries exactly two probe definitions
PASS  [base:GREEN] AC14.identical             the two definitions are byte-identical
                     | definition 1 does not end in the brace form
                     | definition 2 does not end in the brace form
FAIL  [base:RED  ] AC9.brace                  both definitions pass the two arguments in brace form
                     | expected: 0
                     | got     : 2
PASS  [base:GREEN] AC12.nomatch               a genuine no-match exits 20 (not 1) from the raw reading
PASS  [base:GREEN] AC12.control               CONTROL: a data-layer path exits 0, so 20 above is a real no-match
PASS  [base:GREEN] AC14.suite                 test-panel-composition-fail-direction.sh passes UNMODIFIED

--- AC15 / AC16 -- the deferrals and the no-new-issue set comparison
                     | issue 38 is OPEN with 15 comment line(s)
FAIL  [base:RED  ] AC15.38                    #38 carries the three case names, their file, and the #66 cross-ref
                     | lacks: cross-ref-#66
                     | issue 52 is CLOSED with 0 comment line(s)
                     | NOTE: #52 is CLOSED but is in the spec's ba_approved_at baseline. R10(c) still asks for the comment; route the contradiction to BA rather than silently dropping it.
FAIL  [base:RED  ] AC15.52                    #52 names BOTH free-text fields this change adds
                     | lacks: must_satisfy remediation(the-second-field)
                     | issue 59 is CLOSED with 0 comment line(s)
FAIL  [base:RED  ] AC15.59                    #59 states the interaction CONDITIONALLY and names b279ffa
                     | lacks: commit-b279ffa LEADING_SPAN ABSOLUTE_VALUE
                     | closed since the baseline (NOT a violation, reported for the set comparison): 52 54 58 59
FAIL  [base:GREEN] AC16.nonew                 the implementation opened NO new tracker issue
                     | open but not in the baseline: 67 68
                     |   #67 2026-08-21T20:36:30Z  nsmedia-io  Two isMain cells in test-scripts-lib.sh assert on the INVOKER'S cwd, not on 
                     |   #68 2026-08-21T20:36:53Z  nsmedia-io  test-telemetry-exit-attribution.sh reads pipeline.md through a pinned absolu
                     |   If every row above predates this Phase 3, AC16's baseline is stale, not violated.

--- AC5.suite -- the whole shipped suite (SLOW: several minutes, run last)
SKIP  [base:GREEN] AC5.suite                  deferred by --skip (a deferral is not a pass; exit stays non-zero)

--- SUMMARY
cells: 27 passed, 49 failed, 1 skipped
failing: AC1.census AC1.nonempty AC1.verbatim AC1.placement AC1.tenth AC8.colocation AC2.reconcile AC3.exemptions AC3.identifier AC3.form R3.a R3.a.req R3.b R3.b.desc R3.rnc AC4.dba.absent AC4.secops.concerns AC4.secops.vuln SURVIVOR.discriminates AC5.rebased AC6.typed AC6.description AC7.review.a AC7.review.b AC7.review.c AC7.review.d AC7.review.e AC7.review.f AC7.peer.a AC7.peer.b AC7.peer.c AC7.peer.d AC7.peer.e AC7.peer.f AC7.secops.desc AC7.noRepoScope AC7.deployScope AC7.diffLines AC9.middleware AC9.line29 AC9.veto AC9.veto.property AC9.identifier AC11.additive AC9.brace AC15.38 AC15.52 AC15.59 AC16.nonew AC5.suite(skip)

!! 1 cell(s) declared [base:GREEN] and FAILED. Those are NOT explained by
!! a missing implementation. Read them first: broken harness, stale rebase,
!! rotted fixture, or a real regression.

MANUAL -- NOT DISCHARGED BY THIS BATTERY, AT ANY EXIT CODE:
  AC3.manual  Two readers, handed the shipped passage and these five asks, must
              classify all five identically. No script can run this cell.
                1 "the rate limit must be low enough that credential stuffing is
                   not economical, measured by <observation>"          -> IN
                2 "the token lifetime must be short enough that a leaked token
                   expires before a human can act on it, measured by ..." -> IN
                3 "the failed-login lockout threshold must be at most 6 attempts,
                   per the applicable card-data standard"              -> IN
                4 "the webhook signature must be verified with the provider's
                   HMAC-SHA256 scheme"                                 -> IN
                5 "the retry budget must be at most 3", no source named -> OUT
  AC13.manual The LOADED-TEXT reading of surface_probe. The substitution happens
              in the slash-command loader, not in a shell, so no repo-resident
              check can witness it. The orchestrator must re-load
              `/pipeline --issue 40` after the change and report the rendered
              definition line VERBATIM. Reporting that it was not observed is the
              correct outcome; claiming a pass without the rendering is not.
EXIT=1
```

