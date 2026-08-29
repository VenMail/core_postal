module Postal
  module MessageDB
    module Migrations
      class AddIPProvenanceToMessages < Postal::MessageDB::Migration
        def up
          @database.query(
            "ALTER TABLE `#{@database.database_name}`.`messages` " \
            "ADD COLUMN `transport_peer_ip` varchar(42) DEFAULT NULL, " \
            "ADD COLUMN `external_actor_ip` varchar(42) DEFAULT NULL, " \
            "ADD INDEX `on_external_actor_ip` (`external_actor_ip`)"
          )
        end
      end
    end
  end
end
