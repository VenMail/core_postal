require 'fileutils'
require 'postal/error'

module Postal
  class MaildirSender < Sender
    DEFAULT_DIR_MODE = 0o770

    def initialize()
      @maildir_path = "/mail/v1"
      @log_id = Nifty::Utils::RandomString.generate(:length => 8).upcase
    end

    def cached_sender(klass, *args)
      @sender ||= begin
        sender = klass.new(*args)
        sender.start
        sender
      end
    end
  
    def send_message(message)
      start_time = Time.now
      result = SendResult.new
      result.log_id = @log_id

      ensure_directory!(@maildir_path)

      http_endpoint = message.route.server.http_endpoints.first
      if http_endpoint
        http_sender = cached_sender(Postal::HTTPSender, http_endpoint)
        http_result = http_sender.send_message(message)
        result.details = http_result.details
      else
        result.details = "No default HTTP endpoint found for the server"
      end

      # Generate a unique filename for the new message file
      destination_folder = File.join(@maildir_path, message.recipient_domain, message.recipient_username)
      ensure_directory!(destination_folder)

      new_folder = File.join(destination_folder, "new")
      ensure_directory!(new_folder)

      # Create 'cur' and 'tmp' directories if they don't exist
      %w[cur tmp].each do |subdir|
        subdir_path = File.join(destination_folder, subdir)
        ensure_directory!(subdir_path)
      end

      filename = File.join(new_folder, "#{Time.now.to_f}.#{@log_id}")

      # Write the raw message to the file with UTF-8 encoding
      File.open(filename, "w:UTF-8") do |file|
        file.write(message.raw_message.force_encoding("UTF-8"))
      end

      # Check if the file was written successfully
      if File.exist?(filename)
        result.type = 'Sent'
        result.details += "\nMessage saved to Maildir successfully"
      else
        result.type = 'HardFail'
        result.details += "\nFailed to save message to Maildir"
      end

      result.time = (Time.now - start_time).to_f.round(2)
      result
    end

    private

    def log(text)
      Postal.logger_for(:maildir_sender).info("[#{@log_id}] #{text}")
    end

    def ensure_directory!(path)
      return if Dir.exist?(path) && File.writable?(path)

      FileUtils.mkdir_p(path, mode: DEFAULT_DIR_MODE) unless Dir.exist?(path)

      begin
        FileUtils.chmod(DEFAULT_DIR_MODE, path) if Dir.exist?(path)
      rescue Errno::EPERM, Errno::EACCES
        raise Postal::Error, "Maildir directory #{path} exists but permissions could not be adjusted. Ensure Postal has write access."
      end

      unless File.writable?(path)
        raise Postal::Error, "Maildir directory #{path} is not writable. Update permissions to allow Postal to write deliveries."
      end
    rescue Errno::EACCES => e
      raise Postal::Error, "Maildir directory #{path} could not be prepared: #{e.message}"
    end
  end
end
