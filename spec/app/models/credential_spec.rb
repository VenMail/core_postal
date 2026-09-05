require 'rails_helper'

RSpec.describe Credential, type: :model do
  describe 'credential hold webhook' do
    let(:credential) { create(:credential) }
    let(:hold_at) { Time.utc(2026, 9, 5, 12, 0, 0) }

    it 'emits one safe CredentialLocked event after a false-to-true transition' do
      expect(WebhookRequest).to receive(:trigger).with(
        credential.server,
        'CredentialLocked',
        satisfy do |payload|
          payload[:server] == credential.server.webhook_hash &&
            payload[:credential] == {
              :id => credential.id,
              :uuid => credential.uuid,
              :name => credential.name,
              :type => credential.type
            } &&
            payload[:hold_at] == hold_at.iso8601 &&
            payload[:reason] == 'Manual security hold' &&
            !payload[:credential].key?(:key)
        end
      ).once

      credential.update!(
        :hold => true,
        :hold_at => hold_at,
        :hold_reason => 'Manual security hold'
      )
    end

    it 'does not emit for an unrelated update or an already-held save' do
      allow(WebhookRequest).to receive(:trigger)

      credential.update!(:name => 'Renamed credential')
      credential.update!(:hold => true, :hold_at => hold_at, :hold_reason => 'First hold')
      credential.update!(:hold_reason => 'Already held')

      expect(WebhookRequest).to have_received(:trigger).once
    end

    it 'does not emit when the hold transaction rolls back' do
      enable_credential_webhook(credential)
      allow(WebhookDeliveryJob).to receive(:queue)
      credential_id = credential.id

      expect {
        Credential.transaction(:requires_new => true) do
          credential.update!(:hold => true, :hold_at => hold_at, :hold_reason => 'Rolled back')
          raise ActiveRecord::Rollback
        end
      }.not_to change(WebhookRequest, :count)

      expect(Credential.find(credential_id).hold).to be(false)
      expect(WebhookDeliveryJob).not_to have_received(:queue)
    end

    it 'emits after commit when a later save occurs in the same transaction' do
      expect(WebhookRequest).to receive(:trigger).with(
        credential.server,
        'CredentialLocked',
        hash_including(
          :credential => hash_including(:uuid => credential.uuid),
          :reason => 'Transactional hold'
        )
      ).once

      Credential.transaction do
        credential.update!(
          :hold => true,
          :hold_at => hold_at,
          :hold_reason => 'Transactional hold'
        )
        credential.update!(:name => 'Renamed after hold')
      end
    end

    it 'retains an outer hold transition when a later savepoint rolls back' do
      expect(WebhookRequest).to receive(:trigger).with(
        credential.server,
        'CredentialLocked',
        hash_including(:credential => hash_including(:uuid => credential.uuid))
      ).once

      Credential.transaction do
        credential.update!(
          :hold => true,
          :hold_at => hold_at,
          :hold_reason => 'Outer transaction hold'
        )

        Credential.transaction(:requires_new => true) do
          credential.update!(:name => 'Rolled-back rename')
          raise ActiveRecord::Rollback
        end
      end
    end

    it 'does not emit a transition that occurred wholly inside a rolled-back savepoint' do
      credential.update!(:hold => true, :hold_at => hold_at, :hold_reason => 'Existing hold')
      enable_credential_webhook(credential)
      allow(WebhookDeliveryJob).to receive(:queue)

      expect {
        Credential.transaction(:requires_new => true) do
          credential.update!(:hold => false)
          credential.update!(:hold => true)
          raise ActiveRecord::Rollback
        end
        credential.update!(:name => 'Unrelated committed save')
      }.not_to change(WebhookRequest, :count)

      expect(WebhookDeliveryJob).not_to have_received(:queue)
    end

    def enable_credential_webhook(credential)
      webhook = create(:webhook, :server => credential.server, :enabled => true)
      create(:webhook_event, :webhook => webhook, :event => 'CredentialLocked')
    end
  end
end
