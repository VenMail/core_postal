# == Schema Information
#
# Table name: ip_pools
#
#  id         :integer          not null, primary key
#  name       :string(255)
#  uuid       :string(255)
#  created_at :datetime
#  updated_at :datetime
#  default    :boolean          default(FALSE)
#
# Indexes
#
#  index_ip_pools_on_uuid  (uuid)
#

FactoryBot.define do

  factory :ip_pool do
    sequence(:name) { |n| "IP Pool #{n}" }
    default { false }

    trait :with_ip_address do
      after(:create) do |pool|
        IPAddress.create!(
          ipv4: "192.168.#{rand(1..254)}.#{rand(1..254)}",
          hostname: "mail-#{pool.name.parameterize}.example.com",
          priority: 100,
          ip_pool: pool
        )
      end
    end

    trait :default do
      default { true }
    end
  end

end
