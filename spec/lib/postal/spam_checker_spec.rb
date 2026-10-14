require 'rails_helper'

describe Postal::SpamChecker do
  let(:headers) do
    [
      'Received: from [204.10.162.167] (::ffff:204.10.162.167 [::ffff:204.10.162.167]) by pxa.mail.venmail.io with SMTP; Tue, 19 May 2026 11:53:36 +0000',
      'From: "Mr.Alexander Hallet Esq" <Alex@bammby.com>',
      'Reply-To: alexnhalletesq@outlook.com',
      'To: williamhowland@gmail.com',
      'Subject: Re: Attn Beneficiary'
    ]
  end

  let(:body) do
    <<~BODY
      Our firm administers the estate of a deceased client in which you may hold a beneficiary interest, and we require that you confirm your relationship to the deceased and declare your interest in pursuing entitlement by 2026-05-29. Failure to respond by this deadline may result in asset distribution to verified claimants in accordance with probate laws. This communication is confidential under attorney-client privilege and GDPR; please reply to the Legal Advisor's email provided.

      Reply to: Legal Advisor's Email.

      Sincerely,

      Alex N. Hallet Esq.
      International Legal Advisor & Senior Partner
      Howells & Hallet Solicitors UK.
    BODY
  end

  it 'scores legal beneficiary scam messages as high-confidence spam' do
    score = described_class.classify_email('Alex@bammby.com', body, headers, 'Re: Attn Beneficiary')

    expect(score).to be >= described_class::HIGH_CONFIDENCE_SPAM_SCORE
  end

  it 'treats parent and subdomains as related without matching lookalike domains' do
    expect(described_class.domains_related?('mail.vercel.com', 'vercel.com')).to be(true)
    expect(described_class.domains_related?('vercel.com.evil.example', 'vercel.com')).to be(false)
  end

  it 'normalizes domains and extracts email addresses deterministically' do
    expect(described_class.normalize_domain('MAIL.VERCEL.COM...')).to eq('mail.vercel.com')
    expect(described_class.domain_or_subdomain?('mail.vercel.com', 'VERCEL.COM.')).to be(true)
    expect(described_class.domain_or_subdomain?('vercel.com.evil.example', 'vercel.com')).to be(false)
    expect(described_class.extract_email_address('Vercel <system@vercel.com>')).to eq('system@vercel.com')
  end

  it 'does not match single-character brands inside ordinary content' do
    score = described_class.check_brand_domain_mismatch(
      'Login code',
      'Use the next code to log in',
      'mail.vercel.com'
    )

    expect(score).to eq(0)
  end

  it 'still scores a full impersonated brand from an unrelated domain' do
    score = described_class.check_brand_domain_mismatch(
      'Amazon account notice',
      'Review your Amazon account',
      'attacker.example'
    )

    expect(score).to be >= 6
  end

  it 'does not score an impersonated brand inside an alphanumeric token' do
    score = described_class.check_brand_domain_mismatch(
      'Amazonian account notice',
      'Review your Amazonian account',
      'attacker.example'
    )

    expect(score).to eq(0)
  end

  it 'scores Amazon lookalike sender domains as mismatches' do
    ['amazon-login.attacker.example', 'notamazon.com.evil', 'getamazonsupport.com'].each do |sender_domain|
      score = described_class.check_brand_domain_mismatch(
        'Amazon account notice',
        'Review your Amazon account',
        sender_domain
      )

      expect(score).to be >= 6
    end
  end

  it 'allows a legitimate brand subdomain' do
    score = described_class.check_brand_domain_mismatch(
      'Amazon account notice',
      'Review your Amazon account',
      'mail.amazon.com'
    )

    expect(score).to eq(0)
  end

  it 'allows Amazon ccTLD subdomains through its canonical ownership map' do
    amazon_roots = %w[
      amazon.com amazon.ca amazon.com.mx amazon.com.br amazon.co.uk amazon.de
      amazon.fr amazon.it amazon.es amazon.nl amazon.pl amazon.se amazon.com.be
      amazon.co.jp amazon.com.au amazon.in amazon.sg amazon.ae amazon.sa amazon.eg
      amazon.com.tr
    ]

    amazon_roots.each do |root|
      [root, "mail.#{root}"].each do |sender_domain|
        score = described_class.check_brand_domain_mismatch(
          'Amazon account notice',
          'Review your Amazon account',
          sender_domain
        )

        expect(score).to eq(0)
      end
    end
  end

  it 'scores unlisted Amazon-shaped domains as mismatches' do
    ['amazon.xyz', 'mail.amazon.xyz'].each do |sender_domain|
      score = described_class.check_brand_domain_mismatch(
        'Amazon account notice',
        'Review your Amazon account',
        sender_domain
      )

      expect(score).to be >= 6
    end
  end

  it 'maps every impersonated brand to immutable canonical domains' do
    expect(described_class::BRAND_CANONICAL_DOMAINS.keys).to match_array(described_class::IMPERSONATED_BRANDS)
    expect(described_class::BRAND_CANONICAL_DOMAINS).to be_frozen
    expect(described_class::BRAND_CANONICAL_DOMAINS.values).to all(be_frozen)
  end

  it 'does not penalize a generated envelope sender aligned with the From domain' do
    score = described_class.check_random_sender_address(
      '010101a13918262b-bdcdb6bf-e21d-4656-866f-01cd3b545085-000000@mail.vercel.com',
      'system@vercel.com',
      true
    )

    expect(score).to eq(0)
  end

  it 'retains the random sender score when its reference domain is unrelated' do
    score = described_class.check_random_sender_address(
      '010101a13918262b-bdcdb6bf-e21d-4656-866f-01cd3b545085-000000@mail.vercel.com',
      'system@attacker.example'
    )

    expect(score).to be > 0
  end

  it 'still penalizes an unrelated Reply-To domain' do
    headers = ['Reply-To: collect@attacker.example']

    expect(described_class.check_reply_to_mismatch(headers, 'system@vercel.com')).to eq(8)
  end

  it 'does not penalize a Reply-To address on a related subdomain' do
    headers = ['Reply-To: no-reply@mail.vercel.com']

    expect(described_class.check_reply_to_mismatch(headers, 'system@vercel.com')).to eq(0)
  end

  it 'keeps generated sender scoring when a related From address is unverified' do
    envelope_sender = '010101a13918262b-bdcdb6bf-e21d-4656-866f-01cd3b545085-000000@mail.vercel.com'
    headers = ['From: Vercel <system@vercel.com>']

    score = described_class.classify_email(
      envelope_sender,
      'Your sign-in code is 012789.',
      headers,
      'Vercel sign-in code'
    )

    expect(score).to be >= 5
  end

  it 'uses the parsed related From address only after DMARC authentication' do
    envelope_sender = '010101a13918262b-bdcdb6bf-e21d-4656-866f-01cd3b545085-000000@mail.vercel.com'
    headers = ['From: Vercel <system@vercel.com>']

    expect(described_class.check_random_sender_address(envelope_sender, 'system@vercel.com', true)).to eq(0)

    score = described_class.classify_email(
      envelope_sender,
      'Your sign-in code is 012789.',
      headers,
      'Vercel sign-in code',
      true
    )

    expect(score).to eq(1)
    expect(score).to be < 5
  end
