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

# ---- moving a cursor forward without paying for it twice ---------------------------------------
#
# `${s#"$long"}` -- drop a prefix by NAMING it -- and `${s%"${s#?}"}` -- read the first character
# -- are the two idioms this file used to walk a string, and BOTH are quadratic in the shells that
# run it. Measured on darwin 25.5.0 over a 32000-character subject, 10 calls each, against a
# 72 ms empty-loop floor: `${s#"$pre"}` 22151 ms, `${s%"${s#?}"}` 20524 ms, `${s#*|}` 6423 ms --
# against 75 ms for `${s#<512 literal ?>}` and 176 ms for `${s%%[|]*}`. The shell re-runs a whole
# pattern match per candidate position, so a pattern that GROWS with the subject costs its square.
#
# THE COST WAS NOT THEORETICAL. A subagent's `git commit -a -m "<2.5 KB message>"` took 5.014 s
# and was killed at this hook's own 5-second declared timeout, and a killed PreToolUse hook FAILS
# OPEN -- so the identical forbidden staging was DENIED with a short message and ALLOWED with a
# long one. Length is not a privilege, and it must not buy a bypass.
#
# So every cursor move below drops a prefix in FIXED-WIDTH steps whose patterns are compile-time
# constants, and every first-character read is an ANCHORED `case` instead of a suffix subtraction.
_Q8='????????'

