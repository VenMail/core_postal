# == Schema Information
#
# Table name: auth_attempts
#
#  id                 :integer          not null, primary key
#  scope_key          :string(255)
#  count              :integer          default(0)
#  window_started_at  :datetime
#  blocked_until      :datetime
#  created_at         :datetime
#  updated_at         :datetime
#

class AuthAttempt < ApplicationRecord
  validates :scope_key, presence: true, uniqueness: true

  def blocked?
    blocked_until.present? && blocked_until > Time.now
  end

  def within_window?(window)
    window_started_at && window_started_at > window.ago
  end
end
