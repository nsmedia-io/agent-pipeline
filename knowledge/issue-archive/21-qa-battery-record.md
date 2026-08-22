# QA Phase 3a battery record — issue #21

**Battery:** `.pipeline/21/verify-21.sh` (executable). **This is a COMMAND, not a CI gate.**
Nothing runs it automatically, nothing registers it, and `plugins/pipeline/tests/run.sh` does not
glob it. It lives in a gitignored artifact directory because this session may not create or modify
anything under `plugins/pipeline/tests/` — that directory belongs to a concurrent session and AC15
asserts the diff touches nothing outside the owned surface. So the strongest control available is a
command a human runs: strictly better than reviewer eyes, strictly weaker than a test.

**Run it:**

```
bash .pipeline/21/verify-21.sh                    # every cell
bash .pipeline/21/verify-21.sh --only 'AC4*'      # one cell or one glob
bash .pipeline/21/verify-21.sh --skip 'AC14*'     # defer the ~8-minute run.sh cell
bash .pipeline/21/verify-21.sh --controls         # the mutation battery
bash .pipeline/21/verify-21.sh --src <tree>       # content cells against another tree
```

Exit 0 only when every selected cell PASSes and **no cell SKIPs**. A skip is not a pass.
Re-runnable by anyone from a clean checkout in one command; it self-locates from `BASH_SOURCE`.

**Base:** worktree `/Users/brandonsmith/WebstormProjects/agent-pipeline/.claude/worktrees/lane-4-a521bf`,
branch `claude/lane-4-a521bf`, HEAD `d6b7998`, 0 behind `origin/main` (`13e40e9`), tree clean at both
ends of every measurement below. All mutations happened on `tar` copies under `$TMPDIR` or in a
`git clone` in the scratchpad; **the worktree was never written to and no `git checkout --` was ever
run in it.** No reference-implementation byte is committed anywhere.

---

## 1. Every cell, and its state at the base

`[base:RED]` = the implementation is absent so the cell must fail now; these are the contract.
`[base:GREEN]` = non-regression or instrument; a green here proves nothing about the new prose.
`[base:SKIP]` = needs a Phase 3 artifact; prints SKIP and keeps the exit non-zero.

### base:RED — the contract Dev drives green (28 cells)

| Cell | AC | What it reads |
|---|---|---|
| `AC1.floor-in-bullet` | 1 | the ONE physical line carrying `**architectural**, MANDATORY` contains `` `pipeline.config.json` `` |
| `AC1.four-inputs-pass` | 1 | the same check passes under all four live config inputs: **no file, `{}`, malformed, key omitted** |
| `AC2.mechanism` | 2 | duty 6 states `floor` **and** only-add / never-remove |
| `AC3.survives-strip` | 3 | after deleting every `# CUSTOMIZE:` line, a read duty naming `architecturalTriggers` survives |
| `AC4a.which-file` | 4 | `project root` |
| `AC4a.not-plugin-cache` | 4 | `never/not the plugin cache` |
| `AC4b.absent` | 4 | absent |
| `AC4c.unparseable` | 4 | fails to parse |
| `AC4d.not-a-json-object` | 4 | other than a JSON object |
| `AC4e.no-cite` | 4 | do not name the config as the source of a trigger not read there |
| `AC4f.resolves-to-floor` | 4 | `floor alone` / `treat it as {}` |
| `AC5a.trust-premise` | 5 | `checkCommand` **and** executed at every Stop |
| `AC5b.void-condition` | 5 | void ↔ writable/lower-trust, within one sentence |
| `AC8a.evaluators-named` | 8 | a section line naming evaluation **and** the orchestrator **and** BA |
| `AC8b.no-path-predicate` | 8 | `no path predicate evaluates a diff` |
| `AC8c.parenthetical` | 8 | the parenthetical **immediately after** the bold sentence, != the original, naming ba.md's built-in floor |
| `AC9a.names-the-path` | 9 | the post-BA validation clause names `pipeline.config.json` |
| `AC9b.floor-phrased` | 9 | that clause says floor/built-in and does **not** say "a configured path" |
| `AC10a.secops-siting` | 10a | the **extraction**, not the file |
| `AC10a.dev-presence` | 10a | dev.md carries the backstop |
| `AC10c.secops-label` | 10c | no `not a mechanism` / `unlike` / `the others` **in the backstop text** |
| `AC10c.dev-label` | 10c | same, per file |
| `AC11a.names-both` | 11 | the reader string names `ba.md` and `pipeline.md` |
| `AC11b.not-prose-only` | 11 | it is no longer `BA's tiering decision (prose, not code)` |
| `D1.dev-backstop-own-bullet` | design (5) | own bullet, not appended to the tripwire bullet |
| `D3.secops-directly-after` | GRAFT 2 | backstop is extraction-line `TRIPWIRE+1` |
| `D4.ba-marker-text` | GRAFT 1 | marker reads `(paths + domains + keywords)` |

