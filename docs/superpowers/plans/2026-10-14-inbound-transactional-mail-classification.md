# Inbound Transactional Mail Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop authenticated provider mail from crossing spam thresholds because of raw transport metadata, related subdomains, or generated envelope senders, without allowlisting providers or weakening independent phishing checks.

**Architecture:** Keep Rspamd's authentication and reputation evaluation unchanged. Give Venmail's internal pre-classifier only decoded visible MIME content, then make its domain and brand comparisons boundary-aware. Validate the correction with the captured Vercel/Amazon SES shape and adversarial near-misses.

**Tech Stack:** Ruby 2.6, Rails, Mail gem, RSpec, Docker, Paramiko-based remote test execution.

---

### Task 1: Reproduce the Vercel false positive on the server

**Files:**
- Modify: `spec/lib/postal/spam_checker_spec.rb`
- Create outside repository: `C:/Users/Son/AppData/Local/Temp/run_vercel_classifier_spec_server.py`

- [ ] **Step 1: Add a failing Vercel/Amazon SES inspector regression**

Append a realistic multipart message example to `spec/lib/postal/spam_checker_spec.rb`. Use a generated `mail.vercel.com` envelope sender, `From: Vercel <system@vercel.com>`, `Reply-To: no-reply@vercel.com`, Amazon SES transport headers, DKIM material, and a short HTML login-code body. Pass it through the real `Postal::MessageInspectors::SpamChecker` and assert that no `V_SPAM` check is produced.

```ruby
it 'does not classify aligned Vercel mail sent through Amazon SES as spam' do
  raw_message = <<~MAIL.gsub("\n", "\r\n")
    Received: from e237-243.smtp-out.us-west-2.amazonses.com (e237-243.smtp-out.us-west-2.amazonses.com [23.251.237.243]) by pxa.mail.venmail.io with SMTP
    DKIM-Signature: v=1; d=vercel.com; s=transactional; b=xAmazonSignatureValue
    From: Vercel <system@vercel.com>
    Reply-To: no-reply@vercel.com
    To: copata@venmail.io
    Subject: 012789 is your Vercel log in code
    MIME-Version: 1.0
    Content-Type: text/html; charset=UTF-8

    <html><body><p>Log in to Vercel with this code:</p><strong>012789</strong></body></html>
  MAIL
  message = double(
    :message,
    :mail_from => '010101a13918262b-bdcdb6bf-e21d-4656-866f-01cd3b545085-000000@mail.vercel.com',
    :raw_message => raw_message,
    :headers => Mail.new(raw_message).header.fields.each_with_object({}) { |field, memo| (memo[field.name.downcase] ||= []) << field.decoded }
  )
  inspection = Struct.new(:message, :spam_checks).new(message, [])

  described_class.new.inspect_message(inspection)

  expect(inspection.spam_checks.map(&:code)).not_to include('V_SPAM')
end
```

- [ ] **Step 2: Add focused failing unit regressions**

Add examples proving the required domain and brand behavior:

```ruby
it 'treats parent and subdomains as related without matching lookalike domains' do
  expect(Postal::SpamChecker.domains_related?('mail.vercel.com', 'vercel.com')).to be(true)
  expect(Postal::SpamChecker.domains_related?('vercel.com.evil.example', 'vercel.com')).to be(false)
end

it 'does not match single-character brands inside ordinary content' do
  score = Postal::SpamChecker.check_brand_domain_mismatch(
    'Login code',
    'Use the next code to log in',
    'mail.vercel.com'
  )
  expect(score).to eq(0)
end

it 'still scores a full impersonated brand from an unrelated domain' do
  score = Postal::SpamChecker.check_brand_domain_mismatch(
    'Amazon account notice',
    'Review your Amazon account',
    'attacker.example'
  )
  expect(score).to be >= 6
end

it 'does not penalize a generated envelope sender aligned with the From domain' do
  score = Postal::SpamChecker.check_random_sender_address(
    '010101a13918262b-bdcdb6bf-e21d-4656-866f-01cd3b545085-000000@mail.vercel.com',
    'system@vercel.com'
  )
  expect(score).to eq(0)
end

it 'still penalizes an unrelated Reply-To domain' do
  headers = ['Reply-To: collect@attacker.example']
  expect(Postal::SpamChecker.check_reply_to_mismatch(headers, 'system@vercel.com')).to eq(8)
end
```

