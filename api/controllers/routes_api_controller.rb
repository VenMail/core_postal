controller :routes do
  friendly_name "Routes API"
  description "This API allows you to manage routes"
  authenticator :server

  before do
    @route = Route.new
    @route.server = identity.server
  end

  action :route do
    title "Add a route"
    description "Create an email route"
    # Acceptable Parameters
    param :name, required: true, type: String, desc: "The e-mail address of the recipient (max 255)"
    param :domain_id, required: true, type: Integer, desc: "The id of the domain"
    param :endpoint_id, required: true, type: Integer, desc: "The id of the endpoint"
    param :endpoint_type, type: String, desc: "The type of the endpoint (valid values: 'HttpEndpoint', 'AddressEndpoint', ...)"
    param :mode, type: String, desc: "The mode of the route (valid values: 'Endpoint', 'Accept', ...)"
    param :spam_mode, type: String, desc: "The spam mode of the route (valid values: 'Mark', 'Quarantine', ...)"
    # Errors
    error 'RecordInvalid', "The provided data was not sufficient to create a route", attributes: { errors: "A hash of error details" }
    error 'DomainNotFound', "The domain_id provided does not exist"
    error 'EndpointNotFound', "The endpoint_id provided does not exist"
    # Return
    returns Hash
    # Action
    action do
      def route_params
        params.permit(:name, :domain_id, :endpoint_id, :endpoint_type, :mode, :spam_mode)
      end

      # Check if domain_id and endpoint_id exist in the database
      domain = Domain.find_by(id: route_params[:domain_id])
      endpoint = Endpoint.find_by(id: route_params[:endpoint_id])
      raise DomainNotFound unless domain
      raise EndpointNotFound unless endpoint

      result = {}  # Initialize the result variable
      @route.create(
        name: route_params[:name],
        domain_id: route_params[:domain_id],
        endpoint_id: route_params[:endpoint_id],
        endpoint_type: route_params[:endpoint_type],
        mode: route_params[:mode],
        spam_mode: route_params[:spam_mode]
      )
      if @route.persisted?
        result[:data] = { id: @route.id, name: @route.name }
      else
        raise ActiveRecord::RecordInvalid.new(@route)
      end
      result  # Return the result
    rescue ActiveRecord::RecordInvalid => e
      error "RecordInvalid", e.message, errors: e.record.errors
    rescue DomainNotFound => e
      error "DomainNotFound", e.message
    rescue EndpointNotFound => e
      error "EndpointNotFound", e.message
    end
  end

  action :list do
    # Set the title and description of the action
    title "List routes"
    description "Retrieve all available routes for the current server"
    # Return
    returns Array
    # Action
    action do
      # Find all routes that belong to the current server identity
      routes = Route.where(server_id: identity.server.id)
      # Return an array of hashes with the route attributes
      result = routes.map do |route|
        {
          id: route.id,
          name: route.name,
          domain_id: route.domain_id,
          endpoint_id: route.endpoint_id,
          endpoint_type: route.endpoint_type,
          mode: route.mode,
          spam_mode: route.spam_mode
        }
      end
      result  # Return the result
    end
  end
end
