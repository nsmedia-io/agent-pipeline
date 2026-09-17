#!/usr/bin/env bash
# NOT A SUITE. The CORRECT spelling of same-local-oneline.sh, byte-for-byte identical to it
# apart from the split: the same one-line function body, the same names, the same argument.
# It is the other half of two claims at once -- that the detector reports 0 here (so it is not
# refusing every multi-name `local`), and that this spelling produces the value the defective
# one does not, on whichever bash is running.
set -u
f() { local a="$1"; local b="pre-${a:0:3}"; printf '%s' "$b"; }
f abcdefg
