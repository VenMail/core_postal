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
end
