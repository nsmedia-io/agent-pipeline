#!/usr/bin/env bash
# scripts/reap-orphans.mjs and hooks/reaper.sh: the ORPHAN REAPER (0.49.0).
#
# WHY. A Bash command that outlives the tool's timeout is moved to the background and nothing reaps
# it; a finished sub-agent leaves its background commands running. On the owner's Windows host
# (2026-10-02, the Rome project) one session's sub-agents left five `python3 - <<'E'` stdin stubs
# spinning at 5-6% CPU (the oldest at 24.6 CPU-hours) and four `until grep -q "^exit" <log>; do
# sleep 10; done` loops waiting on logs from agents that had finished a day earlier, on the host
# that also runs CI runners, Docker and the agents (docs/rationale.md, "Orphaned sub-agent
# processes"). The reaper kills a closed allowlist of known-orphan patterns and reports the rest.
#
# WHAT IS PINNED, because a reaper's worst failure is the kill it should not have made:
#   - THE KILLS: an unbounded wait loop whose polled file is stale; a Windows python stdin stub;
#     the SIGKILL escalation on POSIX; the one-line summary and the log line;
#   - THE REFUSALS, each a separate row: a fresh polled file, a missing or unresolvable one, a
#     bounded loop, a live background task (and an unreadable transcript for the python stub), an
#     off mode, a report mode, an allowlist that excludes the pattern;
#   - THE NEVER-TOUCH LIST: a process outside this session's tree (a sibling session's, one whose
#     parent link is a recycled pid, one under the Desktop app but not under this session's claude),
#     claude itself, the hook's own ancestry, Docker/WSL/vmmem/CI runners/MCP/dev servers, and a
#     spinner UNDER one of those;
#   - THE THRESHOLDS, at the line and one step either side; the throttle; the report-once memory;
#     the dry run; the redaction of a secret in a command line;
#   - THE CONFIRMATION: a process gone, or recycled, between the two snapshots is not killed;
#   - REAL PROCESSES: a planted orphan is actually killed, and a planted FRESH-file loop, a loop
#     OUTSIDE the tree and the root survive the same run;
#   - FAIL-OPEN: no process lister, a stub reaper that crashes, node absent, the off switches, and
#     the three hooks' own plumbing (one JSON object on stdout; the decision wins over the summary).
#
# The table-driven cases run in ONE node process (fixtures/reaper-driver.mjs) because a node start
# costs seconds on a loaded host; the planted tables are in fixtures/reaper-scenarios.mjs.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

require_node

REAPER="$SCRIPTS_DIR/reap-orphans.mjs"
FIXDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures" && pwd)"
NODE_BIN="$(command -v node)"

new_tmpdir || exit 90
SCRATCH="$NEW_TMPDIR"
RESULTS="$SCRATCH/results.txt"

node "$FIXDIR/reaper-driver.mjs" "$SCRATCH/s" > "$RESULTS" 2> "$SCRATCH/driver.err"
DRIVER_RC=$?
suite "the driver ran every scenario"
assert_eq "the scenario driver exits 0" "$DRIVER_RC" "0"
assert_eq "and printed nothing on stderr" "$(cat "$SCRATCH/driver.err")" ""

