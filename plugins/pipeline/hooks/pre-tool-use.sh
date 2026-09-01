# PreToolUse hook (agent-pipeline plugin): refuse a Phase 4 subagent's BLANKET STAGING.
#
# THIS FILE DELIBERATELY HAS NO SHEBANG, AND THAT IS A MEASUREMENT, NOT AN OMISSION. The runtime
# executes a hooks.json command through a shell, so an interpreter line costs a second exec on
# every Bash tool call in every adopting session. Measured on darwin 25.5.0, 40 sequential calls
# through `sh -c '<script>'` against a `sh -c ':'` baseline of 6 ms/call: 6 ms with no shebang,
# 9 ms with `#!/bin/bash`, 10 ms with `#!/bin/sh`, 11-13 ms with `#!/usr/bin/env bash`. Without a
# shebang the invoking shell runs the file itself (POSIX: an ENOEXEC on a command file is
# executed as a shell script), so the exec never happens. THE COST OF THAT CHOICE, stated because
# it is real: this file cannot be run by execve directly -- `./pre-tool-use.sh` from a non-shell
# parent fails -- and it must stay strict POSIX sh, since the shell that runs it is dash on most
# Linux hosts and bash-in-sh-mode on macOS. No arrays, no `[[`, no `local`, no bashisms.
#
# TWO STAGES, AND THE SPLIT IS THE POINT. This stage runs on EVERY Bash call, so it must conclude
# "not a candidate" using shell builtins alone -- no node, no forks. Only the narrow
# plausible-deny branch (a subagent-originated Bash call whose command stages paths the caller did
# not name) starts a node process to ask whose run it is. A node cold start measured 66.68 ms on
# this host against a 4.45 ms shell baseline; paying that on every tool call to answer "no" is the
# permanent tax this structure refuses.
#
# THE ORIGIN TERM IS `agent_id`, NOT `agent_type`. Claude Code sets agent_id only when the hook
# fires from inside a subagent and omits it for the main thread even in `--agent` sessions, so it
# is the field that distinguishes a panelist's call from the orchestrator's own checkpoint. There
# is no role allowlist: any subagent-originated call is in scope while a Phase 4 run owns the
# record store, which is deliberately wider than the panel and is disclosed in the agent
# contracts' commit-hygiene paragraph.
#
# FAIL-OPEN EVERYWHERE, EXIT 0 ALWAYS. Every tooling gap and every abstention allows the call and
# writes one attribution line to stderr saying which gap it was, so a non-action is diagnosable
# afterwards without re-running the session. Nothing is written on the non-acting fast path: a
# gate that emitted on every Bash call of every session would be the tax above in another form.
#
# DISARM: CLAUDE_HOOK_PRETOOLUSE_SKIP, operator-set in the hook's own environment only. It is
# read from the environment and from nowhere else, so no file a denied agent can write in one
# tool call reaches it. See plugins/pipeline/README.md for the knob and for why this gate sits
# outside the halting-control carve-out that refuses an opt-out for hooks/stop.sh's phase guard.

_note() {
  printf 'agent-pipeline PreToolUse: %s; nothing enforced.\n' "$1" >&2
}

