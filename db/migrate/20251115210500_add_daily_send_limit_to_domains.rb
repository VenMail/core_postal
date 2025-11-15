class AddDailySendLimitToDomains < ActiveRecord::Migration[5.2]
  def change
    add_column :domains, :daily_send_limit, :integer
    add_column :domains, :send_limit_approaching_at, :datetime
    add_column :domains, :send_limit_exceeded_at, :datetime
  end
end
