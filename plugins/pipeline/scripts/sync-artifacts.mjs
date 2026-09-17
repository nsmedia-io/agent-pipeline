#!/usr/bin/env node
/**
 * sync-artifacts.mjs -- copy a Phase 3 worktree's artifacts back to the canonical pipeline dir
 * (#164 row 14).
 *
 *   node sync-artifacts.mjs --from <worktree>/.pipeline/<issue> --to <PIPELINE_BASE>/<issue>
 *
 * Each top-level file in --from is copied by OWNERSHIP (scripts/artifact-ownership.mjs, the list
 * knowledge-store.mjs's archive staleness check also reads):
 *   seeded       no-clobber: the canonical copy is authoritative, the worktree's is the stale seed
 *   produced     force: the worktree copy is the newer one
 *   unclassified no-clobber, and one `UNCLASSIFIED <name>` line so it gets classified
 *
 * Run it before any worktree cleanup and again immediately before the Phase 5 Librarian dispatch:
 * an APPROVE_WITH_NOTES round keeps writing produced artifacts after the first sync.
 *
 * --from absent, or the same directory as --to, is a no-op (exit 0, said on stdout).
 *
 * EXIT CODES. 0 synced (or nothing to sync). 1 usage, or a copy failed: a produced artifact that
 * did not reach the canonical dir is lost when the worktree is removed, so a failure is not
 * swallowed the way the old `cp ... || true` did.
 */

import { copyFileSync, existsSync, mkdirSync, readdirSync, statSync, constants } from "node:fs";
import { join, resolve } from "node:path";
import { isMain, nativePath } from "./lib.mjs";
import { ownershipOf } from "./artifact-ownership.mjs";

const USAGE = "usage: node sync-artifacts.mjs --from <worktree artifact dir> --to <canonical artifact dir>\n";

/** @returns {{skipped: string|null, lines: string[], failures: string[]}} */
export function syncArtifacts(from, to) {
  const src = resolve(from);
  const dst = resolve(to);
  if (!existsSync(src) || !statSync(src).isDirectory()) return { skipped: `${from} is not a directory; nothing to sync`, lines: [], failures: [] };
  if (src === dst) return { skipped: "--from and --to are the same directory; nothing to sync", lines: [], failures: [] };
  mkdirSync(dst, { recursive: true });
  const lines = [];
  const failures = [];
  for (const name of readdirSync(src).sort()) {
    const f = join(src, name);
    if (!statSync(f).isFile()) continue;
    const owner = ownershipOf(name);
    const force = owner === "produced";
    const target = join(dst, name);
    if (!force && existsSync(target)) {
      lines.push(`kept ${name} (${owner || "unclassified"}; canonical copy exists)`);
    } else {
      try {
        copyFileSync(f, target, force ? 0 : constants.COPYFILE_EXCL);
        lines.push(`copied ${name} (${owner || "unclassified"})`);
      } catch (e) {
        failures.push(`${name}: ${e.message}`);
        continue;
      }
    }
    if (!owner) lines.push(`UNCLASSIFIED ${name}: matches no ownership rule; copied no-clobber. Classify it in scripts/artifact-ownership.mjs.`);
  }
  return { skipped: null, lines, failures };
}

export function main(argv, { out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s) } = {}) {
  let from = "";
  let to = "";
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--from") from = argv[++i] || "";
    else if (argv[i] === "--to") to = argv[++i] || "";
    else {
      err(`sync-artifacts: unknown argument ${argv[i]}\n${USAGE}`);
      return 1;
    }
  }
  if (!from || !to) {
    err(USAGE);
    return 1;
  }
  let r;
  try {
    r = syncArtifacts(nativePath(from), nativePath(to));
  } catch (e) {
    err(`sync-artifacts: ${e.message}\n`);
    return 1;
  }
  if (r.skipped) {
    out(`sync-artifacts: ${r.skipped}\n`);
    return 0;
  }
  for (const l of r.lines) out(`${l}\n`);
  if (r.failures.length) {
    for (const f of r.failures) err(`sync-artifacts: FAILED ${f}\n`);
    return 1;
  }
  return 0;
}

if (isMain("sync-artifacts.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
