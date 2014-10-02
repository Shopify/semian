require 'semian/semian'

class Semian
  class << self
    def register(name, tickets: 0, permissions: 0600, timeout: 1)
      resource = Resource.new(name, tickets, permissions, timeout)
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

require 'semian/version'