*(`AC1.four-inputs-pass` is four measurements; `AC4*` is seven cells because AC4 forbids reading the
paragraph as one blob.)*

### base:GREEN — non-regression and instruments (25 cells)

`AC1.bullet-scoped`, `AC1.four-inputs-invariant`, `AC2.bare-ban`, `AC2.oracle`,
`AC3.strip-is-surgical`, `AC6.on-disk-input-is-live`, `AC7.worktree`, `AC7.origin-main`,
`AC7.oracle`, `AC7.telemetry-suite`, `AC10a.siting-oracle`, `AC10b.axes-5x5`,
`AC10b.naive-is-dead`, `AC10c.oracle`, `AC12.self-test-16`, `AC13a.no-bare-subkey`,
`AC13a.extractor-oracle`, `AC13b.surfaces-suite`, `AC14a.sha-reachability`,
`AC14b.per-suite-table`, `AC14c.contamination`, `AC15a.owned-surface`,
`AC15b.pipeline-md-hunks`, `AC15c.carveout-still-bites`, `AC16.ten-file-digest`,
`AC16.digest-oracle`, `AC17a.ba-floor`, `AC17b.pipeline-floor`, `AC17.oracle`, `D2.no-new-heading`.

**These are labelled non-regression on purpose. A green there proves nothing about the new prose.**

### base:SKIP (1 cell)

`AC6.matrix-recorded` — no `impl-report.json` yet. It prints SKIP and the battery exits non-zero.

---

## 2. The reference implementation: the contract is PASSABLE, and its legs BITE

A contract handed to Dev red is not yet known to be satisfiable, and its legs are not yet known to be
load-bearing; both look identical from the red side. So I built a minimal reference implementation of
the locked design **in `$TMPDIR` only**, ran the battery against it, ran the mutation battery against
it, and threw it away. **Nothing from it is committed and the worktree never held a byte of it.**

**Result: every one of the 28 base:RED cells went GREEN against the reference implementation.**
No criterion in this contract is unsatisfiable. That is the specific waste this step exists to
prevent — a contract nobody can satisfy costs Dev its entire pass before anyone notices.

Two cells reported red against it, and **both were bugs in my own instruments, not in the prose**
(section 5). Two more reported red and were **environment artefacts I then falsified** (section 3).

---

## 3. The finding that matters most to Dev: the locked design costs ZERO on the frozen suites

The design claims the parenthetical rewrite and the `config-doctor` reader-string edit are free
against `test-pipeline-telemetry.sh` and `test-config-doctor-surfaces.sh`. **Checked, and it holds —
but the first measurement said otherwise and the first measurement was wrong.**

Running the two suites against a bare `tar` copy of the reference implementation read
`98 passed / 8 failed` and `83 passed / 2 failed`. That looked like a real cost. It is not:

| environment | telemetry | surfaces |
|---|---|---|
| isolated copy, **UNMODIFIED** tree | **98 / 8** | **83 / 2** |
| isolated copy, reference implementation | 98 / 8 | 83 / 2 |
| worktree (real checkout), unmodified | **107 / 0** | **85 / 0** |
| `git clone` + real `.pipeline/` corpus, unmodified | **107 / 0** | **85 / 0** |
| `git clone` + real corpus, **reference implementation** | **107 / 0** | **85 / 0** |

The reds are the *runner*, not the diff: `test-config-doctor-surfaces.sh` **diagnoses the source root
as a git project**, and `test-pipeline-telemetry.sh` **walks the real `.pipeline/` corpus**. A `tar`
copy has neither, so their own vacuity controls fire ("the real corpus is non-empty (a zero over an
empty corpus proves nothing)"). The unmodified row is the control that settles it, and without that
row I would have shipped a false finding against the locked design.

