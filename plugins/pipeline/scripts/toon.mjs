#!/usr/bin/env node
// TOON (Token-Oriented Object Notation) encoder for PROMPT INPUTS, dependency-free.
//
// Agents still write JSON artifacts and every schema is unchanged. This module exists only so a
// renderer that puts JSON-shaped data into an agent prompt can put it there in fewer tokens: a
// uniform array of objects costs its field names once, in a header, instead of once per item.
//
// What it emits (following the published TOON spec from memory):
//   - objects as indented `key: value` lines, two spaces per level; a nested object is `key:`
//     with its fields one level deeper; an empty object is a bare `key:`;
//   - arrays of primitives inline with a length marker: `tags[3]: a,b,c` (`tags[0]:` when empty);
//   - uniform arrays of objects (every item an object with the same key set and only primitive
//     values) as a tabular block: `items[2]{id,severity,merge_class}:` then one row per item,
//     one level deeper, fields in the first item's key order;
//   - every other array as `key[N]:` followed by `- ` list items one level deeper. An object item
//     puts its first field on the hyphen line and the rest one level deeper; the first field's own
//     children (a nested object or table rows) sit two levels deeper;
//   - a root array uses the same forms with no key (`[3]: a,b,c`); a root primitive is itself.
//   - strings are quoted only when they would otherwise read as something else: empty, leading or
//     trailing whitespace, equal to true/false/null, numeric-looking (including leading zeros
//     such as 05), starting with `-`, or containing the active delimiter, a colon, a double
//     quote, a backslash, a bracket or brace, or a control character. Inside quotes the escapes
//     are \\ \" \n \r \t.
//   - keys are bare when they match ^[A-Za-z_][A-Za-z0-9_.]*$ and quoted otherwise.
//   - numbers are canonical decimals with no exponent (1e21 prints as 1 followed by 21 zeros);
//     -0 prints as 0; NaN and Infinity print as null. Input is first passed through JSON
//     semantics (toJSON, Dates as ISO strings, undefined object fields dropped, undefined array
//     items as null), so the encoding describes exactly the JSON the artifact would hold.
//   - opts.delimiter may be "," (default), "\t" or "|". A non-comma delimiter is declared inside
//     every array header (`[3|]`, `{a|b}`), as the spec does.
//
// Deviations from the spec, stated so nobody mistakes this for a conforming implementation:
//   1. A control character other than \n \r \t is written as \uXXXX inside quotes. The spec
//      names only five escapes; a raw control byte in a prompt is worse than a sixth escape.
//   2. The colon rule quotes a string containing ANY colon, as the spec does, which is stricter
//      than the "colon-space" rule the C2 brief summarised; an ISO timestamp or a Windows path is
//      therefore quoted. Kept strict so a decoder never has to guess where a key ends.
//   3. No key folding (`a.b.c: 1`) and no `[#N]` length-marker prefix; both are optional in the
//      spec and neither is emitted.
//   4. The decoder below is a TEST AID for the subset this plugin emits into prompts (objects,
//      primitives, inline arrays, tabular arrays, lists of primitives). It is not a general TOON
//      parser and nothing in the pipeline decodes TOON at run time.
//
// Usage:
//   node toon.mjs <file.json> [--path a.b.0] [--delimiter comma|tab|pipe]
// prints the TOON encoding of the file (or of the value at the dotted path) on stdout.

import { readFileSync } from "node:fs";
import { isMain } from "./lib.mjs";

const DELIMITERS = { ",": "", "\t": "\t", "|": "|" };
const NUMERIC_LIKE = /^-?\d+(?:\.\d+)?(?:e[+-]?\d+)?$/i;
const LEADING_ZERO = /^-?0\d+(?:\.\d+)?$/;
const BARE_KEY = /^[A-Za-z_][A-Za-z0-9_.]*$/;

