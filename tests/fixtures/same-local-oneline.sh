#!/usr/bin/env bash
# NOT A SUITE, and deliberately DEFECTIVE. This file carries the exact construct the AC41(d)
# detector in test-issue17-integration.sh exists to refuse:
#
#   local a="$1" b="pre-${a:0:3}"
#
# It lives in fixtures/ rather than inline in the suite because the detector's population IS
# the shipped suites and hooks (a flat tests/*.sh plus hooks/*.sh), and a suite that spells the
# defect inline to demonstrate it counts ITSELF and can never reach zero. Moving the construct
# here removes it from that population without touching the detector, which is a ratchet.
#
# run.sh discovers by a flat `test-*.sh` glob in tests/ and never recurses, so nothing here is
# ever run as a suite. It is read by the detector and executed on purpose by the demo.
#
# `set -u` matches harness.sh, which every suite sources. Without it bash 5 expands the
# not-yet-assigned name to the empty string exactly as bash 3.2 does, and the two shells stop
# disagreeing -- which is not the behaviour that broke CI.
set -u
f() { local a="$1" b="pre-${a:0:3}"; printf '%s' "$b"; }
f abcdefg
