# Reputation Score Guard Design

## Problem

The active-attack monitor historically used an unsupported MessageDB comparison
operator. MessageDB converted that unknown operator into `1=1`, so ordinary
outgoing messages could be returned. The monitor then converted missing or zero
scores with `to_f`, grouped those messages by source IP, and created an
indefinite suppression such as "6 spam messages with avg score 0.0".

The SQL operator is now corrected, but the blocking decision still trusts the
database filter completely. A query regression, schema mismatch, or partially
migrated server could therefore reintroduce the same false-positive class.

## Selected approach

Keep the supported `greater_than_or_equal_to` SQL predicate to bound work, then
independently validate every returned message's score before it contributes to
an IP group. Only finite numeric scores at or above
`SPAM_SCORE_THRESHOLD` qualify. Resolve the source through
`Postal::MessageDB::Message#sender_ip`, which prefers the authenticated external
actor provenance, then the transport peer, and only uses the Received-header
fallback for legacy messages.

This is preferred over relying only on SQL because it makes the irreversible
suppression decision safe at the application boundary. Disabling automatic
blocking is rejected because it would weaken live abuse containment.

## Behavior

- Messages below the spam threshold, including missing scores coerced to zero,
  do not contribute to the per-IP count or average.
- Messages at or above the threshold continue to contribute normally.
- Existing count thresholds, IP normalization, configured whitelist checks,
  non-public address protection, and Reply-To mismatch enforcement remain
  unchanged.
- The hot path performs no additional database queries.

## Verification

Add a regression example that simulates six zero-score records returned despite
the SQL predicate and proves no suspicious IP is produced. Add a positive
example proving qualifying scores are still grouped with the expected count and
average. Run the focused reputation-monitor spec and the existing relevant Core
suite before deployment, then verify the deployed source and SMTP access from
the formerly blocked DocuSeal host.