/** Encode a JSON-compatible value as TOON text (no trailing newline). */
export function encode(value, opts = {}) {
  const delimiter = opts.delimiter ?? ",";
  if (!(delimiter in DELIMITERS)) throw new Error(`toon: unsupported delimiter ${JSON.stringify(delimiter)}`);
  const indent = opts.indent ?? 2;
  if (!Number.isInteger(indent) || indent < 1) throw new Error("toon: indent must be a positive integer");
  const v = value === undefined ? null : JSON.parse(JSON.stringify(value));
  const ctx = { delimiter, pad: " ".repeat(indent), lines: [] };
  if (isPrimitive(v)) return primitive(v, delimiter);
  if (Array.isArray(v)) encodeArray(null, v, 0, ctx);
  else encodeFields(v, 0, ctx);
  return ctx.lines.join("\n");
}

function isPrimitive(v) {
  return v === null || typeof v !== "object";
}

function push(ctx, depth, text) {
  ctx.lines.push(ctx.pad.repeat(depth) + text);
}

export function formatNumber(n) {
  if (!Number.isFinite(n)) return "null";
  if (Object.is(n, -0)) return "0";
  const s = String(n);
  if (!/e/i.test(s)) return s;
  const [mant, expText] = s.split(/e/i);
  const neg = mant.startsWith("-");
  const [ip, fp = ""] = (neg ? mant.slice(1) : mant).split(".");
  const digits = ip + fp;
  const point = ip.length + Number(expText);
  let out;
  if (point <= 0) out = "0." + "0".repeat(-point) + digits;
  else if (point >= digits.length) out = digits + "0".repeat(point - digits.length);
  else out = digits.slice(0, point) + "." + digits.slice(point);
  return (neg ? "-" : "") + out;
}

export function needsQuotes(s, delimiter = ",") {
  return (
    s === "" ||
    s !== s.trim() ||
    s === "true" ||
    s === "false" ||
    s === "null" ||
    NUMERIC_LIKE.test(s) ||
    LEADING_ZERO.test(s) ||
    s.startsWith("-") ||
    /[:"\\[\]{}]/.test(s) ||
    // eslint-disable-next-line no-control-regex
    /[\u0000-\u001f\u007f]/.test(s) ||
    s.includes(delimiter)
  );
}

function quote(s) {
  let out = '"';
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (ch === "\\") out += "\\\\";
    else if (ch === '"') out += '\\"';
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (c < 0x20 || c === 0x7f) out += "\\u" + c.toString(16).padStart(4, "0");
    else out += ch;
  }
  return out + '"';
}

function primitive(v, delimiter) {
  if (v === null) return "null";
  if (typeof v === "boolean") return String(v);
  if (typeof v === "number") return formatNumber(v);
  const s = String(v);
  return needsQuotes(s, delimiter) ? quote(s) : s;
}

function key(k) {
  return BARE_KEY.test(k) ? k : quote(k);
}

function tabularFields(arr) {
  if (arr.length === 0) return null;
  let fields = null;
  for (const item of arr) {
    if (isPrimitive(item) || Array.isArray(item)) return null;
    const ks = Object.keys(item);
    if (ks.length === 0) return null;
    if (!ks.every((k) => isPrimitive(item[k]))) return null;
    if (fields === null) fields = ks;
    else if (ks.length !== fields.length || !fields.every((f) => Object.prototype.hasOwnProperty.call(item, f))) return null;
  }
  return fields;
}

function header(name, n, fields, delimiter) {
  const d = DELIMITERS[delimiter];
  const f = fields ? `{${fields.map(key).join(delimiter)}}` : "";
  return `${name === null ? "" : key(name)}[${n}${d}]${f}:`;
}

function encodeArray(name, arr, depth, ctx) {
  const { delimiter } = ctx;
  if (arr.length > 0 && arr.every(isPrimitive)) {
    push(ctx, depth, `${header(name, arr.length, null, delimiter)} ${arr.map((x) => primitive(x, delimiter)).join(delimiter)}`);
    return;
  }
  const fields = tabularFields(arr);
  if (fields) {
    push(ctx, depth, header(name, arr.length, fields, delimiter));
    for (const item of arr) push(ctx, depth + 1, fields.map((f) => primitive(item[f], delimiter)).join(delimiter));
    return;
  }
  push(ctx, depth, header(name, arr.length, null, delimiter));
  for (const item of arr) encodeListItem(item, depth + 1, ctx);
}

