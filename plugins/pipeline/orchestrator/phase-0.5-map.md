## Phase 0.5: Understand & Map (before the spec locks)

**Checkpoint first:** `checkpoint.mjs enter 0.5-map --exit-verdict <verdict> --commit` (`status-record.md`; it writes `current_phase: "0.5-map"`) BEFORE dispatching the mapping pass.

Phase 0.5 runs BEFORE the Phase 1 spec locks. It produces a `map.json` artifact at `ARTIFACT_DIR` (or, before the issue number exists, at `$PIPELINE_BASE/<placeholder>`) that enumerates the contracts, tables, and types the ask will touch and, for each, its READERS / CONSUMERS across three layers:

1. **Code call sites** (grep the repo for importers and callers of the symbol).
2. **Data-layer-resident readers** (function and view bodies in your migration/schema sources that read the changed table; invisible to a code-level call-site grep).
3. **Client-side or other independent re-derivations** (a client that recomputes a label the server now composes, or any second code path that derives the same value).

Dispatch the mapping pass as BA (or, for an architectural-tier ask, parallel reader agents each scoping one layer), seeding from the knowledge store (`knowledge/living-context/<domain>--<contract>-consumers.json` under the contract's owning domain; see Phase 5) when one exists for a touched contract, then verifying and extending it. The map is the INPUT to the Phase 1 spec (BA writes the blast-radius section from it) and to the Phase 4 blast-radius lens, so blast radius is consulted from a stored map rather than re-grepped fresh each phase, where a data-layer-resident reader is easy to miss. When a SEPARATE map dispatch is made, add the line `node "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-model.mjs" ba <risk_tier> 0.5 --site map --emit` prints (see "Dispatch model routing").

The depth is the `MAP:` line `next-phase.mjs` printed: `separate` runs the deep three-layer map as its own dispatch; `folded` makes no map dispatch, and BA produces `map.json` alongside `spec.json` in its Phase 1 dispatch, as catalog-seeded verification of the touched contracts and their consumer catalogs; `skip` writes no deep map. After the map is written, update `status.json` with `current_phase: "0.5-map-complete"` and proceed to Phase 1.

---
