#!/usr/bin/env node
/**
 * reap-orphans.mjs — find, and when it is certain, kill, the processes a finished sub-agent left
 * running under THIS session's claude process.
 *
 * WHY. A Bash command that outlives the tool's timeout is moved to the background and nothing
 * reaps it; a sub-agent that finishes leaves its background commands running. On the owner's
 * Windows host (2026-10-02, the Rome project) one session's sub-agents left five `python3 - <<'E'`
 * stdin stubs spinning at 5-6% CPU each (the oldest at 24.6 CPU-hours) and four
 * `until grep -q "^exit" <log>; do sleep 10; done` loops waiting on logs from agents that had
 * finished a day earlier. They tax the host that runs the CI runners, Docker and the agents.
 * hooks/pre-tool-use.sh now refuses the two constructs for a subagent (scripts/runaway-commands.mjs);
 * this is the second line, for whatever that did not catch. See docs/rationale.md, "Orphaned
 * sub-agent processes".
 *
 * WHAT IT TOUCHES, AND THE ORDER OF THE REFUSALS. Run from SessionStart, SubagentStop and Stop.
 * Every one of these must hold before a process is even a CANDIDATE, and a candidate is only
 * KILLED if it also matches the allowlist and nothing says it is live:
 *   1. it is a DESCENDANT of the current session's claude process (the nearest `claude` ancestor
 *      of this hook; the Desktop app's own `claude.exe` and every other session sit outside it).
 *      No such ancestor means nothing is touched. Parent links are trusted only when the parent
 *      is older than the child, so a recycled Windows pid cannot pull a stranger into the tree;
 *   2. it is not the claude process, this hook's own ancestry, or anything on the never-touch list
 *      (Docker, WSL, vmmem, CI runners, MCP servers, preview/dev servers, plus the config's
 *      `protectPatterns`), and none of its ancestors is either;
 *   3. it is older than `minAgeMinutes` AND has accumulated at least `minCpuSeconds` of CPU at an
 *      average of `minCpuPercent` of one core or more over its life ("still accumulating CPU");
 *   4. KILL ONLY: it matches a pattern named in `killPatterns` (a closed set, no user regex):
 *        pythonStdinStub  Windows only: python run with no script argument or just `-`
 *        waitLoop         a shell whose command line holds an UNBOUNDED until/while ... sleep loop
 *                         whose polled file(s) are all older than `staleFileMinutes`. A loop whose
 *                         file cannot be resolved, is missing, or was written recently is reported,
 *                         never killed: something may still be writing it;
 *   5. KILL ONLY: the session transcript (and the transcripts of agents still active) does not show
 *      a background task that is still running and whose command text appears in the process's
 *      command line or its ancestors'. If the transcript cannot be read the python stub is
 *      reported only (it has no evidence of its own); the wait loop's stale-file proof stands alone.
 *   Everything that passes 1-3 and is not killed is REPORTED once (one line, plus the log).
 *
 * The decision is made on one process snapshot and CONFIRMED on a second, immediately before
 * acting, matching pid and start time, so a pid recycled in between is never killed.
 *
 * FAIL-OPEN, EXIT 0 ALWAYS except two cases the hook turns into a disarm line: exit 3 when the
 * process list cannot be read (no PowerShell / ps) and exit 1 on a crash. Nothing here can block
 * a stop or a session start. Off: `orphanReaper.mode` "off" in pipeline.config.json, or
 * CLAUDE_PIPELINE_REAPER=off for one session.
 *
 * CLI (the hooks call this; the payload arrives on stdin):
 *   node reap-orphans.mjs --event SessionStart|SubagentStop|Stop|manual
 *        [--dry-run] [--verbose] [--root-pid N] [--project-dir D]
 * stdout: one summary line when something was killed or newly reported, otherwise nothing.
 * `--dry-run` never kills, ignores the throttle and the already-reported memory, and prints every
 * candidate. `--root-pid` names the root explicitly (manual runs from a terminal outside claude;
 * the hooks never pass it).
 */

