require 'ipaddr'
require 'postal/api_request_trust'

authenticator :server do
  friendly_name "Server Authenticator"
  header "X-Server-API-Key", "The API token for a server that you wish to authenticate with.", :example => 'f29a45f0d4e1744ebaee'
  error 'InvalidServerAPIKey', "The API token provided in X-Server-API-Key was not valid.", :attributes => {:token => "The token that was looked up"}
  error 'ServerSuspended', "The mail server has been suspended"
  error 'IPBanned', "The IP address has been banned"
  lookup do
    if key = request.headers['X-Server-API-Key']
      # Check if IP is globally banned first (before any database queries)
      if GlobalSuppression.ip_banned?(request.ip)
        error 'IPBanned'
      elsif credential = Credential.where(:type => 'API', :key => key).first
        if credential.server.suspended?
          error 'ServerSuspended'
        else
          credential.use
          credential
        end
      else
        error 'InvalidServerAPIKey', :token => key
      end
    end
  end
  rule :default, "AccessDenied", "Must be authenticated as a server." do
    identity.is_a?(Credential)
  end
end

# This authenticator is deliberately limited to management APIs. It preserves
# API-key authentication, suspension checks, and credential audit usage while
# allowing authenticated infrastructure to reconcile DNS and configuration
# from an explicitly trusted source even when its request IP is globally
# suppressed. Mail-submission APIs must remain on :server so GlobalSuppression
# continues to stop mail from banned IPs.
authenticator :server_control_plane do
  friendly_name "Server Control-plane Authenticator"
  header "X-Server-API-Key", "The API token for a server that you wish to authenticate with.", :example => 'f29a45f0d4e1744ebaee'
  error 'InvalidServerAPIKey', "The API token provided in X-Server-API-Key was not valid.", :attributes => {:token => "The token that was looked up"}
  error 'ServerSuspended', "The mail server has been suspended"
  lookup do
    if key = request.headers['X-Server-API-Key']
      credential = Credential.where(:type => 'API', :key => key).first
      whitelist = if Postal.config.general.respond_to?(:whitelist)
                    Array(Postal.config.general.whitelist)
                  else
                    []
                  end
      trusted_control_plane = Postal::ApiRequestTrust.trusted?(
        request,
        :expected_master_key => Postal.config.general.master_api_key,
        :whitelist => whitelist
      )

      if GlobalSuppression.ip_banned?(request.ip) && !(credential && trusted_control_plane)
        error 'IPBanned'
      elsif credential
        if credential.server.suspended?
          error 'ServerSuspended'
        else
          credential.use
          credential
        end
      else
        error 'InvalidServerAPIKey', :token => key
      end
    end
  end
  rule :default, "AccessDenied", "Must be authenticated as a server." do
    identity.is_a?(Credential)
  end
end

authenticator :master do
  friendly_name "Master Authenticator"
  header "X-Master-Key", "The master token", :example => 'asdf'
  error 'InvalidKey', "The key was not valid.", :attributes => {:key => "The key supplied"}
  error 'InvalidIP', "The IP is invalid", :attributes => {:ip => "Given header IP"}
  lookup do
    if key = request.headers['X-Master-Key']
      if !Postal::ApiRequestTrust.key_valid?(key, Postal.config.general.master_api_key)
        error 'InvalidKey', :key => key
      elsif Postal::ApiRequestTrust.source_trusted?(
        request.ip,
        Postal.config.general.respond_to?(:whitelist) ? Postal.config.general.whitelist : []
      )
        'authok'
      else
        error 'InvalidIP', :ip => request.ip
      end
    end
  end
  rule :default, "AccessDenied", "Must be authenticated as a master." do
    identity.is_a?(String)
  end
end

authenticator :anonymous do
  rule :default, "MustNotBeAuthenticated", "Must not be authenticated." do
    identity.nil?
  end
end
