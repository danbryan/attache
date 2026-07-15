#!/bin/zsh
# INF-331: documentation link checker.
# Verifies internal documentation links resolve from the repository root.

set -eu
cd "$(dirname "$0")/.."

echo "Checking internal documentation links..."
errors=0

for file in docs/*.md; do
  dir=$(dirname "$file")
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    target="$dir/$link"
    if [ ! -e "$target" ]; then
      echo "BROKEN: $file -> $link"
      errors=$((errors + 1))
    fi
  done < <(grep -oE '\]\([^h][^)]*\)' "$file" | sed 's/^](//' | sed 's/)$//')
done

if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors broken link(s)."
  exit 1
fi
echo "PASS: all internal links resolve."