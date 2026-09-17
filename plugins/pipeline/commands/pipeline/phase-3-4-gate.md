## Phase 3 to 4 transition: fail-CLOSED pre-Phase-4 gate (run before the panel)

Before dispatching the panel, run the orchestrator-invoked, fail-closed gate against the Phase 3 artifacts. It is the deterministic counterpart to the (deliberately fail-OPEN) SubagentStop validator: a malformed or incomplete `impl-report.json` must HALT the pipeline before the panel rather than slip through. The gate validates `impl-report.json` against its schema, checks that `requirement_checks` covers every `acceptance_criteria` entry in `spec.json`, and checks that any schema migration added in the diff has both an up and a down section (if your project uses migrations). It checks structural reversibility only; full migration-syntax validity remains your CI's job, not the gate's.

The gate is wired ONLY here, at the Phase 3 to 4 transition. Do NOT add it to your CI or deploy workflows; it gates the pipeline panel, not deploys.

```bash
# Run from the orchestrator checkout. Non-zero exit HALTS: do not dispatch the panel.
# impl-report.json and spec.json live in the worktree's ARTIFACT_DIR at this point (the Phase 4
# sync below copies them back to $PIPELINE_BASE afterward), so point the gate at the absolute paths.
node ${CLAUDE_PLUGIN_ROOT}/scripts/gate-pre-phase4.mjs --issue <issue> \
  --impl-report "$ARTIFACT_DIR/impl-report.json" \
  --spec "$ARTIFACT_DIR/spec.json"
```

If the gate exits non-zero (absent or unparseable artifact, schema violation, an acceptance criterion with no covering `requirement_check`, a migration missing its down section, an empty down region with no rollback note under the marker, a down region that contains executable SQL, or a down region the gate cannot classify because of an unterminated block comment), HALT:
- Update `status.json` with `current_phase: "3-impl-gate-failed"` and the gate's stderr summary.
- Return to the owner, loop back to Phase 3 (Dev) to fix the artifact or implementation. Re-run the gate before retrying the panel.

Then run the **frontend visual-verification gate** (the frontend twin of the live-verification gate below). It self-SKIPS (exit 0) when the diff touches no frontend surface, and fails CLOSED only when a frontend file changed but the recorded design evidence (a `design_review` verdict + a token-lint pass + an axe pass) is missing. Run it AFTER the gate above, never inside your CI:

```bash
# Run from the orchestrator checkout, after gate-pre-phase4.mjs passed. Non-zero exit
# HALTS the panel. The frontend surface is read from ${CLAUDE_PLUGIN_ROOT}/scripts/frontend-surface.mjs
# (# CUSTOMIZE: the frontend surface globs live there; it is the same allowlist Phase 4 uses for
# panel_roles), so detection and dispatch never diverge.
node ${CLAUDE_PLUGIN_ROOT}/scripts/gate-pre-phase4-frontend.mjs --issue <issue> \
  --impl-report "$ARTIFACT_DIR/impl-report.json"
```

If this gate exits non-zero (a frontend file changed with no `design_review` evidence, a missing token-lint or axe pass, or a screenshot path that does not start with `.pipeline/` or that contains a `..` segment), HALT: update `status.json` with `current_phase: "3-impl-frontend-gate-failed"` and the gate's stderr summary, and loop back to Phase 3 (Dev records the `design_gate` evidence) or re-dispatch the Design reviewer before retrying the panel. A non-frontend diff prints `SKIP` and proceeds.

### Mis-tier tripwire (trivial/standard tier only, deterministic)

A standard-tier spec has, by definition, no schema/migration dimension, so a migration appearing in the diff means the tier call was wrong and the never-skip DBA migration gate was bypassed. Check mechanically, not by judgment:

The predicate is the surface module's, not a hand-typed regex: `migrationGlobsForTripwire` is the built-in framework-preset union WIDENED by `migrationGlobs` and `extraMigrationGlobs`, so a project config can only ever widen this halt, never narrow it. (# CUSTOMIZE: widen it with `extraMigrationGlobs` in `pipeline.config.json`; narrowing the tripwire is deliberately impossible, because binding a halting control to a narrowing knob lets a four-character edit disarm it while the config still reports healthy.)

