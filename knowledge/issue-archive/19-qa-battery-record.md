# QA battery record — issue #19

**Phase 3a, authored before any implementation exists.** Worktree
`/Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf`,
branch `claude/lane-4-a521bf`, HEAD `82b7d02`, merge-base with `origin/main` `51fc0f9`.

## What the artifact is, and what it is not

`.pipeline/19/verify-19.sh` is a **COMMAND, not a CI gate.** Nothing runs it for you. It is
not registered in `plugins/pipeline/tests/run.sh` and it never will be under this issue,
because #19 forbids creating or modifying anything under `plugins/pipeline/tests/`. Anyone
re-runs the whole thing in one command from the worktree root:

```
bash .pipeline/19/verify-19.sh              # every cell
bash .pipeline/19/verify-19.sh --controls   # the plant-and-observe control battery
bash .pipeline/19/verify-19.sh --no-suites  # skip the ~9-minute suites (then it CANNOT exit 0)
```

It exits non-zero today, deliberately. It exits 0 only when every cell passes. **A SKIP is
counted as a failure** and **a VACUOUS pass is counted as a failure**, so neither an absent
tool nor an empty diff can be mistaken for green.

Companion files written this phase: `.pipeline/19/baseline-run-sh.txt` (the AC3 per-suite
baseline captured at `82b7d02`, 34/34 suites, exit 0) and `.pipeline/19/tasks.json`.
Nothing is committed, and nothing under `plugins/pipeline/` was touched.

## Result today: PASS=37, FAIL=30, SKIP=0, exit 1

Recorded from a full run at `82b7d02` (25 plain FAIL + 5 VACUOUS-counted-as-FAIL). Every
failure is attributable to the absent implementation, and **every one names the missing
behaviour rather than a missing import or a broken setup**. There are **zero SKIPs**: no
cell fails because the harness could not run, so nothing is hiding behind an unrunnable
check. The run left no trace on the real repository — `git worktree list` 18 before and
after, `git status --porcelain` empty.

### Cells that FAIL now and must go green (the target Dev implements against)

| Cell | What it wants |
|---|---|
| `AC11` | the reviewed diff is NON-EMPTY and a subset of the editable surface (VACUOUS today) |
| `AC11.n` | all nine contracts + `pipeline.md` appear in the diff |
| `AC2.c` | `copied byte-for-byte` in 9/9 contracts (pre-change 0) |
| `AC5` `AC6` `AC7` `AC13` | the four three-way equalities, `9 == 9`, plus `pipeline.md >= 1` for three of them |
| `AC7.s` `AC6.s` | the hygiene / trigger literal co-located with its required clauses |
| `ACblk.1` `.2` `.3` | the appended block byte-identical across nine, matching locked `design.json`, at EOF |
| `AC4.h` `AC4.l` | two harms named as separate; the boundary check stated as a limitation |
| `AC8.c` `.e` `.n1` `.n2` | both clauses, the `EXITS 0` caveat, and the worked `83/2` and `85/0` numbers |
| `AC9.d1` `.d2` `.obs` | both flags disqualified by name; `absolute-git-dir` 9/9 + `>= 1`; 0 predicate uses of `--git-dir` |
| `AC12.x` `AC12.s` | frozen-span exclusion and preamble-span containment (both VACUOUS today) |
| `AC14.p` `.o` `.s` | R6's effect stated (unconditional), never overstated, both clauses in the same sentence |
| `AC15.a` `.b` `.c` | registry NAME, no sweeper, prune-only-once-gone |
| `AC16.p` | the location clause phrased as a whole-chain outcome |

### Cells that PASS now, and why that is not a free pass

These are **non-regression**, not coverage. They pin invariants that hold at `82b7d02`
and that this change is the most likely thing in the repo to break.

- `AC1.a` 0, `AC1.b` 1 — the two counts `test-pipeline-telemetry.sh:91/:93` pin.
- `AC2.a` — the frozen span hashes to `14b65c48479dfceefb780689adccfbd53656b21e` in **all
  ten** files, one group, extracted by CONTENT anchor. `AC2.a2` confirms the span is 15
  lines in all ten, which is the premise that makes an agreeing digest meaningful: ten
  agreeing hashes that are not this one would mean the extraction bounds were wrong, not
  that the block drifted, and the cell says so in its own failure message.
