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
end
