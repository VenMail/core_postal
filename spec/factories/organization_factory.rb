# == Schema Information
#
# Table name: organizations
#
#  id                :integer          not null, primary key
#  uuid              :string(255)
#  name              :string(255)
#  permalink         :string(255)
#  time_zone         :string(255)
#  created_at        :datetime
#  updated_at        :datetime
#  ip_pool_id        :integer
#  owner_id          :integer
#  deleted_at        :datetime
#  suspended_at      :datetime
#  suspension_reason :string(255)
#
# Indexes
#
#  index_organizations_on_permalink  (permalink)
#  index_organizations_on_uuid       (uuid)
#

FactoryBot.define do

  factory :organization do
    sequence(:name) { |n| "Test Organization #{n}" }
    sequence(:permalink) { |n| "test-org-#{n}" }
    time_zone { 'UTC' }
    association :owner, factory: :user

    trait :with_ip_pool do
      after(:create) do |org|
        pool = IPPool.create!(name: "#{org.permalink}-default", default: true)
        org.ip_pools << pool
      end
    end
  end

end
