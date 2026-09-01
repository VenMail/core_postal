# Reputation Score Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent the Postal reputation monitor from automatically suppressing an IP based on records whose actual spam scores do not meet the configured threshold.

**Architecture:** Retain the MessageDB SQL predicate for performance and add a second score check at the application boundary before grouping by provenance-aware sender IP. This keeps enforcement fail-closed on evidence without adding database work or changing the separate Reply-To mismatch detector.

**Tech Stack:** Ruby, Rails, Postal MessageDB, RSpec

---

### Task 1: Reproduce the false-positive record path

**Files:**
- Modify: `spec/app/jobs/reputation_monitor_job_spec.rb`

- [ ] **Step 1: Write the failing test**

Add an example that returns six records with `external_actor_ip` set and
`spam_score` equal to `0.0`, calls `find_suspicious_ips`, and expects an empty
result.

- [ ] **Step 2: Verify the regression test fails**

Run the focused example against the unmodified production class. Expected:
failure because the current method returns one suspicious-IP group containing
six zero scores.

### Task 2: Add the application-level score guard

**Files:**
- Modify: `app/jobs/reputation_monitor_job.rb`
- Modify: `spec/app/jobs/reputation_monitor_job_spec.rb`

- [ ] **Step 1: Implement the minimal guard**

Convert the message score once, skip the record unless the score is finite and
at least `SPAM_SCORE_THRESHOLD`, then add that validated value to the IP group.

- [ ] **Step 2: Add positive enforcement coverage**

Return qualifying records at the threshold and assert the source IP, count, and
average remain correct.

- [ ] **Step 3: Run focused tests**

Run `bundle exec rspec spec/app/jobs/reputation_monitor_job_spec.rb`. Expected:
all examples pass.

- [ ] **Step 4: Run relevant regression tests**

Run the reputation, global-suppression, and message-provenance specs. Expected:
all examples pass.

### Task 3: Deliver and verify

**Files:**
- Modify: `app/jobs/reputation_monitor_job.rb`
- Modify: `spec/app/jobs/reputation_monitor_job_spec.rb`

- [ ] **Step 1: Commit and push the isolated branch**

Commit only the design, plan, job, and focused spec; push without including the
unrelated dirty changes from the primary checkout.

- [ ] **Step 2: Integrate through the repository's production path**

Use the existing Core Postal deployment workflow and do not restart unrelated
Mailer Web containers.

- [ ] **Step 3: Verify production**

Confirm the deployed job includes the application-level score guard, confirm no
suppression exists for `178.79.176.19`, and confirm the DocuSeal container can
complete SMTP `EHLO` and see `STARTTLS` without sending a message.
