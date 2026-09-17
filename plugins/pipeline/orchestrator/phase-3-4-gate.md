## Phase 3 to 4 transition: fail-CLOSED pre-Phase-4 gate (run before the panel)

Before dispatching the panel, run the Phase 3 exit. It is the deterministic counterpart to the (deliberately fail-OPEN) SubagentStop validator, and it is wired ONLY here: do NOT add it to your CI or deploy workflows; it gates the pipeline panel, not deploys. One call runs, in order:

- **The mis-tier tripwire** (trivial and standard tier; it prints `SKIP` at architectural). A data-layer path in the diff (`tripwireReport` in `data-layer-surface.mjs`, whose set config can only widen: # CUSTOMIZE with `extraMigrationGlobs`) or a path matching an architectural path trigger (`pipeline.config.json` plus `architecturalTriggers.paths`, through `tier-floor.mjs`; #76) means the tier call was wrong and the pre-code gates were bypassed.
- **`gate-pre-phase4.mjs`**: `impl-report.json` against its schema, every `acceptance_criteria` entry covered, and an up and a down section in any added migration (structural reversibility only; migration syntax stays your CI's job). It refuses on an absent or unparseable artifact, schema violation, an acceptance criterion with no covering `requirement_check`, a migration missing its down section, an empty down region with no rollback note under the marker, a down region that contains executable SQL, or a down region it cannot classify because of an unterminated block comment.
- **`gate-pre-phase4-frontend.mjs`**: self-SKIPS on a diff with no frontend surface; otherwise refuses when the `design_review` verdict, token-lint pass or axe pass is not recorded.

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/phase3-exit.mjs" --issue "<issue>" --worktree "$WORKTREE_PATH" --artifact-dir "$ARTIFACT_DIR" --status "$PIPELINE_BASE/<issue>/status.json"
EXIT_RC=$?
case "$EXIT_RC" in 0|2|3|4) ;; *) echo "INDETERMINATE: 3-impl-tripwire-indeterminate: phase3-exit.mjs did not reach a verdict (exit $EXIT_RC); check \${CLAUDE_PLUGIN_ROOT}" ;; esac
```

It prints `HIT:`, `NOTE:`, `SKIP:`, `INDETERMINATE:`, `PASS:` and `FAIL:` lines, then `RESULT:`, and on a halt it writes the state below into `status.json` itself, with a `flags` entry; commit that write as a checkpoint. Never pipe this call: the exit status is the verdict. The shell history behind that rule is in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Mis-tier tripwire").

| Exit | Written | Do |
|---|---|---|
| 0 | nothing | Proceed (after the live-verification check below). |
| 2 | `current_phase: "3-impl-gate-failed"`, or `current_phase: "3-impl-frontend-gate-failed"` when only the frontend gate refused | HALT. Loop back to Phase 3 (Dev fixes the artifact or implementation, or records the `design_gate` evidence, or re-dispatch the Design reviewer), then re-run this call. |
| 3 | `current_phase: "3-impl-tripwire"` | HALT before the panel. Loop back to BA to re-tier the spec to `architectural`, then on resume run the phases the original tier skipped (Phase 2 fan-out; Phase 2.5 if design-shaped) against the existing worktree before re-entering this gate. DBA's migration review and the live-verification rule then apply in full. |
| 4, or any other exit | `current_phase: "3-impl-tripwire-indeterminate"` (write it yourself on an exit other than 4) | HALT and loop back to BA exactly as on exit 3, recording the failure line in the transcript. The run cannot know the diff was clean, because the thing that would have decided did not run (a git failure, an empty diff, a stale plugin root). Never proceed to the panel. (The model resolver in Phase 4 fails the OPPOSITE way, open to frontmatter; both directions are deliberate.) |

Diffs touching infrastructure/CI config, auth/crypto/webhook-verification surfaces, or the data layer beyond the tripwire set are standard-legal but change the Phase 4 panel composition; they do not halt here.

A `NOTE:` line means the tripwire's set matches zero tracked files in this repository, so it cannot fire here: say that sentence in the run transcript (the script has already put it in `flags`), because the session-start report that says the same may have scrolled past days ago.

**Live-verification gate.** When the diff ADDS or ALTERS a data migration touching access controls or a security-sensitive table, read `${CLAUDE_PLUGIN_ROOT}/orchestrator/live-verification.md` now and apply it before the panel.

Only on exit 0, AND a recorded local pass for any data-migration / security-sensitive change, do you proceed to dispatch the panel below.
