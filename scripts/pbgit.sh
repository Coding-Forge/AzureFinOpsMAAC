#!/usr/bin/env bash
# Local-only git wrapper for the powerbi/ working tree.
#
# powerbi/ is developed with full git history, but its .git directory lives
# OUTSIDE this repo (~/.local/share/git-repos/AzureFinOpsMAAC-powerbi.git) so
# it can never be picked up as an embedded repo/gitlink by the outer repo's
# `git add`, and it has no remote configured, so it can never be pushed.
#
# Usage (from anywhere): scripts/pbgit.sh status
#                         scripts/pbgit.sh add -A
#                         scripts/pbgit.sh commit -m "message"
#                         scripts/pbgit.sh log --oneline
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_DIR="$HOME/.local/share/git-repos/AzureFinOpsMAAC-powerbi.git"
GIT_WORK_TREE="$REPO_ROOT/powerbi"

if [ ! -d "$GIT_DIR" ]; then
  echo "error: $GIT_DIR not found. Has the local powerbi git repo been set up?" >&2
  exit 1
fi

exec git --git-dir="$GIT_DIR" --work-tree="$GIT_WORK_TREE" "$@"
