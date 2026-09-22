# Netcup suspension: reported DHL phishing from Venmail Postal

Status: production contained, durable review gate not deployed. Do not remove the
outbound SMTP egress guard or report the incident as fully remediated until the
Core review/release path has been deployed and verified.

## Verified after Netcup reactivation (2026-09-22)

- SSH, Postal containers, and `m.venmail.io` were reachable again at 15:56 UTC.
  The web endpoint returned HTTP 302. The later unintended 16:20 UTC Docker
  restart during guard-unit setup is recorded below.
- Postal server 61 (`Venia Cloud`, domain 50) holds the reported Message-ID as
  message 261274, outgoing from `shipmail@venia.cloud` to `vandam@gbg.bg`,
  created at 03:50:38 UTC on September 20. It was soft-failed and then marked
  sent at 03:57:21 UTC. Its credential ID is NULL.
- The attack began on September 7 at 00:52:37 UTC, 42 seconds after the
  `shipmail@venia.cloud` mailbox was created, and continued in bursts through
  September 21 at 20:13:59 UTC. Across four delivery-themed subjects, Postal
  recorded 97,370 outbound recipient records to 67,601 distinct addresses:
  67,996 `Sent` (accepted by the recipient MX, not necessarily inbox-delivered),
  26,620 `HardFail`, 2,552 `Held`, and 202 `HoldCancelled`. There were 19 other
  apparent test messages from the same sender. The September 20-21 slice alone
  had 16,518 delivery-themed records, 9,491 marked `Sent`. No new records from
  that sender appeared in the September 22 query after restoration. The abusive
  burst reached 144 distinct recipients in a five-minute bucket; measured
  spam scores in nearby buckets ranged from 0 to 10.2, below the hard-fail
  threshold of 18. This is why content scoring did not reliably stop the burst.
- Postal's own SMTP-generated `Received` headers on sampled records identify
  direct public peers `47.236.178.59` and `196.89.21.76`. Production
  `proxy_protocol` is false, so these are not claimed PROXY-protocol actors.
  This is sample-based attribution; preserve the raw headers and database.
- `maildb.mail_users` entry 8224 for `shipmail@venia.cloud` was active and last
  authenticated on September 21. A deeper check of the sharded application
  table found employee `1-260907-0051-550882-096`, created September 7 at
  00:51:55 UTC under the Venia Cloud shared-domain organization. The employee
  and Dovecot mailbox password hashes match. The employee's `is_active=0`
  tracks recent usage, **not** authentication permission; `deleted_at` was null
  at the start of containment.
  Its `provisioning_source` is null (historically unclassified), so the exact
  creation path and the party who chose the password are not established.
  The matching credential hash, SMTP-generated `Received` header, null Postal
  API credential ID, and production SMTP branch logic together strongly
  indicate password-authenticated mailbox SMTP submission. These facts do not
  establish how the actor knew the password. All 97,389 sender records have
  `received_with_ssl=1`, recording TLS on submission but not ruling out
  password reuse, actor-created registration, or another compromise path.
  The mailbox was deactivated (`active=0`) by exact ID and its password was
  subsequently rotated as described below; the records were not deleted.
- `47.236.178.59` and `196.89.21.76` were entered as exact GlobalSuppression
  source bans and read back as active. They are **not** the reported egress IP
  `91.204.44.28`. The old production `ban_ip` method can erase held/queued
  evidence, so the rows were inserted directly and no purge method was called.
- The same lure was submitted from `160.177.16.114` by
  `taraza222@venia.cloud` three times at 00:47-00:49 UTC on September 7,
  before the `shipmail` mailbox was created. The two first messages were
  marked `Sent` and the third `HardFail`. Its sharded employee and mail-user
  records match, and its last successful mailbox login date was September 7.
  The exact mail-user row 8213 was deactivated. The production SMTP code
  does not yet check `active`, so that flag alone is not revocation. Both
  implicated employee records were subsequently soft-disabled for web access
  and their employee/mail-user passwords rotated to matching, random
  SHA256-CRYPT hashes; no message rows were deleted. Recovery requires an
  owner-reviewed account restore and new password. The exact source IPs
  `160.177.16.114` and `41.251.60.237` were added as 30-day suppression
  rows, preserving message evidence. The outbound SMTP guard remains active.