import { spawnSync } from "node:child_process";
import {
  appendFileSync,
  closeSync,
  existsSync,
  fstatSync,
  openSync,
  readSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { isMain, nativePath } from "./lib.mjs";
import { findUnboundedWaitLoops, polledPaths } from "./runaway-commands.mjs";

// ---- config -----------------------------------------------------------------------------------

export const KILL_PATTERNS = ["pythonStdinStub", "waitLoop"];

export const DEFAULTS = Object.freeze({
  mode: "kill",
  minAgeMinutes: 60,
  minCpuSeconds: 300,
  minCpuPercent: 1,
  staleFileMinutes: 60,
  minIntervalMinutes: 10,
  killPatterns: KILL_PATTERNS,
  protectPatterns: [],
});

const MODES = new Set(["kill", "report", "off"]);

/**
 * `orphanReaper` from the project's pipeline.config.json merged over DEFAULTS, then the
 * CLAUDE_PIPELINE_REAPER env override for the mode. Anything unusable falls back to its default
 * and is named in `warnings`; a bad value never widens what the reaper does: a number must be a
 * finite non-negative number, a mode must be one of kill/report/off, killPatterns is filtered to
 * the built-in names, and protectPatterns entries that are not valid regexes are dropped.
 */
export function readReaperConfig(projectDir, env = process.env) {
  const cfg = { ...DEFAULTS, killPatterns: [...DEFAULTS.killPatterns], protectPatterns: [] };
  const warnings = [];
  let raw;
  try {
    const parsed = JSON.parse(readFileSync(path.join(nativePath(projectDir || "."), "pipeline.config.json"), "utf8"));
    raw = parsed && typeof parsed === "object" ? parsed.orphanReaper : undefined;
  } catch {
    raw = undefined;
  }
  if (raw !== undefined) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      warnings.push("orphanReaper is not an object; defaults apply");
    } else {
      if (raw.mode !== undefined) {
        if (MODES.has(raw.mode)) cfg.mode = raw.mode;
        else warnings.push(`orphanReaper.mode must be kill, report or off (got ${JSON.stringify(raw.mode)})`);
      }
      for (const k of ["minAgeMinutes", "minCpuSeconds", "minCpuPercent", "staleFileMinutes", "minIntervalMinutes"]) {
        if (raw[k] === undefined) continue;
        if (typeof raw[k] === "number" && Number.isFinite(raw[k]) && raw[k] >= 0) cfg[k] = raw[k];
        else warnings.push(`orphanReaper.${k} must be a non-negative number (got ${JSON.stringify(raw[k])})`);
      }
      if (raw.killPatterns !== undefined) {
        if (Array.isArray(raw.killPatterns)) {
          const known = raw.killPatterns.filter((n) => KILL_PATTERNS.includes(n));
          if (known.length !== raw.killPatterns.length) warnings.push("orphanReaper.killPatterns names an unknown pattern; it is ignored");
          cfg.killPatterns = known;
        } else warnings.push("orphanReaper.killPatterns must be an array of names");
      }
      if (raw.protectPatterns !== undefined) {
        if (Array.isArray(raw.protectPatterns)) {
          for (const p of raw.protectPatterns) {
            try {
              cfg.protectPatterns.push(new RegExp(String(p), "i"));
            } catch {
              warnings.push(`orphanReaper.protectPatterns entry ${JSON.stringify(p)} is not a valid regular expression`);
            }
          }
        } else warnings.push("orphanReaper.protectPatterns must be an array of regular expressions");
      }
    }
  }
  const e = String(env.CLAUDE_PIPELINE_REAPER ?? "").trim().toLowerCase();
  if (["off", "0", "false", "no"].includes(e)) cfg.mode = "off";
  else if (e === "report") cfg.mode = "report";
  else if (["kill", "1", "true", "yes"].includes(e)) cfg.mode = "kill";
  return { cfg, warnings };
}

// ---- reading the process table -----------------------------------------------------------------

const PS_SCRIPT = [
  "$ErrorActionPreference = 'Stop'",
  "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false",
  "$r = @(Get-CimInstance Win32_Process | ForEach-Object {",
  "  [pscustomobject]@{",
  "    pid = [int]$_.ProcessId; ppid = [int]$_.ParentProcessId; name = $_.Name; cmd = $_.CommandLine;",
  "    created = $(if ($_.CreationDate) { ([DateTimeOffset]$_.CreationDate).ToUnixTimeMilliseconds() } else { 0 });",
  "    cpu = ([uint64]$_.KernelModeTime + [uint64]$_.UserModeTime)",
  "  } })",
  "ConvertTo-Json -InputObject $r -Compress -Depth 3",
].join("\n");

/** [[dd-]hh:]mm:ss[.ff] -> seconds (ps `etime` and `time`, Linux and macOS spellings). */
export function parsePsDuration(s) {
  const m = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$/.exec(String(s).trim());
  if (!m) return null;
  return Number(m[1] || 0) * 86400 + Number(m[2] || 0) * 3600 + Number(m[3]) * 60 + Number(m[4]);
}

/**
 * Parse `ps -axo pid=,ppid=,etime=,time=,args=` output. `now` is the epoch ms the snapshot is
 * dated at; each process's start is derived from its elapsed time.
 */
export function parsePsOutput(text, now) {
  const procs = [];
  for (const line of String(text).split(/\r?\n/)) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.*)$/.exec(line);
    if (!m) continue;
    const etime = parsePsDuration(m[3]);
    const cpu = parsePsDuration(m[4]);
    if (etime === null || cpu === null) continue;
    const cmd = m[5];
    procs.push({
      pid: Number(m[1]),
      ppid: Number(m[2]),
      name: path.basename(cmd.split(/\s+/)[0] || ""),
      cmd,
      created: now - etime * 1000,
      cpuSec: cpu,
    });
  }
  return procs;
}

/**
 * Read the process table. Windows: CIM Win32_Process through PowerShell (kernel+user time, start
 * time, full command line, parent). POSIX: ps. Never throws.
 *
 * @returns {{ ok: true, procs: object[] } | { ok: false, reason: string }}
 */
