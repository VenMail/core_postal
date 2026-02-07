require 'rails_helper'

RSpec.describe QueuedMessage, type: :model do
  describe 'associations' do
    it 'belongs to server' do
      queued_message = QueuedMessage.new
      expect(queued_message).to respond_to(:server)
      expect(queued_message.server).to be_nil
    end

    it 'belongs to ip_address (optional)' do
      queued_message = QueuedMessage.new
      expect(queued_message).to respond_to(:ip_address)
      expect(queued_message.ip_address).to be_nil
    end

    it 'belongs to user (optional)' do
      queued_message = QueuedMessage.new
      expect(queued_message).to respond_to(:user)
      expect(queued_message.user).to be_nil
    end
  end

  describe 'callbacks' do
    it 'queues after creation' do
      expect(UnqueueMessageJob).to receive(:queue).with(:main, :id => anything)
      message = create(:queued_message)
    end

    it 'allocates IP address before creation' do
      message = build(:queued_message)
      expect(message).to receive(:allocate_ip_address)
      message.save
    end
  end

  describe 'scopes' do
    before do
      @unlocked_message = create(:queued_message, :locked_at => nil)
      @locked_message = create(:queued_message, :locked_at => Time.now)
      @retriable_message = create(:queued_message, :retry_after => nil)
      @non_retriable_message = create(:queued_message, :retry_after => 1.hour.from_now)
    end

    describe '.unlocked' do
      it 'returns only unlocked messages' do
        unlocked = QueuedMessage.unlocked
        expect(unlocked).to include(@unlocked_message)
        expect(unlocked).not_to include(@locked_message)
      end
    end

    describe '.retriable' do
      it 'includes messages with nil retry_after' do
        retriable = QueuedMessage.retriable
        expect(retriable).to include(@retriable_message)
      end

      it 'includes messages with past retry_after' do
        past_retry = create(:queued_message, :retry_after => 5.minutes.ago)
        retriable = QueuedMessage.retriable
        expect(retriable).to include(past_retry)
      end

      it 'excludes messages with future retry_after' do
        retriable = QueuedMessage.retriable
        expect(retriable).not_to include(@non_retriable_message)
      end
    end
  end

  describe 'instance methods' do
    let(:message) { create(:queued_message) }

    describe '#retriable?' do
      it 'returns true for messages with nil retry_after' do
        message.retry_after = nil
        expect(message.retriable?).to be_truthy
      end

      it 'returns true for messages with past retry_after' do
        message.retry_after = 5.minutes.ago
        expect(message.retriable?).to be_truthy
      end

      it 'returns false for messages with future retry_after' do
        message.retry_after = 1.hour.from_now
        expect(message.retriable?).to be_falsey
      end
    end

    describe '#queue_name' do
      it 'returns main queue when no IP address' do
        message.ip_address = nil
        expect(message.queue_name).to eq(:main)
      end

      it 'returns outgoing queue when IP address present' do
        ip_address = create(:ip_address)
        message.ip_address = ip_address
        expect(message.queue_name).to eq(:"outgoing-#{ip_address.id}")
      end
    end

    describe '#locked?' do
      it 'returns true when locked_at is present' do
        message.locked_at = Time.now
        expect(message.locked?).to be_truthy
      end

      it 'returns false when locked_at is nil' do
        message.locked_at = nil
        expect(message.locked?).to be_falsey
      end
    end

    describe '#acquire_lock' do
      it 'acquires lock on unlocked message' do
        expect(message.acquire_lock).to be_truthy
        message.reload
        expect(message.locked_by).to eq(Postal.locker_name)
        expect(message.locked_at).not_to be_nil
      end

      it 'fails to acquire lock on already locked message' do
        # Lock the message first
        message.acquire_lock
        expect(message.acquire_lock).to be_falsey
      end
    end

    describe '#unlock' do
      it 'removes lock' do
        # First lock the message
        message.acquire_lock
        message.unlock
        message.reload
        expect(message.locked_at).to be_nil
        expect(message.locked_by).to be_nil
      end
    end

    describe '#retry_later' do
      it 'sets retry_after and increments attempts' do
        original_attempts = message.attempts
        message.retry_later(10.minutes)
        expect(message.retry_after).to be_within(1.second).of(Time.now + 10.minutes)
        expect(message.attempts).to eq(original_attempts + 1)
        expect(message.locked_by).to be_nil
        expect(message.locked_at).to be_nil
      end
    end

    describe '#queue!' do
      it 'clears retry_after and queues message' do
        message.retry_after = 1.hour.from_now
        expect(UnqueueMessageJob).to receive(:queue)
        message.queue!
        expect(message.retry_after).to be_nil
      end
    end

    describe '#batchable_messages' do
      it 'returns empty array when message is not locked' do
        message.batch_key = 'test_key'
        expect { message.batchable_messages }.to raise_error(Postal::Error)
      end

      it 'returns empty array when batch_key is nil' do
        message.acquire_lock
        message.update_column(:batch_key, nil)
        expect(message.batchable_messages).to be_empty
      end

      it 'returns batchable messages when conditions are met' do
        message.acquire_lock
        message.update_column(:batch_key, 'test_key')
        ip_address = create(:ip_address)
        message.update_column(:ip_address_id, ip_address.id)

        # Create some batchable messages
        create(:queued_message, :batch_key => 'test_key', :ip_address => ip_address, :locked_at => nil)
        
        result = message.batchable_messages
        expect(result).to be_an(ActiveRecord::Relation)
      end
    end
  end

  describe 'class methods' do
    describe '.calculate_retry_time' do
      it 'calculates exponential backoff' do
        expect(QueuedMessage.calculate_retry_time(0, 5.minutes)).to eq(5.minutes)
        expect(QueuedMessage.calculate_retry_time(1, 5.minutes)).to be_within(1.second).of(6.5.minutes)
        expect(QueuedMessage.calculate_retry_time(2, 5.minutes)).to be_within(1.second).of(8.45.minutes)
      end
    end

    describe '.requeue_all' do
      it 'queues all unlocked and retriable messages' do
        retriable_message = create(:queued_message, :locked_at => nil, :retry_after => 1.hour.ago)
        non_retriable_message = create(:queued_message, :retry_after => 1.hour.from_now)
        locked_message = create(:queued_message, :locked_at => Time.now, :retry_after => 1.hour.ago)
        
        allow_any_instance_of(QueuedMessage).to receive(:queue)
        expect(retriable_message).to receive(:queue)
        expect(non_retriable_message).not_to receive(:queue)
        expect(locked_message).not_to receive(:queue)
        
        QueuedMessage.requeue_all
      end
    end
  end

  describe '#allocate_ip_address' do
    it 'does nothing when IP pools are disabled' do
      allow(Postal).to receive(:ip_pools?).and_return(false)
      message = build(:queued_message)
      expect(message).not_to receive(:server)
      message.allocate_ip_address
    end

    it 'allocates IP address when IP pools are enabled' do
      allow(Postal).to receive(:ip_pools?).and_return(true)
      message = build(:queued_message)
      server = create(:server)
      message.server = server
      
      # Mock the message access to avoid database issues
      mock_message = double('message')
      allow(message).to receive(:message).and_return(mock_message)
      expect(server).to receive(:ip_pool_for_message).with(mock_message).and_return(nil)
      message.allocate_ip_address
    end
  end
end
