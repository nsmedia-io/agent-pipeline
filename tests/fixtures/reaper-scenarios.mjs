// The planted process tables tests/test-reap-orphans.sh asks the reaper about. Imported by
// reaper-driver.mjs; every scenario is a table of processes, a clock, a config and (where it
// matters) the files the wait loops poll and the background tasks the session still has.
//
// THE BASE TABLE mirrors the shape measured on the owner's host (2026-10-02): the Desktop app's own
// claude.exe, the session's CLI claude.exe under it, a hook chain (bash -> node = the reaper)
// under the CLI, and under the CLI the orphans: a bash holding `until grep -q "^exit" <log>; do
// sleep 10; done`, and python.exe <- python3.exe <- bash -c "...python3 - <<E...".

const WIN = String.raw;
export const DESKTOP = 1;
export const CLI = 10;
export const HOOK_BASH = 20;
export const SELF = 21;
export const LOOP = 30;
export const PY_SHELL = 32;
export const PY_STUB = 33;
export const PY = 34;

const LOOP_CMD = String.raw`"C:\Program Files\Git\bin\bash.exe" -c "source ~/.claude/shell-snapshots/snapshot-bash-1.sh && eval 'until grep -q \"^exit\" /tmp/agent.log; do sleep 10; done' < /dev/null"`;
const PY_PROGRAM = "python3 - <<'E'\nimport time\nwhile True: pass\nE";

export const proc = (pid, ppid, name, ageMin, cpuSec, cmd) => ({ pid, ppid, name, ageMin, cpuSec, cmd: cmd ?? name });

export const base = () => [
  proc(DESKTOP, 0, "claude.exe", 5000, 9000, WIN`"C:\Program Files\WindowsApps\Claude_2.16_x64__abc\app\claude.exe"`),
  proc(CLI, DESKTOP, "claude.exe", 4000, 4000, WIN`C:\Users\u\AppData\Roaming\Claude\claude-code\2.1.284\claude.exe --output-format stream-json --resume=abc`),
  proc(HOOK_BASH, CLI, "bash.exe", 1, 1, "bash.exe hooks/subagent-stop.sh"),
  proc(SELF, HOOK_BASH, "node.exe", 0, 0, "node reap-orphans.mjs --event SubagentStop"),
];

export const waitLoop = (over = {}) => proc(LOOP, CLI, "bash.exe", 1500, 4500, over.cmd ?? LOOP_CMD);

export const pyTree = () => [
  proc(PY_SHELL, CLI, "bash.exe", 1400, 10, `bash.exe -c "source ~/.claude/shell-snapshots/snapshot-bash-2.sh && eval 'python3 - <<E\nimport time\nwhile True: pass\nE' < /dev/null"`),
  proc(PY_STUB, PY_SHELL, "python3.exe", 1400, 5, WIN`"C:\Users\u\AppData\Local\Microsoft\WindowsApps\python3.exe" -`),
  proc(PY, PY_STUB, "python.exe", 1400, 5000, WIN`C:\Users\u\AppData\Local\Microsoft\WindowsApps\PythonSoftwareFoundation.Python.3.12_x\python.exe -`),
];

const NOW = 1_790_000_000_000;
const withBase = (...extra) => [...base(), ...extra.flat()];
const STALE = { "/tmp/agent.log": 1500 };

