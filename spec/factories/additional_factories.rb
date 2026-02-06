FactoryBot.define do
  factory :global_suppression do
    sequence(:ip_address) { |n| "192.168.#{n % 255}.#{(n / 255) % 255}" }
    reason { 'Test ban' }
    keep_until { nil }

    trait :expired do
      keep_until { 1.hour.ago }
    end

    trait :temporary do
      keep_until { 1.hour.from_now }
    end
  end

  factory :webhook_request do
    server
    url { 'https://example.com/webhook' }
    event { 'message.delivered' }
    payload { { 'message_id' => SecureRandom.uuid, 'status' => 'delivered' } }
    attempts { 0 }
    retry_after { nil }

    trait :with_webhook do
      association :webhook, :factory => :webhook
    end

    trait :failed do
      attempts { 1 }
      retry_after { 2.minutes.from_now }
      error { 'Failed to deliver' }
    end
  end

  factory :user_invite do
    sequence(:email_address) { |n| "invite#{n}@example.com" }
    expires_at { 7.days.from_now }

    trait :expired do
      expires_at { 1.hour.ago }
    end

    trait :with_organizations do
      after(:build) do |invite|
        invite.organizations << build(:organization)
      end
    end
  end

  factory :queued_message do
    server
    sequence(:message_id) { |n| "msg-#{n}-#{SecureRandom.hex(8)}" }
    domain { 'example.com' }
    attempts { 0 }
    manual { false }
    locked_by { nil }
    locked_at { nil }
    retry_after { nil }
    batch_key { nil }

    trait :locked do
      locked_by { 'test_locker' }
      locked_at { Time.now }
    end

    trait :retry_later do
      retry_after { 1.hour.from_now }
      attempts { 1 }
    end

    trait :batched do
      batch_key { 'test_batch' }
    end

    trait :with_ip_address do
      association :ip_address
    end

    trait :manual do
      manual { true }
    end
  end

  factory :webhook do
    server
    name { 'Test Webhook' }
    url { 'https://example.com/webhook' }
    enabled { true }
    all_events { false }
    last_used_at { nil }

    trait :disabled do
      enabled { false }
    end

    trait :all_events do
      all_events { true }
    end
  end

  factory :webhook_event do
    webhook
    event { 'message.delivered' }
  end

  factory :ip_address, class: 'IPAddress' do
    ip_pool
    sequence(:ipv4) { |n| "10.0.#{n % 255}.#{(n / 255) % 255}" }
    sequence(:hostname) { |n| "mail-#{n}.example.com" }
    priority { 100 }

    trait :high_priority do
      priority { 10 }
    end
  end

  factory :credential do
    server
    type { 'SMTP' }
    sequence(:name) { |n| "Test Credential #{n}" }
    sequence(:key) { |n| "test-key-#{n}" }

    trait :smtp do
      type { 'SMTP' }
    end

    trait :api do
      type { 'API' }
    end

    trait :smtp_ip do
      type { 'SMTP-IP' }
      sequence(:key) { |n| "192.168.#{n % 255}.#{(n / 255) % 255}" }
    end

    trait :held do
      hold { true }
      hold_at { Time.now }
      hold_reason { 'Test hold' }
    end
  end
end
