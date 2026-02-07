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
      # Mock the message_db suppression_list.prune method for any server instance
      mock_suppression_list = double('suppression_list')
      mock_message_db = double('message_db', :suppression_list => mock_suppression_list)
      allow_any_instance_of(Server).to receive(:message_db).and_return(mock_message_db)
      expect(mock_suppression_list).to receive(:prune).at_least(:once)

      # Run the job
      job = PruneSuppressionListsJob.new('test-id')
      job.perform
    end
  end

  describe 'PruneWebhookRequestsJob' do
    let(:server) { create(:server) }

    it 'prunes webhook requests for all servers' do
      # Mock the message_db webhooks.prune method for any server instance
      mock_webhooks = double('webhooks')
      mock_message_db = double('message_db', :webhooks => mock_webhooks)
      allow_any_instance_of(Server).to receive(:message_db).and_return(mock_message_db)
      expect(mock_webhooks).to receive(:prune).at_least(:once)

      # Run the job
      job = PruneWebhookRequestsJob.new('test-id')
      job.perform
    end
  end

  describe 'ExpireHeldMessagesJob' do
    let(:server) { create(:server) }

    it 'expires held messages for all servers' do
      # Mock the message_db.messages method and cancel_hold
      held_message = double('held_message')
      mock_messages = double('messages')
      mock_message_db = double('message_db', :messages => mock_messages)
      allow_any_instance_of(Server).to receive(:message_db).and_return(mock_message_db)
      allow(mock_messages).to receive(:each).and_yield(held_message)
      expect(held_message).to receive(:cancel_hold).at_least(:once)

      # Run the job
      job = ExpireHeldMessagesJob.new('test-id')
      job.perform
    end

    it 'queries for held messages with expired hold_expiry' do
      mock_messages = double('messages')
      mock_message_db = double('message_db')
      expected_where = {
        :status => 'Held',
        :hold_expiry => { :less_than => Time.now.to_f }
      }
      
      allow_any_instance_of(Server).to receive(:message_db).and_return(mock_message_db)
      allow(mock_message_db).to receive(:messages).with(:where => expected_where).and_return(mock_messages)
      allow(mock_messages).to receive(:each)

      job = ExpireHeldMessagesJob.new('test-id')
      job.perform

      expect(mock_message_db).to have_received(:messages).with(:where => expected_where)
    end
  end

  describe 'ProcessMessageRetentionJob' do
    let(:server) { create(:server) }

    it 'processes message retention for all servers' do
      # Mock the message_db provisioner methods
      mock_provisioner = double('provisioner')
      mock_message_db = double('message_db')
      allow_any_instance_of(Server).to receive(:message_db).and_return(mock_message_db)
      allow(mock_message_db).to receive(:provisioner).and_return(mock_provisioner)
      allow(mock_provisioner).to receive(:remove_raw_tables_older_than)
      allow(mock_provisioner).to receive(:remove_raw_tables_until_less_than_size)
      allow(mock_provisioner).to receive(:remove_messages)

      # Run the job
      job = ProcessMessageRetentionJob.new('test-id')
      job.perform
    end
  end

  describe 'CheckAllDNSJob' do
    it 'runs without errors' do
      # Mock all domain queries to avoid database dependencies
      domain_relation = double('ActiveRecord::Relation')
      allow(Domain).to receive(:where).and_return(domain_relation)
      allow(domain_relation).to receive(:not).and_return(domain_relation)
      allow(domain_relation).to receive(:where).and_return(domain_relation)
      allow(domain_relation).to receive(:each)
      
      # Mock individual domains to prevent check_dns calls
      mock_domain = double('domain')
      allow(domain_relation).to receive(:each).and_yield(mock_domain)
      allow(mock_domain).to receive(:name).and_return('example.com')
      allow(mock_domain).to receive(:check_dns).with(:auto)
      
      track_domain_relation = double('TrackDomainRelation')
      allow(TrackDomain).to receive(:where).and_return(track_domain_relation)
      allow(track_domain_relation).to receive(:includes).and_return(track_domain_relation)
      allow(track_domain_relation).to receive(:each)
      
      # Mock individual track domains
      mock_track_domain = double('track_domain')
      allow(track_domain_relation).to receive(:each).and_yield(mock_track_domain)
      allow(mock_track_domain).to receive(:full_name).and_return('track.example.com')
      allow(mock_track_domain).to receive(:check_dns)

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
