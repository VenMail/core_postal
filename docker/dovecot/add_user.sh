#!/bin/sh

# Script to add users to Dovecot
# Usage: ./add_user.sh <email> <password> [domain]
# Honors MAIL_ROOT, MAIL_VERSION, VMAIL_UID, and VMAIL_GID env vars.

set -eu

MAIL_ROOT="${MAIL_ROOT:-/mail}"
MAIL_VERSION="${MAIL_VERSION:-v1}"
VMAIL_UID="${VMAIL_UID:-5000}"
VMAIL_GID="${VMAIL_GID:-5000}"
MAILDIR_ROOT="${MAIL_ROOT%/}/${MAIL_VERSION}"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <email> <password> [domain]"
    echo "Example: $0 user@example.com mypassword"
    exit 1
fi

EMAIL=$1
PASSWORD=$2
DOMAIN=${3:-${EMAIL#*@}}
USERNAME=${EMAIL%%@*}

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "$EMAIL" ]; then
    echo "Could not determine domain from email" >&2
    exit 1
fi

if ! command -v doveadm >/dev/null 2>&1; then
    echo "doveadm command not found. Ensure Dovecot is installed." >&2
    exit 1
fi

# Generate SHA512-CRYPT hash
HASH=$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")

# Create user entry
USER_HOME="$MAILDIR_ROOT/$DOMAIN/$USERNAME"
USER_ENTRY="$EMAIL:$HASH:$VMAIL_UID:$VMAIL_GID::$USER_HOME:/bin/false"

# Add to users file
echo "$USER_ENTRY" >> /etc/dovecot/users

# Create maildir structure
mkdir -p "$USER_HOME"/new "$USER_HOME"/cur "$USER_HOME"/tmp
chown -R "$VMAIL_UID:$VMAIL_GID" "$MAILDIR_ROOT/$DOMAIN"
chmod -R 0770 "$MAILDIR_ROOT/$DOMAIN"

echo "User $EMAIL added successfully"
echo "Maildir created at $USER_HOME"