#!/usr/bin/env bash
# Windows (Git Bash) path handling: lib.mjs nativePath, and the suite's ESM resolver shim.
#
# Both are pure string rewrites, so every row runs on every platform: the win32 branch is
# reached by injecting the platform (nativePath) or by calling the exported mapper directly
# (fixtures/windows-esm-paths.mjs), never by needing a Windows host. Each rewrite row has a
# CONTROL showing the same input untouched where the rewrite must not apply.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

LIB="$SCRIPTS_DIR/lib.mjs"
SHIM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/windows-esm-paths.mjs"
# The rows below switch off Git Bash's argv rewrite so the LITERAL spellings reach node, which also
# stops the rewrite of these two module paths; hand node their native spelling up front.
if command -v cygpath >/dev/null 2>&1; then LIB="$(cygpath -m "$LIB")"; SHIM="$(cygpath -m "$SHIM")"; fi

# The module paths travel through the environment and are turned into URLs with pathToFileURL,
# the rule the shim exists to apply, so this suite does not depend on the shim to load its subject.
native() { LIB="$LIB" node --input-type=module -e '
  const { pathToFileURL } = await import("node:url");
  const { nativePath } = await import(pathToFileURL(process.env.LIB).href);
  console.log(nativePath(process.argv[1], process.argv[2]));' "$1" "$2"; }

suite "nativePath: MSYS drive paths on win32 only"

assert_eq "win32: /c/Users/x becomes C:/Users/x" "$(MSYS_NO_PATHCONV=1 native /c/Users/x win32)" "C:/Users/x"
assert_eq "win32: a bare drive /d becomes D:/" "$(MSYS_NO_PATHCONV=1 native /d win32)" "D:/"
assert_eq "CONTROL: linux leaves /c/Users/x alone" "$(MSYS_NO_PATHCONV=1 native /c/Users/x linux)" "/c/Users/x"
assert_eq "CONTROL: win32 leaves a multi-letter first segment alone" "$(MSYS_NO_PATHCONV=1 native /tmp/x win32)" "/tmp/x"
assert_eq "CONTROL: win32 leaves a Windows path alone" "$(native 'C:\Users\x' win32)" 'C:\Users\x'

suite "windows-esm-paths shim: every spelling bash hands node becomes a file URL"

map() { SHIM="$SHIM" PIPELINE_MSYS_TMP="C:/Users/u/AppData/Local/Temp" PIPELINE_MSYS_ROOT="C:/Program Files/Git/" node --input-type=module -e '
  const { pathToFileURL } = await import("node:url");
  const m = await import(pathToFileURL(process.env.SHIM).href);
  console.log(String(m.toFileUrl(process.argv[1])));' "$1"; }
export MSYS_NO_PATHCONV=1
# pathToFileURL is platform-aware, so the expected prefix differs by host; the drive part is what
# the rows pin.
assert_contains "C:/x (Git Bash's argv rewrite) maps to a C: file URL" "$(map C:/Users/u/m.mjs)" "C:/Users/u/m.mjs"
assert_contains "file:///c/x maps to a C: file URL" "$(map file:///c/Users/u/m.mjs)" "C:/Users/u/m.mjs"
assert_contains "/c/x maps to a C: file URL" "$(map /c/Users/u/m.mjs)" "C:/Users/u/m.mjs"
assert_contains "/tmp/x maps through the Git Bash tmp mount" "$(map /tmp/tmp.1/m.mjs)" "AppData/Local/Temp/tmp.1/m.mjs"
assert_contains "/usr/x maps through the Git Bash root mount" "$(map /usr/lib/m.mjs)" "Program%20Files/Git/usr/lib/m.mjs"
assert_eq "CONTROL: a relative specifier is left to the default resolver" "$(map ./lib.mjs)" "null"
assert_eq "CONTROL: a bare package specifier is left alone" "$(map node:fs)" "null"
unset MSYS_NO_PATHCONV

suite "the shim is preloaded on Git Bash only"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    assert_contains "on this Windows host NODE_OPTIONS preloads the shim" "${NODE_OPTIONS:-}" "windows-esm-paths.mjs"
    assert_eq "and a module under test loads through import(<C:/ path>)" \
      "$(MOD="$LIB" node --input-type=module -e 'const m = await import(process.env.MOD); console.log(typeof m.isMain)')" "function" ;;
  *)
    assert_not_contains "on this non-Windows host NODE_OPTIONS does not carry the shim" "${NODE_OPTIONS:-}" "windows-esm-paths.mjs"
    record "the Windows-only import row is not applicable on $(uname -s)" ;;
esac

finish