`verify-21.sh` now refuses to run those three cells against a source root that is not a real checkout
(`src_is_real_checkout`), reporting a loud SKIP rather than a red.

**Full `run.sh`, both sides, in real checkouts:**

| | suites | passed | failed | exit |
|---|---|---|---|---|
| worktree at `d6b7998`, unmodified | 34 | **2561** | 0 | 0 |
| clone at `d6b7998` + reference implementation | 34 | **2561** | 0 | 0 |

`diff` of the two per-suite tables: **identical, suite by suite.** The 60ad335 reference table in
`spec.measured_state` still holds at `d6b7998` with `test-gate-phase-entry.sh` at 493, and the locked
design moves no suite. `node config-doctor.mjs --self-test` reads `16 passed, 0 failed` on both sides.

---

## 4. The mutation battery: 14 caught, 3 expected survivors

Run with `bash .pipeline/21/verify-21.sh --src <reference-impl> --controls`. Each mutation lands on
its **own fresh copy**, which is then deleted; a copy is never "restored" by re-typing from context
and `git checkout` is never run in the worktree.

| control | mutation | cell that must redden | result |
|---|---|---|---|
| `CTRL.AC1.delete-literal` | delete the path literal from the contract list | `AC1.floor-in-bullet` | caught |
| `CTRL.AC2.bare-analogy` | say the bare `migrationGlobs` unions | `AC2.bare-ban` | caught (0 → 1) |
| `CTRL.AC3.marker-on-paragraph` | **Sketch B verbatim**: put `# CUSTOMIZE:` at the end of the read-duty paragraph | `AC3.survives-strip` | caught (1 → 0) |
| `CTRL.AC4.outside-duty6` | move the read duty out of duty 6 into the file body | `AC4b.absent` | caught |
| `CTRL.AC5.outside-duty6` | same | `AC5a.trust-premise` | caught |
| `CTRL.AC7.reword-always` | `always` → `normally` | `AC7.worktree` | caught (1 → 0) |
| `CTRL.AC8b.delete-that-half` | delete ONLY the no-path-predicate sentence | `AC8b.no-path-predicate` | caught |
| `CTRL.AC8c.restore-paren` | restore the original parenthetical | `AC8c.parenthetical` | caught |
| `CTRL.AC9b.configured-path` | reword to "a path configured in `architecturalTriggers.paths`" | `AC9b.floor-phrased` | caught |
| `CTRL.AC10a.move-outside` | **move** the backstop past the END marker | `AC10a.secops-siting` | caught (extraction 0, file 1) |
| `CTRL.AC10c.contrast` | inject "a norm, not a mechanism, unlike the rules above" | `AC10c.secops-label` | caught |
| `CTRL.AC13.bare-token` | append a bare `` `domains` `` to pipeline.md | `AC13a.no-bare-subkey` | caught |
| `CTRL.AC16.edit-span` | one-character edit inside dba.md's span | `AC16.ten-file-digest` | caught |
| `CTRL.AC17.drop-data` | delete `data` from ba.md's floor | `AC17a.ba-floor` | caught |

### The three mutations kept because they must SURVIVE

A battery where everything reddens cannot distinguish real coverage from a harness that reddens
indiscriminately. "All red" is a zero result about the instrument. So three mutations are documented
as **expected survivors**, each with its reason:

1. **`CTRL.AC8c.restore-paren` must leave `AC7.worktree` GREEN.** The bold sentence is byte-identical
   either way. This is exactly why AC7 and AC8c are separate criteria, and it is the one reading that
   proves the parenthetical is genuinely unpinned. **Survived, as expected.**
2. **`CTRL.AC3.marker-on-paragraph` must leave `AC1.floor-in-bullet` GREEN.** GRAFT 1 moves the
   *duty*, not the *floor literal*; the contract list is untouched by that mutation. **Survived, as
   expected.**
3. **`CTRL.AC8b.delete-that-half` must leave `AC8a.evaluators-named` GREEN.** AC8 demands the two
   halves be separately mutable, and a mutation that takes both cannot discriminate. **Survived, as
   expected.**

If any of these three ever *dies*, the mutation is not the one I meant and the pair of criteria it
spans is not independent. Investigate before treating it as coverage.

---

## 5. Two instrument bugs I found by running the reference implementation, and one by reading a detail

These are recorded because each produced *the answer I was hoping for* in one state and a false one
in the other, which is the failure mode a battery cannot self-report.

