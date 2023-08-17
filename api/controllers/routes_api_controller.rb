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
    param :name, "The e-mail address of the recipient (max 255)", :type => String 
    param :domain_id, "The id of the domain", :type => Integer
    param :endpoint_id, "The id of the endpoint", :type => Integer
    param :endpoint_type, "The type of the endpoint", :type => String
    param :mode, "The mode of the route", :type => String
    param :spam_mode, "The spam mode of the route", :type => String
    # Errors
    error 'RecordInvalid', "The provided data was not sufficient to create a route", attributes: { errors: "A hash of error details" }
    # Return
    returns Hash
    # Action
    action do
      result = {}  # Initialize the result variable
      # Validate input data
      unless params.name && params.domain_id && params.endpoint_id
        request_body = request.body.read
        error_message = "Missing required parameters: name, domain_id, or endpoint_id"
        error_message += "\nReceived JSON body: #{request_body}"
        error error_message, 400
      end

      domain = Domain.find_by(id: params.domain_id)
      unless domain
        error "Domain with ID #{domain_id} not found", 404
      end
        new_route = Route.create(
        name: params.name,
        server_id: identity.server.id,
        domain_id: params.domain_id,
        endpoint_id: params.endpoint_id,
        endpoint_type: params.endpoint_type,
        mode: params.mode,
        spam_mode: params.spam_mode
      )
      if new_route.persisted?
        result[:data] = { id: new_route.id, name: new_route.name }
      else
        error "Failed to create the route", 500
      end

      result  # Return the result
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