export const scenarios = [
  // ---- the kills ----------------------------------------------------------------------------
  { name: "waitloop_stale", selfPid: SELF, procs: withBase(waitLoop()), mtimes: STALE },
  {
    // the POSIX `ps` spelling of the same process: `bash -c <script>` with no quotes around the script
    name: "waitloop_stale_posix_ps_form",
    selfPid: SELF,
    procs: withBase(waitLoop({ cmd: "/usr/bin/bash -c until grep -q \"^exit\" /tmp/agent.log; do sleep 10; done" })),
    mtimes: STALE,
  },
  { name: "waitloop_stale_sigkill", selfPid: SELF, ignoreTerm: true, procs: withBase(waitLoop()), mtimes: STALE },
  { name: "waitloop_stale_bg_unknown", selfPid: SELF, bg: { known: false, commands: [] }, procs: withBase(waitLoop()), mtimes: STALE },
  { name: "python_stub_win", selfPid: SELF, platform: "win32", bg: { known: true, commands: [] }, procs: withBase(pyTree()) },
  // ---- the same orphans, but not provably dead: reported, never killed -----------------------
  { name: "waitloop_fresh_file", selfPid: SELF, procs: withBase(waitLoop()), mtimes: { "/tmp/agent.log": 2 } },
  { name: "waitloop_missing_file", selfPid: SELF, procs: withBase(waitLoop()), mtimes: {} },
  {
    name: "waitloop_no_file_named",
    selfPid: SELF,
    procs: withBase(waitLoop({ cmd: `bash.exe -c "eval 'until [ -f $MARKER ]; do sleep 10; done'"` })),
    mtimes: STALE,
  },
  {
    name: "waitloop_bounded",
    selfPid: SELF,
    procs: withBase(waitLoop({ cmd: `bash.exe -c "timeout 600 bash -c 'until grep -q ready /tmp/agent.log; do sleep 10; done'"` })),
    mtimes: STALE,
  },
  {
    name: "waitloop_counter_bounded",
    selfPid: SELF,
    procs: withBase(waitLoop({ cmd: `bash.exe -c "n=0; until grep -q ready /tmp/agent.log; do n=$((n+1)); [ $n -gt 30 ] && break; sleep 10; done"` })),
    mtimes: STALE,
  },
  { name: "python_stub_linux", selfPid: SELF, platform: "linux", bg: { known: true, commands: [] }, procs: withBase(pyTree()) },
  { name: "python_stub_bg_unknown", selfPid: SELF, platform: "win32", bg: { known: false, commands: [] }, procs: withBase(pyTree()) },
  { name: "python_stub_live_bg", selfPid: SELF, platform: "win32", bg: { known: true, commands: [PY_PROGRAM] }, procs: withBase(pyTree()) },
  {
    name: "python_with_script",
    selfPid: SELF,
    platform: "win32",
    bg: { known: true, commands: [] },
    procs: withBase(proc(PY, CLI, "python.exe", 1400, 5000, WIN`C:\Python312\python.exe server.py --port 8000`)),
  },
  {
    name: "waitloop_live_bg",
    selfPid: SELF,
    bg: { known: true, commands: [`until grep -q "^exit" /tmp/agent.log; do sleep 10; done`] },
    procs: withBase(waitLoop()),
    mtimes: STALE,
  },
  {
    name: "loop_text_in_non_shell",
    selfPid: SELF,
    procs: withBase(proc(LOOP, CLI, "node.exe", 1500, 4500, `node.exe -e "run('until grep -q x /tmp/agent.log; do sleep 10; done')"`)),
    mtimes: STALE,
  },
  // ---- the never-touch list ------------------------------------------------------------------
  { name: "outside_tree", selfPid: SELF, procs: [...base(), proc(11, DESKTOP, "claude.exe", 4000, 4000, WIN`C:\Users\u\AppData\Roaming\Claude\claude-code\2.1.284\claude.exe --output-format stream-json`), proc(LOOP, 11, "bash.exe", 1500, 4500, LOOP_CMD)], mtimes: STALE },
  {
    name: "protected_processes",
    selfPid: SELF,
    platform: "win32",
    bg: { known: true, commands: [] },
    procs: withBase(
      proc(100, CLI, "docker.exe", 1500, 6000, "docker compose up"),
      proc(101, CLI, "com.docker.backend.exe", 1500, 6000, "com.docker.backend.exe"),
      proc(102, CLI, "wsl.exe", 1500, 6000, "wsl.exe -d Ubuntu"),
      proc(103, CLI, "vmmem", 1500, 6000, "vmmem"),
      proc(104, CLI, "Runner.Worker.exe", 1500, 6000, "Runner.Worker.exe spawnclient"),
      proc(105, CLI, "node.exe", 1500, 6000, "node.exe node_modules/vite/bin/vite.js --port 5173"),
      proc(106, CLI, "node.exe", 1500, 6000, "node.exe C:/tools/playwright-mcp/cli.js --mcp-server"),
      proc(107, CLI, "node.exe", 1500, 6000, WIN`node.exe C:\w\.claude\launch.json-runner.js`),
      proc(108, CLI, "node.exe", 1500, 6000, "node.exe C:/x/node_modules/.bin/next dev"),
      proc(109, CLI, "node.exe", 1500, 6000, "pnpm run dev"),
      // a spinning stub UNDER a Docker ancestor is still never touched
      proc(110, 100, "python.exe", 1400, 5000, WIN`C:\Python312\python.exe -`),
      proc(111, 100, "bash.exe", 1400, 4500, LOOP_CMD),
    ),
    mtimes: STALE,
  },
  { name: "protect_patterns", selfPid: SELF, config: { protectPatterns: ["agent\\.log"] }, procs: withBase(waitLoop()), mtimes: STALE },
  {
    name: "claude_never_killed",
    selfPid: SELF,
    procs: withBase(proc(60, CLI, "claude.exe", 1500, 6000, WIN`C:\Users\u\AppData\Roaming\Claude\claude-code\2.1.284\claude.exe --output-format stream-json`)),
  },
  {
    name: "own_chain_never_killed",
    selfPid: SELF,
    procs: [
      proc(DESKTOP, 0, "claude.exe", 5000, 9000, WIN`"C:\Program Files\WindowsApps\Claude_2.16_x64__abc\app\claude.exe"`),
      proc(CLI, DESKTOP, "claude.exe", 4000, 4000, WIN`C:\Users\u\AppData\Roaming\Claude\claude-code\2.1.284\claude.exe --output-format stream-json`),
      proc(HOOK_BASH, CLI, "bash.exe", 1500, 4500, LOOP_CMD),
      proc(SELF, HOOK_BASH, "node.exe", 0, 0, "node reap-orphans.mjs"),
    ],
    mtimes: STALE,
  },
  {
    name: "pid_reuse_not_a_child",
    selfPid: SELF,
    // the loop is OLDER than the "parent" it names: a recycled pid, so it is not in the tree
    procs: withBase(proc(LOOP, CLI, "bash.exe", 6000, 9000, LOOP_CMD)),
    mtimes: { "/tmp/agent.log": 6000 },
  },
  { name: "no_claude_ancestor", selfPid: SELF, procs: [proc(HOOK_BASH, 999, "bash.exe", 1, 1), proc(SELF, HOOK_BASH, "node.exe", 0, 0), proc(LOOP, 998, "bash.exe", 1500, 4500, LOOP_CMD)], mtimes: STALE },
  {
    name: "desktop_main_is_not_a_root",
    selfPid: SELF,
    procs: [
      proc(DESKTOP, 0, "claude.exe", 5000, 9000, WIN`"C:\Program Files\WindowsApps\Claude_2.16_x64__abc\app\claude.exe"`),
      proc(HOOK_BASH, DESKTOP, "bash.exe", 1, 1),
      proc(SELF, HOOK_BASH, "node.exe", 0, 0),
      // another session's orphan, under the Desktop app but not under THIS hook's session
      proc(LOOP, DESKTOP, "bash.exe", 1500, 4500, LOOP_CMD),
    ],
    mtimes: STALE,
  },
  // ---- thresholds ----------------------------------------------------------------------------
  {
    name: "thresholds",
    selfPid: SELF,
    procs: withBase(
      proc(200, CLI, "node.exe", 59, 6000, "node young.js"), //            too young
      proc(201, CLI, "node.exe", 1500, 299, "node lowcpu.js"), //          under minCpuSeconds
      proc(202, CLI, "node.exe", 6000, 400, "node idle.js"), //            under minCpuPercent (0.1%)
      proc(203, CLI, "node.exe", 60, 300, "node exactly-at-the-line.js"), // on every threshold: a candidate
    ),
  },
  // ---- modes and config ----------------------------------------------------------------------
  { name: "mode_report", selfPid: SELF, config: { mode: "report" }, procs: withBase(waitLoop()), mtimes: STALE },
  { name: "mode_off_config", selfPid: SELF, config: { mode: "off" }, procs: withBase(waitLoop()), mtimes: STALE },
  { name: "mode_off_env", selfPid: SELF, env: { CLAUDE_PIPELINE_REAPER: "off" }, procs: withBase(waitLoop()), mtimes: STALE },
  { name: "mode_env_overrides_config", selfPid: SELF, config: { mode: "off" }, env: { CLAUDE_PIPELINE_REAPER: "kill" }, procs: withBase(waitLoop()), mtimes: STALE },
  { name: "killpatterns_without_waitloop", selfPid: SELF, config: { killPatterns: ["pythonStdinStub"] }, procs: withBase(waitLoop()), mtimes: STALE },
  { name: "killpatterns_unknown_name", selfPid: SELF, config: { killPatterns: ["waitLoop", "rm-everything"] }, procs: withBase(waitLoop()), mtimes: STALE },
  { name: "bad_config_values", selfPid: SELF, config: { mode: "nuke", minAgeMinutes: -5, minCpuSeconds: "lots" }, procs: withBase(waitLoop()), mtimes: STALE },
  { name: "custom_thresholds", selfPid: SELF, config: { minAgeMinutes: 2000 }, procs: withBase(waitLoop()), mtimes: STALE },
  // ---- confirm-before-kill -------------------------------------------------------------------
  { name: "confirm_process_gone", selfPid: SELF, procs: withBase(waitLoop()), second: base(), mtimes: STALE },
  {
    name: "confirm_pid_reused",
    selfPid: SELF,
    procs: withBase(waitLoop()),
    second: withBase(proc(LOOP, CLI, "bash.exe", 3, 1, LOOP_CMD)),
    mtimes: STALE,
  },
  // ---- throttle, memory, dry run, failures ---------------------------------------------------
  {
    name: "throttle",
    selfPid: SELF,
    procs: withBase(waitLoop()),
    mtimes: STALE,
    runs: [
      { event: "SubagentStop" },
      { event: "SubagentStop", now: NOW + 5 * 60000 },
      { event: "Stop", now: NOW + 5 * 60000 },
      { event: "SessionStart", now: NOW + 5 * 60000 },
      { event: "Stop", now: NOW + 20 * 60000 },
    ],
  },
  {
    name: "reported_once",
    selfPid: SELF,
    event: "SessionStart",
    procs: withBase(proc(210, CLI, "node.exe", 1500, 4500, "node long-running-job.js")),
    // the same process one minute later: its start time does not move, so its age grows by a minute
    runs: [{}, { now: NOW + 60000, procs: withBase(proc(210, CLI, "node.exe", 1501, 4500, "node long-running-job.js")) }],
  },
  { name: "dry_run", selfPid: SELF, dryRun: true, procs: withBase(waitLoop()), mtimes: STALE, runs: [{ event: "SubagentStop" }, { event: "SubagentStop", now: NOW + 60000 }] },
  { name: "collect_failure", selfPid: SELF, collectFailure: "the process list could not be read: PowerShell was not found", procs: withBase(waitLoop()), mtimes: STALE },
  {
    name: "redaction",
    selfPid: SELF,
    procs: withBase(proc(220, CLI, "node.exe", 1500, 4500, "node uploader.js --token=SECRET123 --api-key ABCDEF987")),
  },
];
