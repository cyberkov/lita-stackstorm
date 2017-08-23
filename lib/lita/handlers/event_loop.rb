require 'eventmachine'
require 'singleton'

module Lita
  module Handlers
    class Stackstorm < Handler
      class EventLoop
        include Singleton
        class << self
          def defer
            EM.defer { yield }
          end

          def run
            EM.run { yield }
          end

          def safe_stop
            EM.stop if running?
          end

          def running?
            EM.reactor_running? && !EM.stopping?
          end
        end
      end
    end
  end
end