# v <scenario>.<run>.<field> -> the value, from the one results file
v() { awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$RESULTS"; }
# r <scenario> <field> -> run 0
r() { v "$1.0.$2"; }

# ===============================================================================================
suite "KILLS: an unbounded wait loop whose polled file is stale"
# ===============================================================================================
assert_eq "the loop (pid 30) is killed" "$(r waitloop_stale killedPids)" "30"
assert_eq "with exactly one SIGTERM and nothing else (the process died)" "$(r waitloop_stale killCalls)" "30:SIGTERM"
assert_eq "a killed process is not also reported" "$(r waitloop_stale reportedPids)" ""
assert_contains "the summary says what was killed" "$(r waitloop_stale summary)" "orphan reaper: killed 1"
assert_contains "and what it was polling" "$(r waitloop_stale summary)" "polling /tmp/agent.log"
assert_contains "and how to turn it off" "$(r waitloop_stale summary)" 'CLAUDE_PIPELINE_REAPER=off'
assert_contains "every kill is in the log" "$(r waitloop_stale log)" "KILLED pid 30 bash.exe (wait loop)"
assert_eq "a process that ignores SIGTERM gets the SIGKILL escalation" \
  "$(r waitloop_stale_sigkill killCalls)" "30:SIGTERM,30:SIGKILL"
assert_eq "no readable transcript does not stop a loop whose file proves its writer is gone" \
  "$(r waitloop_stale_bg_unknown killedPids)" "30"

suite "KILLS: the Windows python stdin stub"
assert_eq "python.exe reading stdin (pid 34) is killed on win32" "$(r python_stub_win killedPids)" "34"
assert_eq "only the spinner: its alias stub and its shell are under the CPU line and are left to exit on their own" \
  "$(r python_stub_win killCalls)" "34:SIGTERM"
assert_contains "the log names the pattern" "$(r python_stub_win log)" "KILLED pid 34 python.exe (python stdin stub)"

# ===============================================================================================
suite "NOT KILLED, REPORTED: the same orphans when nothing proves them dead"
# ===============================================================================================
nokill() { # <scenario> <label>
  assert_eq "$2: nothing killed" "$(r "$1" killCalls)" ""
}
nokill waitloop_fresh_file "a fresh polled file (a writer may be alive)"
assert_eq "  ...but it is reported" "$(r waitloop_fresh_file reportedPids)" "30"
assert_contains "  ...with the reason" "$(r waitloop_fresh_file summary)" "recently written"
nokill waitloop_missing_file "a missing polled file"
assert_contains "  ...reported as missing" "$(r waitloop_missing_file summary)" "missing"
nokill waitloop_no_file_named 'a loop polling $MARKER (no file to resolve)'
assert_contains "  ...reported with that reason" "$(r waitloop_no_file_named summary)" "no polled file could be identified"
nokill waitloop_bounded "a loop under timeout"
assert_eq "  ...reported, as a spinning process off the allowlist" "$(r waitloop_bounded reportedPids)" "30"
assert_contains "  ...as such" "$(r waitloop_bounded summary)" "not on the kill allowlist"
nokill waitloop_counter_bounded "a loop with an attempt counter and a break"
assert_eq "  ...reported" "$(r waitloop_counter_bounded reportedPids)" "30"
nokill python_stub_linux "the python stub on a POSIX host (python reading stdin is legitimate there)"
assert_eq "  ...reported" "$(r python_stub_linux reportedPids)" "34"
nokill python_stub_bg_unknown "the python stub with the session transcript unreadable"
assert_contains "  ...says why" "$(r python_stub_bg_unknown summary)" "transcript could not be read"
nokill python_stub_live_bg "the python stub whose program is a background task still running"
assert_contains "  ...says why" "$(r python_stub_live_bg summary)" "background task the session may still be waiting on"
nokill python_with_script "python running a script (not a stdin program)"
assert_eq "  ...reported" "$(r python_with_script reportedPids)" "34"
nokill waitloop_live_bg "a stale-file loop that IS a live background task"
assert_contains "  ...says why" "$(r waitloop_live_bg summary)" "background task the session may still be waiting on"
nokill loop_text_in_non_shell "loop text inside a node process's argv"
assert_eq "  ...reported" "$(r loop_text_in_non_shell reportedPids)" "30"

# ===============================================================================================
suite "NEVER TOUCHED: outside the session's tree, or on the never-touch list"
# ===============================================================================================
untouched() { # <scenario> <label>
  assert_eq "$2: no kill" "$(r "$1" killCalls)" ""
  assert_eq "$2: not even reported" "$(r "$1" reportedPids)" ""
}
untouched outside_tree "a wait loop under ANOTHER session's claude"
untouched protected_processes "docker, com.docker, wsl, vmmem, a CI runner, vite, an MCP server, launch.json tooling, next dev, pnpm dev, and a spinner and a stale loop UNDER docker"
assert_eq "  ...the protected table ran clean (a summary would mean something was left running)" "$(r protected_processes summary)" ""
untouched protect_patterns "a loop matching the config's protectPatterns"
untouched claude_never_killed "a nested claude process"
untouched own_chain_never_killed "a stale wait loop that IS the hook's own ancestor"
untouched pid_reuse_not_a_child "a process whose parent link is a recycled pid (it is older than its claimed parent)"
untouched no_claude_ancestor "an orphan when the hook has no claude ancestor"
assert_eq "  ...and the run says it found no root" "$(r no_claude_ancestor status)" "no-root"
untouched desktop_main_is_not_a_root "an orphan under the Desktop app, when the only claude above the hook is the Desktop app's own"
assert_eq "  ...the Desktop app's main process is not taken for a session root" "$(r desktop_main_is_not_a_root status)" "no-root"

# ===============================================================================================
suite "THRESHOLDS: a candidate must be old enough, have enough CPU, and spin"
# ===============================================================================================
assert_eq "only the process ON every threshold is a candidate (59 min, 299 s and 0.1% are not)" \
  "$(r thresholds reportedPids)" "203"
assert_eq "custom minAgeMinutes above the loop's age: nothing is a candidate" "$(r custom_thresholds reportedPids)" ""
assert_eq "  ...and nothing is killed" "$(r custom_thresholds killCalls)" ""

# ===============================================================================================
suite "MODES AND CONFIG: kill, report, off, the env override, the closed allowlist, bad values"
# ===============================================================================================
assert_eq "mode report: nothing killed" "$(r mode_report killCalls)" ""
assert_eq "mode report: the orphan is reported" "$(r mode_report reportedPids)" "30"
assert_contains "mode report: says it is report mode" "$(r mode_report summary)" "mode is report"
assert_eq "mode off (config): status off" "$(r mode_off_config status)" "off"
assert_eq "mode off (config): the process list is never read" "$(r mode_off_config collects)" "0"
assert_eq "mode off (env): status off" "$(r mode_off_env status)" "off"
assert_eq "mode off (env): the process list is never read" "$(r mode_off_env collects)" "0"
assert_eq "the env override beats the config (off in config, kill in env)" "$(r mode_env_overrides_config killedPids)" "30"
assert_eq "killPatterns without waitLoop: the loop is not killed" "$(r killpatterns_without_waitloop killCalls)" ""
assert_eq "  ...it is reported" "$(r killpatterns_without_waitloop reportedPids)" "30"
assert_eq "an unknown killPatterns name is ignored (the allowlist is closed) and the known one still applies" \
  "$(r killpatterns_unknown_name killedPids)" "30"
assert_contains "  ...and the ignored name is reported" "$(r killpatterns_unknown_name notes)" "unknown pattern"
assert_eq "bad config values fall back to the defaults (the loop is still killed)" "$(r bad_config_values killedPids)" "30"
assert_contains "  ...a bad mode is named" "$(r bad_config_values notes)" "orphanReaper.mode must be kill, report or off"
assert_contains "  ...a bad number is named" "$(r bad_config_values notes)" "orphanReaper.minAgeMinutes must be a non-negative number"
assert_contains "  ...a string where a number belongs is named" "$(r bad_config_values notes)" "orphanReaper.minCpuSeconds"

# ===============================================================================================
suite "CONFIRMATION: decide on one snapshot, act on a second"
# ===============================================================================================
assert_eq "a process gone at the second read is not killed" "$(r confirm_process_gone killCalls)" ""
assert_contains "  ...and the report says it changed" "$(r confirm_process_gone summary)" "changed before the kill"
assert_eq "a pid recycled between the two reads (new start time) is not killed" "$(r confirm_pid_reused killCalls)" ""
assert_eq "a normal run reads the table twice before a kill" "$(r waitloop_stale collects)" "2"
assert_eq "and once when there is nothing to kill" "$(r thresholds collects)" "1"

# ===============================================================================================
suite "THROTTLE, REPORT-ONCE, DRY RUN, FAILURE, REDACTION"
# ===============================================================================================
assert_eq "SubagentStop run 1 reaps" "$(v throttle.0.status)" "ran"
assert_eq "SubagentStop run 2, 5 min later: throttled (default interval 10 min)" "$(v throttle.1.status)" "throttled"
assert_eq "  ...and the process list was not read" "$(v throttle.1.collects)" "0"
assert_eq "Stop 5 min later: throttled too" "$(v throttle.2.status)" "throttled"
assert_eq "SessionStart is never throttled" "$(v throttle.3.status)" "ran"
assert_eq "Stop 15 min after the last run: runs" "$(v throttle.4.status)" "ran"

assert_contains "a non-allowlisted spinner is reported the first time" "$(v reported_once.0.summary)" "pid 210"
assert_eq "  ...and not again a minute later (same pid, same start time)" "$(v reported_once.1.summary)" ""
assert_eq "  ...though it is still a candidate" "$(v reported_once.1.reportedPids)" "210"

assert_eq "dry run: nothing killed" "$(v dry_run.0.killCalls)" ""
assert_contains "dry run: says what it WOULD kill" "$(v dry_run.0.summary)" "would kill pid 30"
assert_eq "dry run ignores the throttle (a second run a minute later still runs)" "$(v dry_run.1.status)" "ran"
assert_contains "  ...and still says it" "$(v dry_run.1.summary)" "would kill pid 30"

assert_eq "an unreadable process list: status unavailable" "$(r collect_failure status)" "unavailable"
assert_contains "  ...with the reason" "$(r collect_failure reason)" "PowerShell was not found"
assert_eq "  ...and nothing killed" "$(r collect_failure killCalls)" ""

assert_not_contains "a secret in a command line is not in the summary (token)" "$(r redaction summary)" "SECRET123"
assert_not_contains "  ...(api key)" "$(r redaction summary)" "ABCDEF987"
assert_contains "  ...it is replaced, not dropped silently" "$(r redaction summary)" "***"

# ===============================================================================================
suite "the building blocks: durations, ps rows, command lines, roots, transcripts"
# ===============================================================================================
cat > "$SCRATCH/units.mjs" <<'MJS'
import { mkdirSync, writeFileSync, utimesSync } from "node:fs";
import path from "node:path";
const m = await import(process.env.REAPER_MJS);
const out = [];
const put = (k, v) => out.push(`${k}=${v}`);
const scratch = process.env.SCRATCH_DIR;

put("dur.ss", m.parsePsDuration("00:05"));
put("dur.mmss", m.parsePsDuration("12:34"));
put("dur.hhmmss", m.parsePsDuration("01:02:03"));
put("dur.dd", m.parsePsDuration("2-01:00:00"));
put("dur.mac_hundredths", m.parsePsDuration("0:01.50"));
put("dur.junk", m.parsePsDuration("abc"));

const rows = m.parsePsOutput(
  [
    "  100     1       02:00:00     00:30:00 /usr/local/bin/claude --resume=abc",
    "  200   100     1-00:00:00     01:00:00 bash -c until grep -q x /tmp/a; do sleep 5; done",
    "garbage line",
    "  300   200        00:10         00:00 sleep 5",
  ].join("\n"),
  1_000_000_000_000,
);
put("ps.count", rows.length);
put("ps.pid", rows.map((r) => r.pid).join(","));
put("ps.name1", rows[0].name);
put("ps.age2h", (1_000_000_000_000 - rows[0].created) / 3600000);
put("ps.cpu2", rows[1].cpuSec);
put("ps.cmd2", rows[1].cmd);

put("args.win", JSON.stringify(m.splitCmdline('"C:\\Program Files\\x\\python.exe" - -u')));
put("args.empty", JSON.stringify(m.splitCmdline("python.exe")));

const P = (name, cmd) => ({ name, cmd });
put("claude.cli", m.isClaudeSession(P("claude.exe", "C:\\Users\\u\\AppData\\Roaming\\Claude\\claude-code\\2.1.284\\claude.exe --output-format stream-json")));
put("claude.desktop_main", m.isClaudeSession(P("claude.exe", '"C:\\Program Files\\WindowsApps\\Claude_2.16_x64__abc\\app\\claude.exe"')));
put("claude.electron_helper", m.isClaudeSession(P("claude.exe", "claude.exe --type=renderer --lang=en-US")));
put("claude.posix", m.isClaudeSession(P("claude", "/usr/local/bin/claude --resume=x")));
put("claude.node_cli", m.isClaudeSession(P("node", "node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js")));
put("claude.macos_desktop", m.isClaudeSession(P("Claude", "/Applications/Claude.app/Contents/MacOS/Claude")));
put("claude.other", m.isClaudeSession(P("bash", "bash -c claude")));

// the root is the NEAREST claude ancestor, and a parent link from a younger process is not trusted
const mk = (pid, ppid, name, cmd, created) => ({ pid, ppid, name, cmd, created, cpuSec: 0 });
const procs = [
  mk(1, 0, "claude.exe", '"C:\\Program Files\\WindowsApps\\Claude_2.16_x64__abc\\app\\claude.exe"', 100),
  mk(2, 1, "claude.exe", "claude.exe --output-format stream-json", 200),
  mk(3, 2, "bash.exe", "bash.exe", 300),
  mk(4, 3, "node.exe", "node reap", 400),
  mk(5, 2, "claude.exe", "claude.exe --output-format stream-json", 250),
];
put("root.nearest", m.findSessionRoot(procs, 4).pid);
const recycled = procs.map((p) => (p.pid === 3 ? { ...p, created: 50 } : p)); // bash older than its "parent" claude
put("root.recycled_link", m.findSessionRoot(recycled, 4));
const tree = m.treeUnder(procs, procs[1]);
put("tree.under_2", tree.map((t) => t.p.pid).sort().join(","));
put("tree.chain_of_4", tree.find((t) => t.p.pid === 4).chain.map((a) => a.pid).join(","));

// background tasks: started and unfinished = live; finished, killed, or never backgrounded = not
const bash = (id, cmd) => JSON.stringify({ message: { content: [{ type: "tool_use", id, name: "Bash", input: { command: cmd } }] } });
const res = (id, bg) => JSON.stringify({ toolUseResult: { backgroundTaskId: bg }, message: { content: [{ type: "tool_result", tool_use_id: id, content: `Command running in background with ID: ${bg}. Output is being written to: x` }] } });
const note = (id, status) => JSON.stringify({ type: "queue-operation", content: `<task-notification>\n<task-id>${id}</task-id>\n<status>${status}</status>\n</task-notification>` });
const transcript = [
  bash("t1", "until grep -q ready /tmp/live.log; do sleep 5; done"), res("t1", "aaa"),
  bash("t2", "npm run build"), res("t2", "bbb"), note("bbb", "completed"),
  bash("t3", "sleep 9999"), res("t3", "ccc"), JSON.stringify({ message: { content: [{ type: "tool_use", id: "k", name: "KillShell", input: { shell_id: "ccc" } }] } }),
  bash("t4", "ls"),
  bash("t5", "slow --thing"), JSON.stringify({ message: { content: [{ type: "tool_result", tool_use_id: "t5", content: "Command exceeded timeout and is running in background with ID: ddd" }] } }),
  bash("t6", "make test"), res("t6", "eee"), note("eee", "running"),
  "not json at all with backgroundTaskId in it",
].join("\n");
const live = m.liveTasksFromTranscript(transcript);
put("bg.live", JSON.stringify(live));
put("bg.matches_ancestor", m.matchesLiveBackground({ cmd: "bash" }, [{ cmd: "bash -c \"eval 'until grep -q ready /tmp/live.log; do sleep 5; done' < /dev/null\"" }], { known: true, commands: live }));
put("bg.no_match_when_unknown", m.matchesLiveBackground({ cmd: "bash -c until grep -q ready /tmp/live.log; do sleep 5; done" }, [], { known: false, commands: live }));
put("bg.no_match_other", m.matchesLiveBackground({ cmd: "bash -c something entirely different here" }, [], { known: true, commands: live }));

// a transcript FILE larger than the 8 MB read chunk, with a live task whose lines straddle a chunk boundary
const big = path.join(scratch, "big.jsonl");
const pad = JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "x".repeat(2000) }] } });
const CHUNK = 8 * 1024 * 1024;
const lines = [];
let bytes = 0;
// pad until the next line would START about 60 bytes before the chunk boundary, then put the task
// lines there: the first of them is ~170 bytes long, so it is cut in two by the chunk read
while (bytes < CHUNK - 60) { lines.push(pad); bytes += pad.length + 1; }
lines.push(bash("big1", "until grep -q big /tmp/big.log; do sleep 5; done"), res("big1", "zzz"));
for (let i = 0; i < 400; i++) lines.push(pad);
writeFileSync(big, lines.join("\n") + "\n");
put("scan.big_file_over_one_chunk", lines.join("\n").length > CHUNK + 1000);
const sc = new m.TaskScanner();
m.scanTranscriptFile(big, sc);
put("scan.big_live", JSON.stringify(sc.live()));
put("scan.missing_file_throws", (() => { try { m.scanTranscriptFile(path.join(scratch, "nope.jsonl"), new m.TaskScanner()); return "no"; } catch { return "yes"; } })());

