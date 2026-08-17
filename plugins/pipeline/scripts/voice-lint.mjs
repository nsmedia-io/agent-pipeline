#!/usr/bin/env node
/**
 * voice-lint.mjs — Stop-hook check that voice.md was actually honored.
 *
 * WHY THIS EXISTS. voice.md is referenced twelve times in pipeline.md and four in phase.md,
 * and until this script nothing read it. That is evidence.md rule 19 exactly: a written
 * expectation no code reads is a comment. The orchestrator was asked to remember both WHEN a
 * voice moment occurs and WHAT shape it takes, at the end of a long run, with nothing checking
 * either. The trigger half is the more interesting failure: status.json has always known which
 * phase it is in, so "is this a voice moment" never needed to be a judgment call at all. This
 * script derives it.
 *
 * SCOPE, deliberately narrow. It lints ONLY when the active pipeline's current_phase is a
 * known voice moment. Ordinary conversational turns are never linted. That matters because
 * voice.md bans em dashes "anywhere, ever", and a lint that enforced it on every message in
 * every session would be switched off within a day — which is the failure mode that makes a
 * control worthless (evidence.md: ask what your control REFUSES).
 *
 * WHAT IT CANNOT DO. It checks for the SHAPE of voice mode, never the quality. A report can
 * carry every required marker and still be written for a machine. The markers are a floor, not
 * a grade, and the analogy rules, the "explain it twice" rule, and the jargon-gloss rule are
 * not machine-checkable at all. Treat a pass as "the owner-facing scaffolding is present".
 *
 * KNOWN LIMIT, stated rather than hidden (evidence.md rule 19's own trap): a phase NOT in
 * VOICE_MOMENTS is not linted, and an unrecognised phase therefore passes silently. The table
 * is keyed on the phase strings pipeline.md actually writes; if a phase is renamed and the
 * table is not updated, this check goes quiet rather than loud. The companion that would close
 * it is a test asserting every full-voice moment listed in pipeline.md has a table entry, and
 * that test is in tests/test-voice-lint.sh.
 *
 * FAIL-OPEN by contract, exactly like validate-pipeline-artifact.mjs: any missing input,
 * unreadable transcript, unparseable payload or thrown error exits 0 silently. A voice lint
 * that wedges a legitimate stop is worse than no voice lint.
 */

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { isMain as isMainScript } from "./lib.mjs";

const ISSUE_DIR_RE = /^\d+$/;

// current_phase -> what voice.md requires of the message that accompanies it.
// Keys are matched EXACTLY against status.current_phase. Sourced from the checkpoint strings
// pipeline.md writes and the "Full voice mode" list it keeps.
const VOICE_MOMENTS = {
  "1-ba-open-questions": { decision: true, label: "a blocking open question" },
  "2.5-design-owner-decision": { decision: true, label: "the design-lock" },
  "4-veto-rework-required": { scales: true, label: "a SecOps veto" },
  "4-request-changes": { scales: true, label: "a REQUEST_CHANGES panel result" },
  "3-live-verification-required": { label: "the live-verification halt" },
  "5-pr-ready": { scales: true, replication: true, label: "a PR presented as ready to merge" },
  "5-complete": { scales: true, replication: true, label: "the completion report" },
  "halted-error": { label: "a halted run" },
};

// voice.md, "Language rules": these phrases all assume the reader was in the thread.
const BANNED_PHRASES = ["as discussed", "as noted above", "per the spec", "as you know"];

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

