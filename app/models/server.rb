# == Schema Information
#
# Table name: servers
#
#  id                                 :integer          not null, primary key
#  organization_id                    :integer
#  uuid                               :string(255)
#  name                               :string(255)
#  mode                               :string(255)
#  ip_pool_id                         :integer
#  created_at                         :datetime
#  updated_at                         :datetime
#  permalink                          :string(255)
#  send_limit                         :integer
#  deleted_at                         :datetime
#  message_retention_days             :integer
#  raw_message_retention_days         :integer
#  raw_message_retention_size         :integer
#  allow_sender                       :boolean          default(FALSE)
#  token                              :string(255)
#  send_limit_approaching_at          :datetime
#  send_limit_approaching_notified_at :datetime
#  send_limit_exceeded_at             :datetime
#  send_limit_exceeded_notified_at    :datetime
#  spam_threshold                     :decimal(8, 2)
#  spam_failure_threshold             :decimal(8, 2)
#  postmaster_address                 :string(255)
#  suspended_at                       :datetime
#  outbound_spam_threshold            :decimal(8, 2)
#  domains_not_to_click_track         :text(65535)
#  suspension_reason                  :string(255)
#  log_smtp_data                      :boolean          default(FALSE)
#
# Indexes
#
#  index_servers_on_organization_id  (organization_id)
#  index_servers_on_permalink        (permalink)
#  index_servers_on_token            (token)
#  index_servers_on_uuid             (uuid)
#

