#!/usr/bin/env bash
# The suite on Linux, in a container, on demand.
#
#   bash plugins/pipeline/tests/run-linux.sh                 # the whole suite (run.sh)
#   bash plugins/pipeline/tests/run-linux.sh test-a.sh ...   # named suites only
#
# This replaced .github/workflows/tests.yml in 0.40.2. That workflow ran the ~40-minute suite
# (with its nested fresh-checkout run) on every push and pull request, and the Actions minutes
# were the owner's subscription. The property the workflow carried is kept, not dropped: the
# suite is evaluated on a LINUX host with the strict-capability flag set, so a column that only
# exists when an optional tool is installed (the [zsh] columns, the #17 veto's regression test)
# is a counted failure when the tool is absent rather than a silently narrower suite. It is now
# run by hand, or by the Stop hook of a session that wants a Linux answer, instead of by a
# hosted runner on every push.
#
# What it does, and why each line is there:
#   - The image is PINNED to a tag, never :latest, because a moving base is a gate that breaks
#     on someone else's package and gets disabled the first time it does. node:22-bookworm
#     ships bash, git and node; zsh and jq are the two distro packages the suite also wants.
#   - The repo is mounted at ITS OWN absolute path, not /repo, and so is the git common dir when
#     the checkout is a worktree. A worktree's `.git` is a FILE holding an absolute `gitdir:`
#     pointer into the main repo's .git/worktrees/<name>; mounted anywhere else, git reports
#     "not a git repository" and every suite that materializes the tree (git archive) or clones
#     it (the fresh-checkout run) measures nothing. Mounting at the same path makes the pointer
#     resolve unchanged.
#   - safe.directory '*': the mount is owned by the host user and the container runs as root,
#     which git refuses to touch by default.
#   - No npm install and no dependencies, the same constraint manifests.yml keeps.
#   - PIPELINE_TESTS_REQUIRE_CAPABILITIES=1 is set HERE and only here (see optional_tool in
#     harness.sh): a developer's laptop may lack zsh, the Linux answer may not.
set -euo pipefail

IMAGE="${PIPELINE_TESTS_IMAGE:-node:22-bookworm}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd -P)"
COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"

if ! command -v docker >/dev/null 2>&1; then
  echo "run-linux.sh: docker is not on PATH; nothing was run" >&2
  exit 91
fi

MOUNTS=(-v "$REPO_ROOT:$REPO_ROOT")
# A worktree's common dir lives outside the checkout; a plain repo's is $REPO_ROOT/.git, already
# inside the first mount, and mounting it twice would shadow it.
if [[ -n "$COMMON_DIR" && "$COMMON_DIR" != "$REPO_ROOT/.git" ]]; then
  MOUNTS+=(-v "$COMMON_DIR:$COMMON_DIR:ro")
fi

# Inside the container: install the two distro packages, then either the whole suite through
# run.sh (the same command the workflow ran) or the named suites one by one, exit non-zero if
# any of them did. Arguments pass through as suite file names under tests/.
INNER='
set -uo pipefail
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq zsh jq >/dev/null 2>&1 \
  || { echo "run-linux.sh: apt-get failed inside the container" >&2; exit 92; }
git config --global --add safe.directory "*"
echo "run-linux.sh: $(uname -srm) | $(bash --version | head -1) | node $(node -v) | zsh $(zsh --version) | git $(git --version)"
if [[ $# -eq 0 ]]; then
  exec bash plugins/pipeline/tests/run.sh
fi
rc=0
for t in "$@"; do
  echo "== $t =="
  bash "plugins/pipeline/tests/$t" || rc=1
done
exit $rc
'
exec docker run --rm "${MOUNTS[@]}" -w "$REPO_ROOT" \
  -e PIPELINE_TESTS_REQUIRE_CAPABILITIES=1 \
  "$IMAGE" bash -c "$INNER" run-linux "$@"
