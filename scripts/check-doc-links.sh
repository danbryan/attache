#!/bin/zsh
# INF-331: documentation link checker.
# Verifies internal documentation links resolve from the repository root.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "Checking internal documentation links..."
errors=0

files=(README.md CONTRIBUTING.md)
while IFS= read -r file; do
  files+=("$file")
done < <(rg --files docs | grep -E '\.md$' | sort)

check_link() {
  local file="$1"
  local link="$2"
  local dir target

  link="${link#<}"
  link="${link%>}"
  link="${link%%[[:space:]]\"*}"
  case "$link" in
    ""|\#*|http://*|https://*|mailto:*|tel:* ) return ;;
  esac

  link="${link%%\#*}"
  link="${link%%\?*}"
  [ -z "$link" ] && return
  dir="$(dirname "$file")"
  if [[ "$link" == /* ]]; then
    target=".${link}"
  else
    target="$dir/$link"
  fi
  if [ ! -e "$target" ]; then
    echo "BROKEN: $file -> $link"
    errors=$((errors + 1))
  fi
}

for file in "${files[@]}"; do
  [ -f "$file" ] || continue
  dir=$(dirname "$file")
  while IFS= read -r link; do
    check_link "$file" "$link"
  done < <(grep -oE '\]\([^)]*\)' "$file" | sed 's/^](//' | sed 's/)$//' || true)
  while IFS= read -r link; do
    check_link "$file" "$link"
  done < <(grep -oE '^\[[^]]+\]:[[:space:]]+[^[:space:]]+' "$file" | sed -E 's/^\[[^]]+\]:[[:space:]]+//' || true)
done

if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors broken link(s)."
  exit 1
fi
echo "PASS: all internal links resolve across README, CONTRIBUTING, and docs."
