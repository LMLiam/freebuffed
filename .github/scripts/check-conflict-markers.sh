#!/usr/bin/env bash

# Find unresolved conflict markers in files changed between two Git refs.
# This module does not change the caller's shell options when it is sourced.
readonly CONFLICT_MARKER_PATTERN='^(<<<<<<<( |$)|=======( |$)|>>>>>>>( |$))'

# Write changed paths to a NUL-delimited file.
# Arguments: base ref, head ref, and output path.
# Return non-zero when Git cannot read the diff.
write_changed_files() {
  local base_ref="$1"
  local head_ref="$2"
  local output_file="$3"

  if ! git diff --name-only -z --diff-filter=ACMR \
    "$base_ref...$head_ref" > "$output_file"; then
    echo "::error::could not read changed files for $base_ref...$head_ref" >&2
    return 1
  fi
}

# Write changed paths that contain a standard conflict marker.
# Arguments: base ref, head ref, and NUL-delimited output path.
# Return non-zero for a Git error. A clean scan writes an empty file.
write_conflict_marker_files() {
  local base_ref="$1"
  local head_ref="$2"
  local output_file="$3"
  local tmp_dir changed_file file grep_status

  tmp_dir=$(mktemp -d) || return 1
  changed_file="$tmp_dir/changed-files"
  : > "$output_file"
  if ! write_changed_files "$base_ref" "$head_ref" "$changed_file"; then
    rm -rf -- "$tmp_dir"
    return 1
  fi
  while IFS= read -r -d '' file; do
    if git grep -qI -E "$CONFLICT_MARKER_PATTERN" "$head_ref" -- \
      ":(literal)$file" 2>/dev/null; then
      printf '%s\0' "$file" >> "$output_file"
    else
      grep_status=$?
      if [[ "$grep_status" -ne 1 ]]; then
        echo "::error::could not scan changed file for conflict markers" >&2
        rm -rf -- "$tmp_dir"
        return 1
      fi
    fi
  done < "$changed_file"
  rm -rf -- "$tmp_dir"
}

# Run the pull-request conflict-marker check.
# Arguments: base ref and optional head ref. The default head ref is HEAD.
# Output: one clean summary or the marker matches.
# Return 0 for a clean scan, 1 for markers or a scan error, and 2 for usage.
check_conflict_markers() {
  local base_ref="$1"
  local head_ref="${2:-HEAD}"
  local tmp_dir changed_file conflict_file
  local changed_count=0 found="" file hits grep_status

  git rev-parse --verify "$base_ref^{commit}" >/dev/null || return 1
  git rev-parse --verify "$head_ref^{commit}" >/dev/null || return 1

  tmp_dir=$(mktemp -d) || return 1
  changed_file="$tmp_dir/changed-files"
  conflict_file="$tmp_dir/conflict-files"
  if ! write_changed_files "$base_ref" "$head_ref" "$changed_file"; then
    rm -rf -- "$tmp_dir"
    return 1
  fi
  while IFS= read -r -d '' file; do
    changed_count=$((changed_count + 1))
  done < "$changed_file"
  if [[ "$changed_count" -eq 0 ]]; then
    rm -rf -- "$tmp_dir"
    echo "No changed files."
    return 0
  fi

  if ! write_conflict_marker_files "$base_ref" "$head_ref" "$conflict_file"; then
    rm -rf -- "$tmp_dir"
    return 1
  fi
  while IFS= read -r -d '' file; do
    if hits=$(git grep -nI -E "$CONFLICT_MARKER_PATTERN" "$head_ref" -- \
      ":(literal)$file" 2>/dev/null); then
      found+="${hits}"$'\n'
    else
      grep_status=$?
      if [[ "$grep_status" -ne 1 ]]; then
        echo "::error::could not read conflict markers from a changed file" >&2
        rm -rf -- "$tmp_dir"
        return 1
      fi
    fi
  done < "$conflict_file"
  rm -rf -- "$tmp_dir"

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
  set -euo pipefail
  main "$@"
fi
