#!/bin/bash

# Script to add users to Dovecot
# Usage: ./add_user.sh <email> <password> [domain]

if [ $# -lt 2 ]; then
    echo "Usage: $0 <email> <password> [domain]"
    echo "Example: $0 user@example.com mypassword"
    exit 1
fi

EMAIL=$1
PASSWORD=$2
DOMAIN=${3:-$(echo $EMAIL | cut -d@ -f2)}
USERNAME=$(echo $EMAIL | cut -d@ -f1)

# Generate SHA512-CRYPT hash
HASH=$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")

# Create user entry
USER_ENTRY="$EMAIL:$HASH:5000:5000::/mail/v1/$DOMAIN/$USERNAME:/bin/false"

# Add to users file
echo "$USER_ENTRY" >> /etc/dovecot/users

# Create maildir structure
mkdir -p "/mail/v1/$DOMAIN/$USERNAME/"{new,cur,tmp}
chown -R 5000:5000 "/mail/v1/$DOMAIN/$USERNAME"

echo "User $EMAIL added successfully"
echo "Maildir created at /mail/v1/$DOMAIN/$USERNAME" 