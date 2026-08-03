class DomainApiAccess
  def initialize(server)
    @server = server
  end

  def find_by_id(id)
    scope.find_by(:id => id)
  end

  def find_by_name(name)
    normalized_name = name.to_s.downcase
    direct_scope.where('LOWER(name) = ?', normalized_name).first ||
      organization_scope.where('LOWER(name) = ?', normalized_name).first
  end

  def find_directly_owned_by_id(id)
    direct_scope.find_by(:id => id)
  end

  def scope
    direct_scope.or(organization_scope)
  end

  def direct_scope
    @server.domains
  end

  def organization_scope
    Domain.where(:owner_type => 'Organization', :owner_id => @server.organization_id)
  end
end
