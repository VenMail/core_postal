# frozen_string_literal: true

require 'rails_helper'

describe Postal::DKIMHeader do

  examples = Rails.root.join('spec/examples/dkim_signing/*.msg')
  Dir[examples].each do |path|
    contents = File.read(path)
    # puts "DEBUG: Contents length: #{contents.length}"
    # puts "DEBUG: Contains ---\\n: #{contents.include?("---\n")}"
    parts = contents.split(/^---\r?\n/m, 2)
    # puts "DEBUG: Parts length: #{parts.length}"
    frontmatter = YAML.load(parts[0])
    email = (parts[1] || '').strip
    it "works with #{path.split('/').last}" do
      mocked_time = Time.at(frontmatter['time'].to_i)
      allow(Time).to receive(:now).and_return(mocked_time)

      domain = instance_double('Domain')
      allow(domain).to receive(:dkim_verified?).and_return(true)
      allow(domain).to receive(:name).and_return(frontmatter['domain'])
      allow(domain).to receive(:dkim_key).and_return(OpenSSL::PKey::RSA.new(frontmatter['private_key']))
      allow(domain).to receive(:dkim_identifier).and_return(frontmatter['dkim_identifier'])

      expectation = "DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed;\r\n"  \
                    "\td=#{frontmatter['domain']};\r\n" \
                    "\ts=#{frontmatter['dkim_identifier']}; t=#{mocked_time.to_i};\r\n" \
                    "\tbh=#{frontmatter['bh']};\r\n"\
                    "\th=#{frontmatter['headers']};\r\n" \
                    "\tb=#{frontmatter['b'].scan(/.{1,72}/).join("\r\n\t")}"

      header = described_class.new(domain, email)

      expect(header.dkim_header).to eq expectation
    end
  end

  it 'uses fallback signing when a domain is not currently DKIM verified' do
    domain = instance_double('Domain')
    allow(domain).to receive(:dkim_verified?).and_return(false)

    header = described_class.new(domain, "From: sender@example.com\r\nSubject: Test\r\n\r\nBody")

    expect { header.dkim_header }.not_to raise_error
    expect(header.dkim_header).to include("d=#{Postal.config.dns.return_path};")
    expect(header.dkim_header).to include("s=venmail;")
  end

end
