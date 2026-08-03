require 'rails_helper'

RSpec.describe DomainsController, :type => :controller do
  describe '#setup' do
    it 'accepts a malformed DKIM row without raising' do
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
    end

    it 'accepts missing legacy DKIM material without raising' do
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
    end

    it 'uses the safe DKIM setup accessor and repair-required branch in the template' do
      template = File.read(Rails.root.join('app/views/domains/setup.html.haml'))

      expect(template).to include('- dkim_setup_record = @domain.dkim_setup_record')
      expect(template).to include('- if dkim_setup_record.present?')
      expect(template).to include('DKIM setup requires repair before DNS instructions can be shown.')
      expect(template).not_to include('%pre.codeBlock.u-margin= @domain.dkim_record')
    end
  end
end
