#!/usr/bin/env node
/**
 * version-check.mjs: is the plugin copy this session runs older than one already on disk?
 *
 * WHY. A consumer machine ran every hook from
 * ~/.claude/plugins/cache/agent-pipeline/pipeline/0.24.0 while 0.42.0 was published, and
 * nothing said so. The hooks, the agent contracts and /pipeline all load from the installed
 * cache, not from the project checkout, so a stale install is invisible from inside a session:
 * every gate answers consistently for the version it is.
 *
 * WHAT IT COMPARES, WITH NO NETWORK CALL. The running plugin.json version against:
 *   (a) the marketplace clone Claude Code keeps under <plugins>/marketplaces/<marketplace>/,
 *       read from its marketplace.json entry and from the plugin.json that entry points at;
 *   (b) every other version directory under <plugins>/cache/<marketplace>/<plugin>/, which is
 *       how a machine can hold 0.42.0 and still run 0.24.0.
 * ONLY (a) DECIDES WHETHER IT WARNS. A newer cached directory with no newer marketplace entry is
 * an orphan (a rolled-back install, a local test build), and a warning keyed on it would repeat
 * every session with nothing the update command could change. The cache is named in the line
 * only when the marketplace already says the copy is behind. The clone is only as fresh as its
 * last marketplace update, so a silent result means "nothing newer is advertised on this disk",
 * never "you are current".
 *
 * OUTPUT. At most ONE plain line, and only when the running copy is behind. Otherwise nothing.
 * It never exits non-zero and never writes: it runs inside the SessionStart hook's budget and a
 * version probe must not be able to wedge a session.
 *
 * Usage: node version-check.mjs [--plugin-root <dir>] [--plugins-dir <dir>] [--json]
 *   --plugin-root  the running plugin (default: $CLAUDE_PLUGIN_ROOT, else this script's parent)
 *   --plugins-dir  Claude Code's plugins dir (default: $CLAUDE_CONFIG_DIR/plugins, else
 *                  ~/.claude/plugins)
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMain, nativePath } from "./lib.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_MARKETPLACE = "agent-pipeline";

const SEMVER_RE = /^(\d+)\.(\d+)\.(\d+)$/;

/** Numeric x.y.z compare. Returns null when either side is not plain x.y.z. */
export function compareVersions(a, b) {
  const ma = SEMVER_RE.exec(String(a ?? ""));
  const mb = SEMVER_RE.exec(String(b ?? ""));
  if (!ma || !mb) return null;
  for (let i = 1; i <= 3; i++) {
    const d = Number(ma[i]) - Number(mb[i]);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function isDir(p) {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/**
 * When the running root is a cache install, <plugins>/cache/<marketplace>/<plugin>/<version>,
 * return those three names. Decided on path SEGMENTS, so a Windows path, a forward-slash
 * Windows path and a POSIX path all resolve the same way.
 */
export function cacheCoordinates(pluginRoot) {
  const segs = String(pluginRoot).split(/[\\/]+/).filter(Boolean);
  const i = segs.lastIndexOf("cache");
  if (i < 0 || segs.length !== i + 4) return null;
  if (segs[i - 1] !== "plugins") return null;
  return { marketplace: segs[i + 1], plugin: segs[i + 2], version: segs[i + 3] };
}

/** Versions advertised by the local marketplace clone for this plugin. */
function marketplaceVersions(pluginsDir, marketplace, pluginName) {
  const clone = path.join(pluginsDir, "marketplaces", marketplace);
  const manifest = readJson(path.join(clone, ".claude-plugin", "marketplace.json"));
  const found = [];
  const entry = Array.isArray(manifest?.plugins) ? manifest.plugins.find((p) => p?.name === pluginName) : null;
  if (entry) {
    if (typeof entry.version === "string") found.push(entry.version);
    const src = typeof entry.source === "string" ? entry.source : null;
    if (src && src.startsWith("./")) {
      const pj = readJson(path.join(clone, src, ".claude-plugin", "plugin.json"));
      if (typeof pj?.version === "string") found.push(pj.version);
    }
  }
  return found.filter((v) => SEMVER_RE.test(v));
}

/** Version directories cached for this plugin. */
function cachedVersions(pluginsDir, marketplace, pluginName) {
  const dir = path.join(pluginsDir, "cache", marketplace, pluginName);
  let names = [];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  return names.filter((n) => SEMVER_RE.test(n) && isDir(path.join(dir, n)));
}

function newest(versions) {
  let best = null;
  for (const v of versions) if (best === null || compareVersions(v, best) > 0) best = v;
  return best;
}

/**
 * @returns {{running: string|null, plugin: string|null, marketplace: string,
 *            marketplaceVersion: string|null, newestCached: string|null, line: string|null}}
 */
export function checkVersion({ pluginRoot, pluginsDir }) {
  const root = nativePath(pluginRoot);
  const dir = nativePath(pluginsDir);
  const pj = readJson(path.join(root, ".claude-plugin", "plugin.json"));
  const running = typeof pj?.version === "string" ? pj.version : null;
  const plugin = typeof pj?.name === "string" ? pj.name : null;
  const coords = cacheCoordinates(root);
  const marketplace = coords?.marketplace || DEFAULT_MARKETPLACE;
  const result = { running, plugin, marketplace, marketplaceVersion: null, newestCached: null, line: null };
  if (!running || !plugin || !SEMVER_RE.test(running)) return result;

  result.marketplaceVersion = newest(marketplaceVersions(dir, marketplace, plugin));
  // Other cached copies only say something about THIS session when this session runs from the
  // cache. A development checkout next to an old cache is not running the old cache.
  if (coords && coords.plugin === plugin) {
    result.newestCached = newest(cachedVersions(dir, marketplace, plugin));
  }

  const behindMarket = result.marketplaceVersion && compareVersions(running, result.marketplaceVersion) < 0;
  if (!behindMarket) return result;
  const behindCache = result.newestCached && compareVersions(running, result.newestCached) < 0;

  const target = result.marketplaceVersion;
  const where = [
    `the ${marketplace} marketplace clone has ${result.marketplaceVersion}`,
    behindCache ? `${result.newestCached} is already in the plugin cache` : null,
  ]
    .filter(Boolean)
    .join(" and ");
  result.line =
    `PLUGIN OUT OF DATE: this session runs ${plugin} ${running} but ${where}, so hooks, gates and agent contracts are ${running}'s. ` +
    `Update to ${target}: /plugin marketplace update ${marketplace}, then /plugin update ${plugin}@${marketplace}, then restart the session.`;
  return result;
}

function argValue(argv, flag) {
  const i = argv.indexOf(flag);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
}

function main(argv) {
  const pluginRoot = argValue(argv, "--plugin-root") || process.env.CLAUDE_PLUGIN_ROOT || path.resolve(SCRIPT_DIR, "..");
  const configDir = process.env.CLAUDE_CONFIG_DIR ? nativePath(process.env.CLAUDE_CONFIG_DIR) : path.join(homedir(), ".claude");
  const pluginsDir = argValue(argv, "--plugins-dir") || path.join(configDir, "plugins");
  const r = checkVersion({ pluginRoot, pluginsDir });
  if (argv.includes("--json")) {
    console.log(JSON.stringify(r));
    return;
  }
  if (r.line) console.log(r.line);
}

if (isMain("version-check.mjs")) {
  try {
    main(process.argv.slice(2));
  } catch {
    /* fail open: a version probe never wedges a session */
  }
  process.exit(0);
}
