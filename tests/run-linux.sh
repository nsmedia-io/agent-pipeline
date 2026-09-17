#!/usr/bin/env bash
# The suite on Linux, in a container, on demand.
#
#   bash tests/run-linux.sh                        # the whole suite (run.sh), routine mode
#   PIPELINE_TESTS_FULL=1 bash tests/run-linux.sh  # full mode, which a release is cut on
#   bash tests/run-linux.sh test-a.sh ...          # named suites only
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
#   - The base image is PINNED to a tag, never :latest, because a moving base is a gate that
#     breaks on someone else's package and gets disabled the first time it does. node:22-bookworm
#     ships bash, git and node; zsh and jq are the two distro packages the suite also wants.
#   - THE TEST IMAGE (#162). tests/Dockerfile bakes zsh and jq into that base, built locally and
#     tagged with the Dockerfile's checksum, so a run no longer reinstalls them and a changed
#     Dockerfile cannot reuse a stale image. Nothing is pushed anywhere. PIPELINE_TESTS_IMAGE
#     names a different image instead (no build); the container still installs zsh and jq when
#     that image lacks them, so an override cannot shrink the population.
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
#   - PIPELINE_TESTS_FULL and PIPELINE_TESTS_JOBS pass through to run.sh unchanged.
set -euo pipefail

BASE_IMAGE="node:22-bookworm"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/.." && pwd -P)"
COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
GIT_DIR_ABS="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"

if ! command -v docker >/dev/null 2>&1; then
  echo "run-linux.sh: docker is not on PATH; nothing was run" >&2
  exit 91
fi

if [[ -n "${PIPELINE_TESTS_IMAGE:-}" ]]; then
  IMAGE="$PIPELINE_TESTS_IMAGE"
else
  IMAGE="agent-pipeline-tests:$(cksum < "$HERE/Dockerfile" | cut -d' ' -f1)"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "run-linux.sh: building $IMAGE from tests/Dockerfile on $BASE_IMAGE" >&2
    docker build -q -t "$IMAGE" --build-arg "BASE_IMAGE=$BASE_IMAGE" - < "$HERE/Dockerfile" >/dev/null \
      || { echo "run-linux.sh: docker build failed; nothing was run" >&2; exit 93; }
  fi
fi

# ON WINDOWS (Git Bash), git prints drive paths (C:/Users/...) and Docker's -v cannot parse a
# drive path on BOTH sides of the colon ("too many colons"). The container side is therefore the
# POSIX spelling bash already uses (/c/Users/...), the host side the drive spelling (cygpath -m),
# and MSYS path conversion is switched off for the docker call so neither is rewritten. A
# worktree's `.git` FILE still holds a drive-path `gitdir:` pointer no Linux git can follow, so a
# one-line replacement pointing at the POSIX spelling of the same gitdir is mounted over it,
# read-only. The host file is never edited. The worktree's `commondir` is relative, so git reaches
# the mounted common dir through it unchanged.
HOSTPATH() { printf '%s' "$1"; }
POINTER_DIR=""
if [[ "$(uname -s 2>/dev/null)" == MINGW* || "$(uname -s 2>/dev/null)" == MSYS* ]] && command -v cygpath >/dev/null 2>&1; then
  export MSYS_NO_PATHCONV=1
  HOSTPATH() { cygpath -m "$1"; }
  [[ -n "$COMMON_DIR" ]] && COMMON_DIR="$(cygpath -u "$COMMON_DIR")"
fi
trap '[[ -n "$POINTER_DIR" && -d "$POINTER_DIR" ]] && rm -r "$POINTER_DIR"' EXIT

MOUNTS=(-v "$REPO_ROOT:$REPO_ROOT")
[[ "$(HOSTPATH /)" == "/" ]] || MOUNTS=(-v "$(HOSTPATH "$REPO_ROOT"):$REPO_ROOT")
# A worktree's common dir lives outside the checkout; a plain repo's is $REPO_ROOT/.git, already
# inside the first mount, and mounting it twice would shadow it.
if [[ -n "$COMMON_DIR" && "$COMMON_DIR" != "$REPO_ROOT/.git" ]]; then
  MOUNTS+=(-v "$(HOSTPATH "$COMMON_DIR"):$COMMON_DIR:ro")
  if [[ -f "$REPO_ROOT/.git" && -n "$GIT_DIR_ABS" && "$(HOSTPATH /)" != "/" ]]; then
    POINTER_DIR="$(mktemp -d)"
    printf 'gitdir: %s\n' "$(cygpath -u "$GIT_DIR_ABS")" > "$POINTER_DIR/git"
    MOUNTS+=(-v "$(HOSTPATH "$POINTER_DIR/git"):$REPO_ROOT/.git:ro")
  fi
fi

# Inside the container: install the two distro packages only if the image lacks them (the built
# test image has both), then either the whole suite through run.sh (the same command the workflow
# ran) or the named suites one by one, exit non-zero if any of them did. Arguments pass through as
# suite file names under tests/.
INNER='
set -uo pipefail
if ! command -v zsh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq zsh jq >/dev/null 2>&1 \
    || { echo "run-linux.sh: apt-get failed inside the container" >&2; exit 92; }
fi
git config --global --add safe.directory "*"
echo "run-linux.sh: $(uname -srm) | $(bash --version | head -1) | node $(node -v) | zsh $(zsh --version) | git $(git --version)"
if [[ $# -eq 0 ]]; then
  exec bash tests/run.sh
fi
rc=0
for t in "$@"; do
  echo "== $t =="
  bash "tests/$t" || rc=1
done
exit $rc
'
docker run --rm "${MOUNTS[@]}" -w "$REPO_ROOT" \
  -e PIPELINE_TESTS_REQUIRE_CAPABILITIES=1 \
  -e "PIPELINE_TESTS_FULL=${PIPELINE_TESTS_FULL:-}" \
  -e "PIPELINE_TESTS_JOBS=${PIPELINE_TESTS_JOBS:-}" \
  "$IMAGE" bash -c "$INNER" run-linux "$@"
