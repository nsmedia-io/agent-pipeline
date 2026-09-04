#!/usr/bin/env bash
# security-surface.mjs -- the two predicates the Phase 4 DELTA round reads to decide whether
# SecOps and QA re-review a fix. Before it, both re-reviewed unconditionally on every delta
# round. Both directions are pinned: a security path seats SecOps, a docs path does not, config
# can WIDEN the security set and never narrow it, and the match is case-insensitive on the
# security surface (Auth/ and auth/ are one surface) but not on the test surface.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

MOD="$SCRIPTS_DIR/security-surface.mjs"
make_temp_project || exit 90

PROBE="$TEMP_PROJECT/probe.mjs"
cat > "$PROBE" <<'JS'
// probe <fn> <cfg-json> <path...> -> "true"/"false"
const m = await import(process.env.MOD);
const [fn, cfgJson, ...paths] = process.argv.slice(2);
const cfg = JSON.parse(cfgJson);
console.log(String(m[fn](paths, cfg)));
JS
probe() { MOD="$MOD" node "$PROBE" "$@"; }

suite "security surface: what seats SecOps on a delta round"

assert_eq "an auth directory is a security surface" "$(probe diffTouchesSecuritySurface '{}' src/auth/login.ts)" "true"
assert_eq "a capitalized Auth directory is the same surface (lowercased match)" "$(probe diffTouchesSecuritySurface '{}' src/Auth/Login.tsx)" "true"
assert_eq "a session file" "$(probe diffTouchesSecuritySurface '{}' lib/session.ts)" "true"
assert_eq "a webhook handler" "$(probe diffTouchesSecuritySurface '{}' api/stripe-webhook.ts)" "true"
assert_eq "an env file" "$(probe diffTouchesSecuritySurface '{}' .env.production)" "true"
assert_eq "a middleware directory" "$(probe diffTouchesSecuritySurface '{}' src/middleware/cors.ts)" "true"
assert_eq "a password reset flow" "$(probe diffTouchesSecuritySurface '{}' features/account/PasswordReset.vue)" "true"
assert_eq "one security path among many plain ones is enough" \
  "$(probe diffTouchesSecuritySurface '{}' README.md src/ui/Button.tsx src/lib/jwt.ts)" "true"
assert_eq "CONTROL: a docs change is not" "$(probe diffTouchesSecuritySurface '{}' docs/notes.md)" "false"
assert_eq "CONTROL: an ordinary component is not" "$(probe diffTouchesSecuritySurface '{}' src/ui/Button.tsx)" "false"
assert_eq "CONTROL: an empty list is not (the shell probe refuses an empty list separately)" "$(probe diffTouchesSecuritySurface '{}')" "false"
assert_eq "a non-string element is ignored, not a crash" \
  "$(MOD="$MOD" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(m.diffTouchesSecuritySurface([null, 42, "docs/x.md"], {}))')" "false"

suite "security surface: config WIDENS and never narrows"

assert_eq "a configured glob seats SecOps on a path the defaults miss" \
  "$(probe diffTouchesSecuritySurface '{"securitySurfaceGlobs":["**/billing/**"]}' src/billing/charge.ts)" "true"
assert_eq "CONTROL: without the config that path is not a security surface" \
  "$(probe diffTouchesSecuritySurface '{}' src/billing/charge.ts)" "false"
assert_eq "a configured list does NOT replace the defaults: auth still matches" \
  "$(probe diffTouchesSecuritySurface '{"securitySurfaceGlobs":["**/billing/**"]}' src/auth/login.ts)" "true"
assert_eq "an explicit [] means defaults, never seat-nobody" \
  "$(probe diffTouchesSecuritySurface '{"securitySurfaceGlobs":[]}' src/auth/login.ts)" "true"
assert_eq "a malformed config value is ignored, defaults apply" \
  "$(probe diffTouchesSecuritySurface '{"securitySurfaceGlobs":"**/auth/**"}' src/auth/login.ts)" "true"

suite "test surface: what seats QA on a delta round"

assert_eq "a tests/ directory" "$(probe diffTouchesTests '{}' tests/login.test.ts)" "true"
assert_eq "a .spec. file anywhere" "$(probe diffTouchesTests '{}' src/lib/parse.spec.ts)" "true"
assert_eq "a __tests__ directory" "$(probe diffTouchesTests '{}' src/__tests__/x.js)" "true"
assert_eq "a pytest module" "$(probe diffTouchesTests '{}' app/test_models.py)" "true"
assert_eq "a fixtures directory" "$(probe diffTouchesTests '{}' plugins/pipeline/tests/fixtures/x.mjs)" "true"
assert_eq "CONTROL: source only does not seat QA" "$(probe diffTouchesTests '{}' src/lib/parse.ts)" "false"
assert_eq "CONTROL: a file merely NAMED test in a word does not" "$(probe diffTouchesTests '{}' src/contest/entry.ts)" "false"

finish
