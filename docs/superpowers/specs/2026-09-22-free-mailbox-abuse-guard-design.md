# Free Mailbox Abuse Guard Design

## Goal

Prevent a shared free-domain mailbox from submitting or delivering bulk mail
outside the existing Venmail review path, and deactivate that mailbox promptly
when transport failures demonstrate abuse.

## Evidence

On production server 61, `venia.cloud` had neither a server `send_limit` nor a
domain `daily_send_limit`. Postal's send limit is a rolling 60-second server
counter; no per-mailbox rate limit existed. Password-authenticated mailbox SMTP
messages have no Postal `credential_id`, so `ReputationMonitorJob` skipped them.
It also counted only `Bounced`, not outbound `HardFail` records. Employee and
mail-user quota fields govern storage and do not govern SMTP recipients.

## Decision

Use Postal as the enforcement point for password-authenticated mailbox SMTP.

1. Persist the authenticated mailbox address on every outgoing SMTP message.
2. Before persistence, atomically reserve the recipient count in the Core main
   database. Enforce 60 recipients/minute across each configured shared free
   domain and enforce the app's existing free-account limits per mailbox:
   three recipients/message, five submissions/hour, and ten recipients/day.
3. Reject a submission that cannot reserve capacity, before a message is queued
   or delivered. The SMTP response identifies the applicable temporary rate or
   account limit without exposing internal rules.
4. On outbound `HardFail`, atomically count failures for the stored mailbox in
   a 24-hour window. At 100 failures, deactivate that exact `mail_users` row,
   emit a `MailboxLocked` webhook, and retain evidence.
5. Immediately before transport delivery, hold queued mail whose recorded
   authenticated mailbox has been deactivated. This protects queued rows after
   the failure threshold crosses.

## Scope and non-goals

This guard applies only to configured shared free domains, initially
`venia.cloud`. Custom-domain customers and API/Postal credentials retain their
existing controls. The database-backed guard is safe across SMTP processes and
does not rely on process-local memory.

This is the emergency enforcement layer. The separate immutable
Postal-to-Venmail admin/Telegram approval protocol remains required before
outbound SMTP egress is restored globally. This work does not reopen the host
SMTP firewall guard.

## Rollout

Run Core migration and image rollout through CI. Validate the migration, SMTP
admission tests, hard-failure deactivation test, and queued-delivery hold test.
Keep egress blocked until the deployed image, migration, and review path have
been independently verified.
