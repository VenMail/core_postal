module Postal
  module MessageDB
    module Migrations
      class AddGatewayTrustToMessages < Postal::MessageDB::Migration
        def up
          @database.query(
            "ALTER TABLE `#{@database.database_name}`.`messages` " \
            "ADD COLUMN `trusted_gateway` tinyint(1) DEFAULT NULL"
          )
        end
      end
    end
  end
end
