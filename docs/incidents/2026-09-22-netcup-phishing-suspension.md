# Netcup suspension: reported DHL phishing from Venmail Postal

Status: investigation in progress. Do not report the server as remediated or request unrestricted reactivation until the sending path and scope have been verified.

## Known from the abuse notice

- Netcup reports a phishing message sent on 2026-09-20 at 03:50 UTC, apparently from `shipmail@venia.cloud` to `vandam@gbg.bg`.
- The reported Message-ID is `1f99088a-b76a-64b5-c3af-15e1d38713d7@venia.cloud`.
- The recipient's headers identify outbound IP `91.204.44.28` and `pxb.mail.venmail.io`; SPF and DKIM reportedly passed for `venia.cloud`.
- The message impersonated DHL and linked to a payment lure at `syc.rnpp.ci`.
- Netcup says it temporarily disabled the VPS. Its notice requires a maintenance-window request and subsequent findings through CCP's Abuse Notices > Statement. A server may only be available in rescue mode.
- The signed-in CCP product list separately shows `91.204.44.28` as an additional Nürnberg IPv4 on this Netcup account and the named VPS as another Nürnberg product. This confirms account ownership of the reported egress IP, but not the sending process or how that IP was assigned at message time.

SPF and DKIM pass indicate that authorized sending infrastructure/signing was used; they do not identify the actor. The headers alone do not distinguish Postal SMTP, Postal API, the Venmail app, compromised credentials, or host-level compromise. The outbound IP is not the submitter's IP.

## Code finding and contained fix

`Postal::SMTPServer::Client#valid_user_authentication?` accepted a mailbox with a correct password even when its `active` value was false, whereas `Server#mail_user_exists?` excludes inactive mailboxes. A disabled mailbox could therefore continue authenticating by SMTP. The patch rejects inactive mailboxes on login and rechecks before DATA and before persistence, covering an account disabled during a live SMTP session. Focused RSpec examples cover the rejection and an active-mailbox control case.

The recheck closes the ordinary long-lived-session bypass, but it is not an atomic guarantee against a mailbox being disabled in the interval between the completion check and message persistence, nor against already-queued messages. A durable guarantee would require binding mailbox identity to each message and enforcing revocation at queue/delivery time with coordinated state changes. Avoid a per-recipient SMTP check without an atomic write: it could persist some recipients, return an error, and cause duplicate delivery when the client retries.

This is a genuine revocation flaw, but there is no evidence yet that the reported phish used an inactive mailbox. This patch alone is not incident remediation.

## Forensics required during maintenance access

1. Preserve a snapshot or read-only copies of relevant Postal databases and SMTP/API/application logs before cleanup. Keep the original message and headers as evidence.
2. Find the exact Message-ID in Postal's per-server `messages` table and correlate its `server_id`, `domain_id`, `credential_id`, scope, timestamp, envelope/from/recipient, queue and delivery records, and spam-check results.
3. Trace its submission path and client IP in SMTP/API logs. If `credential_id` is present, identify and hold that credential; if absent, examine mailbox SMTP authentication and the Venmail app's Postal API credential use. A missing `credential_id` does not prove mailbox SMTP by itself.
4. Search a bounded period around the incident for the same sender, account, credential, submitter IP, lure domain, subject/body fingerprint, and other recipient domains. Determine the first and last unauthorized submission and delivery.
5. Revoke only implicated credentials/sessions, contain the submitting account or server as justified by evidence, and inspect host integrity. Preserve legitimate queued mail where possible.
6. Verify the exploit path and affected scope before submitting a factual explanation, cleanup steps, and prevention measures to Netcup. Do not claim all malicious files are removed without checking the host.

Do not reinstall the VPS as a first diagnostic step: it would destroy evidence and data. Production container restart/reload remains outside this investigation unless the owner makes the required separate decision.
