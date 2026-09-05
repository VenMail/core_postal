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
      expect(WebhookRequest).not_to receive(:trigger)

      Credential.transaction do
        credential.update!(:hold => true, :hold_at => hold_at, :hold_reason => 'Rolled back')
        raise ActiveRecord::Rollback
      end

      expect(credential.reload.hold).to be(false)
    end
  end
end