- `AC2.b` — `replicated verbatim` occurs **exactly once** in each of the ten files. This is
  the AC2 extraction terminator anchor and the single thing this change is most likely to
  break silently, which is why the new block must close on `copied byte-for-byte`.
- `AClit`, `AClit.c`, `AClit.d` — the literal-admissibility gate, below.
- `AC12.u`, `AC12.r` — probe uniqueness and the fence-aware/fence-blind separation.
- `AC9.*` — the ten-cell matrix, below.
- `AC16.live` … `AC16.w3` — the six worked location cases and both wrong spellings.
- `AC3`, `AC10.a`, `AC10.b` — 34/34 suites per-suite identical to baseline;
  `self-test: 16 passed, 0 failed`; zero `WARNING` in the doctor's output.

Note on running `run.sh`: it terminates **only with stdin closed**. The battery always
invokes it as `bash plugins/pipeline/tests/run.sh </dev/null`. Without that it hangs at 0%
CPU for 20+ minutes, which looks exactly like a failing suite and is not one.

The five cells that report **VACUOUS** today rather than plain FAIL are `AC11`, `AC12.x`,
`AC12.s`, `AC14.o` and `AC14.s`. Each would have passed trivially against an empty diff —
"no changed line lies inside the frozen span" is true when no line changed, and "zero
occurrences of `prevent` in the added lines" is true when there are no added lines. They
assert their presence half first and count the empty case as a failure, which is the same
defect AC14 itself was rewritten to close, one layer down.

## The disqualified-literal trap, and the cell that catches it

`AClit` does not trust the implementer's choice of literal. For each of the four it
recomputes the **pre-change** count from `git show <merge-base>:<file>`, so the claim is
checkable from the post-change tree rather than taken on trust:

```
pre-change medium      [absolute-git-dir]              = 0/9
pre-change trigger     [about to write a tracked file] = 0/9
pre-change hygiene     [stage explicit paths]          = 0/9
pre-change disclosure  [silence is not compliance]     = 0/9
```

`AClit.c` is the **non-zero control for that zero**: it runs the same function over the
four measured-disqualified literals and requires all four to come back non-zero.

```
[worktree]=9  [git commit -a]=9  [worktree isolation]=8  [porcelain]=3
```

Without `AClit.c`, `AClit`'s four zeros would be a zero result about the probe rather than
about the literals. A literal at 9/9 would read GREEN with the rule delivered to zero
files; `worktree isolation` at 8/9 would redden for `qa.md`'s pre-existing wording, the
wrong reason. `AClit.d` additionally requires the four to be pairwise distinct, which AC6
and AC7 both demand and neither states as a checkable count.

If Dev re-chooses a literal and records it in `impl-report.json` under `chosen_literals`,
the battery picks it up automatically and re-runs the same admissibility gate against it.

## AC9: the ten-cell matrix, run in both topologies, all three spellings

Run from throwaway `git clone --no-hardlinks` stand-ins. **`AC9.iso` asserts the run
registered nothing against the real repository: worktree count 18 → 18, `git status
--porcelain` 0 → 0 lines, both unchanged.** Every worktree the battery registers is removed
and pruned; the convention under test has a measured compliance record of zero and this
battery does not add to it.

Topology is **asserted before any cell is judged** (`AC9.main.t`, `AC9.linked.t`):
`<dispatch>/.git` is a DIRECTORY in the main run and a FILE in the linked run.

```
main   --absolute-git-dir  ADMIT / ADMIT / REFUSE / ADMIT  / REFUSE   <- expected, PASS
main   --git-dir           ADMIT / REFUSE/ ADMIT  / REFUSE / REFUSE   <- THE BITE
main   --git-common-dir    ADMIT / REFUSE/ ADMIT  / REFUSE / REFUSE
linked --absolute-git-dir  ADMIT / ADMIT / REFUSE / REFUSE / REFUSE   <- expected, PASS
linked --git-dir           ADMIT / ADMIT / REFUSE / REFUSE / REFUSE   <- all five correct
linked --git-common-dir    REFUSE/ ADMIT / REFUSE / REFUSE / REFUSE   <- refuses cell 1
```

- **`AC9.bite`** — in a main checkout `--git-dir` falsely REFUSES a real
  `git clone --no-hardlinks` (`REFUSE(same gitdir)`, both print the relative `.git`) and
  falsely ADMITS a tracked subdirectory of the dispatch tree (`ADMIT(n=15)`), which is
  where `git commit -a` commits the DISPATCH tree. SecOps's conditional veto on the
  relative spelling is honoured by measurement.