1. **`AC1.bullet-scoped` and `AC10a.siting-oracle` only worked at the base.** Both mutators
   *appended* text (the path literal outside the bullet; the backstop outside the markers). At the
   base that discriminates. Against a correct implementation it is a no-op, because the bullet
   already carries the literal and the span already carries the backstop — so both instruments
   reported `INSTRUMENT BROKEN` / a false red against a correct tree. **An instrument that only works
   in one of the two states it exists to distinguish is not an instrument.** Both now *remove* the
   real thing first, and both were re-run in both states: PASS at the base, PASS against the
   reference implementation.
2. **`CTRL.AC10a.move-outside` was a DELETE wearing a MOVE's name.** It used one
   `perl -ni -e '... END { print $h }'`, and perl closes the in-place redirect *before* `END` runs, so
   the saved line went to the terminal instead of the file. The cell reddened — for the wrong reason.
   The tell was in the cell's own printed detail: `whole file: 0`, where a genuine move must leave it
   at 1. Now two explicit passes; it reads `extraction 0 / whole file 1`.
3. **`CTRL.AC10c.contrast` "survived", and the coverage hole was in my mutator.** A bare
   `s/(mis-tier)/…/` over secops.md landed on line 54's unrelated `mis-tier` and never touched the
   backstop at line 122, leaving the cell correctly clean. Now scoped to the backstop line.
4. **`doctor_reader` read three INFO lines as part of the reader string.** Passing config-doctor's own
   path as `argv[1]` makes its `isMain(import.meta.url)` true, so the import ran the whole diagnosis
   and prepended its output. The tell: **`AC11b.not-prose-only` PASSED at a base where it must fail**,
   because the polluted string was `!=` the literal. The path now goes in the environment.

---

## 6. Criteria I could NOT build a full cell for, and exactly how far the battery gets

Printed by the battery every run under `MANUAL`, so no reader can take a zero exit as covering them.

- **AC1's actual criterion is a READING** — "a reader who has only `agents/ba.md`, in a project with
  no `pipeline.config.json`, tiers an ask that edits that file as architectural". The battery proves
  the mechanical half and proves it is **file-independent**: `AC1.four-inputs-invariant` runs the same
  check against four copies (no config file / `{}` / malformed / key omitted) and requires all four to
  agree with the unmutated result. Whether a reader *acts* on it is not mechanically checkable.
- **AC2's mechanism cell is a keyword check** over duty 6 (`floor` + only-add/never-remove). It cannot
  tell a correct widen-only sentence from a confused one. Its companion, `AC2.bare-ban`, is
  **vacuous at the base** and the cell says so in its own output: the analogy is absent from ba.md, so
  the word-bounded zero has nothing to discriminate until Dev writes the analogy. The *oracle* is
  asserted every run on two fixed strings, including the one that matters — the plain substring form
  returns 1 on the compliant `migrationGlobsForTripwire` sentence, i.e. **it refuses the exact text
  R2(a) mandates**, which is why the ban is word-bounded.
- **AC4 / AC5 are regex presence checks per clause.** Seven and two cells respectively, mutated
  separately as AC4 requires. They prove nine distinct things were said; they cannot judge whether
  each says the right thing.
- **AC6's twelve cells are applied BY A READER** to the rule as written — there is nothing executable
  to run them against. The battery audits the record (`AC6.matrix-recorded`: all twelve row/column
  labels present, both verbatim inputs present) and separately **re-reads the live config**
  (`AC6.on-disk-input-is-live`: `domains=["security","compliance"]`, `paths=["pipeline.config.json"]`)
  so a stale hand-copy in `impl-report.json` fails loudly instead of passing confidently about a world
  that has moved. It does **not** check that each recorded outcome is a correct superset.
- **AC10(c)'s ban is three strings.** A contrastive construction spelled any other way ("the rules
  above are enforced") passes the cell and fails the criterion. The battery does assert the
  word-boundary, because `unlikely` contains `unlike` and a plain ban would refuse compliant text —
  the same substring trap AC2 names.
- **AC11 wants the file *and section*** each evaluator lives in. The cell checks the two filenames.
- **AC15b is vacuous at the base** (0 hunks) and prints that it is. It becomes load-bearing only once
  Dev's diff exists; read it beside `AC15a`.
