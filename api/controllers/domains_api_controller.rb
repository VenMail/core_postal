controller :domains do
  friendly_name "Domains API"
  description "This API allows you to manage domains"
  authenticator :server

  action :get do
    title "Get domain details"
    description "Retrieve details of a single domain based on its ID"
    
    param :id, "ID of the domain", :type => Integer, :required => true
    returns Hash

    action do
      begin
        domain = Domain.find_by(id: params.id)

        unless domain
          error("Domain with ID #{params.id} not found", 404)
        else
          domain.as_json
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
    param :include_private_key, "Include the DKIM private key (for internal provisioning only)", :type => :boolean, :required => false
    returns Hash

    action do
      begin
        domain = Domain.find_by(name: params.name)

        unless domain
          error("Domain with name '#{params.name}' not found", 404)
        else
          result = {
            id: domain.id,
            name: domain.name,
            verified_at: domain.verified_at,
            dkim_status: domain.dkim_status,
            dkim_error: domain.dkim_error,
            dkim_identifier_string: domain.dkim_identifier_string,
            dkim_identifier: domain.dkim_identifier,
            dkim_record: domain.dkim_record,
            dkim_record_name: domain.dkim_record_name,
            spf_record: domain.spf_record,
            spf_status: domain.spf_status,
            mx_status: domain.mx_status,
            return_path_status: domain.return_path_status,
            outgoing: domain.outgoing,
            incoming: domain.incoming,
            owner_type: domain.owner_type,
            owner_id: domain.owner_id,
            created_at: domain.created_at,
            updated_at: domain.updated_at
          }
          result[:dkim_private_key] = domain.dkim_private_key if params.include_private_key == true
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
    description "Add a new domain based on the given name parameter. Supports BYODKIM by accepting existing DKIM keys."

    param :name, "Name of the domain", :type => String
    param :include_private_key, "Include the DKIM private key (for internal provisioning only)", :type => :boolean, :required => false
    param :dkim_private_key, "DKIM private key to use (BYODKIM - will not generate new key if provided)", :type => String, :required => false
    param :dkim_record, "DKIM record to use (BYODKIM)", :type => String, :required => false
    param :dkim_identifier_string, "DKIM identifier string to use (BYODKIM)", :type => String, :required => false
    error 'RecordInvalid', "The provided data was not sufficient to create a domain", attributes: { errors: "A hash of error details" }
    returns Hash

    action do
      begin
        @server = identity.server

        # Build domain with optional BYODKIM parameters
        domain_params = { name: params.name, verification_method: "DNS" }

        # If DKIM keys are provided, use them instead of generating new ones
        if params.dkim_private_key.present?
          domain_params[:dkim_private_key] = params.dkim_private_key
        end

        if params.dkim_identifier_string.present?
          domain_params[:dkim_identifier_string] = params.dkim_identifier_string
        end

        @domain = @server.domains.build(domain_params)

        if @domain.save
          dkim_record = @domain.dkim_record
          dkim_identifier = @domain.dkim_identifier
          spf_record = @domain.spf_record
          verification_token = @domain.verification_token
          verification_method = @domain.verification_method
          dkim_private_key = @domain.dkim_private_key

          {
            id: @domain.id,
            name: @domain.name,
            dkim_record: dkim_record,
            dkim_identifier: dkim_identifier,
            spf_record: spf_record,
            verification_token: verification_token,
            verification_method: verification_method,
            dkim_private_key: (params.include_private_key == true ? dkim_private_key : nil)
          }
        else
          error "RecordInvalid", :errors => @domain.errors.full_messages
        end
      rescue => e
        custom_data = e.data if e.is_a?(Moonrope::Errors::StructuredError)
        error "An error occurred while retrieving the domain: #{e.message}", :details => custom_data
      end
    end
  end

  action :list do
    title "List domains"
    description "Retrieve all available domains for the current server"
    returns Array
    
    action do
      begin
        domains = Domain.where(owner_id: identity.server.id, owner_type: "Server")
        result = domains.map do |domain|
          {
            id: domain.id,
            name: domain.name,
            verified_at: domain.verified_at,
            created_at: domain.created_at,
            updated_at: domain.updated_at,
            dns_checked_at: domain.dns_checked_at,
            spf_record: domain.spf_record,
            spf_status: domain.spf_status,
            spf_error: domain.spf_error,
            dkim_status: domain.dkim_status,
            dkim_error: domain.dkim_error,
            mx_status: domain.mx_status,
            mx_error: domain.mx_error,
            verification_method: domain.verification_method,
            verification_token: domain.verification_token,
            return_path_status: domain.return_path_status,
            return_path_error: domain.return_path_error,
            outgoing: domain.outgoing,
            incoming: domain.incoming,
            owner_type: domain.owner_type,
            owner_id: domain.owner_id,
            dkim_identifier_string: domain.dkim_identifier_string,
            dkim_record: domain.dkim_record,
            use_for_any: domain.use_for_any
          }
        end

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
    description "Verify a single domain based on ID"

    param :id, "ID of the domain", :type => Integer, :required => true
    param :force, "Force verification", :type => :boolean, :required => false
    returns Hash

    action do
      begin
        domain = Domain.find_by(id: params.id)

        unless domain
          error("Domain with ID #{params.id} not found", 404)
        else
          if domain.verified?
            domain.check_dns(:manual)
            domain.as_json
          else
            if params.force
              domain.verify
            else
              if domain.verify_with_dns
                domain.as_json
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
    description "Delete a domain from the server"

    param :id, "ID of the domain", :type => Integer, :required => true
    returns Hash

    action do
      begin
        domain = Domain.find_by(id: params.id)

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
    description "Update DKIM identifier and private key for all domains in an organization. Supports bulk updates with optional dry-run mode."

    param :organization_id, "ID of the organization", :type => Integer, :required => true
    param :dkim_private_key, "New DKIM private key (RSA 1024+ bits)", :type => String, :required => false
    param :dkim_identifier_string, "New DKIM identifier string", :type => String, :required => false
    param :regenerate_keys, "Generate new DKIM keys for all domains", :type => :boolean, :required => false, :default => false
    param :dry_run, "Preview changes without applying them", :type => :boolean, :required => false, :default => false
    param :force, "Skip validation warnings", :type => :boolean, :required => false, :default => false
    returns Hash

    action do
      begin
        organization = Organization.find_by(id: params.organization_id)
        error("Organization with ID #{params.organization_id} not found", 404) unless organization

        servers = organization.servers
        domains = Domain.where(owner_type: "Server", owner_id: servers.map(&:id))
        
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
          detail = {
            domain_id: domain.id,
            domain_name: domain.name,
            old_identifier: domain.dkim_identifier_string,
            old_key_present: domain.dkim_private_key.present?
          }

          if params.dry_run
            detail[:status] = "would_update"
            results[:skipped] += 1
          else
            begin
              updates = {}
              
              if params.regenerate_keys
                updates[:dkim_private_key] = OpenSSL::PKey::RSA.new(1024).to_s
                updates[:dkim_identifier_string] = SecureRandom.alphanumeric(6).upcase
              elsif params.dkim_private_key.present?
                updates[:dkim_private_key] = params.dkim_private_key
                updates[:dkim_identifier_string] = params.dkim_identifier_string if params.dkim_identifier_string.present?
              end

              if updates.any?
                if domain.update(updates)
                  detail[:status] = "updated"
                  detail[:new_identifier] = domain.dkim_identifier_string
                  detail[:new_key_present] = domain.dkim_private_key.present?
                  detail[:dkim_record] = domain.dkim_record
                  detail[:dkim_record_name] = domain.dkim_record_name
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
    param :dkim_private_key, "New DKIM private key (RSA 1024+ bits)", :type => String, :required => false
    param :dkim_identifier_string, "New DKIM identifier string (6 chars uppercase)", :type => String, :required => false
    param :regenerate, "Generate new DKIM key", :type => :boolean, :required => false, :default => false
    returns Hash

    action do
      begin
        domain = Domain.find_by(id: params.id)
        error("Domain with ID #{params.id} not found", 404) unless domain

        updates = {}
        
        if params.regenerate
          updates[:dkim_private_key] = OpenSSL::PKey::RSA.new(1024).to_s
          updates[:dkim_identifier_string] = SecureRandom.alphanumeric(6).upcase
        else
          if params.dkim_private_key.present?
            begin
              key = OpenSSL::PKey::RSA.new(params.dkim_private_key)
              updates[:dkim_private_key] = key.to_s
            rescue OpenSSL::PKey::RSAError => e
              error "Invalid DKIM private key: #{e.message}", 422
            end
          end
          
          if params.dkim_identifier_string.present?
            if params.dkim_identifier_string.match?(/\A[A-Z0-9]{6}\z/)
              updates[:dkim_identifier_string] = params.dkim_identifier_string
            else
              error "DKIM identifier must be 6 uppercase alphanumeric characters", 422
            end
          end
        end

        if updates.any?
          if domain.update(updates)
            {
              success: true,
              domain_id: domain.id,
              domain_name: domain.name,
              dkim_identifier_string: domain.dkim_identifier_string,
              dkim_identifier: domain.dkim_identifier,
              dkim_record: domain.dkim_record,
              dkim_record_name: domain.dkim_record_name,
              updated_at: domain.updated_at
            }
          else
            error "Failed to update DKIM", :errors => domain.errors.full_messages
          end
        else
          error "No updates provided. Specify dkim_private_key, dkim_identifier_string, or regenerate=true", 422
        end
      rescue => e
        custom_data = e.data if e.is_a?(Moonrope::Errors::StructuredError)
        error "An error occurred while updating DKIM: #{e.message}", :details => custom_data
      end
    end
  end
end
