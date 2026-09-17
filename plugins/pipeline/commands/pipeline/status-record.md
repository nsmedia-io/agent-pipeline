The `status.json` record and its checkpoint convention. `commands/pipeline.md` has you read this file on every run, fresh or resumed, before the record is first written or read.

Append an entry to `events` after each phase transition: `{"phase": "1-ba", "verdict": "<agent verdict>", "at": "<iso>"}`.

**The exit event for phase N and the entry checkpoint for phase N+1 are ONE write, in that order, committed together.** Appending the closing event first and checkpointing the next phase second are not two steps to be interleaved with anything, least of all with the end of a turn. The Stop hook fires at the turn boundary and a turn very commonly ends right after a checkpoint commit, so checkpointing first and appending later leaves a window in which the record says "entering 3-impl" with neither `design.json` (absent in a fresh checkout, because every artifact except `status.json` is gitignored) nor a closing 2.5 event. The phase-entry guard is CORRECT to refuse in that window -- the record is the only truth it has, and it genuinely does not show the phase closed -- so this convention, not a guard exemption, is what prevents the state.

**`events[]` entries are EXIT markers and `current_phase` is an ENTRY marker.** An event is appended AFTER a phase finishes and carries that phase's `verdict`, so it records a phase CLOSING; `current_phase` is set BEFORE a phase begins and names the phase being ENTERED. Two fields with opposite conventions five lines apart is the trap that made the telemetry credit every interval to the wrong phase, so the two are named here rather than left to be inferred.

**NO FREE-TEXT FIELD IN A COMMITTED PIPELINE ARTIFACT MAY CARRY A SECRET.** `status.json` reaches a public tree twice: it is the one `.pipeline/` artifact committed to git (see the durable-checkpoint convention below), and Phase 5 copies it **verbatim** into `knowledge/issue-archive/<n>.json`. Neither copy is rewritten afterwards, so a pasted secret persists in history and a fix-forward commit does not remove it. Before writing any of these five fields, redact any token-shaped substring (API key, Bearer token, OAuth code, password, DSN with inline credentials, `.env` line):

| field | why it is exposed |
|---|---|
| `ask_text` | a truncated, human-written task summary; the /pipeline argument is pasted by a human |
| `events[].note` | orchestrator prose, unbounded |
| `flags[].summary` | orchestrator prose, 140 chars |
| `veto_reason` | orchestrator prose, unbounded |
| `error` | **the sharpest case**: the natural content of an error field is COPIED MACHINE OUTPUT -- a failed `gh`/`curl` echoing a URL with a token, a DB connection error carrying a DSN, a stack trace |

