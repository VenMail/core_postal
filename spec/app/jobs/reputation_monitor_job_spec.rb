require 'rails_helper'

RSpec.describe ReputationMonitorJob do
  around do |example|
    old_whitelist = Postal.config.general.respond_to?(:whitelist) ? Postal.config.general.whitelist : nil
    example.run
  ensure
    Postal.config.general.whitelist = old_whitelist
  end

  describe '#find_suspicious_ips' do
    it 'uses the MessageDB-supported spam score comparison operator' do
      message_db = double('message_db')
      server = double('server', :id => 81, :message_db => message_db)
      relation = double('server_relation')

      allow(Server).to receive(:where).with(:suspended_at => nil).and_return(relation)
      allow(relation).to receive(:find_each).and_yield(server)

      expect(message_db).to receive(:select).with(
        'messages',
        hash_including(
          :where => hash_including(
            :spam_score => { :greater_than_or_equal_to => ReputationMonitorJob::SPAM_SCORE_THRESHOLD }
          )
        )
      ).and_return([])

      described_class.new('test-id').send(:find_suspicious_ips, Time.at(0))
    end

    it 'ignores records whose actual spam score is below the blocking threshold' do
      message_db = double('message_db')
      server = double('server', :id => 81, :message_db => message_db)
      relation = double('server_relation')
      records = Array.new(6) do |index|
        {
          'id' => index + 1,
          'external_actor_ip' => '198.51.100.24',
          'spam_score' => 0.0
        }
      end

      allow(Server).to receive(:where).with(:suspended_at => nil).and_return(relation)
      allow(relation).to receive(:find_each).and_yield(server)
      allow(message_db).to receive(:select).and_return(records)

      result = described_class.new('test-id').send(:find_suspicious_ips, Time.at(0))

      expect(result).to be_empty
    end

    it 'groups records whose actual spam score meets the blocking threshold' do
      message_db = double('message_db')
      server = double('server', :id => 81, :message_db => message_db)
      relation = double('server_relation')
      records = Array.new(6) do |index|
        {
          'id' => index + 1,
          'external_actor_ip' => '198.51.100.25',
          'spam_score' => 12.5
        }
      end

      allow(Server).to receive(:where).with(:suspended_at => nil).and_return(relation)
      allow(relation).to receive(:find_each).and_yield(server)
      allow(message_db).to receive(:select).and_return(records)

      result = described_class.new('test-id').send(:find_suspicious_ips, Time.at(0))

      expect(result).to contain_exactly(
        'ip_address' => '198.51.100.25',
        'spam_count' => 6,
        'avg_score' => 12.5,
        'server_id' => 81
      )
    end
  end

  describe '#whitelisted_ip?' do
    it 'uses the configured IPv4 and IPv6 CIDR whitelist' do
      Postal.config.general.whitelist = ['203.0.113.0/24', '2001:db8::/32']
      job = described_class.new('test-id')

      expect(job.send(:whitelisted_ip?, '203.0.113.44')).to eq(true)
      expect(job.send(:whitelisted_ip?, '2001:db8::44')).to eq(true)
      expect(job.send(:whitelisted_ip?, '198.51.100.44')).to eq(false)
    end
  end

  describe '#block_ip_address' do
    it 'never suppresses or firewalls a configured gateway' do
      gateway_ip = '203.0.113.44'
      Postal.config.general.whitelist = ['203.0.113.0/24']
      job = described_class.new('test-id')

      expect(GlobalSuppression).not_to receive(:ban_ip)
      expect(job).not_to receive(:execute_firewall_block)

      job.send(:block_ip_address, gateway_ip, 20, 15.0)
    end

    it 'never firewalls private, loopback, or link-local infrastructure addresses' do
      Postal.config.general.whitelist = []
      job = described_class.new('test-id')

      expect(GlobalSuppression).not_to receive(:ban_ip)
      expect(job).not_to receive(:execute_firewall_block)

      %w[10.0.0.8 127.0.0.1 169.254.10.20 172.18.0.9 192.168.1.8 ::1 fc00::8 fe80::8].each do |ip|
        job.send(:block_ip_address, ip, 20, 15.0)
      end
    end
  end

  it 'stores bounded metadata and emits one model-level event when suspending a credential' do
    credential = create(:credential)
    job = described_class.new('test-job', {})
    allow(job).to receive(:consider_server_suspension_optimized)
    expect(WebhookRequest).to receive(:trigger).with(
      credential.server,
      'CredentialLocked',
      hash_including(
        :credential => hash_including(:uuid => credential.uuid),
        :reason => a_string_including('Smart spam detection')
      )
    ).once

    job.send(
      :suspend_credential_optimized,
      credential,
      credential.server,
      { :count => 12 },
      8.5,
      { 'spam_probability' => 0.91 }
    )

    credential.reload
    expect(credential.hold).to be(true)
    expect(credential.hold_at).not_to be_nil
    expect(credential.hold_reason).to include('Smart spam detection')
    expect(credential.hold_reason.length).to be <= 255
  end
end
