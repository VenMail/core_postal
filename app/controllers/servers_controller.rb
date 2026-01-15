class ServersController < ApplicationController

  include WithinOrganization
  require 'csv'

  before_action :admin_required, :only => [:advanced, :suspend, :unsuspend, :clear_queue, :export_queue, :clear_held, :export_held]
  before_action { params[:id] && @server = organization.servers.present.find_by_permalink!(params[:id]) }

  def index
    @servers = organization.servers.present.order(:name).to_a
  end

  def show
    if @server.created_at < 48.hours.ago
      @graph_type = :daily
      graph_data = @server.message_db.statistics.get(:daily, [:incoming, :outgoing, :bounces], Time.now, 30)
    elsif @server.created_at < 24.hours.ago
      @graph_type = :hourly
      graph_data = @server.message_db.statistics.get(:hourly, [:incoming, :outgoing, :bounces], Time.now, 48)
    else
      @graph_type = :hourly
      graph_data = @server.message_db.statistics.get(:hourly, [:incoming, :outgoing, :bounces], Time.now, 24)
    end
    @first_date = graph_data.first.first
    @last_date = graph_data.last.first
    @graph_data = graph_data.map(&:last)
    @messages = @server.message_db.messages(:order => 'id', :direction => 'desc', :limit => 6)
  end

  def new
    @server = organization.servers.build
  end

  def create
    @server = organization.servers.build(safe_params(:permalink))
    if @server.save
      redirect_to_with_json organization_server_path(organization, @server)
    else
      render_form_errors 'new', @server
    end
  end

  def update
    extra_params = [:spam_threshold, :spam_failure_threshold, :postmaster_address]
    extra_params += [:send_limit, :allow_sender, :log_smtp_data, :outbound_spam_threshold, :message_retention_days, :raw_message_retention_days, :raw_message_retention_size, :block_outgoing_without_verified_route] if current_user.admin?
    if @server.update(safe_params(*extra_params))
      redirect_to_with_json organization_server_path(organization, @server), :notice => "Server settings have been updated"
    else
      render_form_errors 'edit', @server
    end
  end

  def destroy
    unless current_user.authenticate(params[:password])
      respond_to do |wants|
        wants.html do
          redirect_to [:delete, organization, @server], :alert => "The password you entered was not valid. Please check and try again."
        end
        wants.json do
          render :json => {:alert => "The password you entere was invalid. Please check and try again"}
        end
      end
      return
    end
    @server.soft_destroy
    redirect_to_with_json organization_root_path(organization), :notice => "#{@server.name} has been deleted successfully"
  end

  def queue
    @messages = @server.queued_messages.order(:id => :desc).page(params[:page])
    @messages_with_message = @messages.include_message
  end

  def export_queue
    headers = ["id", "server_id", "message_id", "created_at", "updated_at", "domain", "attempts", "locked_at", "retry_after", "route_id", "manual", "batch_key", "locked_by", "ip_address_id", "to", "from", "subject"]
    csv_rows = []
    @server.queued_messages.retriable.find_each do |queued_message|
      message = queued_message.message
      next unless message && message.scope == 'outgoing'
      csv_rows << [
        queued_message.id,
        queued_message.server_id,
        queued_message.message_id,
        queued_message.created_at&.iso8601,
        queued_message.updated_at&.iso8601,
        queued_message.domain,
        queued_message.attempts,
        queued_message.locked_at&.iso8601,
        queued_message.retry_after&.iso8601,
        queued_message.route_id,
        queued_message.manual,
        queued_message.batch_key,
        queued_message.locked_by,
        queued_message.ip_address_id,
        message.rcpt_to,
        message.mail_from,
        message.subject
      ]
    end

    if csv_rows.empty?
      redirect_to_with_json [:queue, organization, @server], :alert => "No outgoing queued messages available to export"
    else
      csv_string = CSV.generate do |csv|
        csv << headers
        csv_rows.each { |row| csv << row }
      end
      send_data csv_string,
        :filename => "outgoing-queue-#{organization.permalink}-#{@server.permalink}-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.csv",
        :type => 'text/csv'
    end
  end

  def clear_queue
    removed = 0
    @server.queued_messages.find_each do |queued_message|
      message = queued_message.message
      next unless message && message.scope == 'outgoing'
      queued_message.destroy
      removed += 1
    end
    notice = removed.zero? ? "No outgoing queued messages were removed" : "Removed #{removed} outgoing queued message#{'s' unless removed == 1}"
    redirect_to_with_json [:queue, organization, @server], :notice => notice
  end

  def export_held
    headers = ["id", "server_id", "message_id", "timestamp", "scope", "status", "held", "hold_expiry", "to", "from", "subject"]
    
    # Check if there are any held messages first
    held_messages = @server.message_db.messages(:where => {:held => 1}, :limit => 1)
    
    if held_messages.empty?
      redirect_to_with_json [:held, organization, @server, :messages], :alert => "No held messages available to export"
      return
    end
    
    # Stream the CSV to handle large datasets efficiently
    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = "attachment; filename=\"held-messages-#{organization.permalink}-#{@server.permalink}-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.csv\""
    
    self.response_body = Enumerator.new do |yielder|
      # Write headers first
      yielder << CSV.generate_line(headers)
      
      # Stream messages one by one to avoid memory issues
      @server.message_db.messages(:where => {:held => 1}).each do |message|
        row = [
          message.id,
          message.server_id,
          message.message_id,
          message.timestamp&.iso8601,
          message.scope,
          message.status,
          message.held,
          message.hold_expiry&.iso8601,
          message.rcpt_to,
          message.mail_from,
          message.subject
        ]
        yielder << CSV.generate_line(row)
      end
    end
  end

  def clear_held
    removed = 0
    
    # Process messages in batches to handle large datasets efficiently
    @server.message_db.messages(:where => {:held => 1}).each do |message|
      message.delete
      removed += 1
      
      # Yield control periodically to prevent blocking for too long
      if removed % 1000 == 0
        sleep(0.01) # Small delay to allow other requests
      end
    end
    
    notice = removed.zero? ? "No held messages were removed" : "Removed #{removed} held message#{'s' unless removed == 1}"
    redirect_to_with_json [:held, organization, @server, :messages], :notice => notice
  end

  def suspend
    @server.suspend(params[:reason])
    redirect_to_with_json [organization, @server], :notice => "Server has been suspended"
  end

  def unsuspend
    @server.unsuspend
    redirect_to_with_json [organization, @server], :notice => "Server has been unsuspended"
  end

  private

  def safe_params(*extras)
    params.require(:server).permit(:name, :mode, :ip_pool_id, *extras)
  end

end
