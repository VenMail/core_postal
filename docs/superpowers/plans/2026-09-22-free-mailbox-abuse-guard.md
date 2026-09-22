# Free Mailbox Abuse Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce free shared-domain mailbox limits and deactivate a mailbox after 100 outbound hard failures.

**Architecture:** Store the authenticated mailbox with every SMTP-submitted outgoing message. Use a Core main-database guard row locked inside a transaction to reserve per-domain and per-mailbox capacity. Enforce delivery-time deactivation using the stored mailbox, preserving held-message evidence.

**Tech Stack:** Ruby on Rails 5.2, RSpec, Postal MessageDB, MariaDB.

---

### Task 1: Persist mailbox attribution

**Files:**
- Create: `db/migrate/20260922170000_add_authenticated_mailbox_to_messages.rb`
- Modify: `lib/postal/smtp_server/client.rb`
- Test: `spec/lib/postal/smtp_server/mailbox_authentication_spec.rb`

- [ ] Write a failing SMTP client spec proving a mailbox-authenticated outgoing message receives `authenticated_mailbox = address`.
- [ ] Run `bundle exec rspec spec/lib/postal/smtp_server/mailbox_authentication_spec.rb` and confirm failure because the assignment is absent.
- [ ] Add the nullable MessageDB column and set it only in the mailbox-authenticated outgoing branch.
- [ ] Re-run the spec and commit the focused change.

### Task 2: Reserve free-mailbox capacity before queueing

**Files:**
- Create: `app/models/mailbox_submission_guard.rb`
- Create: `db/migrate/20260922170100_create_mailbox_submission_guards.rb`
- Modify: `config/postal.defaults.yml`
- Modify: `lib/postal/smtp_server/client.rb`
- Test: `spec/app/models/mailbox_submission_guard_spec.rb`
- Test: `spec/lib/postal/smtp_server/mailbox_authentication_spec.rb`

- [ ] Write failing model examples for 60 domain recipients/minute, three recipients/message, five submissions/hour, and ten recipients/day.
- [ ] Run the model spec and confirm the unimplemented guard fails.
- [ ] Implement a locked transactional counter keyed by server/domain/mailbox and configure `venia.cloud` as the shared free domain.
- [ ] Call reservation before creating message rows and return SMTP rejection on denial.
- [ ] Run both focused specs and commit.

### Task 3: Deactivate after hard failures and hold queued mail

**Files:**
- Create: `app/services/mailbox_abuse_guard.rb`
- Modify: `app/jobs/unqueue_message_job.rb`
- Modify: `app/models/webhook_event.rb`
- Test: `spec/app/jobs/unqueue_message_job_mailbox_abuse_spec.rb`

- [ ] Write a failing job spec for the 100th `HardFail` deactivating only its recorded mailbox and emitting `MailboxLocked`.
- [ ] Write a failing job spec for a queued message held when its recorded mailbox is inactive.
- [ ] Run the focused spec and confirm failure.
- [ ] Implement exact mailbox deactivation, evidence-preserving hold, and webhook emission.
- [ ] Re-run the focused spec and commit.

### Task 4: Verify and release

**Files:**
- Modify: `docs/incidents/2026-09-22-netcup-phishing-suspension.md`

- [ ] Run all focused specs plus `bundle exec rspec spec/lib/postal/smtp_server/mailbox_authentication_spec.rb spec/app/models/mailbox_submission_guard_spec.rb spec/app/jobs/unqueue_message_job_mailbox_abuse_spec.rb`.
- [ ] Run `bundle exec rubocop` if configured and `git diff --check`.
- [ ] Update the incident report with final limits and non-goal that egress remains blocked.
- [ ] Commit, push, open PR, wait for CI, then deploy only through the reviewed CI path.
