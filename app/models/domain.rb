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
#  verification_token_verified_at :datetime
#  verification_token_verified_fingerprint :string(255)
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

require 'digest'
require 'resolv'

class Domain < ApplicationRecord

  include HasUUID

  require_dependency 'domain/dns_checks'
  require_dependency 'domain/dns_verification'

  VERIFICATION_EMAIL_ALIASES = ['webmaster', 'postmaster', 'admin', 'administrator', 'hostmaster']

  belongs_to :server, optional: true
  belongs_to :owner, optional: true, polymorphic: true
  has_many :routes, dependent: :destroy
  has_many :track_domains, dependent: :destroy

  VERIFICATION_METHODS = ['DNS', 'Email']
  DKIM_KEY_BITS = 2048
  DKIM_SELECTOR_SUFFIX_PATTERN = /\A[A-Za-z0-9_-]+\z/
  DKIM_SELECTOR_PREFIX_PATTERN = /\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/

  validates :name, presence: true, format: { with: /\A[a-z0-9\-\.]*\z/ }, uniqueness: { scope: [:owner_type, :owner_id], message: "is already added" }
  validates :verification_method, inclusion: { in: VERIFICATION_METHODS }
  validate :dkim_private_key_is_valid, if: :dkim_private_key_changed?
  validate :dkim_identifier_string_is_valid, if: :dkim_identifier_string_changed?

  before_validation :validate_dkim_identifier_string_before_generation, :prepend => true
  random_string :dkim_identifier_string, type: :chars, length: 6, unique: true, upper_letters_only: true

  before_create :generate_dkim_key, unless: :dkim_private_key_provided?
  before_create :set_default_daily_send_limit

  scope :verified, -> { where.not(verified_at: nil) }

  def self.for_api_server(server)
    server_domains = where(:owner_type => 'Server', :owner_id => server.id)
    return server_domains unless server.organization_id

    server_domains.or(where(:owner_type => 'Organization', :owner_id => server.organization_id))
  end

  def self.for_routing_server(server)
    for_api_server(server)
  end

  def self.configured_dkim_identifier_prefix
    prefix = Postal.config.dns.dkim_identifier.to_s
    unless prefix.present? && prefix == prefix.strip && prefix.ascii_only? && prefix.match?(DKIM_SELECTOR_PREFIX_PATTERN) && prefix.bytesize < 63
      raise ArgumentError, 'Configured DKIM selector prefix must be a valid DNS label'
    end

    prefix
  end

  def self.dkim_identifier_string_for_suffix(suffix)
    prefix = configured_dkim_identifier_prefix
    supplied_suffix = suffix.to_s

    unless supplied_suffix.present? && supplied_suffix == supplied_suffix.strip && supplied_suffix.ascii_only? && supplied_suffix.match?(DKIM_SELECTOR_SUFFIX_PATTERN) && "#{prefix}-#{supplied_suffix}".bytesize <= 63
      raise ArgumentError, 'DKIM identifier must be a valid selector suffix for the configured DKIM selector prefix'
    end

    if supplied_suffix.start_with?("#{prefix}-")
      raise ArgumentError, 'DKIM identifier must be a suffix; use dkim_selector for a full selector'
    end

    supplied_suffix
  end

  def self.dkim_identifier_string_for_selector(selector)
    prefix = configured_dkim_identifier_prefix
    full_prefix = "#{prefix}-"
    supplied_selector = selector.to_s

    unless supplied_selector.start_with?(full_prefix)
      raise ArgumentError, 'DKIM selector must use the configured DKIM selector prefix'
    end

    suffix = supplied_selector[full_prefix.length..-1]
    parsed_suffix = dkim_identifier_string_for_suffix(suffix)
    unless supplied_selector == "#{prefix}-#{parsed_suffix}"
      raise ArgumentError, 'DKIM selector must be an exact DNS label with the configured DKIM selector prefix'
    end

    parsed_suffix
  end

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
      self.verification_token_verified_at = nil
      self.verification_token_verified_fingerprint = nil
    end
  end

  before_save :clear_verification_token_verified_at, if: :verification_proof_changed?
  before_save :clear_dkim_verification_status, if: :dkim_material_changed?

  def verified?
    verified_at.present?
  end

  def verification_token_status
    verification_token_verified? ? 'OK' : 'Pending'
  end

  def verification_token_verified?
    return false unless verification_token_verified_at.present? && verification_token_verified_fingerprint.present?

    ActiveSupport::SecurityUtils.secure_compare(verification_token_verified_fingerprint, verification_token_proof_fingerprint)
  rescue ArgumentError
    false
  end

  def verification_token_proof_fingerprint
    Digest::SHA256.hexdigest(dns_verification_string)
  end

  def dkim_verified?
    dkim_status == 'OK' && api_public_dkim_payload[:status] == 'ready'
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
    @dkim_key ||= OpenSSL::PKey::RSA.new(dkim_private_key)
  end

  def dkim_private_key=(value)
    @dkim_key = nil
    super
  end

  def dkim_identifier
    prefix = self.class.configured_dkim_identifier_prefix
    suffix = self.class.dkim_identifier_string_for_suffix(dkim_identifier_string)
    "#{prefix}-#{suffix}"
  rescue ArgumentError
    nil
  end

  def api_public_payload
    dkim = api_public_dkim_payload

    {
      :id => id,
      :name => name,
      :verified_at => verified_at,
      :created_at => created_at,
      :updated_at => updated_at,
      :dns_checked_at => dns_checked_at,
      :verification_method => verification_method,
      :verification_token => verification_token,
      :verification_token_verified_at => verification_token_verified_at,
      :verification_token_status => verification_token_status,
      :spf_record => spf_record,
      :spf_status => spf_status,
      :spf_error => spf_error,
      :dkim_status => dkim_status,
      :dkim_verified => dkim_verified?,
      :dkim_error => dkim_error,
      :dkim_identifier_string => dkim[:identifier_string],
      :dkim_identifier => dkim[:selector],
      :dkim_selector => dkim[:selector],
      :dkim_record => dkim[:record],
      :dkim_record_name => dkim[:record_name],
      :dkim_material_status => dkim[:status],
      :dkim => dkim,
      :mx_status => mx_status,
      :mx_error => mx_error,
      :return_path_status => return_path_status,
      :return_path_error => return_path_error,
      :outgoing => outgoing,
      :incoming => incoming,
      :owner_type => owner_type,
      :owner_id => owner_id,
      :use_for_any => use_for_any
    }
  end

  def api_public_dkim_payload
    details = {
      :identifier_string => nil,
      :selector => nil,
      :record_name => nil
    }

    prefix = self.class.configured_dkim_identifier_prefix
    suffix = self.class.dkim_identifier_string_for_suffix(dkim_identifier_string)
    selector = "#{prefix}-#{suffix}"
    details.merge!(:identifier_string => suffix, :selector => selector, :record_name => "#{selector}._domainkey")

    return details.merge(:record => nil, :status => 'missing') if dkim_private_key.blank?

    key = dkim_key
    return details.merge(:record => nil, :status => 'invalid') unless key.private? && key.n.num_bits >= DKIM_KEY_BITS

    record = dkim_record
    return details.merge(:record => nil, :status => 'invalid') if record.blank?

    details.merge(:record => record, :status => 'ready')
  rescue OpenSSL::OpenSSLError, ArgumentError, TypeError
    details.merge(:record => nil, :status => 'invalid')
  end

  def as_json(options = nil)
    options = (options || {}).dup
    options[:except] = Array(options[:except]).map(&:to_s) | ['dkim_private_key']
    options[:only] = Array(options[:only]).reject { |attribute| attribute.to_s == 'dkim_private_key' } if options.key?(:only)
    options[:methods] = Array(options[:methods]).reject { |method| method.to_s == 'dkim_private_key' } if options.key?(:methods)

    super(options)
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
    self.dkim_private_key = OpenSSL::PKey::RSA.new(DKIM_KEY_BITS).to_s
    @dkim_key = nil
  end

  def regenerate_dkim_key
    generate_dkim_key
    self.dkim_identifier_string = SecureRandom.alphanumeric(6).upcase
  end

  def dkim_private_key_provided?
    dkim_private_key.present?
  end

  def clear_verification_token_verified_at
    self.verification_token_verified_at = nil
    self.verification_token_verified_fingerprint = nil
  end

  def verification_proof_changed?
    verification_token_changed? || name_changed?
  end

  def dkim_material_changed?
    dkim_private_key_changed? || dkim_identifier_string_changed?
  end

  def clear_dkim_verification_status
    self.dkim_status = nil
    self.dkim_error = nil
  end

  def validate_dkim_identifier_string_before_generation
    return unless dkim_identifier_string_changed?

    self.class.dkim_identifier_string_for_suffix(dkim_identifier_string)
  rescue ArgumentError => e
    errors.add(:dkim_identifier_string, e.message)
  end

  def dkim_identifier_string_is_valid
    self.class.dkim_identifier_string_for_suffix(dkim_identifier_string)
  rescue ArgumentError => e
    errors.add(:dkim_identifier_string, e.message)
  end

  def dkim_private_key_is_valid
    unless dkim_private_key.present?
      errors.add(:dkim_private_key, 'must be a valid RSA private key')
      return
    end

    key = OpenSSL::PKey::RSA.new(dkim_private_key)
    unless key.private?
      errors.add(:dkim_private_key, 'must be a valid RSA private key')
    else
      errors.add(:dkim_private_key, "must be at least #{DKIM_KEY_BITS} bits") if key.n.num_bits < DKIM_KEY_BITS
    end
  rescue OpenSSL::OpenSSLError, ArgumentError, TypeError
    errors.add(:dkim_private_key, 'must be a valid RSA private key')
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
  rescue OpenSSL::OpenSSLError, ArgumentError, TypeError
    nil
  end

  def dkim_record_name
    selector = dkim_identifier
    selector && "#{selector}._domainkey"
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
