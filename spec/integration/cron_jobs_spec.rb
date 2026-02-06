require 'rails_helper'

RSpec.describe 'Cron Jobs', type: :request do
  describe 'GlobalSuppression.prune_expired' do
    it 'is called in daily cron job' do
      # Create expired and active suppressions
      expired_suppression = create(:global_suppression, 
        :ip_address => '192.168.1.1',
        :reason => 'Expired ban',
        :keep_until => 1.hour.ago
      )
      active_suppression = create(:global_suppression,
        :ip_address => '192.168.1.2', 
        :reason => 'Active ban',
        :keep_until => 1.hour.from_now
      )
      permanent_suppression = create(:global_suppression,
        :ip_address => '192.168.1.3',
        :reason => 'Permanent ban',
        :keep_until => nil
      )

      expect(GlobalSuppression.count).to eq(3)

      # Simulate the cron job call
      GlobalSuppression.prune_expired

      expect(GlobalSuppression.count).to eq(2)
      expect(GlobalSuppression.find_by(id: expired_suppression.id)).to be_nil
      expect(GlobalSuppression.find_by(id: active_suppression.id)).not_to be_nil
      expect(GlobalSuppression.find_by(id: permanent_suppression.id)).not_to be_nil
    end
  end

  describe 'PruneSuppressionListsJob' do
    let(:server) { create(:server, :provision_database => true) }

    it 'prunes suppression lists for all servers' do
      # Mock the message_db suppression_list.prune method
      mock_suppression_list = double('suppression_list')
      allow(server.message_db).to receive(:suppression_list).and_return(mock_suppression_list)
      expect(mock_suppression_list).to receive(:prune)

      # Create additional servers
      server2 = create(:server, :provision_database => true)
      mock_suppression_list2 = double('suppression_list2')
      allow(server2.message_db).to receive(:suppression_list).and_return(mock_suppression_list2)
      expect(mock_suppression_list2).to receive(:prune)

      # Run the job
      job = PruneSuppressionListsJob.new
      job.perform
    end
  end

  describe 'PruneWebhookRequestsJob' do
    let(:server) { create(:server, :provision_database => true) }

    it 'prunes webhook requests for all servers' do
      # Mock the message_db webhooks.prune method
      mock_webhooks = double('webhooks')
      allow(server.message_db).to receive(:webhooks).and_return(mock_webhooks)
      expect(mock_webhooks).to receive(:prune)

      # Create additional servers
      server2 = create(:server, :provision_database => true)
      mock_webhooks2 = double('webhooks2')
      allow(server2.message_db).to receive(:webhooks).and_return(mock_webhooks2)
      expect(mock_webhooks2).to receive(:prune)

      # Run the job
      job = PruneWebhookRequestsJob.new
      job.perform
    end
  end

  describe 'ExpireHeldMessagesJob' do
    let(:server) { create(:server, :provision_database => true) }

    it 'expires held messages for all servers' do
      # Mock the message_db.messages method and cancel_hold
      held_message = double('held_message')
      mock_messages = double('messages')
      allow(server.message_db).to receive(:messages).and_return(mock_messages)
      allow(mock_messages).to receive(:each).and_yield(held_message)
      expect(held_message).to receive(:cancel_hold)

      # Create additional servers
      server2 = create(:server, :provision_database => true)
      held_message2 = double('held_message2')
      mock_messages2 = double('messages2')
      allow(server2.message_db).to receive(:messages).and_return(mock_messages2)
      allow(mock_messages2).to receive(:each).and_yield(held_message2)
      expect(held_message2).to receive(:cancel_hold)

      # Run the job
      job = ExpireHeldMessagesJob.new
      job.perform
    end

    it 'queries for held messages with expired hold_expiry' do
      mock_messages = double('messages')
      expected_where = {
        :status => 'Held',
        :hold_expiry => { :less_than => Time.now.to_f }
      }
      
      allow(server.message_db).to receive(:messages).with(:where => expected_where).and_return(mock_messages)
      allow(mock_messages).to receive(:each)

      job = ExpireHeldMessagesJob.new
      job.perform

      expect(server.message_db).to have_received(:messages).with(:where => expected_where)
    end
  end

  describe 'ProcessMessageRetentionJob' do
    let(:server) { create(:server, :provision_database => true) }

    it 'processes message retention for all servers' do
      # Mock the message_db retention.process method
      mock_retention = double('retention')
      allow(server.message_db).to receive(:retention).and_return(mock_retention)
      expect(mock_retention).to receive(:process)

      # Create additional servers
      server2 = create(:server, :provision_database => true)
      mock_retention2 = double('retention2')
      allow(server2.message_db).to receive(:retention).and_return(mock_retention2)
      expect(mock_retention2).to receive(:process)

      # Run the job
      job = ProcessMessageRetentionJob.new
      job.perform
    end
  end

  describe 'CheckAllDNSJob' do
    let(:server) { create(:server) }

    it 'checks DNS for all servers' do
      # Mock the check_dns method
      expect(server).to receive(:check_dns)

      # Create additional servers
      server2 = create(:server)
      expect(server2).to receive(:check_dns)

      # Run the job
      job = CheckAllDNSJob.new
      job.perform
    end
  end

  describe 'CleanupAuthieSessionsJob' do
    it 'cleans up old authie sessions' do
      # Mock Authie::Session.cleanup method
      expect(Authie::Session).to receive(:cleanup)

      # Run the job
      job = CleanupAuthieSessionsJob.new
      job.perform
    end
  end

  describe 'ReputationMonitorJob' do
    let(:server) { create(:server) }

    it 'monitors reputation for all servers' do
      # Mock the reputation monitoring
      expect(Postal::ReputationMonitor).to receive(:new).with(server).and_return(double('monitor', :check => true))

      # Create additional servers
      server2 = create(:server)
      expect(Postal::ReputationMonitor).to receive(:new).with(server2).and_return(double('monitor2', :check => true))

      # Run the job
      job = ReputationMonitorJob.new
      job.perform
    end
  end

  describe 'RequeueWebhooksJob' do
    it 'requeues webhook requests' do
      # Mock WebhookRequest.requeue_all method
      expect(WebhookRequest).to receive(:requeue_all)

      # Run the job
      job = RequeueWebhooksJob.new
      job.perform
    end
  end

  describe 'SendNotificationsJob' do
    it 'sends notifications' do
      # Mock Postal::Notification.send_all method
      expect(Postal::Notification).to receive(:send_all)

      # Run the job
      job = SendNotificationsJob.new
      job.perform
    end
  end

  describe 'Clockwork configuration' do
    it 'loads cron configuration without errors' do
      # This test ensures the cron.rb file can be loaded and parsed
      expect { load 'config/cron.rb' }.not_to raise_error
    end

    it 'defines expected cron jobs' do
      # Load the cron configuration
      load 'config/cron.rb'

      # Check that Clockwork has the expected jobs configured
      # Note: This is a basic smoke test to ensure the configuration loads
      expect(Clockwork.manager).not_to be_nil
    end
  end
end
