# == Schema Information
# Database: maildb
# Table name: mail_users
#
#  id              :integer          not null, primary key
#  last_login      :date             null
#  active          :boolean          default(TRUE)
#  email           :string(100)
#  password        :string(100)
#

module Postal
    module MessageDB
      class MailUser
        def initialize(database)
          @database = database
        end

        def find(email)
          @database.select('mail_users', :db => 'maildb', :where => {:email => email}, :limit => 1).first
        end

        def update_login(email)
          # Use current date for last_login
          current_date = Date.today.strftime("%Y-%m-%d")
          @database.update('mail_users', {:last_login => current_date}, :db => 'maildb', :where => {:email => email})
        end

        def active?(email)
          user = find(email)
          user && [true, 1, '1'].include?(user['active'])
        end

        # The conditional update makes the transition idempotent so competing
        # workers cannot emit duplicate lock events for the same mailbox.
        def deactivate(email)
          @database.update('mail_users', {:active => false}, :db => 'maildb', :where => {:email => email, :active => true}) == 1
        end
      end
    end
  end

