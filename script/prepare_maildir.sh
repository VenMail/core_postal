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
      [ -n "${2:-}" ] || { echo "Missing value for $1" >&2; exit 1; }
      HOST_MAIL_ROOT="$2"
      shift 2
      ;;
    -v|--mail-version)
      [ -n "${2:-}" ] || { echo "Missing value for $1" >&2; exit 1; }
      MAIL_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root (or via sudo)." >&2
  exit 1
fi

[ -z "${MAIL_ROOT:-}" ] || HOST_MAIL_ROOT="$MAIL_ROOT"
HOST_MAIL_ROOT=$(to_absolute "$HOST_MAIL_ROOT")
BASE_ROOT="${HOST_MAIL_ROOT%/}"

MAIL_VERSION=${MAIL_VERSION%/}
MAILDIR_ROOT="$BASE_ROOT"
if [ -n "$MAIL_VERSION" ]; then
  case "$MAILDIR_ROOT" in
    */"$MAIL_VERSION") : ;; # already suffixed
    *) MAILDIR_ROOT="$MAILDIR_ROOT/$MAIL_VERSION" ;;
  esac
fi

ensure_dir() {
  dir=$1
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    echo "ERROR: $dir exists but is not a directory" >&2
    exit 1
  fi

  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    echo "Created directory $dir"
  fi

  current_perm=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir")
  if [ "$current_perm" != "770" ]; then
    chmod 0770 "$dir"
    echo "Adjusted permissions on $dir to 0770"
  fi

  chown "$POSTAL_UID:$VMAIL_GID" "$dir"
  echo "Set ownership of $dir to ${POSTAL_UID}:${VMAIL_GID}"
}

ensure_dir "$BASE_ROOT"
ensure_dir "$MAILDIR_ROOT"
for subdir in new cur tmp; do
  ensure_dir "$MAILDIR_ROOT/$subdir"
done

cat <<INFO
Prepared Maildir structure at: $MAILDIR_ROOT
Host directory mounted into containers should be: $BASE_ROOT
Ownership set to UID:GID ${POSTAL_UID}:${VMAIL_GID} with permissions 0770.
INFO
