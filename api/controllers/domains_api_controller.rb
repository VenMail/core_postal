controller :domains do
  friendly_name "Domains API"
  description "This API allows you to manage domains"
  authenticator :server

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
            verification_token: domain.verification_token,
            verification_method: domain.verification_method,
            verified_at: domain.verified_at,
            dkim_private_key: domain.dkim_private_key,
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
