# frozen_string_literal: true

require "concurrent-ruby"

module Semian
  module Instrumentable
    SUBSCRIBERS = Concurrent::Map.new

    def subscribe(name = rand, &block)
      SUBSCRIBERS[name] = block
      name
    end

    def unsubscribe(name)
      SUBSCRIBERS.delete(name)
    end

    def subscribers
      SUBSCRIBERS
    end

    # Args:
    #   event (string)
    #   resource (Object)
    #   scope (string)
    #   adapter (string)
    #   payload (optional)
    def notify(*args)
      SUBSCRIBERS.values.each { |subscriber| subscriber.call(*args) }
    end
  end
end