- **`AC9.blind`** — asserted, not incidental: in the linked topology `--git-dir` produces
  all five correct verdicts. That is why two review rounds passed the wrong spelling, and
  why a criterion run only in the topology the pipeline actually dispatches into cannot
  fail. The main-checkout run is the one that decides.
- **`AC9.gcd`** — `--git-common-dir` REFUSES cell 1 in the linked topology, i.e. it would
  refuse `git worktree add --detach`, the primary mechanism the rule recommends.
- **`AC9.main.c3` / `AC9.linked.c3`** — cell 3 is proved TRACKED (`ls-files=15`) and a
  **named untracked control** in the same tree is shown refusing for the unrelated
  `ls-files count 0` reason. A run whose cell 3 refuses under `--git-dir` used an untracked
  directory and got the right answer for the wrong reason.
- **`AC9.main.i` / `AC9.linked.i`** — cell 4's topology split is PROVED, not asserted, by
  comparing the inode of `<absolute-git-dir>/index`: **different** in the main checkout
  (`279588419` vs `279592834`, so the tar copy is an independent repository and refusing it
  would refuse correct work) and **identical** in the linked worktree (`279609310`, so it
  shares the dispatch index, HEAD and branch and admitting it would admit the harm).

This independently reproduces the design's amended AC9 verdicts, including the
topology-conditional cell 4. Nothing in the amended criterion is unsatisfiable.

## Controls run (`--controls`): 5 fire, 1 survives as predicted

```
CONTROL FIRES     AC2.a frozen digest reddens when a line INSIDE the span is edited
CONTROL FIRES     AC2.b terminator uniqueness reddens on a second 'replicated verbatim'
CONTROL FIRES     AC1.a reddens when the forbidden shard-path sentence appears
CONTROL FIRES     AC1.b reddens when the pinned fallback-shards count moves off 1
CONTROL FIRES     AC5 equality: 9==9 green, then qa.md alone stripped -> 9==8 red
CONTROL SURVIVES  AC2.a digest is BLIND to an edit outside the frozen span  (expected)
```

Every mutation is planted on a **throwaway clone** and reverted with `git checkout --`
inside that clone; the working tree is never written to.

Two notes on why these are shaped the way they are.

**The AC5 control needed two steps.** AC5's equality is red TODAY (`0 == 9`), so "it
reddens when I break it" would have proved nothing about it. The control first plants the
literal into all nine files to drive the equality GREEN (`9 == 9`), then strips it from
`qa.md` alone and observes `9 == 8` — the exact 9-vs-8 case AC5 was rewritten to catch.

**One mutation is kept that must SURVIVE.** A battery in which every mutation reddens
cannot distinguish real coverage from a probe that reddens on any edit at all; "all red" is
a zero result about the instrument. The frozen-span digest must be BLIND to a line appended
at EOF, outside the span. It is. If that control ever starts firing, `AC2.a` has stopped
measuring the span and started measuring the file, and the cell is worthless.

Cells `AC7.sc`, `AC16.w1`, `AC16.w2`, `AC16.w3`, `AC11.f`, `AC14.o`, `AC10.b` and `AC12.x`
each carry their own inline control, because each asserts a zero or an absence:
- `AC7.sc` proves the proximity check refuses a dispersed clause and accepts a tight one —
  it DISCRIMINATES rather than merely firing.
- `AC16.w1`/`w2` prove each wrong spelling disagrees with the correct one, and `AC16.w3`
  proves they AGREE on the bare world-readable case, so they are wrong *somewhere* rather
  than probes that always disagree.
- `AC11.f`, `AC14.o`, `AC10.b` each run their matcher against a planted positive first, so
  the zero they report is not a zero about the matcher.
- `AC12.x` requires the `**Halves.**` probe to be reported INSIDE the frozen span before it
  will accept "0 changed lines inside the span".

## The contract is PASSABLE, and every leg BITES

A contract handed to Dev red is not yet known to be satisfiable, and its legs are not yet
known to be load-bearing; both questions look identical from the red side. So a **throwaway
reference implementation** was built from the locked `design.json` in a `git clone
--no-hardlinks` outside the repository, committed there, mutated, and then **destroyed**.
Nothing from it was committed to this branch and the clone no longer exists. The real
worktree is at `82b7d02` with `git status --porcelain` empty and nothing under
`plugins/pipeline/` touched.

