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
    param :display_name, "Display name of the upstream Venmail organization", type: String
    param :venmail_organization_id, "Upstream Venmail organization ID", type: Integer
    returns Hash

    action do  
      organization_id = params.organization_id || 2 # Use organization_id from params or default to 2
      upstream_organization_id = params.venmail_organization_id.to_s.strip.presence
      server_name = params.name.to_s.strip

      if upstream_organization_id
        server_prefix = "venmail-org-#{upstream_organization_id}"
        unless server_name == server_prefix || server_name.start_with?("#{server_prefix}-")
          name_source = params.display_name.to_s.strip.presence || server_name
          name_slug = name_source.parameterize.presence || "organization"
          server_name = "#{server_prefix}-#{name_slug}"[0, 120]
        end
      end

      @organization = Organization.find(organization_id)

      @organization.with_lock do
        @server = @organization.servers.where(name: server_name).first

        unless @server
          @server = @organization.servers.build(
            name: server_name,
            mode: params.mode,
            organization_id: organization_id
          )

          # Set the default organization_id if not supplied
          @server.organization_id ||= @organization.id

          unless @server.save
            error "Could not save server information #{@server.errors.full_messages}", 422
          end
        end
      end

      # Create a new default HTTP endpoint for the created server if one does not already exist
      base_url = Postal.config.general.external_api_base_url.to_s.chomp('/')
      venmail_org_id = upstream_organization_id || @server.id
      endpoint_url = params.webhook.to_s.strip.presence || "#{base_url}/api/v1/mails/org/#{venmail_org_id}"
      event_hook_url = params.event_hook.to_s.strip.presence || "#{base_url}/api/v1/events/org/#{venmail_org_id}"

      default_endpoint = HTTPEndpoint.where(
        name: "DefaultEndpoint",
        server_id: @server.id
      ).first

      if default_endpoint.nil?
        default_endpoint = HTTPEndpoint.new(
          name: "DefaultEndpoint",
          server_id: @server.id,
          url: endpoint_url,
          timeout: 5,
          encoding: 'BodyAsJSON', # Set encoding
          format: 'Hash', # Set format
          strip_replies: false,
          include_attachments: true
        )
        if not default_endpoint.save
          error "Could not save server information #{default_endpoint.errors.full_messages}", 422
        end
      elsif default_endpoint.url != endpoint_url
        unless default_endpoint.update(url: endpoint_url)
          error "Could not update endpoint information #{default_endpoint.errors.full_messages}", 422
        end
      end

      default_event_hook = Webhook.where(
        name: "DefaultEventHook",
        server_id: @server.id
      ).first

      if default_event_hook.nil?
        default_event_hook = Webhook.new(
          name: "DefaultEventHook",
          server_id: @server.id,
          url: event_hook_url,
          enabled: true,
          all_events: false,
          events: ['MessageDelayed', 'MessageDeliveryFailed', 'MessageHeld', 'MessageBounced']
        )
        if not default_event_hook.save
          error "Could not save server information #{default_event_hook.errors.full_messages}", 422
        end
      elsif default_event_hook.url != event_hook_url
        default_event_hook.url = event_hook_url
        if not default_event_hook.save
          error "Could not update webhook information #{default_event_hook.errors.full_messages}", 422
        end
      end
      
      # Create a new default credential for the created server if one does not already exist
      default_credential = Credential.where(
        server_id: @server.id,
        type: 'API', # Set the type as needed
        name: 'Default Credential' # Set the name as needed
      ).first

      unless default_credential
        default_credential = Credential.new(
          server_id: @server.id,
          type: 'API', # Set the type as needed
          name: 'Default Credential', # Set the name as needed
          hold: false
        )
      end

      if default_credential.save
        result = { notice: 'Server was successfully created.' }
        result[:server_id] = @server.id
        result[:credential_key] = default_credential.key
        result[:endpoint_id] = default_endpoint.id
      else
        result = { notice: 'Server creation failed.' }
      end

      result
    end
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

  action :remove do
    title "Remove a server by ID"
    description "Remove a server from the organization by its ID"

    param :server_id, "Server ID to be removed", type: Integer
    returns Hash

    action do
      @server = Server.find_by_id(params.server_id)
      error("NotFound", 404) unless @server

      if @server.destroy
        result = { notice: 'Server was successfully removed.' }
      else
        error "Could not remove the server", 422
      end

      result
    end
  end
end
