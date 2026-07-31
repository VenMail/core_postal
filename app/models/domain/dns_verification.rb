require 'resolv'

class Domain

  def dns_verification_string
    "#{Postal.config.dns.domain_verify_prefix} #{verification_token}"
  end

  def verify_with_dns
    return false unless self.verification_method == 'DNS'
    result = resolver.getresources(self.name, Resolv::DNS::Resource::IN::TXT)
    if result.map { |d| d.data.to_s.strip }.include?(self.dns_verification_string)
      verified_at = Time.now
      self.verified_at = verified_at
      self.verification_token_verified_at = verified_at
      self.verification_token_verified_fingerprint = verification_token_proof_fingerprint
      self.save
    else
      check_mx_records
      check_dkim_record
      if self.mx_status == 'OK' || dkim_verified?
        self.verified_at = Time.now
        self.save
      else
        false
      end
    end
  end

end

# -*- SkipSchemaAnnotations
