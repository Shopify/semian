# frozen_string_literal: true

require "concurrent-ruby"

module Semian
  module Instrumentable
    SUBSCRIBERS = Concurrent::Map.new
    SHAREABLE_SUBSCRIBERS_LOCK = Mutex.new
    private_constant :SHAREABLE_SUBSCRIBERS_LOCK

    def subscribe(name = rand, &block)
      if main_ractor?
        SUBSCRIBERS[name] = block
        update_shareable_subscribers
      else
        ractor_subscribers[name] = block
      end
      name
    end

    def unsubscribe(name)
      return ractor_subscribers.delete(name) unless main_ractor?

      subscriber = SUBSCRIBERS.delete(name)
      update_shareable_subscribers
      subscriber
    end

    def subscribers
      main_ractor? ? SUBSCRIBERS : ractor_subscribers
    end

    # Args:
    #   event (string)
    #   resource (Object)
    #   scope (string)
    #   adapter (string)
    #   payload (optional)
    def notify(*args)
      if main_ractor?
        SUBSCRIBERS.values.each { |subscriber| subscriber.call(*args) }
      else
        @shareable_subscribers&.each_value { |subscriber| subscriber.call(*args) }
        Ractor[:semian_subscribers]&.values&.each { |subscriber| subscriber.call(*args) }
      end
    end

    private

    def ractor_subscribers
      Ractor.store_if_absent(:semian_subscribers) { Concurrent::Map.new }
    end

    def update_shareable_subscribers
      SHAREABLE_SUBSCRIBERS_LOCK.synchronize do
        shareable = {}
        SUBSCRIBERS.each_pair do |name, block|
          shareable[name] = block if Ractor.shareable?(name) && Ractor.shareable?(block)
        end
        @shareable_subscribers = Ractor.make_shareable(shareable)
      end
    end
  end
end
