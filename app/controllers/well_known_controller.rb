class WellKnownController < ApplicationController

  skip_before_action :login_required, only: [:show]

  def show
    agent_name = params[:agent_name]
    domain = request.host.to_s.split(':').first
    agent_key = VvsAgentKey.active.where(agent_name: agent_name, domain: domain).order(key_version: :desc).first

    if agent_key
      render json: {
        agent_id: agent_key.agent_id,
        public_key: agent_key.public_key_base64url,
        key_version: agent_key.key_version,
        status: agent_key.status,
        algorithm: 'ed25519'
      }, headers: { 'Cache-Control' => 'public, max-age=3600' }
    else
      render json: { error: 'Agent not found' }, status: :not_found
    end
  end

end
