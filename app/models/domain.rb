# == Schema Information
#
# Table name: domains
#
#  id                     :integer          not null, primary key
#  server_id              :integer
#  uuid                   :string(255)
#  name                   :string(255)
#  verification_token     :string(255)
#  verification_method    :string(255)
#  verified_at            :datetime
#  dkim_private_key       :text(65535)
#  created_at             :datetime
#  updated_at             :datetime
#  dns_checked_at         :datetime
#  spf_status             :string(255)
#  spf_error              :string(255)
#  dkim_status            :string(255)
#  dkim_error             :string(255)
#  mx_status              :string(255)
#  mx_error               :string(255)
#  return_path_status     :string(255)
#  return_path_error      :string(255)
#  outgoing               :boolean          default(TRUE)
#  incoming               :boolean          default(TRUE)
#  owner_type             :string(255)
#  owner_id               :integer
#  dkim_identifier_string :string(255)
#  use_for_any            :boolean
#
# Indexes
#
#  index_domains_on_server_id  (server_id)
#  index_domains_on_uuid       (uuid)
#

require 'resolv'

class Domain < ApplicationRecord

  DKIM_MINIMUM_RSA_BITS = 2048
  DKIM_IDENTIFIER_STRING_PATTERN = /\A[A-Za-z0-9_-]{1,63}\z/

  include HasUUID

  require_dependency 'domain/dns_checks'
  require_dependency 'domain/dns_verification'

  VERIFICATION_EMAIL_ALIASES = ['webmaster', 'postmaster', 'admin', 'administrator', 'hostmaster']

  belongs_to :server, optional: true
  belongs_to :owner, optional: true, polymorphic: true
  has_many :routes, dependent: :destroy
  has_many :track_domains, dependent: :destroy

  VERIFICATION_METHODS = ['DNS', 'Email']

  validates :name, presence: true, format: { with: /\A[a-z0-9\-\.]*\z/ }, uniqueness: { scope: [:owner_type, :owner_id], message: "is already added" }
  validates :verification_method, inclusion: { in: VERIFICATION_METHODS }
  validate :validate_dkim_private_key, if: :dkim_private_key_changed?
  validate :validate_dkim_identifier_string, if: -> { dkim_identifier_string_changed? && dkim_identifier_string.present? }

  random_string :dkim_identifier_string, type: :chars, length: 6, unique: true, upper_letters_only: true

  before_validation :generate_dkim_key, on: :create, unless: :dkim_private_key_provided?
  before_create :set_default_daily_send_limit

  scope :verified, -> { where.not(verified_at: nil) }

  when_attribute :verification_method, changes_to: :anything do
    before_save do
      self.verification_token = case self.verification_method
                                when 'DNS'
                                  Nifty::Utils::RandomString.generate(length: 32)
                                when 'Email'
                                  rand(999999).to_s.ljust(6, '0')
                                else
                                  nil
                                end
    end
  end

  def verified?
    verified_at.present?
  end

  CLOUDFLARE_IP_RANGES = [
    IPAddr.new('173.245.48.0/20'),
    IPAddr.new('103.21.244.0/22'),
    IPAddr.new('103.22.200.0/22'),
    IPAddr.new('103.31.4.0/22'),
    IPAddr.new('141.101.64.0/18'),
    IPAddr.new('108.162.192.0/18'),
    IPAddr.new('190.93.240.0/20'),
    IPAddr.new('188.114.96.0/20'),
    IPAddr.new('197.234.240.0/22'),
    IPAddr.new('198.41.128.0/17'),
    IPAddr.new('162.158.0.0/15'),
    IPAddr.new('104.16.0.0/13'),
    IPAddr.new('104.24.0.0/14'),
    IPAddr.new('172.64.0.0/13'),
    IPAddr.new('131.0.72.0/22'),

    IPAddr.new('2400:cb00::/32'),
    IPAddr.new('2606:4700::/32'),
    IPAddr.new('2803:f800::/32'),
    IPAddr.new('2405:b500::/32'),
    IPAddr.new('2405:8100::/32'),
    IPAddr.new('2a06:98c0::/29'),
    IPAddr.new('2c0f:f248::/32')
  ]

  def proxied_through_cloudflare?(name = self.name)
    begin
      a_records = resolver.getresources(name, Resolv::DNS::Resource::IN::A)
      a_records.any? { |record| cloudflare_ip?(record.address) }
    rescue Resolv::ResolvError
      false
    end
  end

  def dkim_key
    return @dkim_key if defined?(@dkim_key_material) && @dkim_key_material == dkim_private_key

    @dkim_key_material = dkim_private_key
    @dkim_key = OpenSSL::PKey::RSA.new(dkim_private_key)
  end

  def dkim_identifier
    return nil unless dkim_identifier_string_valid?

    "#{Postal.config.dns.dkim_identifier}-#{dkim_identifier_string}"
  end

  def cloudflare_ip?(ip)
    ip = IPAddr.new(ip.to_s)
    CLOUDFLARE_IP_RANGES.any? { |range| range.include?(ip) }
  end

  def verify
    self.verified_at = Time.now
    save!
  end

  def parent_domains
    parts = name.split('.')
    parts[0, parts.size - 1].each_with_index.map { |p, i| parts[i..-1].join('.') }
  end

  def generate_dkim_key
    self.dkim_private_key = OpenSSL::PKey::RSA.new(DKIM_MINIMUM_RSA_BITS).to_s
  end

  def regenerate_dkim_key
    generate_dkim_key
    self.dkim_identifier_string = SecureRandom.alphanumeric(6).upcase
  end

  def dkim_private_key_provided?
    dkim_private_key.present?
  end

  def set_default_daily_send_limit
    if self.daily_send_limit.nil?
      default_limit = Postal.config.general.default_domain_daily_send_limit rescue nil
      self.daily_send_limit = (default_limit || 1000).to_i
    end
  end

  def verification_email_addresses
    parent_domains.flat_map { |domain| VERIFICATION_EMAIL_ALIASES.map { |a| "#{a}@#{domain}" } }
  end

  def spf_record
    "v=spf1 a mx include:#{Postal.config.dns.spf_include} ~all"
  end

  def dkim_record
    public_key = dkim_key.public_key.to_s.gsub(/-+[A-Z ]+-+\n/, '').gsub(/\n/, '')
    "v=DKIM1; t=s; h=sha256; p=#{public_key};"
  end

  def dkim_record_name
    identifier = dkim_identifier
    identifier ? "#{identifier}._domainkey" : nil
  end

  # Legacy rows can contain an invalid selector or missing/corrupt signing
  # material. The setup page must not turn those states into a 500 response or
  # publish incomplete DNS instructions.
  def dkim_setup_record
    return nil if dkim_record_name.blank?

    record = dkim_record
    return nil unless record.start_with?('v=DKIM1;') && record.match?(/(?:\A|;\s*)p=[^;\s]+;/)

    record
  rescue OpenSSL::PKey::RSAError, OpenSSL::PKey::PKeyError, ArgumentError, TypeError
    nil
  end

  # Domain JSON is used in several legacy paths. Keep the private signing key out of
  # generic serialization so a new API action cannot disclose it by accident. APIs
  # which legitimately need it must use DomainApiPayload with an authenticated owner.
  def serializable_hash(options = nil)
    redact_dkim_private_key(super(options))
  end

  def as_json(options = nil)
    redact_dkim_private_key(super(options))
  end

  def return_path_domain
    "#{Postal.config.dns.custom_return_path_prefix}.#{name}"
  end

  def nameservers
    @nameservers ||= get_nameservers
  end

  def resolver
    @resolver ||= Postal.config.general.use_local_ns_for_domains? ? Resolv::DNS.new : Resolv::DNS.new(nameserver: nameservers)
  end

  private

  def redact_dkim_private_key(payload)
    payload.delete('dkim_private_key')
    payload.delete(:dkim_private_key)
    payload
  end

  def validate_dkim_private_key
    key = OpenSSL::PKey::RSA.new(dkim_private_key)

    unless key.private?
      errors.add(:dkim_private_key, 'must be a valid RSA private key')
      return
    end

    if key.n.num_bits < DKIM_MINIMUM_RSA_BITS
      errors.add(:dkim_private_key, "must be at least #{DKIM_MINIMUM_RSA_BITS} bits")
    end
  rescue OpenSSL::PKey::RSAError, OpenSSL::PKey::PKeyError, ArgumentError, TypeError
    errors.add(:dkim_private_key, 'must be a valid RSA private key')
  end

  def validate_dkim_identifier_string
    unless dkim_identifier_string_valid?
      errors.add(:dkim_identifier_string, 'must be a valid DKIM selector suffix')
    end
  end

  def dkim_identifier_string_valid?
    dkim_identifier_string.present? && dkim_identifier_string.match?(DKIM_IDENTIFIER_STRING_PATTERN)
  end

  def get_nameservers
    local_resolver = Resolv::DNS.new
    ns_records = []
    parts = name.split('.')
    (parts.size - 1).times do |n|
      d = parts[n, parts.size - n + 1].join('.')
      ns_records = local_resolver.getresources(d, Resolv::DNS::Resource::IN::NS).map(&:name)
      break unless ns_records.blank?
    end
    return [] if ns_records.blank?

    ns_records = ns_records.map { |r| local_resolver.getresources(r, Resolv::DNS::Resource::IN::A).map(&:address) }.flatten
    return [] if ns_records.blank?

    ns_records
  end

end
