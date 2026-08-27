# Legacy DKIM Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore existing RSA-1024 DKIM domains without weakening the RSA-2048 requirement for new or replacement keys.

**Architecture:** Separate the read-time compatibility floor from the write-time security floor inside `Domain`. Persisted private RSA keys at 1024 bits or stronger remain derivable and verifiable; validation and key generation continue to require 2048 bits.

**Tech Stack:** Ruby, Rails/ActiveRecord, OpenSSL, RSpec

---

### Task 1: Capture the legacy compatibility contract

**Files:**
- Modify: `spec/app/models/domain_api_payload_spec.rb`

- [ ] **Step 1: Replace the obsolete fail-closed RSA-1024 example with a failing backward-compatibility example**

The example must persist a 1024-bit private key with `update_columns`, assert that the public payload is `ready`, assert `legacy: true` and `key_bits: 1024`, stub the exact selector TXT result, and assert `check_dkim_record!` changes `dkim_status` to `OK`.

- [ ] **Step 2: Run the focused example and verify RED**

Run:

```bash
bundle exec rspec spec/app/models/domain_api_payload_spec.rb
```

Expected: failure because the payload still returns `status: invalid` and no record.

### Task 2: Add a read-time legacy floor

**Files:**
- Modify: `app/models/domain.rb`

- [ ] **Step 1: Add the compatibility constant**

```ruby
LEGACY_DKIM_KEY_BITS = 1024
```

- [ ] **Step 2: Make the public payload accept persisted legacy private keys**

Parse the key once, require `private?` and at least `LEGACY_DKIM_KEY_BITS`, derive the public record, then return:

```ruby
details.merge(
  :record => record,
  :status => 'ready',
  :key_bits => key_bits,
  :legacy => key_bits < DKIM_KEY_BITS
)
```

Missing and invalid payloads must also include `key_bits: nil` and `legacy: false` so callers receive a stable shape.

- [ ] **Step 3: Keep write-time enforcement unchanged**

Confirm `generate_dkim_key` and `dkim_private_key_is_valid` still use `DKIM_KEY_BITS` (2048), not the legacy constant.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
bundle exec rspec spec/app/models/domain_api_payload_spec.rb spec/app/models/domain_dns_checks_spec.rb
```

Expected: all examples pass.

### Task 3: Full verification and deployment

**Files:**
- Verify: `app/models/domain.rb`
- Verify: `app/models/domain/dns_checks.rb`
- Verify: `spec/app/models/domain_api_payload_spec.rb`
- Verify: `spec/app/models/domain_dns_checks_spec.rb`

- [ ] **Step 1: Run syntax and whitespace checks**

```bash
ruby -c app/models/domain.rb
ruby -c app/models/domain/dns_checks.rb
git diff --check
```

Expected: syntax OK and no whitespace errors.

- [ ] **Step 2: Run the full Core suite through CI**

Push the feature branch and require the full `make ci-test` workflow to pass before advancing the exact tested commit to `main`.

- [ ] **Step 3: Deploy only the Core web API image**

Use the reviewed `Core-Web-Only-Deploy: approved` trailer. Do not replace SMTP, Core workers, `mailer_web`, or `mailer_horizon`.

- [ ] **Step 4: Recheck the existing production domain**

Run `check_dns(:manual)` for Core domain `venmail.io` ID 18 without regenerating its key. Verify `dkim_status: OK`, `dkim_verified: true`, selector unchanged, and live/stored public-key hashes equal.

- [ ] **Step 5: Verify public endpoints and protected containers**

Confirm `prod.venmail.io` and `m.venmail.io` return HTTP 200, and confirm the protected Mailer and SMTP containers retain their prior image IDs and start times.
