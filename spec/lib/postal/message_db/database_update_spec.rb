require 'spec_helper'
require ENV.fetch(
  'POSTAL_MESSAGE_DATABASE_SOURCE',
  File.expand_path('../../../../lib/postal/message_db/database', __dir__)
)

RSpec.describe Postal::MessageDB::Database do
  describe '#update' do
    it 'joins compound WHERE predicates with AND' do
      database = described_class.allocate
      mysql = double('mysql', :affected_rows => 1)
      allow(database).to receive(:escape) do |value|
        if value == true
          '1'
        elsif value == false
          '0'
        else
          "'#{value}'"
        end
      end
      allow(database).to receive(:with_mysql).and_yield(mysql)
      expect(database).to receive(:query_on_connection).with(
        mysql,
        "UPDATE `maildb`.`mail_users` SET `active` = 0 WHERE `email` = 'sender@venia.cloud' AND `active` = 1"
      )

      expect(database.update(
        'mail_users',
        { :active => false },
        :db => 'maildb',
        :where => { :email => 'sender@venia.cloud', :active => true }
      )).to eq(1)
    end
  end
end
