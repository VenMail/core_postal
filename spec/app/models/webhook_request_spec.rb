require 'rails_helper'

RSpec.describe WebhookRequest, type: :model do
  describe 'associations' do
    it 'belongs to server' do
      webhook_request = WebhookRequest.new
      expect(webhook_request).to respond_to(:server)
      expect(webhook_request.server).to be_nil
    end

    it 'belongs to webhook (optional)' do
      webhook_request = WebhookRequest.new
      expect(webhook_request).to respond_to(:webhook)
      expect(webhook_request.webhook).to be_nil
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      webhook_request = WebhookRequest.new(
        server: create(:server),
        url: 'https://example.com/webhook',
        event: 'message.delivered',
        payload: { 'message_id' => '123' }
      )
      expect(webhook_request).to be_valid
    end

    it 'is invalid without url' do
      webhook_request = WebhookRequest.new(
        server: create(:server),
        url: nil,
        event: 'message.delivered'
      )
      expect(webhook_request).not_to be_valid
      expect(webhook_request.errors[:url]).to include("can't be blank")
    end

    it 'is invalid without event' do
      webhook_request = WebhookRequest.new(
        server: create(:server),
        url: 'https://example.com/webhook',
        event: nil
      )
      expect(webhook_request).not_to be_valid
      expect(webhook_request.errors[:event]).to include("can't be blank")
    end
  end

  describe 'constants' do
    describe 'RETRIES' do
      it 'defines retry schedule' do
        expect(WebhookRequest::RETRIES).to eq({
          1 => 2.minutes,
          2 => 3.minutes,
          3 => 6.minutes,
          4 => 10.minutes,
          5 => 15.minutes
        })
      end
    end
  end

  describe 'callbacks' do
    it 'queues after creation' do
      expect(WebhookDeliveryJob).to receive(:queue).with(:main, :id => anything)
      webhook_request = create(:webhook_request)
    end
  end

  describe 'class methods' do
    describe '.trigger' do
      let(:server) { create(:server) }
      let(:webhook) { create(:webhook, :server => server, :enabled => true) }
      let(:webhook_event) { create(:webhook_event, :webhook => webhook, :event => 'message.delivered') }

      before do
        webhook.webhook_events << webhook_event
      end

      it 'creates webhook requests for enabled webhooks' do
        expect(WebhookDeliveryJob).to receive(:queue)
        
        WebhookRequest.trigger(server, 'message.delivered', { 'message_id' => '123' })
        
        webhook_request = WebhookRequest.last
        expect(webhook_request.server).to eq(server)
        expect(webhook_request.event).to eq('message.delivered')
        expect(webhook_request.payload).to eq({ 'message_id' => '123' })
      end

      it 'accepts server as integer ID' do
        expect(WebhookDeliveryJob).to receive(:queue)
        
        WebhookRequest.trigger(server.id, 'message.delivered', { 'message_id' => '123' })
        
        webhook_request = WebhookRequest.last
        expect(webhook_request.server).to eq(server)
      end

      it 'does not create requests for disabled webhooks' do
        webhook.update_column(:enabled, false)
        
        expect(WebhookDeliveryJob).not_to receive(:queue)
        
        WebhookRequest.trigger(server, 'message.delivered', { 'message_id' => '123' })
        
        expect(WebhookRequest.count).to eq(0)
      end

      it 'creates requests for webhooks with all_events enabled' do
        all_events_webhook = create(:webhook, :server => server, :enabled => true, :all_events => true)
        
        # Mock the webhook query to avoid complex joins
        allow(server.webhooks).to receive(:enabled).and_return([all_events_webhook])
        allow(all_events_webhook).to receive(:webhook_events).and_return([])
        
        expect {
          WebhookRequest.trigger(server, 'message.delivered', { 'message_id' => '123' })
        }.to change(WebhookRequest, :count).by(1)
        
        webhook_request = WebhookRequest.where(:webhook_id => all_events_webhook.id).first
        expect(webhook_request).not_to be_nil
        expect(webhook_request.event).to eq('message.delivered')
        expect(webhook_request.payload).to include('message_id' => '123')
      end
    end

    describe '.requeue_all' do
      it 'queues requests with past retry_after' do
        past_request = create(:webhook_request, :retry_after => 5.minutes.ago)
        future_request = create(:webhook_request, :retry_after => 1.hour.from_now)
        
        # Mock the queue method on the specific instances
        expect(past_request).to receive(:queue)
        expect(future_request).not_to receive(:queue)
        
        # Call requeue_all which should find and queue the past request
        WebhookRequest.requeue_all
      end
    end
  end

  describe 'instance methods' do
    let(:webhook_request) { create(:webhook_request) }
    let(:mock_result) { { :code => 200, :body => 'OK' } }

    describe '#queue' do
      it 'queues webhook delivery job' do
        expect(WebhookDeliveryJob).to receive(:queue).with(:main, :id => webhook_request.id)
        webhook_request.queue
      end
    end

    describe '#deliver' do
      before do
        allow(Postal::HTTP).to receive(:post).and_return(mock_result)
        allow(webhook_request.server.message_db.webhooks).to receive(:record)
      end

      context 'when successful (2xx status)' do
        before do
          mock_result[:code] = 200
        end

        it 'returns true and destroys the request' do
          result = webhook_request.deliver
          expect(result).to be_truthy
          expect(WebhookRequest.find_by(id: webhook_request.id)).to be_nil
        end

        it 'updates webhook last_used_at' do
          webhook = create(:webhook)
          webhook_request.webhook = webhook
          
          webhook_request.deliver
          
          expect(webhook.reload.last_used_at).to be_within(1.second).of(Time.now)
        end

        it 'records the delivery in message database' do
          expect(webhook_request.server.message_db.webhooks).to receive(:record).with(
            :event => webhook_request.event,
            :url => webhook_request.url,
            :webhook_id => webhook_request.webhook_id,
            :attempt => anything,
            :timestamp => anything,
            :payload => anything,
            :uuid => webhook_request.uuid,
            :status_code => 200,
            :body => 'OK',
            :will_retry => 0
          )
          
          webhook_request.deliver
        end
      end

      context 'when unsuccessful (non-2xx status)' do
        before do
          mock_result[:code] = 500
        end

        it 'returns false and sets error' do
          result = webhook_request.deliver
          expect(result).to be_falsey
          expect(webhook_request.reload.error).to include("Code received was 500")
        end

        it 'sets retry_after for attempts less than max' do
          webhook_request.attempts = 3
          webhook_request.deliver
          expect(webhook_request.reload.retry_after).to be_within(1.second).of(Time.now + 10.minutes)
        end

        it 'destroys request after max attempts' do
          webhook_request.attempts = 5
          webhook_request.deliver
          expect(WebhookRequest.find_by(id: webhook_request.id)).to be_nil
        end
      end
    end
  end

  describe 'payload serialization' do
    it 'serializes payload as hash' do
      webhook_request = create(:webhook_request, :payload => { 'key' => 'value' })
      expect(webhook_request.payload).to eq({ 'key' => 'value' })
    end
  end

  describe 'UUID generation' do
    it 'generates UUID on creation' do
      webhook_request = create(:webhook_request)
      expect(webhook_request.uuid).not_to be_nil
      expect(webhook_request.uuid).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end
  end
end
