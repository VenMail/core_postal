controller :server do
  friendly_name "Server API"
  description "This API allows you to manage servers"

  action :create do
    title "Create a new server"
    description "Create a new server under the organization"

    param :name, "Name of the server", type: String
    param :mode, "Mode of the server", type: String
    param :organization_id, "Organization ID", type: Integer
    param :custom_key, "Key", type: String
    returns Hash

    action do
      allowed_ips = ['102.219.153.196', '104.200.31.152', '185.218.126.208']

      unless params.custom_key == 'l<LJF*SMH*;xcpk9o8j57FS21ZUD*B' && allowed_ips.include?(request.remote_ip)
        error!('Unauthorized access', 401)
      end
  
      organization_id = params.organization_id || 2 # Use organization_id from params or default to 2

      @organization = Organization.find(organization_id)
      @server = @organization.servers.build(server_params)

      # Set the default organization_id if not supplied
      @server.organization_id ||= @organization.id

      if @server.save
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
        else
          result = { notice: 'Server creation failed.' }
        end
    
        result
      else
        error!("Could not save server information", 422)
      end
    end
  end

end
