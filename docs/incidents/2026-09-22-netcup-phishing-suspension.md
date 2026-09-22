# Netcup suspension: reported DHL phishing from Venmail Postal

Status: production contained, durable review gate not deployed. Do not remove the
outbound SMTP egress guard or report the incident as fully remediated until the
Core review/release path has been deployed and verified.

## Verified after Netcup reactivation (2026-09-22)

- SSH, Postal containers, and `m.venmail.io` were reachable again at 15:56 UTC.
  The web endpoint returned HTTP 302. No production containers were restarted
  or reloaded by this investigation.
- Postal server 61 (`Venia Cloud`, domain 50) holds the reported Message-ID as
  message 261274, outgoing from `shipmail@venia.cloud` to `vandam@gbg.bg`,
  created at 03:50:38 UTC on September 20. It was soft-failed and then marked
  sent at 03:57:21 UTC. Its credential ID is NULL.
- The same sender has 16,520 outbound recipient records from September 20-21:
  9,493 marked sent, 5,304 hard-failed, and 1,723 held. No new messages from
  that sender appeared in the September 22 query after restoration. The abusive
  burst reached 144 distinct recipients in a five-minute bucket; measured
  spam scores in nearby buckets ranged from 0 to 10.2, below the hard-fail
  threshold of 18. This is why content scoring did not reliably stop the burst.
- Postal's own SMTP-generated `Received` headers on sampled records identify
  direct public peers `47.236.178.59` and `196.89.21.76`. Production
  `proxy_protocol` is false, so these are not claimed PROXY-protocol actors.
  This is sample-based attribution; preserve the raw headers and database.
- `maildb.mail_users` entry 8224 for `shipmail@venia.cloud` was active and last
  authenticated on September 21. The Venmail application's current employees,
  users, and organization-1 mail records have no matching `shipmail` identity or
  composed send. This points to direct mailbox SMTP submission, not the app's
  outbound-review path. The mailbox was deactivated (`active=0`) by exact ID;
  subsequent readback confirmed the change. Do not reset its password or
  delete the row before evidence capture.
- `47.236.178.59` and `196.89.21.76` were entered as exact GlobalSuppression
  source bans and read back as active. They are **not** the reported egress IP
  `91.204.44.28`. The old production `ban_ip` method can erase held/queued
  evidence, so the rows were inserted directly and no purge method was called.
- The shared `venia.cloud` mail-user table has 8,009 entries, 8,007 active,
  while the current app has no employee assigned to that domain. Only one of
  these users had a recorded September 19-or-later `last_login` in that table.
  This mismatch requires a separate account-ownership reconciliation. Do not
  bulk-disable the other accounts without establishing their provisioning path.
- A harmless TCP connect to an external SMTP server on port 25 succeeded after
  restoration: provider-level outbound SMTP was not blocked. A reversible
  host firewall guard now rejects outbound TCP 25/465/587 on `eth0` in both
  `OUTPUT` and `DOCKER-USER`, IPv4 and IPv6, with the comment
  `venmail-netcup-phishing-20260922-temporary-egress`. Host and Postal worker
  connect probes then returned connection refused while the web endpoint still
  returned HTTP 302. Inbound SMTP is not matched by the `-o eth0` rule.
- The guard is installed as `/usr/local/sbin/venmail-smtp-egress-guard` with
  `venmail-smtp-egress-guard.service`, enabled and active, to survive a reboot.
  Source files are `script/incident_smtp_egress_guard.sh` and
  `script/venmail-smtp-egress-guard.service`. It pauses legitimate external
  email delivery as well as abuse. Do not disable it merely because the server
  or containers are healthy; first verify the exact-content admin/Telegram
  approval path and a controlled test of direct SMTP/API traffic.

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

The recheck closes the ordinary long-lived-session bypass, but it is not an atomic guarantee against a mailbox being disabled in the interval between the completion check and message persistence, nor against already-queued messages. A durable guarantee would require binding mailbox identity to each message and enforcing revocation at queue/delivery time with coordinated state changes. Avoid a per-recipient SMTP check without an atomic write: it could persist some recipients, return an error, and cause duplicate delivery when the client retries.

This is a genuine revocation flaw, but there is no evidence yet that the reported phish used an inactive mailbox. This patch alone is not incident remediation.

## Further containment hardening under review

Core's `GlobalSuppression.ban_ip` currently deletes queued and held message records as a side effect. The queue worker also deletes a stored message when its sender IP is banned. That destroys attribution evidence during an incident. A follow-up patch changes bans to leave existing messages intact and makes the worker hold, not delete, queued mail from the banned source. It also records the SMTP client IP as structured message provenance on outbound SMTP submissions and restricts automatic IP enforcement to structured submission provenance rather than spoofable legacy `Received` headers. Trusted API gateway requests with no validated actor and pre-migration ambiguous records cannot attribute a submitter IP. The worker rechecks bans immediately before delivery, but messages already being processed can still send; a fully atomic ban-versus-send guarantee would require additional coordination. These changes are not deployed merely because they are present in this repository.

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
