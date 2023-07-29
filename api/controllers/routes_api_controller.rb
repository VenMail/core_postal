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
        param :name, "The e-mail address of the recipient (max 255)", :type => String, :required => true
        param :domain_id, "The id of the domain", :type => Integer, :required => true
        param :endpoint_id, "The id of the endpoint", :type => Integer, :required => true
        param :endpoint_type, "The type of the endpoint", :type => String
        param :mode, "The mode of the route", :type => String
        param :spam_mode, "The spam mode of the route", :type => String
        # Errors
        error 'ValidationError', "The provided data was not sufficient to create a route", :attributes => {:errors => "A hash of error details"}
        # Return
        returns Hash
        # Action
        action do
          @route.create(route_params)
          if @route.persisted?
            result[:data] = {:id => @route.id, :name => @route.name}   
          else
            raise ValidationError.new(@route.errors)
          end
        rescue ValidationError => e
          error "ValidationError", e.message, :errors => e.errors
        end
      end
      
      private

      def route_params
        params.permit(:name, :domain_id, :endpoint_id, :endpoint_type, :mode, :spam_mode)
      end
      
  end
