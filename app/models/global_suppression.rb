class GlobalSuppression < ApplicationRecord
  
  self.table_name = 'global_suppressions'
  
  validates :ip_address, presence: true, uniqueness: true
  validates :reason, presence: true
  
  before_validation :normalize_ip_address
  
  scope :active, -> { where(keep_until: nil).or(where("keep_until >= ?", Time.now)) }
  scope :by_ip, ->(ip) { where(ip_address: ip) }
  
  def self.ban_ip(ip_address, reason: "Manual IP ban")
    normalized_ip = normalize_ip_address_string(ip_address)
    return false unless normalized_ip
    
    where(ip_address: normalized_ip).first_or_create!(
      reason: reason,
      keep_until: nil # Permanent ban by default
    )
  end
  
  def self.unban_ip(ip_address)
    normalized_ip = normalize_ip_address_string(ip_address)
    return false unless normalized_ip
    
    where(ip_address: normalized_ip).destroy_all > 0
  end
  
  def self.ip_banned?(ip_address)
    normalized_ip = normalize_ip_address_string(ip_address)
    return false unless normalized_ip
    
    by_ip(normalized_ip).active.exists?
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
    return nil if ip.blank?
    
    # Basic IP validation and normalization
    ip.strip.downcase
  rescue
    nil
  end
  
end
