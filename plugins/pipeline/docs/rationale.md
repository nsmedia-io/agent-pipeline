# Rationale and incident history for the /pipeline orchestrator

No prompt loads this file. It holds the measurement write-ups and incident histories that used to sit inline in `commands/pipeline.md`, moved here verbatim when that command was split into a core plus per-phase files (see `CHANGELOG.md`, Unreleased). Each section names the phase file whose one-line pointer leads here. The rules these paragraphs justify stay in the phase files; nothing here is an instruction a run acts on.

## Phase 0 step 0: why a missing pipeline.config.json halts

**Origin, and it is why this is a halt rather than a warning.** A session ran an entire pipeline end to end inside a worktree created before its project adopted this plugin. That tree carried the project's own retired, in-repo copy of the pipeline, so every phase dispatched, every gate ran, every gate PASSED, and Phase 5 silently no-opped: the knowledge writes went to a store nothing read. Nothing in the run looked wrong, because everything the run consulted was the stale copy answering consistently about itself. The absent config file is the one cheap, early signal that separates that tree from a configured one, and a warning printed into a report the run then scrolls past is exactly what did not stop it.

## Frontend probe: the late arrival on the three-outcome shape (#20)

The frontend probe is on the same three-outcome shape as the data-layer and infra ones, and it got there late: it shipped as `process.exit(m.diffTouchesFrontend(...)?0:1)` with no `.catch()` and no exit-status branch, four hundred lines below a paragraph in this file titled "Three outcomes, never two". A stale `${CLAUDE_PLUGIN_ROOT}` made it exit 1 with zero bytes on both streams, byte-identical to "no frontend file changed", and Design was dropped from a panel reviewing a frontend diff while `status.json` recorded a panel. That was issue #20; the seat now goes to the specialist on any exit that is not the reserved 20.

## Dispatch via Workflow: the two gating questions (#101 q4, q6)

