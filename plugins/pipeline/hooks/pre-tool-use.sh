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
#
# THE RESIDUAL IS DROPPED BY NAME, AND THE MEASUREMENT SAYS WHY IT IS SAFE TO. `${s#"$pre"}` is
# quadratic in the PREFIX, not in the subject: over a 20000-character subject, 2000 calls each,
# against a 98 ms empty-loop floor -- a 4-character prefix 270 ms, a 40-character prefix 161 ms, a
# 400-character prefix 868 ms, and the whole-subject prefix that bought the ladder above 2.2 s PER
# CALL. So the ladder is right for a long prefix and wrong for a short one, and the `?`-at-a-time
# rung was the wrong tool for the case this file hits most: a four-character word cost four whole
# copies of the remaining command instead of one.
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
      *)
        # At most 63 characters are left, and every caller passes a prefix _CUR really starts
        # with, so naming it is exact and costs one pass rather than one pass per character.
        _CUR=${_CUR#"$_ct"}
        _ct=''
        ;;
    esac
  done
}

# The same move on the SCANNER's cursor, and the duplication is bought by a measurement rather
# than tolerated. Routing the scan through `_CUR` costs `_CUR=$_sc` and `_sc=$_CUR` either side of
# every cut -- two more whole-string copies per structural character, on top of the one the cut
# itself needs. On a 78 KB heredoc, whose every line-ending newline is a structural character,
# that was three copies per line rather than one and measured 4064 ms against a 5000 ms bound.
_cut_sc() { # <prefix> : drop exactly as many leading characters from _sc as <prefix> has
  _ct=$1
  while [ -n "$_ct" ]; do
    case $_ct in
      $_Q512*)
        _ct=${_ct#$_Q512}
        _sc=${_sc#$_Q512}
        ;;
      $_Q64*)
        _ct=${_ct#$_Q64}
        _sc=${_sc#$_Q64}
        ;;
      *)
        _sc=${_sc#"$_ct"}
        _ct=''
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

# THE ESCAPES ARE CUT APART IN ONE PASS, FOR THE SAME REASON THE SCANNER'S WORDS ARE. Walking the
# value one escape at a time copied everything still to come, once per escape, so the cost was
# (number of escapes) x (length) -- and a MULTI-LINE command carries one `\n` escape per line, so
# an ordinary heredoc lands squarely in it: measured on darwin 25.5.0, 215 ms over a 20 KB value,
# 609 ms over 40 KB and 2165 ms over 80 KB, on the path that decides a refusal, against the
# 5-second `timeout` hooks.json declares. Splitting on the escape character with the shell's own
# field splitting is one C-level pass, and the walk below makes no function call, so the whole
# thing is linear.
#
# THE EMPTY FIELD IS THE ESCAPED BACKSLASH, and that reading is what makes the split faithful. A
# non-whitespace IFS character delimits on EVERY occurrence, so `\\` leaves an empty field between
# its two backslashes; the field after it is therefore ordinary text and not an escape. A trailing
# lone backslash leaves no field at all and so produces nothing, which is what the previous walk
# did. Verified identical on bash 3.2 in sh mode, `bash --posix` and dash over `a\nb`, `a\\b`,
# `a\\\\b`, `\nfoo`, `foo\`, `foo\\`, `a\n\nb`, the empty string and a value with no escape.
_js_unescape() { # <escaped> -> _UNESC
  _ue_o=''
  _ue_sv=${IFS-}
  set -f
  IFS='\'
  set -- $1
  IFS=$_ue_sv
  set +f
  _ue_first=1
  _ue_lit=0
  for _ue_f do
    if [ "$_ue_first" = 1 ]; then
      _ue_first=0
      _ue_o=$_ue_o$_ue_f # the text before the first escape
      continue
    fi
    if [ "$_ue_lit" = 1 ]; then
      _ue_lit=0
      _ue_o=$_ue_o$_ue_f # the field behind an escaped backslash is text, not an escape
      continue
    fi
    # The arms enumerate every escape RFC 8259 admits. The last one keeps the old reading of a
    # malformed escape -- the escape character stands for itself -- which is affordable because a
    # runtime that emits this payload emits valid JSON, so nothing reaches it in production.
    case $_ue_f in
      n*) _ue_o=$_ue_o$_NL${_ue_f#?} ;;
      t*) _ue_o=$_ue_o$_TAB${_ue_f#?} ;;
      r* | b* | f*) _ue_o=$_ue_o${_ue_f#?} ;;
      u*)
        # A \uXXXX escape cannot spell any token this matcher decides on, so it collapses to one
        # placeholder rather than being decoded: a decoder here would be a second, unreviewed
        # unescaper on the path that decides a refusal.
        _ue_o=$_ue_o'?'${_ue_f#?????}
        ;;
      '"'*) _ue_o=$_ue_o'"'${_ue_f#?} ;;
      /*) _ue_o=$_ue_o'/'${_ue_f#?} ;;
      '')
        _ue_o=$_ue_o'\'
        _ue_lit=1
        ;;
      *) _ue_o=$_ue_o$_ue_f ;;
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

# THE JUDGE TAKES ANY NUMBER OF WORDS IN ONE CALL, AND THE SHAPE OF THAT INTERFACE IS THE COST
# FIX. Three measurements on darwin 25.5.0 set it, and each rules out an interface that reads more
# naturally:
#
#   * `_eval_inv <every word of the invocation>` -- the previous round's shape -- made the scanner
#     hoard with `set -- "$@" "$_w"`, an append that rebuilds the whole list. That append ALONE
#     measured 347 ms at 500 words, 1195 at 1000, 4807 at 2000, 19658 at 4000 and 78780 at 8000,
#     which is why `git add . <2000 operands>` took 8.3 s and crossed the 5-second `timeout`
#     hooks.json declares.
#   * one call PER WORD is worse, not better, and that is the trap this file walked into once.
#     A function call SAVES AND RESTORES THE POSITIONAL PARAMETERS, so calling anything while a
#     large list is live costs the length of that list: a `for` walk over k fields calling one
#     function per field measured 219 ms at k=500, 714 at 1000, 2699 at 2000 and 10466 at 4000,
#     against 68-99 ms for the same walk with NO call at any k. The first draft of this fix did
#     exactly that and made `echo <5000 words> ; git add -A` SLOWER (8901 ms) than the 3305 ms it
#     set out to remove.
#   * `for f do` with no call inside is flat in k. So the words arrive as `$@` here, the walk
#     happens here, and NOTHING inside the loop is a function call -- which is why the head-word
#     test and the operand test are written inline rather than factored out.
#
# The rules are the same rules the batch walk applied, with its position held in `_ist` instead of
# in `shift`; nothing about WHAT is forbidden moved.
#
#   _ist       head -> global -> arg, the three regions the old walk used three loops for
#   _idead     this invocation cannot stage anything; every later word is inert
#   _valnext   the previous word was an option that takes the NEXT word as its value
_inv_reset() {
  _ist=head
  _idead=0
  _valnext=0
  _verb=''
  _blanket=0    # an all-tracked flag: -a/--all for commit, -A/-u/--all/--update for add
  _pathspec=0   # any operand that narrows what is staged
  _blanketspec=0
  _endopts=0
}

_inv_words() { # <closed word>...
  for _f do
    if [ "$_redir" = 1 ]; then
      _redir=0 # a redirection TARGET is not an operand
      continue
    fi
    [ "$_idead" = 0 ] || continue
    case $_ist in
      head)
        # WHICH WORD NAMES THE COMMAND.
        case $_f in
          [A-Za-z_]*=*) ;; # a leading VAR=value assignment: the command word is still ahead
          git | */git) _ist=global ;;
          *) _idead=1 ;; # this word names something else, so nothing here can stage
        esac
        continue
        ;;
      global)
        # git's own global options, before the subcommand. -C and -c take a value, separated or
        # attached; every other global is a flag. An unknown leading dash is skipped rather than
        # treated as the subcommand, so a future global cannot silently turn a deny into an allow.
        if [ "$_valnext" = 1 ]; then
          _valnext=0
          continue
        fi
        case $_f in
          -C | -c | --git-dir | --work-tree | --namespace | --exec-path | --super-prefix) _valnext=1 ;;
          -*) ;;
          *)
            _verb=$_f
            case $_verb in
              add | stage | commit) _ist=arg ;;
              *) _idead=1 ;; # checkout, restore, stash, clean, diff, log, status: not staging
            esac
            ;;
        esac
        continue
        ;;
    esac

    if [ "$_valnext" = 1 ]; then
      _valnext=0
      continue
    fi
    # AN OPERAND NARROWS ONLY IF THE SCANNER CAN SEE WHAT IT NAMES, and the second half of that
    # sentence is the one that was live. Two kinds of word name nothing this scanner can see:
    #
    #   THE EMPTY STRING, which real git refuses outright (`fatal: empty string is not a valid
    #   pathspec`, exit 128, nothing staged), so reading `git add -A ''` as a NARROWED stage
    #   credited the command with a restriction the shell never handed it. Closing that alone
    #   prevented no staging, because the command it refuses stages nothing either way.
    #
    #   A WORD CARRYING AN UNRESOLVED EXPANSION, which is the half that stages every file. This
    #   scanner reads TEXT; the shell hands git ARGV; and between the two sits an expansion whose
    #   result is not in the text at all. `git add -A $CHANGED` with CHANGED unset or empty is not
    #   `add -A <empty operand>` -- the word is DELETED, and a recording git shim reads
    #   `ARGC=2 [add] [-A]`, a full blanket stage that in a scratch repository staged a modified
    #   tracked file and two untracked ones. That is the ORDINARY shape and the dangerous one at
    #   once: an agent that builds a path list in a variable gets a blanket stage EXACTLY WHEN THE
    #   LIST CAME BACK EMPTY, which is precisely when it did not mean to stage anything.
    #
    # THE TEST IS STRUCTURAL, NOT A TABLE OF SPELLINGS, because a table would be reopened by the
    # next spelling nobody enumerated. POSIX sh has exactly TWO characters that introduce a
    # substitution -- `$` (parameter, command and arithmetic) and the backquote -- and every
    # spelling of every one of them (`$X`, `${X}`, `${X:-}`, `$(cmd)`, `$((e))`, `$@`, `$1`, `$?`,
    # and the backquoted form) necessarily contains one of the two. So the rule is over the CLASS:
    # a word whose final content is not determined by the text cannot be read as naming a path.
    #
    # THE DIRECTION IS DELIBERATE AND ONLY ONE WAY. An opaque word is refused the power to NARROW,
    # so `git add -A $X` earns the same verdict as `git add -A` alone. It is NOT credited with the
    # power to BLANKET: `git add $X` stays clear, because crediting it would refuse `git add
    # $FILE`, the ordinary correct command, on the strength of X possibly being `.`. That is the
    # residual, stated rather than hidden -- and it is the deliberate half, since an empty
    # expansion is an ACCIDENT the author did not intend while `X=.` is a blanket stage the author
    # chose, and a text-scanning gate never claimed to refuse a stage its author meant.
    #
    # WHAT IT COSTS, measured rather than assumed: `git add -A foo$X` and `git add -A '$literal'`
    # are now denied although a real shell hands git a pathspec for both. Both keep a blanket flag
    # beside a path this scanner cannot resolve, neither is a shape anything in this repository
    # writes, and the narrow form `git add $X` -- which is what an agent staging a computed path
    # actually writes -- is untouched.
    #
    # THE TEST SITS AT THE OPERAND POSITIONS AND NOWHERE ELSE, because a word that opens with a
    # dash is read for its FLAG letters and those still count: `git commit -a$X` and `git add -A$X`
    # are `-a` and `-A` however `$X` resolves, and skipping them here would trade one phantom
    # operand for a lost blanket flag.
    if [ "$_endopts" = 1 ]; then
      case $_f in
        '' | *'$'* | *'`'*) continue ;; # after `--` every word is an operand, opaque ones included
      esac
      _pathspec=1
      case $_f in
        . | ./ | :/)
          _blanketspec=1
          _VERDICT=blanket
          return 0
          ;;
      esac
      continue
    fi
    case $_f in
      --) _endopts=1 ;;
      --all | --no-ignore-removal) _blanket=1 ;;
      --update)
        [ "$_verb" = commit ] || _blanket=1
        ;;
      --message | --file | --author | --date | --cleanup | --template | --fixup | --squash | --reuse-message | --reedit-message | --pathspec-from-file | --trailer)
        _valnext=1
        ;;
      --*) ;; # every other long option, including the --opt=value forms, carries its own value
      -) _pathspec=1 ;;
      -*)
        # A short-option CLUSTER. Each letter is read in turn; a letter that takes a value
        # consumes the rest of the cluster, or the next word when it is the last letter. This is
        # the cell an eleven-row literal table fails: `-aqm` and `-Av` are the same staging as
        # `-a` and `-A` and match no row.
        _cl=${_f#-}
        while [ -n "$_cl" ]; do
          if [ "$_verb" = commit ]; then
            case $_cl in
              a*) _blanket=1 ;;
              m* | F* | C* | c* | t*)
                _cl=${_cl#?}
                if [ -n "$_cl" ]; then
                  _cl=''
                else
                  _valnext=1
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
      '' | *'$'* | *'`'*) ;; # names nothing this scanner can see, so it narrows nothing
      . | ./ | :/)
        _pathspec=1
        _blanketspec=1
        _VERDICT=blanket # nothing later in this invocation can un-blanket a blanket pathspec
        return 0
        ;;
      *) _pathspec=1 ;;
    esac
  done
  return 0
}

