**Rows that loop back for remediation leave no stale verdict (#110).** `checkpoint.mjs enter 3-impl --loopback` and the later `enter 4-review` both clear `final_verdict` and `peer_review_verdict_counts` in their own write, so a run under remediation never carries the verdict of the round it is remediating; the panel result stays durable in `events[]`. The record that forced this is cited in `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` ("Phase 4 checkpoint: the stale verdict").

### Delta re-review (a REQUEST_CHANGES / REQUEST_REFACTOR re-run, not a fresh panel)

**The delta stance: rule on your open blockers; a fix round is not a fresh hunt.** Every delta reviewer is told: "Rule only on your open blockers listed below. A new finding blocks only if the fix commits introduced it and it has a merge_class; everything else is a note." `render-panel.mjs --delta` prepends that sentence to the preamble and appends each role's open blocker ids to its lens, read from `materiality.open_blocker_ids` in the merged `peer-review.json` passed as `--peer-review`.

This replaced two instructions that could not converge together: a preamble telling every reviewer to surface the single strongest flaw it could find, and a delta paragraph telling it to assume the remediation introduced a defect until evidence said otherwise. A reviewer instructed to find a defect finds one, every round. Measured on one consumer: one tooling issue ran 8 Phase 4 panel rounds and 21 spec revisions under those two instructions. What they were protecting is kept where it has a cost attached: a defect the fix commits INTRODUCED still blocks when it has a merge_class (a fix that makes a gate report green on a real failure, or that exposes data, is exactly that), and a fix that opens a merge_class hole is still the first thing a delta reviewer checks.

When a residual is argued down to a note, apply the ship-or-block line from `evidence.md`: a control a LIVE INPUT can defeat is a gap; a control only a FUTURE EDIT can defeat is a ratchet. Do not grade the identical defect two ways one round apart because the second time it arrived with a mitigation attached.

When Phase 4 loops back on a `REQUEST_CHANGES` (or a `REQUEST_REFACTOR`) and Dev has pushed fix commits, do NOT re-run the whole panel. Re-dispatch only the roles whose judgment the fix could have changed, and let the standing approvals of the untouched roles hold. Resolve `ROLES_TO_MERGE` for the delta round mechanically:

```bash
# The FULL panel is whatever was recorded in status.json panel_roles on the first
# round; that set is authoritative for the rubric and the counts below. Do NOT
# recompute or shrink panel_roles on a delta round.
FULL_PANEL="$(jq -r '.panel_roles | join(" ")' "$PIPELINE_BASE/<issue>/status.json")"

# cost_class decides which surfaces reseat a role (tooling: see below). Absent reads as product.
COST_CLASS="${COST_CLASS-$(jq -r '.cost_class // empty' "$PIPELINE_BASE/<issue>/status.json" 2>/dev/null)}"

# Re-dispatch: SEED with every role that still HOLDS AN OPEN BLOCKER ID in the merged
# peer-review.json (materiality.open_blocker_ids), THEN add a role by surface ONLY where the fix
# commits touched that role's MERGE-CLASS surface, through the same three-outcome probes the
# first round used so detection never drifts: dba on the data layer (data-loss), secops on a
# security path (security-exposure) and on the data layer except at cost_class tooling, qa on a
# test file (wrong-pass), devops on infra except at cost_class tooling, where CI and hook config
# IS the change. Design has no merge-class surface of its own and re-sits only while it holds an
# open blocker. Otherwise a standing verdict holds. SecOps seating on a FULL round is unchanged.
if [ -z "${OBJECTING_ROLES+set}" ]; then
  if ! OBJECTING_ROLES="$(node -e 'import(process.env.CLAUDE_PLUGIN_ROOT+"/scripts/materiality.mjs").then(m=>{const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(m.openBlockerRoles(j).join(" "))}).catch(e=>{console.error("SEED-INDETERMINATE: "+(e&&e.message));process.exit(1)})' "$ARTIFACT_DIR/peer-review.json")"; then
    OBJECTING_ROLES="$FULL_PANEL"
    echo "PANEL-NOTE: open blocker ids UNREADABLE from peer-review.json; the delta seeds the FULL panel ($FULL_PANEL)."
  fi
fi
DELTA=""
for role in $OBJECTING_ROLES; do case " $DELTA " in *" $role "*) ;; *) DELTA="$DELTA $role";; esac; done
FIX_CHANGED_PATHS="$(mktemp)"
# SUBSTITUTE THIS, or the block refuses to run. FIRST_ROUND_HEAD is the sha HEAD pointed at when
# the FIRST round's panel ran. Spelled as an angle-bracket placeholder on the git line, it parsed
# as a shell REDIRECTION rather than a ref if the line was copied verbatim: harmless in the end
# (every probe went indeterminate and the panel over-seated) but harmless by accident. The `:?`
# makes an unsubstituted copy fail loudly and immediately instead.
FIRST_ROUND_HEAD="${FIRST_ROUND_HEAD:?substitute the first-round HEAD sha before running this block}"
git -C "$WORKTREE_PATH" diff --name-only -z "$FIRST_ROUND_HEAD"...HEAD > "$FIX_CHANGED_PATHS"
GIT_RC=$?
if [ "$GIT_RC" -ne 0 ]; then
  : > "$FIX_CHANGED_PATHS"
  echo "SURFACE-INDETERMINATE: git diff --name-only -z exited $GIT_RC; the changed-path list is UNKNOWN, not empty." >&2
fi
# The SAME module AND the SAME three-outcome probe the first-round panel composition uses, so a
# delta round cannot drift from it, and an unevaluable probe SEATS the specialist here too.
# This definition is byte-identical to the one above on purpose; keep them that way. The path
# list is passed by REDIRECTION at the call site rather than named inside the function, which
# is what lets the two definitions stay byte-identical across two differently-named lists.
surface_probe() {  # $1 = module basename under scripts/, $2 = predicate export; NUL path list on STDIN
  # THE BRACES ARE LOAD-BEARING, and nothing else in the tree says so. Plain bash treats
  # "$1" and "${1}" identically, so reverting both copies to the bare form is a no-op to a
  # shell, to the test suite, and to any diff review: it reads as a stray-brace cleanup. The
  # risk sits UPSTREAM of any shell. This file is a slash-command template, and the loader
  # substitutes bare $N tokens in the TEXT before a shell ever runs it; a rendered copy with
  # $1 substituted away exits 1 (INDETERMINATE) on every call, which the caller reads as a
  # broken probe rather than a broken template. Keep the braces, and keep both copies
  # byte-identical to each other.
  node -e 'const fs=require("node:fs");new Promise(r=>r(fs.readFileSync(0,"utf8").split("\0").filter(Boolean))).then(paths=>import(process.env.CLAUDE_PLUGIN_ROOT + "/scripts/" + process.argv[1]).then(m=>{const f=m[process.argv[2]];if(typeof f!=="function")throw new Error("missing export "+process.argv[2]+" in "+process.argv[1]);if(paths.length===0)throw new Error("empty path list: an unread diff is not a clean diff");process.exit(f(paths)?0:20)})).catch(e=>{console.error("SURFACE-INDETERMINATE: "+process.argv[2]+": "+(e&&e.message));process.exit(1)})' "${1}" "${2}"
}
surface_probe data-layer-surface.mjs diffTouchesDataLayer < "$FIX_CHANGED_PATHS"; RC=$?
if [ "$RC" -ne 20 ]; then
  case " $DELTA " in *" dba "*) ;; *) DELTA="$DELTA dba";; esac
  if [ "$RC" -ne 0 ]; then
    echo "PANEL-NOTE: dba SEATED on an INDETERMINATE data-layer probe (exit $RC; see SURFACE-INDETERMINATE on stderr), not on a match."
  fi
  # A data-layer fix is a security surface too (access policies, retained data), so it seats
  # SecOps; at cost_class tooling SecOps reseats only on a security path, probed next.
  if [ "$COST_CLASS" != "tooling" ]; then
    case " $DELTA " in *" secops "*) ;; *) DELTA="$DELTA secops";; esac
    if [ "$RC" -ne 0 ]; then
      echo "PANEL-NOTE: secops SEATED on an INDETERMINATE data-layer probe (exit $RC; see SURFACE-INDETERMINATE on stderr), not on a match."
    fi
  fi
fi
# SecOps and QA are seated by their OWN surfaces (scripts/security-surface.mjs), on the same
# three-outcome shape: an unevaluable probe seats them, a no-match (20) leaves them out.
surface_probe security-surface.mjs diffTouchesSecuritySurface < "$FIX_CHANGED_PATHS"; RC=$?
if [ "$RC" -ne 20 ]; then
  case " $DELTA " in *" secops "*) ;; *) DELTA="$DELTA secops";; esac
  if [ "$RC" -ne 0 ]; then
    echo "PANEL-NOTE: secops SEATED on an INDETERMINATE security-surface probe (exit $RC; see SURFACE-INDETERMINATE on stderr), not on a match."
  fi
fi
surface_probe security-surface.mjs diffTouchesTests < "$FIX_CHANGED_PATHS"; RC=$?
if [ "$RC" -ne 20 ]; then
  case " $DELTA " in *" qa "*) ;; *) DELTA="$DELTA qa";; esac
  if [ "$RC" -ne 0 ]; then
    echo "PANEL-NOTE: qa SEATED on an INDETERMINATE test-surface probe (exit $RC; see SURFACE-INDETERMINATE on stderr), not on a match."
  fi
fi
surface_probe data-layer-surface.mjs diffTouchesInfra < "$FIX_CHANGED_PATHS"; RC=$?
if [ "$RC" -ne 20 ] && [ "$COST_CLASS" != "tooling" ]; then
  case " $DELTA " in *" devops "*) ;; *) DELTA="$DELTA devops";; esac
  if [ "$RC" -ne 0 ]; then
    echo "PANEL-NOTE: devops SEATED on an INDETERMINATE infra probe (exit $RC; see SURFACE-INDETERMINATE on stderr), not on a match."
  fi
fi
rm -f "$FIX_CHANGED_PATHS"
ROLES_TO_MERGE="$DELTA"
```

Every role is seated on a delta round by the same rule: it holds an open blocker id, or the fix commits touched its MERGE-CLASS surface (the table in the block's comment). An unevaluable probe still seats, under the three-outcome rule. Otherwise the standing verdict holds. **SecOps seating on a FULL round stays mandatory at every tier and every cost class**; this rule trims delta rounds only, so a fix to a layout file, or a tooling fix that touches CI config, no longer buys a fresh security pass. (A SecOps `VETO` on a delta round stands only on a valid `veto_ground` carrying a blocking concern, and then halts to BA as always.) Dispatch ONLY `$ROLES_TO_MERGE`, rendered the same way as the first round with the delta form (`node "${CLAUDE_PLUGIN_ROOT}/scripts/render-panel.mjs" --status ... --worktree ... --delta "$ROLES_TO_MERGE" --first-round-head "$FIRST_ROUND_HEAD" --peer-review "$ARTIFACT_DIR/peer-review.json" --check --out "$ARTIFACT_DIR/panel.delta.workflow.mjs"`; the delta paragraph it prepends names the first-round head, the fix diff and the delta stance, and each lens lists that role's open blocker ids), then run the merge block above but WITHOUT the `rm -f "$ARTIFACT_DIR/peer-review.json"` line, so `merge-peer-review.mjs` folds the delta shards INTO the existing file and the standing approvals of the NON-delta roles survive. After the delta merge:

- `peer-review.json` carries a verdict for the FULL panel: the objecting and surface-touched roles are freshly re-reviewed, and every other role's standing verdict is preserved.
- Record the verdict with `record-verdict.mjs` (`phase-4-verdict.md`) plus `--note "delta re-review: $ROLES_TO_MERGE"`. It counts and applies the rubric over the FULL recorded `panel_roles`, never the delta subset, lists EVERY panel role in the PR summary, and leaves `panel_roles` as the original full panel, so the audit trail shows the full panel and the delta subset separately.

