class VvsAgentKey < ApplicationRecord

  belongs_to :server, optional: true

  validates :agent_name, :domain, :status, presence: true
  validates :key_version, numericality: { greater_than: 0 }
  validates :agent_name, uniqueness: { scope: [:domain, :key_version] }

  scope :active, -> { where(status: 'active') }
  scope :for_agent, ->(name, domain) { where(agent_name: name, domain: domain) }

  def agent_id
    "#{agent_name}@#{domain}"
  end

  def generate_keypair!
    signing_key = Ed25519::SigningKey.generate
    self.private_key = signing_key.to_bytes
    self.public_key = signing_key.verify_key.to_bytes
    self
  end

  def signing_key
    Ed25519::SigningKey.new(private_key)
  end

  def verify_key
    Ed25519::VerifyKey.new(public_key)
  end

  def public_key_base64url
    Base64.urlsafe_encode64(public_key, padding: false)
  end

  def sign(payload)
    signing_key.sign(payload)
  end

end
