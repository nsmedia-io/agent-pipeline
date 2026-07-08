# Knowledge store (file-based)

This replaces what would otherwise be a vector database. It is plain JSON on disk, versioned in your project's git, with no external service, no embeddings, and no network calls.

The plugin ships this folder empty. The real content lives in your **project's** `knowledge/` directory (the Librarian writes it, warmup and the agents read it).

## Layout

```
knowledge/
  living-context/   <domain>--<slug>.json   # current project & architecture state, one topic per file
  issue-archive/    <issue>.json            # archived completed pipeline runs
  decisions/        <slug>.json             # optional decision records (ADRs)
```

## living-context file shape

```json
{
  "title": "Auth token lifecycle",
  "domain": "security",
  "status": "current",
  "last_updated": "2026-01-01T00:00:00Z",
  "tags": ["auth", "tokens", "sessions"],
  "content": "Free text. What is true now, and the gotchas a future change must respect.",
  "see_also": ["session-refresh-flow"]
}
```

`domain` is one of: `data | api | frontend | infrastructure | security | compliance | architecture | testing`.
`status` is `current` or `superseded`. To retire a fact, set the old file to `superseded` and write a new `current` one.

## How it is used

- **Read** (warmup, every agent): glob the folder, filter `status: current`, keyword-match on title + tags + content.
  ```bash
  node "${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-store.mjs" --search "auth tokens" --domain security
  ```
- **Write** (Librarian only, Phase 5):
  ```bash
  node "${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-store.mjs" --write --file knowledge/living-context/security--auth-tokens.json
  ```
- **Archive** a completed run (Librarian, Phase 5):
  ```bash
  node "${CLAUDE_PLUGIN_ROOT}/scripts/archive-pipeline.mjs" --issue 42
  ```

## Source precedence

1. The **code and the live system** are present truth and win on any disagreement.
2. `knowledge/*.json` is durable derived truth: reviewable, branch-aware.

Treat a knowledge file as a lead to verify against the code before acting on anything load-bearing. When a file and the code disagree, the code wins, and the Librarian updates the file.
