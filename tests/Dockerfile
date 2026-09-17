# The test image run-linux.sh builds locally (#162). Nothing is pushed to a registry.
#
# The base is a PINNED tag, never :latest (run-linux.sh passes BASE_IMAGE, and its header says
# why). zsh and jq are baked in here so a run no longer spends its first minute on apt-get, and so
# every run gets the same package set until this file changes: run-linux.sh tags the image with a
# checksum of this file, and a changed file builds a new image rather than reusing a stale one.
ARG BASE_IMAGE=node:22-bookworm
FROM ${BASE_IMAGE}
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends zsh jq \
 && rm -rf /var/lib/apt/lists/*
