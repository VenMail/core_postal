module Postal
  module MessageDB
    module Migrations
      class AddTerminalDeliveryIndex < Postal::MessageDB::Migration
        def up
          @database.query(
            "ALTER TABLE `#{@database.database_name}`.`deliveries` " \
            "ADD INDEX `on_status_timestamp_message_id` (`status`(8), `timestamp`, `message_id`)"
          )
        end
      end
    end
  end
end
