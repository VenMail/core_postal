require 'resolv'

class Domain

  def dns_verification_string
    "#{Postal.config.dns.domain_verify_prefix} #{verification_token}"
  end

  def verify_with_dns
    return false unless self.verification_method == 'DNS'
    result = resolver.getresources(self.name, Resolv::DNS::Resource::IN::TXT)
    if result.map { |d| d.data.to_s.strip }.include?(self.dns_verification_string)
      self.verified_at = Time.now
      self.save
    else
      check_mx_records
      check_dkim_record
      if self.mx_status == 'OK' || self.dkim_status == 'OK'
        self.verified_at = Time.now
        self.save
      else
        false
      end
    end
  end

end

# -*- SkipSchemaAnnotations