**Passable:** against the reference implementation the battery reports
**`PASS=67  FAIL=0  SKIP=0`, exit 0.** So "green" is reachable, and reachable by exactly the
implementation the design specifies — nine byte-identical EOF blocks plus the two preamble
paragraphs inserted after the `order its file runs in` bullet and before `WRITE YOUR SHARD
FIRST`. Dev is not being sent after something nobody can satisfy.

**Every leg bites.** 11 mutations expected to die, all caught; 3 expected to survive, all
survived.

| # | Mutation | Cell | Verdict |
|---|---|---|---|
| M1 | block deleted from `qa.md` alone | `AC5` | CAUGHT (9==8) |
| M2 | one word changed in `dev.md`'s block only | `ACblk.1` | CAUGHT |
| M2b | *same* drift, against the three-way equality | `AC5` | SURVIVED (predicted) |
| M3 | block closes `replicated verbatim` instead of `copied byte-for-byte` | `AC2.b` | CAUGHT |
| M3b | *same*, against the digest cell | `AC2.a` | SURVIVED (predicted) |
| M4 | a line edited INSIDE the frozen span | `AC2.a` | CAUGHT |
| M5 | `--git-dir` shipped as the predicate | `AC9.obs` | CAUGHT |
| M6 | prose says staging PREVENTS the harm | `AC14.o` | CAUGHT |
| M7 | a disqualified literal (`worktree`) declared in `impl-report.json` | `AClit` | CAUGHT |
| M8 | a forbidden path (`scripts/`) touched | `AC11.f` | CAUGHT |
| M9 | preamble paragraph moved outside the preamble span | `AC12.s` | CAUGHT |
| M10 | R6's effect stated nowhere (the vacuous form) | `AC14.s` | CAUGHT (as VACUOUS) |
| M11 | unrelated comment appended to `ba.md` | `AC2.a` | SURVIVED (predicted) |

**M2b and M3b are the load-bearing survivors.** M2b proves the three-way equality CANNOT
see a one-word drift inside one copy — which is precisely why `ACblk.1` exists beside it, and
why "nine files contain the literal" is not the same claim as "nine files carry the same
block". M3b proves that swapping the closing phrase to `replicated verbatim` leaves **every
digest still agreeing** while breaking AC2's extraction terminator: the exact trap AC2 names,
reproduced. M11 is the blunt instrument check — a battery in which everything reddens is a
zero result about itself.

Three mutations initially read as ESCAPES. **All three were defects in the MUTATION script,
not gaps in the contract**, and each is worth recording because each produced a confident
wrong reading:

- **M2's substitution hit the wrong occurrence.** `the disagreement is the defect` appears in
  the FROZEN SPAN as well as in the new block, and `perl` without `/g` replaces the FIRST
  one — so the mutation edited the frozen span and was then graded against `ACblk.1`, which
  correctly ignored it. Re-run anchored on a phrase unique to the block: CAUGHT. The control
  `M2c` re-runs the original string against `AC2.a` and catches it there, and its
  landed-proof line prints the tell — `the disagreement is a variation, not a variation` —
  visible evidence the edit landed somewhere other than intended.
- **M6's mutation was never committed.** `AC14.o` reads the COMMITTED diff
  (`git diff BASE...HEAD`), which is right for Phase 4 and means a working-tree-only mutation
  is invisible to it. Committed: CAUGHT.
- **M10 was misclassified by my own oracle.** The cell went `PASS -> VACUOUS(=FAIL)`, which
  IS a failure; the oracle read field 1 and matched neither `PASS` nor `FAIL`. A verification
  oracle can be wrong in the direction that flatters you, and this one was wrong in the
  direction that alarmed. Re-classified: CAUGHT.

## Four harness defects this battery caught in itself, before Dev saw it

Recorded because each produced a plausible, wrong reading, and three of them read GREEN or
read like a real finding.

1. **`GROUPS` is a bash special variable.** `DIGSET=$(... | sort -u)` was originally
   `GROUPS=`. Assignment to `GROUPS` is silently ignored and `$GROUPS` expands to the
   primary gid — `20`, i.e. `staff` — so the digest cell compared a **group ID** against the
   frozen sha and reported `ten AGREEING digests, but 20 != 14b65c…`. It looked exactly like
   a real extraction-bounds finding. Renamed, and the script is now scanned for collisions
   with every bash special name.
