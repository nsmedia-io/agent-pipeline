#!/usr/bin/env node
/**
 * SINGLE source of truth for which changed paths count as a "frontend surface".
 *
 * Read by BOTH the frontend visual-verification gate (gate-pre-phase4-frontend.mjs, the
 * Phase 3 to 4 gate) AND the orchestrator's panel_roles dispatch logic (the Design agent
 * joins the Phase 2 fan-out and the Phase 4 panel only when this list says the diff is
 * frontend). Keeping the list here, and nowhere else, closes the divergence where a diff
 * is detected as frontend by the gate (halting) but never triggers a Design dispatch (so
 * no review exists to pass the gate).
 *
 * The surface is a list of GLOB patterns. Matching is on the diff path string only; the
 * globs come from the project's OWN committed config (pipeline.config.json), never from
 * agent-influenceable artifact content. No eval, no shell.
 *
 * # CUSTOMIZE: set `frontendSurface` in pipeline.config.json at your project root to the
 * globs that describe YOUR renderable surfaces, e.g.
 *   { "frontendSurface": ["apps/web/**", "packages/ui/**", "**\/*.email.tsx"] }
 * When the key is absent (or empty/invalid) the generic defaults below apply.
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

// # CUSTOMIZE: generic fallback surface (component/markup files plus the usual
// component/ui/style dirs). Override via pipeline.config.json `frontendSurface`.
export const DEFAULT_FRONTEND_SURFACE = [
  "**/*.tsx",
  "**/*.jsx",
  "**/*.vue",
  "**/*.svelte",
  "**/components/**",
  "**/ui/**",
  "**/styles/**",
];

// The project root that owns pipeline.config.json. CLAUDE_PROJECT_DIR is set by the host
// to the user's project; process.cwd() is the fallback when it is not.
function projectRoot() {
  return process.env.CLAUDE_PROJECT_DIR || process.cwd();
}

// Read the frontend-surface globs from pipeline.config.json. A missing or malformed config
// is not an error: fall back to DEFAULT_FRONTEND_SURFACE rather than crash the gate.
function readFrontendSurfaceGlobs() {
  const file = path.join(projectRoot(), "pipeline.config.json");
  try {
    if (!existsSync(file)) return DEFAULT_FRONTEND_SURFACE;
    const cfg = JSON.parse(readFileSync(file, "utf8"));
    const globs = cfg && cfg.frontendSurface;
    if (Array.isArray(globs) && globs.length > 0 && globs.every((g) => typeof g === "string")) {
      return globs;
    }
    return DEFAULT_FRONTEND_SURFACE;
  } catch {
    return DEFAULT_FRONTEND_SURFACE;
  }
}

// Minimal, dependency-free glob -> anchored RegExp. Supports:
//   **/   any number of leading path segments, including none
//   **    any characters, including the path separator
//   *     any characters except the path separator
//   ?     one character except the path separator
// Every other regex metacharacter is escaped, so the pattern is a literal match apart from
// the wildcards above. Exported so the migration gate reuses ONE glob implementation.
export function globToRegExp(glob) {
  let re = "^";
  let i = 0;
  while (i < glob.length) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        i += 2;
        if (glob[i] === "/") {
          re += "(?:.*/)?"; // "**/" -> zero or more leading segments
          i += 1;
        } else {
          re += ".*"; // "**" -> anything, including separators
        }
      } else {
        re += "[^/]*";
        i += 1;
      }
    } else if (c === "?") {
      re += "[^/]";
      i += 1;
    } else if ("\\^$.|+()[]{}".includes(c)) {
      re += "\\" + c;
      i += 1;
    } else {
      re += c;
      i += 1;
    }
  }
  return new RegExp(re + "$");
}

// Compile once (lazily, so config + cwd are read at first use, not at import time; that
// keeps importing this module for globToRegExp free of filesystem side effects).
let COMPILED = null;
function compiledSurface() {
  if (!COMPILED) COMPILED = readFrontendSurfaceGlobs().map(globToRegExp);
  return COMPILED;
}

// A changed path is a frontend surface when it matches any configured glob. `p` is a
// repo-relative path from the diff (git diff --name-only).
export function isFrontendPath(p) {
  if (typeof p !== "string") return false;
  const norm = p.replace(/\\/g, "/").replace(/^\.\//, "");
  return compiledSurface().some((re) => re.test(norm));
}

// True when ANY changed path is a frontend surface. This is the discriminating signal the
// gate fails-closed on: "frontend files changed", never "evidence missing" on an empty set
// (the grounding gate's fail-direction requirement). Signature unchanged for callers.
export function diffTouchesFrontend(changedPaths) {
  return (changedPaths || []).some(isFrontendPath);
}
