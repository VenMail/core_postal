class AddVerificationTokenVerifiedAtToDomains < ActiveRecord::Migration[5.2]
  def change
    add_column :domains, :verification_token_verified_at, :datetime
    add_column :domains, :verification_token_verified_fingerprint, :string
  end
end