# ---- reading one JSON string value, without a JSON parser and without a fork -------------------
#
# Sets _JS_OK/_JS_VAL (the value, still JSON-escaped) and _JS_PRE/_JS_POST (the haystack with that
# value cut out). The caller looks up every OTHER key in _JS_PRE$_JS_POST rather than in the whole
# payload, so a command that merely CONTAINS the text `"agent_id"` cannot be read as carrying one.
_js_get() { # <key> <haystack>
  _JS_OK=0
  _JS_VAL=''
  _JS_PRE=''
  _JS_POST=''
  case $2 in
    *"\"$1\""*) ;;
    *) return 1 ;;
  esac
  _JS_PRE=${2%%"\"$1\""*}
  _js_t=${2#*"\"$1\""}
  case $_js_t in
    *'"'*) ;;
    *) return 1 ;;
  esac
  _js_lead=${_js_t%%'"'*}
  case $_js_lead in
    *[!\ :]*) return 1 ;; # the value is not a string (null, number, object): not ours to read
  esac
  _js_t=${_js_t#*'"'}
  _js_acc=''
  while :; do
    case $_js_t in
      *'"'*) ;;
      *) return 1 ;; # unterminated string
    esac
    _js_seg=${_js_t%%'"'*}
    _js_t=${_js_t#"$_js_seg"}
    _js_t=${_js_t#'"'}
    # An even-length run of backslashes before the quote leaves the quote unescaped, and the
    # string ends there. An odd run means the quote is part of the value.
    _js_bs=${_js_seg##*[!\\]}
    _js_n=${#_js_bs}
    _js_acc=$_js_acc$_js_seg
    if [ $((_js_n % 2)) -eq 0 ]; then
      break
    fi
    _js_acc=$_js_acc'"'
  done
  _JS_VAL=$_js_acc
  _JS_POST=$_js_t
  _JS_OK=1
  return 0
}

_js_unescape() { # <escaped> -> _UNESC
  _ue_s=$1
  _ue_o=''
  while :; do
    case $_ue_s in
      *\\*) ;;
      *)
        _ue_o=$_ue_o$_ue_s
        break
        ;;
    esac
    _ue_pre=${_ue_s%%\\*}
    _ue_o=$_ue_o$_ue_pre
    _ue_s=${_ue_s#"$_ue_pre"\\}
    _ue_c=${_ue_s%"${_ue_s#?}"}
    _ue_s=${_ue_s#?}
    case $_ue_c in
      n) _ue_o=$_ue_o$_NL ;;
      t) _ue_o=$_ue_o$_TAB ;;
      r | b | f) ;;
      u)
        # A \uXXXX escape cannot spell any token this matcher decides on, so it collapses to one
        # placeholder rather than being decoded: a decoder here would be a second, unreviewed
        # unescaper on the path that decides a refusal.
        _ue_s=${_ue_s#????}
        _ue_o=$_ue_o'?'
        ;;
      *) _ue_o=$_ue_o$_ue_c ;;
    esac
  done
  _UNESC=$_ue_o
}

# ---- the forbidden CLASS, decided over flag semantics rather than over spellings ---------------
#
# A decision taken by searching the raw command string denies correct work whose text merely
# MENTIONS a banned spelling -- this issue's own ten-file doc-retirement commit message is exactly
# that commit. A decision taken by matching whole literal spellings under-refuses everything
# nobody enumerated: `git commit -aqm 'm'` commits every tracked modification while matching no
# entry in any eleven-row table, because git bundles short flags. So the command is TOKENIZED
# (quote-aware, so a `-m` operand containing `&&` or `git add -A` is one inert word), split into
# invocations at top-level operators, and EVERY git invocation is judged: staging narrowly and
# then committing blanket is a deny, and a deny by any one invocation denies the whole call.

