#!/usr/bin/env bash
# frontend-surface.mjs — the SINGLE allowlist that decides "is this diff frontend?".
#
# Both the Phase 3->4 frontend gate (halting) and the orchestrator's Design dispatch read this
# list, so a wrong answer here is not a cosmetic bug: too narrow and the gate never fires,
# too wide and the panel halts on a backend-only diff. Config parsing gets the same
# absent/malformed/wrong-typed/empty/valid treatment the hook suite gives its config reader.
#
# Every node invocation below runs with BOTH cwd and CLAUDE_PROJECT_DIR inside a temp dir:
# projectRoot() is `CLAUDE_PROJECT_DIR || cwd`, so pinning only one leaves the other free to
# reach this checkout's own pipeline.config.json.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90
DRIVER="$TEMP_PROJECT/fs-driver.mjs"
cat > "$DRIVER" <<'EOF'
// Thin argv->export bridge so the bash cases read as behavior, not as quoting.
const mod = await import(process.env.FS_MODULE);
const [cmd, a, b] = process.argv.slice(2);
if (cmd === "glob") console.log(String(mod.globToRegExp(a).test(b)));
else if (cmd === "is") console.log(String(mod.isFrontendPath(a)));
else if (cmd === "touches") console.log(String(mod.diffTouchesFrontend(JSON.parse(a))));
else if (cmd === "touches-undefined") console.log(String(mod.diffTouchesFrontend(undefined)));
else { console.error("unknown driver command"); process.exit(2); }
EOF

# fs_run <project-dir> <driver args...>
fs_run() {
  local pdir="$1"; shift
  ( cd "$pdir" && CLAUDE_PROJECT_DIR="$pdir" FS_MODULE="$SCRIPTS_DIR/frontend-surface.mjs" \
      node "$DRIVER" "$@" )
}

# A project root with no pipeline.config.json: the defaults path.
DEFAULTS="$TEMP_PROJECT/defaults"
mkdir -p "$DEFAULTS"

