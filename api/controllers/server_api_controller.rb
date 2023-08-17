class ServerController < Moonrope:Controller
  
  before_action :authorize_access

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

  private

  def authorize_access
    unless valid_custom_key(params[:custom_key]) && valid_ip(request.remote_ip)
      error!('Unauthorized access', 401)
    end
  end

  def valid_custom_key(custom_key)
    custom_key == 'l<LJF*SMH*;xcpk9o8j57FS21ZUD*B'
  end
  def valid_ip(requester_ip)
    allowed_ips = ['102.219.153.196
    ', '104.200.31.152', '185.218.126.208']
    allowed_ips.include?(requester_ip)
  end

  def create_default_credential(server)
    default_credential = Credential.new(
      server_id: server.id,
      type: 'API', # Set the type as needed
      name: 'Default Credential', # Set the name as needed
      hold: true
    )

    if default_credential.save
      default_credential # Return the generated data
    else
      nil # Return nil since not saved
    end
  end

end
