controller :domains do
  friendly_name "Domains API"
  description "This API allows you to manage domains"
  authenticator :server

  action :get do
    title "Get domain details"
    description "Retrieve details of a single domain based on its ID"
    
    param :id, "ID of the domain", :type => Integer, :required => true
    returns Hash

    http_method :get

    action do
      begin
        domain = Domain.find_by(id: params.id)

        unless domain
          error("Domain with ID #{params.id} not found", 404)
        else
          domain.as_json
        end
      rescue Moonrope::Errors::StructuredError => e
        error(e.message, e.status)
      rescue StandardError => e
        {
          error: "An error occurred while retrieving the domain: #{e.message}"
        }
      end
    end
  end

  action :domain do
    title "Add a domain"
    description "Add a new domain based on the given name parameter"
    
    param :name, "Name of the domain", :type => String
    error 'RecordInvalid', "The provided data was not sufficient to create a domain", attributes: { errors: "A hash of error details" }
    returns Hash
    
    action do
      begin
        server = identity.server
        
        domain = server.domains.build(name: params.name)
        
        if domain.save
          # Perform any necessary DNS checks and verification here
          
          dkim_record = domain.dkim_record
          dkim_identifier = domain.dkim_identifier
          spf_record = domain.spf_record
          verification_token = domain.verification_token
          verification_method = domain.verification_method
          
          {
            id: domain.id,
            name: domain.name,
            dkim_record: dkim_record,
            dkim_identifier: dkim_identifier,
            spf_record: spf_record,
            verification_token: verification_token,
            verification_method: verification_method
          }
        else
          error("Failed to create the domain", 500)
        end
      rescue Moonrope::Errors::StructuredError => e
        error(e.message, e.status)
      rescue StandardError => e
        {
          error: "An error occurred while adding the domain: #{e.message}"
        }
      end
    end
  end

  action :list do
    title "List domains"
    description "Retrieve all available domains for the current server"
    returns Array
    
    action do
      begin
        domains = Domain.where(owner_id: identity.server.id, owner_type: "Server")
        result = domains.map do |domain|
          {
            id: domain.id,
            name: domain.name,
            verified_at: domain.verified_at,
            created_at: domain.created_at,
            updated_at: domain.updated_at,
            dns_checked_at: domain.dns_checked_at,
            spf_status: domain.spf_status,
            spf_error: domain.spf_error,
            dkim_status: domain.dkim_status,
            dkim_error: domain.dkim_error,
            mx_status: domain.mx_status,
            mx_error: domain.mx_error,
            return_path_status: domain.return_path_status,
            return_path_error: domain.return_path_error,
            outgoing: domain.outgoing,
            incoming: domain.incoming,
            owner_type: domain.owner_type,
            owner_id: domain.owner_id,
            dkim_identifier_string: domain.dkim_identifier_string,
            use_for_any: domain.use_for_any
          }
        end

        result
      rescue StandardError => e
        {
          error: "An error occurred while fetching the domains: #{e.message}"
        }
      end
    end
  end
end
