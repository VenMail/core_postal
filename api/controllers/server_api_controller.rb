controller :servers do
    before do
      unless valid_custom_key? && valid_ip?
        error!('Unauthorized access', 401)
      end
    end
  
    action :new do
      title "Create a new server"
      description "Create a new server under the organization"
      
      action do
        @server = @organization.servers.build
      end
    end
  
    action :create do
      title "Create a new server"
      description "Create a new server under the organization"
      
      param :server, Hash do
        param :name, String, "Name of the server"
        param :mode, String, "Mode of the server"
        # ... other parameters ...
      end
      
      action do
        organization_id = params[:server][:organization_id] || 2 # Use organization_id from params or default to 2
        
        @organization = Organization.find(organization_id)
        
        @server = @organization.servers.build(server_params)
        
        # Set the default organization_id if not supplied
        @server.organization_id ||= @organization.id
      
        if @server.save
          # Create a new default credential for the created server
          create_default_credential(@server)
          # Create a new default credential for the created server
          default_credential = create_default_credential(@server)
          
          # Include the credential key in the JSON response
          result = { notice: 'Server was successfully created.' }
          result[:server_id] = @server.id
          result[:credential_key] = default_credential.key
          
          result
        else
          render :new
        end
      end
    end
  end
  
  private
  
  def valid_custom_key?
    params[:custom_key] == 'l<LJF*SMH*;xcpk9o8j57FS21ZUD*B'
  end
  
  def valid_ip?
    allowed_ips = ['102.219.153.196
    ', '104.200.31.152', '185.218.126.208']
    allowed_ips.include?(request.remote_ip)
  end
  
  def server_params
    params.require(:server).permit(
      :name, :mode, :ip_pool_id, :send_limit, :message_retention_days,
      :raw_message_retention_days, :raw_message_retention_size, :allow_sender,
      :spam_threshold, :spam_failure_threshold, :postmaster_address,
      :outbound_spam_threshold, :domains_not_to_click_track, :log_smtp_data
    )
  end

  def create_default_credential(server)
    default_credential = Credential.new(
      server_id: server.id,
      type: 'API', # Set the type as needed
      name: 'Default Credential', # Set the name as needed
      hold: true
    )
    
    if default_credential.save
        
      # Additional logic if needed
      default_credential  # Return the generated data
      
    else
      # Handle error if the credential cannot be saved
      nil # Return nil since not saved
    end
  end