- The shared `venia.cloud` mail-user table has 8,009 entries, 8,006 active
  after the two exact-account containments. Only one had a recorded September
  19-or-later `last_login` in that table. This is the shared free-domain
  organization; do not bulk-disable other accounts. Reconcile the historical
  unclassified mailbox provenance and registration controls separately.
- A harmless TCP connect to one external SMTP destination on port 25 succeeded
  after restoration, so that sampled path was not blocked by the provider.
  A reversible host firewall guard now rejects outbound TCP 25/465/587 on
  `eth0` from host processes and forwarded containers, IPv4 and IPv6. Host
  and Postal worker connect probes then returned connection refused while
  the web endpoint still returned HTTP 302. Inbound SMTP is not matched by
  the `oifname "eth0"` rule.
- The primary guard uses a separate `nftables` inet table with output and
  forward hooks at priority -100, ahead of Docker's filter hooks. The
  `venmail-smtp-egress-guard.service` is enabled independently of Docker;
  Docker runs the same atomic guard load as `ExecStartPre`, failing closed
  before Docker starts without a dependency that propagates a guard restart.
  Source files: `script/incident_smtp_egress_guard.nft`,
  `script/venmail-smtp-egress-guard.service`, and
  `script/venmail-docker-egress-guard.conf`. This is configured for reboot
  persistence but has not been tested by rebooting production. Do not restart
  Docker or Postal to test it. It pauses legitimate external email delivery
  as well as abuse. Do not disable it merely because the server is healthy;
  first verify the exact-content admin/Telegram approval path and a
  controlled test of direct SMTP/API traffic.
- The initial commented iptables/ip6tables `OUTPUT` and `DOCKER-USER` rules
  remain in place as redundant live protection. They are not the reboot
  persistence mechanism; both rule sets must be removed during the eventual
  planned release, after the Core approval gate has been verified.
- At 16:20 UTC, restarting the guard **after adding Docker's Requires/After
  dependency caused systemd to restart Docker**, which restarted all production
  containers. The web endpoint temporarily returned HTTP 502 while
  `mailer_web` ran its startup ownership pass. This was unintended. The
  dependency was replaced with Docker's independent `ExecStartPre` and the
  guard now refuses manual stop/restart. A future rules update should apply
  the nftables file transaction directly and verify it, never restart Docker.
  Release of the guard and dependency must be a planned owner decision after
  the review path is live, not an incidental service operation.
- At 16:25 UTC, `mailer_web` was serving HTTP 302 again, the login page returned
  HTTP 200, the unauthenticated admin dashboard redirected to login, and
  `mailer_horizon` was healthy. The startup log recorded an already-existing
  storage symlink and a cancelled interactive migration command; inspect
  migrations separately before any rollout rather than assuming they ran.

## Known from the abuse notice

- Netcup reports a phishing message sent on 2026-09-20 at 03:50 UTC, apparently from `shipmail@venia.cloud` to `vandam@gbg.bg`.
- The reported Message-ID is `1f99088a-b76a-64b5-c3af-15e1d38713d7@venia.cloud`.
- The recipient's headers identify outbound IP `91.204.44.28` and `pxb.mail.venmail.io`; SPF and DKIM reportedly passed for `venia.cloud`.
- The message impersonated DHL and linked to a payment lure at `syc.rnpp.ci`.
- Netcup temporarily disabled the VPS. The owner subsequently reported reactivation, independently verified by SSH and HTTPS on September 22. Findings still need to be submitted through CCP's Abuse Notices > Statement.
- The signed-in CCP product list separately shows `91.204.44.28` as an additional Nürnberg IPv4 on this Netcup account and the named VPS as another Nürnberg product. This confirms account ownership of the reported egress IP, but not the sending process or how that IP was assigned at message time.
- At 2026-09-22 14:23 Europe/Berlin, we requested urgent web-only restoration with outbound SMTP ports 25/465/587 blocked, or a rescue window. Reactivation restored the web service, but the port-25 probe showed unrestricted egress until the host firewall guard was installed.