_inv_finish() { # the invocation has ended: read the verdict off the state it left
  [ "$_idead" = 0 ] || return 0
  [ -n "$_verb" ] || return 0
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

# THE FOUR CHARACTER CLASSES, all assigned beside `_NL`/`_TAB` below, before the first call. None
# of them holds a `]`, a `-`, or a leading `!` or `^`, so none needs bracket quoting.
#
#   _META    every character that can end a word or change the parse state. `>` and `<` and `#`
#            are in here because they are shell METATEXT and not operands: without them a trailing
#            ` > /dev/null` or ` # note` reached the operand walk and was counted as a pathspec,
#            which is the term that decides a blanket stage is narrow -- so a redirection turned a
#            deny into an allow. Read by `_lit1`, which takes an ESCAPED member literally.
#   _STRUCT  `_META` minus space and tab: every character the scan loop has to STOP on. Whitespace
#            is not one, because a run of words is split in bulk rather than walked.
#   _WS      space and tab, the field separators the bulk split uses.
#   _SEP     the top-level operators, so a whole run of adjacent ones is consumed in one move.

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
    # NO NEWLINE ARM, AND ITS ABSENCE IS THE FIX. `\<newline>` is not an escaped newline, it is a
    # LINE CONTINUATION: POSIX deletes the pair before tokenizing, so it produces no character,
    # no word and no word boundary. Taking it as a literal here manufactured an operand the shell
    # never creates, and one phantom operand is exactly the term that downgrades `git add -A`
    # from a blanket stage to a narrow one -- so `git add -A \<newline> && git commit -m "x"`,
    # the most ordinary way an agent writes a multi-line command, was ALLOWED while a real bash
    # staged and committed every file. Both backslash arms in `_scan` now consume the pair and
    # emit nothing, so no newline reaches this function.
    *) _w=$_w${_sc%"${_sc#?}"} ;;
  esac
  _sc=${_sc#?}
}

