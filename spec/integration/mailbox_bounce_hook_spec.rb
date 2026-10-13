require 'spec_helper'

RSpec.describe 'mailbox failure enforcement hooks' do
  let(:message_source) do
    File.read(File.expand_path('../../lib/postal/message_db/message.rb', __dir__))
  end
  it 'evaluates every outgoing hard failure and delayed bounce from the delivery creation boundary' do
    create_delivery = message_source[/def create_delivery.*?^      end/m]
    expect(create_delivery).to include("%w[HardFail Bounced]")
    expect(create_delivery).to include('MailboxAbuseGuard.lock_after_delivery_failure!(self)')
    expect(create_delivery).to include("scope == 'outgoing'")
  end
end