// which transcripts count: the session's, plus agents still writing; not the one that just stopped
const sess = path.join(scratch, "sess");
mkdirSync(path.join(sess, "subagents"), { recursive: true });
writeFileSync(sess + ".jsonl", "");
const recent = path.join(sess, "subagents", "agent-recent.jsonl");
const stale = path.join(sess, "subagents", "agent-stale.jsonl");
const stopped = path.join(sess, "subagents", "agent-stopped.jsonl");
for (const f of [recent, stale, stopped]) writeFileSync(f, "");
const old = new Date(Date.now() - 3 * 3600 * 1000);
utimesSync(stale, old, old);
const files = m.transcriptFiles({ transcript_path: sess + ".jsonl", agent_transcript_path: stopped, agent_id: "agent-stopped" }, Date.now());
put("tfiles.count", files.length);
put("tfiles.has_recent", files.some((f) => f.endsWith("agent-recent.jsonl")));
put("tfiles.has_stale", files.some((f) => f.endsWith("agent-stale.jsonl")));
put("tfiles.has_stopped", files.some((f) => f.endsWith("agent-stopped.jsonl")));
put("tfiles.main_first", files[0].endsWith("sess.jsonl"));
put("tfiles.none_without_payload", m.transcriptFiles({}, Date.now()).length);

