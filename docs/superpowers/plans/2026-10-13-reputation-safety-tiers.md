# Mailbox Reputation Safety Tiers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Warn and throttle a degrading mailbox at 2%, then hold it before the SES 5% review boundary or after five terminal failures.

**Architecture:** Extend the existing `MailboxSubmissionGuard` row with a durable warning outbox and expiry. Evaluate warning and hold policies only after terminal failures, reuse the guard row already locked during SMTP reservation to apply throttle caps, and retry warning and lock outboxes from the existing reputation monitor.

**Tech Stack:** Ruby on Rails 5.2, RSpec, Postal MessageDB, MariaDB, GitHub Actions container deployment.

---

### Task 1: Define validated tier policies

**Files:**
- Modify: `config/postal.defaults.yml`
- Modify: `app/models/mailbox_submission_guard.rb`
- Test: `spec/app/models/mailbox_submission_guard_spec.rb`

- [ ] **Step 1: Write failing policy examples**

Replace the old eight-percent examples with assertions for this public result:

```ruby
expect(described_class.reputation_policy_for(server: server, domain: 'venia.cloud')).to eq(
  warning: { threshold_percent: 2.0, minimum_sample_size: 10, minimum_failures: 1 },
  hold: { threshold_percent: 4.0, minimum_sample_size: 25, minimum_failures: 2 },
  absolute_failure_limit: 5,
  warning_lifetime: 24.hours
)
```

Add a customer-domain example with 25/50 samples and an invalid-configuration example that proves the method falls back to 2%/4% rather than accepting a hold threshold at or above 5%.

- [ ] **Step 2: Run the focused spec and verify RED**

Run: `bundle exec rspec spec/app/models/mailbox_submission_guard_spec.rb`

Expected: failure because `reputation_policy_for` does not exist.

- [ ] **Step 3: Add explicit defaults and the policy builder**

Add these keys beneath the existing reputation configuration:

```yaml
reputation_warning_threshold_percent: 2.0
reputation_hold_threshold_percent: 4.0
reputation_warning_min_sample_size: 25
reputation_hold_min_sample_size: 50
shared_free_mailbox_warning_min_sample_size: 10
shared_free_mailbox_hold_min_sample_size: 25
reputation_warning_min_failures: 1
reputation_hold_min_failures: 2
reputation_warning_lifetime_hours: 24
reputation_throttled_recipient_limit_per_message: 1
reputation_throttled_submission_limit_per_hour: 2
reputation_throttled_recipient_limit_per_day: 5
```

Replace `bounce_policy_for` with `reputation_policy_for`. Validate numeric values, require `0 < warning < hold < 5`, and return the exact hash asserted above. Keep `bounce_policy_for` as a compatibility wrapper returning the hold threshold and sample so older callers cannot silently regain the 8% policy.

- [ ] **Step 4: Run the focused spec and verify GREEN**

Run: `bundle exec rspec spec/app/models/mailbox_submission_guard_spec.rb`

Expected: all examples pass.

- [ ] **Step 5: Commit the policy**

```bash
git add config/postal.defaults.yml app/models/mailbox_submission_guard.rb spec/app/models/mailbox_submission_guard_spec.rb
git commit -m "Define mailbox reputation safety tiers"
```

### Task 2: Persist warnings and deliver a durable warning event

**Files:**
- Create: `db/migrate/20261013113000_add_reputation_warning_outbox_to_mailbox_submission_guards.rb`
- Modify: `app/models/mailbox_submission_guard.rb`
- Modify: `app/models/webhook_event.rb`
- Modify: `app/jobs/reputation_monitor_job.rb`
- Test: `spec/app/models/mailbox_lock_outbox_behavior_spec.rb`
- Test: `spec/integration/mailbox_lock_outbox_spec.rb`

- [ ] **Step 1: Write failing warning-outbox examples**

