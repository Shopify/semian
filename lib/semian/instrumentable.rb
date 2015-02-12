module Semian
  module Instrumentable
    def subscribe(name = rand, &block)
      subscribers[name] = block
      name
    end

    def unsubscribe(name)
      subscribers.delete(name)
    end

    def notify(*args)
      subscribers.values.each { |subscriber| subscriber.call(*args) }
    end

    private

    def subscribers
      @subscribers ||= {}
    end
  end
end
