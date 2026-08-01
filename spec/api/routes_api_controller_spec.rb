require 'rails_helper'
require 'json'

describe 'Routes API' do
  let(:authenticated_server) { create(:server) }
  let(:credential) { create(:credential, :api, :server => authenticated_server) }

  def routes_api_post(params)
    post '/api/v1/routes/route',
         :params => params.to_json,
         :headers => {
           'CONTENT_TYPE' => 'application/json',
           'X-Server-API-Key' => credential.key
         }
    JSON.parse(response.body)
  end

  def valid_route_params(domain)
    {
      :name => 'inbox',
      :domain_id => domain.id,
      :endpoint_id => 1,
      :endpoint_type => 'AddressEndpoint',
      :mode => 'Accept',
      :spam_mode => 'Mark'
    }
  end

  it 'rejects a domain owned by another server at the API ownership boundary' do
    other_domain = create(:domain, :owner => create(:server))

    response_payload = routes_api_post(valid_route_params(other_domain))

    expect(response_payload.fetch('status')).to eq('error')
    expect(response_payload.fetch('data')).to include(
      'code' => "Domain with ID #{other_domain.id} not found",
      'message' => 404
    )
    expect(response_payload.fetch('status')).not_to eq('success')
    expect(Route.where(:domain_id => other_domain.id, :server_id => authenticated_server.id)).to be_empty
  end

  it 'continues to allow a domain owned by the authenticated server organization' do
    organization_domain = create(:organization_domain, :owner => authenticated_server.organization)

    response_payload = routes_api_post(valid_route_params(organization_domain))

    expect(response).to have_http_status(:success)
    expect(response_payload.fetch('status')).to eq('success')
    expect(Route.where(:domain_id => organization_domain.id, :server_id => authenticated_server.id)).to exist
  end
end
