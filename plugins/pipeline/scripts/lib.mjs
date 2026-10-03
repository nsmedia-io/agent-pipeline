/**
 * Shared helpers for the agent-pipeline scripts.
 *
 * This file exists because the entrypoint guard was copied into five scripts in three
 * different forms, and the two weakest forms failed SILENTLY: main() never ran, nothing
 * printed, exit 0. A caller cannot tell that from success. Both forms shipped, and each was
 * found only after it had already misled something downstream.
 */

import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";

/**
 * True when this process was started by running `name` directly, false when it was imported.
 *
 * Compares the BASENAME of argv[1], not a suffix. The suffix form that preceded this also
 * matched any file whose name merely ENDS with the script's name, so an importer called
 * `test-knowledge-store.mjs` or a wrapper called `my-gate-pre-phase4.mjs` would run main()
 * mid-import. That direction fails loudly (a usage error) rather than silently, which is why
 * it was a note and not a blocker, but basename costs nothing and closes it.
 *
 * Deliberately compares argv[1] rather than import.meta.url. The two disagree whenever any
 * path component is a symlink, because import.meta.url is realpathed while argv[1] keeps the
 * path as invoked; on macOS /tmp is itself a symlink, so that disagreement is routine rather
 * than exotic. Comparing the name sidesteps path form entirely: no realpath, no percent
 * decoding, nothing that varies with how the caller spelled the path.
 *
 * @param {string} name Bare filename of the script, e.g. "knowledge-store.mjs".
 */
export function isMain(name) {
  if (!process.argv[1]) return false;
  return basename(process.argv[1]) === name;
}

/**
 * A single path segment safe to interpolate into a filename.
 *
 * Throws on anything carrying a path separator or a `..` segment, so a caller-supplied id
 * cannot walk out of the directory it is joined into. Returns the value unchanged when it is
 * already a plain segment, so legitimate ids (`847`, `exp-script-test-coverage`) pass through.
 *
 * @param {string} value The untrusted id.
 * @param {string} label Field name, used in the error message.
 */
export function assertPathSegment(value, label) {
  const s = String(value);
  if (s === "" || s === "." || s === ".." || s.includes("/") || s.includes("\\")) {
    throw new Error(`${label} must be a single path segment, got: ${JSON.stringify(s)}`);
  }
  return s;
}

/**
 * A path as THIS platform's node understands it.
 *
 * Git Bash on Windows hands a child process MSYS spellings (`/c/Users/x`) wherever a script
 * receives a path through an argument or an environment variable it set itself. Node on
 * Windows reads `/c/Users/x` as `C:\c\Users\x`, a directory that does not exist, so every read
 * under it fails and a fail-open caller reports nothing. On win32 this rewrites a leading
 * `/<drive>/` to `<DRIVE>:/`; on every other platform, and for any other shape, it returns the
 * value unchanged.
 *
 * @param {string} p
 * @param {string} [platform] process.platform, injectable so the rewrite is testable anywhere.
 */
export function nativePath(p, platform = process.platform) {
  const s = String(p ?? "");
  if (platform !== "win32") return s;
  const m = /^\/([a-zA-Z])(\/.*|)$/.exec(s);
  return m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : s;
}

/**
 * Where pipeline.config.json is read from: the worktree under review when it carries one (the
 * config is committed, so the branch being diffed has it), else the project dir.
 *
 * @param {string} [worktree]
 * @param {string} [fallback]
 */
export function configDir(worktree, fallback = process.env.CLAUDE_PROJECT_DIR || process.cwd()) {
  return worktree && existsSync(join(worktree, "pipeline.config.json")) ? worktree : fallback;
}

/**
 * The project's integration branch: `integrationBranch` in `<dir>/pipeline.config.json`, else
 * `main`. Returns `{ branch, source }` so a report can say where the answer came from.
 *
 * @param {string} dir
 */
export function integrationBranch(dir) {
  const file = join(dir, "pipeline.config.json");
  try {
    if (!existsSync(file)) return { branch: "main", source: "default" };
    const cfg = JSON.parse(readFileSync(file, "utf8"));
    const v = cfg && typeof cfg === "object" ? cfg.integrationBranch : undefined;
    if (typeof v === "string" && v.trim() !== "") return { branch: v.trim(), source: "pipeline.config.json integrationBranch" };
    return { branch: "main", source: "default" };
  } catch {
    return { branch: "main", source: "default (pipeline.config.json does not parse)" };
  }
}

/**
 * The ref a PR's diff is taken against: `origin/<integrationBranch>`, read from the worktree's
 * config (see configDir). A PR opens against the integration branch, so this is the base its
 * diff has. A hard-coded origin/main was right only where main IS the integration branch; on a
 * project integrating into staging, with main promoted behind it, `origin/main...HEAD` carried
 * every staging commit main lacked, and an 8-file diff probed as 58 files and seated two
 * reviewers the change never earned.
 *
 * @param {string} [worktree]
 */
export function diffBase(worktree) {
  return `origin/${integrationBranch(configDir(worktree)).branch}`;
}
