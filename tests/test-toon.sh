#!/usr/bin/env bash
# toon.mjs (C2): the TOON encoder used for data in agent prompts. Artifacts stay JSON; this pins the
# encoded SHAPES a prompt relies on (tabular header, inline list, list items), the quoting rules
# that keep a cell from reading as a number, boolean, null, a second field or a key, and a
# round trip through the test-aid decoder for the subset the renderers emit.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

TOON="$SCRIPTS_DIR/toon.mjs"
make_temp_project || exit 90

# js <expression using m (the module)> -> stdout
js() {
  MOD="$TOON" EXPR="$1" node --input-type=module -e '
const m = await import(process.env.MOD);
const r = await eval(process.env.EXPR);
process.stdout.write(typeof r === "string" ? r : JSON.stringify(r));
'
}

suite "toon: shapes"

assert_eq "a uniform array of objects is ONE header plus one row per item" \
  "$(js 'm.encode({items:[{id:"qa-1",severity:"high",merge_class:"wrong-pass"},{id:"qa-2",severity:"nit",merge_class:"none"}]})')" \
  "items[2]{id,severity,merge_class}:
  qa-1,high,wrong-pass
  qa-2,nit,none"
assert_eq "an array of primitives is inline with its length" "$(js 'm.encode({tags:["a","b","c"]})')" "tags[3]: a,b,c"
assert_eq "an empty array still carries its length" "$(js 'm.encode({tags:[]})')" "tags[0]:"
assert_eq "nested objects indent two spaces" "$(js 'm.encode({a:{b:{c:1}},d:true})')" "a:
  b:
    c: 1
d: true"
assert_eq "objects whose keys differ are NOT tabular; they become list items" \
  "$(js 'm.encode({xs:[{a:1},{b:2,c:3}]})')" "xs[2]:
  - a: 1
  - b: 2
    c: 3"
assert_eq "an object with a nested value is NOT tabular" "$(js 'm.encode({xs:[{a:1,b:{c:2}}]})')" "xs[1]:
  - a: 1
    b:
      c: 2"
assert_eq "a mixed array lists primitives, arrays and objects" "$(js 'm.encode({xs:[1,[2,3],{k:"v"}]})')" "xs[3]:
  - 1
  - [2]: 2,3
  - k: v"
assert_eq "a root table has no key" "$(js 'm.encode([{a:1,b:2},{a:3,b:4}])')" "[2]{a,b}:
  1,2
  3,4"
assert_eq "a root primitive is itself" "$(js 'm.encode("plain")')" "plain"
assert_eq "a pipe delimiter is declared in the header" "$(js 'm.encode({r:[{a:"x,y",b:1}]},{delimiter:"|"})')" "r[1|]{a|b}:
  x,y|1"

suite "toon: quoting edge cases"