- **The `# CUSTOMIZE:` residual is deliberately NOT a cell.** Under the locked design the marker stays
  on ba.md's mandatory-trigger line, so a CUSTOMIZE-line strip takes the **floor literal** to 0 even
  though AC3's read duty survives. That is `design.json` residual risk #1 with #76 as its seat, not a
  defect for the battery to report. Do not "fix" it by moving the marker: measured minority
  convention, 6 of 79, rejected in design.

---

## 7. AC14's execution condition, built in

AC14 requires the suite pass be taken either in a checkout no sibling thread can write to, or with
`git status --short` sampled across the **full** run window at a cadence well under a minute, samples
recorded — because a before/after pair cannot distinguish *never contaminated* from *contaminated
inside the window*. This is live: a concurrent process mutated a file in this worktree mid-measurement
during Phase 2 and self-restored within about a minute.

`chk_ac14_contamination` forks a sampler that appends `epoch<TAB>git status --short` every 15 s for
the whole `run.sh` window, then asserts: at least 3 samples, **max inter-sample gap < 60 s**, and no
path dirty in *any* sample once `.pipeline/` is excluded. `.pipeline/` is the only carve-out and it is
named explicitly, matching AC15: `.pipeline/<issue>/status.json` is the one tracked path there and the
**orchestrator** writes it at every checkpoint. Dev must copy this cell's output into
`impl-report.json`; a before/after pair does not satisfy AC14.

`AC15c.carveout-still-bites` is the companion that stops the carve-out from blinding the check: the
same command with the same exclusion over `7a052d3^...7a052d3` still reports **13 unowned paths**.

---

## 8. Notes for Dev

- The battery is the target. `bash .pipeline/21/verify-21.sh` exits 0 only when all 28 red cells are
  green, no non-regression cell has moved, and `impl-report.json` carries AC6's matrix.
- **Do not put a `# CUSTOMIZE:` marker anywhere in the new ba.md paragraph.** ba.md writes every
  paragraph as one physical line; the marker makes AC3's strip delete the whole read duty. That is
  Sketch B's measured defect and `CTRL.AC3.marker-on-paragraph` plants it.
- **Do not touch any of the five secops TRIPWIRE axis strings.** `webhook-verification` is hyphenated
  and the hyphen is the whole discrimination: with the axis deleted, a case-insensitive `webhook`
  check still reads 1 and reports PASS. `AC10b.axes-5x5` runs all 25 outcomes every run;
  `AC10b.naive-is-dead` prints the numbers that make it a reading.
- **The bold sentence in pipeline.md must not change by one byte.** The parenthetical after it must.
- **No bare backticked `paths` / `domains` / `keywords`** in `commands/pipeline.md` or
  `plugins/pipeline/README.md`. The dotted `architecturalTriggers.paths` and the bare
  `architecturalTriggers` are the two deliberate survivors.
- **No new `##` / `###` heading anywhere in the diff** (`D2.no-new-heading`); that is what keeps
  AC16's awk-bounded extraction unambiguous across all **ten** files. Re-hash all ten, not three:
  four of the five edited files (`ba.md`, `dev.md`, `secops.md`, `commands/pipeline.md`) carry the
  span; only `config-doctor.mjs` does not. Verified again at `d6b7998`: ten files, all
  `14b65c48479dfceefb780689adccfbd53656b21e`.

---

## 9. The two runs, as measured (2026-08-22, HEAD `d6b7998`)

### At the base — the contract, red for the right reason

`bash .pipeline/21/verify-21.sh` → **exit 1. PASS 30, FAIL 27, SKIP 1** (58 cells).

- **All 27 failures are `[base:RED]` cells.** Every one names the absent prose, not a broken harness.
- **Zero `[base:GREEN]` cells failed.** That is the reading that makes the 27 reds a contract rather
  than noise: the instruments, the non-regression suites and the digest all hold at the base.
- The one SKIP is `AC6.matrix-recorded`, and it keeps the exit non-zero.

`AC14` at the base, measured in this worktree with the sampler live:

```
AC14a  reachability of 60ad335 and HEAD: both exit 0
AC14b  run.sh exit=0, suites=34 (ref 34), total passed=2561 (ref 2561), per-suite deltas: {}
AC14c  43 samples over a 632s window, max gap 16s, dirty paths outside .pipeline/: {}
```

So the `60ad335` reference table in `spec.measured_state` still holds exactly at `d6b7998`, including
`test-gate-phase-entry.sh` at 493, and the window was clean at a 16-second cadence rather than at two
endpoints.