export function collectProcesses({ platform = process.platform, timeoutMs = 5000, now = Date.now() } = {}) {
  if (platform === "win32") {
    const encoded = Buffer.from(PS_SCRIPT, "utf16le").toString("base64");
    let last = "PowerShell was not found";
    for (const exe of ["pwsh.exe", "powershell.exe"]) {
      const r = spawnSync(exe, ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded], {
        encoding: "utf8",
        timeout: timeoutMs,
        maxBuffer: 128 * 1024 * 1024,
        windowsHide: true,
      });
      if (r.error) {
        last = r.error.code === "ETIMEDOUT" ? `${exe} timed out` : `${exe} could not run (${r.error.code || r.error.message})`;
        if (r.error.code === "ENOENT") continue;
        return { ok: false, reason: last };
      }
      if (r.status !== 0) {
        last = `${exe} exited ${r.status}`;
        continue;
      }
      try {
        let rows = JSON.parse(r.stdout);
        if (!Array.isArray(rows)) rows = [rows];
        return {
          ok: true,
          procs: rows.map((x) => ({
            pid: x.pid,
            ppid: x.ppid,
            name: String(x.name ?? ""),
            cmd: String(x.cmd ?? ""),
            created: Number(x.created) || 0,
            cpuSec: Number(x.cpu) / 1e7,
          })),
        };
      } catch {
        last = `${exe} printed output that is not JSON`;
      }
    }
    return { ok: false, reason: `the process list could not be read: ${last}` };
  }
  const r = spawnSync("ps", ["-axo", "pid=,ppid=,etime=,time=,args="], {
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 128 * 1024 * 1024,
  });
  if (r.error) return { ok: false, reason: `the process list could not be read: ps could not run (${r.error.code || r.error.message})` };
  if (r.status !== 0) return { ok: false, reason: `the process list could not be read: ps exited ${r.status}` };
  const procs = parsePsOutput(r.stdout, now);
  if (procs.length === 0) return { ok: false, reason: "the process list could not be read: ps printed no rows" };
  return { ok: true, procs };
}

// ---- the session's tree ------------------------------------------------------------------------

const baseName = (n) => String(n).replace(/^.*[\\/]/, "").toLowerCase().replace(/\.exe$/, "");

/** The session's claude process: not an Electron helper (`--type=`), named claude (or node running claude-code). */
export function isClaudeSession(p) {
  if (/--type=/.test(p.cmd)) return false;
  // The Desktop app's own main process is also called claude. It is the PARENT of every session
  // it hosts, so treating it as a session root would put every other session in scope.
  if (/[\\/]WindowsApps[\\/]Claude_|[\\/]Claude\.app[\\/]Contents[\\/]MacOS[\\/]Claude(?:\s|$)/.test(p.cmd)) return false;
  const b = baseName(p.name);
  if (b === "claude") return true;
  return b === "node" && /(?:^|[\\/ ])(?:@anthropic-ai[\\/])?claude-code[\\/]/.test(p.cmd);
}

/** Index by pid, and the parent of `p` only when that link can be trusted (parent started first). */
function indexProcs(procs) {
  const byPid = new Map();
  for (const p of procs) byPid.set(p.pid, p);
  const parentOf = (p) => {
    const q = byPid.get(p.ppid);
    if (!q || q.pid === p.pid) return null;
    if (q.created && p.created && q.created > p.created) return null;
    return q;
  };
  return { byPid, parentOf };
}

/** The nearest claude ancestor of `startPid` (exclusive), or null. */
export function findSessionRoot(procs, startPid) {
  const { byPid, parentOf } = indexProcs(procs);
  let cur = byPid.get(startPid);
  for (let i = 0; cur && i < 60; i++) {
    cur = parentOf(cur);
    if (cur && isClaudeSession(cur)) return cur;
  }
  return null;
}

/** Every process under `root`, each with its `chain` of ancestors below the root. */
export function treeUnder(procs, root) {
  const { parentOf } = indexProcs(procs);
  const kids = new Map();
  for (const p of procs) {
    const par = parentOf(p);
    if (!par) continue;
    if (!kids.has(par.pid)) kids.set(par.pid, []);
    kids.get(par.pid).push(p);
  }
  const out = [];
  const queue = (kids.get(root.pid) || []).map((p) => ({ p, chain: [] }));
  const seen = new Set([root.pid]);
  while (queue.length) {
    const { p, chain } = queue.shift();
    if (seen.has(p.pid)) continue;
    seen.add(p.pid);
    out.push({ p, chain });
    for (const k of kids.get(p.pid) || []) queue.push({ p: k, chain: [...chain, p] });
  }
  return out;
}

// ---- what is never touched ---------------------------------------------------------------------

const NEVER_NAMES =
  /^(?:claude|docker.*|com\.docker.*|containerd.*|wsl.*|vmmem.*|vmwp|vmcompute|runner\.listener|runner\.worker|actions\.runner.*|runsvc|node-mcp.*)$/;
