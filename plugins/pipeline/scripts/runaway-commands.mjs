#!/usr/bin/env node
/**
 * runaway-commands.mjs — which Bash commands leave a process behind that nothing will ever reap?
 *
 * WHY. A Bash command that outlives the tool's timeout is moved to the background, and nothing
 * reaps it; a sub-agent that finishes leaves its background commands running. On the owner's
 * Windows host (2026-10-02, the Rome project) one orchestrator session's sub-agents had left five
 * `python3 - <<'E' ... E` stdin stubs spinning at 5-6% CPU each (the oldest at 24.6 CPU-hours) and
 * four `until grep -q "^exit" <log>; do sleep 10; done` loops waiting on logs from agents that had
 * finished a day earlier. See docs/rationale.md, "Orphaned sub-agent processes".
 *
 * TWO CLASSES, refused for a SUBAGENT's Bash call by hooks/pre-tool-use.sh (the reaper,
 * scripts/reap-orphans.mjs, is the second line for whatever this does not catch):
 *
 *   python-stdin-heredoc   `python3 - <<'E'` (or `python <<E`) on Windows. The Store-alias python
 *                          stub can hang reading stdin and spin; `node -e` or a script file does
 *                          not. Refused on win32 only: on POSIX the construct is fine.
 *   unbounded-wait-loop    `until ...; do sleep N; done` / `while ...; do sleep N; done` with no
 *                          deadline, attempt counter, `timeout`, `break` or `exit` anywhere in it.
 *
 * LOW FALSE POSITIVES BY CONSTRUCTION. A wait loop is refused only when the whole structure is
 * there (a loop keyword at command position, a `do`, a `sleep` in the body, a closing `done`) and
 * NO bound signal appears; anything ambiguous passes, because a missed loop costs one orphan the
 * reaper can still find, while a wrongly refused command costs an agent a retry on every run. A
 * heredoc body that is not fed to a shell (a file being written, a python program) is not scanned
 * for loops: writing a script that contains one is not running one.
 *
 * The decision uses fixed vocabulary only. The deny reason never carries command text.
 *
 * CLI (what the hook runs): reads the command on STDIN (never argv: a command on a child's argv is
 * published to every local user), prints the PreToolUse deny JSON or nothing, exits 0. Exit 1 is
 * a crash; the hook turns that into an allow with an attribution line.
 *   node runaway-commands.mjs [--cwd <dir>]
 * `runawayCommandGuard: false` in the project's pipeline.config.json turns the refusal off.
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { isMain, nativePath } from "./lib.mjs";

// ---- heredocs ---------------------------------------------------------------------------------

const SHELL_WORD = /(?:^|[\s;&|(){'"`])(?:ba|z|da|k)?sh(?:\.exe)?(?=[\s;&|)}'"`]|$)/;

/**
 * Split a command into its lines, dropping the BODY of every heredoc that is not fed to a shell.
 * A real shell copies a heredoc body verbatim to its terminator line and never reads it as
 * commands, so a body feeding `cat > f`, `python3 -` or `node -` is data. A body feeding `bash`,
 * `sh`, `zsh`, `source` is a program and is kept.
 *
 * @param {string} command
 * @returns {{ lines: string[], heredocLines: Set<number> }} `lines` holds the kept lines;
 *   `heredocLines` the indexes (into `lines`) of lines that open a heredoc or here-string.
 */
export function splitHeredocs(command) {
  const raw = String(command).replace(/\r\n/g, "\n").split("\n");
  const lines = [];
  const heredocLines = new Set();
  let i = 0;
  while (i < raw.length) {
    const line = raw[i];
    lines.push(line);
    i++;
    // `<<<` is a here-string (one line, no body); `<<-?WORD` opens a heredoc.
    if (/<<</.test(line)) heredocLines.add(lines.length - 1);
    const opens = [...line.matchAll(/<<(-?)\s*(?:'([^']+)'|"([^"]+)"|\\?([A-Za-z_][\w]*))/g)].filter(
      (m) => line[m.index + 2] !== "<",
    );
    if (opens.length === 0) continue;
    heredocLines.add(lines.length - 1);
    const keep = SHELL_WORD.test(line);
    for (const m of opens) {
      const tag = m[2] ?? m[3] ?? m[4];
      const dash = m[1] === "-";
      while (i < raw.length) {
        const body = raw[i];
        i++;
        const cmp = dash ? body.replace(/^\t+/, "") : body;
        if (cmp === tag) break;
        if (keep) lines.push(body);
      }
    }
  }
  return { lines, heredocLines };
}

