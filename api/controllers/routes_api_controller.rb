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
    param :route, required: true do
      param :name, type: String, desc: "The e-mail address of the recipient (max 255)"
      param :domain_id, type: Integer, desc: "The id of the domain"
      param :endpoint_id, type: Integer, desc: "The id of the endpoint"
      param :endpoint_type, type: String, desc: "The type of the endpoint"
      param :mode, type: String, desc: "The mode of the route"
      param :spam_mode, type: String, desc: "The spam mode of the route"
    end
    # Errors
    error 'RecordInvalid', "The provided data was not sufficient to create a route", attributes: { errors: "A hash of error details" }
    # Return
    returns Hash
    # Action
    action do
      result = {}  # Initialize the result variable
      # Validate input data
      unless route_params[:name].present? && route_params[:domain_id].present? && route_params[:endpoint_id].present?
        error! "Missing required parameters: name, domain_id, or endpoint_id", 400
      end
      # Use the nested `params[:route]` to get the permitted parameters
      if @route.create(params[:route])
        result[:data] = { id: @route.id, name: @route.name }
      else
        error! "Failed to create the route", 500
      end

      result  # Return the result
    rescue ActiveRecord::RecordInvalid => e
      error! "RecordInvalid: #{e.message}", 400, errors: e.record.errors
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