const NEVER_CMD = [
  /actions[-.]runner|Runner\.(?:Listener|Worker)/i,
  /\bdocker(?:-compose)?(?:\.exe)?\b|com\.docker|containerd|\bwsl(?:host|service)?(?:\.exe)?\b|vmmem/i,
  /\.claude[\\/]launch\.json|preview_start|claude[-_ ]preview/i,
  /\bmcp\b|mcp-server|modelcontextprotocol/i,
  /\b(?:vite|next dev|next-server|webpack(?:-dev-server)?|storybook|nodemon|ts-node-dev|astro dev|nuxt|remix dev|expo start|metro)\b/i,
  /\b(?:npm|pnpm|yarn|bun)(?:\.cmd|\.cjs)?\s+(?:run\s+)?(?:dev|start|serve|watch)\b/i,
];

export function isNeverTouch(p, cfg) {
  if (NEVER_NAMES.test(baseName(p.name))) return true;
  const text = `${p.name} ${p.cmd}`;
  if (NEVER_CMD.some((re) => re.test(text))) return true;
  return cfg.protectPatterns.some((re) => re.test(text));
}

// ---- command-line parsing -----------------------------------------------------------------------

/** Split a Windows (or POSIX-ish) command line into arguments, honoring double quotes. */
export function splitCmdline(cmd) {
  const out = [];
  let cur = "";
  let inQ = false;
  let any = false;
  for (const ch of String(cmd)) {
    if (ch === '"') {
      inQ = !inQ;
      any = true;
    } else if (!inQ && /\s/.test(ch)) {
      if (any || cur) out.push(cur);
      cur = "";
      any = false;
    } else {
      cur += ch;
    }
  }
  if (any || cur) out.push(cur);
  return out;
}

const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);

// ---- the allowlist -----------------------------------------------------------------------------

/** pythonStdinStub: python with no script argument, or just `-` (and harmless flags). Windows only. */
export function matchPythonStdinStub(p, platform) {
  if (platform !== "win32") return null;
  if (!/^python(?:w)?(?:\d+(?:\.\d+)?)?$/.test(baseName(p.name))) return null;
  const args = splitCmdline(p.cmd).slice(1);
  if (!args.every((a) => a === "-" || /^-[uBsSEIOqvbd]+$/.test(a))) return null;
  return { rule: "pythonStdinStub", label: "python stdin stub" };
}

/**
 * waitLoop: a shell whose command line holds an unbounded until/while-sleep loop. `killable` only
 * when every polled file resolved, exists and is older than `staleMs` (evidence the writer is
 * gone); otherwise the reason it is not is in `note`.
 */
export function matchWaitLoop(p, ctx) {
  if (!SHELLS.has(baseName(p.name))) return null;
  const loops = findUnboundedWaitLoops(p.cmd);
  if (loops.length === 0) return null;
  const files = [];
  for (const l of loops) for (const f of polledPaths(l.header)) if (!files.some((x) => x.token === f.token)) files.push(f);
  const states = files.map((f) => {
    if (!f.resolvable) return { token: f.token, state: "unresolved" };
    const native = ctx.toNative(f.token);
    if (!native) return { token: f.token, state: "unresolved" };
    const mtime = ctx.statMtime(native);
    if (mtime === null) return { token: f.token, state: "missing" };
    return { token: f.token, state: ctx.now - mtime >= ctx.staleMs ? "stale" : "fresh", mtime };
  });
  const killable = states.length > 0 && states.every((s) => s.state === "stale");
  let note = "";
  if (states.length === 0) note = "no polled file could be identified";
  else if (!killable) {
    const bad = states.find((s) => s.state !== "stale");
    note = `polled file ${bad.token} is ${bad.state === "fresh" ? "recently written (a writer may be alive)" : bad.state === "missing" ? "missing" : "not resolvable"}`;
  }
  return { rule: "waitLoop", label: "wait loop", killable, note, files: states };
}

// ---- background tasks the session may still be waiting on ---------------------------------------

const FINISHED_STATUS = (s) => String(s).trim().toLowerCase() !== "running";
const TRANSCRIPT_MAX_BYTES = 1024 * 1024 * 1024;
const CHUNK_BYTES = 8 * 1024 * 1024;

/**
 * Incremental reader of one or more transcripts' lines. A task STARTS when a Bash tool_result
 * carries `backgroundTaskId` (or says "Command running in background with ID: <id>") and FINISHES
 * with a <task-notification> naming it, or a KillShell/TaskStop of it. Lines are pre-filtered by
 * substring so the JSON parse is paid only on the few that can matter: the real incident session's
 * transcript was 142 MB.
 */
export class TaskScanner {
  constructor() {
    this.commandOf = new Map();
    this.started = new Map();
    this.finished = new Set();
  }