2. **`stat` prints modes in OCTAL and `$(( ))` reads them as DECIMAL.** `$(( 755 % 8 ))` is
   `3`, non-zero, so the first location probe returned the **right verdict for
   `/private/tmp/sketchB-43` for the wrong reason**, and the wrong verdict for every
   mode-700 case (it REFUSED `$TMPDIR`). All modes are now parsed with `8#`.
3. **`grep -c` prints `0` and exits `1`.** Under `set -o pipefail` the idiom
   `grep -c … | tr -d ' ' || echo 0` emitted **two** zeros, and every integer comparison
   downstream failed with `integer expression expected`. Fixed by swallowing the status
   inside the group.
4. **A literal triple-backtick inside a double-quoted cell label** opened a command
   substitution and made the whole script unparseable at a line 20 lines away from the
   real cause.

There is also a fixture defect worth naming: the scratchpad-shaped AC16 case was first
built under `$SCRATCH`, which lives under `$TMPDIR` — itself mode 700 — so **every** path
under it admits and the leaf-only discrimination would have passed without discriminating
anything. The fixture is now built at `/private/tmp/verify19-anc-$$` (ancestor 700, leaf
755), under a world-traversable root, so the discrimination is real.

## Findings that belong to BA / Phase 4, not to Dev

**F1 — AC11 fails today on the orchestrator's own bookkeeping, not on Dev's work.**
`git diff --name-only origin/main...HEAD` at `82b7d02` already returns
`.pipeline/19/status.json`, a committed pipeline artifact that is **not** on the declared
editable surface. Read literally — "the diff is a subset of the declared editable surface" —
AC11 fails at the reviewed SHA before Dev writes a line, and it will keep failing because
every checkpoint commit adds more `.pipeline/19/*`. The battery carves `.pipeline/**` out of
the SUBSET half and still holds the FULL diff (bookkeeping included) to the FORBIDDEN-PATH
half, and says so at the definition. **A Phase 4 panelist grading AC11 literally will mark
it FAILED on `status.json`.** AC11 should state the carve-out explicitly.

**F2 — AC16's "admitting direction" example is ambiguous.** AC16 says a clause "decided on
the CONTAINING directory alone gets `~/.cache` wrong in the admitting direction". Measured,
a containing-directory-only clause looks at `~/.cache` (drwxr-xr-x) and REFUSES — that is
the *refusing* direction. The spelling that actually errs in the **admitting** direction on
`~/.cache` is a **blessed-directory allowlist**, which is what the rest of the criterion and
the shipped prose ("not a list of blessed directories") are arguing against. The battery
implements the allowlist as wrong-spelling 2 and records the discrimination; the criterion's
wording should be corrected to name the allowlist rather than the containing directory.

**F3 — AC8's `83/2` vs `85/0` numbers are asserted as string presence only.** `AC8.n1` and
`AC8.n2` check that the worked numbers appear in all nine contracts. The battery does **not**
re-derive them by running `test-config-doctor-surfaces.sh` inside a `tar --exclude .git`
copy, because doing so means executing the suite twice more per run on top of an already
~9-minute pass. AC8 says "a reader following the stated recipe lands on the stated numbers";
that re-derivation is Dev's to run and record in `impl-report.json`, and Phase 4 should
check it was actually run rather than transcribed from the design.

## Criteria I could not build a full cell for

- **AC4's "as a limitation rather than as a remedy"** and **AC14's "never overstated"** are
  irreducibly prose judgements. What is mechanized: `AC4.l` requires the literal
  `limitation of the boundary check` in the preamble; `AC14.o` requires **zero**
  case-insensitive `prevent` in the ADDED lines (with a planted-positive control, and
  reported VACUOUS if there are no added lines); `AC14.s` requires every sentence containing
  `stops nothing` to also carry the ship-event clause and the no-enforcement clause. A
  reviewer still has to read the paragraph. Named so nobody mistakes the green for a
  reading.
- **AC3's "taken in a checkout no sibling process can write to"** is not enforced by the
  battery, which runs the suites in the current worktree. The per-suite comparison is
  mechanized; the isolation clause is Dev's to satisfy and record. Worth stating plainly
  because it is this issue's own subject.
- **AC2's "one hash for all ten"** is verified, but there is **no digest test in the repo**
  and there will not be until #76. Nine byte-identical copies are held together by
  `ACblk.1` in this battery and by nothing else once this battery stops being run.