```bash
CHANGED_PATHS="$(mktemp)"
git -C "$WORKTREE_PATH" diff --name-only -z origin/main...HEAD > "$CHANGED_PATHS"
GIT_RC=$?
if [ "$GIT_RC" -ne 0 ]; then : > "$CHANGED_PATHS"; fi
TRIPWIRE_OUT="$(node -e 'const fs=require("node:fs");new Promise(r=>r(fs.readFileSync(0,"utf8").split("\0").filter(Boolean))).then(paths=>{if(paths.length===0)throw new Error("empty path list: an unread diff is not a clean diff");return import(process.env.CLAUDE_PLUGIN_ROOT + "/scripts/data-layer-surface.mjs").then(m=>{const r=m.tripwireReport(paths);if(r.note)console.error("TRIPWIRE-NOTE: "+r.note);if(r.hits.length)console.log(r.hits.join(" "))})}).catch(e=>{console.log("unevaluable: "+(e&&e.message));process.exit(1)})' < "$CHANGED_PATHS")"
TRIPWIRE_RC=$?
rm -f "$CHANGED_PATHS"
if [ "$GIT_RC" -ne 0 ]; then
  echo "3-impl-tripwire-indeterminate: git diff --name-only -z exited $GIT_RC, so the changed-path list is UNKNOWN rather than empty."
elif [ "$TRIPWIRE_RC" -ne 0 ]; then
  echo "3-impl-tripwire-indeterminate: the data-layer surface module under ${CLAUDE_PLUGIN_ROOT}/scripts/ could not be evaluated (exit $TRIPWIRE_RC). $TRIPWIRE_OUT"
elif [ -n "$TRIPWIRE_OUT" ]; then
  echo "MIS-TIER: data-layer path in a $RISK_TIER diff: $TRIPWIRE_OUT"
fi
```

**The path list crosses the seam NUL-delimited on stdin, never through an unquoted shell variable.** `zsh` does not word-split an unquoted parameter expansion, and zsh is what the orchestrator's own shell tool runs; the measured escape is in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Mis-tier tripwire: the zsh path list").

**`git`'s own exit status is captured and branched on.** A bad `WORKTREE_PATH` or a missing `origin/main` ref leaves an EMPTY list on stdout, byte-identical to a clean diff (the observed failure is in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md`, "Mis-tier tripwire: git's exit status"). **An empty or unreadable path list is INDETERMINATE, never no-match**, at all three call sites: the probe throws on a zero-length list rather than answering false, and here that lands in the fail-closed halt. An empty diff at this gate is itself anomalous, because there is nothing for the panel to review.

**Capture the exit status, then branch on it; never pipe this invocation.** Written as `<the node call> | grep -q ...`, a pipe would discard the module's exit status, so an absent or throwing module exits non-zero with empty stdout, the condition reads false, and NO halt fires: silently restoring the exact pre-fix state this tripwire exists to remove. ${CLAUDE_PLUGIN_ROOT} resolving to a stale installed plugin cache that predates the module is a live condition, not a hypothetical.

**It fails CLOSED.** A non-zero exit means the tripwire was never evaluated, which is not the same as a clean diff: the run cannot know the path was clean, because the thing that would have decided did not run. HALT with `current_phase: "3-impl-tripwire-indeterminate"` and loop back to BA exactly as on a hit, recording the module path and the failure in the transcript. Never proceed to the panel on an unevaluated tripwire. (The model resolver in Phase 4 fails the OPPOSITE way, open to frontmatter; both directions are deliberate.)

On a hit, HALT before the panel: update `status.json` with `current_phase: "3-impl-tripwire"`, loop back to BA to re-tier the spec to `architectural`, then on resume run the phases the original tier skipped (Phase 2 fan-out; Phase 2.5 if the change is design-shaped) against the existing worktree before re-entering the gate. DBA's migration review and the live-verification rule below then apply in full. Diffs touching infrastructure/CI config, auth/crypto/webhook-verification surfaces, or the data layer are standard-legal but change the Phase 4 panel composition (see below); they do not halt here.

If the block prints a `TRIPWIRE-NOTE:` line, the effective tripwire set matches zero tracked files in this repository, so this control cannot fire here: put that sentence in the run transcript and record it in `status.json` (`flags`), because the session-start config report that says the same thing may have scrolled past days ago, while the decision is being made now.

**Live-verification gate.** When the diff ADDS or ALTERS a data migration touching access controls or a security-sensitive table, read `${CLAUDE_PLUGIN_ROOT}/commands/pipeline/live-verification.md` now and apply it before the panel.

Only on a clean (exit 0) gate, AND a recorded local pass for any data-migration / security-sensitive change, do you proceed to dispatch the panel below.

