# Inbound Transactional Mail Classification Design

## Purpose

Prevent authenticated transactional messages sent through providers such as Amazon SES from being hard-failed by unrelated transport metadata, while retaining detection of unauthenticated brand impersonation and reply redirection.

## Incident Evidence

Two Vercel login-code messages to `copata@venmail.io` were rejected on October 14, 2026. Rspamd confirmed DKIM, SPF, and DMARC and contributed a net negative score. Venmail's pre-classifier supplied scores of 26 and 23 because it:

- scanned the complete raw MIME message as content, allowing Amazon SES transport headers and encoded signatures to trigger body heuristics;
- treated the single-character brand token `x` as a substring match;
- treated `mail.vercel.com` and `vercel.com` as unrelated domains;
- treated Amazon SES envelope identifiers as suspicious without requiring corroborating evidence.

## Considered Approaches

### Provider allowlist

Adding `vercel.com` to `TRUSTED_DOMAINS` would repair this incident quickly, but would create a bypass for spoofed or compromised mail and leave identical defects for every other transactional provider. This approach is rejected.

### Threshold increase

Increasing the failure threshold would reduce false positives, but would also admit high-scoring phishing messages and would not correct the invalid evidence. This approach is rejected.

### Evidence-aware classification

The selected approach separates decoded content from transport metadata, uses registrable-domain relationships, and requires corroborating evidence before penalizing generated envelope senders. This corrects the faulty signals without weakening authentication-independent phishing checks.

## Design

### Message content boundary

The internal classifier will receive decoded visible MIME content instead of the complete raw message. Headers remain available through the existing separate header array. Link, phrase, and gibberish checks therefore inspect user-visible content and cannot match DKIM signatures, `Received` headers, or provider message identifiers.

When MIME parsing fails, the inspector will fall back to the raw body section and preserve the existing fail-safe error handling. Attachments will not be concatenated into the heuristic text.

### Domain relationships

Envelope sender, From, and Reply-To comparisons will use a focused helper that treats identical domains and parent/subdomain relationships as related. Thus `mail.vercel.com` and `vercel.com` are related, while `vercel-security.example` and `vercel.com` remain unrelated.

The implementation will not introduce a new network lookup or database lookup. Domain comparison is deterministic string processing during message inspection.

### Brand matching

Brand detection will use boundary-aware tokens. Single-character entries will not participate in free-text brand matching. Transport-only occurrences such as `amazonses.com` will no longer be visible to the content heuristic because headers are classified separately.

### Generated envelope senders

Random-local-part scoring will not independently classify a message as high-confidence spam. For a sender domain related to an authenticated From domain, the generated local part will not be penalized. Unrelated generated senders remain eligible for scoring, preserving the signal for suspicious submissions.

### Authentication evidence

The change will not hardcode Vercel as trusted and will not blindly exempt messages with authentication-looking headers. Rspamd remains responsible for verified SPF, DKIM, and DMARC results. The internal classifier will avoid contradicting those results with weak formatting heuristics; it will continue to score content-based phishing, malicious links, mismatched unrelated Reply-To domains, and other independent evidence.

## Tests

Regression tests will cover:

- a Vercel-style Amazon SES message with generated envelope sender, aligned From and Reply-To domains, transport headers, DKIM material, and a login code;
- parent/subdomain domain equivalence;
- unrelated Reply-To redirection remaining penalized;
- single-character brand substrings not producing brand mismatch points;
- full brand tokens from unrelated domains still producing mismatch points;
- MIME extraction excluding transport headers and encoded signatures;
- existing spam-checker examples and the focused inspector suite.

The Vercel fixture must score below both the normal spam threshold and the historical hard-failure threshold without adding `vercel.com` to a trusted-domain list.

## Deployment and Recovery

The code will be committed and pushed only after focused and broader server-side tests pass. Deployment requires a new Core image through the existing CI/CD workflow. No production container restart or reload is part of this design unless separately and explicitly authorized. Previously hard-failed messages require explicit redelivery after the corrected classifier is deployed; the code change alone does not alter historical delivery records.
