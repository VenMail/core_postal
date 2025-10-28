#!/bin/sh
# Prepare shared Maildir directories for the Postal/Dovecot stack on Linux hosts.
# Usage: sudo ./script/prepare_maildir.sh [--mail-path /path/to/mail] [--mail-version v1]
# Environment overrides: MAIL_ROOT, MAIL_VERSION, POSTAL_UID, VMAIL_GID.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
MAIL_ROOT_DEFAULT="$SCRIPT_DIR/mail"
HOST_MAIL_ROOT="$MAIL_ROOT_DEFAULT"
MAIL_VERSION="${MAIL_VERSION:-v1}"
POSTAL_UID="${POSTAL_UID:-999}"
VMAIL_GID="${VMAIL_GID:-5000}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_warn() {
  printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2
}

log_error() {
  printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

usage() {
  cat <<'HELP'
prepare_maildir.sh

Prepare the host Maildir tree that will be mounted into the Postal and Dovecot
containers. Run with sudo (or as root) on Alpine/CentOS/Ubuntu/Debian hosts.

Options:
  -p, --mail-path PATH   Host path that maps to /mail inside the containers.
                         Defaults to <repo>/mail or the MAIL_ROOT env value.
  -v, --mail-version V   Mail version directory (defaults to MAIL_VERSION env value or "v1").
  -h, --help             Show this help message.

Environment overrides:
  MAIL_ROOT, MAIL_VERSION, POSTAL_UID, VMAIL_GID.
HELP
}

to_absolute() {
  path=$1
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    ~*) printf '%s\n' "$HOME/${path#~/}" ;;
    *)  printf '%s/%s\n' "$(pwd)" "$path" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -p|--mail-path)
      [ -n "${2:-}" ] || { log_error "Missing value for $1"; exit 1; }
      HOST_MAIL_ROOT="$2"
      shift 2
      ;;
    -v|--mail-version)
      [ -n "${2:-}" ] || { log_error "Missing value for $1"; exit 1; }
      MAIL_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Validate we're running as root
if [ "$(id -u)" != "0" ]; then
  log_error "This script must be run as root (or via sudo)."
  exit 1
fi

# Validate UID and GID are numeric
if ! printf '%s' "$POSTAL_UID" | grep -qE '^[0-9]+$'; then
  log_error "POSTAL_UID must be numeric, got: $POSTAL_UID"
  exit 1
fi

if ! printf '%s' "$VMAIL_GID" | grep -qE '^[0-9]+$'; then
  log_error "VMAIL_GID must be numeric, got: $VMAIL_GID"
  exit 1
fi

# Resolve mail root path
[ -z "${MAIL_ROOT:-}" ] || HOST_MAIL_ROOT="$MAIL_ROOT"
HOST_MAIL_ROOT=$(to_absolute "$HOST_MAIL_ROOT")
BASE_ROOT="${HOST_MAIL_ROOT%/}"

# Validate path is not a sensitive system directory
case "$BASE_ROOT" in
  /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/usr|/var)
    log_error "Cannot use system directory as mail root: $BASE_ROOT"
    exit 1
    ;;
esac

MAIL_VERSION=${MAIL_VERSION%/}
MAILDIR_ROOT="$BASE_ROOT"
if [ -n "$MAIL_VERSION" ]; then
  case "$MAILDIR_ROOT" in
    */"$MAIL_VERSION") : ;; # already suffixed
    *) MAILDIR_ROOT="$MAILDIR_ROOT/$MAIL_VERSION" ;;
  esac
fi

log_info "Preparing Maildir structure at: $MAILDIR_ROOT"
log_info "UID:GID will be set to ${POSTAL_UID}:${VMAIL_GID}"

ensure_dir() {
  dir=$1
  
  # Check if it exists and is not a directory
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    log_error "$dir exists but is not a directory"
    exit 1
  fi

  # Check if it's a symlink pointing to nowhere
  if [ -L "$dir" ] && [ ! -e "$dir" ]; then
    log_warn "$dir is a broken symlink, removing it"
    rm -f "$dir"
  fi

  # Create directory if it doesn't exist
  if [ ! -d "$dir" ]; then
    if ! mkdir -p "$dir" 2>/dev/null; then
      log_error "Failed to create directory: $dir"
      exit 1
    fi
    log_info "Created directory: $dir"
  else
    log_info "Directory exists: $dir"
  fi

  # Set ownership with error handling
  if ! chown "$POSTAL_UID:$VMAIL_GID" "$dir" 2>/dev/null; then
    log_error "Failed to set ownership on $dir (UID:GID ${POSTAL_UID}:${VMAIL_GID})"
    exit 1
  fi

  # Set permissions: group-writable and setgid
  if ! chmod 2770 "$dir" 2>/dev/null; then
    log_warn "Failed to set permissions on $dir, trying without setgid"
    chmod 0770 "$dir" 2>/dev/null || {
      log_error "Failed to set any permissions on $dir"
      exit 1
    }
  fi

  log_info "Set ownership and permissions on: $dir"
}

# Create base directory structure
ensure_dir "$BASE_ROOT"
ensure_dir "$MAILDIR_ROOT"

# Create standard Maildir subdirectories
for subdir in new cur tmp; do
  ensure_dir "$MAILDIR_ROOT/$subdir"
done

log_info "Base Maildir structure created successfully"

# Recursively repair ownership and permissions on existing content
log_info "Repairing ownership and permissions recursively..."

