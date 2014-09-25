require 'semian/semian'

class Semian
  class << self
    attr_accessor :resources

    def register(name, tickets, default_timeout)
      resource = Resource.new(name, tickets, default_timeout)
      resources[name] = resource
    end

    def [](name)
      resources[name]
    end

    def resources
      @resources ||= {}
    end
  end
end
