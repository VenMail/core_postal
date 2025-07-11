module Postal
  module MessageDB
    module Migrations
      class IncreaseOutputColumnSize < Postal::MessageDB::Migration
        def up
          @database.query("ALTER TABLE `#{@database.database_name}`.`deliveries` MODIFY COLUMN `output` TEXT")
        end
      end
    end
  end
end 