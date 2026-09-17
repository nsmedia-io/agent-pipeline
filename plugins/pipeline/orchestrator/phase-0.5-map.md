## Phase 0.5: Understand & Map (before the spec locks)

**Checkpoint first:** set `current_phase: "0.5-map"` and commit `status.json` (per the durable-checkpoint convention above) BEFORE dispatching the mapping pass.

Phase 0.5 runs BEFORE the Phase 1 spec locks. It produces a `map.json` artifact at `ARTIFACT_DIR` (or, before the issue number exists, at `$PIPELINE_BASE/<placeholder>`) that enumerates the contracts, tables, and types the ask will touch and, for each, its READERS / CONSUMERS across three layers:

1. **Code call sites** (grep the repo for importers and callers of the symbol).
2. **Data-layer-resident readers** (function and view bodies in your migration/schema sources that read the changed table; invisible to a code-level call-site grep).
3. **Client-side or other independent re-derivations** (a client that recomputes a label the server now composes, or any second code path that derives the same value).

Dispatch the mapping pass as BA (or, for an architectural-tier ask, parallel reader agents each scoping one layer), seeding from the knowledge store (`knowledge/living-context/<domain>--<contract>-consumers.json` under the contract's owning domain; see Phase 5) when one exists for a touched contract, then verifying and extending it. The map is the INPUT to the Phase 1 spec (BA writes the blast-radius section from it) and to the Phase 4 blast-radius lens, so blast radius is consulted from a stored map rather than re-grepped fresh each phase, where a data-layer-resident reader is easy to miss. When a SEPARATE map dispatch is made (the architectural tier), resolve its model from the routing table rather than typing one in: `node "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-model.mjs" ba <risk_tier> 0.5 --site map` prints `sonnet` today, because the map is mechanical catalog-seeded reader enumeration, not the deep-reasoning work that warrants opus. Emit `model:` ONLY IF that call exited 0 and printed exactly one token; on any other outcome omit the key entirely so the agent frontmatter governs (see "Dispatch model routing" below).

Gate by risk tier (see "Risk-tiered orchestration depth" above): the **trivial** tier may SKIP the deep map entirely; **standard** does NOT make a separate map subagent dispatch at all, its map is catalog-seeded verification (the touched contracts plus their known `knowledge/living-context/<domain>--<contract>-consumers.json` catalogs) FOLDED INTO the BA Phase 1 dispatch, so BA produces `map.json` alongside `spec.json` in one context; **architectural** runs the deep three-layer map as its own (sonnet) dispatch. After the map is written (separately at architectural, or as part of Phase 1 at standard), update `status.json` with `current_phase: "0.5-map-complete"` and proceed to Phase 1.

---
