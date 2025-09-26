# frozen_string_literal: true

require "concurrent-ruby"

module Semian
  module Instrumentable
    extend self

    self.subscribers = Concurrent::Map.new

    def subscribe(name = rand, &block)
      subscribers[name] = block
      name
    end

    def unsubscribe(name)
      subscribers.delete(name)
    end

    # Args:
    #   event (string)
    #   resource (Object)
    #   scope (string)
    #   adapter (string)
    #   payload (optional)
    def notify(*args)
      subscribers.values.each { |subscriber| subscriber.call(*args) }
    end

    private

    def subscribers
      self.class.subscribers
    end
  end
end
