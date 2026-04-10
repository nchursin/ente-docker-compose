#!/bin/bash
#
# Ente Photos Backup Script
#
# Exports decrypted photos from Ente to a local folder.
# Photos in Garage S3 are encrypted client-side, so we need the Ente CLI
# to decrypt them using your account credentials.
#
# First run:  ./backup.sh login    — interactive login (do this once)
# After that: ./backup.sh          — export all photos (can be cron'd)
#             ./backup.sh db       — dump postgres only
#             ./backup.sh all      — export photos + dump postgres
#
# If export fails with "disk quota exceeded", clean the CLI temp dir:
#   rm -rf /tmp/ente-download/
#

set -e
cd "$(dirname "$0")"

BACKUP_ROOT="${ENTE_BACKUP_DIR:-./backups}"
PHOTO_DIR="$BACKUP_ROOT/photos"
DB_DIR="$BACKUP_ROOT/db"
CLI_DIR="$BACKUP_ROOT/.cli"
CLI_BIN="$CLI_DIR/ente"
CLI_VERSION="v0.2.3"
CLI_CONFIG="$CLI_DIR/config"

# Auto-detect endpoint from compose.yml
ENDPOINT="${ENTE_ENDPOINT:-}"
if [ -z "$ENDPOINT" ] && [ -f compose.yml ]; then
  ENDPOINT=$(grep 'ENDPOINT:' compose.yml | head -1 | awk '{print $2}')
fi
if [ -z "$ENDPOINT" ]; then
  echo "ERROR: Cannot detect server endpoint. Set ENTE_ENDPOINT or run setup.sh first."
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────

ensure_dirs() {
  mkdir -p "$PHOTO_DIR" "$DB_DIR" "$CLI_DIR" "$CLI_CONFIG"
}

ensure_cli() {
  if [ -x "$CLI_BIN" ]; then
    return
  fi
  echo "Downloading Ente CLI ${CLI_VERSION}..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  ARCH_SUFFIX="amd64" ;;
    aarch64) ARCH_SUFFIX="arm64" ;;
    arm64)   ARCH_SUFFIX="arm64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
  esac
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  TAR_NAME="ente-cli-${CLI_VERSION}-${OS}-${ARCH_SUFFIX}.tar.gz"
  URL="https://github.com/ente-io/ente/releases/download/cli-${CLI_VERSION}/${TAR_NAME}"
  curl -fsSL "$URL" | tar xz -C "$CLI_DIR"
  chmod +x "$CLI_BIN"
  echo "Ente CLI installed at $CLI_BIN"
}

ensure_config() {
  cat > "$CLI_CONFIG/config.yaml" << YAML
endpoint:
  api: $ENDPOINT
log:
  http: false
YAML
}

run_cli() {
  ENTE_CLI_CONFIG_DIR="$CLI_CONFIG" \
  ENTE_CLI_SECRETS_PATH="$CLI_CONFIG/secrets.txt" \
  "$CLI_BIN" "$@"
}

# ── Commands ─────────────────────────────────────────────────────────

do_login() {
  echo "=== Ente CLI Login ==="
  echo ""
  echo "This will interactively log in to your Ente account."
  echo "Credentials are stored in $CLI_CONFIG"
  echo "You only need to do this once (unless you change your password)."
  echo ""
  ensure_dirs
  ensure_cli
  ensure_config
  run_cli account add
  echo ""
  echo "Setting export directory..."
  run_cli account update --dir "$PHOTO_DIR"
  echo ""
  echo "Login complete. You can now run: ./backup.sh"
}

do_export() {
  echo "=== Exporting Photos ==="
  echo "Destination: $PHOTO_DIR"
  echo ""
  ensure_dirs
  ensure_cli
  ensure_config
  run_cli export
  echo ""
  PHOTO_COUNT=$(find "$PHOTO_DIR" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.heic" -o -name "*.mp4" -o -name "*.mov" \) 2>/dev/null | wc -l)
  echo "Export complete. ~$PHOTO_COUNT media files in $PHOTO_DIR"
}

do_db() {
  echo "=== Dumping Postgres ==="
  ensure_dirs
  DUMP_FILE="$DB_DIR/ente_$(date +%Y%m%d_%H%M%S).sql.gz"
  docker compose exec -T postgres pg_dump -U pguser ente_db | gzip > "$DUMP_FILE"
  DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
  echo "Database dump: $DUMP_FILE ($DUMP_SIZE)"

  # Keep only last 7 dumps
  ls -t "$DB_DIR"/ente_*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm --
  REMAINING=$(ls "$DB_DIR"/ente_*.sql.gz 2>/dev/null | wc -l)
  echo "Retained $REMAINING database dumps (keeping last 7)."
}

do_all() {
  do_export
  echo ""
  do_db
}

# ── Main ─────────────────────────────────────────────────────────────

case "${1:-export}" in
  login)
    do_login
    ;;
  export)
    do_export
    ;;
  db)
    do_db
    ;;
  all)
    do_all
    ;;
  help|--help|-h)
    echo "Usage: ./backup.sh [command]"
    echo ""
    echo "Commands:"
    echo "  login   — Interactive login to Ente (do this once)"
    echo "  export  — Export decrypted photos (default)"
    echo "  db      — Dump Postgres database"
    echo "  all     — Export photos + dump database"
    echo "  help    — Show this help"
    echo ""
    echo "Photos export to: $PHOTO_DIR"
    echo "DB dumps go to:   $DB_DIR"
    echo ""
    echo "Environment variables:"
    echo "  ENTE_BACKUP_DIR  — Override backup root (default: ./backups)"
    echo "  ENTE_ENDPOINT    — Override server endpoint (auto-detected from compose.yml)"
    ;;
  *)
    echo "Unknown command: $1 (try: login, export, db, all, help)"
    exit 1
    ;;
esac
