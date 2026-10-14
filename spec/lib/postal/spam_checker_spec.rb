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

  it 'does not penalize a generated envelope sender aligned with the From domain' do
    score = described_class.check_random_sender_address(
      '010101a13918262b-bdcdb6bf-e21d-4656-866f-01cd3b545085-000000@mail.vercel.com',
      'system@vercel.com'
    )

    expect(score).to eq(0)
  end

  it 'still penalizes an unrelated Reply-To domain' do
    headers = ['Reply-To: collect@attacker.example']

    expect(described_class.check_reply_to_mismatch(headers, 'system@vercel.com')).to eq(8)
  end
end

describe Postal::MessageInspectors::SpamChecker do
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
    inspection = Struct.new(:message, :spam_checks).new(message, [])

    described_class.new.inspect_message(inspection)

    expect(inspection.spam_checks.map(&:code)).not_to include('V_SPAM')
    expect(inspection.spam_checks.map(&:code)).not_to include('ERROR')
  end
end