**`status.json` IS NOT THE ONLY ARTIFACT THAT REACHES THAT TREE (#71).** It is the only one COMMITTED from `.pipeline/`, which is why the rule was written about it -- but `ARCHIVE_ARTIFACTS` in `scripts/knowledge-store.mjs` is seven names long, and Phase 5 folds every one of them into the same committed `knowledge/issue-archive/<n>.json`. `review.json` and `peer-review.json` are two of the seven, and their free-text fields are written by the reviewer subagents, not by you:

| field | why it is exposed |
|---|---|
| `concerns[].location` and `vulnerabilities[].location` | **the sharpest case on these two artifacts**, and the same shape as `error` above: a location is PASTED from a tool, so a DSN, a token-bearing URL or an `.env` line arrives without anyone deciding to write one. Measured: `/etc/app.env:12 DATABASE_PASSWORD=s3cr3t` archived with the leading path redacted and the secret standing |
| `concerns[].description`, `vulnerabilities[].description` | reviewer prose, unbounded, and routinely quoting copied machine output from a live reproduction |
| `notes`, `must_satisfy`, `remediation`, `rationale_not_checked` | reviewer prose, unbounded |
| `compliance_flags[].concern` and `.statute` | SecOps prose; the items subschema has no required list, so nothing else reads them either |
| `advisory_notes`, `knowledge_drift_claims[].evidence` | archived and declared in NO schema, so no field-level annotation reaches them at all |

**The instrument is CONTENT, not length.** Do not "solve" this by truncating. `events[].note` is deliberately unbounded and a 600-char note recording a live reproduction is correct work; `veto_reason` is a sentence by design; a reviewer `description` recording a real reproduction is the same. Capping them would destroy audit content to address a problem length was never the mechanism of. Redact the token and keep the sentence.

**YOU are the writer, so YOU are the control.** It is true that no code path copies provider tokens, Bearer tokens, OAuth codes, or database rows into `status.json` -- and it is beside the point, because every field above is written by the orchestrator or a reviewer subagent, which is not a code path. TWO MECHANISMS BACK YOU UP AND NEITHER REPLACES YOU. Both match enumerated credential SHAPES, so a secret spelled as prose ("the staging password is hunter2") passes both, which is why this rule is addressed to you and not to them. They also fail in opposite directions, and that decides your remedy:

- `scripts/knowledge-store.mjs` REFUSES the Phase 5 archive write when the assembled document carries a credential-shaped string, naming the json path and the class. That is PREVENTION: nothing is committed, and the archive simply does not appear. It walks the whole document built from `ARCHIVE_ARTIFACTS`, so it covers the undeclared fields above and any field added later. Override with `PIPELINE_ARCHIVE_ALLOW_CREDENTIAL_SHAPES=1` only for a hit you have hand-checked as a fake -- a planted DSN quoted inside a security report is the case that actually exists -- and say in the run record that you did.
- `tests/test-status-schema-contract.sh` runs a credential-shaped scan over the committed records and the archived copies. That is DETECTION AFTER THE FACT: by the time it reddens, the string is already in the branch's history. If it fires on something you just wrote, **amend the commit; do not fix forward.**
- `tests/test-archive-sidecar-scan.sh` runs the same shipped class table, line by line, over the `*.md` and `*.sh` SIDECARS committed beside the archives -- a QA battery record, a verify script. Nothing writes those files but you, and until #125 nothing read them either. Also DETECTION AFTER THE FACT, so the same remedy applies: **amend, do not fix forward.** It reports `<file>:<line> [<class>]` and never the matched text, because a scanner that echoes its hits into a CI log has moved the exposure rather than closed it. A hit you hand-check as a fake goes in that suite's allowlist by file, class and line digest.

**A BLANK REQUIRED FIELD IS THE OTHER HALF, AND IT FAILS IN THE OPPOSITE DIRECTION.** `""` satisfies every required free-text field on the review artifacts: a MISSING `must_satisfy` or `remediation` is refused where the validator runs, a present-but-EMPTY one is not, same actor and one keystroke cheaper. The Phase 5 archive write now REPORTS every required free-text field that is present but blank, naming it by json path, and prints the count with its denominator on the clean path too (`blank required free-text fields: 0 (of N present, from S/S artifact schemas)`). **It WARNS and archives anyway, deliberately**: by then the run is finished and the archive is its only durable copy, so refusing would destroy the record to punish a blank field -- the exact inversion of the credential guard, which refuses because shipping the secret IS the harm. If you see that warning, fill the field in the source artifact and archive again. Do not write `''` to clear a field you have nothing to say about, and do not "fix" the warning by deleting the key (#122).

### Durable checkpoint convention (resume reliability)

`status.json` is the `/pipeline --resume <issue>` checkpoint, so it must be durable, not a post-hoc log. **Write AND commit `status.json` BEFORE each phase transition begins, recording the phase being ENTERED**, not the phase just finished. Set `current_phase` to the phase about to run, then commit, then dispatch that phase. If the run is interrupted mid-phase, `--resume` reads the committed `current_phase` and re-enters that same phase from the top, never a stale prior one.

Commit the `status.json` checkpoints, but keep every other per-issue artifact (`spec.json`, `review.json`, `impl-report.json`, `peer-review.json`, and all `review.<role>.json`/`peer-review.<role>.json` shards) out of git, so checkpoint commits never drag transient intermediate state into history. The simplest setup is a `.gitignore` that ignores `.pipeline/` but re-includes `/.pipeline/*/status.json`; then a plain `git add .pipeline/<issue>/status.json` stages only the checkpoint (no `-f` needed, which would defeat the scoping). Use a consistent commit-message prefix so checkpoints are easy to spot and squash:

```bash
# Run BEFORE entering each phase, after setting current_phase to the phase being ENTERED.
# The checker refuses an over-cap events[]/flags[] verdict, and a recorded phase that fails the
# schema's pattern, BEFORE either reaches a commit. It takes no arguments, reads the cap and the
# pattern out of schemas/status.schema.json, and is silent when clean; a non-zero exit names the
# file, the json path and the value, and means fix the record.
node "${CLAUDE_PLUGIN_ROOT}/scripts/check-status-record.mjs"
git add .pipeline/<issue>/status.json
git commit -m "chore(pipeline): checkpoint phase <n> for #<issue>"
```

**Run that checker on every checkpoint, not only after you hand-edited a verdict.** It reads the FILE, not a diff, and takes no argument naming what you changed (#117's second occurrence, a fix silently overwritten by a stale `cp`, is in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md`). A check over the record's whole content cannot tell a keystroke from a `cp`, and does not need to.

Dependency note (do not widen the commit scope blindly): a checkpoint commit touches ONLY `.pipeline/<issue>/status.json`. This plugin now ships one such filter itself — the `PreToolUse(Bash)` gate in `hooks/pre-tool-use.sh`, which is the commit-triggered automation nearest to hand and refuses a SUBAGENT's blanket staging while a Phase 4 run is in flight — and your project may wire others (a `PostToolUse(Bash)` hook that fires on specific committed paths, say). A status-only checkpoint commit must match none of them: the two `git` commands above name their pathspec, so they do not, and that is what keeps the gate silent for the orchestrator. A future change that widens what a checkpoint commit stages (e.g. committing other artifacts, or reaching for `git add -A`) must re-check every such filter, or it can silently start firing that automation on every phase transition.

**Append to `flags` after each agent returns** so downstream phases (especially the Phase 4 panel) can start from a digest instead of re-reading the full artifact JSON. One entry per agent, one short line of free text:

```json
{"phase": "2-secops", "agent": "secops", "verdict": "APPROVE_WITH_NOTES", "summary": "auth path OK; PII filter on new logger call could be stricter", "at": "<iso>"}
```

Rules for `summary`:
- Strict 140-char cap; truncate with ellipsis if longer.
- Quote the agent's own concern, do not editorialize.
- Verdict-only ("APPROVE") agents still get an entry with `summary: ""`.

Rules for `verdict` (the same rule governs `events[].verdict`):
- A TOKEN, not prose: strict 32-char cap, matching the `maxLength` on both verdict fields in `schemas/status.schema.json`. Write the agent's verdict word and nothing else; the reasoning goes in `summary`. Nothing validates status.json against that schema automatically, so this restatement is one honorer and `node "${CLAUDE_PLUGIN_ROOT}/scripts/check-status-record.mjs"` is the other -- run it before every checkpoint commit, as the recipe above does. Prose alone was not enough: #117 records the cap being broken twice in one run, once by seven labels accumulating unnoticed across phases (longest 44) and once by a fix being overwritten by a stale copy.

When dispatching Phase 4 reviewer prompts (see `phase-4-panel.md`), include the line `Prior flags: see status.json flags array; the digest is authoritative for what earlier agents already raised.` This avoids each Phase 4 reviewer re-parsing review.json and impl-report.json from cold.