- [ ] **Step 3: Run the new tests against the current production image in an isolated server-side copy**

Create a Paramiko helper that uploads the modified spec, copies `/opt/postal/app` to `/tmp/vercel-classifier` inside `install-web-1`, overlays only the spec in that temporary copy, runs RSpec from the temporary working directory, and removes the temporary copy in `finally`. Do not modify `/opt/postal/app`, restart services, or touch application data.

Run:

```powershell
python C:/Users/Son/AppData/Local/Temp/run_vercel_classifier_spec_server.py
```

Expected: FAIL because `domains_related?` does not exist and the real Vercel-shaped message produces `V_SPAM`.

### Task 2: Make domain and brand evidence precise

**Files:**
- Modify: `lib/postal/spam_checker.rb`
- Test: `spec/lib/postal/spam_checker_spec.rb`

- [ ] **Step 1: Add normalized relationship helpers**

Add deterministic, lookup-free helpers under `class << self`:

```ruby
def normalize_domain(domain)
  domain.to_s.downcase.sub(/\.+\z/, '')
end

def domain_or_subdomain?(candidate, parent)
  candidate = normalize_domain(candidate)
  parent = normalize_domain(parent)
  return false if candidate.empty? || parent.empty?

  candidate == parent || candidate.end_with?(".#{parent}")
end

def domains_related?(left, right)
  domain_or_subdomain?(left, right) || domain_or_subdomain?(right, left)
end

def extract_email_address(value)
  value.to_s[EMAIL_REGEX]
end
```

- [ ] **Step 2: Make brand matching boundary-aware**

In `check_brand_domain_mismatch`, ignore brand values shorter than two characters and require non-alphanumeric boundaries around the brand text:

```ruby
IMPERSONATED_BRANDS.each do |brand|
  next if brand.length < 2
  next unless text.match?(/(?<![a-z0-9])#{Regexp.escape(brand)}(?![a-z0-9])/i)

  domain_contains_brand = sender_domain.include?(brand)
  # retain the existing legitimate-variant evaluation
end
```

This keeps full-token `Amazon` detection while preventing `x` from matching arbitrary prose and preventing `amazon` from matching `amazonses.com` as message content once Task 3 isolates MIME content.

- [ ] **Step 3: Treat aligned envelope and header domains as related**

Change `check_random_sender_address` to accept an optional reference sender and skip random-local-part points only when the domains are related:

```ruby
def check_random_sender_address(sender_email, reference_email = nil)
  sender_domain = extract_domain_from_email(sender_email)
  reference_domain = extract_domain_from_email(reference_email)
  return 0 if domains_related?(sender_domain, reference_domain)

  # existing local-part checks follow unchanged
end
```

Use `domains_related?` in `check_reply_to_mismatch` instead of exact hostname equality. In `classify_email`, extract the From address and provide it to the random-sender check:

```ruby
from_header = headers.find { |header| header.match?(/^From:/i) }
from_email = extract_email_address(from_header)
random_sender_score = check_random_sender_address(sender_email, from_email)
```

- [ ] **Step 4: Re-run the focused server-side spec**

Overlay `lib/postal/spam_checker.rb` and the modified spec in the isolated `/tmp/vercel-classifier` application copy.

Run:

```powershell
python C:/Users/Son/AppData/Local/Temp/run_vercel_classifier_spec_server.py
```

Expected: domain, brand, random-sender, and unrelated Reply-To unit examples PASS; the end-to-end Vercel example remains FAIL until MIME extraction is corrected.

### Task 3: Classify decoded visible MIME content

**Files:**
- Modify: `lib/postal/message_inspectors/spam_checker.rb`
- Modify: `spec/lib/postal/spam_checker_spec.rb`

- [ ] **Step 1: Add an explicit transport-header isolation assertion**