_eval_inv() { # <words of one invocation>
  [ $# -ge 1 ] || return 0
  while [ $# -ge 1 ]; do
    case $1 in
      [A-Za-z_]*=*) shift ;; # a leading VAR=value assignment, not the command
      *) break ;;
    esac
  done
  [ $# -ge 1 ] || return 0
  case $1 in
    git | */git) ;;
    *) return 0 ;;
  esac
  shift
  # git's own global options, before the subcommand. -C and -c take a value, separated or
  # attached; every other global is a flag. An unknown leading dash is skipped rather than
  # treated as the subcommand, so a future global cannot silently turn a deny into an allow.
  while [ $# -ge 1 ]; do
    case $1 in
      -C | -c | --git-dir | --work-tree | --namespace | --exec-path | --super-prefix)
        shift
        [ $# -ge 1 ] && shift
        ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -ge 1 ] || return 0
  _verb=$1
  shift
  case $_verb in
    add | stage | commit) ;;
    *) return 0 ;; # checkout, restore, stash, clean, diff, log, status: not staging verbs
  esac

  _blanket=0    # an all-tracked flag: -a/--all for commit, -A/-u/--all/--update for add
  _pathspec=0   # any operand that narrows what is staged
  _blanketspec=0
  _endopts=0
  while [ $# -ge 1 ]; do
    _a=$1
    shift
    if [ "$_endopts" = 1 ]; then
      _pathspec=1
      case $_a in . | ./ | :/) _blanketspec=1 ;; esac
      continue
    fi
    case $_a in
      --) _endopts=1 ;;
      --all | --no-ignore-removal) _blanket=1 ;;
      --update)
        [ "$_verb" = commit ] || _blanket=1
        ;;
      --message | --file | --author | --date | --cleanup | --template | --fixup | --squash | --reuse-message | --reedit-message | --pathspec-from-file | --trailer)
        [ $# -ge 1 ] && shift
        ;;
      --*) ;; # every other long option, including the --opt=value forms, carries its own value
      -) _pathspec=1 ;;
      -*)
        # A short-option CLUSTER. Each letter is read in turn; a letter that takes a value
        # consumes the rest of the cluster, or the next word when it is the last letter. This is
        # the cell an eleven-row literal table fails: `-aqm` and `-Av` are the same staging as
        # `-a` and `-A` and match no row.
        _cl=${_a#-}
        while [ -n "$_cl" ]; do
          _l=${_cl%"${_cl#?}"}
          _cl=${_cl#?}
          if [ "$_verb" = commit ]; then
            case $_l in
              a) _blanket=1 ;;
              m | F | C | c | t)
                if [ -n "$_cl" ]; then
                  _cl=''
                else
                  [ $# -ge 1 ] && shift
                fi
                ;;
              S | u) _cl='' ;; # optional attached value (-uno, -Skeyid); never the next word
              *) ;;
            esac
          else
            case $_l in
              A | u) _blanket=1 ;;
              *) ;;
            esac
          fi
        done
        ;;
      *)
        _pathspec=1
        case $_a in . | ./ | :/) _blanketspec=1 ;; esac
        ;;
    esac
  done

  if [ "$_blanketspec" = 1 ]; then
    _VERDICT=blanket
  elif [ "$_blanket" = 1 ]; then
    # -u/-A with a pathspec updates only that path: the flag is blanket only when nothing narrows
    # it. `git commit -a` takes no pathspec, so the same test reads as "always" there.
    if [ "$_verb" = commit ] || [ "$_pathspec" = 0 ]; then
      _VERDICT=blanket
    fi
  fi
  return 0
}

_scan() { # <command string> -> _VERDICT
  _sc=$1
  _VERDICT=clear
  _q=0
  _w=''
  _has=0
  set --
  while [ -n "$_sc" ]; do
    _c=${_sc%"${_sc#?}"}
    _sc=${_sc#?}
    if [ "$_q" = 1 ]; then
      if [ "$_c" = "'" ]; then _q=0; else _w=$_w$_c; fi
      continue
    fi
    if [ "$_q" = 2 ]; then
      if [ "$_c" = '\' ]; then
        _n=${_sc%"${_sc#?}"}
        _sc=${_sc#?}
        _w=$_w$_n
      elif [ "$_c" = '"' ]; then
        _q=0
      else
        _w=$_w$_c
      fi
      continue
    fi
    case $_c in
      "'")
        _q=1
        _has=1
        ;;
      '"')
        _q=2
        _has=1
        ;;
      '\')
        _n=${_sc%"${_sc#?}"}
        _sc=${_sc#?}
        _w=$_w$_n
        _has=1
        ;;
      " " | "$_TAB")
        if [ "$_has" = 1 ]; then
          set -- "$@" "$_w"
          _w=''
          _has=0
        fi
        ;;
      ";" | "&" | "|" | "$_NL" | "(" | ")")
        if [ "$_has" = 1 ]; then
          set -- "$@" "$_w"
          _w=''
          _has=0
        fi
        case $_sc in "$_c"*) _sc=${_sc#?} ;; esac # && and || are one separator, not two
        _eval_inv "$@"
        if [ "$_VERDICT" = blanket ]; then
          return 0
        fi
        set --
        ;;
      *)
        _w=$_w$_c
        _has=1
        ;;
    esac
  done
  if [ "$_has" = 1 ]; then
    set -- "$@" "$_w"
  fi
  _eval_inv "$@"
  return 0
}

