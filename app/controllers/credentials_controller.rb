class CredentialsController < ApplicationController

  include WithinOrganization

  before_action { @server = organization.servers.present.find_by_permalink!(params[:server_id]) }
  before_action { params[:id] && @credential = @server.credentials.find_by_uuid!(params[:id]) }

  def index
    @credentials = @server.credentials.order(:name).to_a
  end

  def new
    @credential = @server.credentials.build
  end

  def create
    @credential = @server.credentials.build(params.require(:credential).permit(:type, :name, :key, :hold))
    if @credential.save
      redirect_to_with_json [organization, @server, :credentials]
    else
      render_form_errors 'new', @credential
    end
  end

  def update
    if @credential.update(params.require(:credential).permit(:name, :key, :hold))
      redirect_to_with_json [organization, @server, :credentials]
    else
      render_form_errors 'edit', @credential
    end
  end

  def destroy
    @credential.destroy
    redirect_to_with_json [organization, @server, :credentials]
  end
  
  # ENHANCED: Manual reset endpoint for administrators
  def reset_reputation
    if @credential.update(hold: false, hold_at: nil, hold_reason: nil)
      # Trigger webhook for manual credential unlock
      WebhookRequest.trigger(
        @server,
        'CredentialUnlocked',
        {
          server: @server.webhook_hash,
          credential: {
            id: @credential.id,
            uuid: @credential.uuid,
            name: @credential.name,
            type: @credential.type
          },
          reason: "Manual reset by administrator",
          bounce_rate: @server.bounce_rate
        }
      )
      
      Rails.logger.info "CredentialsController: Manual reset by admin - credential #{@credential.uuid}"
      redirect_to_with_json [organization, @server, :credentials], 
        notice: "Credential reputation has been reset successfully"
    else
      render_form_errors 'edit', @credential
    end
  end

end
