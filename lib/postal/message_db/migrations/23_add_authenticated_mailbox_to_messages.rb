module Postal
  module MessageDB
    module Migrations
      class AddAuthenticatedMailboxToMessages < Postal::MessageDB::Migration
        def up
          @database.query(
            "ALTER TABLE `#{@database.database_name}`.`messages` " \
            "ADD COLUMN `authenticated_mailbox` varchar(255) DEFAULT NULL, " \
            "ADD INDEX `on_authenticated_mailbox_status_timestamp` (`authenticated_mailbox`, `status`, `timestamp`)"
          )
        end
      end
    end
  end
end
