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
    param :organization_id, "Postal parent organization ID", type: Integer, :required => true
    param :display_name, "Display name of the upstream Venmail organization", type: String
    param :venmail_organization_id, "Immutable upstream Venmail organization ID", type: Integer, :required => true
    returns Hash

    action do
      organization_id = params.organization_id.to_i
      upstream_organization_id = params.venmail_organization_id.to_s.strip.presence
      server_name = params.name.to_s.strip

      error 'A Postal parent organization is required.', 422 if organization_id <= 0
      error 'An immutable upstream Venmail organization ID is required.', 422 if upstream_organization_id.nil? || upstream_organization_id.to_i <= 0

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
        # Look up by the immutable upstream identity before any mutable name.
        # A plan-parent change must never silently create a second tenant.
        @server = Server.where(:venmail_organization_id => upstream_organization_id).first
        if @server
          if @server.organization_id != @organization.id
            error 'The upstream Venmail organization is already bound to a different Postal parent.', 409
          end
        else
          same_name = @organization.servers.where(name: server_name).first
          if same_name
            # A legacy server cannot be claimed based only on its name. It must
            # be explicitly backfilled after its true upstream owner is proved.
            error 'An unbound or differently bound Postal server already uses this name.', 409
          end

          @server = @organization.servers.build(
            name: server_name,
            mode: params.mode,
            organization_id: organization_id,
            venmail_organization_id: upstream_organization_id
          )

          # Set the default organization_id if not supplied
          @server.organization_id ||= @organization.id

          unless @server.save
            error "Could not save server information #{@server.errors.full_messages}", 422
          end
        end
      end

      # Endpoint, event hook, and credential creation must be serialized on the
      # remote server as well. A caller can legitimately retry after a timeout;
      # without this lock two retries could both see a missing DefaultEndpoint
      # and create duplicate callbacks or credentials.
      base_url = Postal.config.general.external_api_base_url.to_s.chomp('/')
      venmail_org_id = upstream_organization_id || @server.id
      endpoint_url = params.webhook.to_s.strip.presence || "#{base_url}/api/v1/mails/org/#{venmail_org_id}"
      event_hook_url = params.event_hook.to_s.strip.presence || "#{base_url}/api/v1/events/org/#{venmail_org_id}"

      @server.with_lock do
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
          # `server/create` is retry-safe, not a mutable callback-update API.
          # Accepting a changed URL on a replay would let a stale/cross-boundary
          # caller silently redirect a live tenant's mail ingress.
          error 'The existing Postal HTTP endpoint conflicts with this immutable server binding.', 409
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
            events: ['MessageDelayed', 'MessageDeliveryFailed', 'MessageHeld', 'MessageBounced', 'CredentialLocked']
          )
          if not default_event_hook.save
            error "Could not save server information #{default_event_hook.errors.full_messages}", 422
          end
        elsif default_event_hook.url != event_hook_url
          error 'The existing Postal event hook conflicts with this immutable server binding.', 409
        end

        # Existing servers predate customer-impact credential alerts. Repair
        # the subscription idempotently whenever the immutable create call is
        # replayed, while preserving every existing message event.
        unless default_event_hook.all_events?
          default_event_hook.webhook_events.find_or_create_by!(:event => 'CredentialLocked')
        end

        # Create a new default credential for the created server if one does not already exist.
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
          result
        else
          { notice: 'Server creation failed.' }
        end
      end
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
    description "Remove a server only when its immutable Venmail owner matches"

    param :server_id, "Server ID to be removed", type: Integer
    param :venmail_organization_id, "Immutable upstream Venmail organization ID", type: Integer, :required => true
    returns Hash

    action do
      server_id = params.server_id.to_i
      upstream_organization_id = params.venmail_organization_id.to_s.strip.presence
      error 'A Postal server ID is required.', 422 if server_id <= 0
      error 'An immutable upstream Venmail organization ID is required.', 422 if upstream_organization_id.nil? || upstream_organization_id.to_i <= 0

      @server = Server.find_by_id(server_id)
      unless @server
        # An already-absent, explicitly addressed resource is safe to treat as
        # an idempotent removal. The caller still supplied the immutable owner.
        {
          server_id: server_id,
          venmail_organization_id: upstream_organization_id.to_i,
          removed: false
        }
      else
        unless @server.venmail_organization_id.present? && @server.venmail_organization_id.to_i == upstream_organization_id.to_i
          error 'Postal server ownership does not match the upstream Venmail organization.', 409
        end

        if @server.destroy
          {
            notice: 'Server was successfully removed.',
            server_id: @server.id,
            venmail_organization_id: @server.venmail_organization_id,
            removed: true
          }
        else
          error "Could not remove the server", 422
        end
      end
    end
  end

  action :identity do
    title "Inspect a server's immutable upstream binding"
    description "Return an ownership proof used before an external caller performs a destructive action"

    param :server_id, "Server ID to inspect", type: Integer
    param :venmail_organization_id, "Immutable upstream Venmail organization ID", type: Integer, :required => true
    returns Hash

    action do
      server_id = params.server_id.to_i
      upstream_organization_id = params.venmail_organization_id.to_s.strip.presence
      error 'A Postal server ID is required.', 422 if server_id <= 0
      error 'An immutable upstream Venmail organization ID is required.', 422 if upstream_organization_id.nil? || upstream_organization_id.to_i <= 0

      @server = Server.find_by_id(server_id)
      unless @server
        {
          server_id: server_id,
          venmail_organization_id: upstream_organization_id.to_i,
          exists: false,
          bound: false,
          matches: true
        }
      else
        {
          server_id: @server.id,
          venmail_organization_id: @server.venmail_organization_id,
          postal_parent_organization_id: @server.organization_id,
          exists: true,
          bound: @server.venmail_organization_id.present?,
          matches: @server.venmail_organization_id.present? && @server.venmail_organization_id.to_i == upstream_organization_id.to_i
        }
      end
    end
  end

  action :bind do
    title "Backfill an immutable upstream server binding"
    description "Bind only a conventionally named, parent-matched legacy server after the caller has independently audited its ownership"

    param :server_id, "Existing Postal server ID", type: Integer
    param :organization_id, "Expected Postal parent organization ID", type: Integer, :required => true
    param :venmail_organization_id, "Immutable upstream Venmail organization ID", type: Integer, :required => true
    returns Hash

    action do
      server_id = params.server_id.to_i
      postal_parent_organization_id = params.organization_id.to_i
      upstream_organization_id = params.venmail_organization_id.to_s.strip.presence
      error 'A Postal server ID is required.', 422 if server_id <= 0
      error 'A Postal parent organization is required.', 422 if postal_parent_organization_id <= 0
      error 'An immutable upstream Venmail organization ID is required.', 422 if upstream_organization_id.nil? || upstream_organization_id.to_i <= 0

      @server = Server.find_by_id(server_id)
      error 'Postal server not found.', 404 unless @server

      unless @server.organization_id == postal_parent_organization_id
        error 'Postal server parent organization does not match the audited binding.', 409
      end

      expected_prefix = "venmail-org-#{upstream_organization_id}"
      unless @server.name.to_s == expected_prefix || @server.name.to_s.start_with?("#{expected_prefix}-")
        error 'Legacy Postal server name does not prove the requested upstream organization binding.', 409
      end

      if @server.venmail_organization_id.present?
        unless @server.venmail_organization_id.to_i == upstream_organization_id.to_i
          error 'Postal server is already bound to a different upstream Venmail organization.', 409
        end
      else
        @server.update!(:venmail_organization_id => upstream_organization_id.to_i)
      end

      {
        server_id: @server.id,
        venmail_organization_id: @server.venmail_organization_id,
        postal_parent_organization_id: @server.organization_id,
        bound: true,
        matches: true
      }
    end
  end
end
