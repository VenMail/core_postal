controller :server do
  friendly_name "Server API"
  description "This API allows you to manage servers"
  authenticator :master

  action :create do
    title 'Create a new server'
    description 'Create a new server under the organization'

    param :name, "Name of the server", type: String
    param :mode, "Mode of the server", type: String
    param :webhook, "Webhook of the server", type: String
    param :event_hook, "Event webhook of the server", type: String
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
          url: params[:webhook] || "https://api.venmail.io/api/v1/mails/org/#{@server.id}",
          timeout: 5,
          encoding: 'BodyAsJSON', # Set encoding
          format: 'Hash', # Set format
          strip_replies: false,
          include_attachments: true
        )
        if not default_endpoint.save
          error "Could not save server information #{default_endpoint.errors.full_messages}", 422
        end

  action :attach_ip_pool do
    title "Attach an IP pool to a server"
    description "Assign an IP pool to the specified server for outgoing mail"
    param :server_id, "Server ID", type: Integer
    param :ip_pool_uuid, "UUID of the IP pool", type: String
    returns Hash
    action do
      server = Server.find(params.server_id)
      ip_pool = IPPool.find_by_uuid(params.ip_pool_uuid)
      error("NotFound", 404) unless server && ip_pool

      # Ensure pool belongs to server's organization
      unless server.organization.ip_pools.include?(ip_pool)
        error "Forbidden", 403
      end

      server.update!(ip_pool: ip_pool)
      {
        notice: 'IP pool attached',
        server: server.webhook_hash,
        ip_pool_uuid: ip_pool.uuid
      }
    end
  end

  action :detach_ip_pool do
    title "Detach IP pool from a server"
    description "Remove any attached IP pool from the server"
    param :server_id, "Server ID", type: Integer
    returns Hash
    action do
      server = Server.find(params.server_id)
      error("NotFound", 404) unless server
      server.update!(ip_pool: nil)
      {
        notice: 'IP pool detached',
        server: server.webhook_hash
      }
    end
  end

        default_event_hook = Webhook.new(
          name: "DefaultEventHook",
          server_id: @server.id,
          url: params[:event_hook] || "https://api.venmail.io/api/v1/events/org/#{@server.id}",
          enabled: true,
          all_events: false,
          events: ['MessageDelayed', 'MessageDeliveryFailed', 'MessageHeld', 'MessageBounced']
        )
        if not default_event_hook.save
          error "Could not save server information #{default_event_hook.errors.full_messages}", 422
        end
        
        # Create a new default credential for the created server
        default_credential = Credential.new(
          server_id: @server.id,
          type: 'API', # Set the type as needed
          name: 'Default Credential', # Set the name as needed
          hold: false
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
  
  action :remove do
    title "Remove a server by ID"
    description "Remove a server from the organization by its ID"

    param :server_id, "Server ID to be removed", type: Integer
    returns Hash

    action do
      @server = Server.find(params.server_id)

      if @server.destroy
        result = { notice: 'Server was successfully removed.' }
      else
        error "Could not remove the server", 422
      end

      result
    end
  end
end
