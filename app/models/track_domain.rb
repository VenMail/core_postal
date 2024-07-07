# == Schema Information
#
# Table name: track_domains
#
#  id                     :integer          not null, primary key
#  uuid                   :string(255)
#  server_id              :integer
#  domain_id              :integer
#  name                   :string(255)
#  dns_checked_at         :datetime
#  dns_status             :string(255)
#  dns_error              :string(255)
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  ssl_enabled            :boolean          default(TRUE)
#  track_clicks           :boolean          default(TRUE)
#  track_loads            :boolean          default(TRUE)
#  excluded_click_domains :text(65535)
#

require 'resolv'

class TrackDomain < ApplicationRecord

  include HasUUID

  belongs_to :server
  belongs_to :domain

  validates :name, presence: true, format: { with: /\A[a-z0-9\-]+\z/ }, uniqueness: { scope: :domain_id, message: "is already added" }
  validates :domain_id, uniqueness: { scope: :server_id, message: "already has a track domain for this server" }
  validate :validate_domain_belongs_to_server

  scope :ok, -> { where(dns_status: 'OK') }

  after_create :check_dns, unless: :dns_status

  before_validation do
    self.server = self.domain.server if self.domain && self.server.nil?
  end

  def full_name
    "#{name}.#{domain.name}"
  end

  def excluded_click_domains_array
    @excluded_click_domains_array ||= excluded_click_domains ? excluded_click_domains.split("\n").map(&:strip) : []
  end

  def dns_ok?
    dns_status == 'OK'
  end

  def check_dns
    if ssl_enabled?
      check_ssl_dns
    end
  end

  def use_ssl?
    ssl_enabled?
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

  def resolver
    @resolver ||= Postal.config.general.use_local_ns_for_domains? ? Resolv::DNS.new : Resolv::DNS.new(nameserver: nameservers)
  end

  def nameservers
    @nameservers ||= get_nameservers
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

  def cloudflare_ip?(ip)
    ip = IPAddr.new(ip.to_s)
    CLOUDFLARE_IP_RANGES.any? { |range| range.include?(ip) }
  end

  private

  def check_ssl_dns
    if proxied_through_cloudflare?
      self.dns_status = 'OK'
      self.dns_error = nil
    else
      begin
        result = domain.resolver.getresources(full_name, Resolv::DNS::Resource::IN::CNAME)
        records = result.map { |r| r.name.to_s.downcase }
        if records.empty?
          self.dns_status = 'Missing'
          self.dns_error = "There is no record at #{full_name}"
        elsif records.size == 1 && records.first == Postal.config.dns.track_domain
          self.dns_status = 'OK'
          self.dns_error = nil
        else
          self.dns_status = 'Invalid'
          self.dns_error = "There is a CNAME record at #{full_name} but it points to #{records.first} which is incorrect. It should point to #{Postal.config.dns.track_domain}."
        end
      rescue Resolv::ResolvError => e
        self.dns_status = 'Error'
        self.dns_error = "DNS resolution error: #{e.message}"
      end
    end
    self.dns_checked_at = Time.now
    save!
    dns_ok?
  end

  def check_non_ssl_dns
    # Implement logic for non-SSL DNS checks here, if different from SSL-enabled checks
    # For example:
    # if non_ssl_conditions_met?
    #   perform_non_ssl_check
    # end
  end

  def validate_domain_belongs_to_server
    if domain && ![server, server.organization].include?(domain.owner)
      errors.add :domain, "does not belong to the server or the server's organization"
    end
  end

end
