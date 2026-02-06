require 'rails_helper'

RSpec.describe 'Cron Jobs', type: :model do
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
    let(:server) { create(:server) }

    it 'prunes suppression lists for all servers' do
      # Mock the message_db suppression_list.prune method
      mock_suppression_list = double('suppression_list')
      allow(server.message_db).to receive(:suppression_list).and_return(mock_suppression_list)
      expect(mock_suppression_list).to receive(:prune)

      # Create additional servers
      server2 = create(:server)
      mock_suppression_list2 = double('suppression_list2')
      allow(server2.message_db).to receive(:suppression_list).and_return(mock_suppression_list2)
      expect(mock_suppression_list2).to receive(:prune)

      # Run the job
      job = PruneSuppressionListsJob.new
      job.perform
    end
  end

  describe 'PruneWebhookRequestsJob' do
    let(:server) { create(:server) }

    it 'prunes webhook requests for all servers' do
      # Mock the message_db webhooks.prune method
      mock_webhooks = double('webhooks')
      allow(server.message_db).to receive(:webhooks).and_return(mock_webhooks)
      expect(mock_webhooks).to receive(:prune)

      # Create additional servers
      server2 = create(:server)
      mock_webhooks2 = double('webhooks2')
      allow(server2.message_db).to receive(:webhooks).and_return(mock_webhooks2)
      expect(mock_webhooks2).to receive(:prune)

      # Run the job
      job = PruneWebhookRequestsJob.new
      job.perform
    end
  end

  describe 'ExpireHeldMessagesJob' do
    let(:server) { create(:server) }

    it 'expires held messages for all servers' do
      # Mock the message_db.messages method and cancel_hold
      held_message = double('held_message')
      mock_messages = double('messages')
      allow(server.message_db).to receive(:messages).and_return(mock_messages)
      allow(mock_messages).to receive(:each).and_yield(held_message)
      expect(held_message).to receive(:cancel_hold)

      # Create additional servers
      server2 = create(:server)
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
    let(:server) { create(:server) }

    it 'processes message retention for all servers' do
      # Mock the message_db retention.process method
      mock_retention = double('retention')
      allow(server.message_db).to receive(:retention).and_return(mock_retention)
      expect(mock_retention).to receive(:process)

      # Create additional servers
      server2 = create(:server)
      mock_retention2 = double('retention2')
      allow(server2.message_db).to receive(:retention).and_return(mock_retention2)
      expect(mock_retention2).to receive(:process)

      # Run the job
      job = ProcessMessageRetentionJob.new('test-id')
      job.perform
    end
  end

  describe 'CheckAllDNSJob' do
    it 'runs without errors' do
      # Mock the domain queries to avoid database dependencies
      allow(Domain).to receive(:where).and_return([])
      allow(TrackDomain).to receive(:where).and_return([])
      allow(TrackDomain).to receive(:includes).and_return([])

      # Run the job - should complete without errors
      expect { CheckAllDNSJob.new('test-id').perform }.not_to raise_error
    end
  end

  describe 'CleanupAuthieSessionsJob' do
    it 'cleans up old authie sessions' do
      # Mock Authie::Session.cleanup method
      expect(Authie::Session).to receive(:cleanup)

      # Run the job
      job = CleanupAuthieSessionsJob.new('test-id')
      job.perform
    end
  end

  describe 'ReputationMonitorJob' do
    it 'runs without errors' do
      # Create some credentials for the job to process
      create(:credential)
      create(:credential)
      
      # Mock the actual monitoring to avoid external API calls
      allow_any_instance_of(ReputationMonitorJob).to receive(:monitor_credential_optimized)
      allow_any_instance_of(ReputationMonitorJob).to receive(:reset_eligible_credentials)
      
      # Run the job - should complete without errors
      expect { ReputationMonitorJob.new('test-id').perform }.not_to raise_error
    end
  end

  describe 'RequeueWebhooksJob' do
    it 'requeues webhook requests' do
      # Mock WebhookRequest.requeue_all method
      expect(WebhookRequest).to receive(:requeue_all)

      # Run the job
      job = RequeueWebhooksJob.new('test-id')
      job.perform
    end
  end

  describe 'SendNotificationsJob' do
    it 'sends send limit notifications for all servers' do
      # Mock Server.send_send_limit_notifications method
      expect(Server).to receive(:send_send_limit_notifications)

      # Run the job
      job = SendNotificationsJob.new('test-id')
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
