class DomainApiPayload
  # This is intentionally an allowlist. Do not replace it with Domain#as_json:
  # Domain records contain DKIM signing material and internal transport metadata.
  PUBLIC_FIELDS = [
    :id,
    :name,
    :verified_at,
    :dns_checked_at,
    :verification_method,
    :verification_token,
    :spf_record,
    :spf_status,
    :spf_error,
    :dkim_status,
    :dkim_error,
    :mx_status,
    :mx_error,
    :return_path_status,
    :return_path_error,
    :outgoing,
    :incoming,
    :owner_type,
    :owner_id,
    :use_for_any,
    :created_at,
    :updated_at
  ].freeze

  def self.build(domain, options = {})
    server = options[:server]
    include_private_key = options[:include_private_key] == true && privately_owned_by?(domain, server)

    payload = PUBLIC_FIELDS.each_with_object({}) do |field, result|
      result[field] = domain.public_send(field)
    end

    payload.merge!(dkim_fields(domain))
    payload[:dkim_private_key] = domain.dkim_private_key if include_private_key
    payload
  end

  def self.privately_owned_by?(domain, server)
    server.present? && domain.owner_type == 'Server' && domain.owner_id == server.id
  end

  def self.dkim_fields(domain)
    identifier = domain.dkim_identifier

    {
      :dkim_identifier_string => identifier ? domain.dkim_identifier_string : nil,
      :dkim_identifier => identifier,
      :dkim_record => identifier ? safely_read_dkim_record(domain) : nil,
      :dkim_record_name => domain.dkim_record_name
    }
  end

  def self.safely_read_dkim_record(domain)
    domain.dkim_record
  rescue OpenSSL::PKey::RSAError, OpenSSL::PKey::PKeyError, ArgumentError, TypeError
    nil
  end
  private_class_method :safely_read_dkim_record
end