# ---- the fast path ----------------------------------------------------------------------------

_NL='
'
_TAB='	'

_INPUT=''
while IFS= read -r _line || [ -n "$_line" ]; do
  _INPUT=$_INPUT$_line
done

# (1) ORIGIN, the cheapest reject and the most common one: the main thread carries no agent_id at
# all. A command whose own text contains the token survives this and is rejected precisely below.
#
# THE SECOND ARM IS WHAT KEEPS AN UNREADABLE PAYLOAD FROM LOOKING LIKE A MAIN-THREAD CALL. Both
# arrive here with no agent_id, and one of them must be attributed while the other must stay
# silent -- so the reject fires only when the payload also carries the field this gate reads, and
# anything else falls through to the precise read below.
case $_INPUT in
  *'"agent_id"'*) ;;
  *'"command"'*) exit 0 ;;
  *) ;;
esac

# (2) the command. Absent, this is either a non-Bash tool (silent) or a payload we cannot read.
if ! _js_get command "$_INPUT"; then
  if _js_get tool_name "$_INPUT" && [ "$_JS_VAL" != "Bash" ]; then
    exit 0
  fi
  _note 'the hook payload carried no readable Bash command'
  exit 0
fi
_REST=$_JS_PRE$_JS_POST
_js_unescape "$_JS_VAL"
_COMMAND=$_UNESC

# (3) nothing without `git` in it can stage anything.
case $_COMMAND in
  *git*) ;;
  *) exit 0 ;;
esac

# (4) the tool and the origin, read from the payload with the command's text cut out.
_js_get tool_name "$_REST" || exit 0
[ "$_JS_VAL" = "Bash" ] || exit 0
_js_get agent_id "$_REST" || exit 0
[ -n "$_JS_VAL" ] || exit 0

# (5) the forbidden class.
_scan "$_COMMAND"
[ "$_VERDICT" = blanket ] || exit 0

# (6) the disarm, read from the environment and from nowhere else. Its own name never reaches
# stdout or stderr: telling a denied agent which variable turns the gate off would hand it the
# set-step this scoping exists to keep out of its reach.
if [ -n "${CLAUDE_HOOK_PRETOOLUSE_SKIP:-}" ]; then
  _note 'disarmed for this session by an operator-set environment variable'
  exit 0
fi

# (7) the seam. Everything past here is a tooling condition in the operator's environment, and
# each one allows the call with its own attribution.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _note 'CLAUDE_PLUGIN_ROOT is not set, so the resolver cannot be located'
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  _note 'node is not on PATH'
  exit 0
fi
_RESOLVER=$CLAUDE_PLUGIN_ROOT/hooks/pre-tool-use-resolve.mjs
if [ ! -f "$_RESOLVER" ]; then
  _note 'the resolver is not present under the plugin root'
  exit 0
fi

_js_get agent_type "$_REST" && _AGENT_TYPE=$_JS_VAL || _AGENT_TYPE=''
_js_get active_issue "$_REST" && _ACTIVE=$_JS_VAL || _ACTIVE=''
_js_get cwd "$_REST" && { _js_unescape "$_JS_VAL"; _CWD=$_UNESC; } || _CWD=''

# The caller's command is NOT passed. The resolver decides ownership and phase; the class of the
# command was decided here, and putting it on a child's argv would publish user-controlled text
# to every other local user on the host.
node "$_RESOLVER" "$_CWD" "$_AGENT_TYPE" "$_ACTIVE" || {
  _note 'the resolver exited non-zero'
  exit 0
}
exit 0