### Against the reference implementation — the contract, green and passable

`bash <clone>/.pipeline/21/verify-21.sh --skip 'AC14*'` in a real `git clone` carrying the locked
design → **PASS 54, FAIL 0**, skips only `AC6.matrix-recorded` (no impl-report) and the three
deferred `AC14*`. That includes `AC7.telemetry-suite` at **107/0** and `AC13b.surfaces-suite` at
**85/0**, the two cells that read falsely red in an isolated copy.

`AC14` against the reference implementation was measured separately, in the same clone:
**34 suites, 2561 passed, 0 failed, exit 0, per-suite table identical to the unmodified worktree.**

**Every one of the 28 base:RED cells is satisfiable, and no non-regression cell moves under a correct
implementation.** The reference implementation was then discarded; nothing from it is committed.

---

## 10. `AC15b` repaired — the cell that crashed the battery (2026-08-22, HEAD `3722934`)

Dev's diagnosis was correct in every particular and its refusal to edit the battery was right. Its
hand-check of the criterion was also sound. The cell is mine and it was broken; here is the repair.

### What was wrong

`chk_ac15_hunks` collapsed each hunk header with `sed` and then split it with an **unquoted
`set -- $a`**. git omits the `,count` when a hunk is exactly one line, so the optional groups became
empty strings, **word splitting deleted them**, and the positionals shifted. Under `set -uo pipefail`
the unbound `$3` terminated the whole script at AC15 — so **AC16, AC17 and the four D cells never ran
at all.** The defect is a function of hunk **shape**, not diff **content**, which is why it survived
my reference run: that run was taken with the reference implementation uncommitted, so the cell saw
zero hunks and reported itself vacuous. **A cell that has never seen a real hunk has never been
evaluated in either direction.** The locked design puts all four `pipeline.md` edits on one physical
line, which git can only render as `@@ -125 +125 @@` — the crashing shape.

### What I changed

Not Dev's sentinel patch. That fixes the four shapes but keeps the positional splitting and, more
importantly, still has **no branch for a header it cannot read** — a combined-diff `@@@` header from a
merge would have flowed into an integer comparison as the literal string `@@@`.

1. **`parse_hunk`**, an isolated function using `[[ =~ ]]` + `BASH_REMATCH` with the counts defaulted
   explicitly (`${BASH_REMATCH[3]:-1}`). **No positional splitting anywhere.** Verified on bash
   3.2.57, which is what actually runs the battery.
2. **An explicit UNPARSED branch.** A header the parser cannot read is recorded as
   `UNPARSED[<header>]` and **fails the cell**. It is never a silent skip.
3. **`AC15b.parser-oracle`, a new cell.** The parser is now an oracle, so it gets its own control,
   **asserted every run rather than printed**: four shapes it must read with their exact expected
   readings, and two it must **refuse**. Deliberately not all-positive — an oracle that accepts
   everything is not an oracle.

   | header | required reading |
   |---|---|
   | `@@ -125,2 +125,3 @@` | `125 2 125 3` |
   | `@@ -126,0 +127,1 @@` | `126 0 127 1` |
   | `@@ -125 +125,3 @@` | `125 1 125 3` |
   | `@@ -125 +125 @@` | `125 1 125 1` ← **the shape that killed the draft** |
   | `@@@ -1,2 -1,2 +1,3 @@@` | must REFUSE |
   | `not a hunk header at all` | must REFUSE |

4. **The vacuity is now checked instead of confessed.** The old cell printed "with 0 hunks this cell
   says nothing" and passed anyway. It now cross-checks `git diff --name-only`: if git lists
   `commands/pipeline.md` as changed while the hunk walk reads zero, that is
   `CONTRADICTION[file-changed-but-the-hunk-walk-saw-none]` and the cell **fails**. A clean sweep of
   an empty set is not a pass.

### Both directions, measured

Green on the real diff, and **non-vacuously** — it names the hunk count it actually range-checked:

```
PASS AC15b.pipeline-md-hunks  section range: old 113-126 (at d6b7998), new 113-126 (at HEAD).
                              1 hunk(s), file-in-diff=1; outside the section: {}.
                              NON-VACUOUS: the walk read 1 hunk(s) and range-checked each one.
```

Red on planted defects, in a throwaway clone, each committed then `reset --hard` away:

