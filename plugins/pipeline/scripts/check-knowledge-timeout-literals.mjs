#!/usr/bin/env node
// Reconciles the knowledge store's stated PreToolUse timeout against the value hooks.json
// actually declares, and reports what it COMPARED so a run that compared nothing is not read as
// a pass.
//
// Usage: node check-knowledge-timeout-literals.mjs [--root <dir>]
//
// Output, one TAB-separated line per observation on stdout, plus one summary line:
//
//   COMPARED       <file-relative-to-root>  <literal-as-written>  ok|MISMATCH
//   ADEQUACY       <file-relative-to-root>  present|absent
//   RESIDUAL       <file-relative-to-root>  present|absent
//   COMPARED-COUNT <n>
//
// Exit 0 when every COMPARED line is `ok` AND no qualifying file carries ADEQUACY present with
// RESIDUAL absent. Non-zero otherwise.
//
// -------------------------------------------------------------------------------------------
// THE ANCHOR IS THE SUBJECT, NEVER THE PHRASE, AND THAT IS THE WHOLE DESIGN.
//
// The record this exists to watch says today: "with a 5-SECOND timeout (not 5000ms -- the
// declaration is genuinely tiny against the platform's 600s default)". Anchoring on that
// parenthetical would pass every test written against today's tree and then die: the Librarian
// pass this issue REQUIRES rewrites that exact sentence, after which the pattern matches nothing,
// the compared count falls to zero, and the check reports success forever after against a record
// it is no longer reading -- an assertion outliving its own premise, shipped inside the change
// that removes the premise.
//
// So a sentence qualifies by carrying all THREE subject terms (this hook, the word timeout, a
// declaration term), and any honest rewrite of a sentence about this hook's declared timeout
// still carries all three.
//
// COMPARING NOTHING IS NOT AN ERROR, AND SAYING SO IS THE POINT. A record is allowed to stop
// stating the number; what is refused is a run that compared nothing and looks identical to a run
// that compared one and agreed. That is what COMPARED-COUNT is for.
// -------------------------------------------------------------------------------------------

import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HOOKS_REL = "plugins/pipeline/hooks/hooks.json";
const STORE_REL = "knowledge/living-context";

// A sentence is about THIS hook's declared timeout only when all three are present.
const SUBJECT_HOOK = /pre-?tool-?use/i;
const SUBJECT_TIMEOUT = /timeouts?/i;
const SUBJECT_DECLARED = /declar/i;

// Every number carrying a time unit inside a qualifying sentence is a CANDIDATE literal. Longest
// alternatives first, so `milliseconds` is not read as `m` + `s`.
const LITERAL = /(?<![\w.])(\d+(?:\.\d+)?)[ \t-]*(milliseconds?|seconds?|msec|ms|s)\b/gi;

// WHICH SUBJECT A CANDIDATE BELONGS TO IS DECIDED BY PROXIMITY, NOT BY A BLOCKLIST OF SPELLINGS.
// The qualifying sentence legitimately carries figures about OTHER subjects -- the platform's own
// 600s default sits in the same sentence as the declaration -- and a check that reddened on those
// would refuse the correct work of recording them at all. Each candidate is attributed to whichever
// subject term is NEAREST to it in the sentence; only the ones nearest to `timeout` are compared.
const OWN_SUBJECT = /timeouts?/gi;
const OTHER_SUBJECT = /\b(default|platform|ceiling|margin|budget|baseline|cold start|elapsed|interval|window)\b/gi;

// An ADEQUACY statement frames the declaration's SIZE as comfortable. It is claim drift rather
// than value drift, so it is read over words rather than numbers.
const ADEQUACY = /\b(tiny|small|generous|ample|plenty|comfortabl\w*|conservative|roomy|sufficient|adequate|more than enough|well (?:under|below|within))\b/i;

// The RESIDUAL is the fail-open direction: a large enough command outruns the declaration, the
// hook is killed, and it emits nothing. Both halves are required, because either alone is a
// sentence the record already carries about a different failure (a crashing gate).
const RESIDUAL_SIZE = /(outrun\w*|exceed\w*|larger than|too large|large enough|still crosses|past that point)/i;
const RESIDUAL_OPEN = /(fails? open|failing open|emits? nothing|produces? nothing|killed)/i;

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

