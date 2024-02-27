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
      end
    end
  end
  