| control | planted | rendered shape | cell |
|---|---|---|---|
| **A** | one-line replacement at line 200, **outside** the section | `@@ -200 +200 @@` ← **the crashing shape** | **FAIL** `old@200,1 new@200,1` |
| **B** | two-line replacement at 200-201, outside | `@@ -200,2 +200,2 @@` | **FAIL** `old@200,2 new@200,2` |
| **C** | pure insertion after 200, outside | `@@ -200,0 +201 @@` | **FAIL** `new@201,1` |
| **D** | one-line edit at line 120, **inside** the section | `@@ -120 +120 @@` | **PASS** |
| **E** *(synthetic baseline only, NOT this diff)* | mode-only change (`chmod +x`) **as the sole difference from the baseline** | *(none)* | **FAIL** `CONTRADICTION[...]` |

**D is the control that makes the other four a reading.** A cell that reddened on any hunk at all
would have failed D; it passes, so the cell is checking the **range**, not merely hunk presence.
C exercises the zero-count branch *and* the omitted-count branch in one header.

**E is a property of the cell against a synthetic baseline, not a property of it on this diff, and
the row above now says so in the row rather than only in this paragraph.** QA re-measured it at
Phase 4 against the REAL diff: `chmod +x plugins/pipeline/commands/pipeline.md` on top of `186f517`
leaves the real content hunk at line 125 in the diff, so the walk reads n=1, the contradiction
branch is unreachable, and the cell correctly **PASSES**. Anyone re-running E on this branch will
see a PASS and should: reaching the FAIL requires a baseline where the mode change is the only
difference, which is how E was originally taken.

### Sweep: does the same bug exist elsewhere?

I classified **all 18 git invocations** in the battery. **One instance of the bug class, and it was
the one that fired.** The rest:

- **Exit-code only** (`cat-file -e`, `merge-base --is-ancestor`, `rev-parse` existence) — no parsing.
- **Counts** (`grep -c`, `grep -cE`) — no field extraction.
- **Line-based** (`diff --name-only`) — quoted throughout; a path with spaces reports as outside the
  owned surface, which is the **fail-loud** direction.
- **Fixed-arity** (`grep -n … | cut -d: -f1`) — grep's first field is always the line number.
- **`git status --short`** (the AC14c sampler) — parsed with a fixed-width porcelain prefix, not by
  arity. A rename (`R old -> new`) or a quoted path would be reported as a dirty path, i.e. **fail
  loud**, so it cannot hide contamination. Recorded rather than changed: it is green and correct in
  the direction that matters, and churning a passing safety cell buys less than it risks.

The nearest relatives are therefore fail-loud or fixed-arity. `parse_hunk` was the only variable-arity
positional parse of git output in the battery.

---

## 11. Phase 3a verdict on the implementation

**APPROVE** as the Phase 3a hand-off. *(This is the hand-off verdict against the contract, not the
binding Phase 4 panel verdict, which is rendered later against the finished diff with fresh eyes.)*

Battery whole, against HEAD `3722934`: **PASS 59 / FAIL 0 / SKIP 0, exit 0** (58 original cells plus
`AC15b.parser-oracle`). All 28 base:RED contract cells green; **no base:GREEN cell moved**; `AC6.matrix-recorded`
now passes on Dev's recorded matrix. `--controls` independently re-run by me against the **shipped
text**: **14 caught / 0 missed**, all three documented survivors surviving. Dev's own control run is
the stronger evidence and it agrees.

Non-regression, re-measured at HEAD: `run.sh` **34 suites / 2561 passed / 0 failed / exit 0, zero
per-suite deltas** against the `60ad335` table — the diff moves no suite. AC14c sampled the window at
**35 samples / 512 s / max gap 16 s**, no path dirty outside the `.pipeline/` carve-out.

### Two of those 59 greens do not discriminate (found at Phase 4, on the shipped text)

**Read the 59/0 line above with these two subtractions.** Both were found by QA in Phase 4 by
mutating the SHIPPED text, both are in this battery rather than in the diff, and neither changes a
shipped byte. Neither is fixed: `verify-21.sh` is gitignored, unregistered and un-globbed, so the
cost of the gap is to this archive and to the #76 implementer, not to the plugin.

