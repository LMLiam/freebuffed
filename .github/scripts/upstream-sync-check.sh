#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/CodebuffAI/freebuff.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"

upstream_sha=$(git ls-remote "$UPSTREAM_URL" "refs/heads/$UPSTREAM_BRANCH" | awk 'NR==1{print $1}')
if [[ -z "$upstream_sha" ]]; then
  echo "::error::$UPSTREAM_BRANCH not found at $UPSTREAM_URL." >&2
  exit 1
fi
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
  {
    echo "changed=${changed}"
    echo "upstream_sha=${upstream_sha}"
    echo "marker=${marker}"
  } >> "$GITHUB_OUTPUT"
fi