function encodeFields(obj, depth, ctx) {
  for (const [k, v] of Object.entries(obj)) encodeField(k, v, depth, ctx);
}

function encodeField(k, v, depth, ctx) {
  if (isPrimitive(v)) push(ctx, depth, `${key(k)}: ${primitive(v, ctx.delimiter)}`);
  else if (Array.isArray(v)) encodeArray(k, v, depth, ctx);
  else {
    push(ctx, depth, `${key(k)}:`);
    encodeFields(v, depth + 1, ctx);
  }
}

/** Render lines into a scratch context at `depth`, then hang the first one off a hyphen. */
function hang(depth, ctx, emit) {
  const scratch = { ...ctx, lines: [] };
  emit(scratch);
  const [first, ...rest] = scratch.lines;
  push(ctx, depth, "- " + first.trimStart());
  ctx.lines.push(...rest);
}

function encodeListItem(item, depth, ctx) {
  if (isPrimitive(item)) return push(ctx, depth, `- ${primitive(item, ctx.delimiter)}`);
  if (Array.isArray(item)) return hang(depth, ctx, (s) => encodeArray(null, item, depth, s));
  const entries = Object.entries(item);
  if (entries.length === 0) return push(ctx, depth, "-");
  const [[k0, v0], ...others] = entries;
  hang(depth, ctx, (s) => encodeField(k0, v0, depth + 1, s));
  for (const [k, v] of others) encodeField(k, v, depth + 1, ctx);
}

// ---------------------------------------------------------------------------------------------
// Test-aid decoder for the emitted subset (see deviation 4 in the header).

function splitRow(text, delimiter) {
  const out = [];
  let cur = "";
  let inQ = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQ) {
      cur += ch;
      if (ch === "\\") cur += text[++i] ?? "";
      else if (ch === '"') inQ = false;
    } else if (ch === '"') {
      inQ = true;
      cur += ch;
    } else if (text.startsWith(delimiter, i)) {
      out.push(cur);
      cur = "";
    } else cur += ch;
  }
  out.push(cur);
  return out;
}

function unquote(tok) {
  let out = "";
  for (let i = 1; i < tok.length - 1; i++) {
    const ch = tok[i];
    if (ch !== "\\") {
      out += ch;
      continue;
    }
    const e = tok[++i];
    if (e === "n") out += "\n";
    else if (e === "r") out += "\r";
    else if (e === "t") out += "\t";
    else if (e === "u") {
      out += String.fromCharCode(parseInt(tok.slice(i + 1, i + 5), 16));
      i += 4;
    } else out += e;
  }
  return out;
}

export function parsePrimitive(tok) {
  const t = tok.trim();
  if (t.startsWith('"')) return unquote(t);
  if (t === "null") return null;
  if (t === "true") return true;
  if (t === "false") return false;
  if (NUMERIC_LIKE.test(t) && !LEADING_ZERO.test(t)) return Number(t);
  return t;
}

const HEADER = /^(?:("(?:[^"\\]|\\.)*")|([A-Za-z_][A-Za-z0-9_.]*))?\[(\d+)([\t|]?)\](?:\{([^}]*)\})?:(?: (.*))?$/;