_cut() { # <prefix> : drop exactly as many leading characters from _CUR as <prefix> has
  _ct=$1
  while [ -n "$_ct" ]; do
    case $_ct in
      $_Q512*)
        _ct=${_ct#$_Q512}
        _CUR=${_CUR#$_Q512}
        ;;
      $_Q64*)
        _ct=${_ct#$_Q64}
        _CUR=${_CUR#$_Q64}
        ;;
      $_Q8*)
        _ct=${_ct#$_Q8}
        _CUR=${_CUR#$_Q8}
        ;;
      *)
        _ct=${_ct#?}
        _CUR=${_CUR#?}
        ;;
    esac
  done
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
  _CUR=$2
  _cut "$_JS_PRE"
  _js_t=${_CUR#"\"$1\""}
  case $_js_t in
    *'"'*) ;;
    *) return 1 ;;
  esac
  _js_lead=${_js_t%%'"'*}
  case $_js_lead in
    *[!\ :]*) return 1 ;; # the value is not a string (null, number, object): not ours to read
  esac
  _CUR=$_js_t
  _cut "$_js_lead"
  _js_t=${_CUR#'"'}
  _js_acc=''
  while :; do
    case $_js_t in
      *'"'*) ;;
      *) return 1 ;; # unterminated string
    esac
    _js_seg=${_js_t%%'"'*}
    _CUR=$_js_t
    _cut "$_js_seg"
    _js_t=${_CUR#'"'}
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
    _CUR=$_ue_s
    _cut "$_ue_pre"
    _ue_s=${_CUR#\\}
    # The escape character is read by ANCHORED match rather than by subtracting the tail, so the
    # cost of one escape does not grow with the length of the text after it. The arms enumerate
    # every escape RFC 8259 admits; the last one keeps the old reading of a malformed escape and
    # is the only place a growing pattern survives, which is affordable because a runtime that
    # emits this payload emits valid JSON, so nothing reaches it in production.
    case $_ue_s in
      n*)
        _ue_o=$_ue_o$_NL
        _ue_s=${_ue_s#?}
        ;;
      t*)
        _ue_o=$_ue_o$_TAB
        _ue_s=${_ue_s#?}
        ;;
      r* | b* | f*) _ue_s=${_ue_s#?} ;;
      u*)
        # A \uXXXX escape cannot spell any token this matcher decides on, so it collapses to one
        # placeholder rather than being decoded: a decoder here would be a second, unreviewed
        # unescaper on the path that decides a refusal.
        _ue_s=${_ue_s#?}
        _ue_s=${_ue_s#????}
        _ue_o=$_ue_o'?'
        ;;
      '"'*)
        _ue_o=$_ue_o'"'
        _ue_s=${_ue_s#?}
        ;;
      \\*)
        _ue_o=$_ue_o'\'
        _ue_s=${_ue_s#?}
        ;;
      /*)
        _ue_o=$_ue_o'/'
        _ue_s=${_ue_s#?}
        ;;
      '') ;; # a trailing lone backslash: nothing follows it
      *)
        _ue_c=${_ue_s%"${_ue_s#?}"}
        _ue_s=${_ue_s#?}
        _ue_o=$_ue_o$_ue_c
        ;;
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

# WHICH WORD NAMES THE COMMAND, decided in ONE place. `_eval_inv` needs the answer over a finished
# word list and `_scan` needs it as each word closes, and two readings of "is this invocation a
# git one" that drifted apart would silently stop the scanner hoarding words for an invocation
# `_eval_inv` would still have judged. Exit status, not a variable, so no caller can forget it:
#   0 a leading VAR=value assignment -- the command word is still ahead
#   1 this word IS the git command
#   2 this word names something else, so the invocation cannot stage anything
_head_kind() { # <word>
  case $1 in
    [A-Za-z_]*=*) return 0 ;;
    git | */git) return 1 ;;
    *) return 2 ;;
  esac
}

_eval_inv() { # <words of one invocation>
  while [ $# -ge 1 ]; do
    _head_kind "$1"
    case $? in
      0) shift ;;
      1) break ;;
      *) return 0 ;;
    esac
  done
  [ $# -ge 1 ] || return 0
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
          if [ "$_verb" = commit ]; then
            case $_cl in
              a*) _blanket=1 ;;
              m* | F* | C* | c* | t*)
                _cl=${_cl#?}
                if [ -n "$_cl" ]; then
                  _cl=''
                else
                  [ $# -ge 1 ] && shift
                fi
                continue
                ;;
              S* | u*) # optional attached value (-uno, -Skeyid); never the next word
                _cl=''
                continue
                ;;
            esac
          else
            case $_cl in
              A* | u*) _blanket=1 ;;
            esac
          fi
          _cl=${_cl#?}
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

# EVERY CHARACTER THAT CAN END A WORD OR CHANGE THE PARSE STATE, as a bracket expression, so a run
# of ordinary characters is taken in ONE parameter expansion instead of one per character. `>` and
# `<` and `#` are in here because they are shell METATEXT and not operands: without them a trailing
# ` > /dev/null` or ` # note` reached the operand walk below and was counted as a pathspec, which
# is the term that decides a blanket stage is narrow -- so a redirection turned a deny into an
# allow. The set has no `]`, no `-`, and no leading `!` or `^`, so it needs no bracket quoting.
# `_META`/`_META_DQ` are assigned beside `_NL`/`_TAB` below, before the first call.

# Consume the ONE leading character of _sc into the current word. Every arm but the last is a
# member of `_META`, spelled out because an anchored `case` costs nothing while the general read
# costs a pattern match over the whole remaining string. The last arm is that general read, and it
# is what makes this total: a member missing from the list above is SLOW here, never wrong.
_lit1() {
  case $_sc in
    "'"*) _w=$_w"'" ;;
    '"'*) _w=$_w'"' ;;
    '\'*) _w=$_w'\' ;;
    ' '*) _w=$_w' ' ;;
    ';'*) _w=$_w';' ;;
    '&'*) _w=$_w'&' ;;
    '|'*) _w=$_w'|' ;;
    '('*) _w=$_w'(' ;;
    ')'*) _w=$_w')' ;;
    '<'*) _w=$_w'<' ;;
    '>'*) _w=$_w'>' ;;
    '#'*) _w=$_w'#' ;;
    "$_TAB"*) _w=$_w$_TAB ;;
    "$_NL"*) _w=$_w$_NL ;;
    *) _w=$_w${_sc%"${_sc#?}"} ;;
  esac
  _sc=${_sc#?}
}

