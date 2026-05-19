require 'rails_helper'

describe Postal::CompromiseDetector do

  it "does not flag generic deadline text as compromise" do
    with_global_server do |server|
      message = create_plain_text_message(server, 'Please review this within 24 hours. Thanks!', 'test@example.com')
      detector = Postal::CompromiseDetector.new
      result = detector.analyze(message)
      expect(result.codes).not_to include('COMPROMISE_BLACKMAIL')
      expect(result.strong?).to be false
    end
  end

  it "flags blackmail only when payment signal is present" do
    with_global_server do |server|
      body = "I hacked you and recorded you. Pay bitcoin bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080 within 24 hours"
      message = create_plain_text_message(server, body, 'test@example.com')
      detector = Postal::CompromiseDetector.new
      result = detector.analyze(message)
      expect(result.codes).to include('COMPROMISE_BLACKMAIL')
      expect(result.codes).to include('COMPROMISE_BITCOIN')
      expect(result.strong?).to be true
    end
  end

  it "does not flag inline base64 image-only html as base64 blob" do
    with_global_server do |server|
      html = "<html><body><img src=\"data:image/png;base64,#{'A' * 800}\" /></body></html>"
      message = create_plain_text_message(server, '', 'test@example.com', { html_body: html })
      detector = Postal::CompromiseDetector.new
      result = detector.analyze(message)
      expect(result.codes).not_to include('COMPROMISE_BASE64_BLOB')
    end
  end

  it "flags social security themed content from non-authoritative domains" do
    with_global_server do |server|
      body = <<~BODY
        Social Security Benefit Statement Created
        Generated on 09/01/2026

        Dear Beneficiary (reneeu@roadrunner.com),

        This is your official 2025 SSA-1099 form from the Social Security Administration. It securely details benefits paid, Medicare deductions, and taxable amounts.
      BODY

      message = create_plain_text_message(
        server,
        body,
        'victim@example.com',
        { subject: 'Your Social Security Benefit Statement', from: 'ssa-updates@example.com' }
      )

      detector = Postal::CompromiseDetector.new
      result = detector.analyze(message)

      expect(result.codes).to include('COMPROMISE_SOCIAL_SECURITY_SPOOF')
      expect(result.suspicious?).to be true
      expect(result.strong?).to be false
    end
  end

  it "does not flag social security content from authoritative .gov sender" do
    with_global_server do |server|
      body = "Official notice from the Social Security Administration about your SSA-1099 form."
      message = create_plain_text_message(
        server,
        body,
        'victim@example.com',
        { subject: 'SSA-1099 Notice', from: 'no-reply@ssa.gov' }
      )

      detector = Postal::CompromiseDetector.new
      result = detector.analyze(message)

      expect(result.codes).not_to include('COMPROMISE_SOCIAL_SECURITY_SPOOF')
    end
  end

  it "flags broader government-claim content (IRS/benefits) from non-government domains" do
    with_global_server do |server|
      body = <<~BODY
        Internal Revenue Service notification of tax refund eligibility.
        Call 1-800-772-1213 to claim your stimulus payment.
      BODY

      message = create_plain_text_message(
        server,
        body,
        'victim@example.com',
        { subject: 'IRS Tax Refund Notice', from: 'refunds@irs-support.com' }
      )

      detector = Postal::CompromiseDetector.new
      result = detector.analyze(message)

      expect(result.codes).to include('COMPROMISE_SOCIAL_SECURITY_SPOOF')
      expect(result.suspicious?).to be true
    end
  end

  it "flags legal beneficiary advance-fee scam content as strong compromise" do
    with_global_server do |server|
      body = <<~BODY
        Our firm administers the estate of a deceased client in which you may hold a beneficiary interest.
        Please confirm your relationship to the deceased and declare your interest in pursuing entitlement.
        Failure to respond may result in asset distribution under probate laws. This communication is confidential under attorney-client privilege and GDPR; please reply to the Legal Advisor's email.
      BODY

      message = create_plain_text_message(
        server,
        body,
        'victim@example.com',
        { subject: 'Re: Attn Beneficiary', from: 'alex@bammby.com' }
      )

      detector = Postal::CompromiseDetector.new
      result = detector.analyze(message)

      expect(result.codes).to include('COMPROMISE_LEGAL_BENEFICIARY')
      expect(result.strong?).to be true
    end
  end
end