  feed(line) {
    if (
      !line.includes('"name":"Bash"') &&
      !line.includes("backgroundTaskId") &&
      !line.includes("task-notification") &&
      !line.includes("running in background") &&
      !line.includes('"name":"KillShell"') &&
      !line.includes('"name":"TaskStop"')
    )
      return;
    for (const m of line.matchAll(/<task-id>([^<]+)<\/task-id>[\s\S]*?<status>([^<]+)<\/status>/g)) {
      if (FINISHED_STATUS(m[2])) this.finished.add(m[1]);
    }
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      return;
    }
    const content = obj?.message?.content;
    if (!Array.isArray(content)) return;
    for (const c of content) {
      if (c?.type === "tool_use" && c.name === "Bash" && typeof c.input?.command === "string") {
        this.commandOf.set(c.id, c.input.command);
      } else if (c?.type === "tool_use" && (c.name === "KillShell" || c.name === "TaskStop")) {
        const id = c.input?.shell_id ?? c.input?.task_id;
        if (id) this.finished.add(String(id));
      } else if (c?.type === "tool_result") {
        const txt = typeof c.content === "string" ? c.content : JSON.stringify(c.content ?? "");
        const id = obj?.toolUseResult?.backgroundTaskId || /running in background with ID: (\w+)/.exec(txt)?.[1];
        if (id) this.started.set(String(id), c.tool_use_id);
      }
    }
  }

  /** Commands of tasks that started and have not finished. */
  live() {
    const live = [];
    for (const [id, toolUseId] of this.started) {
      if (this.finished.has(id)) continue;
      const cmd = this.commandOf.get(toolUseId);
      if (cmd) live.push(cmd);
    }
    return live;
  }
}

/** Commands of the background tasks still running, from one transcript's full text. */
export function liveTasksFromTranscript(text) {
  const sc = new TaskScanner();
  for (const line of text.split("\n")) sc.feed(line);
  return sc.live();
}

/** Feed a transcript FILE through a scanner in fixed-size chunks (never holds it all in memory). */
export function scanTranscriptFile(file, scanner) {
  const fd = openSync(file, "r");
  try {
    if (fstatSync(fd).size > TRANSCRIPT_MAX_BYTES) throw new Error("transcript too large");
    const buf = Buffer.allocUnsafe(CHUNK_BYTES);
    let carry = Buffer.alloc(0);
    for (;;) {
      const n = readSync(fd, buf, 0, CHUNK_BYTES, null);
      if (n === 0) break;
      const data = carry.length ? Buffer.concat([carry, buf.subarray(0, n)]) : buf.subarray(0, n);
      const cut = data.lastIndexOf(10);
      if (cut === -1) {
        carry = Buffer.from(data);
        continue;
      }
      for (const line of data.subarray(0, cut).toString("utf8").split("\n")) scanner.feed(line);
      carry = Buffer.from(data.subarray(cut + 1));
    }
    if (carry.length) scanner.feed(carry.toString("utf8"));
  } finally {
    closeSync(fd);
  }
}

const LIVE_AGENT_MS = 30 * 60 * 1000;

/** The transcript files whose still-running background tasks protect a process. */
export function transcriptFiles(payload, now, statFn = statSync, readdirFn = readdirSync) {
  const files = [];
  const main = payload?.transcript_path ? nativePath(payload.transcript_path) : "";
  if (main) files.push(main);
  if (main.endsWith(".jsonl")) {
    const dir = path.join(main.slice(0, -".jsonl".length), "subagents");
    const stopped = payload?.agent_transcript_path ? nativePath(payload.agent_transcript_path) : "";
    const walk = (d, depth) => {
      let ents = [];
      try {
        ents = readdirFn(d, { withFileTypes: true });
      } catch {
        return;
      }
      for (const e of ents) {
        const f = path.join(d, e.name);
        if (e.isDirectory()) {
          if (depth < 2) walk(f, depth + 1);
        } else if (e.name.endsWith(".jsonl") && f !== stopped && !(payload?.agent_id && e.name.includes(payload.agent_id))) {
          try {
            // an agent that is still writing is live; one that stopped writing has left its tasks orphaned
            if (now - statFn(f).mtimeMs <= LIVE_AGENT_MS) files.push(f);
          } catch {
            /* unreadable: not counted */
          }
        }
      }
    };
    walk(dir, 0);
  }
  return files;
}

/** @returns {{ known: boolean, commands: string[] }} known is false when the main transcript could not be read. */
export function readLiveBackgroundCommands(payload, now) {
  const files = transcriptFiles(payload, now);
  const scanner = new TaskScanner();
  let mainRead = false;
  files.forEach((f, i) => {
    try {
      scanTranscriptFile(f, scanner);
      if (i === 0) mainRead = true;
    } catch {
      /* unreadable transcript */
    }
  });
  // The main transcript is the one that proves anything; without it nothing is known.
  return { known: mainRead, commands: scanner.live() };
}

const norm = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, "");

/** True when a live background command's text appears in this process's or an ancestor's command line. */
export function matchesLiveBackground(p, chain, bg) {
  if (!bg.known) return false;
  const hay = norm([p.cmd, ...chain.map((a) => a.cmd)].join(" "));
  return bg.commands.some((c) => {
    const n = norm(c);
    return n.length >= 12 && hay.includes(n);
  });
}