Add examples proving that `begin_mailbox_warning!` stores `warning_at`, `warning_expires_at`, `warning_reason`, and clears `warning_notification_enqueued_at`; `enqueue_mailbox_warning_notification!` triggers `MailboxReputationWarning` before marking the outbox complete; and a trigger failure leaves the outbox pending.

Use this payload contract:

```ruby
{
  mailbox: 'sender@venia.cloud',
  reason: '2 of 50 terminal outcomes failed in 24 hours (4.0% failure rate)',
  warning_at: warning_at.iso8601,
  warning_expires_at: warning_expires_at.iso8601
}
```

Extend the integration source assertion to require both:

```ruby
MailboxSubmissionGuard.retry_pending_mailbox_warnings!
MailboxSubmissionGuard.retry_pending_mailbox_locks!
```

- [ ] **Step 2: Run the outbox specs and verify RED**

Run: `bundle exec rspec spec/app/models/mailbox_lock_outbox_behavior_spec.rb spec/integration/mailbox_lock_outbox_spec.rb`

Expected: failures for missing warning methods and event.

- [ ] **Step 3: Add the migration and warning outbox methods**

The migration adds nullable `warning_at`, `warning_expires_at`, `warning_reason`, and `warning_notification_enqueued_at` columns plus an index on `warning_notification_enqueued_at, warning_at`.

Implement these methods beside the lock outbox:

```ruby
begin_mailbox_warning!(server:, mailbox:, reason:, now: Time.now, expires_at:)
enqueue_mailbox_warning_notification!(guard, now: Time.now)
retry_pending_mailbox_warnings!
```

`begin_mailbox_warning!` starts a new cycle only when there is no unexpired warning. `enqueue_mailbox_warning_notification!` emits `MailboxReputationWarning` once. The retry method scans only pending warning outbox rows. Add `MailboxReputationWarning` to `WebhookEvent::EVENTS` and invoke warning retry before lock retry in `ReputationMonitorJob#perform`.

- [ ] **Step 4: Run the outbox specs and verify GREEN**

Run: `bundle exec rspec spec/app/models/mailbox_lock_outbox_behavior_spec.rb spec/integration/mailbox_lock_outbox_spec.rb`

Expected: all examples pass.

- [ ] **Step 5: Commit warning durability**

```bash
git add db/migrate/20261013113000_add_reputation_warning_outbox_to_mailbox_submission_guards.rb app/models/mailbox_submission_guard.rb app/models/webhook_event.rb app/jobs/reputation_monitor_job.rb spec/app/models/mailbox_lock_outbox_behavior_spec.rb spec/integration/mailbox_lock_outbox_spec.rb
git commit -m "Persist mailbox reputation warnings"
```

### Task 3: Evaluate warning and hold tiers after failures

**Files:**
- Modify: `app/models/mailbox_abuse_guard.rb`
- Test: `spec/app/models/mailbox_abuse_guard_spec.rb`

- [ ] **Step 1: Write failing boundary examples**

Add focused examples for:

```ruby
# 1/25 = 4%: warn, do not deactivate, and enqueue one warning.
# 1/24: no action because the warning sample is not met.
# 2/50 = 4%: lock and deactivate.
# 5 failures with a smaller sample: lock through the absolute boundary.
# Repeated warning evaluation: update no second notification in the same cycle.
```

The warning example must expect `begin_mailbox_warning!` and `enqueue_mailbox_warning_notification!`, while explicitly rejecting `mail_user.deactivate`. The hold examples must expect the existing lock outbox path.

- [ ] **Step 2: Run the abuse-guard spec and verify RED**

Run: `bundle exec rspec spec/app/models/mailbox_abuse_guard_spec.rb`

Expected: warning examples fail because the guard only knows the old hold policy.

- [ ] **Step 3: Implement ordered tier evaluation**

Refactor `lock_after_delivery_failure!` to:

