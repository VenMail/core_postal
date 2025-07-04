# Dovecot IMAP/POP3 Service

This directory contains the configuration for Dovecot, which provides IMAP and POP3 access to emails stored in Maildir format by Postal.

## Directory Structure

The Maildir structure follows the pattern used by Postal's MaildirSender:
```
/mail/v1/{domain}/{username}/
├── new/     # New messages
├── cur/     # Current messages (read)
└── tmp/     # Temporary files
```

## Configuration Files

- `10-mail.conf` - Mail location and namespace configuration
- `10-auth.conf` - Authentication settings
- `10-master.conf` - Service configuration (IMAP/POP3 ports)
- `10-ssl.conf` - SSL/TLS configuration
- `15-lda.conf` - Local Delivery Agent settings
- `20-imap.conf` - IMAP protocol settings
- `20-pop3.conf` - POP3 protocol settings
- `90-quota.conf` - Quota management
- `90-sieve.conf` - Email filtering (Sieve)

## Ports

- `143` - IMAP (non-SSL)
- `993` - IMAPS (SSL)
- `110` - POP3 (non-SSL)
- `995` - POP3S (SSL)

## User Management

### Adding Users

1. **Using the script (recommended):**
   ```bash
   # From the docker/dovecot directory
   docker exec -it <dovecot_container> /bin/bash
   ./add_user.sh user@example.com password
   ```

2. **Manually:**
   - Edit the `users` file
   - Generate password hash: `doveadm pw -s SHA512-CRYPT -p "password"`
   - Add entry: `user@example.com:{SHA512-CRYPT}$6$...:5000:5000::/mail/v1/example.com/user:/bin/false`

### User File Format

```
email:password_hash:uid:gid:gecos:home:shell
```

## SSL Certificates

The Dockerfile creates a self-signed certificate for development. For production:

1. Replace `/etc/ssl/certs/dovecot.crt` with your certificate
2. Replace `/etc/ssl/private/dovecot.key` with your private key
3. Update `10-ssl.conf` if needed

## Client Configuration

### IMAP Settings
- Server: `localhost` (or your domain)
- Port: `143` (non-SSL) or `993` (SSL)
- Username: Full email address
- Password: User password
- Security: STARTTLS (port 143) or SSL/TLS (port 993)

### POP3 Settings
- Server: `localhost` (or your domain)
- Port: `110` (non-SSL) or `995` (SSL)
- Username: Full email address
- Password: User password
- Security: STARTTLS (port 110) or SSL/TLS (port 995)

## Troubleshooting

1. **Check logs:**
   ```bash
   docker logs <dovecot_container>
   ```

2. **Test authentication:**
   ```bash
   docker exec -it <dovecot_container> doveadm auth test user@example.com
   ```

3. **Verify maildir structure:**
   ```bash
   docker exec -it <dovecot_container> ls -la /mail/v1/example.com/user/
   ```

## Security Notes

- For production, use proper SSL certificates
- Consider implementing database authentication instead of file-based
- Regularly update Dovecot and monitor security advisories
- Use strong passwords and consider implementing rate limiting 