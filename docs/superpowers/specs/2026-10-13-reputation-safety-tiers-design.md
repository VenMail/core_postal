# Mailbox Reputation Safety Tiers Design

## Goal

Stop one mailbox from pushing the shared SES reputation into review while
avoiding permanent locks for an isolated mistyped recipient.

## Scope

This slice changes Postal mailbox enforcement. SES tenant provisioning and IP
pool separation require a separate design because they change AWS resource
ownership and the Venmail-to-SES sending contract.

## Decision

Evaluate each authenticated mailbox after a terminal delivery failure. Count
one outcome per message over the previous 24 hours and use only `Sent`,
`HardFail`, and `Bounced` outcomes.

The policy has two persistent tiers:

1. **Warning and throttle.** At or above a 2% failure rate, after the configured
   sample and failure floors, record a warning cycle, emit one durable warning
   event, and cap future SMTP submissions for 24 hours. The warning path does
   not deactivate the mailbox.
2. **Hold.** At or above a 4% failure rate, after the stricter sample and
   failure floors, deactivate the mailbox, preserve queued evidence, and emit
   the existing durable `MailboxLocked` event. Five terminal failures in 24
   hours also hold the mailbox regardless of rate.

Default floors protect low-volume senders from one typo:

- warning: at least 25 terminal outcomes and one failure;
- percentage hold: at least 50 terminal outcomes and two failures;
- absolute hold: five failures in 24 hours.

Shared free domains retain their smaller warning sample of ten outcomes, but
the percentage-hold sample remains 25. Their existing low submission and
recipient limits remain in force.

## Throttling

The mailbox guard row already loaded and locked during SMTP reservation stores
the warning state. No additional successful-login or unflagged-submission query
is introduced.

While warned, effective limits are capped at:

- one recipient per message;
- two submissions per hour;
- five recipients per day.

The stricter value wins when a server already has a lower limit. The warning
expires after 24 hours. Expiry is applied within the existing reservation
transaction, so it does not require a new scheduled scan.

## Durability and idempotency

Add warning timestamps, reason, and notification-enqueued state to
`mailbox_submission_guards`. Starting a warning cycle and recording its outbox
state are transactional. `ReputationMonitorJob` retries any warning or lock
notification left incomplete by a database or webhook failure.

Each warning cycle emits at most one `MailboxReputationWarning` webhook.
Repeated failures may update the stored reason but do not flood operators.
Escalation to a lock uses the existing lock outbox and permanently deactivates
the mailbox until an operator releases it.

## Configuration

Defaults are explicit and validated with safe fallbacks:

- warning threshold: 2%;
- hold threshold: 4%;
- warning sample: 25;
- hold sample: 50;
- warning minimum failures: 1;
- hold minimum failures: 2;
- absolute 24-hour failure limit: 5;
- warning lifetime: 24 hours;
- throttled caps: 1 recipient/message, 2 submissions/hour, 5 recipients/day.

The hold threshold must be greater than the warning threshold and below the SES
5% review boundary. Invalid configuration fails toward these safe defaults.

## Testing

RSpec coverage will prove:

- warning begins at the configured boundary without deactivation;
- warning notification is idempotent and retryable;
- warned mailboxes receive capped limits without an extra guard lookup;
- warning expiry restores ordinary limits;
- a 4% rate with sufficient evidence locks the mailbox;
- five failures lock regardless of sample size;
- one low-volume failure does not warn or lock;
- terminal outcomes remain deduplicated per message;
- all existing SMTP, queue, outbox, and workflow checks remain green.

## Rollout

Ship through the Core CI image workflow, apply the main-database migration,
verify all six Core services use the same immutable image and configuration,
then confirm the live thresholds and outbox columns read-only over Paramiko.
No Venmail web or Horizon container is part of this rollout.
