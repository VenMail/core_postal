module ApiHelpers
  included do
    before_action :authorize_access # Add any necessary authorization logic
  end

  private

  def authorize_access
    unless valid_custom_key(params.custom_key) && valid_ip(request.remote_ip)
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