/** Newest issue dir holding a status.json, or null. Mirrors the validator's resolution order. */
export function resolveStatus(projectDir, envIssue) {
  const base = path.join(projectDir, ".pipeline");
  if (!existsSync(base)) return null;
  if (envIssue && ISSUE_DIR_RE.test(envIssue)) {
    const s = readJson(path.join(base, envIssue, "status.json"));
    if (s) return s;
  }
  let newest = null;
  let newestMs = -1;
  let entries;
  try {
    entries = readdirSync(base, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const d of entries) {
    if (!d.isDirectory() || !ISSUE_DIR_RE.test(d.name)) continue;
    const f = path.join(base, d.name, "status.json");
    if (!existsSync(f)) continue;
    let ms;
    try {
      ms = statSync(f).mtimeMs;
    } catch {
      continue;
    }
    if (ms > newestMs) {
      newestMs = ms;
      newest = f;
    }
  }
  return newest ? readJson(newest) : null;
}

/** Last assistant text block in a Claude Code JSONL transcript, or "" if none found. */
export function lastAssistantText(transcriptPath) {
  let raw;
  try {
    raw = readFileSync(transcriptPath, "utf8");
  } catch {
    return "";
  }
  const lines = raw.split("\n").filter((l) => l.trim() !== "");
  for (let i = lines.length - 1; i >= 0; i--) {
    let rec;
    try {
      rec = JSON.parse(lines[i]);
    } catch {
      continue;
    }
    if (rec?.type !== "assistant") continue;
    const content = rec?.message?.content;
    if (!Array.isArray(content)) continue;
    const text = content
      .filter((c) => c && c.type === "text" && typeof c.text === "string")
      .map((c) => c.text)
      .join("\n");
    if (text.trim() !== "") return text;
  }
  return "";
}

/**
 * The lint itself, pure and exported so the self-test can drive it without a transcript.
 * Returns an array of human-readable failures; empty means the shape is present.
 */
export function lintVoice(text, moment) {
  const failures = [];
  if (!moment || typeof text !== "string" || text.trim() === "") return failures;

  if (moment.decision && !/^###\s+I need a decision\s*$/m.test(text)) {
    failures.push(
      `this is ${moment.label}, which voice.md says ends with the decision block, and there is no "### I need a decision" heading`,
    );
  }
  if (moment.scales) {
    for (const scale of ["Blast radius", "Reversibility", "Confidence"]) {
      if (!new RegExp(`\\*\\*${scale}:\\*\\*`).test(text)) {
        failures.push(
          `this is ${moment.label}, which carries the rating scales, and "**${scale}:**" is missing`,
        );
      }
    }
  }
  if (moment.replication && !/^###\s+See it yourself\s*$/m.test(text)) {
    failures.push(
      `this is ${moment.label}, and the "### See it yourself" replication block is missing; voice.md calls these steps not optional`,
    );
  }
  // An em dash is the one language rule with no judgment in it: voice.md bans it outright.
  if (/—/.test(text)) {
    failures.push('voice.md bans the em dash outright ("anywhere, ever"); use a comma, colon, or parentheses');
  }
  const lower = text.toLowerCase();
  for (const phrase of BANNED_PHRASES) {
    if (lower.includes(phrase)) {
      failures.push(`"${phrase}" assumes the owner was in the thread; voice.md says they were not`);
    }
  }
  return failures;
}

export function run(payload, projectDir) {
  // Already inside a stop-hook continuation: never block twice, or a stubborn message loops.
  if (payload?.stop_hook_active) return { failures: [], phase: null };
  const status = resolveStatus(projectDir, process.env.CLAUDE_PIPELINE_ACTIVE_ISSUE);
  const phase = status?.current_phase;
  if (!phase) return { failures: [], phase: null };
  const moment = VOICE_MOMENTS[phase];
  if (!moment) return { failures: [], phase }; // not a voice moment (see KNOWN LIMIT above)
  const transcript = payload?.transcript_path;
  if (!transcript) return { failures: [], phase };
  const text = lastAssistantText(transcript);
  if (text.trim() === "") return { failures: [], phase };
  return { failures: lintVoice(text, moment), phase, moment };
}

function main() {
  let payload = null;
  try {
    payload = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    process.exit(0);
  }
  let result;
  try {
    result = run(payload, payload?.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd());
  } catch {
    process.exit(0); // fail open, always
  }
  if (!result.failures.length) process.exit(0);
  const lines = [
    `Stop hook: this message accompanies pipeline phase "${result.phase}", which voice.md treats as a full voice mode moment, and the required shape is not there.`,
    "",
    ...result.failures.map((f) => `- ${f}`),
    "",
    "Read ${CLAUDE_PLUGIN_ROOT}/voice.md and rewrite the message for someone who did not read the diff.",
    "This checks SHAPE only; a message can pass this and still be written for a machine.",
    "To bypass for a one-off: CLAUDE_HOOK_STOP_SKIP=1",
  ];
  process.stderr.write(lines.join("\n") + "\n");
  process.exit(2);
}

// ---- self-test -----------------------------------------------------------
function selfTest() {
  let pass = 0;
  let fail = 0;
  const check = (name, actual, expected) => {
    if (actual === expected) {
      pass++;
      console.log(`  ok   ${name}`);
    } else {
      fail++;
      console.log(`  FAIL ${name}\n       expected ${expected}, got ${actual}`);
    }
  };
  const has = (t, m) => lintVoice(t, m).length > 0;

  const DECISION = VOICE_MOMENTS["2.5-design-owner-decision"];
  const REPORT = VOICE_MOMENTS["5-complete"];

  const goodDecision = "Some prose.\n\n### I need a decision\n\nWhat I'm asking: pick one.";
  check("decision moment with the block passes", has(goodDecision, DECISION), false);
  check("decision moment without the block fails", has("Some prose, no block.", DECISION), true);
  check("a near-miss heading does not satisfy it", has("### I need a decision now", DECISION), true);

  const goodReport =
    "### Done\n\n### See it yourself\n\nsteps\n\n**Blast radius:** Contained\n**Reversibility:** Undo button\n**Confidence:** Solid";
  check("completion report with scales + replication passes", has(goodReport, REPORT), false);
  check(
    "completion report missing Confidence fails",
    lintVoice(goodReport.replace("**Confidence:** Solid", ""), REPORT).some((f) => f.includes("Confidence")),
    true,
  );
  check(
    "completion report missing See it yourself fails",
    lintVoice(goodReport.replace("### See it yourself", "### Try it"), REPORT).some((f) =>
      f.includes("See it yourself"),
    ),
    true,
  );

  check("an em dash fails", has(`${goodDecision}—here`, DECISION), true);
  check("a hyphen does not fail", has(`${goodDecision} well-formed`, DECISION), false);
  check("an en dash does not fail", has(`${goodDecision} 1–2`, DECISION), false);
  check("a banned phrase fails", has(`${goodDecision} As discussed, this is fine.`, DECISION), true);
  check(
    "the banned-phrase check is case-insensitive",
    has(`${goodDecision} AS YOU KNOW, this is fine.`, DECISION),
    true,
  );

  // Non-zero control on the instrument: a moment of null must never produce failures, or the
  // "not a voice moment" path would be blocking silently.
  check("a null moment lints nothing", lintVoice(goodDecision, null).length, 0);
  check("empty text lints nothing", lintVoice("", DECISION).length, 0);

  // The table must cover every phase pipeline.md checkpoints as a full-voice moment. This is
  // the companion for the KNOWN LIMIT: an unrecognised phase passes silently, so the set of
  // recognised phases is asserted from CONFIGURATION, not inferred from what has been seen.
  const required = ["1-ba-open-questions", "2.5-design-owner-decision", "halted-error"];
  for (const r of required) {
    check(`VOICE_MOMENTS covers "${r}"`, Object.prototype.hasOwnProperty.call(VOICE_MOMENTS, r), true);
  }

  console.log(`\nself-test: ${pass} passed, ${fail} failed`);
  return fail === 0;
}

if (isMainScript("voice-lint.mjs")) {
  if (process.argv.includes("--self-test")) process.exit(selfTest() ? 0 : 1);
  main();
}
