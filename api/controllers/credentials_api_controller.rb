controller :credentials do
  friendly_name "Credentials API"
  description "Manage SMTP credentials for the current server"
  authenticator :server

  action :list do
    title "List credentials"
    description "List SMTP credentials for this server"
    returns Array
    action do
      identity.server.credentials.order(:name).map do |c|
        {
          id: c.id,
          uuid: c.uuid,
          name: c.name,
          type: c.type,
          hold: c.hold,
          last_used_at: c.last_used_at
        }
      end
    end
  end

  action :create do
    title "Create SMTP credential"
    description "Create a new SMTP credential"
    param :name, "Name for the credential", type: String
    param :hold, "Whether to hold the new credential", type: :boolean
    returns Hash
    action do
      cred = identity.server.credentials.build(type: 'SMTP', name: params.name, hold: !!params.hold)
      if cred.save
        { id: cred.id, uuid: cred.uuid, name: cred.name, type: cred.type, hold: cred.hold, key: cred.key }
      else
        error "RecordInvalid", errors: cred.errors.full_messages
      end
    end
  end

  action :regenerate do
    title "Regenerate SMTP credential"
    description "Create a new credential and hold the old one"
    param :uuid, "UUID of the existing credential", type: String
    returns Hash
    action do
      old = identity.server.credentials.find_by_uuid(params.uuid)
      error("NotFound", 404) unless old
      # create new
      new_cred = identity.server.credentials.build(type: 'SMTP', name: old.name)
      if new_cred.save
        old.update(hold: true)
        WebhookRequest.trigger(identity.server, 'CredentialLocked', {
          server: identity.server.webhook_hash,
          credential: { id: old.id, uuid: old.uuid, name: old.name, type: old.type },
          reason: 'Rotated'
        })
        { old_id: old.id, old_uuid: old.uuid, new_id: new_cred.id, new_uuid: new_cred.uuid, key: new_cred.key }
      else
        error "RecordInvalid", errors: new_cred.errors.full_messages
      end
    end
  end

  action :revoke do
    title "Revoke SMTP credential"
    description "Mark a credential as held"
    param :uuid, "UUID of the credential", type: String
    returns Hash
    action do
      cred = identity.server.credentials.find_by_uuid(params.uuid)
      error("NotFound", 404) unless cred
      cred.update(hold: true)
      WebhookRequest.trigger(identity.server, 'CredentialLocked', {
        server: identity.server.webhook_hash,
        credential: { id: cred.id, uuid: cred.uuid, name: cred.name, type: cred.type },
        reason: 'Revoked'
      })
      { id: cred.id, uuid: cred.uuid, hold: cred.hold }
    end
  end
end
