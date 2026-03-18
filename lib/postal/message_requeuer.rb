module Postal
  class MessageRequeuer

    def run
      Signal.trap("INT")  { @running ? @exit = true : Process.exit(0) }
      Signal.trap("TERM") { @running ? @exit = true : Process.exit(0) }

      log "Running message requeuer..."
      loop do
        @running = true
        begin
          QueuedMessage.requeue_all
        rescue => e
          log "Error in MessageRequeuer: #{e.class}: #{e.message}"
          if e.backtrace
            e.backtrace.first(5).each do |line|
              log "    #{line}"
            end
          end
          # Exit so the supervisor / Docker can restart a clean requeuer
          Process.exit(1)
        ensure
          @running = false
        end
        check_exit
        sleep 5
      end
    end

    private

    def log(text)
      Postal.logger_for(:message_requeuer).info text
    end

    def check_exit
      if @exit
        log "Exiting"
        Process.exit(0)
      end
    end

  end
end
