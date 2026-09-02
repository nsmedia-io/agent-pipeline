"""Re-derives captured-records.json from the live Claude Code transcripts on THIS machine.

TWO INPUTS, AND ONLY ONE OF THEM IS PORTABLE (#91). The OUTPUT path is derived from this file's
own location, so the script writes beside itself in whatever checkout it is run from; it used to
be an absolute path naming an author's home directory and an ephemeral worktree, which made the
documented re-derivation recipe break the moment that worktree was removed.

THE INPUT IS NOT PORTABLE AND CANNOT BE MADE SO, so the constraint is stated rather than hidden:
these fixtures are captured from real transcripts, and transcripts are not in the repo and never
will be (they are the owner's conversations). Running this on a machine with no Claude Code
history exits non-zero naming the class it could not find, rather than writing a thinner file
that would silently weaken every cell it feeds. The transcript root defaults to
~/.claude/projects and can be pointed elsewhere with CLAUDE_PROJECTS_DIR.
"""

import glob, json, collections, datetime, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "captured-records.json")
PROJECTS = os.environ.get("CLAUDE_PROJECTS_DIR") or os.path.expanduser("~/.claude/projects")
files = sorted(glob.glob(os.path.join(PROJECTS, '*', '*.jsonl')))
if not files:
    sys.exit("NO TRANSCRIPTS under " + PROJECTS + ". Set CLAUDE_PROJECTS_DIR, or run this on a "
             "machine with Claude Code history: these fixtures are CAPTURED, never hand-written.")

def content_str(r):
    c = r.get('message', {}).get('content')
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(b.get('text', '') for b in c if isinstance(b, dict) and b.get('type') == 'text')
    return ""

want = {}
counts = collections.Counter()
for f in files:
    for line in open(f, errors='replace'):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if not isinstance(r, dict) or r.get('type') != 'user':
            continue
        o = r.get('origin')
        k = o.get('kind') if isinstance(o, dict) else None
        c = r.get('message', {}).get('content')
        txt = content_str(r)
        def take(name, cond):
            if cond:
                counts[name] += 1
                want.setdefault(name, r)
        take('owner_string', k == 'human' and isinstance(c, str))
        take('owner_image_array', k == 'human' and isinstance(c, list)
             and any(isinstance(b, dict) and b.get('type') == 'image' for b in c))
        take('task_notification', k == 'task-notification')
        take('auto_compaction', bool(r.get('isCompactSummary')))
        take('cross_session_peer', k == 'peer')
        take('voice_lint_refusal', bool(r.get('isMeta')) and txt.startswith('Stop hook feedback:'))
        take('tool_result', isinstance(c, list)
             and any(isinstance(b, dict) and b.get('type') == 'tool_result' for b in c))

REDACT = "[content redacted at capture; the predicate reads no message content]"
KEEP_TOP = {'type', 'isSidechain', 'isMeta', 'isCompactSummary', 'isVisibleInTranscriptOnly',
            'timestamp', 'version', 'userType', 'entrypoint', 'permissionMode', 'promptSource'}

def redact_content(c, prefix=""):
    if isinstance(c, str):
        return prefix + REDACT
    if isinstance(c, list):
        out = []
        for b in c:
            if not isinstance(b, dict):
                out.append(b)
                continue
            nb = dict(b)
            if nb.get('type') == 'text':
                nb['text'] = REDACT
            if nb.get('type') == 'image':
                nb['source'] = {'type': 'base64', 'media_type': 'image/png', 'data': 'UkVEQUNURUQ='}
            if nb.get('type') == 'tool_result':
                nb['content'] = REDACT
                if 'tool_use_id' in nb:
                    nb['tool_use_id'] = 'toolu_REDACTED'
            out.append(nb)
        return out
    return c

