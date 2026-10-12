#!/usr/bin/env bash
# Print the next chart version using the Chronoflow carry rule:
# 0.1.0 -> 0.1.1, 0.1.9 -> 0.2.0.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: bump-version.sh <major.minor.patch>" >&2
  exit 2
fi

version="$1"
if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Version must be major.minor.patch, got: ${version}" >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

if [ "$patch" -ge 9 ]; then
  minor=$((minor + 1))
  patch=0
else
  patch=$((patch + 1))
fi

printf '%s.%s.%s\n' "$major" "$minor" "$patch"
