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
# and was killed at this hook's own 5-second declared timeout -- a superseded figure, and the era
# it describes is the tree before this change, since #132 raised that declaration to 30 s -- and a
# killed PreToolUse hook FAILS OPEN, so the identical forbidden staging was DENIED with a short
# message and ALLOWED with a long one. Length is not a privilege, and it must not buy a bypass.
# The DIRECTION is not superseded: a killed PreToolUse hook still emits nothing and still falls
# open, and README item 27 cost (4) publishes where the crossing sits at the current bound.
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
# ERA: that 5000 ms bound is the pre-#132 declaration, superseded by 30 s; the 4064 ms is the
# measurement it was taken against and is unchanged by the raise.
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
  # THE VALUE IS CUT OUT BY FIELD SPLITTING, FOR THE REASON `_js_unescape` BELOW IS. Walking it
  # quote to quote cost one whole copy of the remainder per quote, so a JSON-escaped command --
  # which is what every quote-bearing command arrives as, since JSON spells each `"` as `\"` --
  # paid (quotes) x (length) on the path that decides a refusal, and a command carrying NO quote
  # paid the same product once, as a single `_cut` of the whole value through a 512-character
  # rung ladder that is quadratic in the prefix it drops. Measured on darwin 25.5.0 at 0b354c2,
  # that pair was the whole of the difference between `_scan` alone and the hook: 748 ms at 78 KB
  # and 1937 ms at 156 KB. Splitting on `"` is one C-level pass and the walk below calls nothing.
  #
  # THE FIELDS RECONSTRUCT THE OLD WALK EXACTLY. `${_js_t%%'"'*}` IS the first field, and what the
  # old loop left in `_js_t` after cutting it IS the remaining fields joined by `"`. A trailing
  # IFS delimiter produces no field, so an explicit empty one is appended when the haystack ends
  # in a quote; without it the closing quote of a value at the very end of the payload would be
  # read as part of the value.
  _js_sv=${IFS-}
  set -f
  IFS='"'
  set -- $_js_t
  IFS=$_js_sv
  set +f
  case $_js_t in *'"') set -- "$@" '' ;; esac
  # THE JOINING QUOTE IS CARRIED IN A VARIABLE RATHER THAN DECIDED BY A FIRST-FIELD TEST, and the
  # backslash-run parity is reached only through a `case` that most fields fail at their last
  # character. Both are statement-count fixes: this loop turns once per `"` in the command, which
  # in a JSON-escaped payload is once per quote the author WROTE, and the interpreter charges about
  # 16 us a statement.
  _js_acc=''
  _js_sml=''
  _js_post=''
  _js_state=0
  _js_j=''
  for _js_f do
    if [ "$_js_state" = 1 ]; then
      _js_post=$_js_post$_js_j$_js_f
      _js_j='"'
      continue
    fi
    _js_sml=$_js_sml$_js_j$_js_f
    _js_j='"'
    # TWO TIERS, BECAUSE ONE ACCUMULATOR IS QUADRATIC IN ITS OWN OUTPUT. `x=$x$f` copies x, so
    # appending k fields into one string costs (length)^2 / (field length). The small tier is
    # flushed at a fixed width, which bounds both terms: (length x 4096 / field length) for the
    # small tier and (length^2 / 8192) for the big one.
    if [ ${#_js_sml} -ge 4096 ]; then
      _js_acc=$_js_acc$_js_sml
      _js_sml=''
    fi
    # An even-length run of backslashes before the quote leaves the quote unescaped, and the
    # string ends there. An odd run means the quote is part of the value.
    case $_js_f in
      *'\')
        _js_bs=${_js_f##*[!\\]}
        [ $(( ${#_js_bs} % 2 )) -eq 0 ] && { _js_state=1; _js_j=''; }
        ;;
      *)
        _js_state=1
        _js_j=''
        ;;
    esac
  done
  [ "$_js_state" = 1 ] || return 1 # unterminated string
  _JS_VAL=$_js_acc$_js_sml
  _JS_POST=$_js_post
  _JS_OK=1
  return 0
}

# THE ESCAPES ARE CUT APART IN ONE PASS, FOR THE SAME REASON THE SCANNER'S WORDS ARE. Walking the
# value one escape at a time copied everything still to come, once per escape, so the cost was
# (number of escapes) x (length) -- and a MULTI-LINE command carries one `\n` escape per line, so
# an ordinary heredoc lands squarely in it: measured on darwin 25.5.0, 215 ms over a 20 KB value,
# 609 ms over 40 KB and 2165 ms over 80 KB, on the path that decides a refusal, against the
# 5-second `timeout` hooks.json declared before this change (superseded: #132 raised it to 30 s,
# and the three measurements above are unaffected -- what grew is the margin they left).
# Splitting on the escape character with the shell's own
# field splitting is one C-level pass, and the walk below makes no function call, so the whole
# thing is linear.
#
# THE EMPTY FIELD IS THE ESCAPED BACKSLASH, and that reading is what makes the split faithful. A
# non-whitespace IFS character delimits on EVERY occurrence, so `\\` leaves an empty field between
# its two backslashes; the field after it is therefore ordinary text and not an escape. A trailing
# lone backslash leaves no field at all and so produces nothing, which is what the previous walk
# did. Verified identical on bash 3.2 in sh mode, `bash --posix` and dash over `a\nb`, `a\\b`,
# `a\\\\b`, `\nfoo`, `foo\`, `foo\\`, `a\n\nb`, the empty string and a value with no escape.
#
# THE OUTPUT IS ACCUMULATED IN TWO TIERS for the reason `_js_get` is: `_ue_o=$_ue_o$_ue_f` copies
# `_ue_o`, so appending one field per escape costs (length)^2 / (bytes per escape), and an
# ordinary multi-line command carries one `\n` escape per line. Measured on darwin 25.5.0 over the
# 117 KB prose heredoc this issue's re-take builds: 2508 appends averaging half the output.
_js_unescape() { # <escaped> -> _UNESC
  _ue_o=''
  _ue_s=''
  _ue_sv=${IFS-}
  set -f
  IFS='\'
  set -- $1
  IFS=$_ue_sv
  set +f
  # THE TEXT BEFORE THE FIRST ESCAPE IS TAKEN OFF THE LIST RATHER THAN TESTED FOR ON EVERY FIELD.
  # One `shift` costs one pass over the list; a `_ue_first` test costs a statement per escape, and
  # a multi-line command carries one escape per line.
  [ $# -gt 0 ] || { _UNESC=''; return 0; }
  _ue_s=$1
  shift
  _ue_lit=0
  for _ue_f do
    if [ ${#_ue_s} -ge 4096 ]; then
      _ue_o=$_ue_o$_ue_s
      _ue_s=''
    fi
    if [ "$_ue_lit" = 1 ]; then
      _ue_lit=0
      _ue_s=$_ue_s$_ue_f # the field behind an escaped backslash is text, not an escape
      continue
    fi
    # The arms enumerate every escape RFC 8259 admits. The last one keeps the old reading of a
    # malformed escape -- the escape character stands for itself -- which is affordable because a
    # runtime that emits this payload emits valid JSON, so nothing reaches it in production.
    case $_ue_f in
      n*) _ue_s=$_ue_s$_NL${_ue_f#?} ;;
      t*) _ue_s=$_ue_s$_TAB${_ue_f#?} ;;
      r* | b* | f*) _ue_s=$_ue_s${_ue_f#?} ;;
      u*)
        # A \uXXXX escape cannot spell any token this matcher decides on, so it collapses to one
        # placeholder rather than being decoded: a decoder here would be a second, unreviewed
        # unescaper on the path that decides a refusal.
        _ue_s=$_ue_s'?'${_ue_f#?????}
        ;;
      '"'*) _ue_s=$_ue_s'"'${_ue_f#?} ;;
      /*) _ue_s=$_ue_s'/'${_ue_f#?} ;;
      '')
        _ue_s=$_ue_s'\'
        _ue_lit=1
        ;;
      *) _ue_s=$_ue_s$_ue_f ;;
    esac
  done
  _UNESC=$_ue_o$_ue_s
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
#     hooks.json declared prior to #132. ERA: the declaration is 30 s now, so that particular
#     8.3 s row no longer crosses; the shape it names is why the append was removed regardless.
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
#   _blanket   an all-tracked flag: -a/--all for commit, -A/-u/--all/--update for add
#   _pathspec  any operand that narrows what is staged
#
# ONE COMMAND, EIGHT ASSIGNMENTS, AND THAT IS A MEASUREMENT. This runs once per TOP-LEVEL
# SEPARATOR, so a heredoc body pays it per line; at about 16 us per statement in the interpreter
# that runs this file, eight statements is 130 us a line and 325 ms over a 2500-line document. A
# POSIX simple command may carry any number of assignments and no command word, and all of them
# take effect, so the whole reset is one statement.
_inv_reset() {
  _ist=head _idead=0 _valnext=0 _verb='' _blanket=0 _pathspec=0 _blanketspec=0 _endopts=0
}

_inv_words() { # <closed word>...
  for _f do
    if [ "$_redir" = 1 ]; then
      # A HEREDOC DELIMITER WORD IS CAPTURED HERE INSTEAD OF DISCARDED, and it costs nothing beyond
      # what the redirect-target discard already paid: `_f` arrives already quote-and-backslash
      # stripped by the SAME word-building machinery every other word goes through (#140), so bare,
      # single-quoted, double-quoted and backslash-escaped delimiter spellings all fall out of code
      # already in this file rather than a second, independently-maintained quote parser -- which is
      # exactly the class this file's own backslash-newline comment above names as a proven prior
      # bypass (a second, subtly divergent implementation of one parsing rule).
      if [ "$_hd" = 1 ]; then
        _hd=0
        # An EMPTY delimiter (`<<` immediately followed by whitespace/newline) is a real-bash syntax
        # error that opens no heredoc at all, so it must not claim any opacity a real shell would not
        # apply either -- the pending flag is left unset and the scanner falls through to ordinary
        # scanning of whatever follows.
        if [ -n "$_f" ]; then
          _HDDELIM=$_f
          _HDQ=$_hdq
          _hdpending=1
        fi
      fi
      _redir=0 # a redirection TARGET is not an operand
      continue
    fi
    # BREAK, NOT CONTINUE, AND THAT IS THE COST FIX AT THE OTHER END OF THE SAME ARGUMENT
    # `_run_words` makes. `_idead` is set only in the two arms below and cleared only by
    # `_inv_reset` at a top-level separator, so once it is 1 no later word of THIS invocation can
    # be read by anything -- including `_redir`, whose whole job is to skip a word nothing reads.
    # Walking the rest to conclude that cost two statements a word, and to this scanner every line
    # of a heredoc body is an invocation: 12 words a line, 5008 lines, ~350 us of nothing per line.
    [ "$_idead" = 0 ] || break
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
    # THE TEST IS STRUCTURAL OVER THE SUBSTITUTIONS, NOT A TABLE OF SPELLINGS OF THEM, because a
    # table would be reopened by the next spelling nobody enumerated. POSIX sh introduces a
    # SUBSTITUTION with exactly two characters -- `$` (parameter, command and arithmetic) and the
    # backquote -- and every spelling of every one of them (`$X`, `${X}`, `${X:-}`, `$(cmd)`,
    # `$((e))`, `$@`, `$1`, `$?`, and the backquoted form) necessarily contains one of the two. So
    # the rule is over THAT class: a word whose final content is decided by a SUBSTITUTION cannot
    # be read as naming a path.
    #
    # WHAT THAT SENTENCE DOES NOT COVER, named because a general claim over a specific test is what
    # makes the next reader stop looking. Substitution is not the only word expansion that can
    # erase an operand. PATHNAME EXPANSION contains neither character, and its result is decided by
    # the FILESYSTEM rather than by the text -- and under `shopt -s nullglob` it DELETES the word,
    # which is the same argv erasure this arm exists to close. Measured on darwin 25.5.0 with bash
    # 3.2.57(1) and a recording `git` shim, in a directory holding a.txt and b.txt:
    #
    #   bash -c 'shopt -s nullglob; git add -A *.nope'  -> ARGC=2 [add] [-A]   gate: ALLOW
    #   bash -c 'git add -A *.nope'   (nullglob OFF)    -> ARGC=3 [add] [-A] [*.nope]   gate: ALLOW
    #
    # The second line is the non-zero control that makes the first a reading and not a silence, and
    # it is also why this is left OPEN: nullglob is off by default, so on an ordinary host the word
    # survives, real git exits 128 having staged nothing, and the ALLOW is correct. Closing it by
    # adding `*` to the opaque set would put the control back to reading spellings of the input,
    # and would refuse `git add -A *.md` where the glob RESOLVES -- real narrowing work.
    #
    # AND THE COMMAND WORD AND THE VERB ARE READ LITERALLY, which is issue #118's residual, stated
    # here because a reader asking why some blanket stage was not seen looks at this comment first.
    # The opacity rule above is applied at the OPERAND positions only; the word naming the command
    # and the word naming the subcommand are matched as TEXT. Measured with the same shim, each of
    # these hands git `ARGC=2 [add] [-A]` -- a full blanket stage -- and each is ALLOWED here:
    # `GIT=git; $GIT add -A`, `VERB=add; git $VERB -A`, `eval "git add -A"`, and
    # `CMD="git add -A"; sh -c "$CMD"`. All four require an author to write the indirection
    # deliberately, which is why they are #118's adversarial class and not this change's accident.
    #
    # THE DIRECTION IS DELIBERATE AND ONLY ONE WAY. An opaque word is refused the power to NARROW,
    # so `git add -A $X` earns the same verdict as `git add -A` alone. It is NOT credited with the
    # power to BLANKET: `git add $X` stays clear, because crediting it would refuse `git add
    # $FILE`, the ordinary correct command, on the strength of X possibly being `.`. That is the
    # residual, stated rather than hidden -- and it is the deliberate half, since an empty
    # expansion is an ACCIDENT the author did not intend while `X=.` is a blanket stage the author
    # chose, and a text-scanning gate never claimed to refuse a stage its author meant.
    #
    # WHAT IT COSTS, measured rather than assumed, and stated over the CLASS rather than over two
    # convenient fixtures. EVERY blanket flag standing beside an operand that carries a
    # substitution is now denied, INCLUDING one that RESOLVES to a real path and would have staged
    # a correctly narrowed set. Measured against real git 2.x in a scratch repository holding a
    # modified `packages/pipeline/a.txt`, an untracked `packages/pipeline/new.txt` and an untracked
    # `outside.txt`:
    #
    #   PKG=pipeline; git add -A packages/$PKG   -> rc 0, staged packages/pipeline/{a,new}.txt,
    #                                               outside.txt untouched. DENIED here.
    #   F=packages/pipeline/a.txt; git add -u "$F" -> rc 0, staged exactly that one file. DENIED.
    #
    # `git add -A "$ARTIFACT_DIR"`, `git add -A .pipeline/$ISSUE` and `git add -u "$DIR"` are the
    # same shape. An earlier version of this paragraph named only `git add -A foo$X` and
    # `git add -A '$literal'`, which exit 128 and stage nothing, and concluded that no successful
    # staging is refused. THAT CONCLUSION WAS FALSE: both of those fixtures use an UNSET variable,
    # so exit 128 was a property of the two fixtures chosen and not of the class.
    #
    # THE REFUSAL IS ACCEPTED RATHER THAN OVERLOOKED, and this is the reason. `$F` holding a real
    # path and `$F` holding nothing are THE SAME TEXT, and this scanner never sees argv -- so
    # refusing the first is the price of denying the second, and no ordering of a text scan
    # separates them. What bounds the cost: the refusal is loud, carries its reason, and is
    # rewritable in two ways that are both allowed and both asserted in the suite -- name the path
    # literally (`git add -A packages/pipeline`), or drop the blanket flag (`git add "$DIR"`). And
    # a repository-wide grep for a blanket flag beside an expansion-bearing operand returns only
    # prose ABOUT this trade-off and zero real consumers, so no work this repository does today is
    # actually refused.
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

# THE SCAN READS A BOUNDED WINDOW, REFILLED FROM AN UNTOUCHED REMAINDER, AND THAT IS WHAT MAKES
# THE COST LINEAR RATHER THAN A PRODUCT.
#
# EVERY READ OF A SHELL VARIABLE COPIES WHAT IS IN IT. `${s%%[$_STRUCT]*}`, `${s#?}` and even
# `case $s in` each cost the LENGTH OF WHAT IS LEFT, and the scan has to turn once per STRUCTURAL
# character -- a quote, a backslash, a `#`, a redirection operator, a top-level separator. Walking
# the whole remainder therefore cost
#
#     (structural-character count)  x  (command length)
#
# which is linear for the three shapes #106 round 3 closed (one long token, many short words, many
# operands: all carry O(1) structural characters) and SUPERLINEAR for a command carrying many of
# them. Whitespace is deliberately not structural, which is what makes the bulk word split linear
# -- and is also why a fixture padded with quote-free tokens cannot construct the expensive
# subject. Density, not size, is the axis: a double quote costs about 3x a newline, and the shapes
# an agent really writes range over 24x.
#
# THE COST WAS NOT THEORETICAL AND THE SUBJECT WAS THIS REPOSITORY'S OWN WORK. Every figure in this
# paragraph describes the tree at 0b354c2, before the bounded window below existed and before #132
# raised the declaration, and all three crossings it states are superseded twice over. They are
# kept because they are what the window was built to answer, not as current figures.
# Measured on darwin 25.5.0 / bash 3.2.57(1) in sh mode / node v24.19.0 at 0b354c2, driving the
# then-shipped hook against the 5 s its hooks.json entry declared at that commit -- superseded, and
# the era it describes is the tree before this change -- quote-dense text (`echo "a" "a" ... ;
# git add -A`) took 5101 ms at 12.0 KB, ordinary pretty-printed JSON 5095 ms at 29.0 KB, and
# quote-free prose 5094 ms at 116.9 KB. Those three KB figures are superseded and describe the
# pre-#116 scan; each was killed at the timeout, each emitted nothing, and A PRETOOLUSE HOOK THAT
# EMITS NOTHING FAILS OPEN, so past those points the blanket staging on the far side of the heredoc
# was ALLOWED. WHERE THE CROSSING SITS NOW, re-derived at #132 against the current 30 s declaration
# and the current scan: README item 27 cost (4) carries it at both ends of the density range, with
# the lengths, the densities and the cells that remain uncovered. The non-synthetic instance: heredoc-writing `.pipeline/106/peer-review.json` (81.3 KB,
# the merged Phase 4 panel record of the issue that shipped this gate) and staging it in the same
# Bash call measured 3373-4500 ms, 67-90% of the budget, and doubling the file crossed.
#
# SO `_sc` NEVER HOLDS MORE THAN A WINDOW. The rest of the command sits in a QUEUE built by the
# shell's own field splitting, which is the only O(n) primitive this language offers. The queue has
# two levels and the second is built ONLY when the first produced a piece too big to scan:
#
#   1. WORDS. `IFS=<space><tab>` splits the command in one C-level pass and adjacent words are
#      regrouped with ONE space between them until the group reaches `_CW`. Whitespace RUN LENGTH
#      is the only thing lost and it is a term in no test `_inv_words` applies: collapsing never
#      removes ALL the whitespace from a word, so no word becomes `.`, `./`, `:/` or the empty
#      string. Whether the command OPENED and CLOSED with whitespace is restored explicitly,
#      because those are word boundaries and an unterminated quote makes the trailing one visible.
#   2. PIECES, for a word longer than `_CMAX`. The word is split on the first delimiter that cuts
#      it into small enough pieces and that delimiter is put back between them, so the
#      reconstruction is byte-for-byte. A newline is tried first, since a heredoc body carrying no
#      space at all is one word to level 1 and its newlines are its structure.
#
# NEWLINE IS THE ONE DELIMITER THAT CANNOT BE USED BLIND, AND THE DIFFERENTIAL FOUND IT RATHER THAN
# THIS COMMENT PREDICTING IT. A newline is an IFS WHITESPACE character, so a RUN of them collapses
# to one field boundary and cannot be reconstructed. That is verdict-neutral everywhere but one
# place: `echo a\<newline><newline>git add -A` is a line continuation followed by a SEPARATOR, and
# collapsing the pair leaves a continuation that swallows the separator, joins `a` to `git`, and
# turns a blanket stage into an `echo` invocation -- an ALLOW, from a live input, which is exactly
# the tokenizer-vs-shell divergence class #106's own backslash-newline bypass belonged to. A first
# draft of this queue split on newlines at level 1 and moved 6 verdicts of 38312 that way. So the
# newline delimiter is taken only when no backslash stands in front of one, which is checkable in
# a single pattern match, and a leading newline is restored by hand because a whitespace IFS drops
# it and a dropped leading separator MERGES two invocations.
#
# WHY THE LEVELS ARE BUILT LAZILY, AND NEVER FROM INSIDE A FIELD WALK. A shell function call SAVES
# AND RESTORES THE POSITIONAL PARAMETERS, and the cost is per STRING in that list, not per byte:
# measured on this host, 200 calls to a `:` function cost 88 ms with one 100 KB parameter and
# 3183 ms with 20000 five-byte ones, against an 80 ms instrument floor. A refill helper called once
# per field is therefore the trap #106 round 3 fell into once already, when a draft made the
# 5000-word case slower than the thing it replaced. So every loop below that walks `$@` calls
# NOTHING, and writes the queue with `eval` instead -- `eval` runs in the current context and does
# not touch `$@` (measured: 156 ms for 8000 evals inside an 8000-element walk, against 47585 ms for
# 8000 function calls in the same walk).
#
# `set -f` and an explicit IFS are load-bearing at every split, not tidiness: without `-f` a field
# containing `*` or `?` would be PATHNAME-EXPANDED against the caller's working directory.

_CW=512    # the window the scan works in, and the size the queue groups pieces up to
_CMAX=1024 # a queue entry at or over this is split one level finer before it is scanned

_wordchunk() { # <queue entry at or over _CMAX> : fills _T1.._TN with windows
  # A TRAILING SPACE IS APPENDED BEFORE THE SPLIT AND NEVER REMOVED. A trailing IFS delimiter
  # produces no field at all, so without it a word ending in the chosen delimiter would silently
  # lose that delimiter. The space itself is inert: level 1 hands a word here only when whitespace
  # or the end of the command follows it, so the word ends in the same place either way, and the
  # entry is at least _CMAX long so no test that reads an EMPTY operand can see the difference.
  _wc_w=$1' '
  _TN=0
  _TI=1
  _wc_need=$(( ${#_wc_w} / _CW ))
  [ "$_wc_need" -lt 2 ] && _wc_need=2
  _wc_d=''
  _wc_best=''
  _wc_bestn=0
  _wc_lead=''
  _wc_sv=${IFS-}
  # NEWLINE FIRST, AND ONLY BEHIND ITS GUARD. A heredoc body that carries no space is one word to
  # level 1 and every newline in it is a top-level separator, so this is the delimiter that matters
  # most -- but it is an IFS whitespace character, so a RUN of newlines collapses to one boundary
  # and a LEADING run is dropped entirely. Collapsing is verdict-neutral except in front of a
  # backslash, where it converts a continuation-plus-separator into a continuation that eats the
  # separator; the guard refuses the delimiter outright in that case rather than trying to tell the
  # two apart. A dropped LEADING newline is never neutral -- it merges two invocations -- so it is
  # restored by hand. The trailing one is restored by the appended space above.
  #
  # THAT RESTORE IS A RATCHET AND NOT A LIVE CONTROL, said plainly so a reader does not go looking
  # for the input that reaches it. Deleting it moves no verdict over 38864 corpus rows, because
  # level 1 prefixes EVERY word with one space unconditionally, so no queue entry can open with a
  # newline. It guards `_wordchunk`'s own contract against a level-1 build that stopped doing that.
  case $_wc_w in
    *'\'"$_NL"*) ;;
    *"$_NL"*)
      IFS=$_NL
      set -- $_wc_w
      IFS=$_wc_sv
      if [ $# -ge "$_wc_need" ]; then
        _wc_d=$_NL
        case $_wc_w in "$_NL"*) _wc_lead=$_NL ;; esac
      else
        _wc_bestn=$#
        _wc_best=$_NL
      fi
      ;;
  esac
  # A delimiter is ACCEPTED when it cuts the entry into enough pieces to average under one window,
  # and the FIRST one that does wins so the common case stops early. When none does, the fallback is
  # the delimiter that occurred MOST, and that choice is what keeps the whole function linear rather
  # than merely usually-fast. Taking the first one PRESENT instead is a trap with a measurement
  # behind it: one `"` early in a 64 KB word and 1200 `;` after it would pick the `"`, leave a 64 KB
  # piece holding every `;`, and put the product of density and length straight back inside one
  # window. Picking the most frequent bounds it in both directions at once -- no other delimiter can
  # occur more often than the winner, so the entry's TOTAL structural count is at most (size of
  # `_DELIMS`) x (winner's count) while the window is (length / winner's count), and the product of
  # those two is (size of `_DELIMS`) x length however the characters are distributed.
  #
  # If NO delimiter is present at all the entry carries no structural character, and the scan
  # crosses it in a single move whatever its length.
  if [ -z "$_wc_d" ]; then
    _wc_rest=$_DELIMS
    while [ -n "$_wc_rest" ]; do
      _wc_c=${_wc_rest%"${_wc_rest#?}"}
      _wc_rest=${_wc_rest#?}
      case $_wc_w in
        *"$_wc_c"*) ;;
        *) continue ;;
      esac
      IFS=$_wc_c
      set -- $_wc_w
      IFS=$_wc_sv
      if [ $# -ge "$_wc_need" ]; then
        _wc_d=$_wc_c
        break
      fi
      if [ $# -gt "$_wc_bestn" ]; then
        _wc_bestn=$#
        _wc_best=$_wc_c
      fi
    done
    if [ -z "$_wc_d" ]; then
      if [ -z "$_wc_best" ]; then
        _TN=1
        _T1=$_wc_w
        return 0
      fi
      _wc_d=$_wc_best
      case $_wc_d in
        "$_NL") case $_wc_w in "$_NL"*) _wc_lead=$_NL ;; esac ;;
      esac
      IFS=$_wc_d
      set -- $_wc_w
      IFS=$_wc_sv
    fi
  fi
  _wc_acc=$_wc_lead
  _wc_first=1
  for _wc_p do
    if [ "$_wc_first" = 1 ]; then
      _wc_first=0
      _wc_acc=$_wc_acc$_wc_p
    else
      _wc_acc=$_wc_acc$_wc_d$_wc_p # the delimiter belongs BEFORE every piece but the first
    fi
    if [ ${#_wc_acc} -ge "$_CW" ]; then
      _TN=$((_TN + 1))
      eval "_T$_TN=\$_wc_acc"
      _wc_acc=''
    fi
  done
  if [ -n "$_wc_acc" ]; then
    _TN=$((_TN + 1))
    eval "_T$_TN=\$_wc_acc"
  fi
  [ "$_TN" -gt 0 ] || { _TN=1; _T1=$_wc_w; }
  return 0
}

_fill() { # append the next window to _sc; return 1 when the command is exhausted
  while :; do
    if [ "$_TI" -le "$_TN" ]; then
      eval "_fl=\$_T$_TI"
      _TI=$((_TI + 1))
    elif [ "$_QI" -le "$_QN" ]; then
      eval "_fl=\$_Q$_QI"
      _QI=$((_QI + 1))
      if [ ${#_fl} -ge "$_CMAX" ]; then
        # Level 2 is built HERE and never from inside the level-1 walk, because `$@` holds every
        # word of the command while that walk runs and a call would save and restore all of them.
        _wordchunk "$_fl"
        continue
      fi
    else
      return 1
    fi
    [ -n "$_fl" ] || continue
    _sc=$_sc$_fl
    return 0
  done
}

_run_words() { # the run is in _run, already cut from _sc
  # A DEAD INVOCATION READS NO WORDS AT ALL, AND THIS IS THE SECOND HALF OF THE COST FIX. Once the
  # head word of an invocation is not `git`, nothing later in it can stage, so every word after it
  # is inert -- and the walk that proves each one inert costs more than everything else on this
  # path put together. The interpreter this file runs in charges about 16 us PER STATEMENT
  # (measured on darwin 25.5.0, bash 3.2.57(1) in sh mode: 50000 turns of a bare `while` loop with
  # one arithmetic assignment, 794 ms, plus 412 ms for a function call, 379 ms for a `case`, 513 ms
  # for `${#var}`), so cost here is STATEMENT COUNT and not bytes. A heredoc body is the shape that
  # makes it visible: to this scanner every line of it is an invocation headed by an ordinary word,
  # so 30000 words of prose were 30000 trips through the flag-and-operand walk to conclude nothing.
  #
  # ONLY THE WORD-BOUNDARY STATE SURVIVES, because the comment and redirection arms ask whether a
  # word is open. The word's CONTENT cannot be read by anything while `_idead` is 1: `_inv_words`
  # returns on it, `_inv_finish` returns on it, and the flush in `_sep_done` runs BEFORE the
  # `_inv_reset` that clears it -- so `_w` is consumed while still dead, every time.
  #
  # ONE EXCEPTION (#140): a pending heredoc delimiter's TEXT must still reach `_inv_words`'s capture
  # branch even when the invocation introducing it is dead (`cat <<EOF`, not `git`) -- the body a
  # heredoc opens has to be opaque regardless of which command owns it, since a live command can
  # follow the terminator on a LATER line of the same call. `_redir$_hd` is `11` only while THIS
  # specific word is that delimiter, so every other dead word this scanner meets (the common case a
  # heredoc BODY line is) still takes the fast path with no added cost.
  if [ "$_idead" = 1 ] && [ "$_redir$_hd" != 11 ]; then
    _w=''
    case $_run in
      *' ' | *"$_TAB") _has=0 ;;
      *) _has=1 ;;
    esac
    return 0
  fi
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
        if [ ${#_seg} -lt 64 ]; then
          _run=${_run#"$_seg"} # one pass over the run, against the ladder's copy per 512 characters
        else
          _CUR=$_run
          _cut "$_seg"
          _run=$_CUR
        fi
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
      # The last field has no whitespace behind it, so it stays open for whatever follows -- which
      # is also how a word survives a window boundary, since a window ends where a field does.
      # `${_run##*[$_WS]}` IS QUADRATIC AND THIS IS THE THIRD PLACE IN THIS FILE THAT SENTENCE HAS
      # BEEN TRUE. A `##` asks for the LONGEST prefix, so the shell tries prefix lengths from the
      # whole string DOWNWARD and re-runs `*[$_WS]` -- itself a scan -- at each one. When the last
      # whitespace is at the FRONT of the run, which is exactly where the queue puts it, that is
      # length^2. It is the density axis's own `run` cell that found it: a 24 KB unbroken word as a
      # heredoc body measured 40.5 s in `_scan` at 0b354c2 and 39.6 s with the window in place,
      # because the window fixed the SCAN and this line is not in the scan. Field splitting answers
      # the same question in one pass, and `$@` is empty on this path (`_scan_go` cleared it), so
      # the positional list this borrows costs one string per word and no save-and-restore.
      _has=1
      case $_run in
        *[$_WS]*)
          IFS=$_WS
          set -- $_run
          _nw=$#
          [ "$_nw" -gt 1 ] && shift $((_nw - 1))
          _w=$1
          set --
          _inv_words ${_run%[$_WS]*}
          ;;
        *) _w=$_run ;;
      esac
      ;;
  esac
  return 0
}

# A REAL SHELL NEVER RE-TOKENIZES A HEREDOC BODY; IT COPIES IT VERBATIM TO THE TERMINATOR LINE, and
# this is that copy, called once per pending heredoc right after the newline that starts its body
# (#140). No quote, comment, redirection or operator character below can change `_VERDICT` or any
# scan state other than what this function itself tracks -- that is the opacity the fix adds.
#
# THE SAME BULK-SLICE / `_cut_sc` IDIOM THE COMMENT ARM ALREADY USES, extended to run PER LINE
# instead of to end of command, because a heredoc body ends at a specific line and a comment does
# not. `_seg`/`_hdnl` name whether the CURRENT WINDOW holds a real newline; when it does not (a
# single line wider than one refill), the window in hand is cut and discarded immediately rather
# than accumulated onto `_sc`, which is what keeps this LINEAR rather than quadratic in that line's
# length -- the DENSITY AXIS `run` fixture (one unbroken run at a fixed length, no internal
# whitespace or newline) is exactly the adversarial shape that would expose an accumulate-then-scan
# version of this loop, and is why AC7 re-measures the DENSITY AXIS post-fix rather than assuming
# the window model alone carries over.
#
# A LINE THAT NEVER FIT IN ONE WINDOW CANNOT BE THE TERMINATOR EITHER WAY (`_hdtoolong`), because
# `_HDDELIM` is a single already-captured word and a real terminator line is exactly that word alone
# -- so once a line has needed a second refill, its candidacy is settled without assembling its full
# text, and only the AC12 substring scan (below) still has to see every byte of it.
#
# AC12's OWN GUARD RUNS HERE TOO, ONE COARSE CHECK PER WINDOW, gated on `_HDQ` (frozen at capture
# time: 0 for an unquoted delimiter, 1 for a quoted or backslash-escaped one -- quoted stays fully
# opaque, per SecOps's non-weakening clause, and never runs this check at all). `_hdtail` carries the
# last byte of the PREVIOUS window into this one so a two-character trigger split across a refill
# boundary is still seen; it is cleared at every real newline, because a `$` at the end of one line
# and a `(` at the start of the next are not adjacent text and must not be read as one.
#
# THE TWO TRIGGERS DO NOT GET THE SAME RESPONSE, AND THAT ASYMMETRY IS AC12(b)'S OWN REQUIREMENT.
# Backtick and `${` are not members of `_STRUCT` at all (confirmed by SecOps via direct grep), so
# there is no existing mechanism that would ever evaluate what is inside them -- an unquoted body
# containing either is denied OUTRIGHT here, unconditionally, which is the "genuinely new
# protection" AC12(c) names. `$(` is different: `(` already IS a `_STRUCT` member and already ends
# an invocation as an ordinary top-level separator, so the PRE-FIX scanner already evaluates
# `$(git add -A)` correctly BY ACCIDENT once nothing is holding it opaque (SecOps's VETO evidence).
# So for `$(` alone this function does the MINIMUM the fix needs -- stop being opaque and hand `_sc`
# back to `_scan_go`'s own top-level loop exactly where the body was, unconsumed -- and lets that
# existing mechanism discriminate blanket (AC12(a), `_verb=add` `_blanket=1` `_pathspec=0` ->
# `_VERDICT=blanket`) from narrow (AC12(b), a pathspec is set so `_inv_finish` never sets a verdict)
# on its own. Denying on sight of `$(` regardless of content, the same way backtick is handled,
# would satisfy AC12(a) but fail AC12(b) outright -- this is why the two are not one `case` arm.
_hd_skip() {
  _hdtail=''
  _hdtoolong=0
  while :; do
    case $_sc in
      *"$_NL"*)
        _seg=${_sc%%"$_NL"*}
        _hdnl=1
        ;;
      *)
        _seg=$_sc
        _hdnl=0
        ;;
    esac
    if [ "$_hdnl" = 0 ] && [ "$_eof" = 0 ]; then
      if [ "$_HDQ" = 0 ]; then
        case $_hdtail$_seg in
          *'`'* | *'${'*)
            _VERDICT=blanket
            return 0
            ;;
          *'$('*) return 0 ;;
        esac
      fi
      _hdtoolong=1
      # READ THE LAST CHARACTER WITHOUT NAMING A LONG LITERAL. `${_seg#"${_seg%?}"}` -- the file's
      # own first-character idiom mirrored backwards -- is exactly the `${s#"$long"}` shape its own
      # header measures at 2.2 s PER CALL over a whole-string prefix (#106); `_seg` is unbounded
      # here (a `_wordchunk` fallback can hand back one window far past `_CW` for a structural-
      # character-free run, which is the DENSITY AXIS `run` fixture's own shape), so that idiom is
      # quadratic in exactly the input this branch exists to handle. Shrunk to under 64 bytes FIRST,
      # by the same glob-anchored rung ladder `_cut`/`_cut_sc` already use, the identical idiom over
      # the SHORT remainder costs at most 64^2 -- a rounding error -- which is why it is safe in
      # `_lit1` (always called on an already-window-bounded `_sc`) and was not safe verbatim here.
      _hdshrink=$_seg
      while :; do
        case $_hdshrink in
          $_Q512*) _hdshrink=${_hdshrink#$_Q512} ;;
          $_Q64*) _hdshrink=${_hdshrink#$_Q64} ;;
          *) break ;;
        esac
      done
      case $_hdshrink in
        '') ;;
        *) _hdtail=${_hdshrink#"${_hdshrink%?}"} ;;
      esac
      if [ -n "$_seg" ]; then
        if [ ${#_seg} -lt 64 ]; then
          _sc=${_sc#"$_seg"}
        else
          _cut_sc "$_seg"
        fi
      fi
      _fill || _eof=1
      continue
    fi
    if [ "$_HDQ" = 0 ]; then
      case $_hdtail$_seg in
        *'`'* | *'${'*)
          _VERDICT=blanket
          return 0
          ;;
        *'$('*) return 0 ;;
      esac
    fi
    if [ "$_hdtoolong" = 0 ]; then
      if [ "$_hddash" = 1 ]; then
        # STRIPS A LEADING _WS RUN (SPACE-OR-TAB), NOT A BARE TAB, EVEN THOUGH POSIX `<<-` ONLY
        # STRIPS TABS. `_sc` never sees the raw command text: LEVEL 1's own queue split
        # (`_scan_go`, `IFS=$_WS`) already collapsed every leading tab run into ONE reconstructed
        # `_SP` character before this function ever runs, so the tab/space distinction this
        # candidate is compared on is gone by construction, not by a choice made here. Widening the
        # strip to cover a reconstructed space is the SAFE side of that loss: it can only make this
        # function decide the body ended SOONER than a real `<<-` would, handing the (real, still-
        # part-of-the-body-in-a-real-shell) text that follows to ORDINARY scanning instead of
        # opacity -- which can only turn inert data into something this scanner denies, never the
        # reverse. No AC constructs a space-indented terminator that must NOT match under `<<-`.
        _cand=$_seg
        while :; do
          case $_cand in
            [$_WS]*) _cand=${_cand#?} ;;
            *) break ;;
          esac
        done
      else
        _cand=$_seg
      fi
    else
      _cand=''
    fi
    if [ -n "$_seg" ]; then
      if [ ${#_seg} -lt 64 ]; then
        _sc=${_sc#"$_seg"}
      else
        _cut_sc "$_seg"
      fi
    fi
    [ "$_hdnl" = 1 ] && _sc=${_sc#?}
    if [ "$_hdtoolong" = 0 ] && [ "$_cand" = "$_HDDELIM" ]; then
      return 0
    fi
    _hdtail=''
    _hdtoolong=0
    [ "$_hdnl" = 1 ] || return 0
  done
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
  # LEVEL 1 OF THE QUEUE. Built inline rather than in a helper because `$@` holds every word of the
  # command while this walk runs, and a call here would pay for all of them.
  #
  # TWO STATEMENTS PER WORD, AND THE COUNT IS THE WHOLE DESIGN OF THIS LOOP. It turns once per
  # word of the command whatever the shape, so at ~16 us a statement it is the floor every other
  # figure sits on: 60000 words of prose cost 1.3 s here at two statements and 2.6 s at four.
  #
  # SO EVERY WORD IS PREFIXED WITH ONE SPACE, unconditionally, rather than testing for the first.
  # A leading space on the whole command is inert -- no word is open at the start, so the run
  # `_run_words` sees splits into no fields at all -- while the space BETWEEN two words is a word
  # boundary that must be there. Whitespace RUN LENGTH and tabs collapse to that one space; the
  # verdict reads neither.
  #
  # THE TRAILING RUN IS THE ONE THAT HAS TO BE RESTORED BY HAND, because field splitting drops it
  # and an unterminated quote at the end of a command makes it VISIBLE: a real shell hands
  # `git add -A '<spaces>` the operand `<spaces>`, which NARROWS, and the empty operand without it,
  # which does not. That is a verdict, so it is read from the command before the split.
  _QN=0
  _QI=1
  _TN=0
  _TI=1
  case $1 in
    *[$_WS]) _qacc=$_SP ;;
    *) _qacc='' ;;
  esac
  _qtail=$_qacc
  _qacc=''
  IFS=$_WS
  set -- $1
  for _ql do
    _qacc=$_qacc$_SP$_ql
    if [ ${#_qacc} -ge "$_CW" ]; then
      _QN=$((_QN + 1))
      eval "_Q$_QN=\$_qacc"
      _qacc=''
    fi
  done
  _qacc=$_qacc$_qtail
  if [ -n "$_qacc" ]; then
    _QN=$((_QN + 1))
    eval "_Q$_QN=\$_qacc"
  fi
  set -- # from here on every call is free of the positional-parameter save and restore

  _sc=''
  _eof=0
  _VERDICT=clear
  _w=''
  _has=0
  _redir=0
  # THE FOURTH OPAQUE REGION, ALONGSIDE THE SINGLE-QUOTE/DOUBLE-QUOTE/COMMENT REGIONS ABOVE (#140).
  # `_hd`/`_hddash`/`_hdq` track the delimiter word CURRENTLY being captured (cleared the moment
  # that word closes); `_hdpending`/`_HDDELIM`/`_HDQ` are the FROZEN result once it has, read by
  # `_hd_skip` at the next real newline. Two heredocs introduced on one line (`cat <<A <<B`) share
  # this scalar state last-writer-wins -- a named, accepted gap (design.json residual_risks), not
  # this scanner's only unmodeled construct (#118's verb opacity is the other).
  _hd=0
  _hddash=0
  _hdq=0
  _hdpending=0
  _HDDELIM=''
  _HDQ=0
  _inv_reset
  while :; do
    # TWO CHARACTERS, NOT ONE, AND THE SECOND ONE IS LOAD-BEARING. `&&`, `||`, `;;`, `((`, `))`,
    # `>>` and the `&` of `2>&1` are each decided by a PAIR, so a window that ended between them
    # would read one operator as two. Every such pair happens to be inert when split -- two
    # separators judge one empty invocation, which `_inv_finish` returns from without a verdict --
    # except `>&`, where the `&` would end the invocation instead of being consumed as part of the
    # redirection. Keeping two characters in the window while any input remains closes all of them
    # at once rather than one spelling at a time.
    #
    # THIS IS ALSO A RATCHET TODAY, and the reason is worth writing down because it is the kind of
    # thing a reader re-derives badly. Weakening `??*` to `?*` moves no verdict over 38864 corpus
    # rows: a window edge falls either at a WORD boundary (level 1, so an adjacent pair is never
    # split) or immediately before a delimiter INSIDE a word of at least `_CMAX` bytes (level 2) --
    # and a `>&` reachable inside a git invocation cannot sit at the second kind, because that
    # word's own `&` characters have ended the invocation long before the `>&` is reached.
    #
    # THE GUARD IS A `case` AND NOT TWO `[`s, AND SO IS EVERY OTHER TEST ON THIS PATH. `case`
    # measured 379 ms per 50000 turns against 513 ms for `${#var}` and 794 ms for the bare loop
    # itself, so replacing `[ ${#_sc} -lt 2 ] && [ "$_eof" = 0 ]` with one anchored pattern takes
    # about 25 us off EVERY turn of the scan.
    case $_sc in
      ??*) ;;
      *)
        while [ "$_eof" = 0 ]; do
          _fill || _eof=1
          case $_sc in ??*) break ;; esac
        done
        [ -n "$_sc" ] || break
        ;;
    esac
    _run=${_sc%%[$_STRUCT]*}
    if [ -n "$_run" ]; then
      # A SHORT RUN IS DROPPED BY NAME AND A LONG ONE THROUGH THE LADDER, and the split is bought
      # by both measurements this file already carries. `${s#"$pre"}` costs one pass over the
      # SUBJECT and is quadratic in the PREFIX, so it is right here, where the subject is one
      # bounded window; the rung ladder costs a whole copy of the window per 512 characters, so it
      # is right only for a prefix long enough to make its own quadratic worse -- which happens
      # only inside an oversized window, the giant-token shape `git commit -a -m "c <200000 y>"`.
      # Below the cut, this replaces a function call and its loop (six statements) with two.
      if [ ${#_run} -lt 64 ]; then
        _sc=${_sc#"$_run"}
      elif [ "$_run" = "$_sc" ]; then
        _sc=''
      else
        _cut_sc "$_run"
      fi
      _run_words
      [ "$_VERDICT" = blanket ] && return 0
      continue
    fi
    case $_sc in
      '') break ;;
      "'"*)
        _sc=${_sc#?}
        _has=1
        # A quoted heredoc delimiter (`<<'EOF'`) suppresses the body's own $-expansion in a real
        # shell (POSIX: "if any characters in word are quoted"), which is why AC12's coarse guard
        # must not apply to it -- `_redir$_hd` is `11` only while THIS word is the pending delimiter.
        case $_redir$_hd in 11) _hdq=1 ;; esac
        while :; do
          _seg=${_sc%%\'*}
          if [ "$_seg" = "$_sc" ]; then
            _w=$_w$_seg # the closing quote is not in this window
            _sc=''
            _fill || break
            continue
          fi
          _w=$_w$_seg
          if [ ${#_seg} -lt 64 ]; then
            _sc=${_sc#"$_seg"}
          else
            _cut_sc "$_seg"
          fi
          _sc=${_sc#\'}
          break
        done
        ;;
      '"'*)
        _sc=${_sc#?}
        _has=1
        case $_redir$_hd in 11) _hdq=1 ;; esac # see the single-quote arm's comment above
        # ONE TURN PER QUOTED SEGMENT, NOT TWO. The bulk slice and the character that ENDED it are
        # taken in the same iteration, because `"a"` -- one token of the quote-dense shape that
        # crossed the timeout at 12 KB -- otherwise costs a second trip through the refill guard,
        # the `%%` and the dispatch to conclude that the next character is the closing quote.
        while :; do
          _seg=${_sc%%[$_META_DQ]*}
          if [ -n "$_seg" ]; then
            _w=$_w$_seg
            if [ ${#_seg} -lt 64 ]; then
              _sc=${_sc#"$_seg"}
            elif [ "$_seg" = "$_sc" ]; then
              _sc=''
            else
              _cut_sc "$_seg"
            fi
          fi
          # `_seg` stopped at a member of `_META_DQ` or ran the window out, so exactly three cases
          # remain: the closing quote, the window edge, and a backslash.
          case $_sc in
            '"'*)
              _sc=${_sc#?} # the closing quote
              break
              ;;
            '')
              while [ "$_eof" = 0 ]; do
                _fill || _eof=1
                case $_sc in ?*) break ;; esac
              done
              [ -n "$_sc" ] || break
              ;;
            *)
              # The backslash is dropped and the character behind it is inert. Only `\"` and `\\`
              # need taking here: any other escaped character is not in `_META_DQ`, so the next
              # bulk slice absorbs it and the word comes out the same. `\<newline>` is the one
              # pair that must produce NOTHING -- a line continuation is deleted inside double
              # quotes exactly as it is outside them.
              _sc=${_sc#?}
              case $_sc in
                '')
                  while [ "$_eof" = 0 ]; do
                    _fill || _eof=1 # the escaped character can open the next window
                    case $_sc in ?*) break ;; esac
                  done
                  ;;
              esac
              case $_sc in
                "$_NL"*) _sc=${_sc#?} ;;
                '"'* | '\'*) _lit1 ;;
              esac
              ;;
          esac
        done
        ;;
      '\'*)
        _sc=${_sc#?}
        if [ -z "$_sc" ] && [ "$_eof" = 0 ]; then
          _fill || _eof=1 # the escaped character can be the first one of the next window
        fi
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
            case $_redir$_hd in 11) _hdq=1 ;; esac # see the single-quote arm's comment above
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
          while :; do
            _seg=${_sc%%"$_NL"*}
            if [ "$_seg" != "$_sc" ]; then
              _cut_sc "$_seg"
              break
            fi
            _sc='' # the comment runs past this window
            _fill || break
          done
        fi
        ;;
      '<<<'*)
        # A here-string's operand is fed to the command's STDIN; it is not part of the invocation's
        # argv and it opens no multi-line body for this scanner to walk (#140 sibling_causes_
        # considered). Tested and consumed here, ahead of the heredoc arm below, so a here-string can
        # never by construction reach the heredoc-body-opacity logic (AC11(a)/(b)) -- this arm is
        # byte-for-byte the pre-#140 generic redirection handling, unchanged.
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
      '<<'*)
        # A heredoc introducer (`<<` or `<<-`). The delimiter word that follows is claimed as an
        # inert redirect TARGET exactly like any other (`_redir=1`), and is additionally captured
        # into `_HDDELIM` as a side effect of the SAME discard branch in `_inv_words` -- #140.
        if [ "$_has" = 1 ]; then
          case $_w in
            '' | *[!0-9]*) _inv_words "$_w" ;;
          esac
          _w=''
          _has=0
        fi
        _sc=${_sc#??}
        case $_sc in
          '-'*)
            _hddash=1
            _sc=${_sc#?}
            ;;
          *) _hddash=0 ;;
        esac
        _hd=1
        _hdq=0
        _redir=1
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
      #
      # `$_NL$_NL` (a blank line) is DELIBERATELY NOT bundled in here (#140), even though it is a
      # two-character spelling like the others. A single newline is the one separator a heredoc
      # BODY actually starts after -- never `;`/`&`/`|`/`(`/`)` -- so it needs its own arm to check
      # `_hdpending` right after `_sep_done` flushes the delimiter word, on EVERY newline including
      # the first of a pair. Folding `$_NL$_NL` in here would skip that check whenever the body's
      # own first line is blank, silently missing the opacity switch. The cost is real and named
      # rather than assumed: this trades away the paired-newline fast path, so AC7's regression
      # budget is re-measured post-fix on a many-blank-line corpus rather than carried over.
      ';;'* | '&&'* | '||'* | '(('* | '))'*)
        _sep_done || return 0
        _sc=${_sc#??}
        ;;
      "$_NL"*)
        _sep_done || return 0
        _sc=${_sc#?}
        if [ "$_hdpending" = 1 ]; then
          _hdpending=0
          _hd_skip
          [ "$_VERDICT" = blanket ] && return 0
        fi
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
_SP=" "
_Q64="$_Q8$_Q8$_Q8$_Q8$_Q8$_Q8$_Q8$_Q8"
_Q512="$_Q64$_Q64$_Q64$_Q64$_Q64$_Q64$_Q64$_Q64"

# THE CANDIDATE WINDOW BOUNDARIES FOR A WORD TOO LONG TO SCAN WHOLE, most useful first. These are
# not a security list and nothing is decided by membership: a delimiter here only says WHERE the
# queue may cut, and whichever is chosen is put straight back between the pieces, so the string the
# scanner sees is byte-for-byte the one the payload carried. `_STRUCT`'s members lead because
# structural density is the term that makes a window expensive; the six after them bound a window
# in minified data (JSON, a base64 blob, a long URL) that carries no structural character to cut
# on. Built by concatenation rather than spelled as one literal, because a string holding a quote,
# an apostrophe and a backslash at once is exactly the shape #106 already shipped a silent
# deny-to-allow in. No newline: level 1 has already split on those, so no word can hold one.
_DELIMS='"'
_DELIMS=$_DELIMS"'"
_DELIMS=$_DELIMS'\'
_DELIMS=$_DELIMS';&|()<>#,:=./-'

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