if command -v find >/dev/null 2>&1; then
  # Use find for more granular control
  if ! chown -R "$POSTAL_UID:$VMAIL_GID" "$MAILDIR_ROOT" 2>/dev/null; then
    log_warn "Some files could not be chowned, continuing anyway"
  fi
  
  # Set directories to 02770 (setgid + rwxrwx---)
  find "$MAILDIR_ROOT" -type d -print0 2>/dev/null | \
    xargs -0 -r chmod 2770 2>/dev/null || \
    log_warn "Some directories could not be set to 2770"
  
  # Set files to 0660 (rw-rw----)
  find "$MAILDIR_ROOT" -type f -print0 2>/dev/null | \
    xargs -0 -r chmod 0660 2>/dev/null || \
    log_warn "Some files could not be set to 0660"
  
  # Set ACLs if available (for better permission inheritance)
  if command -v setfacl >/dev/null 2>&1; then
    log_info "Setting default ACLs for group permissions..."
    setfacl -R -m g::rwx "$MAILDIR_ROOT" 2>/dev/null || \
      log_warn "Failed to set regular ACLs"
    setfacl -R -d -m g::rwx "$MAILDIR_ROOT" 2>/dev/null || \
      log_warn "Failed to set default ACLs"
  fi
else
  # Fallback if find is not available
  log_warn "find command not available, using basic recursive chmod"
  chown -R "$POSTAL_UID:$VMAIL_GID" "$MAILDIR_ROOT" 2>/dev/null || \
    log_warn "Recursive chown had errors"
  chmod -R u+rwX,g+rwX,o-rwx "$MAILDIR_ROOT" 2>/dev/null || \
    log_warn "Recursive chmod had errors"
fi

log_info "Ownership and permissions repaired"

# Verify the setup
verify_setup() {
  log_info "Verifying setup..."
  
  # Check if base directories exist and have correct permissions
  for dir in "$BASE_ROOT" "$MAILDIR_ROOT" "$MAILDIR_ROOT/new" "$MAILDIR_ROOT/cur" "$MAILDIR_ROOT/tmp"; do
    if [ ! -d "$dir" ]; then
      log_error "Directory missing: $dir"
      return 1
    fi
    
    if [ ! -w "$dir" ]; then
      log_warn "Directory not writable by current user: $dir"
    fi
  done
  
  # Test write permission by creating a test file
  test_file="$MAILDIR_ROOT/.prepare_test_$$"
  if touch "$test_file" 2>/dev/null; then
    rm -f "$test_file"
    log_info "Write test successful"
  else
    log_warn "Could not create test file in $MAILDIR_ROOT"
  fi
  
  return 0
}

verify_setup

# Fix permissions inside running containers if Docker is available
compose_cmd=""
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    compose_cmd="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    compose_cmd="docker-compose"
  fi
fi

fix_in_container() {
  svc="$1"
  [ -n "$compose_cmd" ] || return 0
  
  log_info "Checking if $svc container is running..."
  
  # Check if service exists and is running
  if ! $compose_cmd ps --status running "$svc" >/dev/null 2>&1; then
    log_info "Container $svc is not running, skipping in-container fixes"
    return 0
  fi
  
  log_info "Adjusting permissions inside $svc container..."
  
  # Run permission fixes inside container with error handling
  if $compose_cmd exec -u 0 -T "$svc" sh -c '
    set -eu
    MAIL_ROOT="${MAIL_ROOT:-/mail}"
    MAIL_VERSION="${MAIL_VERSION:-v1}"
    TARGET="$MAIL_ROOT"
    SUB="$MAIL_VERSION"
    
    # Create base directory
    [ -d "$TARGET" ] || mkdir -p "$TARGET" || exit 1
    chown -R 999:5000 "$TARGET" 2>/dev/null || echo "Warning: chown failed on $TARGET"
    chmod -R u+rwX,g+rwX,o-rwx "$TARGET" 2>/dev/null || echo "Warning: chmod failed on $TARGET"
    
    # Create versioned directory
    [ -d "$TARGET/$SUB" ] || mkdir -p "$TARGET/$SUB" || exit 1
    chown -R 999:5000 "$TARGET/$SUB" 2>/dev/null || echo "Warning: chown failed on $TARGET/$SUB"
    chmod -R u+rwX,g+rwX,o-rwx "$TARGET/$SUB" 2>/dev/null || echo "Warning: chmod failed on $TARGET/$SUB"
    
    # Create standard Maildir subdirectories
    for subdir in new cur tmp; do
      [ -d "$TARGET/$SUB/$subdir" ] || mkdir -p "$TARGET/$SUB/$subdir"
    done
    
    echo "Container permissions adjusted successfully"
  ' 2>/dev/null; then
    log_info "Successfully adjusted permissions in $svc container"
  else
    log_warn "Failed to adjust permissions in $svc container (may not be critical)"
  fi
}

if [ -n "$compose_cmd" ]; then
  log_info "Docker Compose detected, attempting to fix container permissions..."
  fix_in_container postal
  fix_in_container dovecot
else
  log_info "Docker Compose not available, skipping container fixes"
fi

# Final summary
cat <<INFO

${GREEN}✓ SUCCESS${NC}
===========
Maildir structure prepared at: $MAILDIR_ROOT
Host directory for container mount: $BASE_ROOT
Ownership: UID:GID ${POSTAL_UID}:${VMAIL_GID}
Permissions: 2770 (directories), 0660 (files)

Standard Maildir subdirectories created:
  - $MAILDIR_ROOT/new
  - $MAILDIR_ROOT/cur
  - $MAILDIR_ROOT/tmp

Next steps:
1. Ensure your docker-compose.yml mounts $BASE_ROOT to /mail in containers
2. Verify POSTAL_UID ($POSTAL_UID) and VMAIL_GID ($VMAIL_GID) match container users
3. Start your containers: docker compose up -d
4. Check container logs for any permission issues

INFO
