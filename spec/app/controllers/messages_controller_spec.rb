require 'rails_helper'

describe MessagesController, type: :controller do
  describe '#recall' do
    let(:phrase) { 'Social Security' }
    let(:hours) { 48 }
    let(:subject_line) { 'Security Alert Message Recall – Phishing Attempt Detected' }
    let(:body_text) { 'Please disregard the previous email.' }

    it 'permits recall params and sends notices to matching recipients (body search)' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        create_plain_text_message(server, 'This contains Social Security information', 'recipient@example.com')

        mail_double = double(deliver: true)
        expect(AppMailer).to receive(:recall_notice).
          with('recipient@example.com', subject_line, body_text).
          and_return(mail_double)

        post :recall, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          recall: {
            phrase: phrase,
            hours: hours,
            subject: subject_line,
            body: body_text,
            search_scope: 'body'
          }
        }

        expect(response).to redirect_to(
          outgoing_organization_server_messages_path(server.organization, server)
        )
        expect(flash[:notice]).to include('Recall notice sent to 1 recipient')
      end
    end

    it 'supports subject-only search scope' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        create_plain_text_message(server, 'body without phrase', 'recipient2@example.com', :subject => 'Special Subject Social Security')

        mail_double = double(deliver: true)
        expect(AppMailer).to receive(:recall_notice).
          with('recipient2@example.com', subject_line, body_text).
          and_return(mail_double)

        post :recall, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          recall: {
            phrase: 'social security',
            hours: 48,
            subject: subject_line,
            body: body_text,
            search_scope: 'subject'
          }
        }

        expect(response).to redirect_to(
          outgoing_organization_server_messages_path(server.organization, server)
        )
        expect(flash[:notice]).to include('Recall notice sent to 1 recipient')
      end
    end

    it 'rejects missing required fields' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        post :recall, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          recall: { phrase: '', hours: 0, subject: '', body: '' }
        }

        expect(response).to redirect_to(
          outgoing_organization_server_messages_path(server.organization, server)
        )
        expect(flash[:alert]).to include('Please provide a phrase')
      end
    end
  end

  describe '#retry' do
    it 'retries a queued message with a new IP address' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        # Create a message and queued message
        message = create_plain_text_message(server, 'Test message', 'recipient@example.com')
        queued_message = QueuedMessage.create!(
          message: message,
          server: server,
          domain: 'example.com',
          manual: false
        )

        allow_any_instance_of(Postal::MessageDB::Message).to receive(:queued_message).and_return(queued_message)
        
        # Mock IP allocation to ensure it gets called
        expect(queued_message).to receive(:allocate_ip_address).with(exclude_current: true)
        expect(queued_message).to receive(:update_column).with(:ip_address_id, anything)
        expect(queued_message).to receive(:queue!)

        post :retry, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          id: message.id
        }

        expect(response).to redirect_to(organization_server_message_path(server.organization, server, message.id))
        expect(flash[:notice]).to include('will be retried shortly with a new IP address')
      end
    end

    it 'retries a held message' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        message = create_plain_text_message(server, 'Test message', 'recipient@example.com')
        message.update(held: 1)

        allow_any_instance_of(Postal::MessageDB::Message).to receive(:queued_message).and_return(nil)
        allow_any_instance_of(Postal::MessageDB::Message).to receive(:held?).and_return(true)
        expect_any_instance_of(Postal::MessageDB::Message).to receive(:add_to_message_queue).with(manual: true)

        post :retry, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          id: message.id
        }

        expect(response).to redirect_to(organization_server_message_path(server.organization, server, message.id))
        expect(flash[:notice]).to include('has been released')
      end
    end

    it 'handles retry when no IP pools are available' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        message = create_plain_text_message(server, 'Test message', 'recipient@example.com')
        queued_message = QueuedMessage.create!(
          message: message,
          server: server,
          domain: 'example.com',
          manual: false
        )

        allow_any_instance_of(Postal::MessageDB::Message).to receive(:queued_message).and_return(queued_message)
        
        # Mock IP pools to be disabled
        allow(Postal).to receive(:ip_pools?).and_return(false)
        
        # Should still call queue! even without IP allocation
        expect(queued_message).to receive(:allocate_ip_address).with(exclude_current: true)
        expect(queued_message).to receive(:update_column).with(:ip_address_id, nil)
        expect(queued_message).to receive(:queue!)

        post :retry, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          id: message.id
        }

        expect(response).to redirect_to(organization_server_message_path(server.organization, server, message.id))
        expect(flash[:notice]).to include('will be retried shortly with a new IP address')
      end
    end

    it 'handles retry when only one IP is available' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        message = create_plain_text_message(server, 'Test message', 'recipient@example.com')
        queued_message = QueuedMessage.create!(
          message: message,
          server: server,
          domain: 'example.com',
          manual: false
        )
        
        # Mock IP allocation to return the same IP when no alternatives exist
        original_ip = double('ip_address', id: 123)
        queued_message.update(ip_address: original_ip)
        
        allow(queued_message).to receive(:allocate_ip_address).with(exclude_current: true) do
          queued_message.ip_address = original_ip # Falls back to same IP
        end
        
        expect(queued_message).to receive(:update_column).with(:ip_address_id, 123)
        expect(queued_message).to receive(:queue!)

        post :retry, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          id: message.id
        }

        expect(response).to redirect_to(organization_server_message_path(server.organization, server, message.id))
        expect(flash[:notice]).to include('will be retried shortly with a new IP address')
      end
    end

    it 'handles retry when message has no raw message' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        message = create_plain_text_message(server, 'Test message', 'recipient@example.com')
        # Stub the raw_message? method on any message instance the controller might load
        allow_any_instance_of(Postal::MessageDB::Message).to receive(:raw_message?).and_return(false)

        post :retry, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          id: message.id
        }

        expect(response).to redirect_to(organization_server_message_path(server.organization, server, message.id))
        expect(flash[:alert]).to include('no longer available')
      end
    end
  end

  describe '#retry_with_ip' do
    it 'retries a queued message with a specific IP address' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        message = create_plain_text_message(server, 'Test message', 'recipient@example.com')
        queued_message = QueuedMessage.create!(
          message: message,
          server: server,
          domain: 'example.com',
          manual: false
        )

        allow_any_instance_of(Postal::MessageDB::Message).to receive(:queued_message).and_return(queued_message)
        ip_address = IPAddress.create!(ipv4: '192.168.1.100', hostname: 'mail.example.com', priority: 100, ip_pool: server.ip_pool)

        expect(queued_message).to receive(:update_column).with(:ip_address_id, ip_address.id.to_s)
        expect(queued_message).to receive(:queue!)

        post :retry_with_ip, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          id: message.id,
          ip_address_id: ip_address.id
        }, format: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['flash']['notice']).to include('selected IP address')
      end
    end

    it 'retries a held message with a specific IP address' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        message = create_plain_text_message(server, 'Test message', 'recipient@example.com')
        message.update(held: 1)
        ip_address = IPAddress.create!(ipv4: '192.168.1.100', hostname: 'mail.example.com', priority: 100, ip_pool: server.ip_pool)

        new_queued_message = double('queued_message')
        allow_any_instance_of(Postal::MessageDB::Message).to receive(:queued_message).and_return(nil)
        allow_any_instance_of(Postal::MessageDB::Message).to receive(:held?).and_return(true)
        expect_any_instance_of(Postal::MessageDB::Message).to receive(:add_to_message_queue).with(manual: true).and_return(new_queued_message)
        expect(new_queued_message).to receive(:update_column).with(:ip_address_id, ip_address.id.to_s)

        post :retry_with_ip, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          id: message.id,
          ip_address_id: ip_address.id
        }, format: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['flash']['notice']).to include('released and will be retried')
      end
    end

    it 'handles retry with IP when message has no raw message' do
      with_global_server do |server|
        user = server.organization.owner
        user.update!(:admin => true)

        allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

        message = create_plain_text_message(server, 'Test message', 'recipient@example.com')
        # Stub the raw_message? method on any message instance the controller might load
        allow_any_instance_of(Postal::MessageDB::Message).to receive(:raw_message?).and_return(false)

        post :retry_with_ip, params: {
          org_permalink: server.organization.permalink,
          server_id: server.permalink,
          id: message.id,
          ip_address_id: 123
        }, format: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['flash']['alert']).to include('no longer available')
      end
    end
  end
end
