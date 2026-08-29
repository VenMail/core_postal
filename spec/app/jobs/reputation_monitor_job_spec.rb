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
end
