module Postal

  extend ActiveSupport::Autoload

  eager_autoload do
    autoload :AppLogger
    autoload :BounceMessage
    autoload :CompromiseDetector
    autoload :Config
    autoload :Countries
    autoload :DKIMHeader
    autoload :Error
    autoload :Helpers
    autoload :HTTP
    autoload :HTTPSender
    autoload :MaildirSender
    autoload :Job
    autoload :MessageDB
    autoload :MessageInspection
    autoload :MessageInspector
    autoload :MessageInspectors
    autoload :MessageParser
    autoload :MessageRequeuer
    autoload :MXLookup
    autoload :QueryString
    autoload :RabbitMQ
    autoload :ReplySeparator
    autoload :RspecHelpers
    autoload :Sender
    autoload :SendResult
    autoload :SMTPSender
    autoload :SMTPServer
    autoload :SpamCheck
    autoload :SpamChecker
    autoload :TrackingMiddleware
    autoload :UserCreator
    autoload :Version
    autoload :Worker
    autoload :VVS
  end

  def self.eager_load!
    super
    Postal::MessageDB.eager_load!
    Postal::SMTPServer.eager_load!
    Postal::MessageInspectors.eager_load!
  end

end
