controller :domains do
  friendly_name 'Domains API'
  description 'This API allows the authenticated server to manage only its own domains.'
  authenticator :server

  action :get do
    title 'Get domain details'
    description 'Retrieve public details of a domain owned by the authenticated server.'

    param :id, 'ID of the domain', :type => Integer, :required => true
    param :include_private_key, 'Include the DKIM private key for this authenticated server-owned domain', :type => :boolean, :required => false
    returns Hash

    action do
      domain = DomainApiAccess.new(identity.server).find_by_id(params.id)
      error("Domain with ID #{params.id} not found", 404) unless domain

      DomainApiPayload.build(domain, :server => identity.server, :include_private_key => params.include_private_key == true)
    end
  end

  action :find_by_name do
    title 'Find domain by name'
    description 'Retrieve public details of an authenticated server-owned domain by name.'

    param :name, 'Name of the domain (e.g., example.com)', :type => String, :required => true
    param :include_private_key, 'Include the DKIM private key for this authenticated server-owned domain', :type => :boolean, :required => false
    returns Hash

    action do
      domain = DomainApiAccess.new(identity.server).find_by_name(params.name)
      error("Domain with name '#{params.name}' not found", 404) unless domain

      DomainApiPayload.build(domain, :server => identity.server, :include_private_key => params.include_private_key == true)
    end
  end

  action :domain do
    title 'Add a domain'
    description 'Add a domain to the authenticated server. Supplied BYODKIM private material must be an RSA key of at least 2048 bits.'

    param :name, 'Name of the domain', :type => String
    param :include_private_key, 'Include the generated or BYODKIM private key in this authenticated server-owned response', :type => :boolean, :required => false
    param :dkim_private_key, 'Existing DKIM private key to use (BYODKIM)', :type => String, :required => false
    param :dkim_record, 'Ignored. The public DKIM record is always derived from the accepted private key.', :type => String, :required => false
    param :dkim_identifier_string, 'DKIM identifier suffix to use', :type => String, :required => false
    error 'RecordInvalid', 'The provided data was not sufficient to create a domain', :attributes => { :errors => 'A hash of error details' }
    returns Hash

    action do
      attributes = { :name => params.name, :verification_method => 'DNS' }
      attributes[:dkim_private_key] = params.dkim_private_key if params.dkim_private_key.present?
      attributes[:dkim_identifier_string] = params.dkim_identifier_string if params.dkim_identifier_string.present?

      domain = identity.server.domains.build(attributes)
      unless domain.save
        error 'RecordInvalid', :errors => domain.errors.full_messages
      end

      DomainApiPayload.build(domain, :server => identity.server, :include_private_key => params.include_private_key == true)
    end
  end

  action :list do
    title 'List domains'
    description 'Retrieve public details for domains owned by the authenticated server.'
    returns Array

    action do
      DomainApiAccess.new(identity.server).scope.map do |domain|
        DomainApiPayload.build(domain, :server => identity.server)
      end
    end
  end

  action :verify do
    title 'Verify domain TXT'
    description 'Verify an authenticated server-owned domain.'

    param :id, 'ID of the domain', :type => Integer, :required => true
    param :force, 'Force verification', :type => :boolean, :required => false
    returns Hash

    action do
      domain = DomainApiAccess.new(identity.server).find_by_id(params.id)
      error("Domain with ID #{params.id} not found", 404) unless domain

      if domain.verified?
        domain.check_dns(:manual)
        DomainApiPayload.build(domain, :server => identity.server)
      elsif params.force
        domain.verify
        DomainApiPayload.build(domain, :server => identity.server)
      elsif domain.verify_with_dns
        DomainApiPayload.build(domain, :server => identity.server)
      else
        {
          :success => false,
          :message => 'Invalid verification code. Please check and try again'
        }
      end
    end
  end

  action :destroy do
    title 'Delete domain'
    description 'Delete an authenticated server-owned domain.'

    param :id, 'ID of the domain', :type => Integer, :required => true
    returns Hash

    action do
      domain = DomainApiAccess.new(identity.server).find_directly_owned_by_id(params.id)
      error("Domain with ID #{params.id} not found", 404) unless domain

      if domain.destroy
        {
          :success => true,
          :message => "Domain #{domain.name} deleted successfully"
        }
      else
        error 'Failed to delete domain', :errors => domain.errors.full_messages
      end
    end
  end

  action :update_dkim do
    title 'Update DKIM records (deprecated)'
    description 'Bulk DKIM updates are disabled to prevent unscoped rotation. Use update_single_dkim for an explicit domain repair.'

    param :organization_id, 'Deprecated', :type => Integer, :required => false
    param :dkim_private_key, 'Deprecated', :type => String, :required => false
    param :dkim_identifier_string, 'Deprecated', :type => String, :required => false
    param :regenerate_keys, 'Deprecated', :type => :boolean, :required => false
    param :dry_run, 'Deprecated', :type => :boolean, :required => false
    param :force, 'Deprecated', :type => :boolean, :required => false
    returns Hash

    action do
      error 'Bulk DKIM updates are disabled. Use update_single_dkim with a server-owned domain ID for an explicit repair.', 422
    end
  end

  action :update_single_dkim do
    title 'Update single domain DKIM'
    description 'Repair or update DKIM material for an authenticated server-owned domain.'

    param :id, 'ID of the domain', :type => Integer, :required => true
    param :dkim_private_key, 'New DKIM private key (RSA 2048+ bits)', :type => String, :required => false
    param :dkim_identifier_string, 'New DKIM identifier string (6 uppercase alphanumeric characters)', :type => String, :required => false
    param :regenerate, 'Generate a new 2048-bit DKIM key', :type => :boolean, :required => false, :default => false
    param :include_private_key, 'Include the private key in this authenticated server-owned response', :type => :boolean, :required => false
    returns Hash

    action do
      domain = DomainApiAccess.new(identity.server).find_directly_owned_by_id(params.id)
      error("Domain with ID #{params.id} not found", 404) unless domain

      if params.regenerate && params.dkim_private_key.present?
        error 'Specify either regenerate=true or dkim_private_key, not both', 422
      end

      attributes = {}
      if params.regenerate
        domain.regenerate_dkim_key
        attributes[:dkim_private_key] = domain.dkim_private_key
        attributes[:dkim_identifier_string] = domain.dkim_identifier_string
      elsif params.dkim_private_key.present?
        begin
          attributes[:dkim_private_key] = OpenSSL::PKey::RSA.new(params.dkim_private_key).to_s
        rescue OpenSSL::PKey::RSAError, OpenSSL::PKey::PKeyError, ArgumentError, TypeError => e
          error "Invalid DKIM private key: #{e.message}", 422
        end
      end

      if params.dkim_identifier_string.present?
        if params.dkim_identifier_string.match?(/\A[A-Z0-9]{6}\z/)
          attributes[:dkim_identifier_string] = params.dkim_identifier_string
        else
          error 'DKIM identifier must be 6 uppercase alphanumeric characters', 422
        end
      end

      if attributes.empty?
        error 'No updates provided. Specify dkim_private_key, dkim_identifier_string, or regenerate=true', 422
      end

      unless domain.update(attributes)
        error 'Failed to update DKIM', :errors => domain.errors.full_messages
      end

      DomainApiPayload.build(domain, :server => identity.server, :include_private_key => params.include_private_key == true)
    end
  end
end