def sanitize(name, r):
    out = {}
    for key, val in r.items():
        if key in KEEP_TOP:
            out[key] = val
        elif key == 'origin':
            # kind is the field the predicate reads: verbatim. Every other key keeps its NAME
            # (the shape is part of the capture) and loses its value.
            out['origin'] = {kk: (vv if kk == 'kind' else 'REDACTED') for kk, vv in val.items()}
        elif key == 'message':
            prefix = ''
            if name == 'voice_lint_refusal':
                prefix = 'Stop hook feedback:\n'
            elif name == 'task_notification':
                prefix = '<task-notification>\n'
            elif name == 'cross_session_peer':
                prefix = 'Another Claude session sent a message:\n'
            elif name == 'auto_compaction':
                prefix = 'This session is being continued from a previous conversation that ran out of context.\n'
            out['message'] = {kk: (redact_content(vv, prefix) if kk == 'content' else vv)
                              for kk, vv in val.items()}
        elif key in ('cwd', 'gitBranch', 'slug'):
            out[key] = 'REDACTED'
        elif key in ('sessionId', 'uuid', 'parentUuid', 'promptId', 'sourceToolAssistantUUID'):
            out[key] = '00000000-0000-4000-8000-000000000000'
        elif key == 'toolUseResult':
            out[key] = 'REDACTED'
        else:
            out[key] = 'REDACTED'
    return out

records = {}
for name in ['owner_string', 'owner_image_array', 'task_notification', 'auto_compaction',
             'cross_session_peer', 'voice_lint_refusal', 'tool_result']:
    if name not in want:
        sys.exit("MISSING CLASS: " + name)
    r = want[name]
    records[name] = {
        'captured_from_client_version': r.get('version'),
        'captured_timestamp': r.get('timestamp'),
        'population_in_corpus': counts[name],
        'record': sanitize(name, r),
    }

doc = {
    "_README": [
        "CAPTURED transcript records, one per provenance class R5 rules on. NOT hand-written.",
        "A hand-copied fixture restates the contract instead of observing it, so it tracks whoever",
        "last remembered to update it; these were read out of live Claude Code JSONL transcripts.",
        "",
        "WHAT WAS CHANGED AT CAPTURE, and why each change is safe for what these fixtures assert:",
        "  - message.content values are REPLACED with a fixed marker (the class-identifying prefix",
        "    is kept). R5's predicate reads NO message content at all, deliberately, so the value",
        "    is not an input to anything under test. The SHAPE is preserved verbatim: a string",
        "    stays a string, an array keeps its block types and their order.",
        "  - cwd / gitBranch / sessionId / uuid / parentUuid / promptId / toolUseResult and every",
        "    unrecognised key are replaced with a placeholder. Their KEYS are preserved, because",
        "    the record's key set is part of what a vendor drift would change.",
        "  - origin.kind is VERBATIM. Every other origin key keeps its name and loses its value.",
        "  - timestamp is the captured one and is OVERWRITTEN per cell by the fixture builder.",
        "",
        "RE-DERIVE (records are the owner's own transcripts and are not in the repo, so this",
        "needs a machine with Claude Code history; the script writes beside itself, in whatever",
        "checkout it is run from, and reads ~/.claude/projects unless CLAUDE_PROJECTS_DIR says",
        "otherwise):",
        "  python3 plugins/pipeline/tests/fixtures/voice-lint-56/capture.py",
        "",
        "STALENESS: every field these fixtures are pinned on is asserted as a present-tense fact",
        "by test-voice-lint.sh (see the PINNED FACTS suite). If the vendor changes a record shape,",
        "the pin reddens rather than the fixture quietly satisfying the cell it sits in.",
    ],
    "captured_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
    "corpus": {
        "files": len(files),
        "scope": "main-session transcripts under ~/.claude/projects on the author's machine",
    },
    "records": records,
}
with open(OUT, 'w') as fh:
    json.dump(doc, fh, indent=2, sort_keys=False)
    fh.write("\n")
print("wrote", OUT)
for name, v in records.items():
    print(" ", name, "pop=", v['population_in_corpus'], "ver=", v['captured_from_client_version'])
