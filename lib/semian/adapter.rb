module Semian
  module Adapter
    def semian_identifier
      raise NotImplementedError.new("Semian adapters must implement a `semian_identifier` method")
    end

    def semian_resource
      @semian_resource ||= case semian_options
      when false
        UnprotectedResource.new(semian_identifier)
      when nil
        Semian.logger.debug("Semian is not configured for #{self.class.name}: #{semian_identifier}")
        UnprotectedResource.new(semian_identifier)
      else
        options = semian_options.dup
        options.delete(:name)
        options[:exceptions] ||= []
        options[:exceptions] += resource_exceptions
        ::Semian.retrieve_or_register(semian_identifier, **options)
      end
    end

    private

    def acquire_semian_resource(scope:, adapter:, &block)
      return yield if resource_already_acquired?
      semian_resource.acquire(scope: scope, adapter: adapter) do
        mark_resource_as_acquired(&block)
      end
    rescue ::Semian::OpenCircuitError => error
      raise self.class::CircuitOpenError.new(semian_identifier, error)
    rescue ::Semian::BaseError => error
      raise self.class::ResourceBusyError.new(semian_identifier, error)
    rescue *resource_exceptions => error
      error.semian_identifier = semian_identifier if error.respond_to?(:semian_identifier=)
      raise
    end

    def semian_options
      return @semian_options if defined? @semian_options
      options = raw_semian_options
      @semian_options = options && options.map { |k, v| [k.to_sym, v] }.to_h
    end

    def raw_semian_options
      raise NotImplementedError.new("Semian adapters must implement a `raw_semian_options` method")
    end

    def resource_exceptions
      []
    end

    def resource_already_acquired?
      @resource_acquired
    end

    def mark_resource_as_acquired
      previous = @resource_acquired
      @resource_acquired = true
      yield
    ensure
      @resource_acquired = previous
    end
  end
end