// ---- python reading its program from a heredoc ------------------------------------------------

// `python`, `python3`, `python3.11`, `python.exe`, optionally behind a path, optionally with the
// harmless single-letter flags, then EITHER a lone `-` (read the program from stdin) OR a
// heredoc / here-string straight away. `-c`, `-m`, a script path and `python3 -V` do not match.
const PYTHON_STDIN = new RegExp(
  "(?:^|[\\s;&|(){`'\"])" +
    "(?:[^\\s;&|(){`'\"]*[\\\\/])?" +
    "python(?:3(?:\\.\\d+)?)?(?:\\.exe)?" +
    "(?:\\s+-[uBsSEIOqvbd]+)*" +
    "(?:\\s+-(?=\\s|$|<)|\\s*(?=<<))",
  "i",
);

// A command that takes a STRING and runs it.
const STRING_EXECUTOR = /(?:^|[\s;&|(){`'"])(?:eval|(?:ba|z|da|k)?sh|su|ssh|sudo|env|timeout|xargs|nohup|time|exec|docker|podman|wsl)(?:\.exe)?(?=[\s'"]|$)/;

/** True when some line runs python with its program on a heredoc or here-string. */
export function pythonReadsHeredoc(command) {
  const { lines, heredocLines } = splitHeredocs(command);
  for (let n = 0; n < lines.length; n++) {
    if (!heredocLines.has(n)) continue;
    const m = PYTHON_STDIN.exec(lines[n]);
    if (!m) continue;
    // `python3 - <<E` inside quotes only RUNS when something executes the string (`bash -c '...'`,
    // `eval '...'`, `ssh host '...'`); `echo 'python3 - <<E'` and `git commit -m "..."` print it.
    if (/['"`]/.test(m[0][0]) && !STRING_EXECUTOR.test(lines[n].slice(0, m.index))) continue;
    // The heredoc must come AFTER the python word on that line (`python3 - <<'E'`); a heredoc
    // feeding some earlier command on the same line (`cat <<E; python3 -`) is not this construct.
    if (/<</.test(lines[n].slice(m.index + m[0].length))) return true;
  }
  return false;
}

// ---- wait loops -------------------------------------------------------------------------------

/**
 * True when the keyword at `idx` stands where a command can start: line start, after a separator
 * or an opening quote/paren/brace/backtick, or after `do`, `then`, `else`, `elif`, `time`.
 */
