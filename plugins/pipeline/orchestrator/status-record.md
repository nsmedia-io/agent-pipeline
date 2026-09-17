The `status.json` record and its checkpoint convention. `commands/pipeline.md` has you read this file on every run, fresh or resumed, before the record is first written or read.

**`events[]` entries are EXIT markers and `current_phase` is an ENTRY marker, and the exit event for the phase closing and the entry checkpoint for the phase opening are ONE write.** `scripts/checkpoint.mjs` makes them one, atomically and in that order. Do not hand-edit `current_phase`, `events[]`, `review_rounds`, `fix_rounds`, `spec_revisions`, `final_verdict` or `telemetry`; what the script does on each write, and why, is in its header.

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

`status.json` is the `/pipeline --resume <issue>` checkpoint, committed BEFORE each phase begins and naming the phase being ENTERED, so an interrupted run re-enters that same phase from the top. The checkpoint at the top of every phase file is this command, run before that phase's dispatch:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.mjs" enter <phase> --status "$PIPELINE_BASE/<issue>/status.json" --exit-verdict <verdict token of the phase closing> --commit
```

Add `--note "<note>"` for the exit event's note, and `--loopback` on a loop back (`loop-backs.md`). Exit 0 written and committed. Exit 2 REFUSED with nothing written: the phase fails the schema pattern, a verdict is over the schema cap, a round is past its budget, or the record would fail `check-status-record.mjs`; fix the input, do not hand-edit around it. Exit 1: an unreadable record, or a write that could not be committed (the message says which). The commit stages ONLY that `status.json`, so it matches no commit-triggered automation's filter (`hooks/pre-tool-use.sh` included); keep every other `.pipeline/` artifact out of git.

**After each agent returns, record its digest line** so later phases start from it instead of re-reading artifacts: `node "${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.mjs" flag --status "$PIPELINE_BASE/<issue>/status.json" --phase <phase>-<role> --agent <role> --verdict <token> --summary "<the agent's own concern, quoted, not editorialized>"`. Omit `--summary` for a verdict-only agent. The script refuses an over-cap verdict and cuts an over-cap summary, both caps read from the schema.

When dispatching Phase 4 reviewer prompts (see `phase-4-panel.md`), include the line `Prior flags: see status.json flags array; the digest is authoritative for what earlier agents already raised.` This avoids each Phase 4 reviewer re-parsing review.json and impl-report.json from cold.