```ruby
policy = MailboxSubmissionGuard.reputation_policy_for(server: message.server, domain: domain)
rate = outcomes[:total].positive? ? outcomes[:failures].to_f / outcomes[:total] * 100.0 : 0.0

if absolute_limit_reached || policy_boundary_reached?(policy[:hold], outcomes, rate)
  # existing durable lock, deactivate, notify; return true
elsif policy_boundary_reached?(policy[:warning], outcomes, rate)
  # durable warning, notify; return false
else
  false
end
```

Use inclusive `>=` comparisons. Keep the terminal-outcome SQL unchanged so one message contributes one outcome and pending/held deliveries never dilute the rate.

- [ ] **Step 4: Run the abuse-guard spec and verify GREEN**

Run: `bundle exec rspec spec/app/models/mailbox_abuse_guard_spec.rb spec/integration/mailbox_bounce_hook_spec.rb`

Expected: all examples pass.

- [ ] **Step 5: Commit tier evaluation**

```bash
git add app/models/mailbox_abuse_guard.rb spec/app/models/mailbox_abuse_guard_spec.rb
git commit -m "Enforce mailbox warning and hold boundaries"
```

### Task 4: Throttle warned mailboxes without an additional lookup

**Files:**
- Modify: `app/models/mailbox_submission_guard.rb`
- Test: `spec/app/models/mailbox_submission_guard_spec.rb`

- [ ] **Step 1: Write failing reservation examples**

Create a mailbox guard with an unexpired warning and prove the existing `reserve!` transaction caps it at one recipient/message, two submissions/hour, and five recipients/day. Add an expired-warning example that clears warning fields and restores the ordinary limits. Assert that `locked_guards` remains the only guard-loading call.

- [ ] **Step 2: Run the submission-guard spec and verify RED**

Run: `bundle exec rspec spec/app/models/mailbox_submission_guard_spec.rb`

Expected: warned rows still receive ordinary limits.

- [ ] **Step 3: Apply throttle caps to the already locked mailbox row**

After `locked_guards` and window reset, clear warning fields when `warning_expires_at <= now`. Otherwise cap the three mailbox limits with the configured throttle values using the lower positive limit. Leave the domain minute limit unchanged. Do not add a query before the reservation transaction.

- [ ] **Step 4: Run the submission-guard spec and verify GREEN**

Run: `bundle exec rspec spec/app/models/mailbox_submission_guard_spec.rb`

Expected: all examples pass.

- [ ] **Step 5: Commit throttling**

```bash
git add app/models/mailbox_submission_guard.rb spec/app/models/mailbox_submission_guard_spec.rb
git commit -m "Throttle warned SMTP mailboxes"
```

### Task 5: Verify, review, and deploy

**Files:**
- Modify only if verification exposes a defect in the files above.

- [ ] **Step 1: Run focused regression coverage**

Run:

```bash
bundle exec rspec spec/app/models/mailbox_submission_guard_spec.rb spec/app/models/mailbox_abuse_guard_spec.rb spec/app/models/mailbox_lock_outbox_behavior_spec.rb spec/integration/mailbox_lock_outbox_spec.rb spec/integration/mailbox_bounce_hook_spec.rb spec/integration/cron_jobs_spec.rb
```

Expected: zero failures.

- [ ] **Step 2: Run the full test suite and static checks**

Run `bundle exec rspec` and `git diff --check`.

Expected: zero failures and no whitespace errors.

- [ ] **Step 3: Review the branch diff against the design**

Confirm every new method has direct tests, successful SMTP reservations do not add a guard lookup, thresholds are inclusive, invalid configuration falls back below 5%, warning expiry is recoverable, and both outboxes retry.

- [ ] **Step 4: Push, open a PR, and wait for CI**

Push `codex/reputation-safety-tiers`, open the PR against `main`, attach it to this task, and require the full Core CI suite to pass before merge.

- [ ] **Step 5: Deploy through the reviewed Core workflow**

After merge, run the existing full Core rollout. Verify the migration, exact immutable image on all six Core services, live 2%/4%/5 policy values, warning outbox columns, SMTP hook, terminal-failure hook, and zero newly queued suspect spam using the guarded Paramiko verification script.