# What to do with the word that just closed. Sets _KEEP=1 when the caller must append it to the
# invocation's word list and _RESET=1 when the invocation has been settled as one that cannot
# stage anything, so every word hoarded for it can be dropped.
#
# THE DROP IS A COST FIX AND NOT A SHORTCUT PAST THE DECISION. `set -- "$@" "$_w"` rebuilds the
# whole list per word, so hoarding N words costs N-squared: measured on darwin 25.5.0,
# `echo <2500 short words> ; git add -A` took 10.1 s -- past this hook's 5-second timeout, and a
# hook killed at its timeout emits nothing and the call is ALLOWED. The drop only ever discards
# words belonging to an invocation `_head_kind` has already settled as non-git, which is the
# same predicate `_eval_inv` would apply to return 0 over them.
#
# WHAT THIS DOES NOT COVER, STATED RATHER THAN LEFT LATENT. A single GIT invocation's own operands
# still have to be hoarded, because `_eval_inv` decides `_pathspec` and `_blanketspec` over the
# whole list, so the N-squared survives for that one shape: on the same host `git add . <N
# operands>` measured 0.79 s at N=500, 2.4 s at 1000, 8.8 s at 2000 and 34.0 s at 4000, so past
# roughly 1400 operands it crosses the timeout and that deny becomes an allow. Closing it means
# hoisting the operand classification out of `_eval_inv` and into this loop, which is a redesign
# rather than a fix, so it is recorded here and filed rather than done in this round.
_word_done() { # <word>
  _KEEP=0
  _RESET=0
  if [ "$_redir" = 1 ]; then
    _redir=0 # a redirection TARGET is not an operand
    return 0
  fi
  [ "$_skip" = 0 ] || return 0
  _KEEP=1
  [ "$_headseen" = 0 ] || return 0
  _head_kind "$1"
  case $? in
    0) ;;
    1) _headseen=1 ;;
    *)
      _headseen=1
      _skip=1
      _KEEP=0
      _RESET=1
      ;;
  esac
}