// ---- the plan ------------------------------------------------------------------------------------

/** One-line, secret-light rendering of a command line for the report and the log. */
export function brief(cmd, max = 90) {
  const s = String(cmd)
    .replace(/\s+/g, " ")
    // the keyword, then `=`, `:` or whitespace, then the value; [\w-]* only extends the KEYWORD
    // (--api-key-id), never reaches into the value, so `--token=S3CRET --x` hides S3CRET and not --x
    .replace(/((?:token|secret|passw(?:or)?d|api[-_]?key|auth\w*|bearer)[\w-]*(?:\s*[=:]\s*|\s+)(?:bearer\s+)?)\S+/gi, "$1***")
    .trim();
  return s.length > max ? `${s.slice(0, max)}...` : s;
}

export function fmtDuration(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 120) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 48 ? `${h}h` : `${Math.floor(h / 24)}d${h % 24}h`;
}

/**
 * Decide, on one snapshot, what is reported and what is to be killed.
 *
 * @returns {{ rootFound: boolean, root?: object, candidates: object[], notes: string[] }}
 *   each candidate: { p, chain, ageMs, cpuSec, util, match, action: "kill"|"report", reason }
 */
export function plan(procs, ctx) {
  const { cfg, now, selfPid, rootPid } = ctx;
  const notes = [];
  let root = null;
  if (rootPid) {
    root = procs.find((p) => p.pid === rootPid) || null;
    if (!root) notes.push(`--root-pid ${rootPid} is not in the process list`);
  } else {
    root = findSessionRoot(procs, selfPid);
  }
  if (!root) return { rootFound: false, candidates: [], notes };

  const { byPid, parentOf } = indexProcs(procs);
  const self = new Set([selfPid]);
  for (let cur = byPid.get(selfPid), i = 0; cur && i < 60; i++) {
    cur = parentOf(cur);
    if (cur) self.add(cur.pid);
  }

  const candidates = [];
  for (const { p, chain } of treeUnder(procs, root)) {
    if (self.has(p.pid) || isClaudeSession(p)) continue;
    if (isNeverTouch(p, cfg) || chain.some((a) => isNeverTouch(a, cfg))) continue;
    if (!p.created) continue;
    const ageMs = now - p.created;
    if (ageMs < cfg.minAgeMinutes * 60000) continue;
    const util = ageMs > 0 ? (p.cpuSec / (ageMs / 1000)) * 100 : 0;
    if (p.cpuSec < cfg.minCpuSeconds || util < cfg.minCpuPercent) continue;

    const enabled = (n) => cfg.killPatterns.includes(n);
    const match =
      (enabled("pythonStdinStub") && matchPythonStdinStub(p, ctx.platform)) ||
      (enabled("waitLoop") && matchWaitLoop(p, ctx)) ||
      null;

    let action = "report";
    let reason = "not on the kill allowlist";
    if (match) {
      if (cfg.mode !== "kill") reason = `${match.label}, but mode is ${cfg.mode}`;
      else if (matchesLiveBackground(p, chain, ctx.getBg())) reason = `${match.label}, but it matches a background task the session may still be waiting on`;
      else if (match.rule === "waitLoop" && !match.killable) reason = `${match.label}; ${match.note}`;
      else if (match.rule === "pythonStdinStub" && !ctx.getBg().known) reason = `${match.label}, but the session transcript could not be read to rule out a live background task`;
      else {
        action = "kill";
        reason = match.label;
      }
    }
    candidates.push({ p, chain, ageMs, cpuSec: p.cpuSec, util, match, action, reason });
  }
  return { rootFound: true, root, candidates, notes };
}

// ---- state, log, throttle -------------------------------------------------------------------------

function stateDir(projectDir, env = process.env) {
  if (env.CLAUDE_PIPELINE_REAPER_DIR) return env.CLAUDE_PIPELINE_REAPER_DIR;
  const r = spawnSync("git", ["-C", projectDir || ".", "rev-parse", "--git-common-dir"], { encoding: "utf8", timeout: 3000 });
  if (!r.error && r.status === 0 && r.stdout.trim()) {
    const g = r.stdout.trim();
    const abs = path.isAbsolute(g) || /^[A-Za-z]:[\\/]/.test(g) ? g : path.join(projectDir || ".", g);
    return path.join(abs, "agent-pipeline-reaper");
  }
  return path.join(tmpdir(), "agent-pipeline-reaper");
}

function readState(dir) {
  try {
    const s = JSON.parse(readFileSync(path.join(dir, "state.json"), "utf8"));
    return s && typeof s === "object" ? s : {};
  } catch {
    return {};
  }
}

function writeState(dir, state) {
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "state.json"), JSON.stringify(state));
  } catch {
    /* the memory is a convenience; losing it only repeats a report */
  }
}

