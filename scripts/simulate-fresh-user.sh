#!/usr/bin/env bash
set -euo pipefail

# Backups under this script contain exported API keys. Keep everything the
# script creates readable by the owner only.
umask 077

APP_NAME="Attache"
BUNDLE_ID="com.bryanlabs.attache"
SUPPORT_DIR="$HOME/Library/Application Support/Attache"
BACKUP_ROOT="$HOME/Library/Application Support/Attache Backups"
KEYCHAIN_BACKUP_FILE="keychain-secrets.tsv"
DEFAULTS_BACKUP_FILE="defaults.plist"

SECRET_SERVICE="com.bryanlabs.attache.secrets"
LEGACY_PRESENTATION_SERVICE="com.bryanlabs.attache.presentation"
SECRET_ACCOUNTS=(
  "xai-api-key"
  "elevenlabs-api-key"
  "openai-api-key"
  "groq-api-key"
  "custom-api-key"
  "presentationLLMAPIKey"
)

usage() {
  cat <<EOF
Usage:
  scripts/simulate-fresh-user.sh fresh
  scripts/simulate-fresh-user.sh restore <backup-dir>

The fresh command backs up Attaché's local app support directory, UserDefaults,
and known Attaché Keychain API-key accounts, then removes them so the next app
launch behaves like a first run.
EOF
}

quit_app() {
  osascript -e 'tell application "Attache" to quit' >/dev/null 2>&1 || true
  sleep 1
}

# Set while the keychain TSV is being written; the EXIT trap removes a
# partially written file so a failed run never leaves a truncated secrets
# backup behind. Keychain entries are only deleted after the full TSV is
# written, so removing a partial file loses nothing.
KEYCHAIN_TSV_IN_PROGRESS=""

cleanup_partial_keychain_backup() {
  if [[ -n "$KEYCHAIN_TSV_IN_PROGRESS" ]]; then
    rm -f "$KEYCHAIN_TSV_IN_PROGRESS"
  fi
}
trap cleanup_partial_keychain_backup EXIT

backup_keychain_secret() {
  local service="$1"
  local account="$2"
  local out_file="$3"
  local secret

  if secret="$(security find-generic-password -s "$service" -a "$account" -w 2>/dev/null)"; then
    printf '%s\t%s\t%s\n' "$service" "$account" "$(printf '%s' "$secret" | base64 | tr -d '\n')" >> "$out_file"
  fi
}

delete_keychain_secret() {
  local service="$1"
  local account="$2"
  security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1 || true
}

fresh() {
  quit_app

  local stamp backup_dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$BACKUP_ROOT/fresh-user-$stamp"
  mkdir -p "$backup_dir"
  # Backups hold exported API keys; lock the tree down even if the root was
  # created by an older run under a permissive umask.
  chmod 700 "$BACKUP_ROOT" "$backup_dir"

  if [[ -d "$SUPPORT_DIR" ]]; then
    mv "$SUPPORT_DIR" "$backup_dir/Attache"
  fi

  if defaults export "$BUNDLE_ID" "$backup_dir/$DEFAULTS_BACKUP_FILE" >/dev/null 2>&1; then
    chmod 600 "$backup_dir/$DEFAULTS_BACKUP_FILE"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  else
    printf 'No UserDefaults domain found for %s.\n' "$BUNDLE_ID" > "$backup_dir/defaults-not-found.txt"
  fi

  local keychain_tsv="$backup_dir/$KEYCHAIN_BACKUP_FILE"
  KEYCHAIN_TSV_IN_PROGRESS="$keychain_tsv"
  : > "$keychain_tsv"
  chmod 600 "$keychain_tsv"
  for account in "${SECRET_ACCOUNTS[@]}"; do
    backup_keychain_secret "$SECRET_SERVICE" "$account" "$keychain_tsv"
  done
  backup_keychain_secret "$LEGACY_PRESENTATION_SERVICE" "presentationLLMAPIKey" "$keychain_tsv"
  KEYCHAIN_TSV_IN_PROGRESS=""

  # The TSV is complete; only now remove the entries from the Keychain.
  for account in "${SECRET_ACCOUNTS[@]}"; do
    delete_keychain_secret "$SECRET_SERVICE" "$account"
  done
  delete_keychain_secret "$LEGACY_PRESENTATION_SERVICE" "presentationLLMAPIKey"

  mkdir -p "$SUPPORT_DIR"

  cat > "$backup_dir/README.txt" <<EOF
Attaché fresh-user simulation backup

Created: $stamp

Restore with:
  scripts/simulate-fresh-user.sh restore "$backup_dir"
EOF

  echo "Fresh-user state is active."
  echo "Backup: $backup_dir"
  if [[ -s "$keychain_tsv" ]]; then
    echo "WARNING: this backup contains exported API keys (base64, not encrypted):" >&2
    echo "  $keychain_tsv" >&2
    echo "  Running the restore subcommand puts them back in the Keychain and deletes this file." >&2
  fi
  echo "Launch Attaché now to inspect the first-run experience."
}

restore_keychain_secrets() {
  local file="$1"
  [[ -s "$file" ]] || return 0

  while IFS=$'\t' read -r service account encoded; do
    [[ -n "${service:-}" && -n "${account:-}" && -n "${encoded:-}" ]] || continue
    local secret
    secret="$(printf '%s' "$encoded" | base64 --decode)"
    security add-generic-password -U -s "$service" -a "$account" -w "$secret" >/dev/null
  done < "$file"
}

restore() {
  local backup_dir="${1:-}"
  if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
    echo "error: restore requires an existing backup directory." >&2
    usage >&2
    exit 1
  fi

  quit_app

  rm -rf "$SUPPORT_DIR"
  if [[ -d "$backup_dir/Attache" ]]; then
    mv "$backup_dir/Attache" "$SUPPORT_DIR"
  fi

  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -f "$backup_dir/$DEFAULTS_BACKUP_FILE" ]]; then
    defaults import "$BUNDLE_ID" "$backup_dir/$DEFAULTS_BACKUP_FILE"
  fi

  restore_keychain_secrets "$backup_dir/$KEYCHAIN_BACKUP_FILE"
  # The secrets are back in the Keychain; do not leave the exported copy on disk.
  rm -f "$backup_dir/$KEYCHAIN_BACKUP_FILE"

  echo "Attaché state restored from:"
  echo "$backup_dir"
}

case "${1:-}" in
  fresh)
    fresh
    ;;
  restore)
    restore "${2:-}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