q() { js "m.encode({v: $1})"; }
assert_eq "a plain string is bare" "$(q '"hello world"')" "v: hello world"
assert_eq "a string containing the delimiter is quoted" "$(js 'm.encode({t:["a,b","c"]})')" 't[2]: "a,b",c'
assert_eq "a string containing a colon-space is quoted" "$(q '"key: value"')" 'v: "key: value"'
assert_eq "any colon is quoted (spec rule; header states the deviation from colon-space)" "$(q '"2026-01-01T00:00:00Z"')" 'v: "2026-01-01T00:00:00Z"'
assert_eq "leading space is quoted" "$(q '" pad"')" 'v: " pad"'
assert_eq "trailing space is quoted" "$(q '"pad "')" 'v: "pad "'
assert_eq "a newline is quoted and escaped" "$(q '"a\nb"')" 'v: "a\nb"'
assert_eq "a tab and a CR are escaped" "$(q '"a\tb\rc"')" 'v: "a\tb\rc"'
assert_eq "a double quote and a backslash are escaped" "$(q '"say \"hi\" \\ ok"')" 'v: "say \"hi\" \\ ok"'
assert_eq "a number-looking string is quoted" "$(q '"42"')" 'v: "42"'
assert_eq "a decimal-looking string is quoted" "$(q '"-3.5"')" 'v: "-3.5"'
assert_eq "an exponent-looking string is quoted" "$(q '"1e5"')" 'v: "1e5"'
assert_eq "a leading-zero string is quoted" "$(q '"05"')" 'v: "05"'
assert_eq "CONTROL: a sha that merely starts with a digit is bare" "$(q '"0123abc"')" "v: 0123abc"
assert_eq "true as a string is quoted" "$(q '"true"')" 'v: "true"'
assert_eq "null as a string is quoted" "$(q '"null"')" 'v: "null"'
assert_eq "CONTROL: real booleans and null are bare" "$(js 'm.encode({a:true,b:null})')" "a: true
b: null"
assert_eq "the empty string is quoted" "$(q '""')" 'v: ""'
assert_eq "a leading hyphen is quoted (would read as a list item)" "$(q '"- item"')" 'v: "- item"'
assert_eq "brackets are quoted" "$(q '"a[1]"')" 'v: "a[1]"'
assert_eq "a key that is not an identifier is quoted" "$(js 'm.encode({"a b":1,"x-y":2})')" '"a b": 1
"x-y": 2'
assert_eq "a large number prints without an exponent" "$(q '1e21')" "v: 1000000000000000000000"
assert_eq "a small number prints without an exponent" "$(q '1.5e-7')" "v: 0.00000015"
assert_eq "-0 prints as 0 and NaN as null" "$(js 'm.encode({a:-0,b:NaN})')" "a: 0
b: null"
assert_eq "a table cell with a comma is quoted, its neighbours are not" \
  "$(js 'm.encode({r:[{a:"x, y",b:"z"}]})')" 'r[1]{a,b}:
  "x, y",z'

suite "toon: round trip through the test-aid decoder (tabular subset)"

RT="$(js '
const cases = [
  { items: [{ id: "qa-1", severity: "high", n: 3, ok: true, loc: null }, { id: "qa-2", severity: "a,b", n: -1.25, ok: false, loc: "f.mjs:10" }] },
  { tags: ["x", "05", "true", " sp", "line\nbreak", "q\"b\\s"], nested: { deep: { v: "1e5" } }, empty: {}, none: [] },
  [{ a: "", b: "-" }, { a: "tab\there", b: "{x}" }],
  { list: ["a", "b c"] },
];
const bad = cases.map((c, i) => [i, JSON.stringify(m.decode(m.encode(c))) === JSON.stringify(c)]).filter(([, ok]) => !ok).map(([i]) => i);
bad.length ? "mismatch " + bad.join(",") : "all equal";
')"
assert_eq "encode then decode returns the same JSON for every subset case" "$RT" "all equal"
assert_eq "CONTROL: the decoder refuses a table whose declared length is wrong" \
  "$(js 'try { m.decode("t[3]{a}:\n  1\n  2"); "accepted" } catch (e) { "refused" }')" "refused"
assert_eq "CONTROL: a tampered cell does not round-trip equal" \
  "$(js 'JSON.stringify(m.decode(m.encode({t:[{a:"x"}]}).replace("x","y"))) === JSON.stringify({t:[{a:"x"}]}) ? "equal" : "differs"')" "differs"

suite "toon: CLI"

printf '%s' '{"spec":{"acceptance_criteria":[{"id":"AC1","text":"works"},{"id":"AC2","text":"still works"}]}}' > "$TEMP_PROJECT/in.json"
OUT="$(node "$TOON" "$TEMP_PROJECT/in.json" --path spec.acceptance_criteria)"
assert_eq "--path selects a nested value and encodes it" "$OUT" "[2]{id,text}:
  AC1,works
  AC2,still works"
node "$TOON" "$TEMP_PROJECT/in.json" --path spec.nope >/dev/null 2>&1
assert_eq "a missing --path exits non-zero" "$?" "2"
node "$TOON" >/dev/null 2>&1
assert_eq "no file exits non-zero" "$?" "1"

finish