This was gated on two questions (#101 q4, q6) before it could ship, both now resolved:

- **q4 (does the SecOps veto stay fail-closed?):** yes, by construction, not by a new check. Verdicts flow through shard files exactly as the Agent-tool dispatch did; the merge step is unchanged and was already fail-closed on a missing or verdictless shard before this migration existed. A `null` return from a dead or skipped Workflow agent produces no shard file, which is the existing `MISSING SHARD` halt, not a new code path.
- **q6 (does the runtime actually HONOR a `SubagentStop` block on a Workflow-dispatched agent, not just emit one?):** yes, confirmed empirically. A `pipeline:secops` agent dispatched via `Workflow`, instructed to write a deliberately invalid artifact and told not to self-correct, was blocked on **nine consecutive stop attempts**, every one carrying the identical `decision:"block"` reason from the real validator, independently confirmed both from the agent's own transcript and from a temporarily instrumented copy of the live hook. The block did not just fire; it genuinely prevented the turn from ending while the artifact stayed invalid. Full record in #101.

## Artifact sync: why the copy is split by ownership (#34)

**The split is by OWNERSHIP, not by first arrival.** The old form was a single `cp -n "$SRC"/*.json`, and its stated rationale -- that `spec.json`, `review.json` and `status.json` are authoritative and must not be overwritten by stale seeds -- was correct for exactly those three files and wrong for every other file the glob matched. `impl-report.json`, `map.json`, `tasks.json` and `peer-review.json` are written IN the worktree, and for them the canonical copy is the stale one. Measured on #34: the archive recorded an implementation report predating two rounds of fixes and a `map.json` token count the run had already corrected, while `status.json` was correctly taken from the canonical side. Do not collapse this back to one flag in either direction -- both directions are wrong for half the files.

## Fix it immediately: the incident

On the run above, two tracked files were instructing future agents to corrupt the production database.
Both were found mid-review and both were fixed in ten minutes as their own small PR. Filing them as
issues to be specced would have left live hazards in the tree for days.

## Mis-tier tripwire: the zsh path list

`zsh` does not word-split an unquoted parameter expansion, and zsh is what the orchestrator's own shell tool runs. The previous `... $CHANGED` therefore handed a MULTI-FILE diff to the predicate as ONE newline-joined argument; the surface globs compile to `.`-based regexes and `.` does not match a newline, so the predicate matched nothing and the tripwire proceeded silently. Measured on `{db/migrate/001_add_users.rb, src/app.ts}`: bash halted, zsh did not. A single-file diff was correct under both shells, which is why every one-path fixture in the suite passed while the control was inert. This file already warns about the same zsh behavior for `PANEL_ROLES`; a NUL-delimited list read on stdin removes the shell from the path entirely rather than adding a third warning.

## Mis-tier tripwire: git's exit status

`CHANGED="$(git ...)"` discarded it, and a bad `WORKTREE_PATH` or a missing `origin/main` ref yields `fatal: bad revision 'origin/main...HEAD'` on stderr with an EMPTY list on stdout: byte-identical to a clean diff. That failure appears in this repository's own CI log, so it is a live condition.

## review_rounds: the corpus measurement

On the committed corpus this was non-zero on 5 of 7 records in BOTH directions (+2 on #43, -2 on #56, +1 on #17 and #39 which never entered phase 4 at all), and the two it got right were both single-round runs, so hand-maintenance was reliable exactly where nothing depended on it.

## Render the Workflow script: origin (#157)

Origin: seven hand-written panel scripts over four issues produced one mistyped reviewed sha and one parse error.

## Artifact sync: the archive-time backstop

**Prose is not the enforcement.** The "run it twice" rule above is a rule for the orchestrator, and this repo has measured what a rule stated only in prose is worth. The enforcement is in `scripts/knowledge-store.mjs`: at archival, `archiveIssue` compares each worktree-produced artifact against the worktree's own copy when that worktree still exists, and REFUSES to write a stale archive. It abstains when the worktree is already gone, so it is a backstop and not a guarantee -- but the state it refuses is the state #34 actually shipped.

## Deferral ledger: the incident

This is not hypothetical: on one PR the same items were reported as "routed to #N" across three consecutive rounds by three different agents, and none of them had been written anywhere; it surfaced only because a reviewer checked the issue instead of the claim.

## Checkpoint checker: #117's second occurrence

, because the second occurrence in #117 was not a typo: a 33-char label was fixed by Dev in a worktree and then silently restored when a routine `cp` from the orchestrator's own stale copy overwrote the fixed file, and the clobber was committed. A check scoped to "the value I just wrote" passes that.

## Cost class: the measurement that motivated the axis

Measured on one consumer before this axis existed: a single tooling issue ran 21 spec revisions and 8 Phase 4 panel rounds with six reviewers, and produced 79 acceptance criteria, a 676-assertion prover and 35 follow-up issues. The tier alone could not tell that change from a payments migration.

## Phase 4 checkpoint: the stale verdict (#110)

That is not hypothetical and was not reasoned from the code: blob `d83bfc0` of `.pipeline/19/status.json` is `current_phase: "4-review"`, `final_verdict: "REQUEST_CHANGES"`, `review_rounds: 2`, caught mid-fix-round.

## Deferral checklist: the measurement

Before this, every note without a patch became its own tracker issue; measured on one consumer, one tooling issue produced 35 of them.

## Orphaned sub-agent processes (0.49.0)

**The incident (2026-10-02, the Rome project, the owner's Windows 11 host).** The owner saw about five `python` processes at 5-6% CPU each. Walking the parent chain showed every one started by ONE orchestrator session's sub-agents: `python.exe` <- `python3.exe` (the Windows Store alias) <- `bash.exe -c "source ~/.claude/shell-snapshots/snapshot-bash-....sh ... eval '...'"` <- `bash.exe` <- `claude.exe --resume=<session id>`. Each was a sub-agent Bash command of the form `python3 - <<'E' ... E` with a mangled or empty heredoc, and on Windows the python stub then spun reading stdin forever; the oldest had used 24.6 CPU-hours since the previous morning. Four more orphans were `until grep -q "^exit" <log>; do sleep 10; done` wait loops (60 to 80 CPU-minutes each) polling logs written by agents that had finished a day earlier. They share the host with the CI runners, Docker and the agents.

**The root cause is a class, not two commands.** A Bash command that runs past the tool's timeout is moved to the background and nothing reaps it; a sub-agent that finishes does not take its background commands with it. Anything that never terminates on its own (a wait on a condition nothing will ever make true, a program reading a stdin nobody feeds) becomes a process that lives until the machine restarts. So there are two lines of defence, because neither is complete alone: refuse the two constructs where they are written (`hooks/pre-tool-use.sh`, `scripts/runaway-commands.mjs`), and reap what still gets through (`scripts/reap-orphans.mjs`).

**Prevention is scoped to a SUBAGENT, and deliberately narrow.** It uses the same origin term as the staging gate (`agent_id`), so the owner's own interactive Bash is never refused by a plugin installed for every project. A wait loop is refused only when the whole structure is present (a loop keyword at command position, a `do`, a `sleep` in the body, a closing `done`) and no bound signal appears anywhere in it (`$SECONDS`, `date`, `timeout`, an arithmetic counter, a numeric comparison, `break`, `exit`, `return`, or a variable named like a retry or deadline). The bound test is generous on purpose: a data comparison such as `[ $(wc -l < f) -ge 10 ]` also passes, because a missed loop costs one orphan the reaper can still find, while a wrongly refused command costs an agent a retry on every run. A heredoc body that is not fed to a shell is data, so a script merely written to a file is not scanned. The python rule is Windows-only, because the stub is.

**The reaper chooses between certainty and silence, and it never guesses.** What it may kill is a closed list of two named patterns, each with its own evidence: a Windows `python` with no script argument (or just `-`), and a shell whose command line holds an unbounded wait loop whose polled file has not been written for `staleFileMinutes`. A loop waiting on a file that is still being written is waiting for a live writer, so it is reported and left alone; so is one whose file is missing, relative, or built from a variable. Whether the session is still waiting on a background task is read from the transcript, where a Bash task starts with a `backgroundTaskId` result and ends with a `<task-notification>` naming it: a task started and not finished, whose command text appears in the process's or an ancestor's command line, protects the process. The scan streams the file in chunks; the real Rome orchestrator transcript (142 MB, 200 background tasks started, 2009 notifications) scans in about 0.5 s (one run on the host above). If the main transcript cannot be read nothing is known, so the python stub, which has no evidence of its own, is only reported.

**Scope is the session's own process tree, found from the hook.** The hook is a descendant of the session's `claude` process, so the root is the nearest `claude` ancestor. On the owner's host the Desktop app's own `claude.exe` is the parent of every session's CLI `claude.exe`, and other sessions' vitest and turbo trees run beside this one, so "named claude" is not enough: the Desktop main process and Electron helpers (`--type=`) are never a root, and with no root nothing is touched. Parent links are trusted only when the parent started first, so a recycled Windows pid cannot pull a stranger into the tree. The decision is made on one process snapshot and confirmed on a second, matching pid and start time, immediately before the kill.

**Cost, measured on the same host (Windows 11, three runs each).** The Windows process table comes from CIM through PowerShell. `pwsh` 7 answered in 592, 452 and 604 ms; Windows PowerShell 5.1 in 1505, 1256 and 1254 ms; so `pwsh` is tried first. The reaper reads the table once per run when there is nothing to kill and twice when there is, and is throttled to once per `minIntervalMinutes` at SubagentStop and Stop (SessionStart always runs). On a loaded host node itself took 1.8 s to start, so most of a hook's wall time is that, not the reaper's own work.

**What the model sees.** Only SessionStart's stdout is injected into the model's context, so that is where the summary goes. SubagentStop and Stop have no model-visible channel on a normal exit, so the summary leaves as the hook's single `systemMessage` for the owner, and every kill is in `reaper.log` either way. The decision JSON from the artifact validator always wins over the summary: stdout carries one object.

**Turning it off.** `runawayCommandGuard: false` for the refusals; `orphanReaper.mode` `"off"` (or `"report"`), or `CLAUDE_PIPELINE_REAPER=off|report|kill` for one session, for the reaper. `CLAUDE_HOOK_PRETOOLUSE_SKIP=1` disarms the whole PreToolUse gate, the refusals included.
