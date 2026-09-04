#!/usr/bin/env node
/**
 * SINGLE source of truth for two more surface predicates the Phase 4 DELTA round reads:
 *
 *   diffTouchesSecuritySurface(paths)  did the fix commits touch auth, session, crypto,
 *                                      secrets, webhook, policy or rate-limit code? If so
 *                                      SecOps re-reviews the fix; otherwise its round-1
 *                                      verdict stands like every other role's.
 *   diffTouchesTests(paths)            did the fix commits touch a test file? If so QA
 *                                      re-reviews; otherwise its round-1 verdict stands.
 *
 * Before this module the delta seed was "qa secops" unconditionally, so every fix round paid
 * for two fresh high-effort passes over a diff those roles had already approved. The playbook
 * shape this replaces it with: tests and CI gate the fix, and a reviewer re-reads only what
 * its lens could have been changed by.
 *
 * Both predicates are UNION with config and widen-only: `securitySurfaceGlobs` can seat SecOps
 * on more paths, never fewer, because a glob that narrows a security re-review is a quiet
 * permanent edit that reads as tuning. The security matcher runs on the LOWERCASED path so
 * `Auth/Login.tsx` and `auth/login.tsx` are the same surface; the test matcher does not,
 * because test layouts are conventional and case-stable.
 *
 * Same three-outcome shell contract as the other surface modules: the caller's probe exits 0
 * on match, 20 on no-match, anything else is INDETERMINATE and SEATS the reviewer.
 *
 * # CUSTOMIZE: `securitySurfaceGlobs` (additive) in pipeline.config.json.
 */

import { globToRegExp } from "./frontend-surface.mjs";
import { readPipelineConfig } from "./data-layer-surface.mjs";

export const DEFAULT_SECURITY_SURFACE_GLOBS = [
  "**/auth/**",
  "**/authn/**",
  "**/authz/**",
  "**/*auth*",
  "**/session*",
  "**/sessions/**",
  "**/middleware/**",
  "**/guards/**",
  "**/permissions/**",
  "**/policies/**",
  "**/rls/**",
  "**/*crypto*",
  "**/*encrypt*",
  "**/*secret*",
  "**/*token*",
  "**/*jwt*",
  "**/*oauth*",
  "**/*password*",
  "**/*webhook*",
  "**/*csrf*",
  "**/*cors*",
  "**/*rate-limit*",
  "**/*ratelimit*",
  "**/.env*",
  "**/*.pem",
  "**/*.key",
];

export const DEFAULT_TEST_GLOBS = [
  "**/test/**",
  "**/tests/**",
  "**/__tests__/**",
  "**/spec/**",
  "**/*.test.*",
  "**/*.spec.*",
  "**/*_test.*",
  "**/test_*.py",
  "**/fixtures/**",
];

function stringsOnly(v) {
  return Array.isArray(v) ? v.filter((g) => typeof g === "string") : [];
}

function union(...lists) {
  const out = [];
  for (const list of lists) for (const g of list) if (!out.includes(g)) out.push(g);
  return out;
}

function normalizePath(p) {
  return p.replace(/\\/g, "/").replace(/^\.\//, "");
}

function matchesAny(p, globs) {
  return (globs || []).some((g) => typeof g === "string" && globToRegExp(g).test(p));
}

/** UNION: defaults plus whatever config adds. Config can only widen. */
export function securitySurfaceGlobs(cfg) {
  return union(DEFAULT_SECURITY_SURFACE_GLOBS, stringsOnly(cfg && cfg.securitySurfaceGlobs));
}

export function isSecuritySurfacePath(p, cfg) {
  if (typeof p !== "string") return false;
  return matchesAny(normalizePath(p).toLowerCase(), securitySurfaceGlobs(cfg || readPipelineConfig()));
}

export function diffTouchesSecuritySurface(changedPaths, cfg) {
  const globs = securitySurfaceGlobs(cfg || readPipelineConfig());
  return (changedPaths || []).some(
    (p) => typeof p === "string" && matchesAny(normalizePath(p).toLowerCase(), globs),
  );
}

export function isTestPath(p) {
  if (typeof p !== "string") return false;
  return matchesAny(normalizePath(p), DEFAULT_TEST_GLOBS);
}

export function diffTouchesTests(changedPaths) {
  return (changedPaths || []).some((p) => isTestPath(p));
}