function logLine(dir, line) {
  try {
    mkdirSync(dir, { recursive: true });
    const f = path.join(dir, "reaper.log");
    if (existsSync(f) && statSync(f).size > 256 * 1024) {
      const keep = readFileSync(f, "utf8").slice(-128 * 1024);
      writeFileSync(f, keep.slice(keep.indexOf("\n") + 1));
    }
    appendFileSync(f, `${new Date().toISOString()} ${line}\n`);
  } catch {
    /* the line is on stdout/stderr too */
  }
}

// ---- acting -----------------------------------------------------------------------------------------

function realKill(pid, sig) {
  try {
    process.kill(pid, sig);
    return true;
  } catch {
    return false;
  }
}
function realAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e && e.code === "EPERM";
  }
}
const realSleep = (ms) => new Promise((r) => setTimeout(r, ms));

function realToNative(token, platform = process.platform) {
  let t = token;
  if (t.startsWith("~")) t = path.join(homedir(), t.slice(1));
  if (platform !== "win32") return t;
  if (/^[A-Za-z]:[\\/]/.test(t)) return t;
  const drive = nativePath(t, "win32");
  if (drive !== t) return drive;
  const r = spawnSync("cygpath", ["-w", t], { encoding: "utf8", timeout: 2000 });
  return !r.error && r.status === 0 && r.stdout.trim() ? r.stdout.trim() : null;
}

function realStatMtime(f) {
  try {
    return statSync(f).mtimeMs;
  } catch {
    return null;
  }
}

/**
 * Run one reaping pass. Everything that touches the host is injectable so a test can plant a
 * process table, a clock and a killer; the CLI passes the real ones.
 *
 * @returns {Promise<{ status: "ran"|"off"|"throttled"|"no-root"|"unavailable", reason?: string,
 *   killed: object[], reported: object[], summary: string, notes: string[] }>}
 */
export async function reap(opts) {
  const o = {
    event: "manual",
    platform: process.platform,
    now: Date.now(),
    selfPid: process.pid,
    payload: {},
    dryRun: false,
    budgetMs: 8000,
    collect: collectProcesses,
    kill: realKill,
    alive: realAlive,
    sleep: realSleep,
    statMtime: realStatMtime,
    toNative: realToNative,
    readBackground: readLiveBackgroundCommands,
    ...opts,
  };
  const started = Date.now();
  const projectDir = o.projectDir || o.payload?.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const { cfg, warnings } = readReaperConfig(projectDir, o.env || process.env);
  const result = { status: "ran", killed: [], reported: [], summary: "", notes: [...warnings] };
  if (cfg.mode === "off" && !o.dryRun) return { ...result, status: "off" };

  const dir = o.stateDir || stateDir(projectDir, o.env || process.env);
  const state = readState(dir);
  const throttled = o.event === "SubagentStop" || o.event === "Stop";
  if (throttled && !o.dryRun && state.lastRun && o.now - state.lastRun < cfg.minIntervalMinutes * 60000) {
    return { ...result, status: "throttled" };
  }

  const snap = o.collect({ platform: o.platform, timeoutMs: Math.min(4000, o.budgetMs), now: o.now });
  if (!snap.ok) {
    if (!o.dryRun) writeState(dir, { ...state, lastRun: o.now });
    return { ...result, status: "unavailable", reason: snap.reason };
  }

  // A dry run previews the configured policy (an off mode previews as kill) and never acts on it.
  const effective = o.dryRun && cfg.mode === "off" ? { ...cfg, mode: "kill" } : cfg;
  let bg = null;
  const ctx = {
    cfg: effective,
    now: o.now,
    platform: o.platform,
    selfPid: o.selfPid,
    rootPid: o.rootPid,
    staleMs: cfg.staleFileMinutes * 60000,
    statMtime: o.statMtime,
    toNative: (t) => o.toNative(t, o.platform),
    // Read lazily: only a candidate that already matches the allowlist needs the transcripts.
    getBg: () => (bg ??= o.readBackground(o.payload, o.now)),
  };
  const decided = plan(snap.procs, ctx);
  result.notes.push(...decided.notes);
  if (!decided.rootFound) {
    // Not an error: a hook that did not run under claude (a test, a terminal) acts on nothing.
    if (!o.dryRun) writeState(dir, { ...state, lastRun: o.now });
    const why = "no claude process found above this one, so nothing was examined; pass --root-pid <pid> to name the session's claude process";
    return { ...result, status: "no-root", summary: o.dryRun ? why : "" };
  }

  let toKill = decided.candidates.filter((c) => c.action === "kill");
  if (toKill.length > 0 && !o.dryRun) {
    // Decide twice, act on the second: confirm on a fresh snapshot, same pid AND start time.
    const left = o.budgetMs - (Date.now() - started);
    if (left < 1500) {
      result.notes.push("not enough time budget left to confirm a kill; reported only");
      toKill = [];
      for (const c of decided.candidates) if (c.action === "kill") Object.assign(c, { action: "report", reason: `${c.reason} (kill not confirmed in time)` });
    } else {
      const later = o.now + (Date.now() - started);
      const again = o.collect({ platform: o.platform, timeoutMs: Math.min(4000, left - 500), now: later });
      if (!again.ok) {
        result.notes.push(`kill not confirmed (${again.reason}); reported only`);
        toKill = [];
        for (const c of decided.candidates) if (c.action === "kill") Object.assign(c, { action: "report", reason: `${c.reason} (kill not confirmed)` });
      } else {
        const confirmed = plan(again.procs, { ...ctx, now: later });
        const ok = new Set(confirmed.candidates.filter((c) => c.action === "kill").map((c) => `${c.p.pid}:${c.p.created}`));
        toKill = toKill.filter((c) => ok.has(`${c.p.pid}:${c.p.created}`));
        for (const c of decided.candidates) {
          if (c.action === "kill" && !ok.has(`${c.p.pid}:${c.p.created}`)) Object.assign(c, { action: "report", reason: `${c.reason} (changed before the kill)` });
        }
      }
    }
    for (const c of toKill) {
      o.kill(c.p.pid, "SIGTERM");
    }
    if (toKill.length > 0 && o.platform !== "win32") await o.sleep(800);
    for (const c of toKill) {
      if (o.platform !== "win32" && o.alive(c.p.pid)) o.kill(c.p.pid, "SIGKILL");
      await o.sleep(0);
      c.killed = !o.alive(c.p.pid);
    }
  }

  const describe = (c) => {
    const base = `pid ${c.p.pid} ${c.p.name || "?"} (${c.reason}), age ${fmtDuration(c.ageMs)}, cpu ${fmtDuration(c.cpuSec * 1000)}`;
    const polled = c.match?.files?.length ? `, polling ${c.match.files.map((f) => f.token).join(" ")}` : "";
    return `${base}${polled}: ${brief(c.p.cmd)}`;
  };

  const seen = state.reported && typeof state.reported === "object" ? state.reported : {};
  const nextSeen = {};
  const lines = [];
  for (const c of decided.candidates) {
    const key = `${c.p.pid}:${c.p.created}`;
    if (c.action === "kill" && !o.dryRun) {
      if (toKill.includes(c)) {
        const ok = c.killed === true;
        result.killed.push(c);
        logLine(dir, `${o.event} ${ok ? "KILLED" : "KILL FAILED"} ${describe(c)}`);
        lines.push(`${ok ? "killed" : "could not kill"} ${describe(c)}`);
        continue;
      }
    }
    nextSeen[key] = seen[key] || o.now;
    const fresh = !seen[key] || o.dryRun;
    result.reported.push({ ...c, fresh });
    if (!seen[key]) logLine(dir, `${o.event} REPORTED ${describe(c)}`);
    if (fresh) lines.push(`${c.action === "kill" ? "would kill" : "left running"} ${describe(c)}`);
  }
  if (!o.dryRun) writeState(dir, { lastRun: o.now, reported: nextSeen });

  if (o.dryRun) {
    result.summary = lines.length ? lines.join("\n") : "no candidates";
  } else if (lines.length) {
    const k = result.killed.filter((c) => c.killed === true).length;
    const r = lines.filter((l) => l.startsWith("left running")).length;
    const head = `orphan reaper: ${k ? `killed ${k}` : "killed 0"}${r ? `, reported ${r} it left running` : ""}`;
    result.summary = `${head}. ${lines.join("; ")}. Log: ${path.join(dir, "reaper.log")}. Off: orphanReaper.mode "off" or CLAUDE_PIPELINE_REAPER=off.`.replace(/\s+/g, " ");
  }
  return result;
}