class Server < ApplicationRecord

  RESERVED_PERMALINKS = ['new', 'all', 'search', 'stats', 'edit', 'manage', 'delete', 'destroy', 'remove']
  EMAIL_ADDRESS_REGEX = /[A-Z0-9._%+\-']+@[A-Z0-9.\-]+\.[A-Z]{2,}/i.freeze

  include HasUUID
  include HasSoftDestroy

  attr_accessor :provision_database

  belongs_to :organization
  belongs_to :ip_pool, :optional => true
  has_many :domains, :dependent => :destroy, :as => :owner
  has_many :credentials, :dependent => :destroy
  has_many :smtp_endpoints, :dependent => :destroy
  has_many :http_endpoints, :dependent => :destroy
  has_many :address_endpoints, :dependent => :destroy
  has_many :routes, :dependent => :destroy
  has_many :queued_messages, :dependent => :delete_all
  has_many :webhooks, :dependent => :destroy
  has_many :webhook_requests, :dependent => :destroy
  has_many :track_domains, :dependent => :destroy
  has_many :ip_pool_rules, :dependent => :destroy, :as => :owner
  delegate :ip_pools, to: :organization, allow_nil: true

  def ip_pools_with_defaults
    return IPPool.none unless Postal.ip_pools?
    
    pools = organization.ip_pools || IPPool.none
    default_pools = default_ip_pools
    
    # Combine organization pools with default pools, avoiding duplicates
    if default_pools.any?
      pool_ids = pools.pluck(:id) + default_pools.pluck(:id)
      IPPool.where(:id => pool_ids.uniq)
    else
      pools
    end
  end

  MODES = ['Live', 'Development']

  random_string :token, :type => :chars, :length => 6, :unique => true, :upper_letters_only => true
  default_value :permalink, -> { name ? name.parameterize : nil}
  default_value :raw_message_retention_days, -> { 30 }
  default_value :raw_message_retention_size, -> { 2048 }
  default_value :message_retention_days, -> { 60 }
  default_value :spam_threshold, -> { Postal.config.general.default_spam_threshold }
  default_value :spam_failure_threshold, -> { Postal.config.general.default_spam_failure_threshold }

  validates :name, :presence => true, :uniqueness => {:scope => :organization_id}
  validates :mode, :inclusion => {:in => MODES}
  validates :permalink, :presence => true, :uniqueness => {:scope => :organization_id}, :format => {:with => /\A[a-z0-9\-]*\z/}, :exclusion => {:in => RESERVED_PERMALINKS}
  validate :validate_ip_pool_belongs_to_organization

  before_validation(:on => :create) do
    self.token = self.token.downcase if self.token
  end

  after_create do
    unless self.provision_database == false
      message_db.provisioner.provision
    end
  end

  after_commit(:on => :destroy) do
    unless self.provision_database == false
      message_db.provisioner.drop
    end
  end

  def status
    if self.suspended?
      'Suspended'
    else
      self.mode
    end
  end

  def full_permalink
    "#{organization.permalink}/#{permalink}"
  end

  def suspended?
    suspended_at.present? || organization.suspended?
  end

  def actual_suspension_reason
    if suspended?
      if suspended_at.nil?
        organization.suspension_reason
      else
        self.suspension_reason
      end
    end
  end

  def to_param
    permalink
  end

  def message_db
    @message_db ||= Postal::MessageDB::Database.new(self.organization_id, self.id)
  end

  def message(id)
    message_db.message(id)
  end

  def message_rate
    @message_rate ||= message_db.live_stats.total(60, :types => [:incoming, :outgoing]) / 60.0
  end

  def held_messages
    @held_messages ||= message_db.messages(:where => {:held => 1}, :count => true)
  end

  def throughput_stats
    @throughput_stats ||= begin
      incoming = message_db.live_stats.total(60, :types => [:incoming])
      outgoing = message_db.live_stats.total(60, :types => [:outgoing])
      outgoing_usage = send_limit ? (outgoing / send_limit.to_f) * 100 : 0
      {
        :incoming => incoming,
        :outgoing => outgoing,
        :outgoing_usage => outgoing_usage
      }
    end
  end

  def bounce_rate
    @bounce_rate ||= begin
      time = Time.now.utc
      total_outgoing = 0.0
      total_bounces = 0.0
      message_db.statistics.get(:daily, [:outgoing, :bounces], time, 30).each do |date, stat|
        total_outgoing += stat[:outgoing]
        total_bounces += stat[:bounces]
      end
      total_outgoing == 0 ? 0 : (total_bounces / total_outgoing) * 100
    end
  end

  def domain_stats
    domains = Domain.where(:owner_id => self.id, :owner_type => 'Server').to_a
    total, unverified, bad_dns = 0, 0, 0
    domains.each do |domain|
      total += 1
      unverified += 1 unless domain.verified?
      bad_dns += 1 if domain.verified? && !domain.dns_ok?
    end
    [total, unverified, bad_dns]
  end

  def has_verified_route_for?(domain)
    domain_name = if domain.respond_to?(:name)
                    domain.name
                  else
                    domain.to_s
                  end
    return false if domain_name.blank?

    routes.joins(:domain)
          .where("LOWER(domains.name) = ?", domain_name.downcase)
          .exists?
  end

  def verified_route_available_for_sender?(address, domain = nil)
    return true if has_verified_route_for?(domain)

    address = normalize_email_address(address)
    return false if address.blank?

    _local_part, domain_name = address.split('@', 2)
    return true if has_verified_route_for?(domain_name)

    api_available_sender_address_authorized?(address)
  end

  def webhook_hash
    {
      :uuid => self.uuid,
      :name => self.name,
      :permalink => self.permalink,
      :organization => self.organization&.permalink
    }
  end

  def send_volume
    @send_volume ||= message_db.live_stats.total(60, :types => [:outgoing])
  end

  def send_limit_approaching?
    self.send_limit && (send_volume >= self.send_limit * 0.90)
  end

  def send_limit_exceeded?
    self.send_limit && send_volume >= self.send_limit
  end

  def send_limit_warning(type)
    AppMailer.send("server_send_limit_#{type}", self).deliver
    self.update_column("send_limit_#{type}_notified_at", Time.now)
    WebhookRequest.trigger(self, "SendLimit#{type.to_s.capitalize}", :server => webhook_hash, :volume => self.send_volume, :limit => self.send_limit)
  end

  def queue_size
    @queue_size ||= queued_messages.retriable.count
  end

  def stats
    {
      :queue => queue_size,
      :held => self.held_messages,
      :bounce_rate => self.bounce_rate,
      :message_rate => self.message_rate,
      :throughput => self.throughput_stats,
      :size => self.message_db.total_size
    }
  end

  def authenticated_domain_for_address(address)
    address = normalize_email_address(address)
    return nil if address.blank?

    uname, domain_name = address.split('@', 2)
    uname, _ = uname.split('+', 2)

    # Check the server's domain
    domain_scope = Domain.verified.where(:outgoing => true)
    domain_scope = domain_scope.where("(owner_type = 'Organization' AND owner_id = ?) OR (owner_type = 'Server' AND owner_id = ?)", self.organization_id, self.id)
    if domain = domain_scope.order(:owner_type => :desc).where("LOWER(name) = ?", domain_name).first
      return domain
    end

    if any_domain = self.domains.verified.where(:outgoing => true, :use_for_any => true).order(:name).first
      return any_domain
    end
  end

  def normalize_email_address(address)
    stripped = Postal::Helpers.strip_name_from_address(address).to_s.strip
    email = stripped[EMAIL_ADDRESS_REGEX] || stripped
    email = email.to_s.downcase.gsub(/\A['"]+|['"]+\z/, '')
    return nil unless email =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

    email
  end

  def sender_address_authorized?(address, domain = nil)
    address = normalize_email_address(address)
    return false if address.blank?

    local_part, domain_name = address.split('@', 2)
    local_part, = local_part.split('+', 2)
    domain ||= authenticated_domain_for_address(address)
    return false unless domain
    return false unless domain.name.to_s.casecmp(domain_name).zero?

    exact_route_exists?(local_part, domain_name) || mail_user_exists?(address) || api_available_sender_address_authorized?(address)
  end

  def exact_route_exists?(local_part, domain_name)
    return false if local_part.blank? || domain_name.blank?

    routes.joins(:domain)
          .where("LOWER(routes.name) = ? AND LOWER(domains.name) = ?", local_part.downcase, domain_name.downcase)
          .where.not(:name => ['*', '__returnpath__'])
          .exists?
  end

  def mail_user_exists?(address)
    user = message_db.mail_user.find(address)
    return false unless user

    active = user['active']
    active.nil? || active == true || active.to_s == '1'
  rescue => e
    Rails.logger.warn "Sender address lookup failed for #{address}: #{e.class}: #{e.message}" if defined?(Rails)
    false
  end

  def api_available_sender_address_authorized?(address)
    address = normalize_email_address(address)
    return false if address.blank?

    @api_available_sender_authorization_cache ||= {}
    return @api_available_sender_authorization_cache[address] if @api_available_sender_authorization_cache.key?(address)

    response = Postal::AvailableRouteLookup.lookup(address) do |text|
      Rails.logger.debug(text) if defined?(Rails)
    end

    authorized = false
    if response && response['found']
      main_email = normalize_email_address(response['main_email'])
      if main_email.present? && main_email != address
        local_part, domain_name = main_email.split('@', 2)
        local_part, = local_part.split('+', 2)

        domain = authenticated_domain_for_address(main_email)
        authorized = domain.present? &&
                     domain.name.to_s.casecmp(domain_name).zero? &&
                     (exact_route_exists?(local_part, domain_name) || mail_user_exists?(main_email))
      end
    end

    @api_available_sender_authorization_cache[address] = authorized
  rescue => e
    Rails.logger.warn "API available sender lookup failed for #{address}: #{e.class}: #{e.message}" if defined?(Rails)
    @api_available_sender_authorization_cache[address] = false
  end

  def authenticated_sender_from_headers(headers)
    header_to_check = ['from']
    header_to_check << 'sender' if self.allow_sender?
    header_to_check.each do |header_name|
      values = headers[header_name].is_a?(Array) ? headers[header_name] : [headers[header_name].to_s]
      addresses = values.map { |value| normalize_email_address(value) }.compact
      next unless addresses.size == values.size

      authenticated = addresses.map do |address|
        domain = authenticated_domain_for_address(address)
        sender_address_authorized?(address, domain) ? { :domain => domain, :address => address, :header => header_name } : nil
      end.compact
      return authenticated.first if authenticated.size == values.size
    end
    nil
  end

  def find_authenticated_domain_from_headers(headers)
    authenticated_sender_from_headers(headers)&.[](:domain)
  end

  def suspend(reason)
    self.suspended_at = Time.now
    self.suspension_reason = reason
    self.save!
    WebhookRequest.trigger(self, 'ServerSuspended', { :server => self.webhook_hash, :reason => reason })
    AppMailer.server_suspended(self).deliver
  end

  def unsuspend
    self.suspended_at = nil
    self.suspension_reason = nil
    self.save!
  end

  def validate_ip_pool_belongs_to_organization
    if self.ip_pool && self.ip_pool_id_changed? && !self.organization.ip_pools.include?(self.ip_pool)
      errors.add :ip_pool_id, "must belong to the organization"
    end
  end

  def ip_pool_for_message(message)
    if message.scope == 'outgoing'
      [self, self.organization].each do |scope|
        rules = scope.ip_pool_rules.order(:created_at => :desc)
        rules.each do |rule|
          if rule.apply_to_message?(message)
            return rule.ip_pool
          end
        end
      end
      self.ip_pool || default_ip_pools.first
    else
      nil
    end
  end

  def default_ip_pools
    return [] unless Postal.ip_pools?
    return [] if Postal.default_ip_pool_names.empty?
    IPPool.where(:name => Postal.default_ip_pool_names)
  end

  def self.triggered_send_limit(type)
    servers = where("send_limit_#{type}_at IS NOT NULL AND send_limit_#{type}_at > ?", 3.minutes.ago)
    servers.where("send_limit_#{type}_notified_at IS NULL OR send_limit_#{type}_notified_at < ?", 1.hour.ago)
  end

  def self.send_send_limit_notifications
    [:approaching, :exceeded].each_with_object({}) do |type, hash|
      hash[type] = 0
      servers = self.triggered_send_limit(type)
      unless servers.empty?
        servers.each do |server|
          hash[type] += 1
          server.send_limit_warning(type)
        end
      end
    end
  end

  def self.[](id, extra = nil)
    server = nil
    if id.is_a?(String)
      if id =~ /\A(\w+)\/(\w+)\z/
        server = includes(:organization).where(:organizations => {:permalink => $1}, :permalink => $2).first
      end
    else
      server = where(:id => id).first
    end

    if extra
      if extra.is_a?(String)
        server.domains.where(:name => extra.to_s).first
      else
        server.message(extra.to_i)
      end
    else
      server
    end
  end

end
