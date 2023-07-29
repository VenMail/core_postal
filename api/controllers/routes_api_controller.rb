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
    param :endpoint_type, type: String, desc: "The type of the endpoint"
    param :mode, type: String, desc: "The mode of the route"
    param :spam_mode, type: String, desc: "The spam mode of the route"
    # Errors
    error 'ValidationError', "The provided data was not sufficient to create a route", attributes: { errors: "A hash of error details" }
    # Return
    returns Hash
    # Action
    action do
      @route.create(route_params)
      if @route.persisted?
        result[:data] = { id: @route.id, name: @route.name }
      else
        raise ValidationError.new(@route.errors)
      end
    rescue ValidationError => e
      error "ValidationError", e.message, errors: e.errors
    end
  end

  def route_params
    params.permit(:name, :domain_id, :endpoint_id, :endpoint_type, :mode, :spam_mode)
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
      result[:data] = routes.map do |route|
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
    end
  end
end
