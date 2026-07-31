controller :domains do
  friendly_name "Domains API"
  description "This API allows you to manage domains"
  authenticator :server

  action :get do
    title "Get domain details"
    description "Retrieve details of a single domain based on its ID"
    
    param :id, "ID of the domain", :type => Integer, :required => true
    param :include_private_key, "Include the DKIM private key only when this server's provisioning credential retrieves a domain directly owned by that server", :type => :boolean, :required => false
    returns Hash

    action do
      begin
        domain = Domain.for_api_server(identity.server).find_by(id: params.id)

        unless domain
          error("Domain with ID #{params.id} not found", 404)
        else
          result = domain.api_public_payload
          if params.include_private_key == true && domain.owner_type == 'Server' && domain.owner_id == identity.server.id
            result[:dkim_private_key] = domain.dkim_private_key
          end
          result
        end
      rescue => e
        custom_data = e.data if e.is_a?(Moonrope::Errors::StructuredError)
        error "An error occurred while retrieving the domain: #{e.message}", :details => custom_data
      end
    end
  end

  action :find_by_name do
    title "Find domain by name"
    description "Retrieve domain details by searching for the domain name"
    
    param :name, "Name of the domain (e.g., cohultai.com)", :type => String, :required => true
    param :include_private_key, "Include the DKIM private key only when this server's provisioning credential retrieves a domain directly owned by that server", :type => :boolean, :required => false
    returns Hash

    action do
      begin
        domain = identity.server.domains.find_by(name: params.name)
        domain ||= identity.server.organization.domains.find_by(name: params.name) if identity.server.organization

        unless domain
          error("Domain with name '#{params.name}' not found", 404)
        else
          result = domain.api_public_payload
          if params.include_private_key == true && domain.owner_type == 'Server' && domain.owner_id == identity.server.id
            result[:dkim_private_key] = domain.dkim_private_key
          end
          result
        end
      rescue => e
        custom_data = e.data if e.is_a?(Moonrope::Errors::StructuredError)
        error "An error occurred while retrieving the domain: #{e.message}", :details => custom_data
      end
    end
  end

  action :domain do
    title "Add a domain"
    description "Add a server-owned domain. BYODKIM private keys must be valid RSA keys of at least 2048 bits; generated keys are RSA 2048."

    param :name, "Name of the domain", :type => String
    param :include_private_key, "Include the DKIM private key only for this server's directly owned domain during privileged provisioning", :type => :boolean, :required => false
    param :dkim_private_key, "DKIM private key to use (BYODKIM, valid RSA 2048+; a generated RSA 2048 key is used when omitted)", :type => String, :required => false
    param :dkim_record, "Deprecated compatibility parameter. Ignored; the public record is always derived from dkim_private_key.", :type => String, :required => false
    param :dkim_identifier_string, "Legacy DKIM selector suffix (must not include the configured prefix)", :type => String, :required => false
    param :dkim_selector, "Exact full DKIM selector using this server's configured prefix", :type => String, :required => false
    error 'RecordInvalid', "The provided data was not sufficient to create a domain", attributes: { errors: "A hash of error details" }
    returns Hash

    action do
      begin
        @server = identity.server

        has_dkim_selector = params.has?(:dkim_selector)
        has_dkim_identifier_string = params.has?(:dkim_identifier_string)
        if has_dkim_selector && has_dkim_identifier_string
          raise ArgumentError, 'Specify either dkim_selector or dkim_identifier_string, not both'
        end

        requested_dkim_identifier_string = if has_dkim_selector
                                             Domain.dkim_identifier_string_for_selector(params.dkim_selector)
                                           elsif has_dkim_identifier_string
                                             Domain.dkim_identifier_string_for_suffix(params.dkim_identifier_string)
                                           end

        # Build domain with optional BYODKIM parameters
        domain_params = { name: params.name, verification_method: "DNS" }

        # If DKIM keys are provided, use them instead of generating new ones
        if params.dkim_private_key.present?
          domain_params[:dkim_private_key] = params.dkim_private_key
        end

        if requested_dkim_identifier_string
          domain_params[:dkim_identifier_string] = requested_dkim_identifier_string
        end

        @domain = @server.domains.build(domain_params)

        if @domain.save
          result = @domain.api_public_payload
          if params.include_private_key == true && @domain.owner_type == 'Server' && @domain.owner_id == identity.server.id
            result[:dkim_private_key] = @domain.dkim_private_key
          end
          result
        else
          error "RecordInvalid", :errors => @domain.errors.full_messages
        end
      rescue ArgumentError => e
        error e.message, 422
      rescue => e
        custom_data = e.data if e.is_a?(Moonrope::Errors::StructuredError)
        error "An error occurred while retrieving the domain: #{e.message}", :details => custom_data
      end
    end
  end

  action :list do
    title "List domains"
    description "Retrieve domains directly owned by the current server plus domains owned by its organization. Sibling-server domains are excluded."
    returns Array
    
    action do
      begin
        result = Domain.for_api_server(identity.server).map(&:api_public_payload)

        result
      rescue StandardError => e
        {
          error: "An error occurred while fetching the domains: #{e.message}"
        }
      end
    end
  end

  action :verify do
    title "Verify domain TXT"
    description "Verify a single domain based on ID. verification_token_status is OK only after the current exact root TXT proof is recorded; generic verified_at does not imply it."

    param :id, "ID of the domain", :type => Integer, :required => true
    param :force, "Force verification", :type => :boolean, :required => false
    returns Hash

    action do
      begin
        domain = Domain.for_api_server(identity.server).find_by(id: params.id)

        unless domain
          error("Domain with ID #{params.id} not found", 404)
        else
          if domain.verified?
            domain.check_dns(:manual)
            if domain.verification_method == 'DNS' && !domain.verification_token_verified?
              domain.verify_with_dns
            end
            domain.api_public_payload
          else
            if params.force
              domain.verify
              domain.api_public_payload
            else
              if domain.verify_with_dns
                domain.api_public_payload
              else
                {
                  success: false,
                  message: "Invalid verification code. Please check and try again"
                }
              end
            end
          end
        end
      rescue => e
        custom_data = e.data if e.is_a?(Moonrope::Errors::StructuredError)
        error "An error occurred while retrieving the domain: #{e.message}", :details => custom_data
      end
    end
  end

  action :destroy do
    title "Delete domain"
    description "Delete a domain directly owned by the current server. Organization-owned domains are intentionally not deletable through a server credential."

    param :id, "ID of the domain", :type => Integer, :required => true
    returns Hash

    action do
      begin
        domain = Domain.where(:owner_type => 'Server', :owner_id => identity.server.id).find_by(id: params.id)

        unless domain
          error("Domain with ID #{params.id} not found", 404)
        else
          if domain.destroy
            {
              success: true,
              message: "Domain #{domain.name} deleted successfully"
            }
          else
            error "Failed to delete domain", :errors => domain.errors.full_messages
          end
        end
      rescue => e
        custom_data = e.data if e.is_a?(Moonrope::Errors::StructuredError)
        error "An error occurred while deleting the domain: #{e.message}", :details => custom_data
      end
    end
  end

  action :update_dkim do
    title "Update DKIM records"
    description "Update DKIM material for domains directly owned by the authenticated server or its organization. Sibling-server domains are excluded. Supports bulk updates with optional dry-run mode."

    param :organization_id, "ID of the organization", :type => Integer, :required => true
    param :dkim_private_key, "New DKIM private key (must be valid RSA 2048+; generated replacements use RSA 2048)", :type => String, :required => false
    param :dkim_identifier_string, "Legacy DKIM selector suffix (must not include the configured prefix)", :type => String, :required => false
    param :dkim_selector, "Exact full DKIM selector using this server's configured prefix", :type => String, :required => false
    param :regenerate_keys, "Generate new DKIM keys for all domains", :type => :boolean, :required => false, :default => false
    param :dry_run, "Preview changes without applying them", :type => :boolean, :required => false, :default => false
    param :force, "Skip validation warnings", :type => :boolean, :required => false, :default => false
    returns Hash

    action do
      begin
        has_dkim_selector = params.has?(:dkim_selector)
        has_dkim_identifier_string = params.has?(:dkim_identifier_string)
        if has_dkim_selector && has_dkim_identifier_string
          raise ArgumentError, 'Specify either dkim_selector or dkim_identifier_string, not both'
        end

        requested_dkim_identifier_string = if has_dkim_selector
                                             Domain.dkim_identifier_string_for_selector(params.dkim_selector)
                                           elsif has_dkim_identifier_string
                                             Domain.dkim_identifier_string_for_suffix(params.dkim_identifier_string)
                                           end

        organization = identity.server.organization
        unless organization && organization.id == params.organization_id.to_i
          error("Organization with ID #{params.organization_id} not found", 404)
        end

        domains = Domain.for_api_server(identity.server)
        
        results = {
          organization_id: organization.id,
          organization_name: organization.name,
          total_domains: domains.count,
          updated: 0,
          failed: 0,
          skipped: 0,
          dry_run: params.dry_run,
          details: []
        }

        domains.find_each do |domain|
          old_dkim = domain.api_public_dkim_payload
          detail = {
            domain_id: domain.id,
            domain_name: domain.name,
            old_identifier: old_dkim[:identifier_string],
            old_key_present: domain.dkim_private_key.present?
          }

          if params.dry_run
            detail[:status] = "would_update"
            results[:skipped] += 1
          else
            begin
              updates = {}
              
              if params.regenerate_keys
                domain.regenerate_dkim_key
                updates[:dkim_private_key] = domain.dkim_private_key
                updates[:dkim_identifier_string] = domain.dkim_identifier_string
              elsif params.dkim_private_key.present?
                updates[:dkim_private_key] = params.dkim_private_key
              end

              if requested_dkim_identifier_string
                updates[:dkim_identifier_string] = requested_dkim_identifier_string
              end

              if updates.any?
                if domain.update(updates)
                  dkim = domain.api_public_dkim_payload
                  detail[:status] = "updated"
                  detail[:new_identifier] = dkim[:identifier_string]
                  detail[:new_key_present] = domain.dkim_private_key.present?
                  detail[:dkim_material_status] = dkim[:status]
                  detail[:dkim_record] = dkim[:record]
                  detail[:dkim_record_name] = dkim[:record_name]
                  results[:updated] += 1
                else
                  detail[:status] = "failed"
                  detail[:errors] = domain.errors.full_messages
                  results[:failed] += 1
                end
              else
                detail[:status] = "no_changes"
                results[:skipped] += 1
              end
            rescue => e
              detail[:status] = "error"
              detail[:error] = e.message
              results[:failed] += 1
            end
          end

          results[:details] << detail
        end

        results
      rescue ArgumentError => e
        error e.message, 422
      rescue => e
        custom_data = e.data if e.is_a?(Moonrope::Errors::StructuredError)
        error "An error occurred while updating DKIM records: #{e.message}", :details => custom_data
      end
    end
  end

  action :update_single_dkim do
    title "Update single domain DKIM"
    description "Update DKIM identifier and private key for a specific domain"

    param :id, "ID of the domain", :type => Integer, :required => true
    param :dkim_private_key, "New DKIM private key (must be valid RSA 2048+; generated replacements use RSA 2048)", :type => String, :required => false
    param :dkim_identifier_string, "Legacy DKIM selector suffix (must not include the configured prefix)", :type => String, :required => false
    param :dkim_selector, "Exact full DKIM selector using this server's configured prefix", :type => String, :required => false
    param :regenerate, "Generate new DKIM key", :type => :boolean, :required => false, :default => false
    returns Hash

    action do
      begin
        domain = Domain.for_api_server(identity.server).find_by(id: params.id)
        error("Domain with ID #{params.id} not found", 404) unless domain

        updates = {}

        has_dkim_selector = params.has?(:dkim_selector)
        has_dkim_identifier_string = params.has?(:dkim_identifier_string)
        if has_dkim_selector && has_dkim_identifier_string
          raise ArgumentError, 'Specify either dkim_selector or dkim_identifier_string, not both'
        end

        requested_dkim_identifier_string = if has_dkim_selector
                                             Domain.dkim_identifier_string_for_selector(params.dkim_selector)
                                           elsif has_dkim_identifier_string
                                             Domain.dkim_identifier_string_for_suffix(params.dkim_identifier_string)
                                           end

        if params.regenerate
          domain.regenerate_dkim_key
          updates[:dkim_private_key] = domain.dkim_private_key
          updates[:dkim_identifier_string] = domain.dkim_identifier_string
        else
          if params.dkim_private_key.present?
            begin
              key = OpenSSL::PKey::RSA.new(params.dkim_private_key)
              updates[:dkim_private_key] = key.to_s
            rescue OpenSSL::PKey::RSAError => e
              error "Invalid DKIM private key: #{e.message}", 422
            end
          end
          
        end

        if requested_dkim_identifier_string
          updates[:dkim_identifier_string] = requested_dkim_identifier_string
        end

        if updates.any?
          if domain.update(updates)
            dkim_payload = domain.api_public_payload
            {
              success: true,
              domain_id: domain.id,
              domain_name: domain.name,
              dkim_identifier_string: dkim_payload[:dkim_identifier_string],
              dkim_identifier: dkim_payload[:dkim_identifier],
              dkim_selector: dkim_payload[:dkim_selector],
              dkim_record: dkim_payload[:dkim_record],
              dkim_record_name: dkim_payload[:dkim_record_name],
              dkim_material_status: dkim_payload[:dkim_material_status],
              dkim: dkim_payload[:dkim],
              updated_at: domain.updated_at
            }
          else
            error "Failed to update DKIM", :errors => domain.errors.full_messages
          end
        else
          error "No updates provided. Specify dkim_private_key, dkim_identifier_string, dkim_selector, or regenerate=true", 422
        end
      rescue ArgumentError => e
        error e.message, 422
      rescue => e
        custom_data = e.data if e.is_a?(Moonrope::Errors::StructuredError)
        error "An error occurred while updating DKIM: #{e.message}", :details => custom_data
      end
    end
  end
end