# WORDS ARE SPLIT IN BULK, AND THAT IS WHAT MAKES THE COST LINEAR RATHER THAN QUADRATIC.
#
# THE COST WAS NOT THEORETICAL, AND IT WAS NOT WHERE THE PREVIOUS ROUND SAID IT WAS. Every cursor
# move over the remaining command copies the whole remainder, so the scan cost is (number of
# cursor moves) x (command length) -- driven by WORD-BOUNDARY COUNT, not by character count. A
# fixture padded with one unbroken run of one character has a word-boundary count of O(1) and
# cannot construct this at all, which is why the length-axis cells added in the previous round
# were green over it. Measured on darwin 25.5.0 before this change: `echo <5000 short words> ;
# git add -A` spent 3305 ms in the scan with NO git invocation needed to trigger it (the same
# prose with no git at all measured 3247 ms), against 346 ms at 1000 words. Past the 5-second
# `timeout` hooks.json declares, the hook is killed, a killed PreToolUse hook emits nothing, and
# the staging on the far side of the `;` is ALLOWED.
#
# So the loop advances once per STRUCTURAL character -- a quote, a backslash, a `#`, a redirection
# operator, a separator -- and never once per word. Everything between two structural characters
# is one run, cut out in one move and handed to `_inv_words` UNQUOTED, so the shell's own field
# splitting does the tokenizing in one C-level pass. `git add <N paths>` holds no structural
# character at all and is now two cursor moves whatever N is.
#
# `set -f` and an explicit IFS are load-bearing, not tidiness: without `-f` the split would
# PATHNAME-EXPAND a run containing `*` or `?` against the caller's working directory, and IFS is
# pinned to space and tab because a run cannot contain a newline (a newline is structural).
#
# WHAT THIS DOES NOT CLOSE, AND WHERE TO READ THE REST OF IT: issue #116, filed with its curve and
# its re-takeable command BEFORE this shipped, because a residual recorded only in the file that
# has it is readable only by someone already looking at the defect. Once per structural character
# is not once per COMMAND, so a string carrying MANY of them is still (structural characters) x
# (length).
#
# THE REACHABLE SIZE IS SIZE x DENSITY, NOT SIZE, and quoting the size alone understates it by up
# to 8x -- which is the correction #116 now carries and the reason this paragraph no longer quotes
# one curve. Whitespace is deliberately NOT structural, so density ranges over 24x between the
# shapes an agent really writes. Measured on darwin 25.5.0 against the declared 5 s, for a document
# written and staged in one call: quote-free PROSE crosses at ~110 KB (78 KB 3186 ms, 117 KB
# 5656 ms), ordinary JSON at 25-30 KB (19 KB 2791 ms, 34 KB 6837 ms), and quote-dense text at
# ~13 KB (12 KB 4771 ms, 14 KB 5962 ms). The concrete instance is this repository's own work:
# heredoc-writing `.pipeline/106/peer-review.json` (85 KB) and staging it in one call measured
# 3373-4134 ms over four runs, 67-83% of the budget.
#
# Closing it needs a BOUNDED scan window refilled from an untouched remainder, with refill points
# inside both quote loops and the backslash arm, which is a redesign rather than a fix.
_run_words() { # the run is in _run, already cut from _sc
  # A word left OPEN before this run either closes here or absorbs the run's first field --
  # `foo"bar"baz` is one word, and the quoted middle is why the field cannot simply be re-split.
  case $_run in
    [$_WS]*) ;;
    *)
      if [ "$_has" = 1 ]; then
        _seg=${_run%%[$_WS]*}
        if [ "$_seg" = "$_run" ]; then
          _w=$_w$_run # the whole run is one field and the word is still open
          return 0
        fi
        _w=$_w$_seg
        _CUR=$_run
        _cut "$_seg"
        _run=$_CUR
      fi
      ;;
  esac
  if [ "$_has" = 1 ]; then
    _inv_words "$_w"
    _w=''
    _has=0
    [ "$_VERDICT" = blanket ] && return 0
  fi
  case $_run in
    *' ' | *"$_TAB")
      _inv_words $_run # every field closed by the run's own trailing whitespace
      ;;
    *)
      # The last field has no whitespace behind it, so it stays open for whatever follows.
      _w=${_run##*[$_WS]}
      _has=1
      case $_run in
        *[$_WS]*) _inv_words ${_run%[$_WS]*} ;;
      esac
      ;;
  esac
  return 0
}

