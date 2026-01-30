#!/usr/bin/env ruby

# Load the spam checker directly
require_relative 'lib/postal/spam_checker'

# Mock Postal logger for testing
module Postal
  def self.logger_for(type)
    Logger.new(STDOUT)
  end
end

class Logger
  def info(message)
    puts "[LOG] #{message}"
  end
end

# Test the enhanced spam checker with the sample spam message
def test_enhanced_spam_checker
  puts "=== Testing Enhanced Spam Checker ==="
  
  # Sample headers from the spam message
  headers = [
    "X-Venmail-MsgID: mmEUot4CAKPj",
    "Received: from [185.196.9.195] (::ffff:185.196.9.195 [::ffff:185.196.9.195]) by pxa.mail.venmail.io with SMTP; Fri, 30 Jan 2026 14:37:41 -0000",
    "Content-Type: multipart/alternative; boundary=\"===============6346151756094622001==\"",
    "MIME-Version: 1.0",
    "Subject: Shipment Confirmation Address|7094538",
    "From: \"(Global Customer Service)\" <taskcase@venmail.io>",
    "To: krnwahl37@yahoo.com",
    "X-Priority: 1",
    "Priority: urgent",
    "Importance: high",
    "Message-ID: <d22347ecfe124f698317ad2f0a8c744b.1769783860417@venmail.io>",
    "Date: Fri, 30 Jan 2026 08:37:40 -0600",
    "X-Postal-Loop: pxa.mail.venmail.io"
  ]
  
  subject = "Shipment Confirmation Address|7094538"
  sender_email = "taskcase@venmail.io"
  
  # Read the HTML content
  html_content = File.read('decoded-spam.html')
  
  puts "Testing with spam message:"
  puts "From: #{sender_email}"
  puts "Subject: #{subject}"
  puts "Headers count: #{headers.length}"
  puts
  
  # Test individual detection methods
  puts "=== Individual Detection Tests ==="
  
  # Test From name/email mismatch
  from_header = headers.find { |h| h.match?(/^From:/i) }
  mismatch_score = Postal::SpamChecker.check_from_name_email_mismatch(from_header)
  puts "From name/email mismatch score: #{mismatch_score}"
  
  # Test restricted domain priority
  from_domain = Postal::SpamChecker.extract_domain_from_email(sender_email)
  restricted_score = Postal::SpamChecker.check_restricted_domain_priority(headers, from_domain)
  puts "Restricted domain priority score: #{restricted_score}"
  
  # Test suspicious confirmation phrases
  confirmation_score = Postal::SpamChecker.check_suspicious_confirmation_phrases(subject, html_content)
  puts "Suspicious confirmation phrases score: #{confirmation_score}"
  
  puts
  puts "=== Overall Spam Classification ==="
  
  # Test full classification
  score = Postal::SpamChecker.classify_email(sender_email, html_content, headers, subject)
  puts "Final spam score: #{score}"
  puts "Classification: #{score > 5 ? 'SPAM' : 'LIKELY HAM'}"
  
  puts
  puts "=== Rate Limiting Test ==="
  
  # Simulate multiple identical headers (rate limiting test)
  puts "Simulating 6 identical header sets in 5 seconds..."
  6.times do |i|
    headers_fingerprint = headers.sort.join('|')
    frequency = Postal::SpamChecker.track_header_fingerprint(headers_fingerprint)
    puts "Attempt #{i+1}: Current frequency = #{frequency}"
    sleep(0.1) # Small delay to simulate rapid sending
  end
  
  # Test classification again to see rate limiting effect
  puts
  puts "Testing classification after rate limiting trigger:"
  final_score = Postal::SpamChecker.classify_email(sender_email, html_content, headers, subject)
  puts "Final spam score with rate limiting: #{final_score}"
  puts "Classification: #{final_score > 5 ? 'SPAM' : 'LIKELY HAM'}"
  
  puts
  puts "=== Test Complete ==="
end

# Run the test
test_enhanced_spam_checker if __FILE__ == $0