# new_project_root <name> [config-json] -> echoes the dir
new_project_root() {
  local dir="$TEMP_PROJECT/$1"
  mkdir -p "$dir"
  [[ $# -gt 1 ]] && printf '%s' "$2" > "$dir/pipeline.config.json"
  printf '%s' "$dir"
}

suite "frontend-surface: globToRegExp is anchored"

assert_eq "a pattern is anchored at the start" "$(fs_run "$DEFAULTS" glob 'src/*.tsx' 'app/src/a.tsx')" "false"
assert_eq "a pattern is anchored at the end" "$(fs_run "$DEFAULTS" glob '**/*.tsx' 'a/b.tsx.bak')" "false"

suite "frontend-surface: globToRegExp wildcards"

assert_eq '**/ matches zero leading segments' "$(fs_run "$DEFAULTS" glob '**/x.tsx' 'x.tsx')" "true"
assert_eq '**/ matches many leading segments' "$(fs_run "$DEFAULTS" glob '**/x.tsx' 'a/b/c/x.tsx')" "true"
assert_eq 'bare ** crosses separators' "$(fs_run "$DEFAULTS" glob 'src/**' 'src/a/b/c.ts')" "true"
assert_eq '* does not cross a separator' "$(fs_run "$DEFAULTS" glob 'src/*.ts' 'src/a/b.ts')" "false"
assert_eq '* matches within one segment' "$(fs_run "$DEFAULTS" glob 'src/*.ts' 'src/a.ts')" "true"
assert_eq '? matches one non-separator character' "$(fs_run "$DEFAULTS" glob 'a?.ts' 'ab.ts')" "true"
assert_eq '? does not match a separator' "$(fs_run "$DEFAULTS" glob 'a?.ts' 'a/.ts')" "false"

suite "frontend-surface: regex metacharacters are escaped, not interpreted"

assert_eq 'a literal + matches itself' "$(fs_run "$DEFAULTS" glob 'a+b.tsx' 'a+b.tsx')" "true"
assert_eq 'a literal + is not a quantifier' "$(fs_run "$DEFAULTS" glob 'a+b.tsx' 'aab.tsx')" "false"
assert_eq 'a literal . is not any-character' "$(fs_run "$DEFAULTS" glob 'a.tsx' 'axtsx')" "false"
assert_eq 'parens are literal' "$(fs_run "$DEFAULTS" glob 'a(1).tsx' 'a(1).tsx')" "true"

suite "frontend-surface: isFrontendPath normalizes the diff path"

assert_eq "backslash separators are normalized" "$(fs_run "$DEFAULTS" is 'src\components\Card.ts')" "true"
assert_eq "a leading ./ is stripped" "$(fs_run "$DEFAULTS" is './app/Button.tsx')" "true"

suite "frontend-surface: the default surface"

assert_eq ".tsx is frontend" "$(fs_run "$DEFAULTS" is 'app/Button.tsx')" "true"
assert_eq ".jsx is frontend" "$(fs_run "$DEFAULTS" is 'app/Button.jsx')" "true"
assert_eq ".vue is frontend" "$(fs_run "$DEFAULTS" is 'app/App.vue')" "true"
assert_eq ".svelte is frontend" "$(fs_run "$DEFAULTS" is 'app/App.svelte')" "true"
assert_eq "a components/ path is frontend" "$(fs_run "$DEFAULTS" is 'pkg/components/thing.ts')" "true"
assert_eq "a ui/ path is frontend" "$(fs_run "$DEFAULTS" is 'pkg/ui/thing.ts')" "true"
assert_eq "a styles/ path is frontend" "$(fs_run "$DEFAULTS" is 'pkg/styles/main.css')" "true"
assert_eq "a plain .mjs path is NOT frontend" "$(fs_run "$DEFAULTS" is 'plugins/pipeline/scripts/tool.mjs')" "false"
assert_eq "a plain .md path is NOT frontend" "$(fs_run "$DEFAULTS" is 'docs/readme.md')" "false"

suite "frontend-surface: pipeline.config.json overrides, and every bad shape falls back"

OVERRIDE=$(new_project_root cfg-valid '{"frontendSurface":["apps/web/**"]}')
assert_eq "a valid frontendSurface array is honored" "$(fs_run "$OVERRIDE" is 'apps/web/page.ts')" "true"
assert_eq "a valid override REPLACES the defaults" "$(fs_run "$OVERRIDE" is 'pkg/ui/Button.tsx')" "false"

MALFORMED=$(new_project_root cfg-malformed '{"frontendSurface": }')
assert_eq "unparseable JSON falls back to the defaults" "$(fs_run "$MALFORMED" is 'pkg/ui/Button.tsx')" "true"

EMPTY=$(new_project_root cfg-empty '{"frontendSurface":[]}')
assert_eq "an empty array falls back to the defaults" "$(fs_run "$EMPTY" is 'pkg/ui/Button.tsx')" "true"

WRONGTYPE=$(new_project_root cfg-wrongtype '{"frontendSurface":"apps/web/**"}')
assert_eq "a non-array value falls back to the defaults" "$(fs_run "$WRONGTYPE" is 'pkg/ui/Button.tsx')" "true"
assert_eq "a non-array value is not itself used as a glob" "$(fs_run "$WRONGTYPE" is 'apps/web/page.ts')" "false"

BADELEM=$(new_project_root cfg-badelem '{"frontendSurface":["apps/web/**",42]}')
assert_eq "a non-string element falls back to the defaults" "$(fs_run "$BADELEM" is 'pkg/ui/Button.tsx')" "true"

assert_eq "an absent config file falls back to the defaults" "$(fs_run "$DEFAULTS" is 'pkg/ui/Button.tsx')" "true"

suite "frontend-surface: diffTouchesFrontend fail direction"

# The gate reads "no frontend file changed" as SKIP, never as missing evidence, so an empty or
# absent changed-set must be false rather than throwing or defaulting to true.
assert_eq "an empty changed set is not frontend" "$(fs_run "$DEFAULTS" touches '[]')" "false"
assert_eq "an undefined changed set is not frontend" "$(fs_run "$DEFAULTS" touches-undefined)" "false"
assert_eq "a backend-only changed set is not frontend" "$(fs_run "$DEFAULTS" touches '["docs/a.md","src/lib.mjs"]')" "false"
assert_eq "one frontend path in the set is enough" "$(fs_run "$DEFAULTS" touches '["docs/a.md","pkg/ui/x.tsx"]')" "true"

finish
