require 'rails_helper'

RSpec.describe DomainsController, :type => :controller do
  render_views

  describe '#setup' do
    it 'shows a repair-required state instead of rendering malformed DKIM instructions' do
      server = create(:server)
      domain = create(:domain, :owner => server)
      user = server.organization.owner
      user.update!(:admin => true)
      domain.update_column(:dkim_identifier_string, '%dkim_data%')
      domain.update_column(:dkim_status, 'OK')

      allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

      get :setup, :params => {
        :org_permalink => server.organization.permalink,
        :server_id => server.permalink,
        :id => domain.uuid
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('DKIM setup requires repair')
      expect(response.body).not_to include('%dkim_data%')
      expect(response.body).not_to include('Your DKIM record looks good!')
      expect(response.body).not_to include('You need to add a new TXT record with the name')
    end

    it 'shows a repair-required state instead of raising for missing legacy DKIM material' do
      server = create(:server)
      domain = create(:domain, :owner => server)
      user = server.organization.owner
      user.update!(:admin => true)
      domain.update_column(:dkim_private_key, nil)

      allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

      expect do
        get :setup, :params => {
          :org_permalink => server.organization.permalink,
          :server_id => server.permalink,
          :id => domain.uuid
        }
      end.not_to raise_error

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('DKIM setup requires repair')
      expect(response.body).not_to include('You need to add a new TXT record with the name')
    end
  end
end