// ---- CLI ---------------------------------------------------------------------------------------------

function readStdinBounded(ms) {
  return new Promise((resolve) => {
    if (process.stdin.isTTY) return resolve("");
    let buf = "";
    const done = () => {
      clearTimeout(t);
      try {
        process.stdin.destroy();
      } catch {
        /* already closed */
      }
      resolve(buf);
    };
    const t = setTimeout(done, ms);
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => (buf += c));
    process.stdin.on("end", done);
    process.stdin.on("error", done);
  });
}

async function main(argv) {
  const val = (flag) => {
    const i = argv.indexOf(flag);
    return i !== -1 ? argv[i + 1] : undefined;
  };
  const dryRun = argv.includes("--dry-run");
  const event = val("--event") || "manual";
  let payload = {};
  const raw = await readStdinBounded(1500);
  try {
    payload = raw.trim() ? JSON.parse(raw) : {};
  } catch {
    payload = {};
  }
  const rootPid = val("--root-pid") ? Number(val("--root-pid")) : undefined;
  const res = await reap({ event, payload, dryRun, rootPid, projectDir: val("--project-dir") });
  for (const n of res.notes) process.stderr.write(`reap-orphans: ${n}\n`);
  if (res.status === "unavailable") {
    process.stderr.write(`reap-orphans: disarm: ${res.reason}\n`);
    return 3;
  }
  if (res.summary) process.stdout.write(`${res.summary}\n`);
  return 0;
}

if (isMain("reap-orphans.mjs")) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (e) => {
      process.stderr.write(`reap-orphans: ${e && e.message ? e.message : e}\n`);
      process.exitCode = 1;
    },
  );
}
