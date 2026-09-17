/**
 * windows-esm-paths.mjs: lets the suite's `import(<path>)` calls resolve under Git Bash on Windows.
 *
 * Preloaded by harness.sh through NODE_OPTIONS=--import, and ONLY when `uname -s` says MINGW,
 * MSYS or CYGWIN. On Linux and macOS it is never loaded, so it cannot change what those
 * platforms measure.
 *
 * THE ROOT CAUSE. Roughly a hundred call sites across the suites load a module under test with
 * `await import(process.argv[1])`, `import(process.env.MOD)` or `import("$DIR/x.mjs")`. On
 * POSIX an absolute path is also a valid relative URL, so all three work. On Windows none does:
 *   - Git Bash rewrites an argument or environment value `/c/Users/x` to `C:/Users/x` before
 *     node sees it, and the ESM loader reads `C:` as a URL scheme
 *     (ERR_UNSUPPORTED_ESM_URL_SCHEME, "Received protocol 'c:'");
 *   - a path interpolated into JS source is not rewritten at all, so `"file://$DIR/x.mjs"`
 *     becomes `file:///c/Users/x.mjs`, which is not an absolute Windows file URL
 *     (ERR_INVALID_FILE_URL_PATH), and a bare `/tmp/tmp.X/x.mjs` resolves against the current
 *     drive root (C:\tmp\...), which does not exist.
 * The per-site fix is `pathToFileURL(p).href`; this hook applies that one rule at the resolver
 * instead of at every site, so the suites keep a single spelling on every platform.
 *
 * WHAT IT DOES NOT COVER. The plugin's shipped scripts do not `import()` a path (grep for
 * `import(` under plugins/pipeline/scripts finds none), so consumer hooks never needed this and
 * are not helped by it. Assertions that compare a POSIX path string with a script's native
 * `C:\...` output, and fixtures that stub a CLI with a bash script node cannot spawn, are
 * separate causes and are left red on Windows by this file.
 *
 * Mount table: harness.sh exports PIPELINE_MSYS_TMP (`cygpath -m /tmp`) and PIPELINE_MSYS_ROOT
 * (`cygpath -m /`) so a bare `/tmp/...` or `/usr/...` specifier maps the way Git Bash maps it.
 */
import * as nodeModule from "node:module";
import { pathToFileURL } from "node:url";

const TMP = process.env.PIPELINE_MSYS_TMP || "";
const ROOT = process.env.PIPELINE_MSYS_ROOT || "";

export function toFileUrl(specifier) {
  if (typeof specifier !== "string") return null;
  // C:/x or C:\x
  if (/^[A-Za-z]:[\\/]/.test(specifier)) return pathToFileURL(specifier).href;
  // file:///c/x (an MSYS path glued to file://)
  let m = /^file:\/\/\/([A-Za-z])\/(.*)$/.exec(specifier);
  if (m) return pathToFileURL(`${m[1].toUpperCase()}:/${decodeURI(m[2])}`).href;
  // file:///tmp/x or file:///usr/x
  m = /^file:\/\/(\/(?![A-Za-z]:).*)$/.exec(specifier);
  if (m) return msysAbsolute(decodeURI(m[1]));
  // /c/x, /tmp/x, /usr/x
  if (specifier.startsWith("/") && !specifier.startsWith("//")) return msysAbsolute(specifier);
  return null;
}

function msysAbsolute(p) {
  const drive = /^\/([A-Za-z])(\/.*|)$/.exec(p);
  if (drive) return pathToFileURL(`${drive[1].toUpperCase()}:${drive[2] || "/"}`).href;
  if (TMP && (p === "/tmp" || p.startsWith("/tmp/"))) return pathToFileURL(TMP + p.slice(4)).href;
  if (ROOT) return pathToFileURL(ROOT.replace(/\/$/, "") + p).href;
  return null;
}

function resolveHook(specifier, context, nextResolve) {
  // registerHooks also sees require(). CommonJS resolves C:/ and /c/ paths itself (Git Bash has
  // already rewritten argv and env), and it refuses a file URL, so require is passed through.
  if (context?.conditions?.includes("require")) return nextResolve(specifier, context);
  const fixed = toFileUrl(specifier);
  return nextResolve(fixed ?? specifier, context);
}

// Synchronous in-thread hooks (node >= 22.15). Older node gets no hook, and the Windows rows that
// need it stay red rather than running under a worker-thread loader this file does not test.
if (typeof nodeModule.registerHooks === "function") {
  nodeModule.registerHooks({ resolve: resolveHook });
}