end

describe Postal::MessageInspector do
  it 'runs Rspamd before the internal SpamChecker' do
    general = double(:general, :spam_check_enabled => true)
    rspamd = double(:rspamd, :enabled => true)
    config = double(:config, :general => general, :rspamd => rspamd, :spamd => nil, :clamav => nil)
    allow(Postal).to receive(:config).and_return(config)

    expect(described_class.inspectors.map(&:class)).to eq([
      Postal::MessageInspectors::Rspamd,
      Postal::MessageInspectors::SpamChecker
    ])
  end
end

describe Postal::MessageInspectors::SpamChecker do
  def record_rspamd_dmarc_allow(inspection)
    rspamd = Postal::MessageInspectors::Rspamd.new(double(:rspamd_config))
    response = double(
      :response,
      :body => JSON.generate('symbols' => {
        'DMARC_POLICY_ALLOW' => {
          'name' => 'DMARC_POLICY_ALLOW',
          'score' => 0,
          'description' => 'DMARC policy allows sender'
        }
      })
    )
    allow(rspamd).to receive(:request).and_return(response)

    rspamd.inspect_message(inspection)
  end

  it 'extracts decoded visible HTML content without transport headers or attachments' do
    raw_message = <<~MAIL.gsub("\n", "\r\n")
      Received: from Amazon transport.example
      X-Provider: Amazon
      DKIM-Signature: v=1; b=Amazon
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="outer"

      --outer
      Content-Type: multipart/alternative; boundary="inner"

      --inner
      Content-Type: text/plain; charset=UTF-8
      Content-Transfer-Encoding: quoted-printable

      Plain=20visible=20content
      --inner
      Content-Type: text/html; charset=UTF-8
      Content-Transfer-Encoding: quoted-printable

      <p>Visible=20HTML=20content</p>
      --inner--
      --outer
      Content-Type: text/plain; name="receipt.txt"
      Content-Disposition: attachment; filename="receipt.txt"
      Content-Transfer-Encoding: quoted-printable

      Amazon=20attachment=20content
      --outer--
    MAIL

    content = described_class.new.send(:visible_content, raw_message)

    expect(content).to include('Visible HTML content')
    expect(content).not_to include('Amazon')
    expect(content).not_to include('Plain visible content')
  end

  it 'falls back to the body section when MIME parsing fails' do
    raw_message = "X-Provider: Amazon\r\nDKIM-Signature: Amazon\r\n\r\nVisible fallback body"
    allow(Mail).to receive(:read_from_string).and_raise(Mail::Field::ParseError, 'invalid MIME')

    content = described_class.new.send(:visible_content, raw_message)

    expect(content).to eq('Visible fallback body')
    expect(content).not_to include('Amazon')
  end

  it 'retains an inline named text part while excluding a filename-free attachment' do
    raw_message = <<~MAIL.gsub("\n", "\r\n")
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="boundary"

      --boundary
      Content-Type: text/plain; charset=UTF-8; name="notice.txt"
      Content-Disposition: inline; filename="notice.txt"

      Visible inline content
      --boundary
      Content-Type: text/plain; charset=UTF-8
      Content-Disposition: attachment

      Amazon attachment content
      --boundary--
    MAIL

    content = described_class.new.send(:visible_content, raw_message)

    expect(content).to include('Visible inline content')
    expect(content).not_to include('Amazon')
  end

  it 'excludes a filename-only attachment without an explicit inline disposition' do
    raw_message = <<~MAIL.gsub("\n", "\r\n")
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="boundary"

      --boundary
      Content-Type: text/plain; charset=UTF-8; name="receipt.txt"

      Amazon filename-only attachment content
      --boundary--
    MAIL

    expect(described_class.new.send(:visible_content, raw_message)).to eq('')
  end

  it 'drops multipart fallback content after an actual transfer-decoding failure' do
    raw_message = <<~MAIL.gsub("\n", "\r\n")
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="boundary"

      --boundary
      Content-Type: text/html; charset=UTF-8
      Content-Transfer-Encoding: x-invalid-encoding

      Visible undecodable content
      --boundary
      Content-Type: text/plain; charset=UTF-8
      Content-Disposition: attachment

      Amazon attachment content
      --boundary--
    MAIL

    decoded_part = Mail.read_from_string(raw_message).all_parts.find { |part| part.mime_type == 'text/html' }
    expect { decoded_part.decoded }.to raise_error(Mail::UnknownEncodingType)
    expect(described_class.new.send(:visible_content, raw_message)).to eq('')
  end

  it 'bounds the safe fallback body when MIME parsing fails' do
    raw_message = "X-Provider: Amazon\r\n\r\n#{'a' * (Postal::SpamChecker::MAX_BODY_SIZE + 1)}"
    allow(Mail).to receive(:read_from_string).and_raise(Mail::Field::ParseError, 'invalid MIME')

    content = described_class.new.send(:visible_content, raw_message)

    expect(content.length).to eq(Postal::SpamChecker::MAX_BODY_SIZE)
    expect(content).not_to include('Amazon')
  end

  it 'drops fallback content with top-level filename attachment metadata' do
    raw_message = <<~MAIL.gsub("\n", "\r\n")
      MIME-Version: 1.0
      Content-Type: text/plain; charset=UTF-8; name="receipt.txt"
      Content-Transfer-Encoding: x-invalid-encoding

      Amazon filename-only attachment content
    MAIL

    expect { Mail.read_from_string(raw_message).decoded }.to raise_error(Mail::UnknownEncodingType)
    expect(described_class.new.send(:visible_content, raw_message)).to eq('')

    allow(Mail).to receive(:read_from_string).and_raise(Mail::Field::ParseError, 'invalid MIME')
    expect(described_class.new.send(:visible_content, raw_message)).to eq('')
  end

  it 'drops a decode-failure fallback with a folded top-level multipart Content-Type' do
    raw_message = <<~MAIL.gsub("\n", "\r\n")
      MIME-Version: 1.0
      Content-Type:
       multipart/mixed; boundary="boundary"

      --boundary
      Content-Type: text/html; charset=UTF-8
      Content-Transfer-Encoding: x-invalid-encoding

      Visible undecodable content
      --boundary--
    MAIL

    decoded_part = Mail.read_from_string(raw_message).all_parts.find { |part| part.mime_type == 'text/html' }
    expect { decoded_part.decoded }.to raise_error(Mail::UnknownEncodingType)
    expect(described_class.new.send(:visible_content, raw_message)).to eq('')
  end

  it 'drops a decode-failure fallback with a folded top-level attachment disposition' do
    raw_message = <<~MAIL.gsub("\n", "\r\n")
      MIME-Version: 1.0
      Content-Type: text/plain; charset=UTF-8
      Content-Disposition:
       attachment
      Content-Transfer-Encoding: x-invalid-encoding

      Amazon attachment content
    MAIL

    expect { Mail.read_from_string(raw_message).decoded }.to raise_error(Mail::UnknownEncodingType)
    expect(described_class.new.send(:visible_content, raw_message)).to eq('')

    allow(Mail).to receive(:read_from_string).and_raise(Mail::Field::ParseError, 'invalid MIME')
    expect(described_class.new.send(:visible_content, raw_message)).to eq('')
  end

  it 'excludes visible descendants of an attachment-bearing multipart wrapper' do
    raw_message = <<~MAIL.gsub("\n", "\r\n")
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="outer"

      --outer
      Content-Type: multipart/alternative; boundary="inner"
      Content-Disposition: attachment

      --inner
      Content-Type: text/html; charset=UTF-8

      <p>Amazon nested attachment content</p>
      --inner--
      --outer--
    MAIL

    expect(described_class.new.send(:visible_content, raw_message)).to eq('')
  end

  it 'passes high-confidence internal scores through without halving them' do
    message = double(
      :message,
      :mail_from => 'alex@bammby.com',
      :raw_message => 'body',
      :headers => { 'subject' => ['Test'] }
    )
    inspection = Struct.new(:message, :spam_checks).new(message, [])

    allow(Postal::SpamChecker).to receive(:classify_email).and_return(20.0)

    described_class.new.inspect_message(inspection)

    expect(inspection.spam_checks.first.code).to eq('V_SPAM')
    expect(inspection.spam_checks.first.score).to eq(20.0)
  end

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
    inspection = Postal::MessageInspection.new(message, :incoming)
    record_rspamd_dmarc_allow(inspection)

    described_class.new.inspect_message(inspection)

    expect(inspection.rspamd_dmarc_policy_allow?).to be(true)
    expect(inspection.spam_checks.map(&:code)).not_to include('V_SPAM')
    expect(inspection.spam_checks.map(&:code)).not_to include('ERROR')
  end

  it 'does not classify authenticated Vercel mail as spam from a standalone Amazon transport header' do
    raw_message = <<~MAIL.gsub("\n", "\r\n")
      Received: from outbound.vercel.com by pxa.mail.venmail.io with SMTP
      X-Provider: Amazon
      DKIM-Signature: v=1; d=vercel.com; s=transactional; b=signature
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
    inspection = Postal::MessageInspection.new(message, :incoming)
    record_rspamd_dmarc_allow(inspection)

    described_class.new.inspect_message(inspection)

    expect(inspection.rspamd_dmarc_policy_allow?).to be(true)
    expect(inspection.spam_checks.map(&:code)).not_to include('V_SPAM')
    expect(inspection.spam_checks.map(&:code)).not_to include('ERROR')
  end

  it 'classifies the same Vercel-shaped mail as spam without a verified DMARC check' do
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
    inspection = Postal::MessageInspection.new(message, :incoming)
    inspection.spam_checks << Postal::SpamCheck.new('DMARC_POLICY_ALLOW', 0, 'Generic rule')

    described_class.new.inspect_message(inspection)

    expect(inspection.spam_checks.map(&:code)).to include('V_SPAM')
    expect(inspection.spam_checks.map(&:code)).not_to include('ERROR')
  end

  it 'fails closed when a scanner error or timeout accompanies an Rspamd DMARC allow result' do
    message = double(
      :message,
      :mail_from => '010101a13918262b-bdcdb6bf-e21d-4656-866f-01cd3b545085-000000@mail.vercel.com',
      :raw_message => 'Your sign-in code is 012789.',
      :headers => {
        'from' => ['Vercel <system@vercel.com>'],
        'subject' => ['Vercel sign-in code']
      }
    )
    ['ERROR', 'TIMEOUT'].each do |failure_code|
      inspection = Postal::MessageInspection.new(message, :incoming)
      record_rspamd_dmarc_allow(inspection)
      inspection.spam_checks << Postal::SpamCheck.new(failure_code, 0, 'Scanner unavailable')

      described_class.new.inspect_message(inspection)

      expect(inspection.spam_checks.map(&:code)).to include('V_SPAM')
    end
  end
end
