#!/bin/bash

# Startup script for Dovecot container

echo "Starting Dovecot..."

# Ensure mail directory exists and has proper permissions
mkdir -p /mail/v1
chown -R vmail:vmail /mail

# Ensure users file exists
touch /etc/dovecot/users
chown vmail:vmail /etc/dovecot/users
chmod 600 /etc/dovecot/users

# Create sieve directory if it doesn't exist
mkdir -p /var/lib/dovecot/sieve
chown -R vmail:vmail /var/lib/dovecot

# Test configuration
echo "Testing Dovecot configuration..."
dovecot -c /etc/dovecot/dovecot.conf -n

if [ $? -eq 0 ]; then
    echo "Configuration is valid. Starting Dovecot..."
    exec dovecot -F
else
    echo "Configuration error. Exiting."
    exit 1
fi 