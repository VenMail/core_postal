class AddHoldTimestampsToCredentials < ActiveRecord::Migration[5.2]
  def change
    # Add timestamps to track when credentials were put on hold
    # This will help with more accurate bounce rate reset logic
    add_column :credentials, :hold_at, :datetime
    add_column :credentials, :hold_reason, :string
    
    # Backfill existing held credentials
    Credential.where(hold: true).where(hold_at: nil).find_each do |credential|
      # Use updated_at as a fallback for existing records
      credential.update_column(:hold_at, credential.updated_at)
      credential.update_column(:hold_reason, "Legacy hold - reason unknown")
    end
    
    # Add index for performance
    add_index :credentials, :hold_at
  end
end
