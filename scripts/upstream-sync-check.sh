#!/usr/bin/env bash
#
# Cheap check for new upstream commits. Runs before the full sync so that
# no-op runs cost almost nothing.
#
# Writes GitHub Actions step outputs when GITHUB_OUTPUT is set:
#   changed, upstream_sha, marker
#
# Usage:
#   bash scripts/upstream-sync-check.sh
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/CodebuffAI/freebuff.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"

upstream_sha=$(git ls-remote "$UPSTREAM_URL" "$UPSTREAM_BRANCH" | awk '{print $1}')
marker=$(tr -d '[:space:]' < UPSTREAM_SHA 2>/dev/null || true)

if [[ -z "$marker" ]]; then
  echo "::error::UPSTREAM_SHA is missing on main. Bootstrap it and re-run."
  exit 1
fi

changed=false
if [[ "$upstream_sha" == "$marker" ]]; then
  echo "Up to date (marker ${marker:0:8})"
else
  echo "New upstream commits: ${marker:0:8} -> ${upstream_sha:0:8}"
  changed=true
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "changed=${changed}" >> "$GITHUB_OUTPUT"
  echo "upstream_sha=${upstream_sha}" >> "$GITHUB_OUTPUT"
  echo "marker=${marker}" >> "$GITHUB_OUTPUT"
fi