function defaultRoot() {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(here, "..", "..", "..");
}

// Paragraph first, then sentence. A single split on `[.!?]\s` would join two paragraphs whenever
// the first ends without punctuation, and a joined paragraph is how an unrelated measurement gets
// read into the declaration's own sentence.
function sentences(text) {
  return String(text)
    .split(/\n+/)
    .flatMap((p) => p.split(/(?<=[.!?])\s+/))
    .map((s) => s.trim())
    .filter(Boolean);
}

function strings(value, out = []) {
  if (typeof value === "string") out.push(value);
  else if (Array.isArray(value)) for (const v of value) strings(v, out);
  else if (value && typeof value === "object") for (const v of Object.values(value)) strings(v, out);
  return out;
}

function nearest(sentence, re, at) {
  re.lastIndex = 0;
  let best = Infinity;
  for (let m = re.exec(sentence); m; m = re.exec(sentence)) {
    const start = m.index;
    const end = m.index + m[0].length;
    const d = at < start ? start - at : at > end ? at - end : 0;
    if (d < best) best = d;
  }
  return best;
}

function declaredSeconds(root) {
  const raw = JSON.parse(readFileSync(path.join(root, HOOKS_REL), "utf8"));
  const entry = raw?.hooks?.PreToolUse?.[0]?.hooks?.[0];
  const t = Number(entry?.timeout);
  if (!Number.isFinite(t) || t <= 0) throw new Error(`no positive PreToolUse timeout in ${HOOKS_REL}`);
  return t;
}

function expectedFor(unit, seconds) {
  return /^(ms|msec|millisecond)/i.test(unit) ? seconds * 1000 : seconds;
}

function main() {
  const root = path.resolve(arg("--root", defaultRoot()));
  const seconds = declaredSeconds(root);

  const dir = path.join(root, STORE_REL);
  let files = [];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
  } catch {
    files = [];
  }

  const lines = [];
  let compared = 0;
  let mismatched = 0;
  let claimDrift = 0;

  for (const file of files) {
    const rel = `${STORE_REL}/${file}`;
    let record;
    try {
      record = JSON.parse(readFileSync(path.join(dir, file), "utf8"));
    } catch {
      continue;
    }
    // The population is `status: current`, derived here rather than spelled: a check that read
    // every record regardless of status would refuse correct work on every superseded one.
    if (String(record?.status || "").toLowerCase() !== "current") continue;

    const all = strings(record).flatMap(sentences);
    const qualifying = all.filter(
      (s) => SUBJECT_HOOK.test(s) && SUBJECT_TIMEOUT.test(s) && SUBJECT_DECLARED.test(s),
    );
    if (qualifying.length === 0) continue;

    for (const sentence of qualifying) {
      LITERAL.lastIndex = 0;
      for (let m = LITERAL.exec(sentence); m; m = LITERAL.exec(sentence)) {
        const at = m.index;
        if (nearest(sentence, OWN_SUBJECT, at) > nearest(sentence, OTHER_SUBJECT, at)) continue;
        const expected = expectedFor(m[2], seconds);
        const ok = Number(m[1]) === expected;
        compared += 1;
        if (!ok) mismatched += 1;
        lines.push(`COMPARED\t${rel}\t${m[0]}\t${ok ? "ok" : "MISMATCH"}`);
      }
    }

    const adequacy = qualifying.some((s) => ADEQUACY.test(s));
    const residual = all.some(
      (s) =>
        (SUBJECT_TIMEOUT.test(s) || SUBJECT_DECLARED.test(s)) &&
        RESIDUAL_SIZE.test(s) &&
        RESIDUAL_OPEN.test(s),
    );
    lines.push(`ADEQUACY\t${rel}\t${adequacy ? "present" : "absent"}`);
    lines.push(`RESIDUAL\t${rel}\t${residual ? "present" : "absent"}`);
    if (adequacy && !residual) claimDrift += 1;
  }

  lines.push(`COMPARED-COUNT\t${compared}`);
  process.stdout.write(`${lines.join("\n")}\n`);
  process.exit(mismatched > 0 || claimDrift > 0 ? 1 : 0);
}

main();