function atCommandPosition(text, idx) {
  let j = idx - 1;
  while (j >= 0 && (text[j] === " " || text[j] === "\t")) j--;
  if (j < 0) return true;
  if ("\n;&|({'\"`".includes(text[j])) return true;
  return /(?:^|[\s;&|(){'"`])(?:do|then|else|elif|time)$/.test(text.slice(Math.max(0, j - 6), j + 1));
}

const DO_RE = /(?<=[;&\n]\s*)do(?![\w.-])/g;
const DONE_RE = /(?<=(?:[;&|\n({]|\bdo|\bthen|\belse)\s*)done(?![\w.-])/g;

/**
 * Every `until`/`while` loop in `text`, as { kind, header, body, text }. Nesting is followed with
 * a depth count over `do` / `done`; an unterminated loop runs to the end of the text.
 *
 * @param {string} text command text with non-shell heredoc bodies already removed
 */
export function findLoops(text) {
  const loops = [];
  const kw = /(?<![\w.-])(until|while)(?=[\s;(\[!{])/g;
  let m;
  while ((m = kw.exec(text))) {
    if (!atCommandPosition(text, m.index)) continue;
    const afterKw = m.index + m[1].length;
    DO_RE.lastIndex = afterKw;
    const d = DO_RE.exec(text);
    if (!d) continue;
    const header = text.slice(afterKw, d.index).replace(/[;&\n]\s*$/, "");
    const bodyStart = d.index + 2;
    const events = [];
    for (const [re, tag] of [[DO_RE, "do"], [DONE_RE, "done"]]) {
      re.lastIndex = bodyStart;
      let e;
      while ((e = re.exec(text))) events.push({ at: e.index, tag });
    }
    events.sort((a, b) => a.at - b.at);
    let depth = 1;
    let end = text.length;
    for (const e of events) {
      depth += e.tag === "do" ? 1 : -1;
      if (depth === 0) {
        end = e.at;
        break;
      }
    }
    loops.push({
      kind: m[1],
      header,
      body: text.slice(bodyStart, end),
      text: text.slice(m.index, Math.min(text.length, end + 4)),
    });
  }
  return loops;
}

const SLEEP_RE = /(?<![\w.-])u?sleep(?![\w.-])/;

// Anything here means the author thought about stopping. Deliberately generous: a bound that is
// really a data comparison (`[ $(wc -l < f) -ge 10 ]`) still passes, because the cost of letting
// it through is one reapable orphan and the cost of refusing it is a wrongly blocked agent.
const BOUND_ANYWHERE = [
  /\$\{?SECONDS\b|\bSECONDS=/,
  /(?<![\w.-])date(?![\w.-])/,
  /(?<![\w.-])timeout(?![\w.-])/,
  /\$\(\(|\(\(|(?<![\w.-])(?:let|expr|seq|bc)(?![\w.-])/,
  /\s-(?:lt|le|gt|ge)\s/,
  /\b(?:retr(?:y|ies)|attempts?|tries|deadline|elapsed|max_?\w*|timeout)\b/i,
];
const BOUND_IN_BODY = /(?<![\w.-])(?:break|exit|return)(?![\w.-])/;
const WHOLE_COMMAND_TIMEOUT = /(?:^|[\s;&|(){'"`])timeout(?:\s+-\S+)*\s+\d/;
const CONSUMES_INPUT = /^\s*(?:IFS=\S*\s+)?read\b|^\s*getopts\b/;

/** True when a loop (from `findLoops`) waits on something with no bound of any kind. */
export function isUnboundedWait(loop, wholeText = "") {
  if (!SLEEP_RE.test(loop.body)) return false;
  if (CONSUMES_INPUT.test(loop.header)) return false;
  if (WHOLE_COMMAND_TIMEOUT.test(wholeText)) return false;
  const all = `${loop.header}\n${loop.body}`;
  if (BOUND_ANYWHERE.some((re) => re.test(all))) return false;
  if (BOUND_IN_BODY.test(loop.body)) return false;
  return true;
}

/**
 * The unbounded wait loops in a command (or in a process's command line), each as the loop from
 * `findLoops`. Non-shell heredoc bodies are not scanned.
 */
export function findUnboundedWaitLoops(command) {
  const { lines } = splitHeredocs(command);
  const text = lines.join("\n");
  return findLoops(text).filter((l) => isUnboundedWait(l, text));
}

/**
 * File paths a wait-loop header polls, as written: tokens that look like a path. `resolvable` is
 * false for a token that needs shell expansion we cannot do (`$LOG`, a relative path, a glob).
 *
 * @param {string} header the text between `until`/`while` and `do`
 * @returns {{ token: string, resolvable: boolean }[]}
 */
export function polledPaths(header) {
  const out = [];
  for (let tok of header.split(/\s+/)) {
    tok = tok.replace(/^[\\"'`(\[]+|[\\"'`;)\]]+$/g, "");
    if (!tok || tok.startsWith("-") || tok.startsWith("^") || tok === "!") continue;
    if (!/[\\/]/.test(tok) && !/^~/.test(tok)) continue;
    if (/^[a-z]+:\/\//i.test(tok)) continue;
    const absolute = /^(?:~|\/|[A-Za-z]:[\\/])/.test(tok);
    out.push({ token: tok, resolvable: absolute && !/[$*?`]/.test(tok) });
  }
  return out;
}

// ---- the decision -----------------------------------------------------------------------------

const REASONS = {
  "python-stdin-heredoc":
    "Refused: `python3 -` / `python <<` reading its program from a heredoc on stdin. On Windows the " +
    "Store-alias python stub can hang reading stdin and spin forever at 5-6% CPU, and nothing reaps " +
    "it after your Bash call returns, so it keeps burning the owner's machine long after you are " +
    "done. Instead: `node -e '<code>'` (or `node script.mjs`); or write the program to a file with " +
    "your file tool and run `python3 path/to/script.py`; or `python3 -c '<one-liner>'`.",
  "unbounded-wait-loop":
    "Refused: an unbounded wait loop (`until`/`while` ... `do sleep ...; done` with no deadline, " +
    "attempt count, `timeout`, `break` or `exit`). If the awaited condition never becomes true (the " +
    "producer finished or crashed first) it spins forever; a command that outlives the Bash tool's " +
    "timeout is moved to the background and nothing reaps it, so it keeps burning CPU after you " +
    "finish. Instead: bound it (`for i in $(seq 1 60); do <check> && break; sleep 5; done`, or " +
    "`timeout 300 bash -c 'until <check>; do sleep 5; done'`, or compare `$SECONDS` / `date +%s` " +
    "against a deadline), or run the producer in the foreground, or start it with " +
    "run_in_background and read its output file or use the Monitor tool instead of polling in a " +
    "shell loop.",
};

/**
 * @param {string} command
 * @param {{ platform?: string }} [opts]
 * @returns {{ kind: "python-stdin-heredoc" | "unbounded-wait-loop", reason: string } | null}
 */
export function classifyRunawayCommand(command, opts = {}) {
  const platform = opts.platform ?? process.env.PIPELINE_RUNAWAY_PLATFORM ?? process.platform;
  const cmd = String(command ?? "");
  if (platform === "win32" && /python/i.test(cmd) && cmd.includes("<<") && pythonReadsHeredoc(cmd)) {
    return { kind: "python-stdin-heredoc", reason: REASONS["python-stdin-heredoc"] };
  }
  if (/(?:until|while)/.test(cmd) && /sleep/.test(cmd) && findUnboundedWaitLoops(cmd).length > 0) {
    return { kind: "unbounded-wait-loop", reason: REASONS["unbounded-wait-loop"] };
  }
  return null;
}

/** The PreToolUse deny object for a decision from `classifyRunawayCommand`. */
export function denyJson(decision) {
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: decision.reason,
    },
  });
}

/** `runawayCommandGuard` from the project's config; true (on) unless it is exactly `false`. */
export function guardEnabled(projectDir) {
  try {
    const cfg = JSON.parse(readFileSync(path.join(nativePath(projectDir), "pipeline.config.json"), "utf8"));
    return !(cfg && typeof cfg === "object" && cfg.runawayCommandGuard === false);
  } catch {
    return true;
  }
}

function readStdin() {
  try {
    return readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

function main(argv) {
  let cwd = process.env.CLAUDE_PROJECT_DIR || "";
  const i = argv.indexOf("--cwd");
  if (i !== -1 && argv[i + 1]) cwd = argv[i + 1];
  const command = readStdin();
  const decision = classifyRunawayCommand(command);
  if (!decision) return 0;
  if (cwd && !guardEnabled(cwd)) {
    process.stderr.write("agent-pipeline PreToolUse: runawayCommandGuard is false in pipeline.config.json; nothing enforced.\n");
    return 0;
  }
  process.stdout.write(denyJson(decision));
  process.stderr.write(`agent-pipeline PreToolUse: refused a runaway command for a subagent (${decision.kind}).\n`);
  return 0;
}

if (isMain("runaway-commands.mjs")) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`runaway-commands: ${e && e.message ? e.message : e}\n`);
    process.exitCode = 1;
  }
}