_scan() { # <command string> -> _VERDICT
  _sc=$1
  _VERDICT=clear
  _w=''
  _has=0
  _redir=0
  _skip=0
  _headseen=0
  set --
  while [ -n "$_sc" ]; do
    # THE BULK SLICE, and the reason this loop is no longer written character-at-a-time. Every
    # ordinary character used to cost three pattern matches over the WHOLE remaining command, so
    # the loop was quadratic in command length and the gate outran its own timeout on a long
    # commit message. Here the loop turns once per METACHARACTER, and a 2500-character quoted
    # operand is a handful of turns rather than 2500.
    _seg=${_sc%%[$_META]*}
    if [ -n "$_seg" ]; then
      _w=$_w$_seg
      _has=1
      _CUR=$_sc
      _cut "$_seg"
      _sc=$_CUR
      [ -n "$_sc" ] || break
    fi
    case $_sc in
      "'"*)
        _sc=${_sc#?}
        _has=1
        _seg=${_sc%%\'*}
        _w=$_w$_seg
        _CUR=$_sc
        _cut "$_seg"
        _sc=${_CUR#\'}
        ;;
      '"'*)
        _sc=${_sc#?}
        _has=1
        while [ -n "$_sc" ]; do
          _seg=${_sc%%[$_META_DQ]*}
          if [ -n "$_seg" ]; then
            _w=$_w$_seg
            _CUR=$_sc
            _cut "$_seg"
            _sc=$_CUR
            [ -n "$_sc" ] || break
          fi
          case $_sc in
            '\'*)
              # The backslash is dropped and the character behind it is inert. Only `\"` and `\\`
              # need taking here: any other escaped character is not in `_META_DQ`, so the next
              # bulk slice absorbs it and the word comes out the same.
              _sc=${_sc#?}
              case $_sc in '"'* | '\'*) _lit1 ;; esac
              ;;
            *)
              _sc=${_sc#?} # the closing quote
              break
              ;;
          esac
        done
        ;;
      '\'*)
        _sc=${_sc#?}
        _has=1
        # Same reasoning outside quotes, over the wider set: an escaped ORDINARY character is
        # picked up by the next bulk slice, an escaped METAcharacter has to be taken here or it
        # would be read as the operator it is spelled like.
        case $_sc in [$_META]*) _lit1 ;; esac
        ;;
      '#'*)
        # `#` opens a comment only at a WORD START; inside a word it is an ordinary character, so
        # `git add foo#bar` still stages one path. A comment runs to end of line, and its words
        # are not operands: `git add -A # stage everything` is the same blanket stage as `git
        # add -A`.
        if [ "$_has" = 1 ]; then
          _w=$_w'#'
          _sc=${_sc#?}
        else
          _sc=${_sc#?}
          _seg=${_sc%%"$_NL"*}
          _CUR=$_sc
          _cut "$_seg"
          _sc=$_CUR
        fi
        ;;
      '>'* | '<'*)
        # A redirection operator ends the current word and claims the next one as its TARGET. A
        # bare digit run immediately before it is an fd designator (`2>`), not an operand.
        if [ "$_has" = 1 ]; then
          case $_w in
            '' | *[!0-9]*)
              _word_done "$_w"
              [ "$_KEEP" = 1 ] && set -- "$@" "$_w"
              [ "$_RESET" = 1 ] && set --
              ;;
          esac
          _w=''
          _has=0
        fi
        _sc=${_sc#?}
        case $_sc in '>'* | '<'* | '&'* | '|'*) _sc=${_sc#?} ;; esac # >>, >|, >&, <<, <&, <>
        _redir=1
        ;;
      ' '* | "$_TAB"*)
        if [ "$_has" = 1 ]; then
          _word_done "$_w"
          [ "$_KEEP" = 1 ] && set -- "$@" "$_w"
          [ "$_RESET" = 1 ] && set --
          _w=''
          _has=0
        fi
        _sc=${_sc#?}
        ;;
      *)
        # `; & | newline ( )`: the top-level operators, by elimination -- everything else in
        # `_META` has its own arm above.
        if [ "$_has" = 1 ]; then
          _word_done "$_w"
          [ "$_KEEP" = 1 ] && set -- "$@" "$_w"
          [ "$_RESET" = 1 ] && set --
          _w=''
          _has=0
        fi
        _redir=0
        _skip=0
        _headseen=0
        case $_sc in # && and || are one separator, not two
          ';;'* | '&&'* | '||'* | '(('* | '))'* | "$_NL$_NL"*) _sc=${_sc#??} ;;
          *) _sc=${_sc#?} ;;
        esac
        _eval_inv "$@"
        if [ "$_VERDICT" = blanket ]; then
          return 0
        fi
        set --
        ;;
    esac
  done
  if [ "$_has" = 1 ]; then
    _word_done "$_w"
    [ "$_KEEP" = 1 ] && set -- "$@" "$_w"
    [ "$_RESET" = 1 ] && set --
  fi
  _eval_inv "$@"
  return 0
}

# ---- the fast path ----------------------------------------------------------------------------

_NL='
'
_TAB='	'
# THE BACKSLASH IS DOUBLED ON PURPOSE, AND A SINGLE ONE IS A SILENT DENY-TO-ALLOW. These strings
# are used as `[$_META]`, so their content is re-read AS A PATTERN, and there a backslash escapes
# the character behind it instead of joining the set. With one backslash, `[ ...\;&|...]` holds no
# backslash at all, `_scan` reads `\'` as an ordinary character, and `git mv \' $(git add -A)`
# came back CLEAR where the old walk said blanket. `_META_DQ` fails harder still: `["\]` leaves the
# bracket unterminated, and /bin/sh and dash then disagree with each other about what it matches.
# Doubled, the pattern carries an escaped backslash, which is one member and nothing else.
_META=" $_TAB$_NL'\"\\\\;&|()<>#"
_META_DQ="\"\\\\"
_Q64="$_Q8$_Q8$_Q8$_Q8$_Q8$_Q8$_Q8$_Q8"
_Q512="$_Q64$_Q64$_Q64$_Q64$_Q64$_Q64$_Q64$_Q64"

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
