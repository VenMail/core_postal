require 'spec_helper'

RSpec.describe 'mailbox terminal outcome index' do
  let(:migration) do
    File.read(File.expand_path('../../lib/postal/message_db/migrations/24_add_terminal_delivery_index.rb', __dir__))
  end

  it 'indexes bounded terminal delivery scans by status, timestamp, and message' do
    expect(migration).to include('on_status_timestamp_message_id')
    expect(migration).to include('`status`(8), `timestamp`, `message_id`')
  end
end
