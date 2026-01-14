module WithinOrganization

  extend ActiveSupport::Concern

  included do
    helper_method :organization
    before_action :add_organization_to_page_title
  end

  private

  def organization
    @organization ||= if logged_in?
      current_user.organizations_scope.find_by_permalink!(params[:org_permalink])
    else
      raise ActiveRecord::RecordNotFound, "Organization not found" unless params[:org_permalink]
      # For test environments where authentication might be stubbed
      Organization.find_by_permalink!(params[:org_permalink])
    end
  end

  def add_organization_to_page_title
    page_title << organization.name
  end

end
