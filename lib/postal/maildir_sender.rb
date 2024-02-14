require 'fileutils'

module Postal
  class MaildirSender < Sender
    def initialize(domain)
      @maildir_path = "/opt/postal/mail"
      @log_id = Nifty::Utils::RandomString.generate(:length => 8).upcase
    end

    def send_message(message)
        start_time = Time.now
        result = SendResult.new
        result.log_id = @log_id
      
        # Generate a unique filename for the new message file
        filename = File.join(@maildir_path, message.rcpt_to, "new", "#{Time.now.to_f}.#{@log_id}")
      
        # Write the raw message to the file
        File.write(filename, message.raw_message)
      
        # Check if the file was written successfully
        if File.exist?(filename)
          result.type = 'Sent'
          result.details = "Message saved to Maildir successfully"
        else
          result.type = 'HardFail'
          result.details = "Failed to save message to Maildir"
        end
      
        result.time = (Time.now - start_time).to_f.round(2)
        result
      end

    private

    def log(text)
      Postal.logger_for(:maildir_sender).info("[#{@log_id}] #{text}")
    end
  end
end
