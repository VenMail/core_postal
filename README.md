## VenMail Core*

VenMail core provides the core system or service for email routing and is primarily powered by Postal

## Development

To get started with development, copy the sample config files in `docker/ci-config` to `config/postal` and then run `bundle install`.

### Preparing the shared Maildir volume

The Postal and Dovecot containers expect a writable Maildir volume that is shared between both services. Before building images or starting the stack on a new machine, run the admin-only helper script:

```powershell
pwsh ./script/prepare_maildir.ps1
```

The script ensures the host `mail/` directory exists, creates the standard `new`, `cur`, and `tmp` folders, grants the local Users group modify permissions, and exports `POSTAL_MAILDIR_PATH` for the current session. You can override defaults using parameters, for example:

```powershell
pwsh ./script/prepare_maildir.ps1 -MailRoot "C:/PostalMail" -MailVersion "v2"
```

These settings align with the configurable `MAIL_ROOT`/`MAIL_VERSION` build arguments used in both the Postal and Dovecot Dockerfiles.

To create mailbox users inside the Dovecot container, use the helper script:

```bash
docker compose exec dovecot ./add_user.sh user@example.com supersecret
```

The script mirrors the same maildir layout (domain/user) and respects the `MAIL_ROOT`, `MAIL_VERSION`, `VMAIL_UID`, and `VMAIL_GID` environment variables so Postal and Dovecot stay in sync.

Private containers are built and published via Github/ghcr.io