# A top-level operator ended the invocation: judge it and start the next one. Returns 1 when the
# verdict is already settled and the caller must stop.
_sep_done() {
  if [ "$_has" = 1 ]; then
    _inv_words "$_w"
    _w=''
    _has=0
  fi
  _redir=0
  _inv_finish
  [ "$_VERDICT" = blanket ] && return 1
  _inv_reset
  return 0
}

_scan_go() { # <command string> -> _VERDICT
  _sc=$1
  _VERDICT=clear
  _w=''
  _has=0
  _redir=0
  _inv_reset
  # EVERY READ OF `_sc` COSTS A COPY OF WHAT IS LEFT, so the loop is written to make as few of
  # them per structural character as it can: the emptiness test lives in the dispatch's own `''`
  # arm rather than in a `while` condition and a second `|| break`, which is two fewer copies per
  # turn. What survives is one `%%`, one cut, one dispatch and one single-character drop.
  while :; do
    _run=${_sc%%[$_STRUCT]*}
    if [ -n "$_run" ]; then
      _cut_sc "$_run"
      _run_words
      [ "$_VERDICT" = blanket ] && return 0
    fi
    case $_sc in
      '') break ;;
      "'"*)
        _sc=${_sc#?}
        _has=1
        _seg=${_sc%%\'*}
        _w=$_w$_seg
        _cut_sc "$_seg"
        _sc=${_sc#\'}
        ;;
      '"'*)
        _sc=${_sc#?}
        _has=1
        while [ -n "$_sc" ]; do
          _seg=${_sc%%[$_META_DQ]*}
          if [ -n "$_seg" ]; then
            _w=$_w$_seg
            _cut_sc "$_seg"
            [ -n "$_sc" ] || break
          fi
          case $_sc in
            '\'*)
              # The backslash is dropped and the character behind it is inert. Only `\"` and `\\`
              # need taking here: any other escaped character is not in `_META_DQ`, so the next
              # bulk slice absorbs it and the word comes out the same. `\<newline>` is the one
              # pair that must produce NOTHING -- a line continuation is deleted inside double
              # quotes exactly as it is outside them.
              _sc=${_sc#?}
              case $_sc in
                "$_NL"*) _sc=${_sc#?} ;;
                '"'* | '\'*) _lit1 ;;
              esac
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
        case $_sc in
          "$_NL"*)
            # A LINE CONTINUATION IS DELETED, NOT ESCAPED, and the difference was a live bypass.
            # POSIX removes backslash-newline before tokenizing: it is not a character, not a
            # word, and not a word boundary. Reading it as an escaped literal newline appended a
            # phantom operand to `git add -A`, and one operand is the whole of the term that
            # says a blanket stage was narrowed -- so `git add -A \<newline> && git commit -m
            # "x"` came back CLEAR while a real bash staged three files and committed them.
            # Nothing is appended here and `_has` is left exactly as it was, so the words either
            # side of the pair join into one the way the shell joins them.
            _sc=${_sc#?}
            ;;
          '') ;; # a lone trailing backslash: the shell produces no word from it either
          *)
            _has=1
            # An escaped ORDINARY character is picked up by the next bulk run; an escaped
            # METAcharacter has to be taken here or it would be read as the operator it is
            # spelled like.
            case $_sc in [$_META]*) _lit1 ;; esac
            ;;
        esac
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
          _cut_sc "$_seg"
        fi
        ;;
      '>'* | '<'*)
        # A redirection operator ends the current word and claims the next one as its TARGET. A
        # bare digit run immediately before it is an fd designator (`2>`), not an operand.
        if [ "$_has" = 1 ]; then
          case $_w in
            '' | *[!0-9]*) _inv_words "$_w" ;;
          esac
          _w=''
          _has=0
        fi
        _sc=${_sc#?}
        case $_sc in '>'* | '<'* | '&'* | '|'*) _sc=${_sc#?} ;; esac # >>, >|, >&, <<, <&, <>
        _redir=1
        ;;
      # `; & | newline ( )`: the top-level operators, by elimination -- everything else in
      # `_STRUCT` has its own arm above. The two-character spellings get their own arm here
      # rather than a second `case` inside the body, because that second read of `_sc` was one
      # more whole-remainder copy per separator and a multi-line command is mostly separators.
      ';;'* | '&&'* | '||'* | '(('* | '))'* | "$_NL$_NL"*)
        _sep_done || return 0
        _sc=${_sc#??}
        ;;
      *)
        _sep_done || return 0
        _sc=${_sc#?}
        ;;
    esac
  done
  [ "$_has" = 1 ] && _inv_words "$_w"
  [ "$_VERDICT" = blanket ] && return 0
  _inv_finish
  return 0
}

_scan() { # <command string> -> _VERDICT
  _sv_ifs=${IFS-}
  set -f
  IFS=$_WS
  _scan_go "$1"
  IFS=$_sv_ifs
  set +f
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
_STRUCT="$_NL'\"\\\\;&|()<>#"
_META_DQ="\"\\\\"
_WS=" $_TAB"
_SEP=";&|()$_NL"
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