Add an inspector example whose transport headers contain `amazon`, long signatures, and other random tokens while its visible body is benign. Assert no `V_SPAM` result. The Vercel regression from Task 1 supplies the end-to-end case; add a direct extraction example to document the boundary:

```ruby
it 'classifies decoded visible content without transport headers' do
  inspector = described_class.new
  raw_message = "DKIM-Signature: xamazonvalue\r\nContent-Type: text/plain\r\n\r\nNormal account notice"

  expect(inspector.send(:visible_content, raw_message)).to eq('Normal account notice')
end
```

Run the focused server helper before implementation.

Expected: FAIL because `visible_content` does not exist.

- [ ] **Step 2: Implement MIME content extraction in the inspector**

Replace the raw-message classifier input with decoded visible content and add private extraction helpers:

```ruby
def inspect_message(inspection)
  message = inspection.message
  raw_message = message.raw_message
  content = visible_content(raw_message)
  # build headers_array and subject as before
  spam_score = Postal::SpamChecker.classify_email(
    message.mail_from,
    content,
    headers_array,
    subject
  )
  # preserve existing score handling and rescue behavior
end

private

def visible_content(raw_message)
  mail = Mail.new(raw_message.to_s)
  part = if mail.multipart?
    mail.html_part || mail.text_part
  else
    mail
  end
  return '' unless part
  return '' if part.respond_to?(:attachment?) && part.attachment?

  part.decoded.to_s.dup.force_encoding('UTF-8').scrub
rescue StandardError
  raw_message.to_s.split(/\r?\n\r?\n/, 2).last.to_s.dup.force_encoding('UTF-8').scrub
end
```

- [ ] **Step 3: Clarify the approved design wording**

In `docs/superpowers/specs/2026-10-14-inbound-transactional-mail-classification-design.md`, state that related envelope/From domains avoid a weak formatting penalty while verified authentication remains exclusively Rspamd's responsibility. Do not claim that the pre-classifier independently authenticates From.

- [ ] **Step 4: Run focused tests on the server**

Overlay both modified library files and the spec in `/tmp/vercel-classifier`, then run:

```powershell
python C:/Users/Son/AppData/Local/Temp/run_vercel_classifier_spec_server.py
```

Expected: all examples in `spec/lib/postal/spam_checker_spec.rb` PASS, including the existing legal-beneficiary scam regression.

- [ ] **Step 5: Commit the implementation**

```powershell
git add lib/postal/spam_checker.rb lib/postal/message_inspectors/spam_checker.rb spec/lib/postal/spam_checker_spec.rb docs/superpowers/specs/2026-10-14-inbound-transactional-mail-classification-design.md
git commit -m "fix: avoid transactional mail spam false positives"
```

### Task 4: Remote verification and delivery handoff

**Files:**
- Verify: `spec/lib/postal/spam_checker_spec.rb`
- Verify: `.github/workflows/ci.yml`

- [ ] **Step 1: Run the entire relevant server-side spec directory**

Extend the Paramiko helper to run `spec/lib/postal/spam_checker_spec.rb` from the isolated temporary application copy with the changed source files overlaid.

Expected: PASS with no warnings or errors.

- [ ] **Step 2: Check the final diff and repository state**

```powershell
git diff --check origin/main...HEAD
git status --short
git log --oneline origin/main..HEAD
```

Expected: no whitespace errors; only the design, plan, classifier, inspector, and focused spec are changed; the worktree is clean after commits.

- [ ] **Step 3: Push the branch and use remote CI for the full suite**

```powershell
git push -u origin codex/vercel-inbound-false-positive
```

Watch the branch's `CI / Test` workflow. Expected: PASS. A failing full suite blocks merge and deployment.

- [ ] **Step 4: Review before integration**

Inspect the final diff for scoring bypasses, especially lookalike domains, unrelated Reply-To addresses, single-character brand handling, attachment exclusion, and MIME parse fallback. Confirm that no provider allowlist or threshold increase was introduced.

- [ ] **Step 5: Prepare deployment separately**

Create and attach a pull request only with explicit user authorization or existing authorization that clearly covers push/merge. A merge to `main` builds an immutable image but does not automatically perform the required full Core rollout. Do not restart or recreate production services without separate explicit authorization.
