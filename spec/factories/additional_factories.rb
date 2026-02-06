FactoryBot.define do
  factory :global_suppression do
    ip_address { generate(:ip_address) }
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
    payload { { 'message_id' => generate(:uuid), 'status' => 'delivered' } }
    attempts { 0 }
    retry_after { nil }
    uuid { generate(:uuid) }

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
    organization
    email_address { generate(:email) }
    token { generate(:token) }
    expires_at { 7.days.from_now }
    user { nil }

    trait :expired do
      expires_at { 1.hour.ago }
    end

    trait :accepted do
      association :user
    end
  end

  factory :queued_message do
    server
    message_id { generate(:uuid) }
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

  factory :ip_address do
    ip_pool
    address { generate(:ip_address) }
    priority { 1 }
    enabled { true }

    trait :disabled do
      enabled { false }
    end

    trait :high_priority do
      priority { 10 }
    end
  end

  factory :credential do
    server
    type { 'SMTP' }
    username { generate(:username) }
    password { generate(:password) }
    enabled { true }

    trait :smtp do
      type { 'SMTP' }
    end

    trait :api do
      type { 'API' }
    end

    trait :disabled do
      enabled { false }
    end
  end
end
