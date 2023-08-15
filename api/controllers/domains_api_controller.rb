controller :domains do
  friendly_name "Domains API"
  description "This API allows you to manage domains"
  authenticator :server

  action :get_domain do
    title "Get domain details"
    description "Retrieve details of a single domain based on its ID"
    
    param :id, Integer, "ID of the domain"
    
    action do
      begin
        domain = Domain.find(params[:id])
        
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
          use_for_any: domain.use_for_any,
          dkim_record: domain.dkim_record,
          dkim_identifier: domain.dkim_identifier,
          spf_record: domain.spf_record,
          verification: {
            token: domain.verification_token,
            method: domain.verification_method
          }
        }
      rescue ActiveRecord::RecordNotFound
        {
          error: "Domain with ID #{params[:id]} not found"
        }
      rescue StandardError => e
        {
          error: "An error occurred while retrieving domain details: #{e.message}"
        }
      end
    end
  end
  
  action :add_domain do
    title "Add a domain"
    description "Add a new domain based on the given name parameter"
    
    param :name, String, "Name of the domain"
    
    action do
      begin
        server = identity.server
        
        # Build a new domain using the provided name and the retrieved server
        domain = server.domains.build(name: params[:name])
        
        if domain.save
          # Perform any necessary DNS checks and verification here
          
          # Retrieve DKIM related fields
          dkim_record = domain.dkim_record
          dkim_identifier = domain.dkim_identifier
          
          # Retrieve SPF related fields
          spf_record = domain.spf_record
          
          # Retrieve verification token and method
          verification_token = domain.verification_token
          verification_method = domain.verification_method
          
          # Return the domain attributes along with DKIM, SPF, and verification details
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
          # Handle domain creation error and return an error response
          {
            error: "Failed to create the domain: #{domain.errors.full_messages.join(', ')}"
          }
        end
      rescue StandardError => e
        # Handle the exception and return an error response
        {
          error: "An error occurred while adding the domain: #{e.message}"
        }
      end
    end
  end

  # Define an action named list
  action :list do
    # Set the title and description of the action
    title "List domains"
    description "Retrieve all available domains for the current server"
    # Return
    returns Array
    # Action
    action do
      begin
        # Find all domains that belong to the current server identity
        domains = Domain.where(owner_id: identity.server.id, owner_type: "Server")
        # Return an array of hashes with the domain attributes
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

        # Return the result
        result
      rescue StandardError => e
        # Handle the exception and return an error response
        {
          error: "An error occurred while fetching the domains: #{e.message}"
        }
      end
    end
  end
end
