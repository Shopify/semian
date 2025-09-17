# frozen_string_literal: true

module Semian
  module Instrumentable
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
      @subscribers ||= Concurrent::Map.new
    end
  end
end
