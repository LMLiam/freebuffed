#!/usr/bin/env bash
set -euo pipefail

readonly CONFLICT_MARKER_PATTERN='^(<<<<<<<( |$)|=======( |$)|>>>>>>>( |$))'

conflict_marker_files() {
  local base_ref="$1"
  local head_ref="$2"
  local file

  while IFS= read -r -d '' file; do
    if git grep -qI -E "$CONFLICT_MARKER_PATTERN" "$head_ref" -- \
      ":(literal)$file" 2>/dev/null; then
      printf '%s\0' "$file"
    fi
  done < <(git diff --name-only -z --diff-filter=ACMR "$base_ref" "$head_ref")
}

check_conflict_markers() {
  local base_ref="$1"
  local head_ref="${2:-HEAD}"
  local changed_count=0
  local found=""
  local file hits

  git rev-parse --verify "$base_ref^{commit}" >/dev/null
  git rev-parse --verify "$head_ref^{commit}" >/dev/null

  while IFS= read -r -d '' file; do
    changed_count=$((changed_count + 1))
  done < <(git diff --name-only -z --diff-filter=ACMR "$base_ref" "$head_ref")

  if [[ "$changed_count" -eq 0 ]]; then
    echo "No changed files."
    return 0
  fi

  while IFS= read -r -d '' file; do
    if hits=$(git grep -nI -E "$CONFLICT_MARKER_PATTERN" "$head_ref" -- \
      ":(literal)$file" 2>/dev/null); then
      found+="${hits}"$'\n'
    fi
  done < <(conflict_marker_files "$base_ref" "$head_ref")

  if [[ -n "$found" ]]; then
    echo "::error::Unresolved conflict markers in changed files:"
    printf '%s' "$found"
    return 1
  fi
  echo "No conflict markers in changed files."
}

main() {
  if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 BASE_REF [HEAD_REF]" >&2
    return 2
  fi
  check_conflict_markers "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
