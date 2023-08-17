class ServerController < Moonrope:Controller
  include ApiHelpers

  action :create do
    title "Create a new server"
    description "Create a new server under the organization"

    param :name, "Name of the server", type: String
    param :mode, "Mode of the server", type: String
    param :organization_id, "Organization ID", type: Integer
    param :custom_key, "Key", type: String
    returns Hash

    action do
      organization_id = params.organization_id || 2 # Use organization_id from params or default to 2

      @organization = Organization.find(organization_id)
      @server = @organization.servers.build(server_params)

      # Set the default organization_id if not supplied
      @server.organization_id ||= @organization.id

      if @server.save
        # Create a new default credential for the created server
        default_credential = create_default_credential(@server)

        # Include the credential key in the JSON response
        result = { notice: 'Server was successfully created.' }
        result[:server_id] = @server.id
        result[:credential_key] = default_credential.key

        result
      else
        error!("Could not save server information", 422)
      end
    end
  end
end