const cfg = (obj, env = {}) => {
  mkdirSync(path.join(scratch, "cfgproj"), { recursive: true });
  writeFileSync(path.join(scratch, "cfgproj", "pipeline.config.json"), JSON.stringify(obj));
  return m.readReaperConfig(path.join(scratch, "cfgproj"), env);
};
const d = cfg({});
put("cfg.defaults", JSON.stringify({ mode: d.cfg.mode, age: d.cfg.minAgeMinutes, cpu: d.cfg.minCpuSeconds, pct: d.cfg.minCpuPercent, stale: d.cfg.staleFileMinutes, every: d.cfg.minIntervalMinutes, kp: d.cfg.killPatterns }));
put("cfg.override", JSON.stringify(cfg({ orphanReaper: { minAgeMinutes: 5, mode: "report" } }).cfg.minAgeMinutes));
put("cfg.bad_regex_dropped", cfg({ orphanReaper: { protectPatterns: ["(", "ok"] } }).cfg.protectPatterns.length);
put("cfg.not_an_object", cfg({ orphanReaper: 7 }).warnings.length);
put("cfg.env_report", cfg({}, { CLAUDE_PIPELINE_REAPER: "report" }).cfg.mode);
put("cfg.env_zero_is_off", cfg({ orphanReaper: { mode: "kill" } }, { CLAUDE_PIPELINE_REAPER: "0" }).cfg.mode);
put("brief.token_eq", m.brief("node x.js --token=S3CRET1 --next"));
put("brief.api_key_space", m.brief("node x.js --api-key S3CRET2 --next"));
put("brief.auth_bearer", m.brief("curl -H authorization: Bearer S3CRET3 https://h"));
put("brief.password_colon", m.brief("tool password:S3CRET4 run"));
put("brief.truncates", m.brief("x".repeat(500), 90).length);
put("brief.plain", m.brief("node server.js --port 8000"));
process.stdout.write(out.join("\n") + "\n");
MJS
REAPER_MJS="$REAPER" SCRATCH_DIR="$SCRATCH" node "$SCRATCH/units.mjs" > "$SCRATCH/units.txt" 2> "$SCRATCH/units.err"
assert_eq "the unit script ran" "$?" "0"
assert_eq "  ...with nothing on stderr" "$(cat "$SCRATCH/units.err")" ""
u() { awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$SCRATCH/units.txt"; }

assert_eq "ps duration: seconds" "$(u dur.ss)" "5"
assert_eq "ps duration: mm:ss" "$(u dur.mmss)" "754"
assert_eq "ps duration: hh:mm:ss" "$(u dur.hhmmss)" "3723"
assert_eq "ps duration: dd-hh:mm:ss" "$(u dur.dd)" "176400"
assert_eq "ps duration: macOS m:ss.hh" "$(u dur.mac_hundredths)" "1.5"
assert_eq "ps duration: junk is null, not 0" "$(u dur.junk)" "null"
assert_eq "ps rows: the garbage line is skipped" "$(u ps.count)" "3"
assert_eq "ps rows: pids" "$(u ps.pid)" "100,200,300"
assert_eq "ps rows: the name is the executable's basename" "$(u ps.name1)" "claude"
assert_eq "ps rows: start time is derived from elapsed time" "$(u ps.age2h)" "2"
assert_eq "ps rows: cpu seconds" "$(u ps.cpu2)" "3600"
assert_contains "ps rows: the whole command line is kept" "$(u ps.cmd2)" "until grep -q x /tmp/a; do sleep 5; done"
assert_eq "command line: quoted path, then args" "$(u args.win)" '["C:\\Program Files\\x\\python.exe","-","-u"]'
assert_eq "command line: bare exe" "$(u args.empty)" '["python.exe"]'

assert_eq "claude: the session CLI is a session root" "$(u claude.cli)" "true"
assert_eq "claude: the Desktop app's main process is NOT" "$(u claude.desktop_main)" "false"
assert_eq "claude: an Electron helper (--type=) is NOT" "$(u claude.electron_helper)" "false"
assert_eq "claude: a POSIX claude binary is" "$(u claude.posix)" "true"
assert_eq "claude: node running claude-code is" "$(u claude.node_cli)" "true"
assert_eq "claude: the macOS Desktop app's main process is NOT" "$(u claude.macos_desktop)" "false"
assert_eq "claude: something that merely mentions claude is NOT" "$(u claude.other)" "false"
assert_eq "root: the NEAREST claude ancestor, not the Desktop app above it" "$(u root.nearest)" "2"
assert_eq "root: a parent link from a younger process is not trusted" "$(u root.recycled_link)" "null"
assert_eq "tree: everything under the root, and no sibling's subtree" "$(u tree.under_2)" "3,4,5"
assert_eq "tree: the chain of ancestors below the root" "$(u tree.chain_of_4)" "3"

assert_eq "transcript: only the started-and-unfinished background tasks are live (a moved-to-background one with no finish, and a 'running' notification, are live too)" \
  "$(u bg.live)" '["until grep -q ready /tmp/live.log; do sleep 5; done","slow --thing","make test"]'
assert_eq "background match: found through an ANCESTOR's command line, across quoting differences" "$(u bg.matches_ancestor)" "true"
assert_eq "background match: nothing is protected when the transcript is unknown" "$(u bg.no_match_when_unknown)" "false"
assert_eq "background match: an unrelated command is not protected" "$(u bg.no_match_other)" "false"
assert_eq "the planted transcript really is bigger than one read chunk" "$(u scan.big_file_over_one_chunk)" "true"
assert_eq "a transcript file over the read chunk is scanned across the chunk boundary" "$(u scan.big_live)" '["until grep -q big /tmp/big.log; do sleep 5; done"]'
assert_eq "an unreadable transcript throws (the caller turns that into 'not known')" "$(u scan.missing_file_throws)" "yes"
assert_eq "transcripts: the session's and the still-writing agent's" "$(u tfiles.count)" "2"
assert_eq "  ...the recent agent counts" "$(u tfiles.has_recent)" "true"
assert_eq "  ...an agent that stopped writing hours ago does not (its tasks are orphans)" "$(u tfiles.has_stale)" "false"
assert_eq "  ...the agent that just stopped does not either" "$(u tfiles.has_stopped)" "false"
assert_eq "  ...the main transcript is first (it is the one that proves anything)" "$(u tfiles.main_first)" "true"
assert_eq "no payload, no transcripts" "$(u tfiles.none_without_payload)" "0"
assert_eq "config defaults" "$(u cfg.defaults)" '{"mode":"kill","age":60,"cpu":300,"pct":1,"stale":60,"every":10,"kp":["pythonStdinStub","waitLoop"]}'
assert_eq "config: a number overrides" "$(u cfg.override)" "5"
assert_eq "config: an invalid protectPatterns regex is dropped, a valid one kept" "$(u cfg.bad_regex_dropped)" "1"
assert_eq "config: orphanReaper that is not an object is a warning" "$(u cfg.not_an_object)" "1"
assert_eq "config: CLAUDE_PIPELINE_REAPER=report" "$(u cfg.env_report)" "report"
assert_eq "config: CLAUDE_PIPELINE_REAPER=0 is off, over a config that says kill" "$(u cfg.env_zero_is_off)" "off"
assert_eq "redaction: --token=VALUE hides the VALUE and leaves the next argument" "$(u brief.token_eq)" "node x.js --token=*** --next"
assert_eq "redaction: --api-key VALUE" "$(u brief.api_key_space)" "node x.js --api-key *** --next"
assert_eq "redaction: an Authorization: Bearer header hides the credential itself" "$(u brief.auth_bearer)" "curl -H authorization: Bearer *** https://h"
assert_eq "redaction: password:VALUE" "$(u brief.password_colon)" "tool password:*** run"
assert_eq "a long command line is cut to the limit plus an ellipsis" "$(u brief.truncates)" "93"
assert_eq "an ordinary command line is untouched" "$(u brief.plain)" "node server.js --port 8000"

# ===============================================================================================
suite "FAIL-OPEN: no process lister, read through the real CLI"
# ===============================================================================================
new_tmpdir || exit 90
FO_PROJ="$NEW_TMPDIR"
new_tmpdir || exit 90
FO_STATE="$NEW_TMPDIR"
# A PATH with no PowerShell and no ps in it, and the real node by absolute path.
FO_ERR="$SCRATCH/fo.err"
FO_OUT=$(env PATH="/nonexistent-reaper-test" CLAUDE_PIPELINE_REAPER=kill CLAUDE_PIPELINE_REAPER_DIR="$FO_STATE" \
  "$NODE_BIN" "$REAPER" --event manual --project-dir "$FO_PROJ" </dev/null 2>"$FO_ERR")
FO_RC=$?
assert_eq "no PowerShell / ps on PATH: exit 3 (the hook turns that into a disarm line)" "$FO_RC" "3"
assert_eq "  ...nothing on stdout" "$FO_OUT" ""
assert_contains "  ...one line on stderr names the gap" "$(cat "$FO_ERR")" "reap-orphans: disarm: the process list could not be read"

FO_OUT=$(env PATH="/nonexistent-reaper-test" CLAUDE_PIPELINE_REAPER=off CLAUDE_PIPELINE_REAPER_DIR="$FO_STATE" \
  "$NODE_BIN" "$REAPER" --event manual --project-dir "$FO_PROJ" </dev/null 2>"$FO_ERR")
assert_eq "mode off: exit 0 and silent even with no lister (it never looks)" "$?:$FO_OUT:$(cat "$FO_ERR")" "0::"

FO_OUT=$(env CLAUDE_PIPELINE_REAPER=kill CLAUDE_PIPELINE_REAPER_DIR="$FO_STATE" \
  "$NODE_BIN" "$REAPER" --event manual --project-dir "$FO_PROJ" --root-pid 999999 </dev/null 2>"$FO_ERR")
assert_eq "an explicit --root-pid that is not running: exit 0" "$?" "0"
assert_eq "  ...touches nothing and prints nothing" "$FO_OUT" ""
assert_contains "  ...and says why on stderr" "$(cat "$FO_ERR")" "--root-pid 999999 is not in the process list"

FO_OUT=$(env CLAUDE_PIPELINE_REAPER=kill CLAUDE_PIPELINE_REAPER_DIR="$FO_STATE" \
  "$NODE_BIN" "$REAPER" --event SubagentStop --project-dir "$FO_PROJ" </dev/null 2>"$FO_ERR")
assert_eq "run from a terminal with no claude ancestor: exit 0 (the suite itself is not under claude... or it is, and finds nothing old)" "$?" "0"

# ===============================================================================================
suite "REAL PROCESSES: a planted orphan is killed; a fresh-file loop, a loop outside the tree and the root are not"
# ===============================================================================================
cat > "$SCRATCH/plant.mjs" <<'MJS'
// Plants, under THIS process as the root: a wait loop polling a STALE log and one polling a FRESH log.
// Prints their pids (the native ones the process table uses). Exits, taking its children with it,
// when <dir>/stop appears, and in any case after 3 minutes, so a crashed suite leaks nothing for long.
import { spawn } from "node:child_process";
import { existsSync, utimesSync, writeFileSync } from "node:fs";
import path from "node:path";
const [dir, bash, which] = process.argv.slice(2);
const stale = path.join(dir, `stale-${which}.log`);
const fresh = path.join(dir, `fresh-${which}.log`);
writeFileSync(stale, "running\n");
const old = new Date(Date.now() - 3 * 3600 * 1000);
utimesSync(stale, old, old);
writeFileSync(fresh, "running\n");
const loop = (log) => spawn(bash, ["-c", `until grep -q "^exit" "${log}"; do sleep 1; done`], { stdio: "ignore" });
const kids = [loop(stale)];
if (which === "main") kids.push(loop(fresh));
process.stdout.write(JSON.stringify({ root: process.pid, stale: kids[0].pid, fresh: kids[1]?.pid ?? 0 }) + "\n");
const bye = () => {
  for (const k of kids) try { k.kill(); } catch {}
  process.exit(0);
};
setInterval(() => existsSync(path.join(dir, "stop")) && bye(), 300);
setTimeout(bye, 180000);
MJS
cat > "$SCRATCH/alive.mjs" <<'MJS'
for (const pid of process.argv.slice(2).map(Number)) {
  let alive = true;
  try { process.kill(pid, 0); } catch (e) { alive = e.code === "EPERM"; }
  console.log(`${pid}=${alive ? "alive" : "dead"}`);
}
MJS

BASH_BIN="$(command -v bash)"
new_tmpdir || exit 90
PLANT_DIR="$NEW_TMPDIR"
new_tmpdir || exit 90
PLANT_PROJ="$NEW_TMPDIR"
new_tmpdir || exit 90
PLANT_STATE="$NEW_TMPDIR"
# thresholds at zero so a process planted seconds ago is a candidate; the stale-file proof still stands
printf '{"orphanReaper":{"minAgeMinutes":0,"minCpuSeconds":0,"minCpuPercent":0,"staleFileMinutes":60,"minIntervalMinutes":0}}\n' > "$PLANT_PROJ/pipeline.config.json"

node "$SCRATCH/plant.mjs" "$PLANT_DIR" "$BASH_BIN" main > "$PLANT_DIR/main.json" 2>/dev/null &
node "$SCRATCH/plant.mjs" "$PLANT_DIR" "$BASH_BIN" other > "$PLANT_DIR/other.json" 2>/dev/null &
for _ in $(seq 1 100); do
  [[ -s "$PLANT_DIR/main.json" && -s "$PLANT_DIR/other.json" ]] && break
  sleep 0.2
done
eval "$(node -e '
const fs = require("fs");
const [m, o] = process.argv.slice(1).map((f) => JSON.parse(fs.readFileSync(f, "utf8")));
console.log("MAIN_ROOT=" + m.root + "; MAIN_STALE=" + m.stale + "; MAIN_FRESH=" + m.fresh + "; OTHER_STALE=" + o.stale);
' "$PLANT_DIR/main.json" "$PLANT_DIR/other.json")"
record "planted: root=$MAIN_ROOT stale-loop=$MAIN_STALE fresh-loop=$MAIN_FRESH outside-tree-stale-loop=$OTHER_STALE"
sleep 1

if optional_tool ps || [[ "$PIPELINE_ON_WINDOWS" = 1 ]]; then
  PLANT_OUT=$(env CLAUDE_PIPELINE_REAPER=kill CLAUDE_PIPELINE_REAPER_DIR="$PLANT_STATE" \
    "$NODE_BIN" "$REAPER" --event manual --project-dir "$PLANT_PROJ" --root-pid "$MAIN_ROOT" </dev/null 2>"$PLANT_DIR/reaper.err")
  PLANT_RC=$?
  sleep 1
  node "$SCRATCH/alive.mjs" "$MAIN_ROOT" "$MAIN_STALE" "$MAIN_FRESH" "$OTHER_STALE" > "$PLANT_DIR/alive.txt"
  alive() { grep -m1 "^$1=" "$PLANT_DIR/alive.txt" | cut -d= -f2; }
  assert_eq "the reaper exits 0" "$PLANT_RC" "0"
  assert_eq "THE PLANTED ORPHAN (a real bash polling a 3-hour-old log) is dead" "$(alive "$MAIN_STALE")" "dead"
  assert_eq "the loop polling a FRESH log, in the same tree, is alive" "$(alive "$MAIN_FRESH")" "alive"
  assert_eq "the stale loop under ANOTHER root (outside the tree) is alive" "$(alive "$OTHER_STALE")" "alive"
  assert_eq "the root itself is alive" "$(alive "$MAIN_ROOT")" "alive"
  assert_contains "the summary names the kill" "$PLANT_OUT" "killed 1"
  assert_contains "the summary reports the fresh-file loop it left running" "$PLANT_OUT" "recently written"
  assert_contains "the log has the kill" "$(cat "$PLANT_STATE/reaper.log" 2>/dev/null)" "KILLED pid $MAIN_STALE"
  assert_not_contains "and does not mention the outside-tree loop at all" "$PLANT_OUT" "pid $OTHER_STALE"
else
  record "CAPABILITY \`ps\` is absent: the real-process cells were NOT run"
  [[ "$CAPABILITY_STRICT" = 1 ]] && assert_eq "ps is required under PIPELINE_TESTS_REQUIRE_CAPABILITIES=1" "absent" "present"
fi

# let the planted roots take their children with them
: > "$PLANT_DIR/stop"
sleep 1.5

# ===============================================================================================
suite "HOOKS: hooks/reaper.sh plumbing, through the three hooks, with a stub reaper"
# ===============================================================================================
new_tmpdir || exit 90
STUB="$NEW_TMPDIR"
mkdir -p "$STUB/scripts"
printf 'process.exit(0);\n' > "$STUB/scripts/validate-pipeline-artifact.mjs"
export STUB_MARK="$STUB/ran"
MARK="$STUB_MARK"
# A stand-in reaper, kept outside scripts/ so a case can remove the installed copy and put it back.
cat > "$STUB/reaper.keep" <<'MJS'
// Records its argv and stdin, then prints and exits as the STUB_* variables say.
import { appendFileSync, readFileSync } from "node:fs";
let payload = "";
try { payload = readFileSync(0, "utf8"); } catch {}
appendFileSync(process.env.STUB_MARK, JSON.stringify({ argv: process.argv.slice(2), payload }) + "\n");
if (process.env.STUB_ERR) process.stderr.write(process.env.STUB_ERR + "\n");
if (process.env.STUB_OUT) process.stdout.write(process.env.STUB_OUT + "\n");
process.exitCode = Number(process.env.STUB_RC || 0);
MJS
write_stub() { # <stdout-text> <exit-code> [stderr-text]
  export STUB_OUT="$1" STUB_RC="$2" STUB_ERR="${3:-}"
  [[ -f "$STUB/scripts/reap-orphans.mjs" ]] || cp "$STUB/reaper.keep" "$STUB/scripts/reap-orphans.mjs"
}
no_marks() { [[ ! -f "$MARK" ]] && echo yes || echo no; }

SS_PAYLOAD='{"hook_event_name":"SubagentStop","session_id":"s1","transcript_path":"/t/s1.jsonl","agent_id":"a1"}'
run_subagent_stop() { # <repo> [extra env...] -> OUT, ERR, RC
  local repo="$1"; shift
  OUT=$(printf '%s' "$SS_PAYLOAD" | env CLAUDE_PROJECT_DIR="$repo" CLAUDE_PLUGIN_ROOT="$STUB" CLAUDE_PIPELINE_REAPER=kill "$@" \
    bash "$HOOKS_DIR/subagent-stop.sh" 2>"$SCRATCH/hook.err")
  RC=$?
  ERR="$(cat "$SCRATCH/hook.err")"
}

REPO=$(make_repo)
write_stub "orphan reaper: killed 1. killed pid 30 bash.exe (wait loop)." 0
run_subagent_stop "$REPO"
assert_eq "SubagentStop: exits 0" "$RC" "0"
assert_eq "SubagentStop: stdout is ONE line" "$(printf '%s\n' "$OUT" | grep -c .)" "1"
assert_contains "SubagentStop: the summary leaves as the hook's systemMessage" "$OUT" '{"systemMessage":"agent-pipeline: orphan reaper: killed 1.'
assert_contains "SubagentStop: the payload (with transcript_path) reaches the reaper on stdin" "$(cat "$MARK")" 'transcript_path'
assert_contains "SubagentStop: the event is passed" "$(cat "$MARK")" '"argv":["--event","SubagentStop"]'

: > "$MARK"; rm -f "$MARK"
BLOCKSTUB="$SCRATCH/blockroot"; mkdir -p "$BLOCKSTUB/scripts"
cp "$STUB/scripts/reap-orphans.mjs" "$BLOCKSTUB/scripts/"
printf 'process.stdout.write(JSON.stringify({ decision: "block", reason: "spec.json failed validation" }));\n' > "$BLOCKSTUB/scripts/validate-pipeline-artifact.mjs"
OUT=$(printf '%s' "$SS_PAYLOAD" | env CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$BLOCKSTUB" CLAUDE_PIPELINE_REAPER=kill bash "$HOOKS_DIR/subagent-stop.sh" 2>/dev/null)
assert_contains "SubagentStop: a validator decision is passed through" "$OUT" '"decision":"block"'
assert_not_contains "SubagentStop: and the reaper's summary does NOT join it (one JSON object, the decision wins)" "$OUT" "orphan reaper"

rm -f "$MARK"
write_stub "orphan reaper: killed 1." 0
run_subagent_stop "$REPO" CLAUDE_PIPELINE_REAPER=off
assert_eq "SubagentStop: CLAUDE_PIPELINE_REAPER=off never starts the reaper" "$(no_marks)" "yes"
assert_eq "SubagentStop: ...and prints nothing" "$OUT" ""

rm -f "$STUB/scripts/reap-orphans.mjs"
run_subagent_stop "$REPO"
assert_eq "SubagentStop: a missing reaper script is silent and exits 0" "$RC:$OUT" "0:"

write_stub "" 3 "reap-orphans: disarm: the process list could not be read: PowerShell was not found"
run_subagent_stop "$REPO"
assert_eq "SubagentStop: exit 3 (no lister) outside a pipeline project exits 0 with no stdout" "$RC:$OUT" "0:"
assert_contains "SubagentStop: ...and one stderr line says the reaper did not run" "$ERR" "orphan reaper did not run: the process list could not be read: PowerShell was not found"
mkdir -p "$REPO/.pipeline"
run_subagent_stop "$REPO"
assert_eq "SubagentStop: the same in a project with .pipeline exits 0" "$RC" "0"
assert_contains "SubagentStop: ...and is a disarm line (the 0.43.0 rule): a systemMessage" "$OUT" 'pipeline check orphan-reaper did not run: the process list could not be read: PowerShell was not found'
assert_eq "SubagentStop: ...as ONE object" "$(printf '%s\n' "$OUT" | grep -c .)" "1"

write_stub "" 1
run_subagent_stop "$REPO"
assert_eq "SubagentStop: a crashing reaper exits 0" "$RC" "0"
assert_contains "SubagentStop: ...and says it crashed" "$OUT" "scripts/reap-orphans.mjs exited 1"

write_stub "" 0 "reap-orphans: orphanReaper.mode must be kill, report or off (got \"nuke\")"
run_subagent_stop "$REPO"
assert_eq "SubagentStop: config warnings are not a failure (exit 0, no systemMessage)" "$RC:$OUT" "0:"
assert_contains "SubagentStop: ...but the owner can see them on stderr" "$ERR" 'orphanReaper.mode must be kill, report or off'

# Stop
rm -f "$STUB/scripts/reap-orphans.mjs"
REPO2=$(make_repo)
write_stub "orphan reaper: killed 2." 0
OUT=$(printf '%s' '{"hook_event_name":"Stop","session_id":"s1","transcript_path":"/t/s1.jsonl"}' | env CLAUDE_PROJECT_DIR="$REPO2" CLAUDE_PLUGIN_ROOT="$STUB" CLAUDE_PIPELINE_REAPER=kill bash "$HOOKS_DIR/stop.sh" 2>/dev/null)
assert_eq "Stop: exits 0 on a clean tree" "$?" "0"
assert_contains "Stop: the summary leaves as the systemMessage the EXIT trap prints" "$OUT" '"systemMessage":"agent-pipeline: orphan reaper: killed 2.'
assert_contains "Stop: the event is passed" "$(cat "$MARK")" '"argv":["--event","Stop"]'
rm -f "$MARK"
OUT=$(printf '%s' '{"hook_event_name":"Stop"}' | env CLAUDE_PROJECT_DIR="$REPO2" CLAUDE_PLUGIN_ROOT="$STUB" CLAUDE_PIPELINE_REAPER=off CLAUDE_HOOK_STOP_SKIP=1 bash "$HOOKS_DIR/stop.sh" 2>/dev/null)
assert_eq "Stop: CLAUDE_PIPELINE_REAPER=off never starts the reaper" "$(no_marks)" "yes"
OUT=$(printf '%s' '{"hook_event_name":"Stop"}' | env CLAUDE_PROJECT_DIR="$REPO2" CLAUDE_PLUGIN_ROOT="$STUB" CLAUDE_PIPELINE_REAPER=kill CLAUDE_HOOK_STOP_SKIP=1 bash "$HOOKS_DIR/stop.sh" 2>/dev/null)
assert_contains "Stop: CLAUDE_HOOK_STOP_SKIP (the voice-lint/check bypass) does not skip the reaper" "$OUT" "orphan reaper: killed 2."

# SessionStart
OUT=$(CLAUDE_PROJECT_DIR="$REPO2" CLAUDE_PLUGIN_ROOT="$STUB" CLAUDE_PIPELINE_REAPER=kill bash "$HOOKS_DIR/session-start.sh" </dev/null 2>/dev/null)
assert_eq "SessionStart: exits 0" "$?" "0"
assert_contains "SessionStart: the summary is in the warmup context the MODEL reads" "$OUT" "orphan reaper: killed 2."
assert_contains "SessionStart: and it is inside the warmup banners" "$OUT" "=== END WARMUP ==="
assert_contains "SessionStart: the event is passed, and no payload is piped (the script reads the inherited stdin)" "$(tail -1 "$MARK")" '"argv":["--event","SessionStart"],"payload":""'
rm -f "$MARK"
write_stub "" 0
OUT=$(CLAUDE_PROJECT_DIR="$REPO2" CLAUDE_PLUGIN_ROOT="$STUB" CLAUDE_PIPELINE_REAPER=kill bash "$HOOKS_DIR/session-start.sh" </dev/null 2>/dev/null)
assert_not_contains "SessionStart: nothing to say is no line (silent when there is nothing)" "$OUT" "orphan reaper"
write_stub "" 3 "reap-orphans: disarm: the process list could not be read: ps could not run"
OUT=$(CLAUDE_PROJECT_DIR="$REPO2" CLAUDE_PLUGIN_ROOT="$STUB" CLAUDE_PIPELINE_REAPER=kill bash "$HOOKS_DIR/session-start.sh" </dev/null 2>/dev/null)
assert_eq "SessionStart: a reaper that cannot list processes does not break the warmup" "$?" "0"
assert_contains "SessionStart: ...the report is still complete" "$OUT" "=== END WARMUP ==="

# node absent: the plumbing says so and returns
OUT=$(env PATH="/nonexistent-reaper-test" CLAUDE_PLUGIN_ROOT="$STUB" CLAUDE_PROJECT_DIR="$REPO2" CLAUDE_PIPELINE_REAPER=kill \
  /bin/sh -c ". \"$HOOKS_DIR/reaper.sh\"; reap_orphans SubagentStop SubagentStop '{}'; echo \"rc=\$? summary=[\$REAP_SUMMARY]\"" 2>"$SCRATCH/nonode.err")
assert_eq "reaper.sh: with no node on PATH it returns 0 with an empty summary" "$OUT" "rc=0 summary=[]"
assert_contains "reaper.sh: ...and says node was the gap" "$(cat "$SCRATCH/nonode.err")" "node is not on this hook's PATH"

finish
