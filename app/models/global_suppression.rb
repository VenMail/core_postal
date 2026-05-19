require 'ipaddr'

class GlobalSuppression < ApplicationRecord
  
  self.table_name = 'global_suppressions'
  
  validates :ip_address, presence: true, uniqueness: true
  validates :reason, presence: true
  
  before_validation :normalize_ip_address
  
  scope :active, -> { where(keep_until: nil).or(where("keep_until >= ?", Time.now)) }
  scope :by_ip, ->(ip) {
    normalized_ip = normalize_ip_address_string(ip)
    normalized_ip ? where(ip_address: normalized_ip) : none
  }
  
  def self.ban_ip(ip_address, reason: "Manual IP ban")
    normalized_ip = normalize_ip_address_string(ip_address)
    return false unless normalized_ip

    suppression = where(ip_address: normalized_ip).first_or_initialize
    return suppression if suppression.persisted? && suppression.active?

    suppression.reason = reason
    suppression.keep_until = nil # Permanent ban by default
    suppression.save!
    suppression
  end
  
  def self.unban_ip(ip_address)
    normalized_ip = normalize_ip_address_string(ip_address)
    return false unless normalized_ip
    
    where(ip_address: normalized_ip).destroy_all.count > 0
  end
  
  def self.ip_banned?(ip_address)
    normalized_ip = normalize_ip_address_string(ip_address)
    return false unless normalized_ip

    # Include the raw cleaned value so legacy rows saved before IPv4-mapped
    # normalization still match while existing data is being cleaned up.
    exact_candidates = [normalized_ip, clean_ip_string(ip_address)].compact.uniq
    return true if where(ip_address: exact_candidates).active.exists?

    ipaddr = IPAddr.new(normalized_ip.split('/', 2).first)
    active.where("ip_address LIKE '%/%'").any? do |suppression|
      range = IPAddr.new(suppression.ip_address)
      range.include?(ipaddr)
    rescue IPAddr::InvalidAddressError
      false
    end
  rescue IPAddr::InvalidAddressError
    false
  end
  
  def self.prune_expired
    where("keep_until < ?", Time.now).destroy_all
  end
  
  def active?
    keep_until.nil? || keep_until > Time.now
  end
  
  private
  
  def normalize_ip_address
    self.ip_address = self.class.normalize_ip_address_string(ip_address)
  end
  
  def self.normalize_ip_address_string(ip)
    value = clean_ip_string(ip)
    return nil if value.blank?

    if value.include?('/')
      address, prefix = value.split('/', 2)
      prefix_length = Integer(prefix, exception: false)
      return nil unless prefix_length

      parsed = IPAddr.new("#{normalize_ipv4_mapped(address)}/#{prefix_length}")
      max_prefix = parsed.ipv4? ? 32 : 128
      return nil unless prefix_length.between?(0, max_prefix)

      "#{native_ip_string(parsed)}/#{prefix_length}"
    else
      native_ip_string(IPAddr.new(normalize_ipv4_mapped(value)))
    end
  rescue IPAddr::InvalidAddressError
    nil
  end

  def self.clean_ip_string(ip)
    return nil if ip.blank?

    ip.to_s.strip.downcase.gsub(/\A\[|\]\z/, '')
  end

  def self.normalize_ipv4_mapped(value)
    value.to_s.sub(/\A::ffff:/i, '')
  end

  def self.native_ip_string(ipaddr)
    if ipaddr.respond_to?(:ipv4_mapped?) && ipaddr.ipv4_mapped?
      ipaddr.native.to_s
    else
      normalize_ipv4_mapped(ipaddr.to_s)
    end
  end
  
end