SPF and DKIM pass indicate that authorized sending infrastructure/signing was used; they do not identify the actor. The headers alone do not distinguish Postal SMTP, Postal API, the Venmail app, compromised credentials, or host-level compromise. The outbound IP is not the submitter's IP.

## Code finding and contained fix

`Postal::SMTPServer::Client#valid_user_authentication?` accepted a mailbox with a correct password even when its `active` value was false, whereas `Server#mail_user_exists?` excludes inactive mailboxes. A disabled mailbox could therefore continue authenticating by SMTP. The patch rejects inactive mailboxes on login and rechecks before DATA and before persistence, covering an account disabled during a live SMTP session. Focused RSpec examples cover the rejection and an active-mailbox control case.

The recheck closes the ordinary long-lived-session bypass, but it is not an atomic guarantee against a mailbox being disabled in the interval between the completion check and message persistence, nor against already-queued messages. A durable guarantee would require binding mailbox identity to each message and enforcing revocation at queue/delivery time with coordinated state changes. Avoid a per-recipient SMTP check without an atomic write: it could persist some recipients, return an error, and cause duplicate delivery when the client retries. The production SMTP container still runs the old code without the active-mailbox check; the two implicated passwords were rotated as the immediate revocation path.

This is a genuine revocation flaw, but there is no evidence that the reported phish used an inactive mailbox. The attack mailbox was active when it sent. This patch alone is not incident remediation.

## Further containment hardening merged but not deployed

Core's `GlobalSuppression.ban_ip` currently deletes queued and held message records as a side effect. The queue worker also deletes a stored message when its sender IP is banned. That destroys attribution evidence during an incident. PR #11 changes bans to leave existing messages intact and makes the worker hold, not delete, queued mail from the banned source. It also records the SMTP client IP as structured message provenance on outbound SMTP submissions and restricts automatic IP enforcement to structured submission provenance rather than spoofable legacy `Received` headers. Trusted API gateway requests with no validated actor and pre-migration ambiguous records cannot attribute a submitter IP. The worker rechecks bans immediately before delivery, but messages already being processed can still send; a fully atomic ban-versus-send guarantee would require additional coordination. PR #11 is merged but has not been deployed to production; production schema remains at version 21, before provenance migration 22.

Do not ban `91.204.44.28` as a source: it is the reported *egress* IP. Use the exact external submitting IP from authenticated SMTP/API records, and check for a shared gateway before applying any source-IP ban. Hold the implicated credential or mailbox and preserve the submission logs and message rows first.

The existing Venmail admin/Telegram outbound-review route only covers messages composed in the Venmail app. Direct Postal SMTP/API mail can bypass it. The durable mass-mail gate must run in Core before provider delivery, retain exact queued content and per-recipient evidence, emit a signed review event, and require an idempotent, narrowly authenticated release decision from the existing Venmail review/Telegram interface. Approval must bind the immutable content, sender identity and recipient batch; a generic credential unlock is not message approval. The affected submission path and volume must be established from production evidence before selecting safe thresholds and rollout controls.

## Forensics required during maintenance access

1. Preserve a snapshot or read-only copies of relevant Postal databases and SMTP/API/application logs before cleanup. Keep the original message and headers as evidence.
2. Find the exact Message-ID in Postal's per-server `messages` table and correlate its `server_id`, `domain_id`, `credential_id`, scope, timestamp, envelope/from/recipient, queue and delivery records, and spam-check results.
3. Trace its submission path and client IP in SMTP/API logs. If `credential_id` is present, identify and hold that credential; if absent, examine mailbox SMTP authentication and the Venmail app's Postal API credential use. A missing `credential_id` does not prove mailbox SMTP by itself.
4. Search a bounded period around the incident for the same sender, account, credential, submitter IP, lure domain, subject/body fingerprint, and other recipient domains. Determine the first and last unauthorized submission and delivery.
5. Revoke only implicated credentials/sessions, contain the submitting account or server as justified by evidence, and inspect host integrity. Preserve legitimate queued mail where possible.
6. Verify the exploit path and affected scope before submitting a factual explanation, cleanup steps, and prevention measures to Netcup. Do not claim all malicious files are removed without checking the host.

Do not reinstall the VPS as a first diagnostic step: it would destroy evidence and data. Production container restart/reload remains outside this investigation unless the owner makes the required separate decision.
