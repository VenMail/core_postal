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

end