/** Decode the subset encode() emits for prompts. Throws on anything outside it. */
export function decode(text, opts = {}) {
  const indent = opts.indent ?? 2;
  const lines = text.split("\n").filter((l) => l.trim() !== "").map((l) => {
    const n = l.length - l.trimStart().length;
    if (n % indent !== 0) throw new Error(`toon decode: bad indentation: ${l}`);
    return { depth: n / indent, body: l.trimStart() };
  });
  if (lines.length === 0) return {};
  let pos = 0;
  const keyOf = (q, bare) => (q ? unquote(q) : bare);

  function readArray(m, depth) {
    const n = Number(m[3]);
    const delimiter = m[4] || ",";
    if (m[5] !== undefined) {
      const fields = splitRow(m[5], delimiter).map((f) => (f.startsWith('"') ? unquote(f) : f));
      const rows = [];
      while (pos < lines.length && lines[pos].depth === depth + 1) {
        const cells = splitRow(lines[pos++].body, delimiter);
        if (cells.length !== fields.length) throw new Error(`toon decode: row width ${cells.length} != ${fields.length}`);
        rows.push(Object.fromEntries(fields.map((f, i) => [f, parsePrimitive(cells[i])])));
      }
      if (rows.length !== n) throw new Error(`toon decode: table declares ${n} rows, found ${rows.length}`);
      return rows;
    }
    if (m[6] !== undefined) {
      const items = splitRow(m[6], delimiter).map(parsePrimitive);
      if (items.length !== n) throw new Error(`toon decode: inline array declares ${n}, found ${items.length}`);
      return items;
    }
    const items = [];
    while (pos < lines.length && lines[pos].depth === depth + 1 && lines[pos].body.startsWith("- ")) {
      const b = lines[pos++].body.slice(2);
      if (HEADER.test(b) || /^[^"]*: |^"(?:[^"\\]|\\.)*": /.test(b)) throw new Error("toon decode: list items that are objects or arrays are outside the test subset");
      items.push(parsePrimitive(b));
    }
    if (items.length !== n) throw new Error(`toon decode: list declares ${n} items, found ${items.length}`);
    return items;
  }

  function readObject(depth) {
    const obj = {};
    while (pos < lines.length && lines[pos].depth === depth) {
      const { body } = lines[pos];
      const m = HEADER.exec(body);
      if (m && (m[1] || m[2])) {
        pos++;
        obj[keyOf(m[1], m[2])] = readArray(m, depth);
        continue;
      }
      const km = /^(?:("(?:[^"\\]|\\.)*")|([A-Za-z_][A-Za-z0-9_.]*)):(?: (.*))?$/.exec(body);
      if (!km) throw new Error(`toon decode: unsupported line: ${body}`);
      pos++;
      const k = keyOf(km[1], km[2]);
      if (km[3] !== undefined) obj[k] = parsePrimitive(km[3]);
      else obj[k] = pos < lines.length && lines[pos].depth > depth ? readObject(depth + 1) : {};
    }
    return obj;
  }

  const rootArray = HEADER.exec(lines[0].body);
  if (rootArray && !rootArray[1] && !rootArray[2]) {
    pos = 1;
    return readArray(rootArray, 0);
  }
  if (lines.length === 1 && !/^(?:"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_.]*)(?:\[\d+[\t|]?\])?(?:\{[^}]*\})?:(?: |$)/.test(lines[0].body)) {
    return parsePrimitive(lines[0].body);
  }
  const out = readObject(0);
  if (pos !== lines.length) throw new Error(`toon decode: stopped at line ${pos + 1}: ${lines[pos].body}`);
  return out;
}

// ---------------------------------------------------------------------------------------------

export function atPath(value, dotted) {
  if (!dotted) return value;
  let cur = value;
  for (const seg of dotted.split(".")) {
    if (cur === null || typeof cur !== "object" || !(seg in cur)) {
      throw new Error(`--path ${dotted}: no ${JSON.stringify(seg)} at this point`);
    }
    cur = cur[seg];
  }
  return cur;
}

function main(argv) {
  let file = null;
  let dotted = null;
  let delimiter = ",";
  const names = { comma: ",", tab: "\t", pipe: "|" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--path") dotted = argv[++i];
    else if (a === "--delimiter") {
      delimiter = names[argv[++i]];
      if (!delimiter) return fail("--delimiter must be comma, tab or pipe");
    } else if (a.startsWith("--")) return fail(`unknown argument: ${a}`);
    else if (file === null) file = a;
    else return fail(`unexpected argument: ${a}`);
  }
  if (!file) return fail("usage: node toon.mjs <file.json> [--path a.b] [--delimiter comma|tab|pipe]");
  try {
    const value = atPath(JSON.parse(readFileSync(file, "utf8")), dotted);
    process.stdout.write(encode(value, { delimiter }) + "\n");
  } catch (e) {
    return fail(e.message, 2);
  }
}

function fail(msg, code = 1) {
  console.error(`toon: ${msg}`);
  process.exit(code);
}

if (isMain("toon.mjs")) main(process.argv.slice(2));
