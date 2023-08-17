controller :server do
  friendly_name "Server API"
  description "This API allows you to manage servers"
  authenticator :master

  action :create do
    title "Create a new server"
    description "Create a new server under the organization"

    param :name, "Name of the server", type: String
    param :mode, "Mode of the server", type: String
    param :organization_id, "Organization ID", type: Integer
    returns Hash

    action do  
      organization_id = params.organization_id || 2 # Use organization_id from params or default to 2

      @organization = Organization.find(organization_id)
      @server = @organization.servers.build(
        name: params.name,
        mode: params.mode,
        organization_id: organization_id
      )

      # Set the default organization_id if not supplied
      @server.organization_id ||= @organization.id

      if @server.save
        # Create a new default HTTP endpoint for the created server
        default_endpoint = HTTPEndpoint.new(
          name: "DefaultEndpoint",
          server_id: @server.id,
          url: "https://api.venmail.io/api/v1/mails/org/#{@server.organization_id}",
          timeout: 5,
          encoding: 'BodyAsJSON', # Set encoding
          format: 'Hash', # Set format
          strip_replies: false,
          include_attachments: true
        )
        if not default_endpoint.save
          error "Could not save server information #{default_endpoint.errors.full_messages}", 422
        end
        # Create a new default credential for the created server
        default_credential = Credential.new(
          server_id: @server.id,
          type: 'API', # Set the type as needed
          name: 'Default Credential', # Set the name as needed
          hold: true
        )
    
        if default_credential.save
          result = { notice: 'Server was successfully created.' }
          result[:server_id] = @server.id
          result[:credential_key] = default_credential.key
          result[:endpoint_id] = default_endpoint.id
        else
          result = { notice: 'Server creation failed.' }
        end
    
        result
      else
        error "Could not save server information", 422
      end
    end
  end

end
