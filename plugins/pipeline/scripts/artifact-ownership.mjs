/**
 * artifact-ownership.mjs -- which side of a Phase 3 worktree owns each pipeline artifact (#164 row 14).
 *
 * ONE LIST, TWO READERS. sync-artifacts.mjs copies by it, and knowledge-store.mjs's archive
 * staleness check compares by it. Before this module the list lived in a bash `case` in the Phase 4
 * prose and was mirrored by hand in knowledge-store.mjs, so a file added to one side was silently
 * frozen or clobbered by the other.
 *
 *   SEEDED   the orchestrator writes these and copies them INTO the worktree, so the canonical copy
 *            is authoritative: sync never overwrites it (no-clobber).
 *   PRODUCED Dev, QA and the Phase 4 panel write these IN the worktree, so the worktree copy is the
 *            newer one: sync overwrites the canonical copy (force).
 *   anything else is UNCLASSIFIED: copied no-clobber and named, so a new artifact type surfaces as a
 *            line to classify here rather than a silent choice.
 *
 * The split is by OWNERSHIP, not by first arrival; the measurement behind it (#34) is in
 * docs/rationale.md ("Artifact sync").
 */

/** The .json artifacts produced in the worktree, by stem. Shards are `<stem>.<role>.json`. */
export const WORKTREE_PRODUCED = Object.freeze(["map", "tasks", "impl-report", "peer-review"]);
/** The .json artifacts seeded into the worktree, by stem. */
export const WORKTREE_SEEDED = Object.freeze(["spec", "review", "status"]);
const SEEDED_FILES = Object.freeze(["constraints.md"]);
const SEEDED_SHARD_STEMS = Object.freeze(["review"]);
const PRODUCED_SHARD_STEMS = Object.freeze(["peer-review"]);

/** "seeded" | "produced" | null for a file's basename. */
export function ownershipOf(name) {
  const b = String(name);
  if (SEEDED_FILES.includes(b)) return "seeded";
  // The shard is anything the old `review.*.json` / `peer-review.*.json` globs matched.
  const m = /^([a-z][a-z0-9-]*)(?:\.(.+))?\.json$/.exec(b);
  if (!m) return null;
  const [, stem, shard] = m;
  if (shard === undefined) {
    if (WORKTREE_SEEDED.includes(stem)) return "seeded";
    if (WORKTREE_PRODUCED.includes(stem)) return "produced";
    return null;
  }
  if (SEEDED_SHARD_STEMS.includes(stem)) return "seeded";
  if (PRODUCED_SHARD_STEMS.includes(stem)) return "produced";
  return null;
}
