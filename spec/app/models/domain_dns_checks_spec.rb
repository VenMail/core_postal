require 'spec_helper'

describe Domain, '#check_dkim_record' do
  it 'accepts a chunked DNS TXT record when its DKIM public key matches' do
    domain = create(:domain, :owner => create(:server))
    public_dkim = domain.api_public_dkim_payload
    dns_record = public_dkim.fetch(:record).sub(/(p=.{80})/, '\\1 ')
    resolver = instance_double(Resolv::DNS)
    txt_record = instance_double(Resolv::DNS::Resource::IN::TXT, :data => dns_record)

    allow(domain).to receive(:resolver).and_return(resolver)
    allow(resolver).to receive(:getresources)
      .with("#{public_dkim.fetch(:record_name)}.#{domain.name}", Resolv::DNS::Resource::IN::TXT)
      .and_return([txt_record])

    expect(domain.check_dkim_record).to be(true)
    expect(domain.dkim_status).to eq('OK')
    expect(domain.dkim_error).to be_nil
  end

  it 'rejects a DNS TXT record with different DKIM key material' do
    domain = create(:domain, :owner => create(:server))
    other_domain = create(:domain, :owner => domain.owner)
    public_dkim = domain.api_public_dkim_payload
    resolver = instance_double(Resolv::DNS)
    txt_record = instance_double(
      Resolv::DNS::Resource::IN::TXT,
      :data => other_domain.api_public_dkim_payload.fetch(:record)
    )

    allow(domain).to receive(:resolver).and_return(resolver)
    allow(resolver).to receive(:getresources)
      .with("#{public_dkim.fetch(:record_name)}.#{domain.name}", Resolv::DNS::Resource::IN::TXT)
      .and_return([txt_record])

    domain.check_dkim_record
    expect(domain.dkim_status).to eq('Invalid')
    expect(domain.dkim_error).to include('does not match')
  end
end