| gap | mutation applied | cell reported | why it does not discriminate |
|---|---|---|---|
| **C1** `AC8a.evaluators-named` | AC8's FIRST half deleted: the shipped two-evaluator sentence replaced with a one-evaluator sentence naming only the orchestrator | **PASS** (`lines naming evaluation=1, of which lines also naming the orchestrator=1`) | line-granular over a file whose paragraphs are ONE physical line: `BA` and `orchestrator` both survive elsewhere on line 125 (`after BA returns`, `if BA under-tiered`, `validated by the orchestrator`), so the cell reads the paragraph, not the clause |
| **C2** `AC6.matrix-recorded` | all three `config narrower` rows deleted from `impl-report.json`'s `ac6_matrix`, the other nine left | **PASS** (`missing row/col labels ={}; verbatim inputs found=2/2`) | row and column labels are grepped INDEPENDENTLY over the whole flattened report, never as `(row, col)` PAIRS inside `ac6_matrix.cells`; only `wider` was ever unique to the matrix |

**C2 deletes the one cell AC6 itself names as mandatory** (`config narrower` x `domains`, the cell with
a live input, the one that closes SecOps B2). The recorded matrix on disk is NOT defective — QA read
all twelve cells and `narrower x domains` resolves to `[data, security, compliance]` from this repo's
real 2-entry config, which is the correct outcome. This is the instrument, not the record's content.

**What a repaired cell must satisfy** (QA's wording, carried verbatim so a later fix is graded against
the property and not against a shape):

- **C1** — AC8's first half is checked on the evaluator SENTENCE rather than on the physical line: a
  check whose subject is the text between `Two things evaluate this rule today` and the next sentence
  terminator, which fails when the BA evaluator is removed from that sentence while the rest of the
  line is untouched, and fails independently when the orchestrator evaluator is removed instead.
  Demonstrate both directions with the two mutations, and keep a third mutation that must SURVIVE
  (removing `after BA returns` elsewhere on the line must not redden it), or the new cell is
  line-granular again in the other direction.
- **C2** — the cell fails when ANY ONE of the twelve `(row, col)` pairs is absent from
  `ac6_matrix.cells`, checked as a pair inside that array rather than as words anywhere in the file,
  and demonstrated by deleting exactly one cell — `narrower x domains` — and watching it redden while
  the other eleven remain. AC6's superset-or-equal outcome per cell remains a human reading and must
  keep saying so.

### The one thing I will not let the record call covered

Dev flagged that `ba.md`'s floor literal is now load-bearing with nothing pinning it. **My battery
does not cover that, and AC17 is not coverage of it.** Said plainly:

- **AC17 pins the DOMAINS enumeration** (`data`/`security`/`compliance`). The newly load-bearing thing
  is the **PATH literal** on the same line. Different literal, different criterion. Reading AC17 as
  coverage of the path floor is a category error.
- **`AC1.floor-in-bullet` evaluates the path literal, but it pins nothing**, because `verify-21.sh` is
  a command nobody runs. It is not registered, not globbed by `run.sh`, and lives in a gitignored
  directory. It catches an edit only if a human chooses to run it.
- **Measured, and it is worse than Dev stated.** Same method, same directory, with a non-zero control:

  | probe under `plugins/pipeline/tests/` | files |
  |---|---|
  | `architectural, MANDATORY` | **0** |
  | the mandatory-bullet path clause | **0** |
  | **any reference to `agents/ba.md` at all** | **0** |
  | `built-in floor` (the new parenthetical) | **0** |
  | `mandatory trigger list` | **0** |
  | `is architectural, always` — **non-zero control** | **1** (`test-pipeline-telemetry.sh:917`) |

  The control fires, so the method finds pinned prose where pinned prose exists. **No test file reads
  `agents/ba.md` at all** — it is not merely the literal that is unpinned, it is the whole file.

So the chain now reads: a **pinned** bold sentence ("always") → an **unpinned** parenthetical → an
**unpinned** literal in a file **no test opens**. One mechanical pin now depends for its honesty on
two unpinned links. This is a **ratchet, not a gap** — only a future edit can defeat it, no live input
can — so it does not block the hand-off, and #76 is the correct seat. But it must be carried into
Phase 4 as an open exposure with its number, not filed as covered.

### Second flag, now closed

`AC15b` did go from vacuous to unrunnable rather than to passing, and Dev was right that the criterion
had then never been mechanically evaluated in either direction. **That is no longer true**: it is now
green non-vacuously on the real diff and red on five distinct planted defects, including the exact
shape that crashed it. The hand-check is no longer the only record.
